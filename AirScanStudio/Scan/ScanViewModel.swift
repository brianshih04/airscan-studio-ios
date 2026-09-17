import Foundation
import SwiftUI
import PDFKit
import UIKit
import Combine

/// Central scan orchestration: Mock or Real (eSCL) behind one flow.
/// Mirrors Android ScanViewModel + DocumentRepository.
@MainActor
final class ScanViewModel: ObservableObject {
    enum Mode: String, CaseIterable {
        case mock, real
        var displayName: String { self == .mock ? "模擬模式" : "真實模式" }
    }

    enum Phase: Equatable {
        case idle
        case discovering
        case scanning(page: Int)
        case awaitingNextPage(page: Int)
        case saving
        case done
        case failed(String)
    }

    @Published var mode: Mode = .mock {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mode") }
    }
    @Published var settings = ScanSettings() {
        didSet { saveSettings() }
    }
    @Published var phase: Phase = .idle
    @Published var documents: [ScannedDocument] = []
    @Published var adfPageLimit = 5
    @Published var duplexEnabled = false
    /// Flatbed 逐頁模式上限
    static let maxFlatbedPages = 50
    /// Flatbed 逐頁模式：掃描完一頁後等待使用者選「下一頁」或「完成」
    @Published var awaitingNextPage = false
    /// 逐頁 prompt 開關（整合測試/自動化設 false：掃一頁直接完成）
    var flatbedPromptEnabled = true
    // MARK: OCR（backlog 階段一：開關 + 掃描後背景辨識）
    /// 文字辨識開關（預設關，比照 Android）。獨立 UserDefaults key，避免動到 ScanSettings 的 Codable。
    @Published var ocrEnabled: Bool = false {
        didSet { UserDefaults.standard.set(ocrEnabled, forKey: "ocrEnabled") }
    }
    /// OCR 語言多選（階段三）。固定順序輸出；空集合時回落預設。
    @Published var ocrLanguages: Set<String> = [] {
        didSet { UserDefaults.standard.set(Array(ocrLanguages), forKey: "ocrLanguages") }
    }
    /// 支援的 OCR 語言（VNRecognizeTextRequest accurate 支援）
    static let ocrLanguageOptions: [(code: String, name: String)] = [
        ("zh-Hant", "繁中"), ("zh-Hans", "簡中"), ("en-US", "英文"), ("ja-JP", "日文"), ("ko-KR", "韓文")
    ]
    /// 語言以固定順序輸出（zh-Hant 優先，對齊 Android 版行為）
    var ocrLanguageList: [String] {
        let selected = Self.ocrLanguageOptions.map(\.code).filter { ocrLanguages.contains($0) }
        return selected.isEmpty ? OCRService.defaultLanguages : selected
    }
    /// OCR 進行中的文件路徑（詳情頁顯示進度）
    @Published var ocrRunningPaths: Set<String> = []
    /// OCR 結果狀態（路徑 → outcome），session 內有效；文字本身落在磁碟 <文件>.txt
    enum OcrOutcome: Equatable { case hasText(chars: Int), noText, failed(String) }
    @Published var ocrOutcome: [String: OcrOutcome] = [:]
    /// 已刪除文件路徑（review B1）：OCR 背景任務完成回呼據此丟棄產物，
    /// 不把 PDF/txt 寫回已刪路徑（孤兒復活防護）
    var deletedDocumentPaths: Set<String> = []
    /// 目前逐頁累積的頁數（供 UI 顯示）
    @Published var flatbedPageCount = 0
    /// 進行中的掃描工作（供取消）
    private var scanTask: Task<Void, Never>?
    /// 真實掃描的底層工作（供 cancelScan 清理 eSCL job）。
    /// internal：單元測試驗證錯誤路徑 job 清理（review #8）需要觀察。
    var activeESCLClient: ESCLClient?
    var activeJobURL: URL?
    private var flatbedContinuation: CheckedContinuation<FlatbedChoice, Error>?
    var isScanning: Bool { scanTask != nil }

    /// Flatbed 逐頁模式的使用者選擇
    enum FlatbedChoice { case nextPage, finish }
    var discovered: [DiscoveredScanner] { browser.scanners }
    var isBrowsing: Bool { browser.isBrowsing }
    @Published var selectedScannerID: String?
    var selectedScanner: DiscoveredScanner? {
        // 使用者明確選擇（含手動加入）優先（review #5）：
        // 舊行為「manual- 一律霸佔」導致加入 manual 裝置後，Bonjour 探索到的裝置
        // 同 session 內永遠選不到（雙機工作流必踩）。
        if let id = selectedScannerID,
           let picked = discovered.first(where: { $0.id == id }) {
            return picked
        }
        // 無明確選擇：manual 裝置次之（明確測試意圖），最後退回第一台探索結果
        if let manual = discovered.first(where: { $0.id.hasPrefix("manual-") }) {
            return manual
        }
        return discovered.first
    }

    let browser = ScannerBrowser()
    private var cancellables = Set<AnyCancellable>()

    init() {
        if let saved = UserDefaults.standard.string(forKey: "mode"),
           let m = Mode(rawValue: saved) {
            mode = m
        }
        ocrEnabled = UserDefaults.standard.bool(forKey: "ocrEnabled")
        if let langs = UserDefaults.standard.array(forKey: "ocrLanguages") as? [String] {
            ocrLanguages = Set(langs)
        }
        loadSettings()
        loadDocuments()
        // Forward browser changes so DevicesView updates on discovery
        browser.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Discovery

    func startDiscovery() {
        guard mode == .real else { return }
        phase = .discovering
        browser.start()
        // Auto-register a manually pinned scanner (set via UserDefaults for test automation)
        if let pinned = UserDefaults.standard.string(forKey: "manualScannerHost"), !pinned.isEmpty {
            addManual(host: pinned)
        }
    }

    /// 手動輸入驗證結果：ip + 合法 port（1-65535，預設 80）
    enum ManualHostValidation: Equatable {
        case valid(host: String, port: Int)
        case invalid
    }

    /// 解析手動輸入的 "ip" / "ip:port"（review #22）：
    /// port 加入 1-65535 範圍檢查；不合法時 UI 顯示錯誤、不加入。
    /// nonisolated：純函式（字串解析），供任何執行緒/單元測試直接呼叫。
    nonisolated static func validateManualHost(_ input: String) -> ManualHostValidation {
        let parts = input.split(separator: ":", omittingEmptySubsequences: false)
        guard let first = parts.first, !first.isEmpty,
              first.allSatisfy({ $0.isNumber || $0 == "." }) else { return .invalid }
        let ip = String(first)
        if parts.count > 2 { return .invalid }
        if parts.count == 2 {
            guard let p = Int(parts[1]), (1...65_535).contains(p) else { return .invalid }
            return .valid(host: ip, port: p)
        }
        return .valid(host: ip, port: 80)
    }

    /// 手動加入掃描器。回傳是否成功（輸入無效時 false，不加入）。
    @discardableResult
    func addManual(host: String) -> Bool {
        guard case .valid(let ip, let port) = Self.validateManualHost(host) else { return false }
        browser.addManualScanner(host: ip, port: port)
        selectedScannerID = "manual-\(ip):\(port)"
        return true
    }

    /// 移除手動加入的裝置（review #22）：滑動刪除用。
    /// 若刪的是目前選擇，回退到第一台剩餘裝置。
    func removeManual(scanner: DiscoveredScanner) {
        guard scanner.id.hasPrefix("manual-") else { return }
        browser.removeScanner(id: scanner.id)
        if selectedScannerID == scanner.id {
            selectedScannerID = discovered.first?.id
        }
    }

    // MARK: - Scan

    /// 取消/重啟競態防護（review #3）：每次啟動掃描遞增 generation；
    /// 舊 Task 收尾時若 generation 已變，代表使用者已取消並重啟新掃描，
    /// 舊 Task 不得再寫 phase／scanTask（避免蓋掉新掃描狀態、雙掃描並行）。
    private var scanGeneration = 0

    /// UI 進入點：儲存 scanTask 以支援取消。
    func startScan() {
        guard scanTask == nil else { return } // 防止重複啟動
        scanGeneration += 1
        let generation = scanGeneration
        scanTask = Task { [weak self] in
            await self?.performScan(generation: generation)
            await MainActor.run { [weak self] in
                // 無條件清 nil 是安全的：startScan 以 scanTask == nil 為啟動前提，
                // 新 Task 只能在本 Task 收尾後建立，不會誤清新掃描
                self?.scanTask = nil
            }
        }
    }

    /// 取消目前掃描：讓 Task 收到 CancellationError，並清理 eSCL job。
    /// 只把 generation 標記為無效（防舊 Task 蓋狀態）；scanTask 由 Task 本身收尾清 nil。
    func cancelScan() {
        scanGeneration += 1
        scanTask?.cancel()
        phase = .idle
        // 逐頁等待中的 continuation 需 resume（拋 CancellationError），避免流程懸掛
        if let cont = flatbedContinuation {
            flatbedContinuation = nil
            awaitingNextPage = false
            cont.resume(throwing: CancellationError())
        }
        // 清理掃描器端工作（背景執行，不阻塞 UI）
        if let client = activeESCLClient, let jobURL = activeJobURL {
            Task.detached { await client.cleanupJob(jobURL) }
        }
        activeESCLClient = nil
        activeJobURL = nil
        NSLog("[AirScan] scan canceled by user")
    }

    private func performScan(generation: Int) async {
        do {
            switch mode {
            case .mock:
                try await runMockScan()
            case .real:
                try await runRealScan()
            }
        } catch is CancellationError {
            // 使用者取消：回到 idle，不顯示錯誤。只在仍是本次掃描時寫狀態
            if scanGeneration == generation { phase = .idle }
        } catch {
            if Task.isCancelled {
                if scanGeneration == generation { phase = .idle }
            } else if scanGeneration == generation {
                phase = .failed(error.localizedDescription)
            } else {
                NSLog("[AirScan] scan generation \(generation) superseded; dropping error")
            }
        }
    }

    private func runMockScan() async throws {
        let pages = settings.source == .adf ? adfPageLimit : 1
        for i in 0..<pages {
            try Task.checkCancellation()
            phase = .scanning(page: i)
            // Simulate scanner latency
            try await Task.sleep(nanoseconds: 700_000_000)
        }
        try Task.checkCancellation()
        phase = .saving
        let docsDir = Self.documentsDirectory()
        let id = UUID()
        let url = docsDir.appendingPathComponent("scan_\(id.uuidString.prefix(8)).pdf")
        do {
            try MockScanGenerator.generatePDF(settings: settings, pageCount: pages, to: url)
            let doc = ScannedDocument(
                name: "模擬掃描 \(Self.dateFormatter.string(from: Date()))",
                fileURL: url,
                pageCount: pages,
                settings: settings
            )
            documents.insert(doc, at: 0)
            persistDocuments()
            phase = .done
            runOCRAfterScan(doc)
        } catch {
            phase = .failed("儲存失敗: \(error.localizedDescription)")
        }
    }

    private func runRealScan() async throws {
        if selectedScanner == nil {
            // Auto-register pinned scanner + kick discovery before giving up
            let args = ProcessInfo.processInfo.arguments
            let pinned: String
            if let i = args.firstIndex(of: "-manualScannerHost"), i + 1 < args.count {
                pinned = args[i + 1]
            } else {
                pinned = UserDefaults.standard.string(forKey: "manualScannerHost") ?? ""
            }
            NSLog("[AirScan] runRealScan: no scanner selected; pinned='\(pinned)' discovered=\(browser.scanners.count)")
            if !pinned.isEmpty {
                addManual(host: pinned)
            }
            browser.start()
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }
        NSLog("[AirScan] runRealScan: will use \(selectedScanner.map { "\($0.host):\($0.port) secure=\($0.isSecure)" } ?? "nil")")
        guard let scanner = selectedScanner else {
            throw AppError("找不到掃描器，請先在「裝置」頁探索並選擇掃描器")
        }
        let client = ESCLClient(scanner: scanner)
        activeESCLClient = client
        defer { activeESCLClient = nil }
        phase = .scanning(page: 0)
        let caps = try await client.fetchCapabilities()
        // ADF 進階：送 scan:NumberOfPages（caps 支援時）與 scan:Duplex（caps.adfDuplex）
        let sendPageLimit = settings.source == .adf && caps.supportsAdf
        let sendDuplex = settings.source == .adf && caps.adfDuplex && duplexEnabled
        let jobURL = try await client.createJob(
            settings, namespace: caps.scanNamespace,
            numberOfPages: sendPageLimit ? adfPageLimit : nil,
            duplex: sendDuplex
        )
        // 錯誤路徑 job 清理（review #8）：createJob 成功後任何拋出（含取消）都會走到 defer，
        // 確保 job 不殘留掃描器端（HP 已知會因 Aborted job 堆積 wedge）。
        // 冪等設計：主路徑／flatbed 各頁清理後把 cleanedJobURL 歸 nil → defer 不重跑；
        // cancelScan 已先行清理（activeJobURL 清 nil）→ cleanupTrackedJob 跳過，不雙 DELETE；
        // 取消（CancellationError）同樣由 cancelScan 處理 → 跳過。
        var cleanedJobURL: URL?
        defer {
            if let leftover = cleanedJobURL {
                cleanedJobURL = nil
                cleanupTrackedJob(client: client, jobURL: leftover, cancelled: Task.isCancelled)
            }
        }
        func track(_ url: URL) -> URL {
            cleanedJobURL = url
            activeJobURL = url
            return url
        }
        track(jobURL)
        // Pull pages until the job ends or the ADF page limit is reached.
        // Brother serves NextDocument while Pending; HP serves after Completed.
        let maxPages = settings.source == .adf ? adfPageLimit : 1
        var pages: [Data] = []
        while pages.count < maxPages {
            try Task.checkCancellation()
            phase = .scanning(page: pages.count)
            if let data = try await client.pullPage(jobURL: jobURL) {
                pages.append(data)
                // If source is platen, one page only
                if settings.source == .platen { break }
            } else {
                break
            }
        }
        activeJobURL = nil
        cleanedJobURL = nil
        await client.cleanupJob(jobURL)
        try Task.checkCancellation()
        guard !pages.isEmpty else {
            throw AppError("掃描器未回傳影像（可能超時或沒有文件）")
        }

        // ---- Flatbed 逐頁模式：掃描一頁後詢問「下一頁」或「完成 PDF」 ----
        if settings.source == .platen {
            var allPages = pages
            while flatbedPromptEnabled && allPages.count < Self.maxFlatbedPages {
                let choice = try await promptFlatbedNextPage(pageNumber: allPages.count)
                if choice != .nextPage { break }
                // 掃下一頁：建立新 job
                try Task.checkCancellation()
                phase = .scanning(page: allPages.count)
                let nextJobURL = track(try await client.createJob(settings, namespace: caps.scanNamespace))
                guard let data = try await client.pullPage(jobURL: nextJobURL) else {
                    cleanedJobURL = nil
                    await client.cleanupJob(nextJobURL)
                    break // 掃描器未回傳影像：以已累積頁數完成
                }
                allPages.append(data)
                activeJobURL = nil
                cleanedJobURL = nil
                await client.cleanupJob(nextJobURL)
            }
            pages = allPages
        }

        phase = .saving
        let id = UUID()
        // PDF 組裝/寫檔移出 MainActor（review #9）：多頁 JPEG 解碼 + PDF 編碼 + 寫檔
        // 不再凍結 UI。回傳 (URL, 實際寫入頁數)：解碼失敗的頁不計，metadata 與 PDF 一致（review #12）。
        let pageData = pages
        let (url, writtenPages) = try await Task.detached(priority: .userInitiated) { () -> (URL, Int) in
            if pageData.count == 1 {
                let url = Self.documentsDirectory().appendingPathComponent("scan_\(id.uuidString.prefix(8)).jpg")
                try pageData[0].write(to: url)
                return (url, 1)
            }
            // 多頁（ADF 連掃或 Flatbed 逐頁累積）：逐頁 CGPDFContext 串流寫出（review #2）
            let url = Self.documentsDirectory().appendingPathComponent("scan_\(id.uuidString.prefix(8)).pdf")
            let written = try Self.writePDF(from: pageData, to: url)
            return (url, written)
        }.value
        flatbedPageCount = 0
        let doc = ScannedDocument(
            name: "掃描 \(Self.dateFormatter.string(from: Date()))",
            fileURL: url,
            pageCount: writtenPages,
            settings: settings
        )
        documents.insert(doc, at: 0)
        persistDocuments()
        phase = .done
        runOCRAfterScan(doc)
    }

    /// 逐頁把 JPEG page data 以 CGPDFContext 串流寫成 PDF：每頁解碼 → 寫入 → 釋放，
    /// 不再把全部頁面解碼圖同時駐留記憶體（50 頁 × 600dpi 解碼可達數 GB → jetsam）。
    /// 純靜態函式（不碰 actor 狀態），nonisolated 供背景 Task 呼叫。
    /// 注意：mediaBox 必須在 context 建立時給定（per-page kCGPDFContextMediaBox 不會覆蓋
    /// context 預設 Letter，見 OCRService.makeSearchablePDF 同坑），故先解碼首頁取尺寸。
    nonisolated static func writePDF(from pages: [Data], to url: URL) throws -> Int {
        var written = 0
        var ctx: CGContext?
        for data in pages {
            guard let img = UIImage(data: data), let cg = img.cgImage else { continue }
            if ctx == nil {
                // 首頁：以實際像素尺寸建立 context（掃描頁面尺寸一致）
                let box = CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height))
                var mediaBox = box
                ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil)
                guard ctx != nil else {
                    throw AppError("無法建立 PDF 輸出 context")
                }
            }
            let box = CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height))
            ctx!.beginPDFPage([kCGPDFContextMediaBox: NSValue(cgRect: box)] as CFDictionary)
            ctx!.draw(cg, in: box)
            ctx!.endPDFPage()
            written += 1
        }
        guard let ctx, written > 0 else {
            try? FileManager.default.removeItem(at: url)
            throw AppError("頁面影像解碼失敗，無法組成 PDF")
        }
        ctx.closePDF()
        return written
    }

    // MARK: - OCR（backlog 階段一/二）

    /// 錯誤路徑的 eSCL job 清理（review #8）：
    /// - Task 已取消（cancelScan 已做 detached cleanupJob）→ 跳過，不雙 DELETE
    /// - cancelScan 已先行清理（activeJobURL 清 nil）→ 跳過
    /// - 其餘（pullPage/createJob 拋非取消錯誤）→ 背景 DELETE，避免 job 殘留掃描器端
    /// internal 供單元測試 spy 驗證呼叫路徑
    func cleanupTrackedJob(client: ESCLClient, jobURL: URL, cancelled: Bool) {
        if cancelled {
            NSLog("[AirScan] defer cleanup skipped (cancelled; cancelScan already cleaned)")
            return
        }
        guard activeJobURL == jobURL else {
            NSLog("[AirScan] defer cleanup skipped (already cleaned)")
            return
        }
        activeJobURL = nil
        NSLog("[AirScan] error path: cleaning up leftover eSCL job")
        Task.detached { await client.cleanupJob(jobURL) }
    }

    /// 掃描完成後背景執行 OCR；寫 <文件>.txt，PDF 疊不可見文字層（原地替換）。
    private func runOCRAfterScan(_ doc: ScannedDocument) {
        guard ocrEnabled else { return }
        let path = doc.fileURL.path
        ocrRunningPaths.insert(path)
        let languages = ocrLanguageList
        Task.detached(priority: .utility) { [weak self] in
            do {
                let result = try OCRService.processDocument(at: doc.fileURL, languages: languages)
                await MainActor.run { [weak self] in
                    self?.ocrRunningPaths.remove(path)
                    // OCR 刪除復活防護（review B1）：文件在辨識期間被刪除 →
                    // 丟棄產物，不寫回已刪路徑（PDF 原地替換與 .txt 已由 OCRService 對
                    // 不存在來源改為 no-op，這裡不再記 outcome）
                    guard let self, !self.deletedDocumentPaths.contains(path),
                          self.documents.contains(where: { $0.fileURL.path == path }) else {
                        NSLog("[AirScan] OCR result discarded (document deleted during OCR)")
                        return
                    }
                    if result.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.ocrOutcome[path] = .noText
                    } else {
                        self.ocrOutcome[path] = .hasText(chars: result.fullText.count)
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.ocrRunningPaths.remove(path)
                    if let self, !self.deletedDocumentPaths.contains(path) {
                        self.ocrOutcome[path] = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    /// 文件詳情頁「重新辨識」：OCR 未自動跑過（開關沒開）或想重跑時使用。
    /// 已刪除的文件不再受理（review B1）。
    func runOCRNow(for doc: ScannedDocument) {
        guard !ocrRunningPaths.contains(doc.fileURL.path),
              !deletedDocumentPaths.contains(doc.fileURL.path) else { return }
        runOCRAfterScan(doc)
    }

    // MARK: - Flatbed 逐頁合併 PDF

    /// 掛起掃描流程，等待使用者從 UI 選擇「下一頁」或「完成 PDF」。
    /// 取消時以 CancellationError resume。
    func promptFlatbedNextPage(pageNumber: Int) async throws -> FlatbedChoice {
        phase = .awaitingNextPage(page: pageNumber)
        awaitingNextPage = true
        flatbedPageCount = pageNumber
        NSLog("[AirScan] flatbed: page \(pageNumber) done, awaiting user choice")
        return try await withCheckedThrowingContinuation { cont in
            flatbedContinuation = cont
        }
    }

    /// 使用者選擇：下一頁（true）或完成 PDF（false）。
    func resolveFlatbedChoice(_ next: Bool) {
        guard let cont = flatbedContinuation else { return }
        flatbedContinuation = nil
        awaitingNextPage = false
        cont.resume(returning: next ? .nextPage : .finish)
    }

    // MARK: - Testing support

    /// Runs the real-scan pipeline and surfaces errors (for integration tests).
    func startScanForTesting(source: ScanSource? = nil) async throws {
        if let source { settings.source = source }
        try await runRealScan()
        await MainActor.run {
            if let s = selectedScanner {
                print("SCANUSED: \(s.host):\(s.port) secure=\(s.isSecure) dpi=\(settings.resolution.rawValue) color=\(settings.colorMode.rawValue) size=\(settings.widthPx)x\(settings.heightPx)")
            }
        }
    }

    // MARK: - Persistence

    /// nonisolated：只依賴 FileManager，供背景 Task（PDF 組裝）呼叫。
    nonisolated static func documentsDirectory() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scans", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "scanSettings")
        }
    }

    private func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: "scanSettings"),
           let s = try? JSONDecoder().decode(ScanSettings.self, from: data) {
            settings = s
        }
    }

    /// 文件庫只存「相對檔名」（review #1）：iOS container 絕對路徑在 app 更新後會改變，
    /// 存絕對路徑會導致載入時 fileExists 全數失敗、清單全滅。
    private func persistDocuments() {
        let entries = documents.map { ["name": $0.name, "file": $0.fileURL.lastPathComponent, "pages": String($0.pageCount)] }
        if let data = try? JSONSerialization.data(withJSONObject: entries) {
            UserDefaults.standard.set(data, forKey: "documents")
        }
    }

    private func loadDocuments() {
        guard let data = UserDefaults.standard.data(forKey: "documents"),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return }
        let dir = Self.documentsDirectory()
        documents = entries.compactMap { e in
            guard let name = e["name"], let pages = Int(e["pages"] ?? "1") else { return nil }
            // 新格式存 "file"（相對檔名）；舊格式存 "url"（絕對路徑）→ migration：
            // 取 lastPathComponent 重拼目前 Documents/Scans 目錄
            let fileName: String?
            if let f = e["file"] {
                fileName = f
            } else if let path = e["url"] {
                fileName = URL(fileURLWithPath: path).lastPathComponent
            } else {
                fileName = nil
            }
            guard let fileName else { return nil }
            let url = dir.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return ScannedDocument(name: name, fileURL: url, pageCount: pages, settings: settings)
        }
    }

    func deleteDocument(_ doc: ScannedDocument) {
        let path = doc.fileURL.path
        try? FileManager.default.removeItem(at: doc.fileURL)
        // 一併刪除 OCR 文字 sidecar，避免 .txt 孤兒留在磁碟（review #14）
        let txtURL = doc.fileURL.deletingPathExtension().appendingPathExtension("txt")
        try? FileManager.default.removeItem(at: txtURL)
        documents.removeAll { $0.id == doc.id }
        persistDocuments()
        // OCR 刪除復活防護（review B1）：記錄已刪路徑、清 ocrOutcome/ocrRunningPaths entry，
        // 讓進行中/剛完成的 OCR 背景任務據此丟棄產物，不寫回已刪路徑
        deletedDocumentPaths.insert(path)
        ocrOutcome.removeValue(forKey: path)
        ocrRunningPaths.remove(path)
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
