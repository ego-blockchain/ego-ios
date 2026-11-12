import Foundation

/// Posting and closing P2P offers, as Ego Desktop's market_post_offer and
/// market_close_offer do: a market operation sent to the escrow address, moving
/// no coins, whose body rides in call_args and whose memo names the body's hash.
public enum MarketOps {
    public static let escrowAddress = "egot1marketescrow000000000000000000000000000"
    static let bodyDomain = "ego/market/body/v1:"

    public static let postOffer = "market_offer"
    public static let closeOffer = "market_offer_close"
    static let opTypes = [postOffer, closeOffer]

    public static let minTradeUegoc: UInt64 = 1_000_000
    public static let maxTradeUegoc: UInt64 = 10_000_000_000_000
    public static let maxMethods = 8
    public static let maxTermsBytes = 1_000
    public static let paymentWindows: ClosedRange<Int64> = 15 * 60...24 * 3_600
    public static let maxMarginBps = 5_000
    public static let maxPriceMicro: UInt64 = 1_000_000_000_000
    public static let maxOpenOffers = 20

    /// "market:offer:<blake2s of the body>", as the chain checks it.
    public static func memo(for txType: String, callArgs: String) -> String? {
        guard opTypes.contains(txType) else { return nil }
        let op = txType.dropFirst("market_".count)
        return "market:\(op):" + Hex.encode(Blake2s.hash(Array((bodyDomain + callArgs).utf8)))
    }

    public enum Price: Equatable, Sendable {
        case fixed(UInt64)
        case marginBps(Int)
    }

    /// The offer's terms, in the chain's own field names.
    public struct OfferBody: Encodable, Equatable, Sendable {
        public var side: MarketSide
        public var asset: String
        public var fiat: String
        public var price: Price
        public var minMicro: UInt64
        public var maxMicro: UInt64
        public var methods: [String]
        public var country: String?
        public var terms: String
        public var paymentWindowSecs: Int64

        public init(side: MarketSide, asset: String = "EGOC", fiat: String, price: Price, minMicro: UInt64, maxMicro: UInt64,
                    methods: [String], country: String? = nil, terms: String = "", paymentWindowSecs: Int64) {
            self.side = side
            self.asset = asset
            self.fiat = fiat
            self.price = price
            self.minMicro = minMicro
            self.maxMicro = maxMicro
            self.methods = methods
            self.country = country
            self.terms = terms
            self.paymentWindowSecs = paymentWindowSecs
        }

        enum CodingKeys: String, CodingKey {
            case side, asset, fiat, price, methods, country, terms
            case minMicro = "min_micro"
            case maxMicro = "max_micro"
            case paymentWindowSecs = "payment_window_secs"
        }

        enum PriceKeys: String, CodingKey {
            case fixed
            case marginBps = "margin_bps"
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(side, forKey: .side)
            try c.encode(asset, forKey: .asset)
            try c.encode(fiat, forKey: .fiat)
            var p = c.nestedContainer(keyedBy: PriceKeys.self, forKey: .price)
            switch price {
            case .fixed(let micro): try p.encode(micro, forKey: .fixed)
            case .marginBps(let bps): try p.encode(bps, forKey: .marginBps)
            }
            try c.encode(minMicro, forKey: .minMicro)
            try c.encode(maxMicro, forKey: .maxMicro)
            try c.encode(methods, forKey: .methods)
            try c.encodeIfPresent(country, forKey: .country)
            try c.encode(terms, forKey: .terms)
            try c.encode(paymentWindowSecs, forKey: .paymentWindowSecs)
        }
    }

    public struct OfferRef: Encodable, Sendable {
        public let offerId: String
        public init(offerId: String) { self.offerId = offerId }
        enum CodingKeys: String, CodingKey { case offerId = "offer_id" }
    }

    /// What's wrong with an EGOC offer, in words for its owner, checked the way the
    /// chain checks it; nil when it can be posted. `balance` is the spendable EGOC
    /// a sell offer must cover.
    public static func problem(with b: OfferBody, balance: UInt64?) -> String? {
        guard b.asset == "EGOC" else { return "Offers in other coins are posted from Ego Desktop for now." }
        guard b.fiat.count == 3, b.fiat.allSatisfy({ $0.isASCII && $0.isUppercase }) else { return "Pick a currency." }
        switch b.price {
        case .fixed(let p) where p == 0: return "Set a price."
        case .fixed(let p) where p > maxPriceMicro: return "That price is too high."
        case .marginBps(let m) where abs(m) > maxMarginBps: return "The margin is limited to ±\(maxMarginBps / 100)%."
        case .marginBps where b.fiat != "USD": return "A price that follows the market works in USD only."
        default: break
        }
        if b.minMicro < minTradeUegoc { return "The minimum is at least \(Amount.format(minTradeUegoc)) EGOC." }
        if b.maxMicro < b.minMicro { return "The maximum must be at least the minimum." }
        if b.maxMicro > maxTradeUegoc { return "The maximum is at most \(Amount.format(maxTradeUegoc)) EGOC." }
        if b.methods.isEmpty { return "Pick at least one payment method." }
        if b.methods.count > maxMethods { return "Pick at most \(maxMethods) payment methods." }
        if Set(b.methods).count != b.methods.count { return "A payment method is listed twice." }
        if let c = b.country, !(c.count == 2 && c.allSatisfy({ $0.isASCII && $0.isUppercase })) {
            return "Country is a two-letter code like DE or US."
        }
        if b.terms.utf8.count > maxTermsBytes { return "Terms are at most \(maxTermsBytes) characters." }
        if b.terms.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && $0 != "\n" }) {
            return "Terms can't contain special control characters."
        }
        if !paymentWindows.contains(b.paymentWindowSecs) { return "The buyer gets 15 minutes to 24 hours to pay." }
        if b.side == .sell, let balance, balance < b.maxMicro {
            return "You hold \(Amount.format(balance)) EGOC, less than the most this offer sells (\(Amount.format(b.maxMicro)) EGOC). Lower the maximum."
        }
        return nil
    }

    public static func operation<T: Encodable>(
        key: EgoKey, txType: String, body: T, nonce: UInt64, fee: UInt64,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970), version: Int = 3
    ) throws -> SignedTransaction {
        let callArgs = try Dao.body(body)
        guard let memo = memo(for: txType, callArgs: callArgs) else { throw TransactionError.badRecipient }
        var tx = try Transactions.sign(key: key, to: escrowAddress, amount: 0, nonce: nonce, fee: fee, memo: memo,
                                       txType: txType, timestamp: timestamp, version: version)
        tx.callArgs = callArgs
        return tx
    }
}
