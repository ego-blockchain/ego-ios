import XCTest
@testable import EgoKit

final class SecondOpinionTests: XCTestCase {
    func testBalancesDisagreeOnlyWhenBothCountTheSameBlock() {
        XCTAssertTrue(SecondOpinion.disagree(Balance(uegoc: 5, height: 100), Balance(uegoc: 6, height: 100)))
        XCTAssertFalse(SecondOpinion.disagree(Balance(uegoc: 5, height: 100), Balance(uegoc: 5, height: 100)))
        XCTAssertFalse(SecondOpinion.disagree(Balance(uegoc: 5, height: 100), Balance(uegoc: 6, height: 101)), "one is a block behind, a reward may have landed")
        XCTAssertFalse(SecondOpinion.disagree(Balance(uegoc: 5), Balance(uegoc: 6)), "an older Ego Desktop doesn't say which block")
        XCTAssertFalse(SecondOpinion.disagree(nil, Balance(uegoc: 6, height: 1)))
    }

    func testTheGatewayAnswerCarriesTheBlock() throws {
        let b = try JSONDecoder().decode(Balance.self, from: Data(#"{"uegoc":5,"egoc":0.000005,"height":86998}"#.utf8))
        XCTAssertEqual(b.height, 86998)
        let old = try JSONDecoder().decode(Balance.self, from: Data(#"{"uegoc":5,"egoc":0.000005}"#.utf8))
        XCTAssertNil(old.height)
    }

    private func item(_ hash: String, height: UInt64?) -> HistoryItem {
        let h = height.map(String.init) ?? "null"
        let json = #"{"hash":"\#(hash)","from":"a","to":"b","amount":1,"timestamp":1,"block_height":\#(h)}"#
        return try! JSONDecoder().decode(HistoryItem.self, from: Data(json.utf8))
    }

    func testAPaymentIsConfirmedOnlyWhenTwoEgoDesktopsHaveItInABlock() {
        let one = SecondOpinion.confirmations(of: "x", in: [item("x", height: 9), nil, item("x", height: nil)])
        XCTAssertEqual(one.count, 1)
        let two = SecondOpinion.confirmations(of: "x", in: [item("x", height: 9), item("x", height: 9), item("y", height: 9)])
        XCTAssertEqual(two.count, 2)
        XCTAssertEqual(two.height, 9)
        XCTAssertEqual(SecondOpinion.confirmations(of: "x", in: [item("y", height: 9), item("y", height: 9)]).count, 0, "an answer about another payment doesn't count")
    }
}
