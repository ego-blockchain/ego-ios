import Foundation
#if canImport(EgoWalletCore)
import EgoWalletCore
#endif

/// Shielded EGOC, as in Ego Desktop: notes of fixed sizes derived from the
/// seed, found by asking a gateway which commitments are in the pool, and
/// spent with a STARK proof made on the phone (ego-wallet-core).
public enum Shielded {
    public static let poolAddress = "egot1shieldedpool000000000000000000000000000"
    public static let domains = ["desktop", "ext", "ios"]
    public static let phoneDomain = "ios"
    /// Notes are looked for until this many indices in a row are unused, as on Ego Desktop.
    public static let recoveryGap = 20
    public static let maxSpends = 16
    public static let denominations: [UInt64] = [1_000_000, 10_000_000, 100_000_000, 1_000_000_000, 10_000_000_000]

    public struct Note: Identifiable, Equatable, Sendable {
        public let domain: String
        public let index: UInt32
        public let commitment: String
        public let nullifier: String
        public let leafIndex: Int
        public let value: UInt64
        public let spent: Bool
        public var id: String { commitment }
    }

    public struct Pool: Sendable {
        public let leaves: [String]
        public let feeUegoc: UInt64
    }

    public struct DepositPlan: Equatable, Sendable {
        public struct Item: Equatable, Sendable {
            public let value: UInt64
            public let index: UInt32
            public let memo: String
        }
        public let notes: [Item]
        public let remainder: UInt64
    }

    public struct Withdrawal: Sendable {
        public let hash: String
        public let callArgs: String
        public let to: String
        public let amount: UInt64
        public let fee: UInt64
    }

    public static func denominate(_ amount: UInt64) -> (notes: [UInt64], remainder: UInt64) {
        var left = amount
        var notes: [UInt64] = []
        for d in denominations.reversed() {
            while left >= d {
                notes.append(d)
                left -= d
            }
        }
        return (notes, left)
    }

    /// Every leaf in the pool, page by page.
    public static func pool(using client: GatewayClient) async throws -> Pool {
        var leaves: [String] = []
        var fee: UInt64 = 0
        while true {
            let page = try await client.shieldedLeaves(from: leaves.count)
            leaves += page.leaves
            fee = page.feeUegoc
            if page.leaves.isEmpty || leaves.count >= page.nextIndex { break }
        }
        return Pool(leaves: leaves, feeUegoc: fee)
    }

    /// This wallet's notes in every domain, with their values and whether they're spent.
    public static func scan(seed: [UInt8], pool: Pool, using client: GatewayClient) async throws -> [Note] {
        var found: [Note] = []
        for domain in domains {
            var from: UInt32 = 0
            var misses = 0
            while misses < recoveryGap {
                let batch = try call("notes", seed: seed, request: ["domain": domain, "from": from, "count": recoveryGap])
                guard let ids = batch as? [[String: Any]] else { throw Presale.Failure.library("Bad note list.") }
                let commitments = ids.compactMap { $0["commitment"] as? String }
                let nullifiers = ids.compactMap { $0["nullifier"] as? String }
                let lookup = try await client.shieldedLookup(commitments: commitments, nullifiers: nullifiers)
                for (i, id) in ids.enumerated() {
                    guard i < lookup.leafIndexes.count, let leafIndex = lookup.leafIndexes[i], leafIndex < pool.leaves.count else {
                        misses += 1
                        if misses >= recoveryGap { break }
                        continue
                    }
                    misses = 0
                    let values = try call("values", seed: seed, request: ["pairs": [[commitments[i], pool.leaves[leafIndex]]]]) as? [Any]
                    guard let value = (values?.first as? NSNumber)?.uint64Value else { continue }
                    found.append(Note(
                        domain: domain, index: (id["index"] as? NSNumber)?.uint32Value ?? 0,
                        commitment: commitments[i], nullifier: nullifiers[i],
                        leafIndex: leafIndex, value: value, spent: i < lookup.spent.count && lookup.spent[i]
                    ))
                }
                from += UInt32(recoveryGap)
            }
        }
        return found
    }

    /// The notes to deposit for `amount` µEGOC, using phone-domain indices after the last one used.
    public static func planDeposit(seed: [UInt8], amount: UInt64, notes: [Note]) throws -> DepositPlan {
        let next = (notes.filter { $0.domain == phoneDomain }.map(\.index).max()).map { $0 + 1 } ?? 0
        guard let plan = try call("deposit", seed: seed, request: ["amount_uegoc": amount, "start_index": next]) as? [String: Any],
              let items = plan["notes"] as? [[String: Any]] else { throw Presale.Failure.library("Bad deposit plan.") }
        return DepositPlan(
            notes: items.map { DepositPlan.Item(
                value: ($0["value_uegoc"] as? NSNumber)?.uint64Value ?? 0,
                index: ($0["index"] as? NSNumber)?.uint32Value ?? 0,
                memo: $0["memo"] as? String ?? ""
            ) },
            remainder: (plan["remainder_uegoc"] as? NSNumber)?.uint64Value ?? 0
        )
    }

    /// Proves the chosen notes against the pool. Takes a second or more per note.
    public static func prove(seed: [UInt8], notes: [Note], pool: Pool, recipient: String) throws -> Withdrawal {
        let spends = notes.map { ["domain": $0.domain, "index": $0.index, "value_uegoc": $0.value, "leaf_index": $0.leafIndex] as [String: Any] }
        guard let w = try call("unshield", seed: seed, request: [
            "leaves": pool.leaves, "spends": spends, "recipient": recipient, "fee_uegoc": pool.feeUegoc,
        ]) as? [String: Any], let hash = w["hash"] as? String, let args = w["call_args"] as? String else {
            throw Presale.Failure.library("Couldn't build the withdrawal.")
        }
        return Withdrawal(
            hash: hash, callArgs: args, to: recipient,
            amount: (w["amount_uegoc"] as? NSNumber)?.uint64Value ?? 0,
            fee: (w["fee_uegoc"] as? NSNumber)?.uint64Value ?? 0
        )
    }

    /// The transaction a gateway's tx.submit takes: from the pool, unsigned, proofs in call_args.
    public static func transaction(_ w: Withdrawal, now: Int64 = Int64(Date().timeIntervalSince1970)) -> [String: Any] {
        let amount = Double(w.amount) / 1_000_000, fee = Double(w.fee) / 1_000_000
        return [
            "hash": w.hash, "from": poolAddress, "to": w.to, "amount": w.amount, "memo": NSNull(),
            "timestamp": now, "signature": "", "status": "Pending", "block_height": NSNull(),
            "tx_type": "unshield", "fee_uegoc": w.fee, "call_args": w.callArgs,
            "signed_summary": String(format: "Unshield %.6f EGOC\n  To:      %@\n  Fee:     %.6f EGOC\n  Payout:  %.6f EGOC", amount, w.to, fee, amount - fee),
        ]
    }

    static func call(_ kind: String, seed: [UInt8], request: [String: Any]) throws -> Any {
        #if canImport(EgoWalletCore)
        let body = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let json: String = seed.withUnsafeBufferPointer { buffer in
            kind.withCString { k in
                body.withCString { b in
                    guard let raw = ego_wallet_shielded(k, buffer.baseAddress, buffer.count, b) else { return "" }
                    defer { ego_wallet_string_free(raw) }
                    return String(cString: raw)
                }
            }
        }
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
        if let dict = object as? [String: Any], dict.count == 1, let error = dict["error"] as? String {
            throw Presale.Failure.library(error)
        }
        return object
        #else
        throw ExternalWalletError.unavailable
        #endif
    }
}

public struct ShieldedLeavesPage: Decodable, Sendable {
    public let leaves: [String]
    public let nextIndex: Int
    public let feeUegoc: UInt64
    enum CodingKeys: String, CodingKey {
        case leaves
        case nextIndex = "next_index"
        case feeUegoc = "fee_uegoc"
    }
}

public struct ShieldedLookup: Decodable, Sendable {
    public let leafIndexes: [Int?]
    public let spent: [Bool]
    enum CodingKeys: String, CodingKey {
        case leafIndexes = "leaf_indexes"
        case spent
    }
}

extension GatewayClient {
    public func shieldedLeaves(from: Int, limit: Int = 5_000) async throws -> ShieldedLeavesPage {
        try await call("shielded.leaves", ["from": from, "limit": limit])
    }

    public func shieldedLookup(commitments: [String], nullifiers: [String]) async throws -> ShieldedLookup {
        try await call("shielded.lookup", ["commitments": commitments, "nullifiers": nullifiers])
    }
}

/// Any JSON value, so a dictionary can go through the typed RPC call.
enum AnyJSON: Encodable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case array([AnyJSON])
    case object([String: AnyJSON])

    init(_ value: Any) {
        switch value {
        case is NSNull: self = .null
        case let v as Bool where type(of: value) == Bool.self: self = .bool(v)
        case let v as UInt64: self = .uint(v)
        case let v as UInt32: self = .uint(UInt64(v))
        case let v as Int: self = .int(Int64(v))
        case let v as Int64: self = .int(v)
        case let v as Double: self = .double(v)
        case let v as String: self = .string(v)
        case let v as [Any]: self = .array(v.map(AnyJSON.init))
        case let v as [String: Any]: self = .object(v.mapValues(AnyJSON.init))
        case let v as NSNumber: self = CFNumberIsFloatType(v) ? .double(v.doubleValue) : .int(v.int64Value)
        default: self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .uint(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

extension GatewayClient {
    /// Submits a transaction given as JSON, such as an unshield withdrawal.
    public func submit(json tx: [String: Any]) async throws -> SubmitResult {
        try await call("tx.submit", ["tx": AnyJSON(tx)])
    }
}
