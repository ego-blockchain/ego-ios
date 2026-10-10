import XCTest
@testable import EgoKit

final class EGUSDTests: XCTestCase {
    func testMintingMatchesTheChainsFormula() {
        // 1 EGOC at $0.50 is 50 credits; the chain rounds down.
        XCTAssertEqual(EGUSD.credits(forBurning: 1_000_000, priceMicroUsd: 500_000), 50)
        XCTAssertEqual(EGUSD.credits(forBurning: 19_999, priceMicroUsd: 500_000), 0)
        XCTAssertEqual(EGUSD.credits(forBurning: 20_000, priceMicroUsd: 500_000), 1)
        // Large amounts don't overflow: the chain multiplies in 128 bits.
        XCTAssertEqual(EGUSD.credits(forBurning: UInt64.max, priceMicroUsd: 1_000_000), UInt64.max / 10_000)
    }

    func testTransactionsCarryTheMemosValidatorsExpect() throws {
        let key = try EgoKey(seed: [UInt8](repeating: 7, count: 32))
        let other = try EgoKey(seed: [UInt8](repeating: 8, count: 32)).address
        let mint = try Transactions.creditsMint(key: key, amount: 2_000_000, priceMicroUsd: 412_345, nonce: 3, fee: 1_000, timestamp: 1_800_000_000)
        XCTAssertEqual(mint.to, EGUSD.burnAddress)
        XCTAssertEqual(mint.txType, "credits_mint")
        XCTAssertEqual(mint.memo, "credits_mint:412345")
        XCTAssertEqual(mint.amount, 2_000_000)

        let pay = try Transactions.creditsPay(key: key, to: other, credits: 1_250, nonce: 4, fee: 1_000, timestamp: 1_800_000_000)
        XCTAssertEqual(pay.amount, 0)
        XCTAssertEqual(pay.txType, "credits_pay")
        XCTAssertEqual(pay.memo, "credits_pay:1250")
        XCTAssertThrowsError(try Transactions.creditsPay(key: key, to: key.address, credits: 1, nonce: 5, fee: 1_000))
        XCTAssertThrowsError(try Transactions.creditsPay(key: key, to: other, credits: 0, nonce: 5, fee: 1_000))
    }

    func testDollarsAreReadAndWrittenInCents() {
        XCTAssertEqual(EGUSD.format(1_234), "$12.34")
        XCTAssertEqual(EGUSD.format(5), "$0.05")
        XCTAssertEqual(EGUSD.parse("12.34"), 1_234)
        XCTAssertEqual(EGUSD.parse("$3"), 300)
        XCTAssertEqual(EGUSD.parse("0.5"), 50)
        XCTAssertEqual(EGUSD.parse(".05"), 5)
        for bad in ["", "0", "1.234", "abc", "1.2.3", "-1"] {
            XCTAssertNil(EGUSD.parse(bad), bad)
        }
    }
}
