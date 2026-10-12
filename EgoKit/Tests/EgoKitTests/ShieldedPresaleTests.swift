import XCTest
@testable import EgoKit

final class ShieldedPresaleTests: XCTestCase {
    func testAmountsSplitIntoNotesAsOnEgoDesktop() {
        let (notes, rest) = Shielded.denominate(12_500_000)
        XCTAssertEqual(notes, [10_000_000, 1_000_000, 1_000_000])
        XCTAssertEqual(rest, 500_000)
        XCTAssertEqual(Shielded.denominate(999_999).notes, [])
    }

    func testAWithdrawalIsSentFromThePoolWithItsProofs() throws {
        let w = Shielded.Withdrawal(hash: "0xab", callArgs: #"{"spends":[]}"#, to: "egot1someone", amount: 10_000_000, fee: 1_000)
        let tx = Shielded.transaction(w, now: 1_800_000_000)
        XCTAssertEqual(tx["from"] as? String, Shielded.poolAddress)
        XCTAssertEqual(tx["tx_type"] as? String, "unshield")
        XCTAssertEqual(tx["signature"] as? String, "", "a withdrawal is authorised by its proofs, not a signature")
        XCTAssertEqual(tx["status"] as? String, "Pending")
        XCTAssertEqual(tx["call_args"] as? String, #"{"spends":[]}"#)
        let data = try JSONEncoder().encode(AnyJSON(tx))
        let back = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(back?["amount"] as? Int, 10_000_000)
        XCTAssertTrue(back?["memo"] is NSNull)
        XCTAssertEqual(back?["hash"] as? String, "0xab")
    }

    func testAnyJSONKeepsTypes() throws {
        let value: [String: Any] = ["b": true, "i": 3, "u": UInt64.max, "d": 1.5, "s": "x", "a": [1, "two"], "n": NSNull()]
        let back = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(AnyJSON(value))) as? [String: Any]
        XCTAssertEqual(back?["b"] as? Bool, true)
        XCTAssertEqual(back?["i"] as? Int, 3)
        XCTAssertEqual((back?["u"] as? NSNumber)?.uint64Value, UInt64.max)
        XCTAssertEqual(back?["d"] as? Double, 1.5)
        XCTAssertEqual((back?["a"] as? [Any])?.count, 2)
    }

    func testTheMainnetAddressUsesChainZeroAndTheEgoPrefix() throws {
        let key = try EgoKey(seed: [UInt8](repeating: 7, count: 32))
        let mainnet = EgoAddress.mainnet(publicKey: key.publicKey)
        XCTAssertTrue(mainnet.hasPrefix("ego1"))
        XCTAssertNotEqual(String(mainnet.dropFirst(4)), String(key.address.dropFirst(5)))
        XCTAssertEqual(EgoAddress.address(publicKey: key.publicKey, chainId: 1, hrp: "egot"), key.address)
    }
}

final class PresaleIOUFileTests: XCTestCase {
    private func iouFile(coin: String, deposit: String) throws -> URL {
        let json: [String: Any] = [
            "ego_presale": true, "id": "test", "issued_at": 0,
            "allocation": ["egoc_amount": 100, "usd_value": 1],
            "payment": ["coin": coin, "deposit_address": deposit, "amount": 0.01],
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return url
    }

    func testOwnTreasuryKeepsItsPayAddress() throws {
        let iou = try XCTUnwrap(PresaleIOU(file: try iouFile(coin: "ETH", deposit: "0xD4f2B1fA44668B806290A4c3CB758ABb7EF35C64")))
        XCTAssertEqual(iou.depositAddress, "0xD4f2B1fA44668B806290A4c3CB758ABb7EF35C64")
    }

    func testSwappedAddressGetsNoPayButton() throws {
        let iou = try XCTUnwrap(PresaleIOU(file: try iouFile(coin: "ETH", deposit: "0x000000000000000000000000000000000000dEaD")))
        XCTAssertNil(iou.depositAddress)
        let other = try XCTUnwrap(PresaleIOU(file: try iouFile(coin: "BTC", deposit: "0xD4f2B1fA44668B806290A4c3CB758ABb7EF35C64")))
        XCTAssertNil(other.depositAddress, "an ETH treasury on a BTC IOU")
    }
}
