import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum AccountRecordError: Error, Equatable {
    case notThisWallet
    case badRecord
    case badContactKey
}

public enum AccountRecord {
    public static let domain = "ego/account-record/v1"
    public static let deliverDomain = "ego/messenger-deliver/v1"
    public static let desktop = "desktop"
    public static let phone = "phone"
    public static let places = 4
    public static let maxSent = 300

    public struct Envelope: Codable, Equatable, Sendable {
        public let owner: String
        public let pubkey: String
        public let slot: String
        public let ver: Int64
        public let data: String
        public let sig: String
    }

    public struct Contact: Codable, Equatable, Identifiable, Sendable {
        public let address: String
        public let name: String
        public let ed25519: String
        public let sharedKeyHex: String
        public let endpoint: String

        public var id: String { address }

        public init(address: String, name: String, ed25519: String, sharedKeyHex: String, endpoint: String = "") {
            self.address = address
            self.name = name
            self.ed25519 = ed25519
            self.sharedKeyHex = sharedKeyHex
            self.endpoint = endpoint
        }

        enum CodingKeys: String, CodingKey {
            case address, name, ed25519, endpoint
            case sharedKeyHex = "shared_key_hex"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            address = try c.decode(String.self, forKey: .address)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            ed25519 = try c.decode(String.self, forKey: .ed25519)
            sharedKeyHex = try c.decode(String.self, forKey: .sharedKeyHex)
            endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        }
    }

    public struct File: Codable, Equatable, Identifiable, Sendable {
        public let cid: String
        public let name: String
        public let size: UInt64
        public let keyNonceHex: String
        public let storedAt: Int64
        public let received: Bool

        public var id: String { cid }

        public init(cid: String, name: String, size: UInt64, keyNonceHex: String, storedAt: Int64, received: Bool = false) {
            self.cid = cid
            self.name = name
            self.size = size
            self.keyNonceHex = keyNonceHex
            self.storedAt = storedAt
            self.received = received
        }

        enum CodingKeys: String, CodingKey {
            case cid, name, size, received
            case keyNonceHex = "key_nonce_hex"
            case storedAt = "stored_at"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            cid = try c.decode(String.self, forKey: .cid)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            size = try c.decodeIfPresent(UInt64.self, forKey: .size) ?? 0
            keyNonceHex = try c.decode(String.self, forKey: .keyNonceHex)
            storedAt = try c.decodeIfPresent(Int64.self, forKey: .storedAt) ?? 0
            received = try c.decodeIfPresent(Bool.self, forKey: .received) ?? false
        }

        public func shareLink(from address: String) -> String {
            "egoshare1:\(cid):\(keyNonceHex):\(Data(name.utf8).base64EncodedString()):\(address)"
        }

        public var isPicture: Bool {
            let lower = name.lowercased()
            return ["jpg", "jpeg", "png", "heic", "gif", "webp"].contains { lower.hasSuffix(".\($0)") }
        }
    }

    public struct Sent: Codable, Equatable, Identifiable, Sendable {
        public let id: String
        public let to: String
        public let content: String
        public let messageType: String
        public let ts: Int64

        public init(id: String, to: String, content: String, messageType: String, ts: Int64) {
            self.id = id
            self.to = to
            self.content = content
            self.messageType = messageType
            self.ts = ts
        }

        enum CodingKeys: String, CodingKey {
            case id, to, content, ts
            case messageType = "message_type"
        }
    }

    public struct Content: Codable, Equatable, Sendable {
        public var v: UInt32
        public var name: String
        public var bundle: String
        public var contacts: [Contact]
        public var files: [File]
        public var payments: [HistoryItem]
        public var sent: [Sent]
        public var wantHistory: Int64 = 0
        public var avatar: String = ""
        public var avatarAt: Int64 = 0
        public var token: String = ""

        public init(v: UInt32 = 1, name: String = "", bundle: String = "", contacts: [Contact] = [], files: [File] = [], payments: [HistoryItem] = [], sent: [Sent] = []) {
            self.v = v
            self.name = name
            self.bundle = bundle
            self.contacts = contacts
            self.files = files
            self.payments = payments
            self.sent = sent
        }

        enum CodingKeys: String, CodingKey {
            case v, name, bundle, contacts, files, payments, sent, avatar, token
            case wantHistory = "want_history"
            case avatarAt = "avatar_at"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            v = try c.decodeIfPresent(UInt32.self, forKey: .v) ?? 0
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            bundle = try c.decodeIfPresent(String.self, forKey: .bundle) ?? ""
            contacts = try c.decodeIfPresent([Contact].self, forKey: .contacts) ?? []
            files = try c.decodeIfPresent([File].self, forKey: .files) ?? []
            payments = try c.decodeIfPresent([HistoryItem].self, forKey: .payments) ?? []
            sent = try c.decodeIfPresent([Sent].self, forKey: .sent) ?? []
            wantHistory = try c.decodeIfPresent(Int64.self, forKey: .wantHistory) ?? 0
            avatar = try c.decodeIfPresent(String.self, forKey: .avatar) ?? ""
            avatarAt = try c.decodeIfPresent(Int64.self, forKey: .avatarAt) ?? 0
            token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        }
    }

    public struct Delivery: Encodable, Equatable, Sendable {
        public let owner: String
        public let pubkey: String
        public let ts: Int64
        public let to: String
        public let toEd25519: String
        public let bundle: String
        public let sig: String

        enum CodingKeys: String, CodingKey {
            case owner, pubkey, ts, to, bundle, sig
            case toEd25519 = "to_ed25519"
        }
    }

    public static func sha256Hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        Hex.encode(SHA256.hash(data: Data(bytes)))
    }

    public static func signingBytes(owner: String, slot: String, ver: Int64, data: String) -> [UInt8] {
        Array("\(domain)\n\(owner)\n\(slot)\n\(ver)\n\(sha256Hex(Array(data.utf8)))".utf8)
    }

    public static func deliverBytes(owner: String, to: String, ts: Int64, bundle: String) -> [UInt8] {
        Array("\(deliverDomain)\n\(owner)\n\(to)\n\(ts)\n\(sha256Hex(Array(bundle.utf8)))".utf8)
    }

    public static func recordKey(seed: [UInt8]) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data(Array("\(domain)/key\n".utf8) + seed)))
    }

    public static func seal(_ content: Content, with key: EgoKey, slot: String, ver: Int64) throws -> Envelope {
        let plain = try JSONEncoder().encode(content)
        let box = try AES.GCM.seal(plain, using: recordKey(seed: key.seed))
        guard let combined = box.combined else { throw AccountRecordError.badRecord }
        let data = combined.base64EncodedString()
        let owner = key.address
        let sig = try key.sign(signingBytes(owner: owner, slot: slot, ver: ver, data: data))
        return Envelope(owner: owner, pubkey: Hex.encode(key.publicKey), slot: slot, ver: ver, data: data, sig: Hex.encode(sig))
    }

    public static func isGenuine(_ envelope: Envelope, owner: String, slot: String) -> Bool {
        guard envelope.owner == owner, envelope.slot == slot, envelope.ver > 0,
              let pk = Hex.decode(envelope.pubkey), pk.count == 32,
              let sig = Hex.decode(envelope.sig), sig.count == 64,
              EgoAddress.from(publicKey: pk) == owner
        else { return false }
        return EgoKey.verify(signature: sig, message: signingBytes(owner: owner, slot: slot, ver: envelope.ver, data: envelope.data), publicKey: pk)
    }

    public static func open(_ envelope: Envelope, with key: EgoKey) throws -> Content {
        guard isGenuine(envelope, owner: key.address, slot: envelope.slot) else { throw AccountRecordError.notThisWallet }
        guard let combined = Data(base64Encoded: envelope.data) else { throw AccountRecordError.badRecord }
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let plain = try AES.GCM.open(box, using: recordKey(seed: key.seed))
            return try JSONDecoder().decode(Content.self, from: plain)
        } catch {
            throw AccountRecordError.notThisWallet
        }
    }

    public static func newest(_ candidates: [Envelope], owner: String, slot: String) -> Envelope? {
        candidates.filter { isGenuine($0, owner: owner, slot: slot) }.max { $0.ver < $1.ver }
    }

    public static func score(owner: String, node: String) -> [UInt8] {
        Array(SHA256.hash(data: Data("\(owner)\n\(node)".utf8)))
    }

    public static func places(owner: String, nodes: [String], count: Int = places) -> [String] {
        var seen = Set<String>()
        let unique = nodes.filter { seen.insert($0).inserted }
        let ranked = unique.map { ($0, score(owner: owner, node: $0)) }.sorted { a, b in
            a.1 != b.1 ? a.1.lexicographicallyPrecedes(b.1) == false : a.0 < b.0
        }
        return ranked.prefix(count).map { $0.0 }
    }

    public static func chatMessage(from: String, to: String, ts: Int64, type: String, text: String, sharedKeyHex: String) throws -> (bundle: String, id: String) {
        guard let raw = Hex.decode(sharedKeyHex), raw.count == 32 else { throw AccountRecordError.badContactKey }
        let nonceBytes = SecureRandom.bytes(12)
        let box = try AES.GCM.seal(Data(text.utf8), using: SymmetricKey(data: raw), nonce: try AES.GCM.Nonce(data: nonceBytes))
        let nonceHex = Hex.encode(nonceBytes)
        let ctHex = Hex.encode(box.ciphertext + box.tag)
        return ("egomsg1:\(from):\(to):\(ts):\(type):\(nonceHex):\(ctHex)", "\(ts)-\(nonceHex.prefix(8))")
    }

    public static func delivery(of bundle: String, to contact: Contact, ts: Int64, with key: EgoKey) throws -> Delivery {
        let sig = try key.sign(deliverBytes(owner: key.address, to: contact.address, ts: ts, bundle: bundle))
        return Delivery(owner: key.address, pubkey: Hex.encode(key.publicKey), ts: ts, to: contact.address,
                        toEd25519: contact.ed25519, bundle: bundle, sig: Hex.encode(sig))
    }
}

public extension GatewayClient {
    func accountRecord(owner: String, slot: String) async throws -> AccountRecord.Envelope? {
        struct Answer: Decodable { let record: AccountRecord.Envelope? }
        let answer: Answer = try await call("account.get", ["owner": owner, "slot": slot])
        return answer.record
    }

    func putAccountRecord(_ envelope: AccountRecord.Envelope) async throws {
        struct Params: Encodable { let record: AccountRecord.Envelope }
        struct Answer: Decodable { let stored: Bool }
        let _: Answer = try await call("account.put", Params(record: envelope), at: "storage")
    }

    func deliver(_ delivery: AccountRecord.Delivery) async throws {
        struct Answer: Decodable { let sent: Bool }
        let _: Answer = try await call("messenger.deliver", delivery)
    }
}
