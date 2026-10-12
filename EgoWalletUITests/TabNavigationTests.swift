import XCTest

/// Taps through the Wallet tab the way a person does.
final class TabNavigationTests: XCTestCase {
    func testEarningsOpensEveryTime() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "tabs"]
        app.launch()

        let card = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Earnings'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "no Earnings card")
        // Left edge, the empty middle, and right by the arrow.
        for (round, x) in [0.05, 0.6, 0.95].enumerated() {
            card.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)).tap()
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5), "Earnings didn't open on try \(round) at \(x)")
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

    /// Coming back to the Wallet tab shows the Wallet, and Earnings still opens.
    func testWalletTabShowsWallet() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "tabs"]
        app.launch()

        let card = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Earnings'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "no Earnings card")
        let back = app.navigationBars.buttons.firstMatch
        func goToTab(_ name: String) {
            app.buttons.matching(NSPredicate(format: "label == %@", name)).allElementsBoundByIndex.last!.tap()
            sleep(2)
        }

        // Earnings opened and closed, then away and back.
        card.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        sleep(1)
        for other in ["Chat", "Settings"] {
            goToTab(other)
            goToTab("Wallet")
            XCTAssertFalse(back.exists, "Earnings showed after going back, then to \(other) and Wallet")
            XCTAssertTrue(card.isHittable, "Wallet isn't showing after \(other)")
        }

        // Still opens after the trip, and Back leaves the Wallet showing.
        card.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Earnings didn't open after visiting other tabs")
        XCTAssertFalse(app.buttons["Chat"].isHittable, "the tab bar shows over Earnings")
        back.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertFalse(back.exists, "Earnings is still showing after Back")
    }
}
