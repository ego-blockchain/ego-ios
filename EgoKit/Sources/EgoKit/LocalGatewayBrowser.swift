#if canImport(Network)
import Foundation
import Network

/// Finds Ego Desktop gateways on the local network over Bonjour.
///
/// A desktop advertises `_ego-gateway._tcp` with its certificate fingerprint in
/// the TXT record. Each service is resolved to an IPv4 address once, and the
/// phone pins the advertised certificate when it connects.
public final class LocalGatewayBrowser: @unchecked Sendable {
    public static let serviceType = "_ego-gateway._tcp"

    private let queue = DispatchQueue(label: "com.egoblockchain.wallet.local-gateways")
    private let onChange: @Sendable ([Gateway]) -> Void
    private var browser: NWBrowser?
    private var resolved: [String: Gateway] = [:]
    private var pending: [String: NWConnection] = [:]

    public init(onChange: @escaping @Sendable ([Gateway]) -> Void) {
        self.onChange = onChange
    }

    public func start() {
        queue.async { [self] in
            guard browser == nil else { return }
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: NWParameters())
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.update(results)
            }
            browser.stateUpdateHandler = { [weak self] state in
                guard case .failed = state, let self else { return }
                self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                    self?.restart()
                }
            }
            self.browser = browser
            browser.start(queue: queue)
        }
    }

    public func restart() {
        queue.async { [self] in
            browser?.cancel()
            browser = nil
            pending.values.forEach { $0.cancel() }
            pending = [:]
            resolved = [:]
            publish()
            start()
        }
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var seen = Set<String>()
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint,
                  case let .bonjour(txt) = result.metadata,
                  let pin = txt["cert"]?.lowercased(),
                  pin.count == 64, pin.allSatisfy(\.isHexDigit)
            else { continue }
            seen.insert(name)
            if resolved[name]?.certSha256 == pin || pending[name] != nil { continue }
            resolve(name: name, endpoint: result.endpoint, pin: pin)
        }
        for name in resolved.keys where !seen.contains(name) {
            resolved[name] = nil
        }
        for (name, connection) in pending where !seen.contains(name) {
            connection.cancel()
            pending[name] = nil
        }
        publish()
    }

    private func resolve(name: String, endpoint: NWEndpoint, pin: String) {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        pending[name] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint,
                   case let .ipv4(address) = host,
                   let url = URL(string: "https://\(address.rawValue.map(String.init).joined(separator: ".")):\(port.rawValue)/rpc") {
                    self.resolved[name] = Gateway(endpoint: url, certSha256: pin, node: "")
                }
                connection.cancel()
            case .waiting, .failed:
                connection.cancel()
            case .cancelled:
                if self.pending[name] === connection {
                    self.pending[name] = nil
                    self.publish()
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func publish() {
        onChange(resolved.values.sorted { $0.endpoint.absoluteString < $1.endpoint.absoluteString })
    }
}
#endif
