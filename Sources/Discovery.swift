import Foundation
import Network

/// Lightweight stderr logging, enabled with `CABASSE_DEBUG=1`.
func dlog(_ msg: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["CABASSE_DEBUG"] != nil else { return }
    FileHandle.standardError.write(Data(("[cabasse] " + msg() + "\n").utf8))
}

/// A Cabasse amplifier found on the LAN via Bonjour (`_cabasse-api._tcp`).
struct DiscoveredAmp: Identifiable, Hashable {
    let id: String          // service name, e.g. "AMP_240S-63aef4"
    let host: String        // resolved IPv4 literal
    let port: Int
    var base: URL { URL(string: "http://\(host):\(port)")! }
}

/// Browses for `_cabasse-api._tcp` services and resolves each to an IPv4 host:port.
final class Discovery {
    private var browser: NWBrowser?
    private var onFound: ((DiscoveredAmp) -> Void)?

    func start(onFound: @escaping (DiscoveredAmp) -> Void) {
        self.onFound = onFound

        let params = NWParameters.tcp
        // Force IPv4 so the resulting host is a clean dotted literal (no zone id).
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }

        let browser = NWBrowser(
            for: .bonjour(type: "_cabasse-api._tcp", domain: "local."),
            using: .init()
        )
        self.browser = browser

        browser.stateUpdateHandler = { state in
            dlog("browser state: \(state)")
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            dlog("browse results: \(results.count)")
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint else { continue }
                dlog("found service: \(name)")
                self?.resolve(endpoint: result.endpoint, name: name, params: params)
            }
        }
        browser.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Opens a short-lived connection just to read the resolved remote host:port.
    private func resolve(endpoint: NWEndpoint, name: String, params: NWParameters) {
        let conn = NWConnection(to: endpoint, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if case let .hostPort(host, port) = conn.currentPath?.remoteEndpoint {
                    let hostStr: String
                    switch host {
                    case .ipv4(let a): hostStr = "\(a)"
                    case .ipv6(let a): hostStr = "\(a)"
                    case .name(let n, _): hostStr = n
                    @unknown default: hostStr = ""
                    }
                    let clean = hostStr.split(separator: "%").first.map(String.init) ?? hostStr
                    dlog("resolved \(name) -> \(clean):\(port.rawValue)")
                    if !clean.isEmpty {
                        self?.onFound?(DiscoveredAmp(id: name, host: clean, port: Int(port.rawValue)))
                    }
                }
                conn.cancel()
            case .failed, .cancelled:
                conn.cancel()
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }
}
