import Foundation

public enum VaultError: Error, Equatable, LocalizedError {
    case notARequest
    case damagedRequest
    case olderRequest
    case notSecondKey

    public var errorDescription: String? {
        switch self {
        case .notARequest: return "That isn't an Ego vault approval request."
        case .damagedRequest: return "The approval request is damaged. Create it again on the other device."
        case .olderRequest: return "The approval request comes from an older Ego Desktop. Update it first."
        case .notSecondKey: return "This wallet is not the second key of that vault."
        }
    }
}

/// The wallet vault: daily limit, delayed sends, second key, guardians, freeze and sweep.
/// Mirrors the node's `vault_chain.rs`.
public enum Vault {
    public static let sweepMemo = "vault:sweep"
    public static let execPrefix = "vault:exec:"
    public static let cancelChange = "change"
    public static let requestPrefix = "egovault1:"
    public static let approvalPrefix = "egocosig1:"
    static let bodyDomain = "ego/vault/body/v1:"
    static let queueDomain = "ego/vault/queue/v1:"
    static let cosignDomain = "ego/vault/cosign/v1:"

    public static let opTypes = ["vault_set", "vault_off", "vault_freeze", "vault_unfreeze", "vault_cancel", "vault_queue"]

    public static func memo(for txType: String, callArgs: String) -> String? {
        guard opTypes.contains(txType) else { return nil }
        let op = txType.dropFirst("vault_".count)
        return "vault:\(op):" + Blake3.hex(bodyDomain + callArgs)
    }

    public static func queueId(txHash: String) -> String {
        String(Blake3.hex(queueDomain + txHash).prefix(16))
    }

    public static func execMemo(_ id: String) -> String {
        execPrefix + id
    }

    /// A send the vault refused because it is above the daily limit. The node says so in its error.
    public static func isOverLimit(_ error: Error) -> Bool {
        let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        return text.contains("VAULT_LIMIT")
    }

    public static func readable(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        if text.contains("VAULT_LIMIT"), let left = number(after: "lets ", in: text) {
            return left == 0
                ? "Your wallet vault's daily limit is used up, so this can't go out right away. Send it with a delay, or approve it with your second key."
                : "Your wallet vault lets only \(Amount.format(left)) EGOC more out today. Send less, send it with a delay, or approve it with your second key."
        }
        return text
            .replacingOccurrences(of: "rejected: ", with: "")
            .replacingOccurrences(of: "VAULT_LIMIT: ", with: "")
            .replacingOccurrences(of: "VAULT_REFUSED: ", with: "")
    }

    private static func number(after marker: String, in text: String) -> UInt64? {
        guard let r = text.range(of: marker) else { return nil }
        return UInt64(text[r.upperBound...].prefix { $0.isNumber })
    }

    public struct Settings: Codable, Equatable {
        public var limit: UInt64
        public var delay: Int64
        public var highLimit: UInt64
        public var highDelay: Int64
        public var recovery: String
        public var secondKey: String
        public var guardians: [String]

        public init(limit: UInt64, delay: Int64, highLimit: UInt64 = 0, highDelay: Int64 = 0,
                    recovery: String = "", secondKey: String = "", guardians: [String] = []) {
            self.limit = limit
            self.delay = delay
            self.highLimit = highLimit
            self.highDelay = highDelay
            self.recovery = recovery
            self.secondKey = secondKey
            self.guardians = guardians
        }

        enum CodingKeys: String, CodingKey {
            case limit, delay, recovery, guardians
            case highLimit = "high_limit"
            case highDelay = "high_delay"
            case secondKey = "second_key"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            limit = try c.decode(UInt64.self, forKey: .limit)
            delay = try c.decode(Int64.self, forKey: .delay)
            highLimit = try c.decodeIfPresent(UInt64.self, forKey: .highLimit) ?? 0
            highDelay = try c.decodeIfPresent(Int64.self, forKey: .highDelay) ?? 0
            recovery = try c.decodeIfPresent(String.self, forKey: .recovery) ?? ""
            secondKey = try c.decodeIfPresent(String.self, forKey: .secondKey) ?? ""
            guardians = try c.decodeIfPresent([String].self, forKey: .guardians) ?? []
        }

        public func delay(for amount: UInt64) -> Int64 {
            highLimit > 0 && amount > highLimit ? highDelay : delay
        }
    }

    public struct Queued: Decodable, Equatable, Identifiable {
        public let id: String
        public let to: String
        public let amount: UInt64
        public let at: Int64
    }

    public struct PendingChange: Decodable, Equatable {
        public let kind: String
        public let at: Int64
        public let settings: Settings?
    }

    public struct View: Decodable, Equatable, Identifiable {
        public let owner: String
        public let settings: Settings
        public let frozen: Bool
        public let pending: PendingChange?
        public let queue: [Queued]
        public let spentToday: UInt64

        public var id: String { owner }
        public var leftToday: UInt64 { settings.limit > spentToday ? settings.limit - spentToday : 0 }

        enum CodingKeys: String, CodingKey {
            case owner, settings, frozen, pending, queue
            case spentToday = "spent_today"
        }
    }

    public struct Status: Decodable, Equatable {
        public let active: Bool
        public let address: String
        public let vault: View?
        public let helping: [View]
    }

    public struct ApprovalRequest: Codable, Equatable {
        public let txVersion: Int
        public let chainId: UInt8
        public let from: String
        public let to: String
        public let amount: UInt64
        public let nonce: UInt64
        public let timestamp: Int64
        public let fee: UInt64
        public let priorityFee: UInt64
        public let txType: String
        public let memo: String?
        public let callArgs: String

        enum CodingKeys: String, CodingKey {
            case from, to, amount, nonce, timestamp, fee, memo
            case txVersion = "tx_version"
            case chainId = "chain_id"
            case priorityFee = "priority_fee"
            case txType = "tx_type"
            case callArgs = "call_args"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            txVersion = try c.decode(Int.self, forKey: .txVersion)
            chainId = try c.decode(UInt8.self, forKey: .chainId)
            from = try c.decode(String.self, forKey: .from)
            to = try c.decode(String.self, forKey: .to)
            amount = try c.decode(UInt64.self, forKey: .amount)
            nonce = try c.decode(UInt64.self, forKey: .nonce)
            timestamp = try c.decode(Int64.self, forKey: .timestamp)
            fee = try c.decode(UInt64.self, forKey: .fee)
            priorityFee = try c.decodeIfPresent(UInt64.self, forKey: .priorityFee) ?? 0
            txType = try c.decode(String.self, forKey: .txType)
            memo = try c.decodeIfPresent(String.self, forKey: .memo)
            callArgs = try c.decodeIfPresent(String.self, forKey: .callArgs) ?? ""
        }

        public static func decode(_ code: String) throws -> ApprovalRequest {
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(requestPrefix) else { throw VaultError.notARequest }
            guard let data = Data(base64Encoded: String(trimmed.dropFirst(requestPrefix.count))),
                  let request = try? JSONDecoder().decode(ApprovalRequest.self, from: data) else {
                throw VaultError.damagedRequest
            }
            guard request.txVersion == 3 else { throw VaultError.olderRequest }
            return request
        }

        public var cosignMessage: [UInt8] {
            Array(cosignDomain.utf8) + Transactions.signingBytesV3(
                from: from, to: to, amount: amount, nonce: nonce, timestamp: timestamp, chainId: chainId,
                fee: fee, priorityFee: priorityFee, txType: txType, memo: memo ?? "")
        }

        /// What the owner asks to do, in words for the approval screen.
        public var action: String {
            switch txType {
            case "vault_set": return "change the vault settings"
            case "vault_unfreeze": return "unfreeze the wallet"
            case "vault_off": return "turn the vault off"
            default: return "send \(Amount.format(amount)) EGOC to \(to)"
            }
        }
    }

    /// Signs the owner's request with this wallet, acting as the vault's second key.
    public static func approve(_ request: ApprovalRequest, with key: EgoKey, secondKey: String) throws -> String {
        guard key.address == secondKey else { throw VaultError.notSecondKey }
        let signature = try key.sign(request.cosignMessage)
        return approvalPrefix + Hex.encode(key.publicKey) + ":" + Hex.encode(signature)
    }

    public struct SetBody: Encodable {
        public let settings: Settings
        public init(settings: Settings) { self.settings = settings }
    }
    public struct OwnerBody: Encodable {
        public let owner: String
        public init(owner: String) { self.owner = owner }
    }
    public struct CancelBody: Encodable {
        public let owner: String
        public let target: String
        public init(owner: String, target: String) { self.owner = owner; self.target = target }
    }
    public struct QueueBody: Encodable {
        public let to: String
        public let amount: UInt64
        public init(to: String, amount: UInt64) { self.to = to; self.amount = amount }
    }
    public struct EmptyBody: Encodable {
        public init() {}
    }

    public static func body<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// A vault operation: a zero-amount transaction to the sender itself whose memo commits to its body.
    public static func operation<T: Encodable>(
        key: EgoKey, txType: String, body: T, nonce: UInt64, fee: UInt64,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970), version: Int = 3
    ) throws -> SignedTransaction {
        let callArgs = try self.body(body)
        guard let memo = memo(for: txType, callArgs: callArgs) else { throw TransactionError.badRecipient }
        var tx = try Transactions.sign(key: key, to: key.address, amount: 0, nonce: nonce, fee: fee, memo: memo,
                                       txType: txType, timestamp: timestamp, version: version)
        tx.callArgs = callArgs
        return tx
    }
}
