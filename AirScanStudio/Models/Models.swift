import Foundation

// MARK: - Domain Models (mirrors Android version's data layer)

enum ScanSource: String, Codable, CaseIterable, Identifiable {
    case platen
    case adf

    var id: String { rawValue }
    var displayName: String { self == .platen ? "Flatbed 單頁" : "ADF 多頁" }
}

enum ScanResolution: Int, Codable, CaseIterable, Identifiable {
    case dpi100 = 100
    case dpi150 = 150
    case dpi200 = 200
    case dpi300 = 300
    case dpi600 = 600

    var id: Int { rawValue }
    var displayName: String { "\(rawValue) dpi" }
}

enum ScanColorMode: String, Codable, CaseIterable, Identifiable {
    case rgb24
    case grayscale8
    case bw1

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .rgb24: return "彩色"
        case .grayscale8: return "灰階"
        case .bw1: return "黑白"
        }
    }
}

struct ScanSettings: Equatable, Codable {
    var source: ScanSource = .platen
    var resolution: ScanResolution = .dpi300
    var colorMode: ScanColorMode = .rgb24
    /// eSCL Width/Height 單位是 1/300 inch（與 dpi 無關！）：A4 = 2480×3508
    /// dpi 只放在 XResolution/YResolution。之前隨 dpi 放大導致超過 caps Max 被钳制。
    var widthPx: Int {
        Int(((210.0 / 25.4) * 300.0).rounded())
    }
    var heightPx: Int {
        Int(((297.0 / 25.4) * 300.0).rounded())
    }
}

struct DiscoveredScanner: Identifiable, Equatable {
    let id: String          // service name (unique per device)
    let name: String
    let host: String
    let port: Int
    let isSecure: Bool      // uscans (TLS) vs uscan

    /// eSCL root path, typically "/eSCL"
    var rootPath: String { "/eSCL" }
}

enum DocumentFormat: String {
    case jpeg = "image/jpeg"
    case pdf = "application/pdf"
}

struct ScannedDocument: Identifiable {
    let id: UUID
    var name: String
    let createdAt: Date
    let fileURL: URL
    var pageCount: Int
    let settings: ScanSettings
    /// True only when the device reported actual settings back (eSCL JobSettings)
    let actualSettingsReported: Bool

    init(name: String, fileURL: URL, pageCount: Int, settings: ScanSettings, actualSettingsReported: Bool = false) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.fileURL = fileURL
        self.pageCount = pageCount
        self.settings = settings
        self.actualSettingsReported = actualSettingsReported
    }
}

// MARK: - Scan Job Status (eSCL job lifecycle)

enum ScanJobPhase: String {
    case idle
    case processing = "Processing"
    case completed = "Completed"
    case aborted = "Aborted"
    case canceled = "Canceled"
}
