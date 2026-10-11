import XCTest
@testable import EgoKit

final class StorageTests: XCTestCase {
    private let me = "egot1me"

    private func item(to: String, amount: UInt64, memo: String, at ts: Int64, type: String, confirmed: Bool = true, from: String = "egot1me") -> HistoryItem {
        let json = """
        {"hash":"0x\(ts)","from":"\(from)","to":"\(to)","amount":\(amount),"timestamp":\(ts),
         "memo":"\(memo)","tx_type":"\(type)","block_height":\(confirmed ? "10" : "null")}
        """
        return try! JSONDecoder().decode(HistoryItem.self, from: Data(json.utf8))
    }

    private func egusd(_ memo: String, at ts: Int64, confirmed: Bool = true, from: String = "egot1me") -> HistoryItem {
        item(to: EgoStorage.feeSink, amount: 0, memo: memo, at: ts, type: "credits_pay", confirmed: confirmed, from: from)
    }

    /// $0.01 per EGOC.
    private let cent: UInt64 = 10_000

    func testPlanMemosMatchEgoDesktop() {
        let pro = EgoStorage.plans.first { $0.id == "pro" }!
        XCTAssertEqual(EgoStorage.planMemo(for: pro, billing: .monthly), "credits_pay:199:plan:Pro:monthly")
        XCTAssertEqual(EgoStorage.planMemo(for: pro, billing: .annual), "credits_pay:1990:plan:Pro:annual")
        XCTAssertEqual(EgoStorage.memo(for: pro, billing: .monthly), "Ego Storage Pro – monthly ($1.99)")
    }

    func testNewestValidPlanSetsTheQuota() {
        let history = [
            egusd("credits_pay:79:plan:Basic:monthly", at: 1_000),
            egusd("credits_pay:4990:plan:Max:annual", at: 2_000),
            egusd("credits_pay:199:plan:Pro:monthly", at: 3_000, from: "egot1someoneelse"),
            item(to: EgoStorage.poolAddress, amount: 5_000_000, memo: "photo.jpg | 3 blocks", at: 4_000, type: "store_data"),
        ]
        let sub = EgoStorage.subscription(in: history, of: me, egocPriceMicroUsd: cent)!
        XCTAssertEqual(sub.plan.id, "max")
        XCTAssertEqual(sub.billing, .annual)
        XCTAssertEqual(EgoStorage.quotaBytes(sub, now: 2_100), 1024 * 1_000_000_000)
    }

    func testUnderpaidOrMislabelledPlansDontCount() {
        // Paying 1 cent for Max, or a note that merely mentions a plan, unlocks nothing.
        let history = [
            egusd("credits_pay:1:plan:Max:monthly", at: 1),
            egusd("credits_pay:999:plan:Gold:monthly", at: 2),
            item(to: EgoStorage.poolAddress, amount: 1, memo: "Ego Storage Max – monthly ($4.99)", at: 3, type: "transfer"),
            item(to: EgoStorage.poolAddress, amount: 999_000_000, memo: "please give me Max", at: 4, type: "transfer"),
        ]
        XCTAssertNil(EgoStorage.subscription(in: history, of: me, egocPriceMicroUsd: cent))
    }

    func testEgocPlansCountWhenTheyPaidAtLeastHalf() {
        // Pro is $1.99. At $0.01 per EGOC, 100 EGOC is $1.00, over half; 99 EGOC is under.
        let enough = item(to: EgoStorage.poolAddress, amount: 100_000_000, memo: "Ego Storage Pro – monthly ($1.99)", at: 5, type: "transfer")
        let short = item(to: EgoStorage.poolAddress, amount: 99_000_000, memo: "Ego Storage Pro – monthly ($1.99)", at: 5, type: "transfer")
        XCTAssertEqual(EgoStorage.subscription(in: [enough], of: me, egocPriceMicroUsd: cent)?.plan.id, "pro")
        XCTAssertNil(EgoStorage.subscription(in: [short], of: me, egocPriceMicroUsd: cent))
        XCTAssertNil(EgoStorage.subscription(in: [enough], of: me, egocPriceMicroUsd: nil))
    }

    func testLapsedPlanKeepsSpaceThroughGraceThenFallsToFree() {
        let sub = EgoStorage.subscription(in: [egusd("credits_pay:199:plan:Pro:monthly", at: 0)], of: me, egocPriceMicroUsd: nil)!
        let month = EgoStorage.Billing.monthly.seconds
        XCTAssertTrue(sub.active(now: month - 1))
        XCTAssertTrue(sub.inGrace(now: month + 10))
        XCTAssertEqual(EgoStorage.quotaBytes(sub, now: month + 10), 200 * 1_000_000_000)
        XCTAssertEqual(EgoStorage.quotaBytes(sub, now: month + EgoStorage.graceSeconds + 1), EgoStorage.freeBytes)
    }

    func testUnconfirmedPaymentDoesNotRaiseTheQuotaYet() {
        let sub = EgoStorage.subscription(in: [egusd("credits_pay:199:plan:Pro:monthly", at: 0, confirmed: false)], of: me, egocPriceMicroUsd: nil)!
        XCTAssertFalse(sub.confirmed)
        XCTAssertEqual(EgoStorage.quotaBytes(sub, now: 10), EgoStorage.freeBytes)
        XCTAssertEqual(EgoStorage.quotaBytes(nil, now: 10), EgoStorage.freeBytes)
    }

    func testPlanPaymentIsEgusdToTheFeeSink() throws {
        let key = try EgoKey(seed: [UInt8](repeating: 3, count: 32))
        let basic = EgoStorage.plans[1]
        let tx = try Transactions.storagePlan(key: key, plan: basic, billing: .monthly, nonce: 4, fee: 1_000)
        XCTAssertEqual(tx.to, EgoStorage.feeSink)
        XCTAssertEqual(tx.amount, 0)
        XCTAssertEqual(tx.memo, "credits_pay:79:plan:Basic:monthly")
        XCTAssertEqual(tx.txType, "credits_pay")
        XCTAssertThrowsError(try Transactions.storagePlan(key: key, plan: EgoStorage.plans[0], billing: .monthly, nonce: 4, fee: 1))
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
