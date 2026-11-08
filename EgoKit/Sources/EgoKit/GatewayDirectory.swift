import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GatewayAnnouncement: Codable, Equatable, Hashable {
    public let endpoint: String
    public let certSha256: String
    public let node: String
    public let ts: Int64
    public let pubkey: String
    public let sig: String

    public init(endpoint: String, certSha256: String, node: String, ts: Int64, pubkey: String, sig: String) {
        self.endpoint = endpoint
        self.certSha256 = certSha256
        self.node = node
        self.ts = ts
        self.pubkey = pubkey
        self.sig = sig
    }

    enum CodingKeys: String, CodingKey {
        case endpoint, node, ts, pubkey, sig
        case certSha256 = "cert_sha256"
    }

    public var signingBytes: [UInt8] {
        Array("ego/gateway/v1\n\(endpoint)\n\(certSha256)\n\(ts)".utf8)
    }

    public var gateway: Gateway? {
        URL(string: endpoint).map { Gateway(endpoint: $0, certSha256: certSha256, node: node) }
    }

    public static let maxAge: Int64 = 30 * 24 * 60 * 60

    public func isAuthentic(now: Int64) -> Bool {
        guard GatewayAnnouncement.isPublicEndpoint(endpoint),
              ts <= now + 300,
              ts >= now - GatewayAnnouncement.maxAge,
              certSha256.count == 64,
              certSha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              let pk = Hex.decode(pubkey), pk.count == 32,
              let signature = Hex.decode(sig), signature.count == 64,
              EgoAddress.from(publicKey: pk) == node
        else { return false }
        return EgoKey.verify(signature: signature, message: signingBytes, publicKey: pk)
    }

    public static func isPublicEndpoint(_ endpoint: String) -> Bool {
        guard endpoint.hasPrefix("https://"), endpoint.hasSuffix("/rpc") else { return false }
        let hostPort = endpoint.dropFirst("https://".count).dropLast("/rpc".count)
        if hostPort.first == "[" {
            guard let close = hostPort.firstIndex(of: "]") else { return false }
            let afterClose = hostPort[hostPort.index(after: close)...]
            guard afterClose.first == ":", let port = UInt16(afterClose.dropFirst()), port >= 1024,
                  let groups = ipv6Groups(String(hostPort[hostPort.index(after: hostPort.startIndex)..<close]))
            else { return false }
            return isGlobalIPv6(groups)
        }
        let pieces = hostPort.split(separator: ":")
        guard pieces.count == 2, let port = UInt16(pieces[1]), port >= 1024 else { return false }
        let octets = pieces[0].split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard octets.count == 4, "\(octets[0]).\(octets[1]).\(octets[2]).\(octets[3]):\(port)" == hostPort else { return false }
        let (a, b) = (octets[0], octets[1])
        let reserved = a == 0 || a == 10 || a == 127 || a >= 224
            || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
            || (a == 100 && (64...127).contains(b)) || (a == 192 && b == 0) || (a == 198 && (18...19).contains(b))
            || (a == 198 && b == 51) || (a == 203 && b == 0)
        return !reserved
    }

    static func ipv6Groups(_ text: String) -> [UInt16]? {
        guard !text.isEmpty, text == text.lowercased() else { return nil }
        let halves = text.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func parse(_ part: String) -> [UInt16]? {
            if part.isEmpty { return [] }
            var out: [UInt16] = []
            for piece in part.split(separator: ":", omittingEmptySubsequences: false) {
                guard (1...4).contains(piece.count), piece.allSatisfy(\.isHexDigit), let value = UInt16(piece, radix: 16) else { return nil }
                out.append(value)
            }
            return out
        }
        guard let head = parse(halves[0]) else { return nil }
        if halves.count == 1 { return head.count == 8 ? head : nil }
        guard let tail = parse(halves[1]), head.count + tail.count <= 7 else { return nil }
        return head + Array(repeating: 0, count: 8 - head.count - tail.count) + tail
    }

    static func isGlobalIPv6(_ groups: [UInt16]) -> Bool {
        groups.count == 8 && (groups[0] & 0xe000) == 0x2000
            && !(groups[0] == 0x2001 && (groups[1] == 0x0db8 || groups[1] == 0)) && groups[0] != 0x2002
    }
}

public struct CachedGateway: Codable, Equatable {
    public var announcement: GatewayAnnouncement
    public var lastOK: Int64?
    public var failures: Int
    public var lastFailure: Int64? = nil
}

public protocol GatewayStore: Sendable {
    func load() -> [CachedGateway]
    func save(_ gateways: [CachedGateway])
}

public final class FileGatewayStore: GatewayStore, @unchecked Sendable {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> [CachedGateway] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([CachedGateway].self, from: data)) ?? []
    }

    public func save(_ gateways: [CachedGateway]) {
        guard let data = try? JSONEncoder().encode(gateways) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

public actor GatewayDirectory {
    public static let bootstrapURLs = [
        "https://rpc.egoblockchain.com/gateways",
        "https://rpc2.egoblockchain.com/gateways",
        "https://rpc3.egoblockchain.com/gateways",
    ].compactMap(URL.init(string:))
    public static let maxCached = 200
    static let waveSize = 3
    static let maxTries = 9
    static let firstContactGap: Int64 = 30
    static let firstContactMaxGap: Int64 = 600
    static let bootstrapGap: Int64 = 600
    static let maxBootstrapGap: Int64 = 6 * 60 * 60
    static let baseCooldown: Int64 = 60
    static let maxCooldown: Int64 = 6 * 60 * 60
    static let forgetAfter: Int64 = 14 * 24 * 60 * 60
    static let localCooldown: Int64 = 60

    public typealias Probe = @Sendable (GatewayAnnouncement) async -> Bool
    public typealias LocalProbe = @Sendable (Gateway) async -> Bool
    public typealias Fetch = @Sendable () async throws -> [GatewayAnnouncement]
    public typealias Exchange = @Sendable (GatewayAnnouncement) async throws -> [GatewayAnnouncement]

    private var cache: [String: CachedGateway]
    private let store: GatewayStore
    private let probe: Probe
    private let fetchBootstrap: Fetch
    private let exchange: Exchange
    private let clock: @Sendable () -> Int64
    private var lastBootstrap: Int64?
    private var bootstrapMisses = 0
    private var current: GatewayAnnouncement?
    private let localProbe: LocalProbe
    private var local: [Gateway] = []
    private var localFailures: [URL: Int64] = [:]
    private var currentLocal: Gateway?

    public init(
        store: GatewayStore,
        probe: Probe? = nil,
        fetchBootstrap: Fetch? = nil,
        exchange: Exchange? = nil,
        localProbe: LocalProbe? = nil,
        clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.store = store
        self.cache = Dictionary(store.load().map { ($0.announcement.endpoint, $0) }, uniquingKeysWith: { a, _ in a })
        self.probe = probe ?? { a in
            guard let g = a.gateway else { return false }
            return (try? await GatewayClient(gateway: g, timeout: 10).health()) == true
        }
        self.localProbe = localProbe ?? { g in
            (try? await GatewayClient(gateway: g, timeout: 3).health()) == true
        }
        self.fetchBootstrap = fetchBootstrap ?? {
            struct Listing: Decodable { let gateways: [GatewayAnnouncement] }
            var lastError: Error = GatewayError.badResponse
            for url in GatewayDirectory.bootstrapURLs {
                do {
                    let (data, response) = try await GatewayDirectory.fetch(url)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw GatewayError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
                    }
                    return try JSONDecoder().decode(Listing.self, from: data).gateways
                } catch {
                    lastError = error
                }
            }
            throw lastError
        }
        self.exchange = exchange ?? { a in
            guard let g = a.gateway else { return [] }
            return try await GatewayClient(gateway: g).gatewayList()
        }
        self.clock = clock
    }

    public var known: [CachedGateway] {
        ranked()
    }

    /// Gateways on this network that answered recently (or were never tried),
    /// for asking a second Ego Desktop without leaving the home network.
    public var nearby: [Gateway] {
        let now = clock()
        return local.filter { g in
            guard let failed = localFailures[g.endpoint], now >= failed else { return true }
            return now - failed >= GatewayDirectory.localCooldown
        }
    }

    /// Gateways found on the local network. They come from Bonjour rather than a
    /// signed announcement, are never saved, and are tried before any gateway on
    /// the internet because the router may not loop its own public address back.
    public func setLocal(_ gateways: [Gateway]) {
        local = gateways
        if let c = currentLocal, !gateways.contains(c) {
            currentLocal = nil
        }
    }

    /// Gateways run by the computer that uses this wallet: nearby ones first,
    /// then ones it announced on the internet. Only these can show the
    /// computer's own Earnings page.
    public func gateways(runBy node: String) -> [Gateway] {
        guard !node.isEmpty else { return [] }
        let nearby = local.filter { $0.node == node }
        let remote = ranked()
            .filter { $0.announcement.node == node }
            .compactMap(\.announcement.gateway)
        return nearby + remote.filter { r in !nearby.contains { $0.endpoint == r.endpoint } }
    }

    public func client() async throws -> GatewayClient {
        if let currentLocal {
            return GatewayClient(gateway: currentLocal)
        }
        if let nearby = await pickLocal() {
            currentLocal = nearby
            return GatewayClient(gateway: nearby)
        }
        if let current, let g = current.gateway {
            return GatewayClient(gateway: g)
        }
        guard let winner = await pick(), let g = winner.gateway else {
            throw GatewayError.unreachable("No gateway answered. Check your internet connection and try again.")
        }
        current = winner
        await learn(from: winner)
        return GatewayClient(gateway: g)
    }

    public func reportFailure() {
        if let c = currentLocal {
            localFailures[c.endpoint] = clock()
            currentLocal = nil
            return
        }
        if let c = current {
            mark(c.endpoint, ok: false)
        }
        current = nil
    }

    public func networkChanged() {
        currentLocal = nil
        localFailures = [:]
        for (endpoint, var entry) in cache where entry.failures > 0 {
            entry.failures = 0
            entry.lastFailure = nil
            cache[endpoint] = entry
        }
        current = nil
        bootstrapMisses = 0
        persist()
    }

    @discardableResult
    public func merge(_ announcements: [GatewayAnnouncement]) -> Int {
        let now = clock()
        var added = 0
        for a in announcements where a.isAuthentic(now: now) {
            if var existing = cache[a.endpoint] {
                guard a.ts > existing.announcement.ts else { continue }
                let rekeyed = existing.announcement.certSha256 != a.certSha256 || existing.announcement.node != a.node
                if rekeyed {
                    existing.lastOK = nil
                }
                if rekeyed || a.ts > (existing.lastFailure ?? .min) {
                    existing.failures = 0
                    existing.lastFailure = nil
                }
                existing.announcement = a
                cache[a.endpoint] = existing
            } else {
                cache[a.endpoint] = CachedGateway(announcement: a, lastOK: nil, failures: 0)
                added += 1
            }
        }
        trim(now: now)
        persist()
        return added
    }

    static func cooldown(afterFailures failures: Int) -> Int64 {
        guard failures > 0 else { return 0 }
        return min(baseCooldown << min(failures - 1, 20), maxCooldown)
    }

    private func learn(from gateway: GatewayAnnouncement) async {
        if let more = try? await exchange(gateway) {
            merge(more)
        }
    }

    private func pickLocal() async -> Gateway? {
        let now = clock()
        let candidates = local.filter { g in
            guard let failed = localFailures[g.endpoint], now >= failed else { return true }
            return now - failed >= GatewayDirectory.localCooldown
        }
        guard !candidates.isEmpty else { return nil }
        let probe = self.localProbe
        let (winner, failed) = await withTaskGroup(of: (Gateway, Bool).self) { group -> (Gateway?, [Gateway]) in
            for g in candidates.prefix(GatewayDirectory.waveSize) {
                group.addTask { (g, await probe(g)) }
            }
            // Wait for every probe before returning: returning while some were still
            // running is the likeliest cause of the iOS 27.2 crash App Review hit.
            var winner: Gateway?
            var failed: [Gateway] = []
            while let (g, ok) = await group.next() {
                if winner == nil {
                    if ok {
                        winner = g
                        group.cancelAll()
                    } else {
                        failed.append(g)
                    }
                }
            }
            return (winner, failed)
        }
        // Only the ones that really didn't answer: a gateway that simply lost the
        // race is fine, and is what the phone asks for a second opinion.
        for g in failed {
            localFailures[g.endpoint] = now
        }
        return winner
    }

    private func pick() async -> GatewayAnnouncement? {
        if usable().isEmpty {
            await bootstrap()
        }
        if let found = await tryCandidates() {
            return found
        }
        if await bootstrap() {
            return await tryCandidates()
        }
        return nil
    }

    private func tryCandidates() async -> GatewayAnnouncement? {
        let candidates = Array(usable().prefix(GatewayDirectory.maxTries))
        var start = 0
        while start < candidates.count {
            let wave = Array(candidates[start..<min(start + GatewayDirectory.waveSize, candidates.count)])
            if let winner = await race(wave) {
                mark(winner.endpoint, ok: true)
                bootstrapMisses = 0
                return winner
            }
            for a in wave {
                mark(a.endpoint, ok: false)
            }
            start += GatewayDirectory.waveSize
        }
        return nil
    }

    private func race(_ wave: [GatewayAnnouncement]) async -> GatewayAnnouncement? {
        let probe = self.probe
        return await withTaskGroup(of: GatewayAnnouncement?.self) { group in
            for a in wave {
                group.addTask { await probe(a) ? a : nil }
            }
            // Wait for every probe before returning: returning while some were still
            // running is the likeliest cause of the iOS 27.2 crash App Review hit.
            var winner: GatewayAnnouncement?
            while let result = await group.next() {
                if winner == nil, let result {
                    winner = result
                    group.cancelAll()
                }
            }
            return winner
        }
    }

    private var bootstrapWait: Int64 {
        let misses = min(bootstrapMisses, 20)
        if cache.values.contains(where: { $0.lastOK != nil }) {
            return min(GatewayDirectory.bootstrapGap << misses, GatewayDirectory.maxBootstrapGap)
        }
        return min(GatewayDirectory.firstContactGap << misses, GatewayDirectory.firstContactMaxGap)
    }

    @discardableResult
    private func bootstrap() async -> Bool {
        let now = clock()
        if let last = lastBootstrap, now >= last, now - last < bootstrapWait { return false }
        lastBootstrap = now
        guard let fetched = try? await fetchBootstrap() else {
            bootstrapMisses += 1
            return false
        }
        merge(fetched)
        if usable().isEmpty {
            bootstrapMisses += 1
            return false
        }
        return true
    }

    private func usable() -> [GatewayAnnouncement] {
        let now = clock()
        return ranked().filter { !coolingDown($0, now: now) }.map(\.announcement)
    }

    private func coolingDown(_ entry: CachedGateway, now: Int64) -> Bool {
        guard entry.failures > 0, let last = entry.lastFailure, now >= last else { return false }
        return now - last < GatewayDirectory.cooldown(afterFailures: entry.failures)
    }

    private func ranked() -> [CachedGateway] {
        cache.values.sorted { a, b in
            if (a.lastOK ?? .min) != (b.lastOK ?? .min) { return (a.lastOK ?? .min) > (b.lastOK ?? .min) }
            if a.failures != b.failures { return a.failures < b.failures }
            if a.announcement.ts != b.announcement.ts { return a.announcement.ts > b.announcement.ts }
            return a.announcement.endpoint < b.announcement.endpoint
        }
    }

    private func mark(_ endpoint: String, ok: Bool) {
        guard var entry = cache[endpoint] else { return }
        if ok {
            entry.lastOK = clock()
            entry.failures = 0
            entry.lastFailure = nil
        } else {
            entry.failures += 1
            entry.lastFailure = clock()
        }
        cache[endpoint] = entry
        persist()
    }

    private func trim(now: Int64) {
        cache = cache.filter { _, entry in
            entry.failures == 0 || max(entry.lastOK ?? .min, entry.announcement.ts) > now - GatewayDirectory.forgetAfter
        }
        guard cache.count > GatewayDirectory.maxCached else { return }
        let keep = Set(ranked().prefix(GatewayDirectory.maxCached).map(\.announcement.endpoint))
        cache = cache.filter { keep.contains($0.key) }
    }

    private func persist() {
        store.save(ranked())
    }

    static func fetch(_ url: URL) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: url) { data, response, error in
                if let error {
                    continuation.resume(throwing: GatewayError.unreachable(error.localizedDescription))
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: GatewayError.badResponse)
                }
            }.resume()
        }
    }
}

extension GatewayClient {
    public func health() async throws -> Bool {
        var url = gateway.endpoint
        url.deleteLastPathComponent()
        url.appendPathComponent("health")
        struct Health: Decodable { let service: String }
        let data = try await get(url)
        return (try? JSONDecoder().decode(Health.self, from: data))?.service == "ego-gateway"
    }

    public func gatewayList() async throws -> [GatewayAnnouncement] {
        struct Listing: Decodable { let gateways: [GatewayAnnouncement] }
        let listing: Listing = try await call("gateway.list", Empty())
        return listing.gateways
    }
}
