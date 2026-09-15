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
    var discovered: [DiscoveredScanner] { browser.scanners }
    var isBrowsing: Bool { browser.isBrowsing }
    @Published var selectedScannerID: String?
    var selectedScanner: DiscoveredScanner? {
        discovered.first(where: { $0.id == selectedScannerID }) ?? discovered.first
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

    func startScan() async {
        do {
            switch mode {
            case .mock:
                try await runMockScan()
            case .real:
                try await runRealScan()
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func runMockScan() async {
        let pages = settings.source == .adf ? adfPageLimit : 1
        for i in 0..<pages {
            phase = .scanning(page: i)
            // Simulate scanner latency
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
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
            if let pinned = UserDefaults.standard.string(forKey: "manualScannerHost"), !pinned.isEmpty {
                addManual(host: pinned)
            }
            browser.start()
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }
        guard let scanner = selectedScanner else {
            throw AppError("找不到掃描器，請先在「裝置」頁探索並選擇掃描器")
        }
        let client = ESCLClient(scanner: scanner)
        phase = .scanning(page: 0)
        let caps = try await client.fetchCapabilities()
        let jobURL = try await client.createJob(settings, namespace: caps.scanNamespace)
        // Pull pages until the job ends or the ADF page limit is reached.
        // Brother serves NextDocument while Pending; HP serves after Completed.
        let maxPages = settings.source == .adf ? adfPageLimit : 1
        var pages: [Data] = []
        while pages.count < maxPages {
            phase = .scanning(page: pages.count)
            if let data = try await client.pullPage(jobURL: jobURL) {
                pages.append(data)
                // If source is platen, one page only
                if settings.source == .platen { break }
            } else {
                break
            }
        }
        await client.cleanupJob(jobURL)
        guard !pages.isEmpty else {
            throw AppError("掃描器未回傳影像（可能超時或沒有文件）")
        }

        phase = .saving
        let id = UUID()
        let url: URL
        if pages.count == 1 {
            url = Self.documentsDirectory().appendingPathComponent("scan_\(id.uuidString.prefix(8)).jpg")
            try pages[0].write(to: url)
        } else {
            url = Self.documentsDirectory().appendingPathComponent("scan_\(id.uuidString.prefix(8)).pdf")
            let pdf = PDFDocument()
            for (i, data) in pages.enumerated() {
                if let img = UIImage(data: data), let page = PDFPage(image: img) {
                    pdf.insert(page, at: i)
                }
            }
            try pdf.write(to: url)
        }
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
