import XCTest

final class LaunchTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

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

    private func openFromSafari(_ url: URL, expecting app: XCUIApplication) {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launchArguments = app.launchArguments
        safari.launch()
        if safari.buttons["Continue"].waitForExistence(timeout: 2) { safari.buttons["Continue"].tap() }
        let address = safari.textFields.firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 10), safari.debugDescription)
        address.tap()
        let clear = safari.buttons["Clear text"]
        if clear.exists && clear.isEnabled && clear.isHittable { clear.tap() }
        address.typeText(url.absoluteString + "\n")
        let open = safari.buttons["Open"].firstMatch
        if open.waitForExistence(timeout: 5) { open.tap() }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), safari.debugDescription)
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
        {"id":"22222222-2222-4222-8222-222222222222","templateName":"Active Push","exercises":["Bench"],"unit":"lb","startedAt":"2026-01-01T12:00:00.000Z","finishedAt":null,"sets":[{"id":"44444444-4444-4444-8444-444444444444","exercise":"Bench","weight":45,"reps":5,"rpe":7.5}]},
        {"id":"33333333-3333-4333-8333-333333333333","templateName":"Old Push","exercises":["Bench"],"unit":"kg","startedAt":"2025-12-01T12:00:00.000Z","finishedAt":"2025-12-01T13:00:00.000Z","sets":[{"id":"55555555-5555-4555-8555-555555555555","exercise":"Bench","weight":20,"reps":8,"rpe":6}]}
      ]
    }
    """#

    func testColdWarmAndStaleSessionLinks() throws {
        let app = launchApp(backup: backupFixture)
        let url = try XCTUnwrap(URL(string: "workoutlog://session/22222222-2222-4222-8222-222222222222"))
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.buttons["history-Old Push"].waitForExistence(timeout: 10))
        openFromSafari(url, expecting: app)
        XCTAssertTrue(app.buttons["addSet-Bench"].waitForExistence(timeout: 10), app.debugDescription)
        let set = app.descendants(matching: .any).matching(identifier: "loggedSet").firstMatch
        XCTAssertTrue(set.label.contains("45 lb"))
        XCTAssertTrue(set.label.contains("exertion 7.5"))
        set.tap()
        XCTAssertTrue(app.buttons["saveSet"].waitForExistence(timeout: 10))
        app.buttons["saveSet"].tap()
        XCTAssertTrue(set.waitForExistence(timeout: 10))
        XCTAssertTrue(set.label.contains("exertion 7.5"))
        app.buttons["Close"].tap()
        app.terminate()
        openFromSafari(url, expecting: app)
        XCTAssertTrue(app.buttons["addSet-Bench"].waitForExistence(timeout: 10))
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["templateActions"].waitForExistence(timeout: 10))
        app.buttons["templateActions"].tap()
        app.buttons["Data and backups"].tap()
        XCTAssertTrue(app.buttons["exportBackup"].waitForExistence(timeout: 10))
        openFromSafari(url, expecting: app)
        XCTAssertTrue(app.buttons["addSet-Bench"].waitForExistence(timeout: 10))
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["newTemplate"].waitForExistence(timeout: 10))
        app.buttons["newTemplate"].tap()
        enter("Never saved", in: app.textFields["templateName"])
        openFromSafari(url, expecting: app)
        XCTAssertTrue(app.buttons["addSet-Bench"].waitForExistence(timeout: 10))
        app.buttons["Close"].tap()
        app.tabBars.buttons["Calendar"].tap()
        app.buttons["calendarAssign"].tap()
        XCTAssertTrue(app.buttons["saveCalendarAssignment"].waitForExistence(timeout: 10))
        openFromSafari(url, expecting: app)
        XCTAssertTrue(app.buttons["addSet-Bench"].waitForExistence(timeout: 10))
        app.buttons["Close"].tap()
        app.tabBars.buttons["Progress"].tap()
        app.segmentedControls["progressMode"].buttons["Body weight"].tap()
        app.buttons["addBodyWeight"].tap()
        XCTAssertTrue(app.textFields["bodyWeightValue"].waitForExistence(timeout: 10))
        enter("88", in: app.textFields["bodyWeightValue"])
        openFromSafari(url, expecting: app)
        XCTAssertTrue(app.buttons["addSet-Bench"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["saveBodyWeight"].exists)
        app.buttons["Close"].tap()
        app.tabBars.buttons["Progress"].tap()
        app.segmentedControls["progressMode"].buttons["Body weight"].tap()
        XCTAssertTrue(app.buttons["addBodyWeight"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "bodyWeightEntry-")).count, 0)
        app.tabBars.buttons["Templates"].tap()
        for text in ["workoutlog://session/33333333-3333-4333-8333-333333333333",
                     "workoutlog://session/not-a-uuid", "workoutlog://session/\(UUID())"] {
            openFromSafari(try XCTUnwrap(URL(string: text)), expecting: app)
            XCTAssertTrue(app.staticTexts["routeMessage"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["addSet-Bench"].exists)
            XCTAssertTrue(app.buttons["resumeWorkout"].exists)
        }
        XCTAssertFalse(app.buttons["startWorkout-Never saved"].exists)
    }

    func testImportedTemplateEditorCancelAndSave() {
        let fixture = #"{"name":"Imported Push","exercises":["Bench","Press"]}"#
        let app = launchApp(template: fixture)
        XCTAssertTrue(app.textFields["templateName"].waitForExistence(timeout: 10), app.debugDescription)
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

    func testCloseAndConfirmedDiscardKeepTemplate() {
        let app = launchApp()
        createTemplate(in: app)
        app.buttons["startWorkout-Push day"].tap()
        XCTAssertTrue(app.buttons["addSet-Bench"].waitForExistence(timeout: 10))
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["resumeWorkout"].waitForExistence(timeout: 10))
        app.buttons["resumeWorkout"].tap()
        XCTAssertTrue(app.buttons["discardWorkout"].waitForExistence(timeout: 10))
        app.buttons["discardWorkout"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["addSet-Bench"].exists)
        app.buttons["discardWorkout"].tap()
        app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Discard workout", "discardWorkout")).firstMatch.tap()
        XCTAssertTrue(app.buttons["newTemplate"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["resumeWorkout"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["startWorkout-Push day"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["resumeWorkout"].exists)
    }

    func testPresetRowsCanBeLoggedRemovedAddedAndResumed() {
        let app = launchApp()
        createTemplate(in: app)
        app.buttons["startWorkout-Push day"].tap()
        XCTAssertTrue(app.buttons["plannedSet-Bench-3"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["finishWorkout"].isEnabled)
        app.buttons["plannedSet-Bench-3"].tap()
        enter("20", in: app.textFields["setWeight"])
        enter("8", in: app.textFields["setReps"])
        app.buttons["saveSet"].tap()
        let logged = app.descendants(matching: .any).matching(identifier: "loggedSet").firstMatch
        XCTAssertTrue(logged.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["plannedSet-Bench-3"].exists)
        let pending = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "plannedSet-Bench-"))
        XCTAssertEqual(pending.count, 2)
        app.buttons["plannedSet-Bench-1"].swipeLeft()
        app.buttons["Delete"].tap()
        app.buttons["Delete set"].tap()
        XCTAssertEqual(pending.count, 1)
        app.buttons["addSet-Bench"].tap()
        enter("0", in: app.textFields["setWeight"])
        enter("10", in: app.textFields["setReps"])
        app.buttons["saveSet"].tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10))
        app.buttons["Close"].tap()
        app.buttons["Edit Push day"].tap()
        XCTAssertTrue(app.steppers["exerciseSets"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.steppers["exerciseSets"].label.contains("3"))
        app.buttons["Cancel"].tap()
        app.terminate()
        app.launch()
        app.buttons["resumeWorkout"].tap()
        XCTAssertTrue(logged.waitForExistence(timeout: 10))
        XCTAssertEqual(pending.count, 1)
        XCTAssertTrue(app.staticTexts["2 working · 0 warm-up sets · kg"].exists)
    }

    func testImportFormatAndCopyExampleAreVisibleInApp() {
        let app = launchApp()
        app.buttons["templateActions"].tap()
        app.buttons["Import template"].tap()
        let example = app.staticTexts["templateJSONExample"]
        XCTAssertTrue(example.waitForExistence(timeout: 10))
        XCTAssertTrue(example.label.contains("\"sets\":3"))
        XCTAssertTrue(app.buttons["chooseTemplateJSON"].exists)
        app.buttons["copyTemplateExample"].tap()
        for _ in 0..<3 where !app.staticTexts["Example copied."].isHittable { app.swipeDown() }
        XCTAssertTrue(app.staticTexts["Example copied."].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["newTemplate"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["startWorkout-Push day"].exists)
    }

    func testLibraryPickerIncludesVideosAndMultipleExercises() {
        let app = launchApp()
        app.buttons["templateActions"].tap()
        app.buttons["Exercise library"].tap()
        app.buttons["newLibraryExercise"].tap()
        enter("Bench", in: app.textFields["libraryExerciseName"])
        app.buttons["Add video"].tap()
        enter("https://youtu.be/abcdefghijk?t=1m30s", in: app.textFields["exerciseVideoURL"])
        app.buttons["saveLibraryExercise"].tap()
        XCTAssertTrue(app.buttons["libraryExercise-Bench"].waitForExistence(timeout: 10))
        app.buttons["newLibraryExercise"].tap()
        enter("Row", in: app.textFields["libraryExerciseName"])
        app.buttons["saveLibraryExercise"].tap()
        XCTAssertTrue(app.buttons["libraryExercise-Row"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["Templates"].tap()
        app.buttons["newTemplate"].tap()
        enter("Monday", in: app.textFields["templateName"])
        app.buttons["addExercise"].tap()
        app.buttons["pickExercise-Row"].tap()
        app.buttons["pickExercise-Bench"].tap()
        app.buttons["addSelectedExercises"].tap()
        let fields = app.textFields.matching(identifier: "exerciseName")
        XCTAssertEqual(fields.element(boundBy: 0).value as? String, "Row")
        XCTAssertEqual(fields.element(boundBy: 1).value as? String, "Bench")
        XCTAssertEqual(app.textFields["exerciseVideoURL"].value as? String, "https://www.youtube.com/watch?v=abcdefghijk&t=90")
        app.buttons["saveTemplate"].tap()
        XCTAssertTrue(app.buttons["startWorkout-Monday"].waitForExistence(timeout: 10))
        app.buttons["startWorkout-Monday"].tap()
        let video = app.descendants(matching: .any).matching(identifier: "video-Bench").firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 10))
        XCTAssertEqual(video.label, "Watch Bench tutorial")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "video-Row").firstMatch.exists)
        app.buttons["Close"].tap()
        app.terminate()
        app.launch()
        app.buttons["resumeWorkout"].tap()
        XCTAssertTrue(video.waitForExistence(timeout: 10))
    }

    func testPlainTextBatchPreviewCancelImportAndCopyExport() {
        let app = launchApp()
        let json = #"{"templates":[{"name":"Monday","exercises":[{"name":"Bench","sets":3}]},{"name":"Tuesday","exercises":[{"name":"Row","sets":2}]}]}"#
        for shouldSave in [false, true] {
            app.buttons["templateActions"].tap()
            app.buttons["Import template"].tap()
            let input = app.textViews["templateJSONInput"]
            enter(json, in: input)
            if app.buttons["Done"].firstMatch.exists { app.buttons["Done"].firstMatch.tap() }
            app.buttons["reviewTemplateJSON"].tap()
            XCTAssertTrue(app.buttons["importAllTemplates"].waitForExistence(timeout: 10))
            if shouldSave { app.buttons["importAllTemplates"].tap() }
            else {
                app.buttons["Back"].tap()
                XCTAssertEqual(input.value as? String, json)
                app.buttons["Cancel"].tap()
                XCTAssertFalse(app.buttons["startWorkout-Monday"].exists)
            }
        }
        XCTAssertTrue(app.buttons["startWorkout-Monday"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["startWorkout-Tuesday"].exists)
        app.buttons["templateActions"].tap()
        app.buttons["Export templates"].tap()
        app.buttons["Deselect all"].tap()
        XCTAssertFalse(app.buttons["copyTemplateJSON"].isEnabled)
        app.buttons["exportTemplate-Tuesday"].tap()
        app.buttons["copyTemplateJSON"].tap()
        XCTAssertTrue(app.staticTexts["Template JSON copied."].waitForExistence(timeout: 10))
        app.buttons["Close"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["startWorkout-Tuesday"].waitForExistence(timeout: 10))
        app.buttons["templateActions"].tap()
        app.buttons["Exercise library"].tap()
        XCTAssertTrue(app.buttons["libraryExercise-Bench"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["libraryExercise-Row"].exists)
    }

    func testPreviousHintsWarmupNumberingResumeAndLiftingProgress() {
        let app = launchApp(backup: backupFixture)
        app.buttons["resumeWorkout"].tap()
        let hint = app.descendants(matching: .any).matching(identifier: "previousSet-Bench-working-1").firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 10))
        XCTAssertTrue(hint.label.contains("20 kg"), hint.label)
        XCTAssertTrue(hint.label.contains("RPE 6"), hint.label)
        app.buttons["addWarmup-Bench"].tap()
        XCTAssertTrue(app.textFields["setWeight"].waitForExistence(timeout: 10))
        enter("80", in: app.textFields["setWeight"])
        enter("10", in: app.textFields["setReps"])
        app.buttons["saveSet"].tap()
        let warmup = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "loggedSet", "Warm-up 1")).firstMatch
        XCTAssertTrue(warmup.waitForExistence(timeout: 10))
        let working = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "loggedSet", "Set 1")).firstMatch
        XCTAssertTrue(working.exists)
        XCTAssertTrue(working.label.contains("45 lb"), working.label)
        app.buttons["Close"].tap()
        app.terminate()
        app.launch()
        app.buttons["resumeWorkout"].tap()
        XCTAssertTrue(warmup.waitForExistence(timeout: 10))
        XCTAssertTrue(working.exists)
        app.buttons["finishWorkout"].tap()
        app.buttons["Finish workout"].tap()
        app.tabBars.buttons["Progress"].tap()
        XCTAssertTrue(app.segmentedControls["progressMode"].waitForExistence(timeout: 10))
        let point = app.descendants(matching: .any).matching(identifier: "liftingPoint-22222222-2222-4222-8222-222222222222").firstMatch
        for _ in 0..<4 where !point.isHittable { app.swipeUp() }
        XCTAssertTrue(point.waitForExistence(timeout: 10))
        XCTAssertTrue(point.label.contains("45 lb"), point.label)
        XCTAssertFalse(point.label.contains("80 lb"), point.label)
    }

    func testBodyWeightAddDuplicateConfirmationEditReopenAndDelete() {
        let app = launchApp()
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: Date())
        app.tabBars.buttons["Progress"].tap()
        app.segmentedControls["progressUnit"].buttons["kg"].tap()
        app.segmentedControls["progressMode"].buttons["Body weight"].tap()
        app.buttons["addBodyWeight"].tap()
        enter("80.5", in: app.textFields["bodyWeightValue"])
        app.buttons["saveBodyWeight"].tap()
        let row = app.buttons["bodyWeightEntry-\(day)"]
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("80.5 kg"), row.label)
        app.swipeDown()
        app.buttons["addBodyWeight"].tap()
        enter("80", in: app.textFields["bodyWeightValue"])
        app.buttons["saveBodyWeight"].tap()
        XCTAssertTrue(app.buttons["Update weigh-in"].waitForExistence(timeout: 10))
        app.sheets["Update existing weigh-in?"].buttons["Cancel"].tap()
        app.buttons["cancelBodyWeight"].tap()
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.label.contains("80.5 kg"), row.label)
        app.swipeDown()
        app.buttons["addBodyWeight"].tap()
        enter("80", in: app.textFields["bodyWeightValue"])
        app.buttons["saveBodyWeight"].tap()
        app.buttons["Update weigh-in"].tap()
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        row.tap()
        let value = app.textFields["bodyWeightValue"]
        XCTAssertTrue(value.waitForExistence(timeout: 10))
        value.tap()
        value.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10) + "79.5")
        app.segmentedControls["bodyWeightUnit"].buttons["lb"].tap()
        app.buttons["saveBodyWeight"].tap()
        app.terminate()
        app.launch()
        app.tabBars.buttons["Progress"].tap()
        app.segmentedControls["progressMode"].buttons["Body weight"].tap()
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("79.5 lb"), row.label)
        app.buttons["deleteBodyWeight"].firstMatch.tap()
        app.buttons["Delete weigh-in"].tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
        app.terminate()
        app.launch()
        app.tabBars.buttons["Progress"].tap()
        app.segmentedControls["progressMode"].buttons["Body weight"].tap()
        XCTAssertTrue(app.buttons["addBodyWeight"].waitForExistence(timeout: 10))
        XCTAssertFalse(row.exists)
    }

    func testImportConflictRejectOverrideAndKeepBoth() {
        let backup = #"{"schemaVersion":3,"preferredWeightUnit":"kg","templates":[],"sessions":[],"libraryExercises":[{"id":"11111111-1111-4111-8111-111111111111","name":"Bench","videoURL":"https://www.youtube.com/watch?v=abcdefghijk"}]}"#
        let incoming = #"{"name":"Push","exercises":[{"name":"Bench","sets":3,"videoURL":"https://youtu.be/abcdefghijk?t=90s"}]}"#
        for choice in ["reject", "replace", "keepBoth"] {
            let app = launchApp(backup: backup, template: incoming)
            XCTAssertTrue(app.buttons["saveTemplate"].waitForExistence(timeout: 10))
            app.buttons["saveTemplate"].tap()
            XCTAssertTrue(app.staticTexts["importConflictSummary"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["importAllTemplates"].isEnabled)
            XCTAssertTrue(app.staticTexts["https://www.youtube.com/watch?v=abcdefghijk"].exists)
            XCTAssertTrue(app.staticTexts["https://www.youtube.com/watch?v=abcdefghijk&t=90"].exists)
            let option = app.buttons["conflictChoice-0-\(choice)"]
            for _ in 0..<3 where !option.isHittable { app.swipeUp() }
            option.tap()
            XCTAssertTrue(app.buttons["importAllTemplates"].isEnabled)
            app.buttons["importAllTemplates"].tap()
            XCTAssertTrue(app.buttons["startWorkout-Push"].waitForExistence(timeout: 10))
            app.buttons["Edit Push"].tap()
            let expectedName = choice == "keepBoth" ? "Bench (variation 1)" : "Bench"
            XCTAssertEqual(app.textFields.matching(identifier: "exerciseName").firstMatch.value as? String, expectedName)
            let expectedVideo = "https://www.youtube.com/watch?v=abcdefghijk" + (choice == "reject" ? "" : "&t=90")
            XCTAssertEqual(app.textFields["exerciseVideoURL"].value as? String, expectedVideo)
            app.buttons["Cancel"].tap()
            app.buttons["templateActions"].tap()
            app.buttons["Exercise library"].tap()
            XCTAssertTrue(app.buttons["libraryExercise-Bench"].waitForExistence(timeout: 10))
            XCTAssertEqual(app.buttons["libraryExercise-Bench (variation 1)"].exists, choice == "keepBoth")
            app.buttons["libraryExercise-Bench"].tap()
            XCTAssertEqual(app.textFields["exerciseVideoURL"].value as? String,
                           "https://www.youtube.com/watch?v=abcdefghijk" + (choice == "replace" ? "&t=90" : ""))
            app.buttons["Cancel"].tap()
            app.terminate()
        }
    }

    func testImportErrorAlertPreservesTextAndConflictCancelSavesNothing() {
        let app = launchApp()
        app.buttons["templateActions"].tap()
        app.buttons["Import template"].tap()
        let input = app.textViews["templateJSONInput"]
        enter("{broken", in: input)
        if app.buttons["Done"].firstMatch.exists { app.buttons["Done"].firstMatch.tap() }
        app.buttons["reviewTemplateJSON"].tap()
        XCTAssertTrue(app.alerts["Could not import"].waitForExistence(timeout: 10))
        app.alerts.buttons["OK"].tap()
        XCTAssertEqual(input.value as? String, "{broken")
        XCTAssertTrue(app.staticTexts["templateImportStatus"].exists)
        app.buttons["Cancel"].tap()
        app.terminate()

        let variants = #"{"templates":[{"name":"Monday","exercises":[{"name":"Bench","sets":3,"videoURL":"https://youtu.be/abcdefghijk"}]},{"name":"Friday","exercises":[{"name":"Bench","sets":2,"videoURL":"https://youtu.be/abcdefghijk?t=90"}]}]}"#
        let fresh = launchApp(template: variants)
        XCTAssertTrue(fresh.staticTexts["importConflictSummary"].waitForExistence(timeout: 10))
        fresh.buttons["cancelTemplateImport"].tap()
        XCTAssertTrue(fresh.buttons["newTemplate"].waitForExistence(timeout: 10))
        XCTAssertFalse(fresh.buttons["startWorkout-Monday"].exists)
        fresh.buttons["templateActions"].tap()
        fresh.buttons["Exercise library"].tap()
        XCTAssertFalse(fresh.buttons["libraryExercise-Bench"].exists)
    }

    func testClearLibraryCancelConfirmAndReopenPreservesSavedWork() {
        let app = launchApp(backup: backupFixture)
        app.buttons["templateActions"].tap()
        app.buttons["Exercise library"].tap()
        XCTAssertTrue(app.buttons["libraryExercise-Bench"].waitForExistence(timeout: 10))
        app.buttons["libraryActions"].tap()
        app.buttons["clearLibrary"].tap()
        XCTAssertTrue(app.buttons["confirmClearLibrary"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["libraryExercise-Bench"].exists)
        app.buttons["libraryActions"].tap()
        app.buttons["clearLibrary"].tap()
        app.buttons["confirmClearLibrary"].tap()
        XCTAssertFalse(app.buttons["libraryExercise-Bench"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["resumeWorkout"].waitForExistence(timeout: 10))
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.buttons["history-Old Push"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Templates"].tap()
        app.buttons["templateActions"].tap()
        app.buttons["Exercise library"].tap()
        XCTAssertFalse(app.buttons["libraryExercise-Bench"].exists)
    }

    func testCalendarWalkingRepeatOverrideCompletionAndReopen() {
        let app = launchApp()
        app.tabBars.buttons["Calendar"].tap()
        XCTAssertTrue(app.buttons["calendarToday"].waitForExistence(timeout: 10))
        app.buttons["calendarAssign"].tap()
        app.segmentedControls["calendarKind"].buttons["Walking"].tap()
        app.switches["calendarRepeating"].tap()
        app.buttons["saveCalendarAssignment"].tap()
        XCTAssertTrue(app.buttons["markWalkDone"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["calendarStatus"].label, "Not completed")
        app.buttons["markWalkDone"].tap()
        XCTAssertTrue(app.buttons["undoWalkDone"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["calendarStatus"].label, "Completed")
        app.buttons["calendarNextMonth"].tap()
        app.buttons["calendarToday"].tap()
        XCTAssertEqual(app.staticTexts["calendarStatus"].label, "Completed")
        app.terminate()
        app.launch()
        app.tabBars.buttons["Calendar"].tap()
        XCTAssertTrue(app.buttons["undoWalkDone"].waitForExistence(timeout: 10))
        app.buttons["undoWalkDone"].tap()
        XCTAssertEqual(app.staticTexts["calendarStatus"].label, "Not completed")
        app.buttons["calendarAssign"].tap()
        app.segmentedControls["calendarKind"].buttons["Clear"].tap()
        app.switches["calendarRepeating"].tap()
        app.buttons["saveCalendarAssignment"].tap()
        XCTAssertTrue(app.staticTexts["calendarStatus"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["calendarStatus"].label, "No assignment")
        XCTAssertFalse(app.buttons["markWalkDone"].exists)
    }

    func testCalendarStartsResumesFinishesAndRecalculatesAfterDeletion() {
        let app = launchApp()
        createTemplate(in: app)
        app.tabBars.buttons["Calendar"].tap()
        app.buttons["calendarAssign"].tap()
        XCTAssertTrue(app.buttons["saveCalendarAssignment"].waitForExistence(timeout: 10))
        app.buttons["saveCalendarAssignment"].tap()
        XCTAssertTrue(app.buttons["calendarStart"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["calendarStatus"].label, "Not completed")
        app.buttons["calendarStart"].tap()
        XCTAssertTrue(app.buttons["plannedSet-Bench-1"].waitForExistence(timeout: 10))
        app.buttons["plannedSet-Bench-1"].tap()
        enter("20", in: app.textFields["setWeight"])
        enter("8", in: app.textFields["setReps"])
        app.buttons["saveSet"].tap()
        app.buttons["Close"].tap()
        app.tabBars.buttons["Calendar"].tap()
        XCTAssertTrue(app.buttons["calendarResume"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["calendarStatus"].label, "Not completed")
        app.buttons["calendarResume"].tap()
        XCTAssertTrue(app.buttons["finishWorkout"].waitForExistence(timeout: 10))
        app.buttons["finishWorkout"].tap()
        app.buttons["Finish workout"].tap()
        app.tabBars.buttons["Calendar"].tap()
        XCTAssertTrue(app.staticTexts["calendarStatus"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["calendarStatus"].label, "Completed")
        app.tabBars.buttons["History"].tap()
        app.buttons["history-Push day"].swipeLeft()
        app.buttons["Delete"].tap()
        app.buttons["Delete workout"].tap()
        app.tabBars.buttons["Calendar"].tap()
        XCTAssertTrue(app.staticTexts["calendarStatus"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["calendarStatus"].label, "Not completed")
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
