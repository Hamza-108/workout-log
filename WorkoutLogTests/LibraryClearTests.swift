import SwiftData
import XCTest
@testable import WorkoutLog

@MainActor
final class LibraryClearTests: XCTestCase {
    private func store(url: URL? = nil, writable: Bool = true) throws -> ModelContainer {
        let schema = Schema([WorkoutTemplate.self, WorkoutSession.self, LibraryExercise.self, LibrarySetup.self, CalendarRule.self, WalkingCompletion.self])
        let configuration = url.map { ModelConfiguration(schema: schema, url: $0, allowsSave: writable, cloudKitDatabase: .none) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let store = try ModelContainer(for: schema, configurations: [configuration])
        store.mainContext.autosaveEnabled = false
        return store
    }

    func testClearAndReopenNeverReseedsOrChangesTemplatesSessionsOrCalendar() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryClear-\(UUID()).store")
        let video = "https://www.youtube.com/watch?v=bEv6CCg2BC8&t=147"
        do {
            let store = try store(url: url)
            let context = store.mainContext
            let template = WorkoutTemplate(name: "Monday", exercises: ["Back Squat"], setCounts: [3], videoURLs: ["Back Squat": video])
            try context.commit { context.insert(template) }
            try LibraryExercise.seedOnce(in: context)
            let session = try WorkoutSession.start(template: template, unit: .lb, in: context)
            try context.commit { try session.record(LoggedSet(exercise: "Back Squat", weight: 40, reps: 8, rpe: 7.5)) }
            try Schedule.assign(on: "2026-10-19", kind: .template, template: template, repeating: true, in: context)
            try Schedule.assign(on: "2026-10-20", kind: .walking, repeating: false, in: context)
            try Schedule.markWalk(on: "2026-10-20", done: true, in: context,
                                  now: try XCTUnwrap(Schedule.date("2026-10-21")), calendar: Schedule.calendar())
            let before = try DataTransfer.snapshot(in: context, unit: .kg)
            let ids = Set(try context.fetch(FetchDescriptor<LibraryExercise>()).map(\.id))
            try LibraryExercise.clear(in: context, expectedIDs: ids)
            let after = try DataTransfer.snapshot(in: context, unit: .kg)
            XCTAssertEqual(after.libraryExercises, [])
            XCTAssertEqual(after.templates, before.templates)
            XCTAssertEqual(after.sessions, before.sessions)
            XCTAssertEqual(after.calendarRules, before.calendarRules)
            XCTAssertEqual(after.walkingCompletions, before.walkingCompletions)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<LibrarySetup>()), 1)
        }
        let reopened = try store(url: url)
        try LibraryExercise.seedOnce(in: reopened.mainContext)
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<LibraryExercise>()), 0)
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<WorkoutTemplate>()), 1)
        let session = try XCTUnwrap(reopened.mainContext.fetch(FetchDescriptor<WorkoutSession>()).first)
        XCTAssertNil(session.finishedAt)
        XCTAssertEqual(session.sets.first?.rpe, 7.5)
        XCTAssertEqual(session.videoURLs?["Back Squat"], video)
        XCTAssertEqual(session.unit, "lb")
    }

    func testStaleConfirmationRejectsWithoutClearingAnything() throws {
        let store = try store()
        let context = store.mainContext
        let original = LibraryExercise(name: "Bench")
        try context.commit { context.insert(original) }
        let confirmation: Set<UUID> = [original.id]
        try context.commit { context.insert(LibraryExercise(name: "Row")) }
        XCTAssertThrowsError(try LibraryExercise.clear(in: context, expectedIDs: confirmation))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LibraryExercise>()), 2)
        XCTAssertFalse(context.hasChanges)
    }

    func testFailedClearRollsBackAndKeepsSavedLibraryOnDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryClear-readonly-\(UUID()).store")
        var ids: Set<UUID> = []
        do {
            let store = try store(url: url)
            let context = store.mainContext
            let exercise = LibraryExercise(name: "Bench")
            try context.commit { context.insert(exercise); context.insert(LibrarySetup()) }
            ids = [exercise.id]
        }
        do {
            let store = try store(url: url, writable: false)
            XCTAssertThrowsError(try LibraryExercise.clear(in: store.mainContext, expectedIDs: ids))
            XCTAssertFalse(store.mainContext.hasChanges)
        }
        let reopened = try store(url: url)
        XCTAssertEqual(try reopened.mainContext.fetch(FetchDescriptor<LibraryExercise>()).map(\.name), ["Bench"])
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<LibrarySetup>()), 1)
    }
}
