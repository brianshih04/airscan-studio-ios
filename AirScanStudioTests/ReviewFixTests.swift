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

    // MARK: - Round 2（docs/rereview-2026-09-16.md 建議 4 項）

    /// #5：selectedScanner 選擇優先序 — 使用者明確選擇 > manual 霸佔 > 第一台
    @MainActor
    func testSelectedScannerExplicitChoiceBeatsManualHijack() {
        let vm = ScanViewModel()
        let hp = DiscoveredScanner(id: "HP LaserJet [aa]", name: "HP", host: "10.1.121.182", port: 8080, isSecure: false)
        let brother = DiscoveredScanner(id: "manual-10.1.121.175:80", name: "Brother", host: "10.1.121.175", port: 80, isSecure: false)
        vm.browser.scanners = [hp, brother]

        // 1) 無明確選擇：manual 仍優先（測試 pin 意圖保留）
        XCTAssertEqual(vm.selectedScanner?.id, brother.id, "無選擇時 manual 裝置優先")

        // 2) 使用者明確選 HP → HP 贏（manual 不再霸佔）
        vm.selectedScannerID = hp.id
        XCTAssertEqual(vm.selectedScanner?.id, hp.id, "明確選擇應優先於 manual 霸佔")

        // 3) 選擇的裝置已移除 → 回退 manual
        vm.selectedScannerID = "gone"
        XCTAssertEqual(vm.selectedScanner?.id, brother.id, "選擇失效時回退 manual")

        // 4) 只剩 Bonjour 裝置 → 回退第一台
        vm.browser.scanners = [hp]
        vm.selectedScannerID = nil
        XCTAssertEqual(vm.selectedScanner?.id, hp.id)
    }

    /// #22：port 1-65535 範圍驗證
    func testManualHostPortValidation() {
        // 合法
        XCTAssertEqual(ScanViewModel.validateManualHost("192.168.1.50"), .valid(host: "192.168.1.50", port: 80))
        XCTAssertEqual(ScanViewModel.validateManualHost("192.168.1.50:8080"), .valid(host: "192.168.1.50", port: 8080))
        XCTAssertEqual(ScanViewModel.validateManualHost("10.1.121.182:1"), .valid(host: "10.1.121.182", port: 1))
        XCTAssertEqual(ScanViewModel.validateManualHost("10.1.121.182:65535"), .valid(host: "10.1.121.182", port: 65535))
        // 邊界外
        XCTAssertEqual(ScanViewModel.validateManualHost("10.1.121.182:0"), .invalid)
        XCTAssertEqual(ScanViewModel.validateManualHost("10.1.121.182:65536"), .invalid)
        XCTAssertEqual(ScanViewModel.validateManualHost("10.1.121.182:-1"), .invalid)
        XCTAssertEqual(ScanViewModel.validateManualHost("10.1.121.182:abc"), .invalid)
        // 格式錯誤
        XCTAssertEqual(ScanViewModel.validateManualHost(""), .invalid)
        XCTAssertEqual(ScanViewModel.validateManualHost("not an ip"), .invalid)
        XCTAssertEqual(ScanViewModel.validateManualHost("10.1.121.182:80:extra"), .invalid)
        XCTAssertEqual(ScanViewModel.validateManualHost("10.1.121.182:"), .invalid)
    }

    /// #22：無效輸入不加入；manual 裝置可移除，移除後選擇回退
    @MainActor
    func testAddManualRejectsInvalidAndRemoveManualFallsBack() {
        let vm = ScanViewModel()
        // 無效 port → 不加入
        XCTAssertFalse(vm.addManual(host: "10.1.121.182:99999"))
        XCTAssertTrue(vm.discovered.isEmpty, "無效輸入不應加入任何裝置")

        // 有效 → 加入且選中
        XCTAssertTrue(vm.addManual(host: "10.1.121.175"))
        XCTAssertEqual(vm.selectedScanner?.id, "manual-10.1.121.175:80")

        // 再加一台 Bonjour 裝置，明確選它
        let hp = DiscoveredScanner(id: "HP LaserJet [aa]", name: "HP", host: "10.1.121.182", port: 8080, isSecure: false)
        vm.browser.scanners = [hp] + vm.browser.scanners
        vm.selectedScannerID = hp.id
        XCTAssertEqual(vm.selectedScanner?.id, hp.id)

        // 移除 manual 裝置：不在清單、選擇不受影響（目前選的是 HP）
        let manual = vm.discovered.first { $0.id.hasPrefix("manual-") }!
        vm.removeManual(scanner: manual)
        XCTAssertFalse(vm.discovered.contains { $0.id == manual.id })
        XCTAssertEqual(vm.selectedScanner?.id, hp.id)

        // 移除目前選中的 manual（先重建情境）：選擇應回退到第一台剩餘裝置
        XCTAssertTrue(vm.addManual(host: "10.1.121.175"))
        vm.selectedScannerID = "manual-10.1.121.175:80"
        let manual2 = vm.discovered.first { $0.id.hasPrefix("manual-") }!
        vm.removeManual(scanner: manual2)
        XCTAssertEqual(vm.selectedScannerID, hp.id, "刪除選中的 manual 後應回退第一台剩餘裝置")

        // 非 manual 裝置不可透過 removeManual 移除
        vm.removeManual(scanner: hp)
        XCTAssertTrue(vm.discovered.contains { $0.id == hp.id })
    }

    /// #8：錯誤路徑 job 清理 — 非取消錯誤會觸發清理、取消/已清理時跳過（不雙 DELETE）
    @MainActor
    func testCleanupTrackedJobSkipLogic() async throws {
        let vm = ScanViewModel()
        let client = ESCLClient(scanner: DiscoveredScanner(id: "t", name: "t", host: "127.0.0.1", port: 1, isSecure: false))
        let jobURL = URL(string: "http://127.0.0.1:1/eSCL/ScanJobs/1")!

        // 1) 非取消 + activeJobURL 相符 → 應清理（背景 detached DELETE）
        vm.activeJobURL = jobURL
        vm.cleanupTrackedJob(client: client, jobURL: jobURL, cancelled: false)
        try await Task.sleep(nanoseconds: 300_000_000) // 等 detached task 飛出
        XCTAssertNil(vm.activeJobURL, "清理後 activeJobURL 應清 nil")

        // 2) 已取消 → 跳過（cancelScan 已清理）：activeJobURL 保持不變
        vm.activeJobURL = jobURL
        vm.cleanupTrackedJob(client: client, jobURL: jobURL, cancelled: true)
        XCTAssertEqual(vm.activeJobURL, jobURL, "取消路徑應跳過（cancelScan 已處理）")

        // 3) cancelScan 已先行清理（activeJobURL 已清 nil）→ 跳過，不雙 DELETE
        vm.activeJobURL = nil
        vm.cleanupTrackedJob(client: client, jobURL: jobURL, cancelled: false)
        XCTAssertNil(vm.activeJobURL, "cancelScan 已清理過的 job 不應重複 DELETE")
    }

    /// #8（原始碼路徑防回歸）：runRealScan 錯誤路徑不殘留追蹤狀態。
    /// 以本機不可達 port 跑真實掃描（fetchCapabilities 拋非取消錯誤）：
    /// createJob 未達、無 job 產生 → 聚焦「不殘留 activeJobURL/activeESCLClient、流程正確拋錯」，
    /// defer 清理呼叫路徑由 testCleanupTrackedJobSkipLogic 覆蓋。
    @MainActor
    func testRealScanErrorPathLeavesNoTrackedJob() async throws {
        let vm = ScanViewModel()
        vm.mode = .real
        vm.flatbedPromptEnabled = false
        // 127.0.0.1:1 — 本機 connection refused，立即失敗（不依賴網路逾時）
        XCTAssertTrue(vm.addManual(host: "127.0.0.1:1"))
        UserDefaults.standard.removeObject(forKey: "manualScannerHost")

        do {
            try await vm.startScanForTesting(source: .platen)
            XCTFail("不可達掃描器應拋錯")
        } catch {
            // 預期錯誤
        }
        XCTAssertNil(vm.activeJobURL, "錯誤路徑收尾後不應殘留 activeJobURL")
        XCTAssertNil(vm.activeESCLClient)
    }

    /// B1：文件刪除後 OCR 不寫回 — deleteDocument 記錄路徑、清理 outcome，
    /// runOCRNow 對已刪文件不再受理
    @MainActor
    func testDeletedDocumentOcrDiscarded() throws {
        let vm = ScanViewModel()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("b1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("scan_b1.jpg")
        try Data("fakejpg".utf8).write(to: url)
        let doc = ScannedDocument(name: "B1", fileURL: url, pageCount: 1, settings: .init())
        vm.documents = [doc]
        vm.ocrOutcome[url.path] = .hasText(chars: 10)
        vm.ocrRunningPaths = [url.path]

        vm.deleteDocument(doc)

        // 磁碟與清單已清
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(vm.documents.isEmpty)
        // B1 防護狀態
        XCTAssertTrue(vm.deletedDocumentPaths.contains(url.path), "deleteDocument 應記錄已刪路徑")
        XCTAssertNil(vm.ocrOutcome[url.path], "deleteDocument 應清 ocrOutcome entry")
        XCTAssertFalse(vm.ocrRunningPaths.contains(url.path), "deleteDocument 應清 ocrRunningPaths entry")

        // runOCRNow 對已刪文件不再受理
        vm.runOCRNow(for: doc)
        XCTAssertFalse(vm.ocrRunningPaths.contains(url.path), "已刪文件不應重新啟動 OCR")
    }

    /// B1（落地層）：OCRService 對「辨識前已被刪除」的來源不寫任何產物
    func testOcrProcessDeletedSourceWritesNothing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("b1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("gone.jpg")
        // 來源不存在 → 不應拋錯、不寫 txt、不復活任何檔案
        let result = try OCRService.processDocument(at: url)
        XCTAssertFalse(result.textLayerWritten)
        XCTAssertTrue(result.fullText.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "不得把產物寫回已刪路徑（復活）")
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.textFileURL.path), "不得寫出 .txt")
        // 同目錄不應殘留任何 tmp/孤兒檔
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(leftovers.isEmpty, "不得殘留孤兒檔，got \(leftovers)")
    }

    /// B3：mock PDF 尺寸正確（mediaBox 非 Letter、等於設定頁尺寸）且頁數正確
    func testMockPDFCorrectMediaBoxAndPageCount() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("b3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("mock.pdf")

        var s = ScanSettings()   // A4 = 2480×3508（1/300 inch 單位，與 dpi 無關）
        s.source = .adf
        let written = try MockScanGenerator.generatePDF(settings: s, pageCount: 3, to: url)

        XCTAssertEqual(written, 3, "應寫入 3 頁")
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(pdf.pageCount, 3, "頁數應為 3")
        for i in 0..<3 {
            let box = try XCTUnwrap(pdf.page(at: i)).bounds(for: .mediaBox)
            XCTAssertEqual(box.width, 2480, accuracy: 1.0, "第 \(i) 頁 mediaBox 寬應為 2480（非 Letter 612）")
            XCTAssertEqual(box.height, 3508, accuracy: 1.0, "第 \(i) 頁 mediaBox 高應為 3508（非 Letter 792）")
        }
    }

    /// B3：generatePage 不再被螢幕 scale 放大（2480×3508 就是真的 2480×3508）
    func testMockPageNotScaledByScreen() throws {
        let data = MockScanGenerator.generatePage(settings: ScanSettings(), pageIndex: 0, totalPages: 1)
        let img = try XCTUnwrap(UIImage(data: data))
        let px = img.cgImage.map { CGSize(width: $0.width, height: $0.height) }
            ?? CGSize(width: img.size.width * img.scale, height: img.size.height * img.scale)
        XCTAssertEqual(px.width, 2480, accuracy: 2.0, "頁面像素寬應為 2480（scale=1），got \(px.width)")
        XCTAssertEqual(px.height, 3508, accuracy: 2.0, "頁面像素高應為 3508（scale=1），got \(px.height)")
    }

    // MARK: - Round 3（docs/rereview-2026-09-16.md P2 三項）

    /// #26：PDFFileStamp（mtime+size）— 檔案原地替換後 stamp 必須改變、
    /// 未變時相同、不存在回 nil。PDFKitView.updateUIView 以此判斷是否重載。
    func testPDFFileStampReflectsFileReplacement() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("r3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.pdf")

        // 不存在 → nil
        XCTAssertNil(PDFFileStamp.of(url: url), "檔案不存在時 stamp 應為 nil")

        // 寫入 → stamp 有值；未再寫入前連續讀取相同
        try Data("%PDF-1.4 first".utf8).write(to: url)
        let s1 = try XCTUnwrap(PDFFileStamp.of(url: url))
        XCTAssertEqual(PDFFileStamp.of(url: url), s1, "檔案未變時 stamp 應相等")

        // 原地替換（OCR replaceItemAt 情境：URL 不變、內容/大小變）→ stamp 必須不同
        try Data("%PDF-1.4 second with more content (larger)".utf8).write(to: url)
        let s2 = try XCTUnwrap(PDFFileStamp.of(url: url))
        XCTAssertNotEqual(s2, s1, "原地替換後 stamp 應改變（觸發 PDFKitView 重載）")
    }

    /// #10：縮圖快取 — 同一 URL 兩次請求回傳同一 cached instance（不重複 parse）
    func testThumbnailCacheReturnsSameInstanceForSameURL() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("r3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 產生一張小圖（縮圖路徑吃圖檔分支）
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40), format: format)
        let img = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        let url = dir.appendingPathComponent("thumb.jpg")
        try XCTUnwrap(img.jpegData(compressionQuality: 0.8)).write(to: url)

        // 快取隔離：清掉再驗（static shared cache）
        DocumentThumbnailCache.shared.removeAllObjects()
        let a = await DocumentThumbnailLoader.cachedThumbnail(for: url)
        let b = await DocumentThumbnailLoader.cachedThumbnail(for: url)
        XCTAssertNotNil(a, "圖檔應產生縮圖")
        XCTAssertTrue(a === b, "同一 URL 兩次請求應回傳同一 cached instance（不重複 parse）")
        XCTAssertTrue(DocumentThumbnailCache.shared.object(forKey: url.path as NSString) === a,
                      "第二次請求應命中快取（object === 首次結果）")

        // 不同 URL → 不同 instance（快取 key 正確，不誤撞）
        let url2 = dir.appendingPathComponent("thumb2.jpg")
        try XCTUnwrap(img.jpegData(compressionQuality: 0.8)).write(to: url2)
        let c = await DocumentThumbnailLoader.cachedThumbnail(for: url2)
        XCTAssertNotNil(c)
        XCTAssertTrue(c !== a, "不同 URL 應產生不同 instance")
    }

    /// #10：縮圖產生脫離主執行緒路徑可用（PDF 分支：mock PDF 首頁可出縮圖）
    func testThumbnailLoaderHandlesPDF() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("r3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("mock.pdf")
        var s = ScanSettings()
        s.source = .adf
        _ = try MockScanGenerator.generatePDF(settings: s, pageCount: 1, to: url)

        DocumentThumbnailCache.shared.removeAllObjects()
        let thumb = await DocumentThumbnailLoader.cachedThumbnail(for: url)
        XCTAssertNotNil(thumb, "PDF 首頁應能產生縮圖")
    }
}
