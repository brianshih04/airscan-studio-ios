import Foundation
import SwiftUI
import PDFKit
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
    /// 目前逐頁累積的頁數（供 UI 顯示）
    @Published var flatbedPageCount = 0
    /// 進行中的掃描工作（供取消）
    private var scanTask: Task<Void, Never>?
    /// 真實掃描的底層工作（供 cancelScan 清理 eSCL job）
    private var activeESCLClient: ESCLClient?
    private var activeJobURL: URL?
    private var flatbedContinuation: CheckedContinuation<FlatbedChoice, Error>?
    var isScanning: Bool { scanTask != nil }

    /// Flatbed 逐頁模式的使用者選擇
    enum FlatbedChoice { case nextPage, finish }
    var discovered: [DiscoveredScanner] { browser.scanners }
    var isBrowsing: Bool { browser.isBrowsing }
    @Published var selectedScannerID: String?
    var selectedScanner: DiscoveredScanner? {
        // Pinned manual scanner wins over auto-discovered (prevents discovered HP hijacking
        // when user explicitly pinned a device for testing)
        if let manual = discovered.first(where: { $0.id.hasPrefix("manual-") }) {
            return manual
        }
        return discovered.first(where: { $0.id == selectedScannerID }) ?? discovered.first
    }

    let browser = ScannerBrowser()
    private var cancellables = Set<AnyCancellable>()

    init() {
        if let saved = UserDefaults.standard.string(forKey: "mode"),
           let m = Mode(rawValue: saved) {
            mode = m
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

    func addManual(host: String) {
        // Accept "ip" or "ip:port"; validate to avoid index-out-of-range
        let parts = host.split(separator: ":")
        guard let first = parts.first, !first.isEmpty,
              first.allSatisfy({ $0.isNumber || $0 == "." }) else { return }
        let ip = String(first)
        let port = parts.count > 1 ? Int(parts[1]) ?? 80 : 80
        browser.addManualScanner(host: ip, port: port)
        selectedScannerID = "manual-\(ip):\(port)"
    }

    // MARK: - Scan

    /// UI 進入點：儲存 scanTask 以支援取消。
    func startScan() {
        guard scanTask == nil else { return } // 防止重複啟動
        scanTask = Task { [weak self] in
            defer { Task { @MainActor in self?.scanTask = nil } }
            await self?.performScan()
        }
    }

    /// 取消目前掃描：讓 Task 收到 CancellationError，並清理 eSCL job。
    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
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

    private func performScan() async {
        do {
            switch mode {
            case .mock:
                try await runMockScan()
            case .real:
                try await runRealScan()
            }
        } catch is CancellationError {
            // 使用者取消：回到 idle，不顯示錯誤
            phase = .idle
        } catch {
            if Task.isCancelled {
                phase = .idle
            } else {
                phase = .failed(error.localizedDescription)
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
        activeJobURL = jobURL
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
                let nextJobURL = try await client.createJob(settings, namespace: caps.scanNamespace)
                activeJobURL = nextJobURL
                guard let data = try await client.pullPage(jobURL: nextJobURL) else {
                    await client.cleanupJob(nextJobURL)
                    break // 掃描器未回傳影像：以已累積頁數完成
                }
                allPages.append(data)
                activeJobURL = nil
                await client.cleanupJob(nextJobURL)
            }
            pages = allPages
        }

        phase = .saving
        let id = UUID()
        let url: URL
        if pages.count == 1 {
            url = Self.documentsDirectory().appendingPathComponent("scan_\(id.uuidString.prefix(8)).jpg")
            try pages[0].write(to: url)
        } else {
            // 多頁（ADF 連掃或 Flatbed 逐頁累積）組成單一 PDF 存入文件庫
            url = Self.documentsDirectory().appendingPathComponent("scan_\(id.uuidString.prefix(8)).pdf")
            let pdf = PDFDocument()
            for (i, data) in pages.enumerated() {
                if let img = UIImage(data: data), let page = PDFPage(image: img) {
                    pdf.insert(page, at: i)
                }
            }
            try pdf.write(to: url)
        }
        flatbedPageCount = 0
        let doc = ScannedDocument(
            name: "掃描 \(Self.dateFormatter.string(from: Date()))",
            fileURL: url,
            pageCount: pages.count,
            settings: settings
        )
        documents.insert(doc, at: 0)
        persistDocuments()
        phase = .done
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

    static func documentsDirectory() -> URL {
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

    private func persistDocuments() {
        let entries = documents.map { ["name": $0.name, "url": $0.fileURL.path, "pages": String($0.pageCount)] }
        if let data = try? JSONSerialization.data(withJSONObject: entries) {
            UserDefaults.standard.set(data, forKey: "documents")
        }
    }

    private func loadDocuments() {
        guard let data = UserDefaults.standard.data(forKey: "documents"),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return }
        documents = entries.compactMap { e in
            guard let name = e["name"], let path = e["url"], let pages = Int(e["pages"] ?? "1") else { return nil }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return ScannedDocument(name: name, fileURL: url, pageCount: pages, settings: settings)
        }
    }

    func deleteDocument(_ doc: ScannedDocument) {
        try? FileManager.default.removeItem(at: doc.fileURL)
        documents.removeAll { $0.id == doc.id }
        persistDocuments()
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
