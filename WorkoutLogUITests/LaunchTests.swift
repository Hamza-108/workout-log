import XCTest

final class LaunchTests: XCTestCase {
    private func launchApp(backup: String? = nil, template: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["WORKOUT_LOG_TEST_STORE"] = UUID().uuidString
        app.launchEnvironment["WORKOUT_LOG_TEST_BACKUP"] = backup
        app.launchEnvironment["WORKOUT_LOG_TEST_TEMPLATE"] = template
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
        XCTAssertTrue(app.buttons["Keep logging"].waitForExistence(timeout: 10))
        app.buttons["Keep logging"].tap()
        XCTAssertTrue(loggedSet.waitForExistence(timeout: 10))
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["resumeWorkout"].waitForExistence(timeout: 10))
        app.buttons["resumeWorkout"].tap()
        XCTAssertTrue(app.buttons["finishWorkout"].waitForExistence(timeout: 10))
        app.buttons["finishWorkout"].tap()
        XCTAssertTrue(app.buttons["Finish workout"].waitForExistence(timeout: 10))
        app.buttons["Finish workout"].tap()
        XCTAssertTrue(app.buttons["newTemplate"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["resumeWorkout"].exists)
        app.tabBars.buttons["History"].tap()
        let history = app.buttons["history-Push day"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.tap()
        XCTAssertTrue(loggedSet.waitForExistence(timeout: 10))
        XCTAssertTrue(loggedSet.label.contains("20.5 kg"))
        XCTAssertTrue(loggedSet.label.contains("10 reps"))
        app.buttons["deleteSavedWorkout"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(loggedSet.exists)
        app.buttons["deleteSavedWorkout"].tap()
        app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Delete workout", "deleteSavedWorkout")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["No workouts yet"].waitForExistence(timeout: 10))
        app.terminate()
        app.launch()
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["No workouts yet"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Templates"].tap()
        XCTAssertTrue(app.buttons["startWorkout-Push day"].waitForExistence(timeout: 10))
    }

    private let backupFixture = #"""
    {
      "schemaVersion": 1, "preferredWeightUnit": "kg",
      "templates": [{"id":"11111111-1111-4111-8111-111111111111","name":"Imported Plan","exercises":["Bench"]}],
      "sessions": [
        {"id":"22222222-2222-4222-8222-222222222222","templateName":"Active Push","exercises":["Bench"],"unit":"lb","startedAt":"2026-01-01T12:00:00.000Z","finishedAt":null,"sets":[{"id":"44444444-4444-4444-8444-444444444444","exercise":"Bench","weight":45,"reps":5,"rpe":7}]},
        {"id":"33333333-3333-4333-8333-333333333333","templateName":"Old Push","exercises":["Bench"],"unit":"kg","startedAt":"2025-12-01T12:00:00.000Z","finishedAt":"2025-12-01T13:00:00.000Z","sets":[{"id":"55555555-5555-4555-8555-555555555555","exercise":"Bench","weight":20,"reps":8,"rpe":6}]}
      ]
    }
    """#

    func testColdWarmAndStaleSessionLinks() throws {
        let app = launchApp(backup: backupFixture)
        let url = try XCTUnwrap(URL(string: "workoutlog://session/22222222-2222-4222-8222-222222222222"))
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.buttons["history-Old Push"].waitForExistence(timeout: 10))
        app.open(url)
        XCTAssertTrue(app.buttons["addSet-Bench"].waitForExistence(timeout: 10))
        let set = app.descendants(matching: .any).matching(identifier: "loggedSet").firstMatch
        XCTAssertTrue(set.label.contains("45 lb"))
        app.buttons["Close"].tap()
        app.terminate()
        app.open(url)
        XCTAssertTrue(app.buttons["addSet-Bench"].waitForExistence(timeout: 10))
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["newTemplate"].waitForExistence(timeout: 10))
        app.buttons["newTemplate"].tap()
        enter("Never saved", in: app.textFields["templateName"])
        app.open(url)
        XCTAssertTrue(app.buttons["addSet-Bench"].waitForExistence(timeout: 10))
        app.buttons["Close"].tap()
        for text in ["workoutlog://session/33333333-3333-4333-8333-333333333333",
                     "workoutlog://session/not-a-uuid", "workoutlog://session/\(UUID())"] {
            app.open(try XCTUnwrap(URL(string: text)))
            XCTAssertTrue(app.staticTexts["routeMessage"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["addSet-Bench"].exists)
            XCTAssertTrue(app.buttons["resumeWorkout"].exists)
        }
        XCTAssertFalse(app.buttons["startWorkout-Never saved"].exists)
    }

    func testImportedTemplateEditorCancelAndSave() {
        let fixture = #"{"name":"Imported Push","exercises":["Bench","Press"]}"#
        let app = launchApp(template: fixture)
        XCTAssertTrue(app.textFields["templateName"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["templateName"].value as? String, "Imported Push")
        let exercises = app.textFields.matching(identifier: "exerciseName")
        XCTAssertEqual(exercises.element(boundBy: 0).value as? String, "Bench")
        XCTAssertEqual(exercises.element(boundBy: 1).value as? String, "Press")
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.buttons["startWorkout-Imported Push"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.textFields["templateName"].waitForExistence(timeout: 10))
        app.textFields["templateName"].tap()
        app.textFields["templateName"].typeText(" edited")
        app.buttons["saveTemplate"].tap()
        XCTAssertTrue(app.buttons["startWorkout-Imported Push edited"].waitForExistence(timeout: 10))
        app.terminate()
        app.launchEnvironment["WORKOUT_LOG_TEST_TEMPLATE"] = nil
        app.launch()
        XCTAssertTrue(app.buttons["startWorkout-Imported Push edited"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "startWorkout-Imported Push edited").count, 1)
    }

    func testSwipeHistoryDeletionPreservesDraftAndTemplate() {
        let app = launchApp(backup: backupFixture)
        app.tabBars.buttons["History"].tap()
        let history = app.buttons["history-Old Push"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(history.exists)
        history.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertTrue(app.buttons["Delete workout"].waitForExistence(timeout: 10))
        app.buttons["Delete workout"].tap()
        XCTAssertTrue(app.staticTexts["No workouts yet"].waitForExistence(timeout: 10))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["resumeWorkout"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["startWorkout-Imported Plan"].exists)
        XCTAssertFalse(app.buttons["startWorkout-Imported Plan"].isEnabled)
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["No workouts yet"].waitForExistence(timeout: 10))
    }

    func testDataScreenIsAccessible() {
        let app = launchApp()
        app.buttons["templateActions"].tap()
        app.buttons["Data and backups"].tap()
        XCTAssertTrue(app.buttons["exportBackup"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["importBackup"].exists)
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
