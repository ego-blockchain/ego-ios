import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Ego Storage as Ego Desktop sells it: a plan bought with an EGOC payment to
/// the storage pool, read back from the chain, and files encrypted on the
/// device in 256 KB blocks before they go anywhere.
public enum EgoStorage {
    public static let poolAddress = "egot1storagefees000000000000000000000000000000"
    public static let freeBytes: UInt64 = 5_000_000_000
    /// A lapsed plan keeps its space this long, as on Ego Desktop.
    public static let graceSeconds: Int64 = 30 * 86_400
    public static let blockSize = 256 * 1024
    public static let maxFileBytes = 250 * 1024 * 1024

    public enum Billing: String, CaseIterable, Codable, Sendable {
        case monthly, annual

        public var seconds: Int64 { self == .annual ? 365 * 86_400 : 30 * 86_400 }
    }

    public struct Plan: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let gb: UInt64
        public let monthlyUsd: Double
        public let annualUsd: Double
        public var highlight = false

        public var bytes: UInt64 { gb * 1_000_000_000 }
        public func priceUsd(_ billing: Billing) -> Double { billing == .annual ? annualUsd : monthlyUsd }
        public var isFree: Bool { monthlyUsd == 0 }
    }

    /// The same plans and prices as Ego Desktop's Storage page.
    public static let plans: [Plan] = [
        Plan(id: "free", name: "Free", gb: 5, monthlyUsd: 0, annualUsd: 0),
        Plan(id: "basic", name: "Basic", gb: 50, monthlyUsd: 0.79, annualUsd: 7.90),
        Plan(id: "pro", name: "Pro", gb: 200, monthlyUsd: 1.99, annualUsd: 19.90, highlight: true),
        Plan(id: "max", name: "Max", gb: 1024, monthlyUsd: 4.99, annualUsd: 49.90),
    ]

    public struct Subscription: Equatable, Sendable {
        public let plan: Plan
        public let billing: Billing
        public let paidAt: Int64
        public let confirmed: Bool
        public let hash: String

        public var expiresAt: Int64 { paidAt + billing.seconds }
        public func active(now: Int64) -> Bool { now < expiresAt }
        public func inGrace(now: Int64) -> Bool { !active(now: now) && now < expiresAt + EgoStorage.graceSeconds }
    }

    /// The memo Ego Desktop writes, which is also how a plan is recognised on chain.
    public static func memo(for plan: Plan, billing: Billing) -> String {
        "Ego Storage \(plan.name) – \(billing.rawValue) (\(String(format: "$%.2f", plan.priceUsd(billing))))"
    }

    /// The latest plan payment from `address`, read the way Ego Desktop's quota check reads it.
    public static func subscription(in history: [HistoryItem], of address: String) -> Subscription? {
        let payments = history.filter {
            $0.from == address && $0.to == poolAddress && ($0.txType ?? "transfer") == "transfer"
                && ($0.memo ?? "").hasPrefix("Ego Storage ")
        }
        guard let latest = payments.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
        let memo = latest.memo ?? ""
        let plan = plans.last { !$0.isFree && memo.contains($0.name) } ?? plans[0]
        return Subscription(
            plan: plan,
            billing: memo.contains("annual") ? .annual : .monthly,
            paidAt: latest.timestamp,
            confirmed: latest.blockHeight != nil,
            hash: latest.hash
        )
    }

    /// Space the wallet may fill: a paid plan while it runs and through its grace period, else Free.
    public static func quotaBytes(_ subscription: Subscription?, now: Int64) -> UInt64 {
        guard let s = subscription, s.confirmed, now < s.expiresAt + graceSeconds else { return freeBytes }
        return max(s.plan.bytes, freeBytes)
    }

    /// A dollar price in µEGOC at `priceMicroUsd` per EGOC, never under 1 EGOC, as Ego Desktop rounds it.
    public static func priceUegoc(usd: Double, priceMicroUsd: UInt64) -> UInt64? {
        guard usd > 0, priceMicroUsd > 0 else { return nil }
        let uegoc = (usd * 1e12 / Double(priceMicroUsd)).rounded()
        guard uegoc.isFinite, uegoc < Double(UInt64.max) else { return nil }
        return max(1_000_000, UInt64(uegoc))
    }
}

public extension Transactions {
    /// Pays for a storage plan. The pool isn't an ordinary address, so it's named here rather than checked.
    static func storagePlan(
        key: EgoKey, plan: EgoStorage.Plan, billing: EgoStorage.Billing, amount: UInt64,
        nonce: UInt64, fee: UInt64, timestamp: Int64 = Int64(Date().timeIntervalSince1970)
    ) throws -> SignedTransaction {
        guard amount > 0, !plan.isFree else { throw TransactionError.zeroAmount }
        return try sign(key: key, to: EgoStorage.poolAddress, amount: amount, nonce: nonce, fee: fee,
                        memo: EgoStorage.memo(for: plan, billing: billing), txType: "transfer", timestamp: timestamp)
    }
}

// MARK: - Encrypted files

public enum StorageError: Error, Equatable, LocalizedError {
    case tooLarge
    case empty
    case missingBlock(String)
    case corrupt
    case badShareLink

    public var errorDescription: String? {
        switch self {
        case .tooLarge: return "Files can be up to 250 MB."
        case .empty: return "That file is empty."
        case .missingBlock: return "Part of this file isn't available yet. Try again shortly."
        case .corrupt: return "This file couldn't be decrypted. It may have been changed."
        case .badShareLink: return "That isn't an Ego share link."
        }
    }
}

/// One encrypted 256 KB piece of a file. Named after its encrypted bytes, so a
/// host can check it and learns nothing about the contents.
public struct StorageBlock: Equatable, Sendable {
    public let cid: String
    public let nonce: [UInt8]
    public let size: Int
    public let sealed: Data

    public static func cid(for sealed: Data) -> String { "egoblk1" + Hex.encode(Blake2s.hash(sealed)) }
}

/// The list of blocks that make up a file, in Ego Desktop's manifest format.
/// The file's name is left out: it stays in the owner's encrypted library.
public struct StorageManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let blockCid: String
        public let nonceHex: String
        public let size: Int
        public var commR: String = ""

        enum CodingKeys: String, CodingKey {
            case blockCid = "block_cid"
            case nonceHex = "nonce_hex"
            case size
            case commR = "comm_r"
        }
    }

    public var fileName: String = ""
    public let totalSize: Int
    public let blocks: [Entry]

    enum CodingKeys: String, CodingKey {
        case fileName = "file_name"
        case totalSize = "total_size"
        case blocks
    }

    public var data: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)) ?? Data()
    }

    public var cid: String { "egomfd1" + Hex.encode(Blake2s.hash(data)) }
}

public struct EncryptedFile: Sendable {
    public let manifest: StorageManifest
    public let key: [UInt8]
    public let blocks: [StorageBlock]
    public var cid: String { manifest.cid }
}

public enum FileCrypto {
    public static func encrypt(_ plaintext: Data) throws -> EncryptedFile {
        guard !plaintext.isEmpty else { throw StorageError.empty }
        guard plaintext.count <= EgoStorage.maxFileBytes else { throw StorageError.tooLarge }
        let key = SymmetricKey(size: .bits256)
        var blocks: [StorageBlock] = []
        var offset = plaintext.startIndex
        while offset < plaintext.endIndex {
            let end = plaintext.index(offset, offsetBy: EgoStorage.blockSize, limitedBy: plaintext.endIndex) ?? plaintext.endIndex
            let chunk = plaintext[offset..<end]
            let nonce = AES.GCM.Nonce()
            let box = try AES.GCM.seal(chunk, using: key, nonce: nonce)
            var sealed = Data(box.ciphertext)
            sealed.append(box.tag)
            blocks.append(StorageBlock(cid: StorageBlock.cid(for: sealed), nonce: Array(nonce), size: chunk.count, sealed: sealed))
            offset = end
        }
        let manifest = StorageManifest(
            totalSize: plaintext.count,
            blocks: blocks.map { .init(blockCid: $0.cid, nonceHex: Hex.encode($0.nonce), size: $0.size) }
        )
        return EncryptedFile(manifest: manifest, key: key.withUnsafeBytes { Array($0) }, blocks: blocks)
    }

    /// Reassembles a file from its blocks, checking every one.
    public static func decrypt(_ manifest: StorageManifest, key: [UInt8], block: (String) throws -> Data?) throws -> Data {
        let symmetric = SymmetricKey(data: key)
        var out = Data()
        out.reserveCapacity(manifest.totalSize)
        for entry in manifest.blocks {
            guard let fetched = try block(entry.blockCid) else { throw StorageError.missingBlock(entry.blockCid) }
            let sealed = Data(fetched)
            guard StorageBlock.cid(for: sealed) == entry.blockCid, sealed.count >= 16,
                  let nonceBytes = Hex.decode(entry.nonceHex), let nonce = try? AES.GCM.Nonce(data: nonceBytes)
            else { throw StorageError.corrupt }
            let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: sealed.prefix(sealed.count - 16), tag: sealed.suffix(16))
            guard let box, let plain = try? AES.GCM.open(box, using: symmetric), plain.count == entry.size else {
                throw StorageError.corrupt
            }
            out.append(plain)
        }
        guard out.count == manifest.totalSize else { throw StorageError.corrupt }
        return out
    }
}

/// An `egoshare1` link, the format Ego Desktop's "Copy link" makes: anyone who has it can open the file.
public struct EgoShareLink: Equatable, Sendable {
    public let cid: String
    public let key: [UInt8]
    public let name: String
    public let from: String

    public init(cid: String, key: [UInt8], name: String, from: String) {
        self.cid = cid
        self.key = key
        self.name = name
        self.from = from
    }

    public var text: String {
        "egoshare1:\(cid):\(Hex.encode(key)):\(Data(name.utf8).base64EncodedString()):\(from)"
    }

    public init(parsing text: String) throws {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "egoshare1", parts[1].hasPrefix("egomfd1"),
              let key = Hex.decode(String(parts[2])), key.count >= 32,
              let nameData = Data(base64Encoded: String(parts[3])),
              let name = String(data: nameData, encoding: .utf8)
        else { throw StorageError.badShareLink }
        self.init(cid: String(parts[1]), key: Array(key.prefix(32)), name: name, from: String(parts[4]))
    }
}

// MARK: - The owner's file library

public struct LibraryFile: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case photo, video, document

        public static func of(name: String) -> Kind {
            switch (name as NSString).pathExtension.lowercased() {
            case "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "bmp", "dng", "raw": return .photo
            case "mov", "mp4", "m4v", "avi", "mkv", "webm", "3gp", "hevc": return .video
            default: return .document
            }
        }
    }

    public enum State: String, Codable, Sendable {
        /// Encrypted and kept on this iPhone until a gateway takes it.
        case waiting
        /// On the Ego network.
        case stored
    }

    public let cid: String
    public var name: String
    public let size: Int
    public let kind: Kind
    public let addedAt: Int64
    public let keyHex: String
    public let manifest: StorageManifest
    public var state: State
    /// A small JPEG preview for photos and videos, kept inside the sealed library.
    public var thumbnail: Data?

    public var id: String { cid }
    public var key: [UInt8] { Hex.decode(keyHex) ?? [] }

    public init(file: EncryptedFile, name: String, addedAt: Int64 = Int64(Date().timeIntervalSince1970)) {
        cid = file.cid
        self.name = name
        size = file.manifest.totalSize
        kind = Kind.of(name: name)
        self.addedAt = addedAt
        keyHex = Hex.encode(file.key)
        manifest = file.manifest
        state = .waiting
    }
}

/// The wallet's files: names, sizes and keys, sealed with a key derived from
/// the wallet seed so only this wallet can read it, on any device.
public struct FileLibrary {
    public private(set) var files: [LibraryFile]
    private let url: URL
    private let key: SymmetricKey

    public static func indexKey(seed: [UInt8]) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: seed),
                               info: Data("ego/storage-library/v1".utf8), outputByteCount: 32)
    }

    public init(url: URL, seed: [UInt8]) {
        self.url = url
        key = FileLibrary.indexKey(seed: seed)
        if let data = try? Data(contentsOf: url),
           let box = try? AES.GCM.SealedBox(combined: data),
           let plain = try? AES.GCM.open(box, using: key),
           let files = try? JSONDecoder().decode([LibraryFile].self, from: plain) {
            self.files = files
        } else {
            files = []
        }
    }

    public var usedBytes: UInt64 { files.reduce(0) { $0 + UInt64($1.size) } }

    public mutating func add(_ file: LibraryFile) throws {
        files.removeAll { $0.cid == file.cid }
        files.insert(file, at: 0)
        try save()
    }

    public mutating func update(_ file: LibraryFile) throws {
        guard let i = files.firstIndex(where: { $0.cid == file.cid }) else { return }
        files[i] = file
        try save()
    }

    public mutating func remove(_ cid: String) throws {
        files.removeAll { $0.cid == cid }
        try save()
    }

    private func save() throws {
        let plain = try JSONEncoder().encode(files)
        guard let sealed = try AES.GCM.seal(plain, using: key).combined else { throw StorageError.corrupt }
        #if os(iOS)
        try sealed.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try sealed.write(to: url, options: .atomic)
        #endif
    }
}
