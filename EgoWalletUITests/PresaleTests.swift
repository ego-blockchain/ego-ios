import XCTest

final class PresaleTests: XCTestCase {
    /// The number pad has no return key: a tap outside the field puts it away.
    func testTapOutsideClosesNumberPad() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "presale"]
        app.launch()

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no amount field")
        for _ in 0..<4 where !field.isHittable { app.swipeUp(velocity: .slow) }
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the number pad didn't open")
        app.keys["5"].tap()
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/ego-presale-kb.png"))

        app.staticTexts["YOU RECEIVE"].firstMatch.tap()
        sleep(1)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "the number pad stayed open after a tap outside")
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/ego-presale.png"))
    }
}
