import XCTest
@testable import EgoKit

final class ChatContentTests: XCTestCase {
    private let link = EgoShareLink(cid: "egomfd1abc", key: [UInt8](repeating: 1, count: 32), name: "cat.gif", from: "egot1me")

    func testMessagesSplitIntoTextCodeAndMedia() {
        let body = "look at this\n\(link.text)\nand the fix:\n```swift\nlet x = 1\nprint(x)\n```\nnice"
        XCTAssertEqual(ChatContent.parse(body), [
            .text("look at this"),
            .media(link),
            .text("and the fix:"),
            .code(language: "swift", code: "let x = 1\nprint(x)"),
            .text("nice"),
        ])
        XCTAssertEqual(ChatContent.parse("```\nopen fence"), [.code(language: "", code: "open fence")])
        XCTAssertEqual(ChatContent.parse("egoshare1:broken"), [.text("egoshare1:broken")])
    }

    func testEmojiOnlyMessagesAreSpotted() {
        XCTAssertTrue(ChatContent.isOnlyEmoji("🔥"))
        XCTAssertTrue(ChatContent.isOnlyEmoji("😂 🙌🏽"))
        XCTAssertTrue(ChatContent.isOnlyEmoji("❤️"))
        XCTAssertFalse(ChatContent.isOnlyEmoji("gm 🔥"))
        XCTAssertFalse(ChatContent.isOnlyEmoji("123"))
        XCTAssertFalse(ChatContent.isOnlyEmoji(""))
    }

    func testReactionsAndPicturesSignWhatTheNodesCheck() throws {
        // Must match dao_chat.rs React and Avatar signing_bytes.
        let from = "egot1yzwkx349luk82ksl0xe2tm6rfwj26t7pg5apncg2"
        let r = ChatReact(from: from, postId: "cb73b6f6aed5d28c2e7546f860543c1e", postTs: 1_800_000_000, emoji: "🔥", ts: 1_800_000_005, pubkey: "", sig: "")
        XCTAssertEqual(String(decoding: r.signingBytes, as: UTF8.self), "ego/dao-chat/react/v1\n\(from)\ncb73b6f6aed5d28c2e7546f860543c1e\n1800000000\n1800000005\n🔥")
        let a = ChatAvatar(from: from, link: "egoshare1:x", ts: 1_800_000_006, pubkey: "", sig: "")
        XCTAssertEqual(String(decoding: a.signingBytes, as: UTF8.self), "ego/dao-chat/avatar/v1\n\(from)\n1800000006\negoshare1:x")

        let key = try EgoKey(seed: [UInt8](repeating: 8, count: 32))
        let signed = try ChatSigner.react(key: key, postId: "cb73b6f6aed5d28c2e7546f860543c1e", postTs: 1, emoji: "👍", ts: 2)
        XCTAssertTrue(EgoKey.verify(signature: Hex.decode(signed.sig)!, message: signed.signingBytes, publicKey: key.publicKey))
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ChatWire.react(signed))) as! [String: Any]
        XCTAssertEqual(wire["kind"] as? String, "react")
        XCTAssertEqual(wire["post_id"] as? String, "cb73b6f6aed5d28c2e7546f860543c1e")
        XCTAssertTrue(ChatContent.isReactionEmoji("👍🏽"))
        XCTAssertFalse(ChatContent.isReactionEmoji("ok"))
    }

    func testFeedsFromOlderNodesStillRead() throws {
        let json = #"{"me":"m","my_name":"","my_removed_until":null,"threshold":5,"ban_days":14,"oldest":null,"posts":[{"id":"p","from":"f","name":"","body":"hi","ts":1,"mine":false,"edited":false,"change_until":null,"removal_votes":0,"my_vote":false,"removed_until":null}]}"#
        let feed = try JSONDecoder().decode(ChatFeed.self, from: Data(json.utf8))
        XCTAssertEqual(feed.myAvatar, "")
        XCTAssertEqual(feed.posts[0].reactions, [])
        let newer = json.replacingOccurrences(of: #""removed_until":null}"#, with: #""removed_until":null,"avatar":"egoshare1:a","reactions":[{"emoji":"🔥","count":2,"mine":true}]}"#)
        let post = try JSONDecoder().decode(ChatFeed.self, from: Data(newer.utf8)).posts[0]
        XCTAssertEqual(post.avatar, "egoshare1:a")
        XCTAssertEqual(post.reactions, [ChatReaction(emoji: "🔥", count: 2, mine: true)])
    }
}
