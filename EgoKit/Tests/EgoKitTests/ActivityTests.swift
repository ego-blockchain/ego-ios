import XCTest
@testable import EgoKit

final class ActivityTests: XCTestCase {
    private let me = "egot1me"

    private func tx(from: String, to: String, type: String? = "transfer") -> HistoryItem {
        let json = """
        {"hash":"0x1","from":"\(from)","to":"\(to)","amount":5,"timestamp":1,"tx_type":\(type.map { "\"\($0)\"" } ?? "null")}
        """
        return try! JSONDecoder().decode(HistoryItem.self, from: Data(json.utf8))
    }

    func testSentReceivedAndRewards() {
        XCTAssertEqual(tx(from: me, to: "egot1you").direction(for: me), .sent)
        XCTAssertEqual(tx(from: "egot1you", to: me).direction(for: me), .received)
        XCTAssertEqual(tx(from: "egot1you", to: me, type: nil).direction(for: me), .received)
        XCTAssertEqual(tx(from: me, to: me).direction(for: me), .sent, "a payment to yourself is still one you signed")
        XCTAssertEqual(tx(from: me, to: HistoryItem.nodePool, type: "credits_mint").direction(for: me), .sent)
    }

    func testNetworkPayoutsAreRewards() {
        for type in ["reward", "coinbase", "fee_distribution", "post_reward", "uptime_reward", "storage_reward"] {
            XCTAssertEqual(tx(from: HistoryItem.nodePool, to: me, type: type).direction(for: me), .reward, type)
        }
        XCTAssertEqual(tx(from: HistoryItem.nodePool, to: me, type: "faucet").direction(for: me), .reward)
        XCTAssertEqual(tx(from: "egot1you", to: me, type: "early_termination_refund").direction(for: me), .received)
    }
}
