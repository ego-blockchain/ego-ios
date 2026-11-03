import XCTest
@testable import EgoKit

final class DilithiumTests: XCTestCase {
    /// blake3 of Ego Desktop's Dilithium public key for the seed [11; 32], from
    /// `pq_chain::wallet_core_agreement` in ego-blockchain-. The node pins this hash.
    static let desktopKeyHash = "da70065386cada8dfecebdc1f42b450bdb0564fef379d2bf724e761f8731ed51"

    func testThePhoneMakesEgoDesktopsDilithiumKey() throws {
        #if canImport(EgoWalletCore)
        let key = try Dilithium.publicKey(seed: [UInt8](repeating: 11, count: 32))
        XCTAssertEqual(key.count, 1312)
        XCTAssertEqual(Blake3.hex(key), Self.desktopKeyHash)
        #endif
    }

    func testTransactionsCarryADilithiumSignatureOverTheV3Bytes() throws {
        #if canImport(EgoWalletCore)
        let seed = [UInt8](repeating: 11, count: 32)
        let key = try EgoKey(seed: seed)
        let you = try EgoKey(seed: [UInt8](repeating: 8, count: 32)).address
        let tx = try Transactions.transfer(key: key, to: you, amount: 5, nonce: 1, fee: 1_000, timestamp: 1_800_000_000, version: 3)
        let bytes = Transactions.signingBytesV3(from: key.address, to: you, amount: 5, nonce: 1, timestamp: 1_800_000_000,
                                                chainId: EgoNetwork.chainId, fee: 1_000, priorityFee: 0, txType: "transfer", memo: "")
        XCTAssertEqual(tx.dilithiumPubkey, Hex.encode(try Dilithium.publicKey(seed: seed)))
        XCTAssertEqual(tx.dilithiumSignature, Hex.encode(try Dilithium.sign(seed: seed, message: bytes).signature))
        XCTAssertEqual(tx.dilithiumSignature.count, 2 * 2420)

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tx)) as? [String: Any]
        XCTAssertEqual(json?["dilithium_pubkey"] as? String, tx.dilithiumPubkey)
        XCTAssertEqual(json?["dilithium_signature"] as? String, tx.dilithiumSignature)
        XCTAssertEqual(try JSONDecoder().decode(SignedTransaction.self, from: JSONEncoder().encode(tx)), tx)
        #endif
    }

    /// Payments an older build saved in the outbox have no Dilithium fields and must still load.
    func testTransactionsSavedWithoutDilithiumStillLoad() throws {
        let old = """
        {"hash":"0xab","from":"egot1me","to":"egot1you","amount":5,"memo":null,"timestamp":1800000000,
         "signature":"cd","status":"Pending","nonce":1,"public_key_ed25519":"ef","fee_uegoc":1000,
         "tx_type":"transfer","tx_version":3,"chain_id":1}
        """
        let tx = try JSONDecoder().decode(SignedTransaction.self, from: Data(old.utf8))
        XCTAssertEqual(tx.dilithiumPubkey, "")
        XCTAssertEqual(tx.dilithiumSignature, "")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tx)) as? [String: Any]
        XCTAssertNil(json?["dilithium_pubkey"])
    }
}
