import SwiftData
import XCTest
@testable import WorkoutLog

@MainActor
final class PlannedSetTests: XCTestCase {
    private func store(_ url: URL? = nil) throws -> ModelContainer {
        let schema = Schema([WorkoutTemplate.self, WorkoutSession.self, LibraryExercise.self, LibrarySetup.self])
        let config = url.map { ModelConfiguration(schema: schema, url: $0, cloudKitDatabase: .none) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let result = try ModelContainer(for: schema, configurations: [config])
        result.mainContext.autosaveEnabled = false
        return result
    }

    func testPlannedSetsSnapshotResumeAndStableIdentity() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutLog-planned-\(UUID()).store")
        var slots: [PlannedSet] = []
        var actual: LoggedSet?
        do {
            let db = try store(url)
            let context = db.mainContext
            let template = WorkoutTemplate(name: "Push", exercises: ["Bench", "Press"], setCounts: [3, 2])
            try context.commit { context.insert(template) }
            let session = try WorkoutSession.start(template: template, unit: .lb, in: context)
            slots = try XCTUnwrap(session.plannedSets)
            XCTAssertEqual(slots.map(\.exercise), ["Bench", "Bench", "Bench", "Press", "Press"])
            XCTAssertEqual(Set(slots.map(\.id)).count, 5)
            XCTAssertTrue(session.sets.isEmpty)
            XCTAssertThrowsError(try session.finish())
            XCTAssertThrowsError(try session.record(LoggedSet(id: slots[0].id, exercise: "Press", weight: 0, reps: 1, rpe: 0)))
            XCTAssertTrue(session.sets.isEmpty)
            actual = LoggedSet(id: slots[2].id, exercise: "Bench", weight: 45, reps: 8, rpe: 7.5)
            try context.commit {
                try session.record(try XCTUnwrap(actual))
                template.name = "Changed"
                template.exercises = ["Different"]
                template.setCounts = [1]
            }
            XCTAssertEqual(session.rows(for: "Bench").map(\.id), Array(slots.prefix(3)).map(\.id))
            XCTAssertEqual(session.sets.count, 1)
            XCTAssertEqual(session.plannedSets, slots)
        }
        let reopened = try store(url)
        let session = try XCTUnwrap(reopened.mainContext.fetch(FetchDescriptor<WorkoutSession>()).first)
        XCTAssertEqual(session.plannedSets, slots)
        XCTAssertEqual(session.sets, [try XCTUnwrap(actual)])
        XCTAssertEqual(session.exercises, ["Bench", "Press"])
        XCTAssertEqual(session.unit, "lb")
    }

    func testAddRemoveEditAndFinishDoNotLogPlaceholders() throws {
        let db = try store()
        let context = db.mainContext
        let template = WorkoutTemplate(name: "Push", exercises: ["Bench"], setCounts: [3])
        try context.commit { context.insert(template) }
        let session = try WorkoutSession.start(template: template, unit: .kg, in: context)
        let slots = try XCTUnwrap(session.plannedSets)
        var set = LoggedSet(id: slots[1].id, exercise: "Bench", weight: 20, reps: 8, rpe: 7.5)
        try context.commit { try session.record(set) }
        set.reps = 10
        try context.commit { try session.record(set) }
        XCTAssertEqual(session.sets, [set])
        XCTAssertEqual(session.plannedSets?.count, 3)
        XCTAssertThrowsError(try session.record(LoggedSet(id: slots[0].id, exercise: "Other", weight: 0, reps: 1, rpe: 0)))
        let extra = LoggedSet(exercise: "Bench", weight: 0, reps: 5, rpe: 6)
        try context.commit { try session.record(extra) }
        XCTAssertEqual(session.plannedSets?.count, 4)
        try context.commit { try session.removeSet(slots[0].id) }
        XCTAssertEqual(session.plannedSets?.count, 3)
        XCTAssertEqual(session.sets.count, 2)
        try context.commit { try session.removeSet(extra.id) }
        XCTAssertEqual(session.sets, [set])
        XCTAssertEqual(session.plannedSets?.count, 2)
        XCTAssertEqual(template.setCounts, [3])
        try context.commit { try session.finish() }
        XCTAssertEqual(session.sets, [set])
        XCTAssertThrowsError(try session.removeSet(set.id))
    }

    func testLegacySessionsKeepTheirLoggedRowsAndNoPresets() throws {
        let db = try store()
        let template = WorkoutTemplate(name: "Old", exercises: ["Bench"])
        let session = try WorkoutSession.start(template: template, unit: .kg, in: db.mainContext)
        XCTAssertNil(session.plannedSets)
        let set = LoggedSet(exercise: "Bench", weight: 20, reps: 8, rpe: 7)
        try db.mainContext.commit { try session.record(set) }
        XCTAssertEqual(session.rows(for: "Bench"), [PlannedSet(id: set.id, exercise: "Bench")])
        XCTAssertNil(session.plannedSets)
    }

    func testInvalidPresetCountsCannotStartWorkout() throws {
        let db = try store()
        for counts in [[], [0], [-1], [100], [3, 2]] {
            let template = WorkoutTemplate(name: "Bad", exercises: ["Bench"], setCounts: counts)
            XCTAssertThrowsError(try WorkoutSession.start(template: template, unit: .kg, in: db.mainContext))
        }
        XCTAssertEqual(try db.mainContext.fetchCount(FetchDescriptor<WorkoutSession>()), 0)
    }

}
