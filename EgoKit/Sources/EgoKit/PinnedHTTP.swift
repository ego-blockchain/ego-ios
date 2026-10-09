import Foundation

/// The parts of HTTP/1.1 the gateway client needs, kept apart from the
/// connection so they can be tested without a network.
enum HTTPWire {
    static func encode(_ request: URLRequest, host: String, port: UInt16) -> Data {
        let url = request.url
        var target = url?.path.isEmpty == false ? url!.path : "/"
        if let query = url?.query { target += "?\(query)" }
        let body = request.httpBody ?? Data()
        var head = "\(request.httpMethod ?? "GET") \(target) HTTP/1.1\r\n"
        head += "Host: \(host):\(port)\r\n"
        head += "Connection: close\r\n"
        head += "Content-Length: \(body.count)\r\n"
        for (name, value) in request.allHTTPHeaderFields ?? [:]
        where !["host", "connection", "content-length"].contains(name.lowercased()) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    static func parse(_ raw: Data, url: URL) throws -> (Data, HTTPURLResponse) {
        guard let split = raw.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: raw[..<split.lowerBound], encoding: .utf8)
        else { throw GatewayError.badResponse }
        var lines = head.components(separatedBy: "\r\n")
        let status = lines.removeFirst().split(separator: " ")
        guard status.count >= 2, status[0].hasPrefix("HTTP/1."), let code = Int(status[1]) else {
            throw GatewayError.badResponse
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces)] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        func header(_ name: String) -> String? {
            headers.first { $0.key.lowercased() == name }?.value
        }
        var body = Data(raw[split.upperBound...])
        if header("transfer-encoding")?.lowercased().contains("chunked") == true {
            body = try dechunk(body)
        } else if let length = header("content-length").flatMap(Int.init) {
            guard body.count >= length else { throw GatewayError.badResponse }
            body = body.prefix(length)
        }
        guard let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers) else {
            throw GatewayError.badResponse
        }
        return (Data(body), response)
    }

    static func dechunk(_ data: Data) throws -> Data {
        var out = Data()
        var rest = Data(data)
        let crlf = Data("\r\n".utf8)
        while true {
            guard let end = rest.range(of: crlf),
                  let line = String(data: rest[..<end.lowerBound], encoding: .ascii),
                  let size = Int(line.split(separator: ";").first ?? "", radix: 16)
            else { throw GatewayError.badResponse }
            rest = Data(rest[end.upperBound...])
            if size == 0 { return out }
            guard rest.count >= size + 2 else { throw GatewayError.badResponse }
            out += rest.prefix(size)
            rest = Data(rest.dropFirst(size + 2))
        }
    }
}

#if canImport(Network)
import Network
import Security

/// HTTPS to a gateway over Network.framework. Gateways have self-signed
/// certificates and are reached by IP address, which App Transport Security
/// refuses in URLSession even after the app has checked the pin. Here the pin
/// is the only trust decision: the request is sent only if the server's
/// certificate hashes to it.
enum PinnedHTTP {
    static let maxResponse = 8 * 1024 * 1024

    static func send(_ request: URLRequest, pin: String, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, let host = url.host else { throw GatewayError.badResponse }
        let port = UInt16(url.port ?? 443)
        let pin = pin.lowercased()

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let trust = sec_trust_copy_ref(trust).takeRetainedValue()
            let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
            complete(leaf.map { CertificatePin.sha256(of: Array(SecCertificateCopyData($0) as Data)) == pin } ?? false)
        }, DispatchQueue.global(qos: .userInitiated))
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, Int(timeout.rounded(.up)))
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? .https,
            using: NWParameters(tls: tls, tcp: tcp)
        )
        let raw = try await Exchange(connection, timeout: timeout).run(HTTPWire.encode(request, host: host, port: port))
        return try HTTPWire.parse(raw, url: url)
    }

    /// One request on one connection: send, read until the server closes,
    /// and finish exactly once whether that's success, failure or timeout.
    private final class Exchange: @unchecked Sendable {
        private let connection: NWConnection
        private let timeout: TimeInterval
        private let queue = DispatchQueue(label: "ego.gateway.https")
        private var received = Data()
        private var continuation: CheckedContinuation<Data, Error>?

        init(_ connection: NWConnection, timeout: TimeInterval) {
            self.connection = connection
            self.timeout = timeout
        }

        func run(_ bytes: Data) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.continuation = continuation
                    self.connection.stateUpdateHandler = { [self] state in
                        switch state {
                        case .ready:
                            connection.send(content: bytes, completion: .contentProcessed { error in
                                if let error { self.finish(.failure(GatewayError.unreachable(error.localizedDescription))) }
                            })
                            receive()
                        case .waiting(let error), .failed(let error):
                            finish(.failure(GatewayError.unreachable(error.localizedDescription)))
                        default:
                            break
                        }
                    }
                    self.connection.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + self.timeout) {
                        self.finish(.failure(GatewayError.unreachable("The gateway didn't answer in time.")))
                    }
                }
            }
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
                if let data { received += data }
                if received.count > PinnedHTTP.maxResponse {
                    finish(.failure(GatewayError.badResponse))
                } else if isComplete {
                    finish(.success(received))
                } else if let error {
                    finish(.failure(GatewayError.unreachable(error.localizedDescription)))
                } else {
                    receive()
                }
            }
        }

        private func finish(_ result: Result<Data, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            connection.stateUpdateHandler = nil
            connection.cancel()
            continuation.resume(with: result)
        }
    }
}
#endif
