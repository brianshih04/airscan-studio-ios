import XCTest
import PDFKit
@testable import AirScanStudio

/// OCR / Searchable PDF 單元測試（backlog 階段一/二）
final class OCRServiceTests: XCTestCase {

    /// 產生一張含明確文字的測試影像（黑字白底，夠大讓 accurate 模式辨識）
    private func textImage(_ lines: [String], width: CGFloat = 1240, height: CGFloat = 1754) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 48, weight: .semibold),
                .foregroundColor: UIColor.black
            ]
            for (i, line) in lines.enumerated() {
                (line as NSString).draw(
                    at: CGPoint(x: 80, y: 120 + CGFloat(i) * 140),
                    withAttributes: attrs
                )
            }
        }
    }

    @MainActor
    func testOcrToggleDefaultsOffAndPersists() {
        let vm = ScanViewModel()
        XCTAssertFalse(vm.ocrEnabled, "OCR 預設應為關（比照 Android）")
        vm.ocrEnabled = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "ocrEnabled"))
        vm.ocrEnabled = false
    }

    func testRecognizeEnglishText() throws {
        let img = textImage(["HELLO OCR", "AirScan Studio"])
        let result = try OCRService.recognize(in: img)
        let joined = result.text.uppercased()
        XCTAssertTrue(joined.contains("HELLO"), "應辨識出 HELLO，got: \(result.text)")
        XCTAssertTrue(joined.contains("AIRSCAN"), "應辨識出 AirScan，got: \(result.text)")
        for run in result.runs {
            XCTAssertFalse(run.boundingBox.isNull)
            XCTAssertTrue(run.boundingBox.width > 0 && run.boundingBox.height > 0)
            // 正規化座標應在 0–1
            XCTAssertLessThanOrEqual(run.boundingBox.maxX, 1.001)
            XCTAssertLessThanOrEqual(run.boundingBox.maxY, 1.001)
        }
    }

    func testRecognizeChineseText() throws {
        let img = textImage(["掃描文件測試"], width: 1240, height: 400)
        let result = try OCRService.recognize(in: img)
        XCTAssertTrue(result.text.contains("掃描") || result.text.contains("文件") || result.text.contains("測試"),
                      "應辨識出中文，got: \(result.text)")
    }

    func testProcessDocumentJPEGWritesTxt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.jpg")
        try textImage(["Invoice 2026", "Total 199"].map { $0 }).jpegData(compressionQuality: 0.9)!.write(to: url)

        let result = try OCRService.processDocument(at: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.textFileURL.path), "應寫出 .txt")
        let saved = try String(contentsOf: result.textFileURL, encoding: .utf8)
        XCTAssertTrue(saved.uppercased().contains("INVOICE"), ".txt 內容應含辨識文字")
        XCTAssertFalse(result.textLayerWritten, "JPEG 無文字層")
    }

    func testSearchablePDFPreservesPagesAndAddsTextLayer() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.pdf")

        // 兩頁 PDF（用 MockScanGenerator 產頁，模擬真實掃描輸出）
        var s = ScanSettings()
        s.source = .adf
        try MockScanGenerator.generatePDF(settings: s, pageCount: 2, to: url)

        let before = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(before.pageCount, 2)

        let result = try OCRService.processDocument(at: url)
        XCTAssertTrue(result.textLayerWritten, "PDF 應重寫並標記 textLayerWritten")

        let after = try XCTUnwrap(PDFDocument(url: url), "重寫後的 PDF 應可開啟")
        XCTAssertEqual(after.pageCount, 2, "頁數應保留")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.textFileURL.path))

        // 文字層驗收（backlog：PDF 內可搜尋/複製）：
        // Mock 頁尾含 "MOCK SCAN · page 1/2" 可辨識文字，搜尋應命中
        let pageText = after.page(at: 0)?.string ?? ""
        let searchable = pageText.contains("MOCK") || pageText.contains("page")
        XCTAssertTrue(searchable, "PDF 應含可搜尋文字層，got: \(pageText.prefix(200))")
    }

    func testSearchablePDFKeepsPageSize() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.pdf")
        try MockScanGenerator.generatePDF(settings: ScanSettings(), pageCount: 1, to: url)

        let before = try XCTUnwrap(PDFDocument(url: url))!
            .page(at: 0)!.bounds(for: .mediaBox)
        _ = try OCRService.processDocument(at: url)
        let after = try XCTUnwrap(PDFDocument(url: url))!
            .page(at: 0)!.bounds(for: .mediaBox)
        XCTAssertEqual(before.width, after.width, accuracy: 0.5, "頁面尺寸應保留")
        XCTAssertEqual(before.height, after.height, accuracy: 0.5, "頁面尺寸應保留")
    }

    func testNoTextDocumentReportsEmpty() throws {
        // 純色影像 → 應成功完成但文字為空（UI 顯示「未偵測到文字」）
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600))
        let blank = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("blank.jpg")
        try blank.jpegData(compressionQuality: 0.9)!.write(to: url)

        let result = try OCRService.processDocument(at: url)
        XCTAssertTrue(result.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "空白頁應無文字，got: \(result.fullText)")
    }

    func testOCRTextStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("scan_abc.jpg")
        try "測試文字".data(using: .utf8)!.write(to: url.deletingPathExtension().appendingPathExtension("txt"))
        try Data().write(to: url)
        let doc = ScannedDocument(name: "t", fileURL: url, pageCount: 1, settings: ScanSettings())
        XCTAssertEqual(OCRTextStore.load(for: doc), "測試文字")
    }
}
