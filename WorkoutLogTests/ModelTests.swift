import SwiftData
import XCTest
@testable import WorkoutLog

@MainActor
final class ModelTests: XCTestCase {
    private func container(url: URL? = nil) throws -> ModelContainer {
        let schema = Schema([WorkoutTemplate.self, WorkoutSession.self, LibraryExercise.self, LibrarySetup.self])
        let config: ModelConfiguration
        if let url {
            config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        } else {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        }
        let container = try ModelContainer(for: schema, configurations: [config])
        container.mainContext.autosaveEnabled = false
        return container
    }

    func testSetValidation() throws {
        for rpe in [0.0, 10.0] {
            XCTAssertNoThrow(try LoggedSet(exercise: "Push-up", weight: 0, reps: 1, rpe: rpe).validate())
        }
        for weight in [-1.0, .infinity, -.infinity, .nan] {
            XCTAssertThrowsError(try LoggedSet(exercise: "Squat", weight: weight, reps: 8, rpe: 7).validate())
        }
        for reps in [0, -1] {
            XCTAssertThrowsError(try LoggedSet(exercise: "Squat", weight: 20, reps: reps, rpe: 7).validate())
        }
        for rpe in [-1.0, 11.0, .infinity, .nan] {
            XCTAssertThrowsError(try LoggedSet(exercise: "Squat", weight: 20, reps: 8, rpe: rpe).validate())
        }
    }

    func testLocalizedWeightInput() throws {
        let english = Locale(identifier: "en_US")
        let german = Locale(identifier: "de_DE")
        XCTAssertEqual(try WeightInput.parse(" 20.5 ", locale: english), 20.5)
        XCTAssertEqual(try WeightInput.parse("20,5", locale: german), 20.5)
        XCTAssertEqual(try WeightInput.parse("0", locale: german), 0)
        for invalid in ["", "-1", "NaN", "inf", "1e3", "20kg", "1.2.3", "20.", ".", "1 000", "20,5"] {
            XCTAssertThrowsError(try WeightInput.parse(invalid, locale: english), invalid)
        }
        XCTAssertThrowsError(try WeightInput.parse("20.5", locale: german))
        XCTAssertThrowsError(try WeightInput.parse(String(repeating: "9", count: 400), locale: english))
        for locale in [english, german] {
            for value in [0, 20.1, 1.2345678901234567, 1e-20, 1e20] {
                XCTAssertEqual(try WeightInput.parse(WeightInput.format(value, locale: locale), locale: locale), value)
            }
        }
    }

    func testTemplateValidationAndExerciseOrder() throws {
        let (name, exercises) = try WorkoutTemplate.validated(name: " Push ", exercises: [" Bench ", "Press"])
        XCTAssertEqual(name, "Push")
        XCTAssertEqual(exercises, ["Bench", "Press"])
        XCTAssertThrowsError(try WorkoutTemplate.validated(name: " ", exercises: ["Bench"]))
        XCTAssertThrowsError(try WorkoutTemplate.validated(name: "Push", exercises: []))
        XCTAssertThrowsError(try WorkoutTemplate.validated(name: "Push", exercises: [" "]))
        XCTAssertThrowsError(try WorkoutTemplate.validated(name: "Push", exercises: ["Bench", " bench "]))
    }

    func testDraftLifecycleAndSetCorrections() throws {
        let store = try container()
        let context = store.mainContext
        let template = WorkoutTemplate(name: "Push", exercises: ["Bench"])
        try context.commit { context.insert(template) }
        let session = try WorkoutSession.start(template: template, unit: .kg, in: context)
        XCTAssertThrowsError(try context.commit { try session.finish() })
        XCTAssertNil(session.finishedAt)
        XCTAssertThrowsError(try WorkoutSession.start(template: template, unit: .kg, in: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkoutSession>()), 1)
        let first = LoggedSet(exercise: "Bench", weight: 20, reps: 8, rpe: 7)
        try context.commit { try session.record(first) }
        var edited = first
        edited.reps = 10
        try context.commit { try session.record(edited) }
        XCTAssertEqual(session.sets, [edited])
        XCTAssertThrowsError(try context.commit { try session.record(LoggedSet(exercise: "Not in template", weight: 20, reps: 8, rpe: 7)) })
        XCTAssertEqual(session.sets, [edited])
        try context.commit { session.sets.removeAll { $0.id == first.id } }
        XCTAssertTrue(session.sets.isEmpty)
        try context.commit { try session.record(first); try session.finish() }
        XCTAssertNotNil(session.finishedAt)
        XCTAssertThrowsError(try session.record(first))
        XCTAssertThrowsError(try session.finish())
        _ = try WorkoutSession.start(template: template, unit: .lb, in: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkoutSession>()), 2)
    }

    func testTemplateChangesAndUnitsDoNotRewriteSessions() throws {
        let store = try container()
        let context = store.mainContext
        let template = WorkoutTemplate(name: "Push", exercises: ["Bench", "Press"])
        try context.commit { context.insert(template) }
        let completed = try WorkoutSession.start(template: template, unit: .kg, in: context)
        let set = LoggedSet(exercise: "Bench", weight: 20, reps: 8, rpe: 7)
        try context.commit { try completed.record(set); try completed.finish() }
        let draft = try WorkoutSession.start(template: template, unit: .lb, in: context)
        try context.commit { template.name = "Renamed"; template.exercises = ["Different"] }
        try context.commit { context.delete(template) }
        for session in [completed, draft] {
            XCTAssertEqual(session.templateName, "Push")
            XCTAssertEqual(session.exercises, ["Bench", "Press"])
        }
        XCTAssertEqual(completed.unit, "kg")
        XCTAssertEqual(draft.unit, "lb")
        XCTAssertEqual(completed.sets, [set])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkoutTemplate>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkoutSession>()), 2)
    }

    func testFailedChangeReloadsSavedDataInFreshContext() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutLog-failure-\(UUID()).store")
        let store = try container(url: url)
        let context = store.mainContext
        let template = WorkoutTemplate(name: "Original", exercises: ["Bench"])
        try context.commit { context.insert(template) }
        let session = try WorkoutSession.start(template: template, unit: .kg, in: context)
        let set = LoggedSet(exercise: "Bench", weight: 20, reps: 8, rpe: 7)
        try context.commit { try session.record(set) }
        let failure = expectation(forNotification: .workoutSaveFailed, object: context)
        XCTAssertThrowsError(try context.commit {
            template.name = "Unsaved change"
            session.sets = []
            context.delete(session)
            context.insert(WorkoutTemplate(name: "Never saved", exercises: ["Press"]))
            throw LogError(message: "Simulated failure")
        })
        wait(for: [failure], timeout: 1)
        XCTAssertFalse(context.hasChanges)
        XCTAssertFalse(context.autosaveEnabled)
        // Do not reuse stale SwiftData objects after rollback; the app replaces the context too.
        let fresh = ModelContext(store)
        let templates = try fresh.fetch(FetchDescriptor<WorkoutTemplate>())
        XCTAssertEqual(templates.count, 1)
        XCTAssertEqual(templates.first?.name, "Original")
        let sessions = try fresh.fetch(FetchDescriptor<WorkoutSession>())
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.sets, [set])
        try fresh.save()
        let reopened = try container(url: url)
        XCTAssertEqual(try reopened.mainContext.fetch(FetchDescriptor<WorkoutTemplate>()).first?.name, "Original")
        XCTAssertEqual(try reopened.mainContext.fetch(FetchDescriptor<WorkoutSession>()).first?.sets, [set])
    }

    func testPersistenceAfterReopen() throws {
        // Leave this unique temporary store intact; never remove existing user files in tests.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutLog-test-\(UUID()).store")
        let set = LoggedSet(exercise: "Bench", weight: 20.5, reps: 8, rpe: 10)
        var draftID: UUID?
        do {
            let store = try container(url: url)
            let context = store.mainContext
            let template = WorkoutTemplate(name: "Push", exercises: ["Bench", "Press"])
            try context.commit { context.insert(template) }
            let completed = try WorkoutSession.start(template: template, unit: .kg, in: context)
            try context.commit { try completed.record(set); try completed.finish() }
            let draft = try WorkoutSession.start(template: template, unit: .lb, in: context)
            try context.commit { try draft.record(set) }
            draftID = draft.id
        }
        let reopened = try container(url: url)
        let context = reopened.mainContext
        let templates = try context.fetch(FetchDescriptor<WorkoutTemplate>())
        XCTAssertEqual(templates.first?.exercises, ["Bench", "Press"])
        let sessions = try context.fetch(FetchDescriptor<WorkoutSession>())
        XCTAssertEqual(sessions.count, 2)
        let draft = try XCTUnwrap(sessions.first { $0.finishedAt == nil })
        XCTAssertEqual(draft.id, draftID)
        XCTAssertEqual(draft.sets, [set])
        XCTAssertEqual(draft.exercises, ["Bench", "Press"])
        XCTAssertEqual(draft.unit, "lb")
        let completed = try XCTUnwrap(sessions.first { $0.finishedAt != nil })
        XCTAssertEqual(completed.sets, [set])
        XCTAssertEqual(completed.unit, "kg")
    }
}
