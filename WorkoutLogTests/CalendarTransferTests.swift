import SwiftData
import XCTest
@testable import WorkoutLog

private enum VersionFiveStore {
    @Model final class WorkoutTemplate {
        var id: UUID
        var name: String
        var exercises: [String]
        var setCounts: [Int]?
        var videoURLs: [String: String]?
        init(id: UUID) {
            self.id = id; name = "Monday"; exercises = ["Bench"]; setCounts = [3]
            videoURLs = ["Bench": "https://www.youtube.com/watch?v=abcdefghijk"]
        }
    }
    @Model final class WorkoutSession {
        var id: UUID
        var startedAt: Date
        var finishedAt: Date?
        var templateName: String
        var exercises: [String]
        var unit: String
        var sets: [LoggedSet]
        var plannedSets: [PlannedSet]?
        var videoURLs: [String: String]?
        init(id: UUID, row: PlannedSet) {
            self.id = id; startedAt = Date(timeIntervalSince1970: 1_700_000_000)
            templateName = "Monday"; exercises = ["Bench"]; unit = "lb"
            sets = [LoggedSet(id: row.id, exercise: "Bench", weight: 45.5, reps: 8, rpe: 7.5)]
            plannedSets = [row, PlannedSet(exercise: "Bench")]
            videoURLs = ["Bench": "https://www.youtube.com/watch?v=abcdefghijk"]
        }
    }
}

@MainActor
final class CalendarTransferTests: XCTestCase {
    private let utc = Schedule.calendar(timeZone: TimeZone(secondsFromGMT: 0)!)

    private func store(_ url: URL? = nil) throws -> ModelContainer {
        let schema = Schema([WorkoutTemplate.self, WorkoutSession.self, LibraryExercise.self, LibrarySetup.self, CalendarRule.self, WalkingCompletion.self])
        let config = url.map { ModelConfiguration(schema: schema, url: $0, cloudKitDatabase: .none) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let db = try ModelContainer(for: schema, configurations: [config])
        db.mainContext.autosaveEnabled = false
        return db
    }

    private func populated() throws -> DataTransfer.Backup {
        let db = try store(), context = db.mainContext
        let template = WorkoutTemplate(name: "Monday", exercises: ["Bench"], setCounts: [3])
        try context.commit { context.insert(template) }
        try Schedule.assign(on: "2026-10-19", kind: .template, template: template, repeating: true, in: context)
        try Schedule.assign(on: "2026-10-20", kind: .walking, repeating: false, in: context)
        try Schedule.markWalk(on: "2026-10-20", done: true, in: context, now: try XCTUnwrap(Schedule.date("2026-10-21", calendar: utc)), calendar: utc)
        let session = try WorkoutSession.start(template: template, unit: .lb, in: context)
        let finished = try XCTUnwrap(Schedule.date("2026-10-19", calendar: utc))
        try context.commit {
            session.startedAt = finished.addingTimeInterval(-3600)
            try session.record(LoggedSet(exercise: "Bench", weight: 45, reps: 8, rpe: 7.5))
            try session.finish(at: finished, calendar: utc)
        }
        return try DataTransfer.snapshot(in: context, unit: .lb)
    }

    func testCalendarBackupRoundTripReopenAndIdempotency() throws {
        let original = try populated()
        XCTAssertEqual(original.schemaVersion, 4)
        XCTAssertEqual(original.calendarRules?.count, 2)
        XCTAssertEqual(original.walkingCompletions?.count, 1)
        XCTAssertEqual(original.sessions.first?.completedDay, "2026-10-19")
        XCTAssertEqual(original.sessions.first?.sourceTemplateID, original.templates.first?.id)
        let backup = try DataTransfer.decode(DataTransfer.encode(original))
        XCTAssertEqual(backup, original)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutLog-calendar-backup-\(UUID()).store")
        do {
            let db = try store(url)
            let (preview, preference) = try DataTransfer.apply(backup, in: db.mainContext)
            XCTAssertEqual(preview.calendarRules.count, 2)
            XCTAssertEqual(preview.walkingCompletions.count, 1)
            XCTAssertEqual(preference, .lb)
            let (again, _) = try DataTransfer.apply(backup, in: db.mainContext)
            XCTAssertTrue(again.calendarRules.isEmpty)
            XCTAssertTrue(again.walkingCompletions.isEmpty)
            XCTAssertEqual(again.skippedRules, 2)
            XCTAssertEqual(again.skippedWalks, 1)
        }
        let reopened = try store(url)
        XCTAssertEqual(try DataTransfer.snapshot(in: reopened.mainContext, unit: .lb), original)
        let rules = try reopened.mainContext.fetch(FetchDescriptor<CalendarRule>())
        let sessions = try reopened.mainContext.fetch(FetchDescriptor<WorkoutSession>())
        let walks = try reopened.mainContext.fetch(FetchDescriptor<WalkingCompletion>())
        XCTAssertEqual(Schedule.status(on: "2026-10-19", rules: rules, sessions: sessions, walks: walks), .completed)
        XCTAssertEqual(Schedule.status(on: "2026-10-20", rules: rules, sessions: sessions, walks: walks), .completed)
    }

    func testCalendarBackupRejectsInvalidAndOverlappingRules() throws {
        let good = try populated()
        var variants: [DataTransfer.Backup] = []
        var bad = good; bad.calendarRules?[0].startDay = "2026-02-30"; variants.append(bad)
        bad = good; bad.calendarRules?[0].kind = "unknown"; variants.append(bad)
        bad = good; bad.calendarRules?[0].templateID = nil; variants.append(bad)
        bad = good; bad.calendarRules?[0].weekday = 9; variants.append(bad)
        let walk = try XCTUnwrap(good.walkingCompletions?.first)
        bad = good; bad.walkingCompletions?.append(walk); variants.append(bad)
        bad = good; bad.sessions[0].completedDay = "2026-02-30"; variants.append(bad)
        bad = good; bad.sessions[0].finishedAt = nil; variants.append(bad)
        bad = good; bad.schemaVersion = 3; variants.append(bad)
        for variant in variants { XCTAssertThrowsError(try variant.validate()) }

        let db = try store()
        let existing = CalendarRule(startDay: "2026-10-19", weekday: 2, kind: .walking)
        try db.mainContext.commit { db.mainContext.insert(existing) }
        XCTAssertThrowsError(try DataTransfer.apply(good, in: db.mainContext))
        XCTAssertEqual(try db.mainContext.fetchCount(FetchDescriptor<CalendarRule>()), 1)
        XCTAssertEqual(try db.mainContext.fetchCount(FetchDescriptor<WorkoutTemplate>()), 0)
        XCTAssertEqual(try db.mainContext.fetchCount(FetchDescriptor<WalkingCompletion>()), 0)
    }

    func testDeletedTemplateDoesNotEraseCalendarOrSnapshot() throws {
        let db = try store()
        try DataTransfer.apply(populated(), in: db.mainContext)
        let template = try XCTUnwrap(db.mainContext.fetch(FetchDescriptor<WorkoutTemplate>()).first)
        let id = template.id
        try db.mainContext.commit { db.mainContext.delete(template) }
        let backup = try DataTransfer.snapshot(in: db.mainContext, unit: .lb)
        XCTAssertEqual(backup.calendarRules?.first?.templateID, id)
        XCTAssertEqual(backup.sessions.first?.sourceTemplateID, id)
        XCTAssertTrue(backup.templates.isEmpty)
        XCTAssertNoThrow(try DataTransfer.decode(DataTransfer.encode(backup)))
    }

    func testOlderBackupsImportWithoutGuessingCalendarMatches() throws {
        for version in 1...3 {
            let json = "{\"schemaVersion\":\(version),\"preferredWeightUnit\":\"kg\",\"templates\":[],\"sessions\":[]}"
            let backup = try DataTransfer.decode(Data(json.utf8))
            XCTAssertNil(backup.calendarRules)
            XCTAssertNil(backup.walkingCompletions)
            let db = try store()
            try DataTransfer.apply(backup, in: db.mainContext)
            XCTAssertEqual(try db.mainContext.fetchCount(FetchDescriptor<CalendarRule>()), 0)
        }
    }

    private func writeOldStore(_ url: URL, templateID: UUID, sessionID: UUID, row: PlannedSet) throws {
        let schema = Schema([VersionFiveStore.WorkoutTemplate.self, VersionFiveStore.WorkoutSession.self, LibraryExercise.self, LibrarySetup.self])
        let db = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        db.mainContext.autosaveEnabled = false
        db.mainContext.insert(VersionFiveStore.WorkoutTemplate(id: templateID))
        db.mainContext.insert(VersionFiveStore.WorkoutSession(id: sessionID, row: row))
        db.mainContext.insert(LibraryExercise(name: "Bench", videoURL: "https://www.youtube.com/watch?v=abcdefghijk"))
        db.mainContext.insert(LibrarySetup())
        try db.mainContext.save()
    }

    func testVersionFiveDiskUpgradeKeepsDataAndDoesNotGuessTemplateIDs() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutLog-v5-calendar-\(UUID()).store")
        let templateID = UUID(), sessionID = UUID(), row = PlannedSet(exercise: "Bench")
        try writeOldStore(url, templateID: templateID, sessionID: sessionID, row: row)
        let db = try store(url)
        let template = try XCTUnwrap(db.mainContext.fetch(FetchDescriptor<WorkoutTemplate>()).first)
        let session = try XCTUnwrap(db.mainContext.fetch(FetchDescriptor<WorkoutSession>()).first)
        XCTAssertEqual(template.id, templateID)
        XCTAssertEqual(template.videoURLs?["Bench"], "https://www.youtube.com/watch?v=abcdefghijk")
        XCTAssertEqual(session.id, sessionID)
        XCTAssertNil(session.sourceTemplateID)
        XCTAssertNil(session.completedDay)
        XCTAssertNil(session.finishedAt)
        XCTAssertEqual(session.sets.first?.id, row.id)
        XCTAssertEqual(session.sets.first?.rpe, 7.5)
        XCTAssertEqual(session.rows(for: "Bench").count, 2)
        XCTAssertEqual(try db.mainContext.fetchCount(FetchDescriptor<CalendarRule>()), 0)
        XCTAssertEqual(try db.mainContext.fetchCount(FetchDescriptor<LibraryExercise>()), 1)
        XCTAssertEqual(try db.mainContext.fetchCount(FetchDescriptor<LibrarySetup>()), 1)
    }
}
