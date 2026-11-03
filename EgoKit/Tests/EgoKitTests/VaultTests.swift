import XCTest
@testable import EgoKit
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class VaultTests: XCTestCase {
    func testBlake3MatchesTheReferenceVectors() {
        let vectors: [(Int, String)] = [
            (0, "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"),
            (1, "2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213"),
            (63, "e9bc37a594daad83be9470df7f7b3798297c3d834ce80ba85d6e207627b7db7b"),
            (64, "4eed7141ea4a5cd4b788606bd23f46e212af9cacebacdc7d1f4c6dc7f2511b98"),
            (65, "de1e5fa0be70df6d2be8fffd0e99ceaa8eb6e8c93a63f2d8d1c30ecb6b263dee"),
            (1023, "10108970eeda3eb932baac1428c7a2163b0e924c9a9e25b35bba72b28f70bd11"),
            (1024, "42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7"),
            (1025, "d00278ae47eb27b34faecf67b4fe263f82d5412916c1ffd97c8cb7fb814b8444"),
            (2048, "e776b6028c7cd22a4d0ba182a8bf62205d2ef576467e838ed6f2529b85fba24a"),
            (3000, "5fade288bf27444bee55ba2babb98c3c922c1e84c2e445e7d1f6da24756f5060"),
            (8193, "bab6c09cb8ce8cf459261398d2e7aef35700bf488116ceb94a36d0f5f1b7bc3b"),
        ]
        for (n, expected) in vectors {
            let input = (0..<n).map { UInt8($0 % 251) }
            XCTAssertEqual(Blake3.hex(input), expected, "length \(n)")
        }
        XCTAssertEqual(Blake3.hex("abc"), "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85")
    }

    func testMemoAndWaitingSendIdMatchTheNode() {
        let body = #"{"to":"egot1friendfriendfriendfriendfriendfriendfri","amount":5000000}"#
        XCTAssertEqual(Vault.memo(for: "vault_queue", callArgs: body),
                       "vault:queue:d1770ec2d76592384b542923744473780689a89e326428edc1988c66c5c15d59")
        XCTAssertNil(Vault.memo(for: "transfer", callArgs: body))
        XCTAssertEqual(Vault.queueId(txHash: "0x" + String(repeating: "ab", count: 32)), "2788dc6d4a03fedc")
    }

    func testAVaultOperationCarriesItsBodyAndMemo() throws {
        let key = try EgoKey(seed: [UInt8](repeating: 7, count: 32))
        let tx = try Vault.operation(key: key, txType: "vault_freeze", body: Vault.OwnerBody(owner: key.address), nonce: 3, fee: 1_000)
        XCTAssertEqual(tx.to, key.address)
        XCTAssertEqual(tx.amount, 0)
        XCTAssertEqual(tx.callArgs, #"{"owner":"\#(key.address)"}"#)
        XCTAssertEqual(tx.memo, Vault.memo(for: "vault_freeze", callArgs: tx.callArgs))
        let json = String(decoding: try JSONEncoder().encode(tx), as: UTF8.self)
        XCTAssertTrue(json.contains("\"call_args\""))
        XCTAssertFalse(json.contains("\"vault_cosig\""), "an empty approval is left out")
    }

    func testOldStoredTransactionsStillDecode() throws {
        let key = try EgoKey(seed: [UInt8](repeating: 7, count: 32))
        let you = try EgoKey(seed: [UInt8](repeating: 8, count: 32)).address
        let tx = try Transactions.transfer(key: key, to: you, amount: 1_000_000, nonce: 1, fee: 1_000)
        let json = try JSONEncoder().encode(tx)
        let back = try JSONDecoder().decode(SignedTransaction.self, from: json)
        XCTAssertEqual(back, tx)
        XCTAssertEqual(back.callArgs, "")
    }

    func testThePhoneApprovesADesktopRequestAsTheSecondKey() throws {
        let phone = try EgoKey(seed: [UInt8](repeating: 9, count: 32))
        let request = """
        {"tx_version":3,"chain_id":1,"from":"egot1owner","to":"egot1friend","amount":5000000000,"nonce":42,\
        "timestamp":1800000000,"fee":1000,"priority_fee":0,"tx_type":"transfer","memo":"rent","call_args":""}
        """
        let code = Vault.requestPrefix + Data(request.utf8).base64EncodedString()
        let parsed = try Vault.ApprovalRequest.decode(code)
        XCTAssertEqual(parsed.amount, 5_000_000_000)
        XCTAssertTrue(parsed.action.hasSuffix("EGOC to egot1friend"), parsed.action)
        XCTAssertThrowsError(try Vault.approve(parsed, with: phone, secondKey: "egot1someoneelse"))
        let approval = try Vault.approve(parsed, with: phone, secondKey: phone.address)
        XCTAssertTrue(approval.hasPrefix(Vault.approvalPrefix))
        let parts = approval.dropFirst(Vault.approvalPrefix.count).split(separator: ":")
        XCTAssertEqual(parts.count, 2)
        let pub = try Curve25519.Signing.PublicKey(rawRepresentation: Hex.decode(String(parts[0]))!)
        XCTAssertTrue(pub.isValidSignature(Data(Hex.decode(String(parts[1]))!), for: Data(parsed.cosignMessage)))
        XCTAssertEqual(Array(parsed.cosignMessage.prefix(20)), Array("ego/vault/cosign/v1:".utf8))
        XCTAssertThrowsError(try Vault.ApprovalRequest.decode("egoshare1:nope"))
    }

    func testOverLimitErrorsAreRecognised() {
        let e = GatewayError.rpc(-32000, "rejected: VAULT_LIMIT: this wallet's vault lets 5 uEGOC out today")
        XCTAssertTrue(Vault.isOverLimit(e))
        XCTAssertFalse(Vault.isOverLimit(GatewayError.rpc(-32000, "rejected: insufficient balance")))
        XCTAssertEqual(Vault.readable(e), "Your wallet vault lets only 0.000005 EGOC more out today.")
        let none = GatewayError.rpc(-32000, "rejected: VAULT_LIMIT: this wallet's vault lets 0 uEGOC out today")
        XCTAssertTrue(Vault.readable(none).hasPrefix("You've reached today's limit"))
    }
}
