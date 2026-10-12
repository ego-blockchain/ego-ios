import XCTest

/// Opens every main screen and keeps a screenshot of each, to check new iPhone sizes.
final class ScreenTests: XCTestCase {
    func testEveryScreen() {
        for tab in ["wallet", "storage", "chat", "market", "settings"] {
            let app = XCUIApplication()
            app.launchArguments = ["-demo", "tabs", "-tab", tab]
            app.launch()
            sleep(6)
            keep(app, tab)
            app.terminate()
        }
        for page in ["earnings", "receive", "lock", "restore"] {
            let app = XCUIApplication()
            app.launchArguments = ["-demo", page]
            app.launch()
            sleep(5)
            keep(app, page)
            app.terminate()
        }
    }

    private func keep(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
