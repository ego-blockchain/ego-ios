import XCTest
@testable import EgoKit

final class ActivityTests: XCTestCase {
    private let me = "egot1me"

    private func tx(from: String, to: String, type: String? = "transfer", amount: UInt64 = 5) -> HistoryItem {
        let json = """
        {"hash":"0x1","from":"\(from)","to":"\(to)","amount":\(amount),"timestamp":1,"tx_type":\(type.map { "\"\($0)\"" } ?? "null")}
        """
        return try! JSONDecoder().decode(HistoryItem.self, from: Data(json.utf8))
    }

    func testAGatewayThatIgnoresTheFilterIsNoticed() {
        let reward = tx(from: HistoryItem.nodePool, to: me, type: "reward")
        let sent = tx(from: me, to: "egot1you")
        let priceReport = tx(from: me, to: me, type: "price_report", amount: 0)
        XCTAssertTrue([sent, priceReport].honors(kind: "sent", for: me))
        XCTAssertTrue([HistoryItem]().honors(kind: "sent", for: me))
        XCTAssertFalse([reward, reward].honors(kind: "sent", for: me))
        XCTAssertFalse([sent].honors(kind: "rewards", for: me))
        XCTAssertTrue([reward].honors(kind: "rewards", for: me))
        XCTAssertTrue([reward].honors(kind: "everything", for: me))
    }

    func testSentReceivedAndRewards() {
        XCTAssertEqual(tx(from: me, to: "egot1you").direction(for: me), .sent)
        XCTAssertEqual(tx(from: "egot1you", to: me).direction(for: me), .received)
        XCTAssertEqual(tx(from: "egot1you", to: me, type: nil).direction(for: me), .received)
        XCTAssertEqual(tx(from: me, to: "egot1you", type: "credits_pay", amount: 0).direction(for: me), .sent, "EGUSD moves no EGOC")
        XCTAssertEqual(tx(from: "egot1you", to: me, type: "credits_pay", amount: 0).direction(for: me), .received)
    }

    func testOnlyPaymentsBetweenPeopleAreSentOrReceived() {
        let readyBatch = tx(from: "", to: HistoryItem.nodePool, type: "ready_batch", amount: 0)
        XCTAssertNil(readyBatch.direction(for: me))
        XCTAssertTrue(readyBatch.isNetworkRecord)
        XCTAssertNil(tx(from: me, to: "egot1you", amount: 0).direction(for: me), "nothing moved")
        XCTAssertNil(tx(from: me, to: me).direction(for: me), "a payment to yourself")
        XCTAssertNil(tx(from: me, to: HistoryItem.nodePool, type: "credits_mint").direction(for: me), "converting to EGUSD")
        XCTAssertNil(tx(from: me, to: "egot1staking000000000000000000000000000000000", type: "stake").direction(for: me))
        XCTAssertNil(tx(from: me, to: "egot1feesink0000000000000000000000000000000", type: "credits_pay", amount: 0).direction(for: me), "a Storage plan")
        XCTAssertFalse(tx(from: me, to: "egot1staking000000000000000000000000000000000", type: "stake").isNetworkRecord, "a stake still shows under All")
    }

    func testNetworkPayoutsAreRewards() {
        for type in ["reward", "coinbase", "fee_distribution", "post_reward", "uptime_reward", "storage_reward"] {
            XCTAssertEqual(tx(from: HistoryItem.nodePool, to: me, type: type).direction(for: me), .reward, type)
        }
        XCTAssertEqual(tx(from: HistoryItem.nodePool, to: me, type: "faucet").direction(for: me), .reward)
        XCTAssertEqual(tx(from: "egot1you", to: me, type: "early_termination_refund").direction(for: me), .received)
    }
}
