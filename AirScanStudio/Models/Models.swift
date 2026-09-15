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


enum PaperSize: String, CaseIterable, Identifiable, Codable {
    case a4
    case a5
    case letter
    case photo4x6
    case photo5x7
    case auto

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .a4: return "A4"
        case .a5: return "A5"
        case .letter: return "Letter"
        case .photo4x6: return "4×6"
        case .photo5x7: return "5×7"
        case .auto: return "自動"
        }
    }

    var widthHundredthsOfInch: Int? {
        switch self {
        case .a4: return 2480
        case .a5: return 1748
        case .letter: return 2550
        case .photo4x6: return 1200
        case .photo5x7: return 1500
        case .auto: return nil
        }
    }

    var heightHundredthsOfInch: Int? {
        switch self {
        case .a4: return 3508
        case .a5: return 2480
        case .letter: return 3300
        case .photo4x6: return 1800
        case .photo5x7: return 2100
        case .auto: return nil
        }
    }
}

struct ScanSettings: Equatable, Codable {
    var source: ScanSource = .platen
    var resolution: ScanResolution = .dpi300
    var colorMode: ScanColorMode = .rgb24
    var paperSize: PaperSize = .a4
    /// eSCL Width/Height 單位是 1/300 inch（與 dpi 無關）。依紙張尺寸；Auto = A4 滿版。
    var widthPx: Int {
        paperSize.widthHundredthsOfInch ?? 2480
    }
    var heightPx: Int {
        paperSize.heightHundredthsOfInch ?? 3508
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
