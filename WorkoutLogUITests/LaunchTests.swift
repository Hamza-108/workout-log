import XCTest

final class LaunchTests: XCTestCase {
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["WORKOUT_LOG_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    private func enter(_ value: String, in field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(value)
    }

    private func createTemplate(in app: XCUIApplication) {
        app.buttons["newTemplate"].tap()
        enter("Push day", in: app.textFields["templateName"])
        enter("Bench", in: app.textFields.matching(identifier: "exerciseName").firstMatch)
        app.buttons["saveTemplate"].tap()
        XCTAssertTrue(app.buttons["startWorkout-Push day"].waitForExistence(timeout: 10))
    }

    func testLogResumeCorrectFinishAndHistory() {
        let app = launchApp()
        createTemplate(in: app)
        app.buttons["startWorkout-Push day"].tap()
        XCTAssertTrue(app.buttons["addSet-Bench"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["finishWorkout"].isEnabled)
        app.buttons["addSet-Bench"].tap()
        enter("20.5", in: app.textFields["setWeight"])
        enter("8", in: app.textFields["setReps"])
        app.buttons["saveSet"].tap()
        let loggedSet = app.descendants(matching: .any).matching(identifier: "loggedSet").firstMatch
        XCTAssertTrue(loggedSet.waitForExistence(timeout: 10))
        XCTAssertTrue(loggedSet.label.contains("20.5 kg"))
        XCTAssertTrue(loggedSet.label.contains("8 reps"))
        XCTAssertTrue(loggedSet.label.contains("exertion 7"))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["resumeWorkout"].waitForExistence(timeout: 10))
        app.buttons["resumeWorkout"].tap()
        XCTAssertTrue(loggedSet.waitForExistence(timeout: 10))
        loggedSet.tap()
        let reps = app.textFields["setReps"]
        XCTAssertTrue(reps.waitForExistence(timeout: 10))
        reps.tap()
        reps.typeText(XCUIKeyboardKey.delete.rawValue + "10")
        app.buttons["saveSet"].tap()
        XCTAssertTrue(loggedSet.waitForExistence(timeout: 10))
        XCTAssertTrue(loggedSet.label.contains("10 reps"))
        app.buttons["finishWorkout"].tap()
        XCTAssertTrue(app.buttons["newTemplate"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["resumeWorkout"].exists)
        app.tabBars.buttons["History"].tap()
        let history = app.buttons["history-Push day"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.tap()
        XCTAssertTrue(loggedSet.waitForExistence(timeout: 10))
        XCTAssertTrue(loggedSet.label.contains("20.5 kg"))
        XCTAssertTrue(loggedSet.label.contains("10 reps"))
    }

    func testInvalidTemplateAndSetCannotBeSaved() {
        let app = launchApp()
        app.buttons["newTemplate"].tap()
        app.buttons["saveTemplate"].tap()
        XCTAssertTrue(app.staticTexts["validationError"].waitForExistence(timeout: 10))
        enter("Push day", in: app.textFields["templateName"])
        enter("Bench", in: app.textFields.matching(identifier: "exerciseName").firstMatch)
        app.buttons["saveTemplate"].tap()
        XCTAssertTrue(app.buttons["startWorkout-Push day"].waitForExistence(timeout: 10))
        app.buttons["startWorkout-Push day"].tap()
        XCTAssertTrue(app.buttons["addSet-Bench"].waitForExistence(timeout: 10))
        app.buttons["addSet-Bench"].tap()
        enter("0", in: app.textFields["setWeight"])
        enter("0", in: app.textFields["setReps"])
        app.buttons["saveSet"].tap()
        XCTAssertTrue(app.staticTexts["validationError"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["setReps"].exists)
    }
}
