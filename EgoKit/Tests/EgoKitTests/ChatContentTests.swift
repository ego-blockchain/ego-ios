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
}
