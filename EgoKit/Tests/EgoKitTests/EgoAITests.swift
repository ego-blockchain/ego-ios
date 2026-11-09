import EgoKit
import XCTest

final class EgoAITests: XCTestCase {
    func testSuggestionsFollowTheTopicLikeTheDesktop() {
        XCTAssertEqual(EgoAI.followUps(after: "How does staking work?", asked: ["How does staking work?"]),
                       ["How does Proof of Coverage work?", "What is DRS reward scoring?", "How do I run a node?"])
        XCTAssertEqual(EgoAI.followUps(after: "where is the API", asked: ["where is the API", "Where is the developer API?"]),
                       ["How do I run a node?", "How do I deploy a contract?"])
        XCTAssertEqual(EgoAI.followUps(after: "hello", asked: ["hello"]),
                       ["What is a dApp?", "How do I create a dApp?", "Show me a smart contract example"])
        XCTAssertEqual(EgoAI.starters.count, 4)
    }
}
