import XCTest

/// Taps through the Wallet tab the way a person does.
final class TabNavigationTests: XCTestCase {
    func testEarningsOpensEveryTime() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "tabs"]
        app.launch()

        let card = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Earnings'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "no Earnings card")
        for round in 1...3 {
            card.tap()
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5), "Earnings didn't open on try \(round)")
            XCTAssertTrue(app.staticTexts["PAID TO THIS WALLET"].exists || app.staticTexts["Paid to this wallet"].exists,
                          "the page that opened isn't Earnings on try \(round)")
            back.tap()
            XCTAssertTrue(card.waitForExistence(timeout: 5), "didn't come back on try \(round)")
            sleep(1)
        }
    }

    func testChatProfileOpensEveryTime() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "tabs", "-tab", "settings"]
        app.launch()

        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Chat profile'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no Chat profile row")
        for round in 1...3 {
            row.tap()
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5), "Chat profile didn't open on try \(round)")
            back.tap()
            XCTAssertTrue(row.waitForExistence(timeout: 5), "didn't come back on try \(round)")
            sleep(1)
        }
    }
}
