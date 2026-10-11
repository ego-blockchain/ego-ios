import Foundation

/// A payment its owner confirmed while no Ego node could be reached, kept
/// until one answers.
public struct QueuedPayment: Codable, Equatable, Identifiable {
    public enum Kind: String, Codable {
        /// EGOC, amount in µEGOC.
        case egoc
        /// EGUSD credits, amount in cents.
        case egusd
    }

    public let id: UUID
    public let kind: Kind
    public let from: String
    public let to: String
    public let amount: UInt64
    public let memo: String
    public let createdAt: Int64
    /// Set when it's signed. From then on exactly this transaction is retried,
    /// so a payment that got through before the connection dropped can't be
    /// sent a second time.
    public var signed: SignedTransaction?
    /// Why the network turned it down. It then waits for its owner.
    public var rejected: String?

    public init(kind: Kind, from: String, to: String, amount: UInt64, memo: String = "",
                createdAt: Int64 = Int64(Date().timeIntervalSince1970), signed: SignedTransaction? = nil) {
        id = UUID()
        self.kind = kind
        self.from = from
        self.to = to
        self.amount = amount
        self.memo = memo
        self.createdAt = createdAt
        self.signed = signed
    }

    /// Still due to be sent automatically.
    public var waiting: Bool { rejected == nil }
}

/// The queued payments, saved in a file that's readable only while the iPhone is unlocked.
public struct Outbox {
    private let url: URL
    public private(set) var items: [QueuedPayment]

    public init(url: URL) {
        self.url = url
        items = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([QueuedPayment].self, from: $0) } ?? []
    }

    public func items(from address: String) -> [QueuedPayment] {
        items.filter { $0.from == address }
    }

    /// What the waiting payments of one kind will take from `address`, fees included where known.
    public func committed(_ kind: QueuedPayment.Kind, from address: String) -> UInt64 {
        items(from: address).filter { $0.kind == kind && $0.waiting }.reduce(0) { total, item in
            let fee = kind == .egoc ? item.signed?.feeUegoc ?? 0 : 0
            return total &+ item.amount &+ fee
        }
    }

    public mutating func add(_ item: QueuedPayment) {
        items.append(item)
        save()
    }

    public mutating func update(_ item: QueuedPayment) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i] = item
        save()
    }

    public mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    public mutating func removeAll(from address: String) {
        items.removeAll { $0.from == address }
        save()
    }

    private func save() {
        if items.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(items) else { return }
        #if os(iOS)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try? data.write(to: url, options: .atomic)
        #endif
    }
}

/// The last balance, credits and history a gateway gave, shown while none can be reached.
public struct WalletSnapshot: Codable, Equatable {
    public let address: String
    public let balance: UInt64?
    public let credits: UInt64?
    public let history: [HistoryItem]
    public let updatedAt: Int64

    public init(address: String, balance: UInt64?, credits: UInt64?, history: [HistoryItem], updatedAt: Int64) {
        self.address = address
        self.balance = balance
        self.credits = credits
        self.history = history
        self.updatedAt = updatedAt
    }

    public static func load(from url: URL, address: String) -> WalletSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(WalletSnapshot.self, from: data),
              snapshot.address == address
        else { return nil }
        return snapshot
    }

    public func save(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        #if os(iOS)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: url, options: .atomic)
        #endif
    }
}
