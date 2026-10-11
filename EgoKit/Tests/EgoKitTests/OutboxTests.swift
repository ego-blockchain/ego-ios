import XCTest
@testable import EgoKit

final class OutboxTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
    }

    func testQueuedPaymentsSurviveARestart() throws {
        var box = Outbox(url: url)
        box.add(QueuedPayment(kind: .egoc, from: "egot1me", to: "egot1you", amount: 2_000_000, memo: "rent"))
        box.add(QueuedPayment(kind: .egusd, from: "egot1me", to: "egot1you", amount: 500))
        let reopened = Outbox(url: url)
        XCTAssertEqual(reopened.items, box.items)
        XCTAssertEqual(reopened.items(from: "egot1me").count, 2)
        XCTAssertTrue(reopened.items(from: "egot1other").isEmpty)
    }

    func testCommittedCountsOnlyWaitingPaymentsOfThatKind() throws {
        let key = try EgoKey(seed: [UInt8](repeating: 7, count: 32))
        let you = try EgoKey(seed: [UInt8](repeating: 8, count: 32)).address
        let signed = try Transactions.transfer(key: key, to: you, amount: 1_000_000, nonce: 1, fee: 1_000, memo: "")
        var box = Outbox(url: url)
        box.add(QueuedPayment(kind: .egoc, from: key.address, to: "egot1you", amount: 1_000_000, signed: signed))
        box.add(QueuedPayment(kind: .egoc, from: key.address, to: "egot1you", amount: 3_000_000))
        var turnedDown = QueuedPayment(kind: .egoc, from: key.address, to: "egot1you", amount: 9_000_000)
        turnedDown.rejected = "rejected: insufficient balance"
        box.add(turnedDown)
        box.add(QueuedPayment(kind: .egusd, from: key.address, to: "egot1you", amount: 700))
        XCTAssertEqual(box.committed(.egoc, from: key.address), 4_001_000)
        XCTAssertEqual(box.committed(.egusd, from: key.address), 700)
    }

    func testRemovingTheLastPaymentDeletesTheFile() {
        var box = Outbox(url: url)
        let item = QueuedPayment(kind: .egoc, from: "egot1me", to: "egot1you", amount: 1)
        box.add(item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        box.remove(item.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSnapshotIsOnlyLoadedForItsOwnAddress() {
        let snapshot = WalletSnapshot(address: "egot1me", balance: 5, credits: nil, history: [], updatedAt: 100)
        snapshot.save(to: url)
        XCTAssertEqual(WalletSnapshot.load(from: url, address: "egot1me"), snapshot)
        XCTAssertNil(WalletSnapshot.load(from: url, address: "egot1other"))
    }
}
