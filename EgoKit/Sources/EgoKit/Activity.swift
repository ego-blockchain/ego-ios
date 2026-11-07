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

    /// Paid by the network: block, uptime, storage and post rewards, fee shares,
    /// and node-pool payouts. Never something this wallet sent.
    func isReward(for me: String) -> Bool {
        to == me && from != me && (Self.rewardTypes.contains(txType ?? "") || from == Self.nodePool)
    }

    /// Received means someone else paid this wallet; anything it signed, even to itself, is sent.
    func direction(for me: String) -> ActivityDirection {
        if isReward(for: me) { return .reward }
        return to == me && from != me ? .received : .sent
    }
}
