import SwiftData
import XCTest
@testable import WorkoutLog

// Match the v0.3 stored fields; nested names keep these entities separate in Swift.
private enum LegacyStore {
    @Model final class WorkoutTemplate {
        var id: UUID
        var name: String
        var exercises: [String]
        init(id: UUID) { self.id = id; name = "Old push"; exercises = ["Bench", "Press"] }
    }
    @Model final class WorkoutSession {
        var id: UUID
        var startedAt: Date
        var finishedAt: Date?
        var templateName: String
        var exercises: [String]
        var unit: String
        var sets: [LoggedSet]
        init(id: UUID, finished: Bool, set: LoggedSet) {
            self.id = id
            startedAt = Date(timeIntervalSince1970: 1_700_000_000)
            finishedAt = finished ? Date(timeIntervalSince1970: 1_700_003_600) : nil
            templateName = "Old push"
            exercises = ["Bench", "Press"]
            unit = finished ? "kg" : "lb"
            sets = [set]
        }
    }
}

@MainActor
final class UpgradeTests: XCTestCase {
    private func writeLegacyStore(_ url: URL, templateID: UUID, draftID: UUID, historyID: UUID, set: LoggedSet) throws {
        let schema = Schema([LegacyStore.WorkoutTemplate.self, LegacyStore.WorkoutSession.self])
        XCTAssertEqual(Set(schema.entities.map(\.name)), ["WorkoutTemplate", "WorkoutSession"])
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let db = try ModelContainer(for: schema, configurations: [config])
        db.mainContext.autosaveEnabled = false
        db.mainContext.insert(LegacyStore.WorkoutTemplate(id: templateID))
        db.mainContext.insert(LegacyStore.WorkoutSession(id: draftID, finished: false, set: set))
        db.mainContext.insert(LegacyStore.WorkoutSession(id: historyID, finished: true, set: set))
        try db.mainContext.save()
    }

    func testVersionThreeStoreUpgradesWithoutChangingSavedWorkouts() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutLog-upgrade-\(UUID()).store")
        let templateID = UUID(), draftID = UUID(), historyID = UUID()
        let set = LoggedSet(exercise: "Bench", weight: 45, reps: 8, rpe: 7.5)
        try writeLegacyStore(url, templateID: templateID, draftID: draftID, historyID: historyID, set: set)
        let schema = Schema([WorkoutTemplate.self, WorkoutSession.self, LibraryExercise.self, LibrarySetup.self, CalendarRule.self, WalkingCompletion.self])
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let db = try ModelContainer(for: schema, configurations: [config])
        db.mainContext.autosaveEnabled = false
        let template = try XCTUnwrap(db.mainContext.fetch(FetchDescriptor<WorkoutTemplate>()).first)
        XCTAssertEqual(template.id, templateID)
        XCTAssertEqual(template.name, "Old push")
        XCTAssertEqual(template.exercises, ["Bench", "Press"])
        XCTAssertNil(template.setCounts)
        let sessions = try db.mainContext.fetch(FetchDescriptor<WorkoutSession>())
        XCTAssertEqual(Set(sessions.map(\.id)), [draftID, historyID])
        for session in sessions {
            XCTAssertEqual(session.startedAt, Date(timeIntervalSince1970: 1_700_000_000))
            XCTAssertEqual(session.exercises, ["Bench", "Press"])
            XCTAssertEqual(session.sets, [set])
            XCTAssertNil(session.plannedSets)
            XCTAssertEqual(session.rows(for: "Bench").map(\.id), [set.id])
        }
        let draft = try XCTUnwrap(sessions.first { $0.id == draftID })
        XCTAssertNil(draft.finishedAt)
        XCTAssertEqual(draft.unit, "lb")
        let history = try XCTUnwrap(sessions.first { $0.id == historyID })
        XCTAssertEqual(history.finishedAt, Date(timeIntervalSince1970: 1_700_003_600))
        XCTAssertEqual(history.unit, "kg")
        try db.mainContext.commit { template.setCounts = [3, 2] }
        XCTAssertNil(draft.plannedSets)
        XCTAssertEqual(history.sets, [set])
        XCTAssertEqual(try DataTransfer.snapshot(in: db.mainContext, unit: .lb).sessions.count, 2)
    }
}
