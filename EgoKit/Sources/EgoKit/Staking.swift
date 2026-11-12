import Foundation

/// Staking as the chain runs it: EGOC sent to the staking address with the lock in
/// the memo ("stake:90"), and an unstake of the whole stake back. Unstaking inside
/// the lock costs 10% ("unstake:early"); a stake vote or report keeps the stake
/// locked until it ends. Staked EGOC is what gives DAO votes their weight.
public enum Staking {
    public static let address = "egot1staking000000000000000000000000000000000"
    public static let maxLockDays: UInt32 = 1825

    public static func stake(key: EgoKey, amount: UInt64, lockDays: UInt32, nonce: UInt64, fee: UInt64,
                             timestamp: Int64 = Int64(Date().timeIntervalSince1970), version: Int = 3) throws -> SignedTransaction {
        guard amount > 0 else { throw TransactionError.zeroAmount }
        guard (1...maxLockDays).contains(lockDays) else { throw StakingError.lock }
        return try Transactions.sign(key: key, to: address, amount: amount, nonce: nonce, fee: fee, memo: "stake:\(lockDays)",
                                     txType: "stake", timestamp: timestamp, version: version)
    }

    /// Unstakes everything staked. `early` pays 10% to leave before the lock ends.
    public static func unstake(key: EgoKey, staked: UInt64, early: Bool, nonce: UInt64, fee: UInt64,
                               timestamp: Int64 = Int64(Date().timeIntervalSince1970), version: Int = 3) throws -> SignedTransaction {
        guard staked > 0 else { throw TransactionError.zeroAmount }
        return try Transactions.sign(key: key, to: address, amount: staked, nonce: nonce, fee: fee,
                                     memo: early ? "unstake:early" : "unstake", txType: "unstake", timestamp: timestamp, version: version)
    }

    public struct LockOption: Decodable, Equatable, Sendable, Hashable {
        public let days: UInt32
        public let apr: Double
    }

    public struct Status: Decodable, Equatable, Sendable {
        public let staked: UInt64
        public let startedAt: Int64
        public let lockDays: UInt32
        public let unlockAt: Int64
        public let locked: Bool
        public let apr: Double
        public let accrued: UInt64
        public let earlyFee: UInt64
        public let voteLockedUntil: Int64
        public let canUnstake: Bool
        public let networkStake: UInt64
        public let lockOptions: [LockOption]
        public let budgetLive: Bool?
        public let activityMilli: UInt64?

        enum CodingKeys: String, CodingKey {
            case staked, locked, apr, accrued
            case startedAt = "started_at"
            case lockDays = "lock_days"
            case unlockAt = "unlock_at"
            case earlyFee = "early_fee"
            case voteLockedUntil = "vote_locked_until"
            case canUnstake = "can_unstake"
            case networkStake = "network_stake"
            case lockOptions = "lock_options"
            case budgetLive = "budget_live"
            case activityMilli = "activity_milli"
        }

        public var activityBoost: Double { Double(activityMilli ?? 1_000) / 1_000 }

        /// This stake's share of all stake on the network, 0...1.
        public var share: Double { networkStake > 0 ? Double(staked) / Double(networkStake) : 0 }
    }
}

public enum StakingError: LocalizedError, Equatable {
    case lock

    public var errorDescription: String? {
        switch self {
        case .lock: return "Choose a lock between 1 day and 5 years."
        }
    }
}

extension GatewayClient {
    public func stakingStatus(of address: String) async throws -> Staking.Status {
        try await call("staking.status", ["address": address])
    }
}
