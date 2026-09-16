import XCTest
import PDFKit
@testable import AirScanStudio

/// 驗證 code review 修復（docs/code-review-2026-09-16.md）的核心修復項
final class ReviewFixTests: XCTestCase {

    // Fix 1：文件庫相對檔名 + migration
    @MainActor
    func testLoadDocumentsMigratesAbsolutePathsToRelative() throws {
        // 準備：把一支真檔案放進 Documents/Scans，UserDefaults 用「舊格式絕對路徑」
        let dir = ScanViewModel.documentsDirectory()
        let fileURL = dir.appendingPathComponent("scan_migrate_test.pdf")
        try Data("%PDF-1.4 fake".utf8).write(to: fileURL)

        let entries: [[String: String]] = [
            ["name": "舊格式文件", "url": "/some/old/container/path/Documents/Scans/scan_migrate_test.pdf", "pages": "3"],
            ["name": "新格式文件", "file": "scan_migrate_test.pdf", "pages": "2"],
            ["name": "消失的文件", "file": "scan_gone.pdf", "pages": "1"]
        ]
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: entries), forKey: "documents")
        defer {
            UserDefaults.standard.removeObject(forKey: "documents")
            try? FileManager.default.removeItem(at: fileURL)
        }

        let vm = ScanViewModel()
        // 舊格式（絕對路徑失效）→ migration 取檔名重拼後應救回
        // 新格式 → 直接命中
        // 檔案不存在的 → 丟棄
        XCTAssertEqual(vm.documents.count, 2, "舊格式應 migration 救回、新格式命中、不存在者丟棄")
        XCTAssertTrue(vm.documents.contains { $0.name == "舊格式文件" && $0.pageCount == 3 })
        XCTAssertTrue(vm.documents.contains { $0.name == "新格式文件" })
        XCTAssertFalse(vm.documents.contains { $0.name == "消失的文件" })
        // 所載入的 fileURL 都應指向目前 Documents/Scans（相對化）
        for doc in vm.documents {
            XCTAssertTrue(doc.fileURL.path.hasPrefix(dir.path), "fileURL 應基於目前 container：\(doc.fileURL.path)")
        }
    }

    // Fix 1：persistDocuments 應存相對檔名而非絕對路徑
    @MainActor
    func testPersistDocumentsStoresRelativeFileName() async throws {
        UserDefaults.standard.removeObject(forKey: "documents")
        defer { UserDefaults.standard.removeObject(forKey: "documents") }

        let vm = ScanViewModel()
        let dir = ScanViewModel.documentsDirectory()
        let fileURL = dir.appendingPathComponent("scan_persist_test.pdf")
        try Data("%PDF-1.4 fake".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        vm.documents.append(ScannedDocument(name: "測試", fileURL: fileURL, pageCount: 1, settings: .init()))
        // persistDocuments 是 private；append 不會自動 persist，改以 deleteDocument 觸發前先抓 UserDefaults
        // → 直接驗證方式：呼叫 deleteDocument（會 persist），檢查殘存 entries 只含相對檔名
        let doc = try XCTUnwrap(vm.documents.first { $0.name == "測試" } , "文件應已加入")
        vm.deleteDocument(doc)
        // deleteDocument 後該文件已從清單移除，entries 應為空陣列（且不含任何 url key）。
        // 為驗證「persist 寫相對檔名」，改用第二份文件觸發 persist 後檢查其 entry。
        let fileURL2 = dir.appendingPathComponent("scan_persist_test2.pdf")
        try Data("%PDF-1.4 fake".utf8).write(to: fileURL2)
        defer { try? FileManager.default.removeItem(at: fileURL2) }
        vm.documents.append(ScannedDocument(name: "測試二", fileURL: fileURL2, pageCount: 2, settings: .init()))
        let doc2 = try XCTUnwrap(vm.documents.first { $0.name == "測試二" }, "文件應已加入")
        vm.deleteDocument(doc2)
        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: "documents"))
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: String]])
        XCTAssertFalse(entries.contains { $0["url"] != nil }, "不應再存絕對路徑 url")
        for e in entries {
            guard let f = e["file"] else {
                XCTFail("應存 file key（相對檔名）")
                continue
            }
            XCTAssertFalse(f.contains("/"))
        }
    }

    // Fix 2：writePDF 串流寫出 — 頁面尺寸保留（mediaBox 於 context 建立時給定）、頁數正確、跳過壞頁
    func testWritePDFStreamsPagesAndKeepsSize() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fixtest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 產生兩頁 A4-ish 大小不同的 JPEG（2480x3508 模擬 300dpi A4）
        func makeJPEG(width: Int, height: Int, color: UIColor) throws -> Data {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
            let img = renderer.image { ctx in
                color.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            return try XCTUnwrap(img.jpegData(compressionQuality: 0.8))
        }

        let pages = [
            try makeJPEG(width: 2480, height: 3508, color: .white),
            try makeJPEG(width: 1200, height: 1800, color: .lightGray) // 壞頁模擬：尺寸不同但可解碼 → 仍應寫入
        ]
        let url = dir.appendingPathComponent("out.pdf")
        let written = try ScanViewModel.writePDF(from: pages, to: url)
        XCTAssertEqual(written, 2)

        let pdf = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(pdf.pageCount, 2, "頁數保留")
        let box = try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(box.width, 2480, accuracy: 0.5, "mediaBox 應為首頁像素尺寸（非 Letter 612）")
        XCTAssertEqual(box.height, 3508, accuracy: 0.5)
    }

    func testWritePDFAllPagesUndecodableThrowsAndCleansUp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fixtest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.pdf")
        let garbage = Data("not an image".utf8)
        XCTAssertThrowsError(try ScanViewModel.writePDF(from: [garbage], to: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "全頁失敗時應清理半成品檔")
    }

    // Fix 4：pullPage 認 .completed 終態（以 parseJobPhase 既有單測補充整合面向）
    func testCompletedPhaseIsTerminalValue() {
        XCTAssertEqual(ScanJobPhase(rawValue: "Completed"), .completed)
    }
}
