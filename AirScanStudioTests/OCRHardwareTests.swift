import XCTest
import PDFKit
@testable import AirScanStudio

/// 實機 OCR 整合測試：ADF 掃描（真實紙張文件）→ OCR → searchable PDF 驗證。
/// 需求：指定主機可達 + ADF 有紙。OCR 文字層驗收以「txt 非空」為前提（紙張內容未知）。
final class OCRHardwareTests: XCTestCase {

    private func runADFScanAndVerifyOCR(host: String, device: String) async throws {
        let vm = await ScanViewModel()
        await MainActor.run {
            vm.mode = .real
            vm.ocrEnabled = true
            vm.settings.source = .adf
            vm.settings.paperSize = .a4   // 明確 A4：避免殘留設定（如 5x7）影響 ADF 進紙行為
            vm.adfPageLimit = 2           // 必須 == ADF 實際放紙張數；job 結束會整疊退紙
            vm.addManual(host: host)
        }
        try await vm.startScanForTesting(source: .adf)

        let docs = await vm.documents
        let newest = try XCTUnwrap(docs.first, "\(device): 掃描後應有文件")
        let url = await newest.fileURL
        let pages = await newest.pageCount
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(device): 檔案應存在")
        XCTAssertGreaterThanOrEqual(pages, 1, "\(device): ADF 至少 1 頁")
        // 單頁（ADF 進紙不足/逾時 fallback）存 .jpg；多頁存 PDF
        if pages > 1 {
            XCTAssertEqual(url.pathExtension.lowercased(), "pdf", "\(device): 多頁應產出 PDF")
        }

        // 等 OCR 完成（背景 Task；ADF 多頁 accurate 模式可能要 1-2 分鐘）
        let deadline = Date().addingTimeInterval(240)
        var empty = false
        while Date() < deadline {
            empty = await MainActor.run { vm.ocrRunningPaths.isEmpty }
            if empty { break }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        XCTAssertTrue(empty, "\(device): OCR 應在 240 秒內完成")

        let outcome = await MainActor.run { vm.ocrOutcome[url.path] }
        print("HWOCR \(device) outcome: \(String(describing: outcome))")

        // .txt sidecar
        let txtURL = url.deletingPathExtension().appendingPathExtension("txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: txtURL.path), "\(device): 應寫出 .txt")
        let text = try String(contentsOf: txtURL, encoding: .utf8)
        print("HWOCR \(device) txt chars: \(text.count)")
        print("HWOCR \(device) txt sample: \(text.prefix(180).replacingOccurrences(of: "\n", with: " / "))")

        // searchable PDF 驗收（單頁 .jpg 無 PDF 可驗，僅多頁時驗文字層）
        guard isPDF(url) else {
            print("HWOCR \(device): single-page jpg — searchable-PDF checks skipped")
            print("HWOCR \(device): FILE=\(url.path)")
            return
        }
        let pdf = try XCTUnwrap(PDFDocument(url: url), "\(device): OCR 後 PDF 應可開啟")
        XCTAssertEqual(pdf.pageCount, pages, "\(device): OCR 不得改變頁數")
        let pageText = pdf.page(at: 0)?.string ?? ""
        print("HWOCR \(device) pdf searchable chars p0: \(pageText.count)")
        print("HWOCR \(device) pdf sample p0: \(pageText.prefix(180).replacingOccurrences(of: "\n", with: " / "))")

        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            XCTAssertGreaterThan(pageText.count, 0, "\(device): 紙張有文字時 PDF 應含可搜尋文字層")
        } else {
            print("HWOCR \(device): OCR 無文字（紙張可能空白），僅驗證 PDF 完整性")
        }
        print("HWOCR \(device): FILE=\(url.path)")
    }

    private func isPDF(_ url: URL) -> Bool { url.pathExtension.lowercased() == "pdf" }

    func testBrotherADFWithOCR() async throws {
        try await runADFScanAndVerifyOCR(host: "10.1.121.175", device: "Brother")
    }

    func testHPADFWithOCR() async throws {
        try await runADFScanAndVerifyOCR(host: "10.1.121.182:8080", device: "HP")
    }
}
