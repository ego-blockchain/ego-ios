import Foundation

/// Rewards the chain has paid to an address. Any gateway can answer this.
public struct RewardsSummary: Decodable, Equatable, Sendable {
    public let totalUegoc: UInt64
    public let last24hUegoc: UInt64
    public let last7dUegoc: UInt64
    public let count: UInt64
    public let lastAt: Int64?

    enum CodingKeys: String, CodingKey {
        case count
        case totalUegoc = "total_uegoc"
        case last24hUegoc = "last_24h_uegoc"
        case last7dUegoc = "last_7d_uegoc"
        case lastAt = "last_at"
    }
}

public struct RewardBreakdown: Decodable, Equatable, Sendable {
    public let storageRewards: UInt64
    public let consensusRewards: UInt64
    public let coverageRewards: UInt64
    public let retrievalRewards: UInt64

    enum CodingKeys: String, CodingKey {
        case storageRewards = "storage_rewards"
        case consensusRewards = "consensus_rewards"
        case coverageRewards = "coverage_rewards"
        case retrievalRewards = "retrieval_rewards"
    }
}

/// The Earnings page of Ego Desktop, field for field.
public struct EarningsData: Decodable, Equatable, Sendable {
    public let dailyRewards: UInt64
    public let epochRewards: UInt64
    public let totalEarned: UInt64
    public let drsMultiplier: Double
    public let rewardBreakdown: RewardBreakdown
    public let pendingRewards: UInt64
    public let sessionStarted: Int64
    public let coverageOnline: Bool
    public let rewardSuspendedUntil: Int64?

    enum CodingKeys: String, CodingKey {
        case dailyRewards = "daily_rewards"
        case epochRewards = "epoch_rewards"
        case totalEarned = "total_earned"
        case drsMultiplier = "drs_multiplier"
        case rewardBreakdown = "reward_breakdown"
        case pendingRewards = "pending_rewards"
        case sessionStarted = "session_started"
        case coverageOnline = "coverage_online"
        case rewardSuspendedUntil = "reward_suspended_until"
    }
}

public struct ComputeEarnings: Decodable, Equatable, Sendable {
    public let totalUegoc: UInt64
    public let jobsCompleted: UInt64
    public let avgPerJobUegoc: UInt64
    public let last24hUegoc: UInt64

    enum CodingKeys: String, CodingKey {
        case totalUegoc = "total_uegoc"
        case jobsCompleted = "jobs_completed"
        case avgPerJobUegoc = "avg_per_job_uegoc"
        case last24hUegoc = "last_24h_uegoc"
    }
}

/// What the owner's own Ego Desktop reports about itself.
public struct NodeEarnings: Decodable, Equatable, Sendable {
    public let address: String
    public let earnings: EarningsData
    public let storageAllocatedBytes: UInt64
    public let drsScore: Double
    public let isValidator: Bool
    public let computeEnabled: Bool
    public let compute: ComputeEarnings?
    public let now: Int64

    enum CodingKeys: String, CodingKey {
        case address, earnings, compute, now
        case storageAllocatedBytes = "storage_allocated_bytes"
        case drsScore = "drs_score"
        case isValidator = "is_validator"
        case computeEnabled = "compute_enabled"
    }
}

public enum NodeEarningsRequest {
    public static let domain = "ego/node-earnings/v1"

    public static func signingBytes(address: String, ts: Int64) -> [UInt8] {
        Array("\(domain)\n\(address)\n\(ts)".utf8)
    }
}

extension GatewayClient {
    public func rewards(of address: String) async throws -> RewardsSummary {
        try await call("wallet.getRewards", ["address": address])
    }

    /// Asks this gateway for its own Earnings page. It only answers when the
    /// gateway is the computer that runs this wallet.
    public func nodeEarnings(key: EgoKey, now: Int64 = Int64(Date().timeIntervalSince1970)) async throws -> NodeEarnings {
        struct Params: Encodable { let address: String; let ts: Int64; let pubkey: String; let sig: String }
        let address = key.address
        let sig = try key.sign(NodeEarningsRequest.signingBytes(address: address, ts: now))
        return try await call("node.earnings", Params(address: address, ts: now, pubkey: Hex.encode(key.publicKey), sig: Hex.encode(sig)))
    }
}
