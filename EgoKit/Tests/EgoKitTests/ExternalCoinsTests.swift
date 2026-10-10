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

    func testDecimalStringsAddAndCompare() {
        XCTAssertEqual(BigUnits.add("999", "1"), "1000")
        XCTAssertEqual(BigUnits.add("1000000000000000000000", "252000"), "1000000000000000252000")
        XCTAssertEqual(BigUnits.add("0", "0"), "0")
        XCTAssertEqual(BigUnits.compare("10", "9"), .orderedDescending)
        XCTAssertEqual(BigUnits.compare("0009", "9"), .orderedSame)
        XCTAssertEqual(BigUnits.compare("123", "124"), .orderedAscending)
    }

    func testSendingChecksTheBalanceAndTheFeeCoin() throws {
        let eth = ExternalAsset(asset: "ETH", name: "Ethereum", chain: "ETH", address: "0x1", addressType: "EVM", explorerPrefix: "", contract: nil, decimals: 18)
        let usdt = ExternalAsset(asset: "USDT", name: "USDT", chain: "ETH", address: "0x1", addressType: "ERC-20", explorerPrefix: "", contract: "0xdAC17F958D2ee523a2206206994597C13D831ec7", decimals: 6)
        func prepared(_ asset: ExternalAsset, amount: String, fee: String) -> PreparedTransfer {
            PreparedTransfer(asset: asset, to: "0x2", raw: "", hash: "", amountUnits: amount, feeUnits: fee, feeDecimals: 18, feeSymbol: "ETH")
        }
        let oneEth = ExternalBalance(units: "1000000000000000000", decimals: 18)
        XCTAssertNoThrow(try ExternalSend.checkFunds(prepared(eth, amount: "999000000000000000", fee: "1000000000000000"), balance: oneEth, nativeBalance: oneEth))
        XCTAssertThrowsError(try ExternalSend.checkFunds(prepared(eth, amount: "999000000000000001", fee: "1000000000000000"), balance: oneEth, nativeBalance: oneEth), "the fee comes out of the same balance")
        let tenUsdt = ExternalBalance(units: "10000000", decimals: 6)
        XCTAssertNoThrow(try ExternalSend.checkFunds(prepared(usdt, amount: "10000000", fee: "1000"), balance: tenUsdt, nativeBalance: oneEth))
        XCTAssertThrowsError(try ExternalSend.checkFunds(prepared(usdt, amount: "10000001", fee: "1000"), balance: tenUsdt, nativeBalance: oneEth))
        XCTAssertThrowsError(try ExternalSend.checkFunds(prepared(usdt, amount: "1", fee: "1000"), balance: tenUsdt, nativeBalance: ExternalBalance(units: "999", decimals: 18)), "a token transfer needs ETH for the fee")
    }

    func testEvmAddressesAreCheckedBeforeSigning() {
        let eth = ExternalAsset(asset: "ETH", name: "Ethereum", chain: "ETH", address: "0x1", addressType: "EVM", explorerPrefix: "", contract: nil, decimals: 18)
        XCTAssertTrue(ExternalSend.isValidAddress("0x13cCB7A7f8d13151382CD793992bA54aFF5b7A43", for: eth))
        XCTAssertTrue(ExternalSend.isValidAddress(" 0x13ccb7a7f8d13151382cd793992ba54aff5b7a43 ", for: eth))
        XCTAssertFalse(ExternalSend.isValidAddress("0x13cCB7A7f8d13151382CD793992bA54aFF5b7A4", for: eth))
        XCTAssertFalse(ExternalSend.isValidAddress("13cCB7A7f8d13151382CD793992bA54aFF5b7A43aa", for: eth))
        XCTAssertFalse(ExternalSend.isValidAddress("bc1qz5fsxpk6s5y92dcn73j84drhrrdh2rjlu2efqh", for: eth))
        XCTAssertEqual(ExternalSend.explorerTxURL(eth, hash: "0xab")?.absoluteString, "https://etherscan.io/tx/0xab")
    }

    func testBitcoinAndLitecoinAddressesAreRoughlyCheckedBeforeTheLibrary() {
        let btc = ExternalAsset(asset: "BTC", name: "Bitcoin", chain: "BTC", address: "bc1q", addressType: "P2WPKH", explorerPrefix: "", contract: nil, decimals: 8)
        let ltc = ExternalAsset(asset: "LTC", name: "Litecoin", chain: "LTC", address: "ltc1q", addressType: "P2WPKH", explorerPrefix: "", contract: nil, decimals: 8)
        XCTAssertTrue(ExternalSend.canSend(btc) && ExternalSend.canSend(ltc))
        for a in ["bc1qz5fsxpk6s5y92dcn73j84drhrrdh2rjlu2efqh", "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa", "3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy",
                  "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0"] {
            XCTAssertTrue(ExternalSend.isValidAddress(a, for: btc), a)
        }
        XCTAssertFalse(ExternalSend.isValidAddress("ltc1qr07zu594qf63xm7l7x6pu3a2v39m2z6hh5pp4t", for: btc))
        XCTAssertFalse(ExternalSend.isValidAddress("0x13cCB7A7f8d13151382CD793992bA54aFF5b7A43", for: btc))
        XCTAssertTrue(ExternalSend.isValidAddress("ltc1qr07zu594qf63xm7l7x6pu3a2v39m2z6hh5pp4t", for: ltc))
        XCTAssertFalse(ExternalSend.isValidAddress("bc1qz5fsxpk6s5y92dcn73j84drhrrdh2rjlu2efqh", for: ltc))
        XCTAssertEqual(ExternalSend.explorerTxURL(btc, hash: "ab")?.absoluteString, "https://blockstream.info/tx/ab")
        XCTAssertEqual(ExternalSend.explorerTxURL(ltc, hash: "ab")?.absoluteString, "https://litecoinspace.org/tx/ab")
    }
}
