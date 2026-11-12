import XCTest
@testable import EgoKit

final class MarketOpsTests: XCTestCase {
    private func sell(max: UInt64 = 5_000_000) -> MarketOps.OfferBody {
        .init(side: .sell, fiat: "USD", price: .fixed(250_000), minMicro: 1_000_000, maxMicro: max,
              methods: ["bank_transfer"], paymentWindowSecs: 3_600)
    }

    func testTheBodyAndMemoMatchWhatTheChainHashes() throws {
        let args = try Dao.body(sell())
        XCTAssertEqual(args, #"{"asset":"EGOC","fiat":"USD","max_micro":5000000,"methods":["bank_transfer"],"min_micro":1000000,"payment_window_secs":3600,"price":{"fixed":250000},"side":"sell","terms":""}"#)
        // blake2s("ego/market/body/v1:" + args), as market_chain::body_hash computes it.
        XCTAssertEqual(MarketOps.memo(for: MarketOps.postOffer, callArgs: args),
                       "market:offer:76c5ee123879100190e08e51c2bc0449e0da43ace5b35fdaeb7003997289102f")
        XCTAssertNil(MarketOps.memo(for: "market_settle", callArgs: args))
    }

    func testAMarginPriceAndCountryEncodeAsTheChainReadsThem() throws {
        var b = sell()
        b.price = .marginBps(-150)
        b.country = "DE"
        let args = try Dao.body(b)
        XCTAssertTrue(args.contains(#""price":{"margin_bps":-150}"#))
        XCTAssertTrue(args.contains(#""country":"DE""#))
        XCTAssertEqual(try Dao.body(MarketOps.OfferRef(offerId: "0xab")), #"{"offer_id":"0xab"}"#)
    }

    func testTheOperationGoesToTheEscrowAndMovesNoCoins() throws {
        let key = try EgoKey(seed: [UInt8](repeating: 7, count: 32))
        let tx = try MarketOps.operation(key: key, txType: MarketOps.postOffer, body: sell(), nonce: 4, fee: 2_000)
        XCTAssertEqual(tx.to, MarketOps.escrowAddress)
        XCTAssertEqual(tx.amount, 0)
        XCTAssertEqual(tx.txType, "market_offer")
        XCTAssertEqual(tx.memo, MarketOps.memo(for: MarketOps.postOffer, callArgs: tx.callArgs))
    }

    func testProblemsAreCaughtBeforePosting() {
        XCTAssertNil(MarketOps.problem(with: sell(), balance: 10_000_000))
        XCTAssertNotNil(MarketOps.problem(with: sell(max: 20_000_000), balance: 10_000_000), "sells more than it holds")
        var b = sell()
        b.methods = []
        XCTAssertEqual(MarketOps.problem(with: b, balance: nil), "Pick at least one payment method.")
        b = sell()
        b.minMicro = 500_000
        XCTAssertNotNil(MarketOps.problem(with: b, balance: nil))
        b = sell()
        b.price = .marginBps(100)
        b.fiat = "EUR"
        XCTAssertNotNil(MarketOps.problem(with: b, balance: nil), "margin prices are USD only")
        b = sell()
        b.paymentWindowSecs = 60
        XCTAssertNotNil(MarketOps.problem(with: b, balance: nil))
        b = sell()
        b.side = .buy
        b.maxMicro = 50_000_000
        XCTAssertNil(MarketOps.problem(with: b, balance: 0), "a buy offer needs no EGOC")
    }
}
