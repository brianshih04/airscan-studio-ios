import Foundation
import Network

/// Discovers eSCL scanners via Bonjour (_uscan._tcp / _uscans._tcp).
/// Mirrors Android version's NsdManager discovery.
@MainActor
final class ScannerBrowser: ObservableObject {
    @Published var scanners: [DiscoveredScanner] = []
    @Published var isBrowsing = false

    private var browsers: [NWBrowser] = []

    func start() {
        stop()
        isBrowsing = true
        // Note: NWBrowser doesn't support multiple descriptors cleanly;
        // we create one browser per service type.
        for (type, secure) in [("_uscan._tcp", false), ("_uscans._tcp", true)] {
            let params = NWParameters()
            params.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: params)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let items: [DiscoveredScanner] = results.compactMap { result in
                    guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                    return DiscoveredScanner(
                        id: name,
                        name: name.replacingOccurrences(of: "\\s*@.*$", with: "", options: .regularExpression),
                        host: name,
                        port: 80,
                        isSecure: secure
                    )
                }
                Task { @MainActor in
                    self?.merge(items)
                }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
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
