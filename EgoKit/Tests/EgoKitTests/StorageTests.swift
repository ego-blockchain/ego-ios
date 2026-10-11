import XCTest
@testable import EgoKit

final class StorageTests: XCTestCase {
    private let me = "egot1me"

    private func payment(_ memo: String, at ts: Int64, confirmed: Bool = true, from: String = "egot1me", type: String? = "transfer") -> HistoryItem {
        let json = """
        {"hash":"0x\(ts)","from":"\(from)","to":"\(EgoStorage.poolAddress)","amount":1000000,"timestamp":\(ts),
         "memo":"\(memo)","tx_type":\(type.map { "\"\($0)\"" } ?? "null"),"block_height":\(confirmed ? "10" : "null")}
        """
        return try! JSONDecoder().decode(HistoryItem.self, from: Data(json.utf8))
    }

    func testMemoMatchesEgoDesktop() {
        let pro = EgoStorage.plans.first { $0.id == "pro" }!
        XCTAssertEqual(EgoStorage.memo(for: pro, billing: .monthly), "Ego Storage Pro – monthly ($1.99)")
        XCTAssertEqual(EgoStorage.memo(for: pro, billing: .annual), "Ego Storage Pro – annual ($19.90)")
    }

    func testLatestPlanPaymentSetsTheQuota() {
        let history = [
            payment("Ego Storage Basic – monthly ($0.79)", at: 1_000),
            payment("Ego Storage Max – annual ($49.90)", at: 2_000),
            payment("photo.jpg | 3 blocks | 12 months", at: 3_000, type: "store_data"),
            payment("Ego Storage Pro – monthly ($1.99)", at: 4_000, from: "egot1someoneelse"),
        ]
        let sub = EgoStorage.subscription(in: history, of: me)!
        XCTAssertEqual(sub.plan.id, "max")
        XCTAssertEqual(sub.billing, .annual)
        XCTAssertEqual(EgoStorage.quotaBytes(sub, now: 2_100), 1024 * 1_000_000_000)
    }

    func testLapsedPlanKeepsSpaceThroughGraceThenFallsToFree() {
        let sub = EgoStorage.subscription(in: [payment("Ego Storage Pro – monthly ($1.99)", at: 0)], of: me)!
        let month = EgoStorage.Billing.monthly.seconds
        XCTAssertTrue(sub.active(now: month - 1))
        XCTAssertTrue(sub.inGrace(now: month + 10))
        XCTAssertEqual(EgoStorage.quotaBytes(sub, now: month + 10), 200 * 1_000_000_000)
        XCTAssertEqual(EgoStorage.quotaBytes(sub, now: month + EgoStorage.graceSeconds + 1), EgoStorage.freeBytes)
    }

    func testUnconfirmedPaymentDoesNotRaiseTheQuotaYet() {
        let sub = EgoStorage.subscription(in: [payment("Ego Storage Pro – monthly ($1.99)", at: 0, confirmed: false)], of: me)!
        XCTAssertFalse(sub.confirmed)
        XCTAssertEqual(EgoStorage.quotaBytes(sub, now: 10), EgoStorage.freeBytes)
        XCTAssertEqual(EgoStorage.quotaBytes(nil, now: 10), EgoStorage.freeBytes)
    }

    func testPriceInEgocHasAOneEgocFloor() {
        // $1.99 at $0.01 per EGOC is 199 EGOC.
        XCTAssertEqual(EgoStorage.priceUegoc(usd: 1.99, priceMicroUsd: 10_000), 199_000_000)
        XCTAssertEqual(EgoStorage.priceUegoc(usd: 0.79, priceMicroUsd: 5_000_000), 1_000_000)
        XCTAssertNil(EgoStorage.priceUegoc(usd: 1, priceMicroUsd: 0))
    }

    func testPlanPaymentIsSignedToThePool() throws {
        let key = try EgoKey(seed: [UInt8](repeating: 3, count: 32))
        let basic = EgoStorage.plans[1]
        let tx = try Transactions.storagePlan(key: key, plan: basic, billing: .monthly, amount: 79_000_000, nonce: 4, fee: 1_000)
        XCTAssertEqual(tx.to, EgoStorage.poolAddress)
        XCTAssertEqual(tx.memo, "Ego Storage Basic – monthly ($0.79)")
        XCTAssertEqual(tx.txType, "transfer")
        XCTAssertThrowsError(try Transactions.storagePlan(key: key, plan: EgoStorage.plans[0], billing: .monthly, amount: 1, nonce: 4, fee: 1))
    }

    func testFilesRoundTripAcrossBlocks() throws {
        var bytes = [UInt8](repeating: 0, count: EgoStorage.blockSize * 2 + 777)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 31) }
        let plain = Data(bytes)
        let file = try FileCrypto.encrypt(plain)
        XCTAssertEqual(file.blocks.count, 3)
        XCTAssertTrue(file.cid.hasPrefix("egomfd1"))
        XCTAssertEqual(file.manifest.fileName, "")
        let store = Dictionary(uniqueKeysWithValues: file.blocks.map { ($0.cid, $0.sealed) })
        XCTAssertEqual(try FileCrypto.decrypt(file.manifest, key: file.key) { store[$0] }, plain)
        // Encrypting the same file twice gives different blocks: nothing links them.
        XCTAssertNotEqual(try FileCrypto.encrypt(plain).cid, file.cid)
    }

    func testTamperedOrMissingBlocksAreCaught() throws {
        let file = try FileCrypto.encrypt(Data("hello ego storage".utf8))
        var tampered = file.blocks[0].sealed
        tampered[0] ^= 1
        XCTAssertThrowsError(try FileCrypto.decrypt(file.manifest, key: file.key) { _ in tampered }) {
            XCTAssertEqual($0 as? StorageError, .corrupt)
        }
        XCTAssertThrowsError(try FileCrypto.decrypt(file.manifest, key: file.key) { _ in nil })
        XCTAssertThrowsError(try FileCrypto.decrypt(file.manifest, key: [UInt8](repeating: 9, count: 32)) { _ in file.blocks[0].sealed })
    }

    func testShareLinksUseEgoDesktopsFormat() throws {
        let link = EgoShareLink(cid: "egomfd1abc", key: [UInt8](repeating: 0xab, count: 32), name: "Beach 🌊.jpg", from: me)
        XCTAssertTrue(link.text.hasPrefix("egoshare1:egomfd1abc:abab"))
        XCTAssertEqual(try EgoShareLink(parsing: link.text), link)
        XCTAssertThrowsError(try EgoShareLink(parsing: "egoshare2:x"))
    }

    func testStorageRequestsSignWhatTheGatewayChecks() throws {
        // Must match phone_storage.rs request_bytes: "domain\nowner\ncid\nts".
        XCTAssertEqual(String(decoding: StorageRequest.signingBytes(domain: StorageRequest.blockDomain, owner: "egot1me", cid: "egoblk1aa", ts: 42), as: UTF8.self),
                       "ego/storage-block/v1\negot1me\negoblk1aa\n42")
        let key = try EgoKey(seed: [UInt8](repeating: 2, count: 32))
        let bytes = StorageRequest.signingBytes(domain: StorageRequest.deleteDomain, owner: key.address, cid: "egomfd1bb", ts: 7)
        XCTAssertTrue(EgoKey.verify(signature: try key.sign(bytes), message: bytes, publicKey: key.publicKey))
    }

    func testManifestBytesAreStableSoTheGatewayGetsTheSameID() throws {
        let file = try FileCrypto.encrypt(Data(repeating: 1, count: 1000))
        let reopened = try JSONDecoder().decode(StorageManifest.self, from: file.manifest.data)
        XCTAssertEqual(reopened.data, file.manifest.data)
        XCTAssertEqual(reopened.cid, file.cid)
        let text = String(decoding: file.manifest.data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix(#"{"blocks":[{"block_cid":"egoblk1"#))
        XCTAssertTrue(text.hasSuffix(#""file_name":"","total_size":1000}"#))
    }

    func testLibraryIsSealedWithTheWalletSeed() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let seed = [UInt8](repeating: 5, count: 32)
        var library = FileLibrary(url: url, seed: seed)
        try library.add(LibraryFile(file: try FileCrypto.encrypt(Data("a".utf8)), name: "clip.MOV"))
        try library.add(LibraryFile(file: try FileCrypto.encrypt(Data("bb".utf8)), name: "notes.pdf"))
        XCTAssertEqual(FileLibrary(url: url, seed: seed).files.map(\.name), ["notes.pdf", "clip.MOV"])
        XCTAssertEqual(FileLibrary(url: url, seed: seed).files.map(\.kind), [.document, .video])
        XCTAssertEqual(FileLibrary(url: url, seed: seed).usedBytes, 3)
        XCTAssertTrue(FileLibrary(url: url, seed: [UInt8](repeating: 6, count: 32)).files.isEmpty)
        XCTAssertFalse(try Data(contentsOf: url).contains(Data("notes".utf8)))
    }
}

private extension Data {
    func contains(_ other: Data) -> Bool { range(of: other) != nil }
}
