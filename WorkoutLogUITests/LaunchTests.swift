import XCTest

final class LaunchTests: XCTestCase {
    func testSetupScreenLaunches() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Ready to log your workouts"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Setup build — workout logging and templates are coming next."].exists)
    }
}
