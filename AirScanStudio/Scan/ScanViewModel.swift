import Foundation
import SwiftUI
import PDFKit

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

    init() {
        if let saved = UserDefaults.standard.string(forKey: "mode"),
           let m = Mode(rawValue: saved) {
            mode = m
        }
        loadSettings()
        loadDocuments()
    }

    // MARK: - Discovery

    func startDiscovery() {
        guard mode == .real else { return }
        phase = .discovering
        browser.start()
    }

    func addManual(host: String) {
        // Accept "ip" or "ip:port"
        let parts = host.split(separator: ":")
        let ip = String(parts[0])
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
        guard let scanner = selectedScanner else {
            throw AppError("找不到掃描器，請先在「裝置」頁探索並選擇掃描器")
        }
        let client = ESCLClient(scanner: scanner)
        phase = .scanning(page: 0)
        let caps = try await client.fetchCapabilities()
        let jobURL = try await client.createJob(settings, namespace: caps.scanNamespace)
        let finalPhase = try await client.waitForJob(jobURL)
        guard finalPhase == .completed else {
            await client.cleanupJob(jobURL)
            throw AppError("掃描工作 \(finalPhase.rawValue)")
        }
        let data = try await client.downloadPage(jobURL: jobURL)
        await client.cleanupJob(jobURL)

        phase = .saving
        let url = Self.documentsDirectory().appendingPathComponent("scan_\(UUID().uuidString.prefix(8)).jpg")
        try data.write(to: url)
        let doc = ScannedDocument(
            name: "掃描 \(Self.dateFormatter.string(from: Date()))",
            fileURL: url,
            pageCount: 1,
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
