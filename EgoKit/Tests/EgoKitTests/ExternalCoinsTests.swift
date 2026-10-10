import XCTest
@testable import EgoKit

final class ExternalCoinsTests: XCTestCase {
    func testHexBalancesBecomeDecimalWithoutOverflow() {
        XCTAssertEqual(BigUnits.decimal(fromHex: "0x0"), "0")
        XCTAssertEqual(BigUnits.decimal(fromHex: "0x"), "0")
        XCTAssertEqual(BigUnits.decimal(fromHex: "0x1bc16d674ec80000"), "2000000000000000000")
        // 1,000 ETH in wei is past UInt64.
        XCTAssertEqual(BigUnits.decimal(fromHex: "0x3635c9adc5dea00000"), "1000000000000000000000")
        XCTAssertEqual(BigUnits.decimal(fromHex: "0x" + String(repeating: "0", count: 63) + "f"), "15")
        XCTAssertNil(BigUnits.decimal(fromHex: "0xzz"))
    }

    func testBalancesAreFormattedWithTheAssetsDecimals() {
        XCTAssertEqual(ExternalBalance(units: "2000000000000000000", decimals: 18).formatted(), "2.00")
        XCTAssertEqual(ExternalBalance(units: "1234567", decimals: 8).formatted(), "0.012345")
        XCTAssertEqual(ExternalBalance(units: "0", decimals: 6).formatted(), "0.00")
        XCTAssertEqual(ExternalBalance(units: "1500000", decimals: 6).formatted(), "1.50")
        XCTAssertEqual(ExternalBalance(units: "123456789", decimals: 8).formatted(maxDecimals: 8), "1.23456789")
        XCTAssertTrue(ExternalBalance(units: "000", decimals: 6).isZero)
    }

    func testTheListMatchesEgoDesktopsAndAddsItsTokens() {
        let derived = [
            ExternalWallet.Derived(chain: "Bitcoin", symbol: "BTC", address: "bc1qexample", addressType: "P2WPKH", explorerPrefix: "https://blockstream.info/address/"),
            ExternalWallet.Derived(chain: "Ethereum", symbol: "ETH", address: "0xAbC0000000000000000000000000000000000001", addressType: "EVM", explorerPrefix: "https://etherscan.io/address/"),
        ]
        let list = ExternalWallet.assets(from: derived)
        XCTAssertEqual(list.map(\.asset), ["BTC", "ETH", "USDT", "USDC"])
        let usdt = list[2]
        XCTAssertEqual(usdt.address, derived[1].address, "tokens live at the ETH address")
        XCTAssertEqual(usdt.chain, "ETH")
        XCTAssertEqual(usdt.decimals, 6)
        XCTAssertEqual(usdt.networkLabel, "USDT on Ethereum")
        XCTAssertEqual(list[0].decimals, 8)
        XCTAssertEqual(list[1].decimals, 18)
        XCTAssertEqual(list[0].explorerURL?.absoluteString, "https://blockstream.info/address/bc1qexample")
    }
}
