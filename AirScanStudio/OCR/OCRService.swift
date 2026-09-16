import Foundation
import PDFKit
import UIKit
import Vision

// MARK: - OCR (對應 Android 版 ML Kit Text Recognition v2，改用內建 Vision framework)

/// 單頁 OCR 結果：辨識片段 + 正規化 boundingBox（Vision 座標：原點左下、0–1）
struct OCRTextRun: Equatable {
    let text: String
    let boundingBox: CGRect
}

struct OCRPageResult: Equatable {
    var runs: [OCRTextRun] = []
    var text: String { runs.map(\.text).joined(separator: "\n") }
}

/// 整份文件的 OCR 產出
struct OCRDocumentResult {
    let textFileURL: URL
    let fullText: String
    /// PDF 是否已重寫為含不可見文字層（可搜尋/複製）
    let textLayerWritten: Bool
}

enum OCRService {
    /// 對應 backlog 預設：繁中、簡中、英文（iOS 16+ Vision 支援 zh-Hant/zh-Hans）
    static let defaultLanguages = ["zh-Hant", "zh-Hans", "en-US"]
    /// 比照 Android 限制：輸入長邊取樣至 4096px
    static let maxLongEdge: CGFloat = 4096

    // MARK: 辨識

    /// 對單一影像執行 VNRecognizeTextRequest（accurate、逐行 boundingBox）。
    /// 同步、CPU 密集：請在背景 Task 呼叫。
    static func recognize(in image: UIImage, languages: [String] = OCRService.defaultLanguages) throws -> OCRPageResult {
        guard let cg = downsampled(image).cgImage else {
            throw AppError("無法讀取影像進行 OCR")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = languages
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try handler.perform([request])
        let observations: [VNRecognizedTextObservation] = request.results ?? []
        let runs: [OCRTextRun] = observations.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            return OCRTextRun(text: candidate.string, boundingBox: obs.boundingBox)
        }
        return OCRPageResult(runs: runs)
    }

    // MARK: 整份文件流程

    /// 對已存的掃描文件（.jpg / .pdf）執行 OCR：
    /// - 寫出 <文件名>.txt（全文）
    /// - PDF：以 drawPDFPage 保留原始內容、疊加不可見文字層後原地替換
    static func processDocument(at url: URL, assumedDPI: Int = 300, languages: [String] = OCRService.defaultLanguages) throws -> OCRDocumentResult {
        let ext = url.pathExtension.lowercased()
        var pageResults: [OCRPageResult] = []
        var sourcePDF: PDFDocument?

        if ext == "pdf" {
            guard let pdf = PDFDocument(url: url) else { throw AppError("無法讀取 PDF 進行 OCR") }
            sourcePDF = pdf
            for i in 0..<pdf.pageCount {
                guard let page = pdf.page(at: i) else { continue }
                let rendered = renderPage(page, scale: 1)
                pageResults.append(try recognize(in: rendered, languages: languages))
            }
        } else {
            guard let img = UIImage(contentsOfFile: url.path) else { throw AppError("無法讀取影像進行 OCR") }
            pageResults.append(try recognize(in: img, languages: languages))
        }

        let fullText = pageResults.map(\.text).joined(separator: "\n\n")
        let txtURL = url.deletingPathExtension().appendingPathExtension("txt")
        try fullText.write(to: txtURL, atomically: true, encoding: .utf8)

        var layer = false
        if let pdf = sourcePDF, pdf.pageCount > 0 {
            let tmp = url.deletingLastPathComponent()
                .appendingPathComponent("ocr_\(UUID().uuidString.prefix(8)).pdf")
            try makeSearchablePDF(from: pdf, results: pageResults, to: tmp)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: tmp, to: url)
            layer = true
        }
        NSLog("[AirScan] OCR: \(url.lastPathComponent) → \(fullText.count) chars, layer=\(layer)")
        return OCRDocumentResult(textFileURL: txtURL, fullText: fullText, textLayerWritten: layer)
    }

    // MARK: Searchable PDF（backlog 階段二）

    /// 逐頁 drawPDFPage 保留原掃描影像，再以 rendering mode .invisible 疊文字層。
    /// 文字層座標：Vision 正規化 bbox（左下原點）× PDF 頁面尺寸（PDF 原點同為左下）。
    static func makeSearchablePDF(from pdf: PDFDocument, results: [OCRPageResult], to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        // mediaBox 必須在 context 建立時給定（nil 會落到 Letter 612×792，
        // 導致原稿被裁切與文字層座標錯位）。掃描 PDF 頁面尺寸一致，取首頁即可。
        var mediaBox = pdf.page(at: 0)?.bounds(for: .mediaBox)
            ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw AppError("無法建立 searchable PDF context")
        }
        for (i, result) in results.enumerated() {
            guard let page = pdf.page(at: i), let pageRef = page.pageRef else { continue }
            let bounds = page.bounds(for: .mediaBox)
            ctx.beginPDFPage([kCGPDFContextMediaBox: NSValue(cgRect: bounds)] as CFDictionary)
            ctx.drawPDFPage(pageRef)
            for run in result.runs {
                let rect = CGRect(
                    x: run.boundingBox.minX * bounds.width,
                    y: run.boundingBox.minY * bounds.height,
                    width: run.boundingBox.width * bounds.width,
                    height: run.boundingBox.height * bounds.height
                )
                drawInvisibleText(run.text, in: rect, on: ctx)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    /// 以 CoreText 在 rect 內繪製不可見文字（字高貼合 bbox，過寬時等比縮小）。
    private static func drawInvisibleText(_ text: String, in rect: CGRect, on ctx: CGContext) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, rect.width > 1, rect.height > 1 else { return }

        var fontSize = rect.height * 0.9
        var attr = NSAttributedString(string: trimmed, attributes: [
            .font: CTFontCreateWithName("PingFang TC" as CFString, fontSize, nil)
        ])
        var line = CTLineCreateWithAttributedString(attr)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        if width > rect.width, width > 0 {
            fontSize *= rect.width / width
            attr = NSAttributedString(string: trimmed, attributes: [
                .font: CTFontCreateWithName("PingFang TC" as CFString, fontSize, nil)
            ])
            line = CTLineCreateWithAttributedString(attr)
        }
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        ctx.textPosition = CGPoint(x: rect.minX, y: rect.minY + (rect.height - fontSize * 0.75) / 2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: 影像處理輔助

    /// 長邊取樣至 maxLongEdge（比照 Android 4096px 限制）
    static func downsampled(_ image: UIImage, maxLongEdge: CGFloat = OCRService.maxLongEdge) -> UIImage {
        let longEdge = max(image.size.width, image.size.height)
        guard longEdge > maxLongEdge, longEdge > 0 else { return image }
        let ratio = maxLongEdge / longEdge
        let newSize = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// 把 PDF 頁面渲染成 UIImage（scale 1：本地掃描 PDF 的頁面尺寸即原始像素）。
    /// 用 PDFPage.thumbnail 保證方向正確（手動翻轉矩陣在部分頁面會畫反 → OCR 變亂碼）。
    static func renderPage(_ page: PDFPage, scale: CGFloat = 1) -> UIImage {
        let bounds = page.bounds(for: .mediaBox)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        return page.thumbnail(of: size, for: .mediaBox)
    }
}
