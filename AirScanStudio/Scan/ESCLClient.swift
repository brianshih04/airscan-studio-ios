import Foundation

/// eSCL scan client: capabilities → create job (POST) → poll status → download page.
/// Protocol flow mirrors the Android app's EsclScanClient (eSCL Mopria spec section behavior).
/// Reference: https://github.com/mopria/eSCL-spec
struct ESCLClient {
    let scanner: DiscoveredScanner
    private let session: URLSession

    init(scanner: DiscoveredScanner) {
        self.scanner = scanner
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: cfg)
    }

    private var baseURL: String {
        let scheme = scanner.isSecure ? "https" : "http"
        return "\(scheme)://\(scanner.host):\(scanner.port)\(scanner.rootPath)"
    }

    // MARK: - Capabilities

    struct ScannerCapabilities {
        var maker: String = ""
        var model: String = ""
        var version: String = "2.0"
        var supportsPlaten = true
        var supportsAdf = false
        var adfDuplex = false
        /// Namespace from caps root — reuse in ScanSettings (HP: schemas.hp.com/imaging/escl)
        var scanNamespace = "http://schemas.microsoft.com/windows/scanning"
    }

    func fetchCapabilities() async throws -> ScannerCapabilities {
        let url = URL(string: "\(baseURL)/ScannerCapabilities")!
        let (data, resp) = try await session.data(from: url)
        NSLog("[AirScan] caps HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1) from \(url)")
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ESCLError.badResponse
        }
        return try parseCapabilities(data)
    }

    // MARK: - Scan flow

    /// POST ScanJobs with settings XML, returns job URL.
    func createJob(_ settings: ScanSettings, namespace: String) async throws -> URL {
        let xml = Self.scanSettingsXML(settings, namespace: namespace)
        var req = URLRequest(url: URL(string: "\(baseURL)/ScanJobs")!)
        req.httpMethod = "POST"
        req.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        req.httpBody = xml.data(using: .utf8)
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ESCLError.badResponse }
        NSLog("[AirScan] POST ScanJobs -> HTTP \(http.statusCode)")
        guard http.statusCode == 201, let location = http.value(forHTTPHeaderField: "Location") else {
            throw ESCLError.jobRejected(status: http.statusCode)
        }
        NSLog("[AirScan] Location header: \(location)")
        // Location may be absolute or relative
        if let abs = URL(string: location), abs.scheme != nil { return abs }
        guard let resolved = URL(string: location, relativeTo: URL(string: baseURL))?.absoluteURL else {
            throw ESCLError.badResponse
        }
        return resolved
    }

    /// Poll job status until Completed/Aborted/Canceled.
    func waitForJob(_ jobURL: URL) async throws -> ScanJobPhase {
        for poll in 0..<300 { // ~5 min max
            var req = URLRequest(url: jobURL)
            req.httpMethod = "GET"
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw ESCLError.badResponse }
            if http.statusCode == 200, let phase = Self.parseJobPhase(data) {
                if poll % 5 == 0 { NSLog("[AirScan] poll \(poll): \(phase.rawValue)") }
                if phase != .processing && phase != .idle {
                    return phase
                }
            } else {
                NSLog("[AirScan] poll \(poll): HTTP \(http.statusCode)")
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw ESCLError.timeout
    }

    /// Unified page pull (Brother & HP compatible):
    /// - Brother: NextDocument returns 200 immediately while job is Pending.
    /// - HP: NextDocument returns data after job Completed.
    /// Returns nil on timeout/cancel; throws on hard errors.
    func pullPage(jobURL: URL) async throws -> Data? {
        let next = jobURL.appendingPathComponent("NextDocument")
        for poll in 0..<120 { // ~2 min ceiling
            // 1) try the document first (Brother serves while Pending)
            var req = URLRequest(url: next)
            req.timeoutInterval = 30
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let mime = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            if code == 200, mime.contains("image/") || mime.contains("application/pdf") {
                NSLog("[AirScan] NextDocument 200 at poll \(poll), \(data.count) bytes")
                return data
            }
            // 2) check job state (HP flips to Completed; Brother flips to Canceled on timeout)
            var sreq = URLRequest(url: jobURL)
            sreq.timeoutInterval = 15
            if let (sdata, sresp) = try? await session.data(for: sreq),
               (sresp as? HTTPURLResponse)?.statusCode == 200,
               let phase = Self.parseJobPhase(sdata) {
                if poll % 10 == 0 { NSLog("[AirScan] pull poll \(poll): doc=\(code) job=\(phase.rawValue)") }
                if phase == .aborted || phase == .canceled {
                    NSLog("[AirScan] job ended: \(phase.rawValue)")
                    return nil
                }
            }
            try await Task.sleep(nanoseconds: 800_000_000)
        }
        NSLog("[AirScan] pullPage timeout")
        return nil
    }

    /// GET the scanned page (NextDocument).
    func downloadPage(jobURL: URL) async throws -> Data {
        let next = jobURL.appendingPathComponent("NextDocument")
        let (data, resp) = try await session.data(from: next)
        NSLog("[AirScan] NextDocument HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1), \(data.count) bytes")
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ESCLError.badResponse
        }
        return data
    }

    /// DELETE the job to clean up scanner state.
    func cleanupJob(_ jobURL: URL) async {
        var req = URLRequest(url: jobURL)
        req.httpMethod = "DELETE"
        _ = try? await session.data(for: req)
    }

    // MARK: - XML generation (pwg + scan namespaces, mirrors Android EsclXmlBuilder)

    static func scanSettingsXML(_ s: ScanSettings, namespace: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScanSettings xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm"
                           xmlns:scan="\(namespace)">
          <pwg:Version>2.63</pwg:Version>
          <scan:InputSource>\(s.source == .platen ? "Platen" : "Feeder")</scan:InputSource>
          <scan:XResolution>\(s.resolution.rawValue)</scan:XResolution>
          <scan:YResolution>\(s.resolution.rawValue)</scan:YResolution>
          <scan:Intent>Document</scan:Intent>
          <scan:ColorMode>\(colorModeXML(s.colorMode))</scan:ColorMode>
          <pwg:Width>\(s.widthPx)</pwg:Width>
          <pwg:Height>\(s.heightPx)</pwg:Height>
          <scan:DocumentFormatExt class="scan:DocumentFormatExtType">image/jpeg</scan:DocumentFormatExt>
        </scan:ScanSettings>
        """
    }

    private static func colorModeXML(_ mode: ScanColorMode) -> String {
        switch mode {
        case .rgb24: return "RGB24"
        case .grayscale8: return "Grayscale8"
        case .bw1: return "BlackPixel1"
        }
    }

    static func parseJobPhase(_ data: Data) -> ScanJobPhase? {
        guard let xml = String(data: data, encoding: .utf8) else { return nil }
        for phase in [ScanJobPhase.completed, .aborted, .canceled, .processing] {
            if xml.contains("<pwg:JobState>\(phase.rawValue)</pwg:JobState>")
                || xml.contains("<JobState>\(phase.rawValue)</JobState>") {
                return phase
            }
        }
        return .processing
    }

    /// Synchronous parse entry for tests.
    func fetchCapabilitiesParser(_ xmlData: Data) throws -> ScannerCapabilities {
        try parseCapabilities(xmlData)
    }

    private func parseCapabilities(_ data: Data) throws -> ScannerCapabilities {
        var caps = ScannerCapabilities()
        guard let xml = String(data: data, encoding: .utf8) else { return caps }
        caps.maker = Self.extract(xml, tag: "pwg:MakerAndModel") ?? ""
        caps.version = Self.extract(xml, tag: "pwg:Version") ?? "2.0"
        if xml.contains("schemas.hp.com/imaging/escl") {
            caps.scanNamespace = "http://schemas.hp.com/imaging/escl/2011/05/03"
        }
        caps.supportsPlaten = xml.contains("<scan:Platen>") || xml.contains("PlatenInputCaps")
        caps.supportsAdf = xml.contains("FeederInputCaps")
        caps.adfDuplex = xml.contains("AdfDuplexInputCaps") && !xml.contains("<scan:AdfDuplexInputCaps/>")
        caps.model = caps.maker
        return caps
    }

    static func extract(_ xml: String, tag: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"), let end = xml.range(of: "</\(tag)>") else { return nil }
        return String(xml[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Errors

enum ESCLError: LocalizedError {
    case badResponse
    case jobRejected(status: Int)
    case timeout

    var errorDescription: String? {
        switch self {
        case .badResponse: return "掃描器回應異常"
        case .jobRejected(let status): return "掃描工作被拒絕 (HTTP \(status))"
        case .timeout: return "掃描工作逾時"
        }
    }
}
