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

    /// Addresses ego-wallet-core gives for this seed. The Wallet Core workflow
    /// checks the library against Ego Desktop's own derivation, so these are
    /// also what Ego Desktop shows; a rebuilt library must keep them.
    func testTheLibraryDerivesEgoDesktopsAddresses() throws {
        #if canImport(EgoWalletCore)
        let list = try ExternalWallet.assets(seed: [UInt8](repeating: 7, count: 32))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: list.map { ($0.asset, $0.address) }), [
            "BTC": "bc1qz5fsxpk6s5y92dcn73j84drhrrdh2rjlu2efqh",
            "ETH": "0x13cCB7A7f8d13151382CD793992bA54aFF5b7A43",
            "BNB": "0xFF7a95B055662D03FaE6F56e1cA914BF656b5e93",
            "SOL": "AMFULyHvZpATpqfBVReLUXBV6xXfxcEdvaN3CNzRTNWK",
            "ADA": "addr1vx9fm33sanu5k7c0smn7g9fetlna27hfnkcr8stgar3g9pcxm3730",
            "XRP": "rUg5aL1DeHDwHXG62CRyBCapq8cArMAyhp",
            "TRX": "TY6pvrSqsNM4cR5vpqvoTW4DPCob4krzip",
            "LTC": "ltc1q0mwuh88l6hydr2ckh7ut42cc880njw9slrh7f2",
            "DOGE": "DE1t437YYWgMUxaxm7gTtp8EkJq6HtBoZE",
            "USDT": "0x13cCB7A7f8d13151382CD793992bA54aFF5b7A43",
            "USDC": "0x13cCB7A7f8d13151382CD793992bA54aFF5b7A43",
        ])
        XCTAssertThrowsError(try ExternalWallet.derive(seed: [1, 2, 3]))
        #endif
    }
}
