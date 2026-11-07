import Foundation

/// Which part of Activity a transaction belongs in, seen from one wallet.
public enum ActivityDirection: Equatable, Sendable {
    case sent
    case received
    case reward
}

public extension HistoryItem {
    /// Where the network pays rewards from, as Ego Desktop names it.
    static let nodePool = "egot1nodepool000000000000000000000000000000000"
    /// What the network pays out, as Ego Desktop's ledger lists it.
    static let rewardTypes: Set<String> = ["reward", "coinbase", "fee_distribution", "post_reward", "uptime_reward", "storage_reward"]

    /// The chain's own accounts (node pool, staking, fee sink, escrows, burn,
    /// shielded pool…) are a word padded with zeros; a person's never is.
    static func isSystemAddress(_ address: String) -> Bool {
        address.isEmpty || address.contains("0000000000")
    }

    /// Paid by the network: block, uptime, storage and post rewards, fee shares,
    /// and node-pool payouts. Never something this wallet sent.
    func isReward(for me: String) -> Bool {
        to == me && from != me && (Self.rewardTypes.contains(txType ?? "") || from == Self.nodePool)
    }

    /// A payment from one person to another: EGOC with an amount, or EGUSD
    /// (which moves no EGOC). Network records such as ready and check-in
    /// batches, stakes, conversions and payments to yourself are not.
    var isBetweenUsers: Bool {
        from != to
            && !Self.isSystemAddress(from) && !Self.isSystemAddress(to)
            && (amount > 0 || txType == "credits_pay")
    }

    /// Records the network writes for itself that move nothing: worth hiding everywhere.
    var isNetworkRecord: Bool {
        amount == 0 && txType != "credits_pay" && (from.isEmpty || Self.isSystemAddress(to))
    }

    /// Sent or received only between people; rewards from the network; nil for the rest.
    func direction(for me: String) -> ActivityDirection? {
        if isReward(for: me) { return .reward }
        guard isBetweenUsers else { return nil }
        if from == me { return .sent }
        if to == me { return .received }
        return nil
    }
}
