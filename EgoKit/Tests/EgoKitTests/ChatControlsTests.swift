import EgoKit
import XCTest

final class ChatControlsTests: XCTestCase {
    func testDeleteForEveryoneRoundTrips() {
        let (type, content) = Messenger.encode(.delete(target: "1700000000-abcd1234"))
        XCTAssertEqual(type, "delete")
        XCTAssertEqual(content, #"{"target":"1700000000-abcd1234"}"#, "Ego Desktop reads this exact shape")
        XCTAssertEqual(Messenger.body(type: type, content: content), .delete(target: "1700000000-abcd1234"))
    }

    func testTheNewestBlockDecisionWins() {
        var here = [AccountRecord.Block(address: "egot1a", blocked: true, at: 100)]
        XCTAssertTrue(AccountRecord.merge(blocks: [.init(address: "egot1a", blocked: false, at: 200)], into: &here, now: 1_000))
        XCTAssertFalse(here[0].blocked)
        XCTAssertFalse(AccountRecord.merge(blocks: [.init(address: "egot1a", blocked: true, at: 150)], into: &here, now: 1_000), "an older block doesn't undo an unblock")
        XCTAssertFalse(AccountRecord.merge(blocks: [.init(address: "egot1a", blocked: true, at: 99_999)], into: &here, now: 1_000), "future-dated decisions are ignored")
        XCTAssertTrue(AccountRecord.merge(blocks: [.init(address: "egot1b", blocked: true, at: 300)], into: &here, now: 1_000))
        XCTAssertEqual(here.count, 2)
    }

    func testRecordsReadTheDesktopsNewFieldsAndOlderOnes() throws {
        let new = #"{"v":1,"name":"Art","name_at":50,"contacts":[{"address":"egot1x","name":"Ana","ed25519":"k","shared_key_hex":"00","name_at":42}],"blocks":[{"address":"egot1y","blocked":true,"at":7}],"renames":[{"address":"egot1x","name":"Annie","at":9}]}"#
        let content = try JSONDecoder().decode(AccountRecord.Content.self, from: Data(new.utf8))
        XCTAssertEqual(content.nameAt, 50)
        XCTAssertEqual(content.contacts.first?.nameAt, 42)
        XCTAssertEqual(content.blocks, [.init(address: "egot1y", blocked: true, at: 7)])
        XCTAssertEqual(content.renames, [.init(address: "egot1x", name: "Annie", at: 9)])
        let old = #"{"v":1,"name":"Art","contacts":[{"address":"egot1x","name":"Ana","ed25519":"k","shared_key_hex":"00"}]}"#
        let older = try JSONDecoder().decode(AccountRecord.Content.self, from: Data(old.utf8))
        XCTAssertEqual(older.nameAt, 0)
        XCTAssertEqual(older.contacts.first?.nameAt, 0)
        XCTAssertTrue(older.blocks.isEmpty)
    }

    func testProfileUpdatesCarryTheNameOnlyWhenSet() {
        XCTAssertNil(Messenger.Outgoing.profile(from: "egot1x", avatar: "")["name"])
        XCTAssertEqual(Messenger.Outgoing.profile(from: "egot1x", avatar: "", name: "Ana")["name"] as? String, "Ana")
    }
}
