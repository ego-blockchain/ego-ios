import Foundation

/// Theft holds as the chain runs them: a victim asks the network to hold stolen
/// funds, staked holders and nodes vote to confirm, a held address can appeal, and
/// the victim can open a vote to have the funds returned. The phone votes with its
/// stake, appeals, and opens the return vote; filing a hold is done in Ego Desktop.
public enum Holds {
    static let bodyDomain = "ego/hold/body/v1:"

    public static let vote = "hold_vote"
    public static let appeal = "hold_appeal"
    public static let openReturn = "hold_return"
    public static let opTypes = ["hold_request", vote, "hold_node_vote", appeal, openReturn]

    public static let phaseConfirm = "confirm"
    public static let phaseReturn = "return"
    public static let maxAppealBytes = 2_000

    public static func memo(for txType: String, callArgs: String) -> String? {
        guard opTypes.contains(txType) else { return nil }
        let op = txType.dropFirst("hold_".count)
        return "hold:\(op):" + Blake3.hex(bodyDomain + callArgs)
    }

    public struct VoteBody: Encodable {
        public let id: String
        public let phase: String
        public let yes: Bool
        public init(id: String, phase: String, yes: Bool) { self.id = id; self.phase = phase; self.yes = yes }
    }

    public struct AppealBody: Encodable {
        public let id: String
        public let text: String
        public init(id: String, text: String) { self.id = id; self.text = text }
    }

    public struct IdBody: Encodable {
        public let id: String
        public init(id: String) { self.id = id }
    }

    public static func operation<T: Encodable>(
        key: EgoKey, txType: String, body: T, nonce: UInt64, fee: UInt64,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970), version: Int = 3
    ) throws -> SignedTransaction {
        let callArgs = try Dao.body(body)
        guard let memo = memo(for: txType, callArgs: callArgs) else { throw TransactionError.badRecipient }
        var tx = try Transactions.sign(key: key, to: key.address, amount: 0, nonce: nonce, fee: fee, memo: memo,
                                       txType: txType, timestamp: timestamp, version: version)
        tx.callArgs = callArgs
        return tx
    }

    // MARK: What a gateway answers

    public struct Tally: Decodable, Equatable, Sendable {
        public let stakeYes: UInt64
        public let stakeNo: UInt64
        public let stakeVoters: UInt64
        public let nodeYes: UInt64
        public let nodeNo: UInt64
        public let nodeVoters: UInt64

        enum CodingKeys: String, CodingKey {
            case stakeYes = "stake_yes"
            case stakeNo = "stake_no"
            case stakeVoters = "stake_voters"
            case nodeYes = "node_yes"
            case nodeNo = "node_no"
            case nodeVoters = "node_voters"
        }
    }

    public struct Held: Equatable, Sendable, Hashable {
        public let address: String
        public let amount: UInt64
    }

    public struct Appeal: Equatable, Sendable, Hashable {
        public let address: String
        public let text: String
    }

    public struct Hold: Decodable, Equatable, Sendable, Identifiable {
        public let id: String
        public let requester: String
        public let victim: String
        public let caseText: String
        public let bond: UInt64
        public let theft: [String]
        public let created: Int64
        /// signing, failed, voting, confirmed, return_voting, returned, rejected, lapsed, expired
        public let phase: String
        public let held: [Held]
        public let heldAt: Int64
        public let voteEnds: Int64
        public let returnEnds: Int64
        public let appeals: [Appeal]
        public let confirm: Tally
        public let ret: Tally
        public let myStakeVote: Bool?
        public let myReturnStakeVote: Bool?
        public let stakeTotal: UInt64

        enum CodingKeys: String, CodingKey {
            case id, requester, victim, bond, theft, created, phase, amounts, appeals, confirm, ret
            case caseText = "case"
            case heldAt = "held_at"
            case voteEnds = "vote_ends"
            case returnEnds = "return_ends"
            case myStakeVote = "my_stake_vote"
            case myReturnStakeVote = "my_return_stake_vote"
            case stakeTotal = "stake_total"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            requester = try c.decode(String.self, forKey: .requester)
            victim = try c.decode(String.self, forKey: .victim)
            caseText = try c.decode(String.self, forKey: .caseText)
            bond = try c.decode(UInt64.self, forKey: .bond)
            theft = try c.decode([String].self, forKey: .theft)
            created = try c.decode(Int64.self, forKey: .created)
            phase = try c.decode(String.self, forKey: .phase)
            held = try c.decode([Pair<UInt64>].self, forKey: .amounts).map { Held(address: $0.first, amount: $0.second) }
            heldAt = try c.decode(Int64.self, forKey: .heldAt)
            voteEnds = try c.decode(Int64.self, forKey: .voteEnds)
            returnEnds = try c.decode(Int64.self, forKey: .returnEnds)
            appeals = try c.decode([Pair<String>].self, forKey: .appeals).map { Appeal(address: $0.first, text: $0.second) }
            confirm = try c.decode(Tally.self, forKey: .confirm)
            ret = try c.decode(Tally.self, forKey: .ret)
            myStakeVote = try c.decodeIfPresent(Bool.self, forKey: .myStakeVote)
            myReturnStakeVote = try c.decodeIfPresent(Bool.self, forKey: .myReturnStakeVote)
            stakeTotal = try c.decode(UInt64.self, forKey: .stakeTotal)
        }

        /// The vote this address can cast now, if any: "confirm" or "return".
        public var openVote: String? {
            switch phase {
            case "voting": return myStakeVote == nil ? phaseConfirm : nil
            case "return_voting": return myReturnStakeVote == nil ? phaseReturn : nil
            default: return nil
            }
        }

        public func canAppeal(_ me: String) -> Bool {
            ["voting", "confirmed", "return_voting"].contains(phase)
                && held.contains { $0.address == me }
                && !appeals.contains { $0.address == me }
        }

        public func canOpenReturn(_ me: String) -> Bool {
            victim == me && phase == "confirmed" && returnEnds == 0
        }
    }

    /// A two-element JSON array, as Rust serializes a tuple.
    struct Pair<T: Decodable>: Decodable {
        let first: String
        let second: T

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            first = try c.decode(String.self)
            second = try c.decode(T.self)
        }
    }

    public struct Status: Decodable, Equatable, Sendable {
        public let active: Bool
        public let myStake: UInt64
        public let myLocked: UInt64
        public let holds: [Hold]

        enum CodingKeys: String, CodingKey {
            case active, holds
            case myStake = "my_stake"
            case myLocked = "my_locked"
        }
    }
}

extension GatewayClient {
    public func holdsStatus(of address: String) async throws -> Holds.Status {
        try await call("holds.status", ["address": address])
    }
}
