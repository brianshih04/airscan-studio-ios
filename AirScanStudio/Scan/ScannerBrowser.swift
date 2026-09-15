import Foundation
import Network

/// Discovers eSCL scanners via Bonjour (_uscan._tcp / _uscans._tcp).
/// Resolves service endpoints to host:port, mirrors Android NsdManager discovery flow.
@MainActor
final class ScannerBrowser: ObservableObject {
    @Published var scanners: [DiscoveredScanner] = []
    @Published var isBrowsing = false

    private var browsers: [NWBrowser] = []
    private var pending = Set<String>()

    func start() {
        stop()
        isBrowsing = true
        for (type, secure) in [("_uscan._tcp", false), ("_uscans._tcp", true)] {
            let params = NWParameters()
            params.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: params)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let endpoints: [(String, NWEndpoint)] = results.compactMap { result in
                    guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                    return (name, result.endpoint)
                }
                Task { @MainActor in
                    for (name, ep) in endpoints {
                        await self?.resolveAndAdd(name: name, endpoint: ep, secure: secure)
                    }
                }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    private func resolveAndAdd(name: String, endpoint: NWEndpoint, secure: Bool) async {
        guard !scanners.contains(where: { $0.id == name }), !pending.contains(name) else { return }
        pending.insert(name)
        defer { pending.remove(name) }

        let ep = endpoint
        let resolved: (String, Int)? = await withCheckedContinuation { cont in
            let conn = NWConnection(to: ep, using: .tcp)
            let box = LockedBox<Bool>(false)
            conn.stateUpdateHandler = { state in
                guard !box.value else { return }
                if state == .ready {
                    box.value = true
                    // remoteEndpoint gives host:port once resolved
                    var host = "0.0.0.0"
                    var port = 80
                    if let remote = conn.currentPath?.remoteEndpoint {
                        let desc = String(describing: remote)
                        // Format is either "IPv4地址%iface:port" or "host:port"
                        let parts = desc.split(separator: ":")
                        if parts.count >= 2, let p = Int(parts.last ?? "") {
                            port = p
                            var h = parts[parts.count - 2].description
                            if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
                            host = h
                        }
                    }
                    cont.resume(returning: (host, port))
                    conn.cancel()
                } else if case .failed = state, !box.value {
                    box.value = true
                    cont.resume(returning: nil)
                    conn.cancel()
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                if !box.value {
                    box.value = true
                    cont.resume(returning: nil)
                    conn.cancel()
                }
            }
        }

        guard let (host, port) = resolved, host != "0.0.0.0" else { return }
        let displayName = name.replacingOccurrences(of: "\\s*@.*$", with: "", options: .regularExpression)
        merge([DiscoveredScanner(id: name, name: displayName, host: host, port: port, isSecure: secure)])
    }

    /// Manual entry fallback when Bonjour is blocked.
    func addManualScanner(host: String, port: Int = 80, name: String? = nil) {
        let id = "manual-\(host):\(port)"
        guard !scanners.contains(where: { $0.id == id }) else { return }
        merge([DiscoveredScanner(
            id: id,
            name: name ?? "手動加入 (\(host))",
            host: host,
            port: port,
            isSecure: false
        )])
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers = []
        isBrowsing = false
    }

    private func merge(_ items: [DiscoveredScanner]) {
        var merged = scanners
        for item in items {
            if !merged.contains(where: { $0.id == item.id }) {
                merged.append(item)
            }
        }
        scanners = merged
    }
}

/// Minimal thread-safe box for one-shot continuation guards.
final class LockedBox<T> {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}
