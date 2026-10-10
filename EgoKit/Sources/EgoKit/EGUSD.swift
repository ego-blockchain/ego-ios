import Foundation

/// EGUSD, the chain's stable payment unit, as Ego Desktop's wallet uses it.
/// One credit is one cent. Credits are minted by burning EGOC at the current
/// EGOC price and can't be turned back into EGOC.
public enum EGUSD {
    public static let burnAddress = "egot1burncredits00000000000000000000000000000"
    public static let microUsdPerCredit: UInt64 = 10_000
    /// Validators refuse a mint whose stated price is further than this from theirs.
    public static let priceTolerancePercent: UInt64 = 25

    /// Credits minted for burning `uegoc` at `priceMicroUsd` µUSD per EGOC,
    /// rounded down exactly as the chain does.
    public static func credits(forBurning uegoc: UInt64, priceMicroUsd: UInt64) -> UInt64 {
        let product = uegoc.multipliedFullWidth(by: priceMicroUsd)
        let (quotient, _) = (1_000_000 * microUsdPerCredit).dividingFullWidth(product)
        return quotient
    }

    public static func priceMicroUsd(_ usd: Double) -> UInt64 {
        guard usd.isFinite, usd > 0 else { return 0 }
        return UInt64(usd * 1_000_000)
    }

    /// "$12.34"
    public static func format(_ credits: UInt64) -> String {
        "$\(credits / 100).\(String(format: "%02d", Int(credits % 100)))"
    }

    /// Credits for an amount typed in dollars, like "12.34". Nil if it isn't one.
    public static func parse(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let dollars = UInt64(parts[0].isEmpty ? "0" : String(parts[0]))
        else { return nil }
        var cents: UInt64 = 0
        if parts.count == 2 {
            let digits = parts[1]
            guard digits.count <= 2 else { return nil }
            cents = UInt64(digits.padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0
        }
        let (scaled, overflow) = dollars.multipliedReportingOverflow(by: 100)
        guard !overflow else { return nil }
        let total = scaled + cents
        return total > 0 ? total : nil
    }
}

public struct CreditsBalance: Decodable, Equatable, Sendable {
    public let credits: UInt64
}

extension Transactions {
    /// Burns EGOC for EGUSD at the stated price, like Ego Desktop's Convert.
    public static func creditsMint(
        key: EgoKey,
        amount: UInt64,
        priceMicroUsd: UInt64,
        nonce: UInt64,
        fee: UInt64,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970)
    ) throws -> SignedTransaction {
        guard amount > 0, priceMicroUsd > 0 else { throw TransactionError.zeroAmount }
        return try sign(
            key: key, to: EGUSD.burnAddress, amount: amount, nonce: nonce, fee: fee,
            memo: "credits_mint:\(priceMicroUsd)", txType: "credits_mint", timestamp: timestamp
        )
    }

    /// Pays EGUSD to another Ego address. The transaction moves no EGOC.
    public static func creditsPay(
        key: EgoKey,
        to: String,
        credits: UInt64,
        nonce: UInt64,
        fee: UInt64,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970)
    ) throws -> SignedTransaction {
        guard EgoAddress.isValid(to), to != key.address, to != EGUSD.burnAddress else { throw TransactionError.badRecipient }
        guard credits > 0 else { throw TransactionError.zeroAmount }
        return try sign(
            key: key, to: to, amount: 0, nonce: nonce, fee: fee,
            memo: "credits_pay:\(credits)", txType: "credits_pay", timestamp: timestamp
        )
    }
}

extension GatewayClient {
    public func credits(of address: String) async throws -> CreditsBalance {
        try await call("wallet.getCredits", ["address": address])
    }
}
