import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum Messenger {
    public static let getDomain = "ego/mail-get/v1"
    public static let editWindow: Int64 = 3_600
    public static let maxSeq: UInt64 = 1_000_000
    public struct Reaction: Hashable, Sendable {
        public let code: String
        public let emoji: String
    }

    public static let reactions: [Reaction] = [
        Reaction(code: "like", emoji: "👍"),
        Reaction(code: "dislike", emoji: "👎"),
        Reaction(code: "thanks", emoji: "🙏"),
        Reaction(code: "heart", emoji: "❤️"),
    ]

    public static func emoji(for code: String) -> String {
        reactions.first { $0.code == code }?.emoji ?? code
    }

    public struct Sealed: Codable, Equatable, Sendable {
        public let to: String
        public let ephPub: String
        public let nonce: String
        public let ct: String
        public let id: String

        public init(to: String, ephPub: String, nonce: String, ct: String, id: String) {
            self.to = to
            self.ephPub = ephPub
            self.nonce = nonce
            self.ct = ct
            self.id = id
        }

        enum CodingKeys: String, CodingKey {
            case to, nonce, ct, id
            case ephPub = "eph_pub"
        }
    }

    public struct Kept: Decodable, Equatable, Sendable {
        public let sealed: Sealed
        public let at: Int64

        enum CodingKeys: String, CodingKey { case at }

        public init(sealed: Sealed, at: Int64) {
            self.sealed = sealed
            self.at = at
        }

        public init(from decoder: Decoder) throws {
            sealed = try Sealed(from: decoder)
            at = try decoder.container(keyedBy: CodingKeys.self).decode(Int64.self, forKey: .at)
        }
    }

    public struct HistoryReaction: Decodable, Equatable, Sendable {
        public let emoji: String
        public let from: String
    }

    public struct HistoryMessage: Decodable, Equatable, Sendable {
        public let id: String
        public let from: String
        public let to: String
        public let ts: Int64
        public let type: String
        public let content: String
        public let replyTo: String?
        public let reactions: [HistoryReaction]
        public let editedAt: Int64?
        public let delivered: Bool
        public let read: Bool

        enum CodingKeys: String, CodingKey {
            case id, from, to, ts, type, content, reactions, delivered, read
            case replyTo = "reply_to"
            case editedAt = "edited_at"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            from = try c.decode(String.self, forKey: .from)
            to = try c.decode(String.self, forKey: .to)
            ts = try c.decode(Int64.self, forKey: .ts)
            type = try c.decodeIfPresent(String.self, forKey: .type) ?? "text"
            content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
            replyTo = try c.decodeIfPresent(String.self, forKey: .replyTo)
            reactions = (try? c.decodeIfPresent([HistoryReaction].self, forKey: .reactions)) ?? []
            editedAt = try c.decodeIfPresent(Int64.self, forKey: .editedAt)
            delivered = try c.decodeIfPresent(Bool.self, forKey: .delivered) ?? false
            read = try c.decodeIfPresent(Bool.self, forKey: .read) ?? false
        }
    }

    public struct HistoryProfile: Decodable, Equatable, Sendable {
        public let address: String
        public let name: String?
        public let avatar: String?
    }

    public struct Inner: Decodable, Equatable, Sendable {
        public let type: String
        public let bundle: String?
        public let seq: UInt64?
        public let fromAddr: String?
        public let fromName: String?
        public let fromEd25519: String?
        public let fromSharedKey: String?
        public let fromEndpoint: String?
        public let bundleToken: String?
        public let approved: Bool?
        public let sharedKey: String?
        public let avatar: String?
        public let from: String?
        public let to: String?
        public let messageIds: [String]?
        public let messages: [HistoryMessage]?
        public let profiles: [HistoryProfile]?

        enum CodingKeys: String, CodingKey {
            case type, bundle, seq, approved, avatar, from, to, messages, profiles
            case fromAddr = "from_addr"
            case fromName = "from_name"
            case fromEd25519 = "from_ed25519"
            case fromSharedKey = "from_shared_key"
            case fromEndpoint = "from_endpoint"
            case bundleToken = "bundle_token"
            case sharedKey = "shared_key"
            case messageIds = "message_ids"
        }
    }

    public enum Outgoing {
        public static func contactRequest(from: String, name: String, ed25519Hex: String, sharedKeyHex: String, token: String) -> [String: Any] {
            ["type": "contact_request", "from_addr": from, "from_name": name, "from_ed25519": ed25519Hex, "from_kyber": "",
             "from_shared_key": sharedKeyHex, "from_endpoint": "", "bundle_token": token.isEmpty ? NSNull() : token]
        }

        public static func contactResponse(from: String, name: String, ed25519Hex: String, approved: Bool, sharedKeyHex: String) -> [String: Any] {
            ["type": "contact_response", "from_addr": from, "from_name": name, "from_ed25519": ed25519Hex, "from_kyber": "",
             "approved": approved, "shared_key": sharedKeyHex, "from_endpoint": ""]
        }

        public static func receipt(read: Bool, from: String, to: String, ids: [String]) -> [String: Any] {
            ["type": read ? "read_receipt" : "delivery_receipt", "from": from, "to": to, "message_ids": ids]
        }

        public static func profile(from: String, avatar: String) -> [String: Any] {
            ["type": "profile_update", "from_addr": from, "avatar": avatar]
        }

        public static func data(_ fields: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        }
    }

    public struct Bundle: Equatable, Sendable {
        public let from: String
        public let to: String
        public let ts: Int64
        public let type: String
        public let nonceHex: String
        public let ctHex: String

        public var id: String { "\(ts)-\(nonceHex.prefix(8))" }

        public init?(parsing text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("egomsg1:") else { return nil }
            let parts = trimmed.dropFirst("egomsg1:".count).split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 6, let ts = Int64(parts[2]), parts[4].count >= 8 else { return nil }
            from = parts[0]
            to = parts[1]
            self.ts = ts
            type = parts[3]
            nonceHex = parts[4]
            ctHex = parts[5]
        }
    }

    public static func agreementKey(seed: [UInt8]) throws -> Curve25519.KeyAgreement.PrivateKey {
        let expanded = Array(SHA512.hash(data: Data(seed.prefix(32))))
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(expanded.prefix(32)))
    }

    static func aesOpen(key: [UInt8], nonce: [UInt8], sealed: [UInt8]) -> Data? {
        guard key.count == 32, nonce.count == 12, sealed.count >= 16,
              let n = try? AES.GCM.Nonce(data: Data(nonce)),
              let box = try? AES.GCM.SealedBox(nonce: n, ciphertext: Data(sealed.dropLast(16)), tag: Data(sealed.suffix(16)))
        else { return nil }
        return try? AES.GCM.open(box, using: SymmetricKey(data: key))
    }

    public static func open(_ sealed: Sealed, seed: [UInt8]) -> Inner? {
        guard let eph = Hex.decode(sealed.ephPub), eph.count == 32,
              let nonce = Hex.decode(sealed.nonce),
              let ct = Hex.decode(sealed.ct),
              let mine = try? agreementKey(seed: seed),
              let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(eph)),
              let shared = try? mine.sharedSecretFromKeyAgreement(with: theirs)
        else { return nil }
        let raw = shared.withUnsafeBytes { Array($0) }
        let key = Blake3.deriveKey(context: "ego dm seal v1", material: raw)
        guard let plain = aesOpen(key: key, nonce: nonce, sealed: ct) else { return nil }
        return try? JSONDecoder().decode(Inner.self, from: plain)
    }

    public static func publicKey(ed25519 text: String) -> [UInt8]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw = Hex.decode(trimmed), raw.count == 32 { return raw }
        if let data = Data(base64Encoded: trimmed), data.count == 32 { return Array(data) }
        return nil
    }

    public static func seal(_ plaintext: Data, to: String, ed25519: [UInt8]) throws -> Sealed {
        guard let x = Field25519.montgomery(fromEdwards: ed25519) else { throw MessengerError.badKey }
        let theirs = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(x))
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let shared = try eph.sharedSecretFromKeyAgreement(with: theirs)
        let raw = shared.withUnsafeBytes { Array($0) }
        let key = Blake3.deriveKey(context: "ego dm seal v1", material: raw)
        let nonce = SecureRandom.bytes(12)
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: Data(nonce)))
        let ctHex = Hex.encode(Array(box.ciphertext) + Array(box.tag))
        let id = Hex.encode(Array(Blake3.hash(Array(ctHex.utf8)).prefix(16)))
        return Sealed(to: to, ephPub: Hex.encode(Array(eph.publicKey.rawRepresentation)), nonce: Hex.encode(nonce), ct: ctHex, id: id)
    }

    public static func sendBytes(by: String, to: String, ts: Int64, id: String) -> [UInt8] {
        Array("ego/mail-send/v1\n\(by)\n\(to)\n\(ts)\n\(id)".utf8)
    }

    public struct ContactCard: Equatable, Sendable {
        public let address: String
        public let ed25519: [UInt8]
        public let name: String
        public let endpoint: String
        public let token: String

        public init(address: String, ed25519: [UInt8], name: String, endpoint: String, token: String) {
            self.address = address
            self.ed25519 = ed25519
            self.name = name
            self.endpoint = endpoint
            self.token = token
        }

        public init?(parsing text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("egocontact1:") else { return nil }
            let parts = trimmed.dropFirst("egocontact1:".count).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4, parts[0].hasPrefix("ego"), parts[0].count <= 90,
                  let ed = Data(base64Encoded: parts[1]), ed.count == 32 else { return nil }
            func decoded(_ b64: String) -> String {
                Data(base64Encoded: b64).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            }
            address = parts[0]
            ed25519 = Array(ed)
            name = decoded(parts[2])
            endpoint = decoded(parts[3])
            token = parts.count > 4 ? parts[4] : ""
        }

        public var text: String {
            "egocontact1:\(address):\(Data(ed25519).base64EncodedString()):\(Data(name.utf8).base64EncodedString()):\(Data(endpoint.utf8).base64EncodedString()):\(token)"
        }
    }

    public static func chain(shared: [UInt8], sending: Bool, me: String, peer: String) -> [UInt8] {
        let lowerIsMine = Array(me.utf8).lexicographicallyPrecedes(Array(peer.utf8))
        return Blake3.deriveKey(context: lowerIsMine == sending ? "ego ratchet chain-1 v1" : "ego ratchet chain-2 v1", material: shared)
    }

    public static func next(_ chain: [UInt8]) -> [UInt8] {
        Blake3.deriveKey(context: "ego chain next v1", material: chain)
    }

    public static func messageKey(_ chain: [UInt8]) -> [UInt8] {
        Blake3.deriveKey(context: "ego msg key v1", material: chain)
    }

    public static func messageKey(shared: [UInt8], sending: Bool, me: String, peer: String, seq: UInt64) -> [UInt8]? {
        guard seq > 0, seq <= maxSeq else { return nil }
        var c = chain(shared: shared, sending: sending, me: me, peer: peer)
        for _ in 1..<seq { c = next(c) }
        return messageKey(c)
    }

    public static func decrypt(_ bundle: Bundle, seq: UInt64, me: String, sharedKeyHex: String, ratchet: RatchetCache? = nil) -> String? {
        guard let shared = Hex.decode(sharedKeyHex), shared.count == 32,
              let nonce = Hex.decode(bundle.nonceHex),
              let ct = Hex.decode(bundle.ctHex) else { return nil }
        let sending = bundle.from == me
        let peer = sending ? bundle.to : bundle.from
        if seq > 0 {
            let key = ratchet?.key(shared: shared, sending: sending, me: me, peer: peer, seq: seq)
                ?? messageKey(shared: shared, sending: sending, me: me, peer: peer, seq: seq)
            if let key, let plain = aesOpen(key: key, nonce: nonce, sealed: ct) {
                return String(data: plain, encoding: .utf8)
            }
        }
        return aesOpen(key: shared, nonce: nonce, sealed: ct).flatMap { String(data: $0, encoding: .utf8) }
    }

    public enum Body: Equatable, Sendable {
        case text(String)
        case reply(text: String, to: String)
        case reaction(target: String, code: String, remove: Bool)
        case edit(target: String, text: String)
        case file(String)
        case other(type: String, content: String)
    }

    struct ReplyBody: Codable { let reply_to: String; let text: String }
    struct ReactBody: Codable { let target: String; let emoji: String; var remove: Bool? }
    struct EditBody: Codable { let target: String; let text: String }

    public static func body(type: String, content: String) -> Body {
        let data = Data(content.utf8)
        switch type {
        case "text": return .text(content)
        case "reply":
            if let b = try? JSONDecoder().decode(ReplyBody.self, from: data) { return .reply(text: b.text, to: b.reply_to) }
            return .text(content)
        case "reaction":
            if let b = try? JSONDecoder().decode(ReactBody.self, from: data) { return .reaction(target: b.target, code: b.emoji, remove: b.remove ?? false) }
        case "edit":
            if let b = try? JSONDecoder().decode(EditBody.self, from: data) { return .edit(target: b.target, text: b.text) }
        case "file_bundle": return .file(content)
        default: break
        }
        return .other(type: type, content: content)
    }

    public static func encode(_ body: Body) -> (type: String, content: String) {
        func json<T: Encodable>(_ value: T) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }
        switch body {
        case .text(let t): return ("text", t)
        case .reply(let t, let to): return ("reply", json(ReplyBody(reply_to: to, text: t)))
        case .reaction(let target, let code, let remove): return ("reaction", json(ReactBody(target: target, emoji: code, remove: remove)))
        case .edit(let target, let text): return ("edit", json(EditBody(target: target, text: text)))
        case .file(let link): return ("file_bundle", link)
        case .other(let type, let content): return (type, content)
        }
    }

    public static func getBytes(owner: String, ts: Int64) -> [UInt8] {
        Array("\(getDomain)\n\(owner)\n\(ts)".utf8)
    }

    public struct AITurn: Codable, Equatable, Sendable {
        public let role: String
        public let content: String

        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }
}

public enum MessengerError: Error, Equatable {
    case badKey
}

public enum Field25519 {
    typealias Fe = [UInt64]

    static let p: Fe = [0xFFFF_FFFF_FFFF_FFED, 0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF, 0x7FFF_FFFF_FFFF_FFFF]
    static let twoP: Fe = [0xFFFF_FFFF_FFFF_FFDA, 0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF]
    static let one: Fe = [1, 0, 0, 0]

    static func load(_ bytes: [UInt8]) -> Fe {
        (0..<4).map { i in
            (0..<8).reduce(UInt64(0)) { acc, j in acc | UInt64(bytes[i * 8 + j]) << (8 * UInt64(j)) }
        }
    }

    static func store(_ a: Fe) -> [UInt8] {
        let x = freeze(a)
        return (0..<32).map { i in UInt8(truncatingIfNeeded: x[i / 8] >> (8 * UInt64(i % 8))) }
    }

    static func less(_ a: Fe, _ b: Fe) -> Bool {
        for i in stride(from: 3, through: 0, by: -1) where a[i] != b[i] {
            return a[i] < b[i]
        }
        return false
    }

    static func subRaw(_ a: Fe, _ b: Fe) -> Fe {
        var out = Fe(repeating: 0, count: 4)
        var borrow: UInt64 = 0
        for i in 0..<4 {
            let (d1, o1) = a[i].subtractingReportingOverflow(b[i])
            let (d2, o2) = d1.subtractingReportingOverflow(borrow)
            out[i] = d2
            borrow = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return out
    }

    static func freeze(_ a: Fe) -> Fe {
        var x = a
        while !less(x, p) { x = subRaw(x, p) }
        return x
    }

    static func fold(_ r: Fe, _ carry: UInt64) -> Fe {
        var out = r
        var extra = carry
        while extra != 0 {
            var c = extra &* 38
            extra = 0
            for i in 0..<4 {
                let (s, o) = out[i].addingReportingOverflow(c)
                out[i] = s
                c = o ? 1 : 0
                if c == 0 { break }
            }
            extra = c
        }
        return out
    }

    static func add(_ a: Fe, _ b: Fe) -> Fe {
        var out = Fe(repeating: 0, count: 4)
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (s1, o1) = a[i].addingReportingOverflow(b[i])
            let (s2, o2) = s1.addingReportingOverflow(carry)
            out[i] = s2
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return fold(out, carry)
    }

    static func sub(_ a: Fe, _ b: Fe) -> Fe {
        add(a, subRaw(twoP, freeze(b)))
    }

    static func mul(_ a: Fe, _ b: Fe) -> Fe {
        var t = [UInt64](repeating: 0, count: 8)
        for i in 0..<4 {
            var carry: UInt64 = 0
            for j in 0..<4 {
                let (hi, lo) = a[i].multipliedFullWidth(by: b[j])
                let (s1, o1) = t[i + j].addingReportingOverflow(lo)
                let (s2, o2) = s1.addingReportingOverflow(carry)
                t[i + j] = s2
                carry = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
            }
            t[i + 4] = carry
        }
        var out = Fe(repeating: 0, count: 4)
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (hi, lo) = t[i + 4].multipliedFullWidth(by: 38)
            let (s1, o1) = t[i].addingReportingOverflow(lo)
            let (s2, o2) = s1.addingReportingOverflow(carry)
            out[i] = s2
            carry = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
        }
        return fold(out, carry)
    }

    static func invert(_ a: Fe) -> Fe {
        let e = subRaw(p, [2, 0, 0, 0])
        var result = one
        for bit in stride(from: 254, through: 0, by: -1) {
            result = mul(result, result)
            if (e[bit / 64] >> UInt64(bit % 64)) & 1 == 1 { result = mul(result, a) }
        }
        return result
    }

    public static func montgomery(fromEdwards ed: [UInt8]) -> [UInt8]? {
        guard ed.count == 32 else { return nil }
        var bytes = ed
        bytes[31] &= 0x7F
        let y = freeze(load(bytes))
        let den = sub(one, y)
        guard freeze(den) != [0, 0, 0, 0] else { return nil }
        return store(mul(add(one, y), invert(den)))
    }
}

public final class RatchetCache: @unchecked Sendable {
    private var entries: [String: (seq: UInt64, chain: [UInt8])] = [:]
    private let lock = NSLock()

    public init() {}

    public func key(shared: [UInt8], sending: Bool, me: String, peer: String, seq: UInt64) -> [UInt8]? {
        guard seq > 0, seq <= Messenger.maxSeq else { return nil }
        let id = "\(Hex.encode(shared))|\(sending)|\(me)|\(peer)"
        lock.lock()
        let cached = entries[id]
        lock.unlock()
        var n: UInt64 = 1
        var c = Messenger.chain(shared: shared, sending: sending, me: me, peer: peer)
        if let cached, cached.seq <= seq {
            n = cached.seq
            c = cached.chain
        }
        while n < seq {
            c = Messenger.next(c)
            n += 1
        }
        lock.lock()
        if (entries[id]?.seq ?? 0) < seq { entries[id] = (seq, c) }
        lock.unlock()
        return Messenger.messageKey(c)
    }
}

public extension GatewayClient {
    func mail(for key: EgoKey, since: Int64) async throws -> (mail: [Messenger.Kept], more: Bool) {
        struct Params: Encodable {
            let owner: String
            let ts: Int64
            let since: Int64
            let pubkey: String
            let sig: String
        }
        struct Answer: Decodable {
            let mail: [Messenger.Kept]
            let more: Bool?
        }
        let ts = Int64(Date().timeIntervalSince1970)
        let sig = try key.sign(Messenger.getBytes(owner: key.address, ts: ts))
        let answer: Answer = try await call("mail.get", Params(owner: key.address, ts: ts, since: since, pubkey: Hex.encode(key.publicKey), sig: Hex.encode(sig)))
        return (answer.mail, answer.more ?? false)
    }

    func sendMail(_ sealed: Messenger.Sealed, with key: EgoKey) async throws {
        struct Params: Encodable {
            let mail: Messenger.Sealed
            let by: String
            let ts: Int64
            let pubkey: String
            let sig: String
        }
        struct Answer: Decodable { let sent: Bool }
        let ts = Int64(Date().timeIntervalSince1970)
        let sig = try key.sign(Messenger.sendBytes(by: key.address, to: sealed.to, ts: ts, id: sealed.id))
        let _: Answer = try await call("mail.send", Params(mail: sealed, by: key.address, ts: ts, pubkey: Hex.encode(key.publicKey), sig: Hex.encode(sig)), at: "storage")
    }

    func askEgoAI(_ question: String, history: [Messenger.AITurn]) async throws -> String {
        struct Params: Encodable {
            let question: String
            let history: [Messenger.AITurn]
        }
        struct Answer: Decodable { let answer: String }
        let answer: Answer = try await call("ai.ask", Params(question: question, history: history))
        return answer.answer
    }
}
