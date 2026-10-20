import SwiftData
import XCTest
@testable import WorkoutLog

private enum VersionFourStore {
    @Model final class WorkoutTemplate {
        var id: UUID
        var name: String
        var exercises: [String]
        var setCounts: [Int]?
        init(id: UUID) { self.id = id; name = "Monday"; exercises = ["Bench"]; setCounts = [3] }
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
        init(id: UUID, row: PlannedSet) {
            self.id = id; startedAt = Date(timeIntervalSince1970: 1_700_000_000)
            templateName = "Monday"; exercises = ["Bench"]; unit = "lb"
            sets = [LoggedSet(id: row.id, exercise: "Bench", weight: 45.5, reps: 8, rpe: 7.5)]
            plannedSets = [row, PlannedSet(exercise: "Bench")]
        }
    }
}

@MainActor
final class ExerciseLibraryTests: XCTestCase {
    private func store(_ url: URL? = nil) throws -> ModelContainer {
        let schema = Schema([WorkoutTemplate.self, WorkoutSession.self, LibraryExercise.self, LibrarySetup.self, CalendarRule.self, WalkingCompletion.self])
        let config = url.map { ModelConfiguration(schema: schema, url: $0, cloudKitDatabase: .none) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let db = try ModelContainer(for: schema, configurations: [config])
        db.mainContext.autosaveEnabled = false
        return db
    }

    func testSeedOnceDeduplicatesAndDoesNotResurrectDeletedExercises() throws {
        let db = try store(), context = db.mainContext
        let monday = WorkoutTemplate(name: "Monday", exercises: ["Bench", "Row"], setCounts: [3, 2])
        let friday = WorkoutTemplate(name: "Friday", exercises: ["bench"], setCounts: [5])
        try context.commit { context.insert(monday); context.insert(friday) }
        try LibraryExercise.seedOnce(in: context)
        let entries = try context.fetch(FetchDescriptor<LibraryExercise>())
        XCTAssertEqual(Set(entries.map { $0.name.lowercased() }), ["bench", "row"])
        try context.commit { for entry in entries { context.delete(entry) } }
        try LibraryExercise.seedOnce(in: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LibraryExercise>()), 0)
        XCTAssertEqual(monday.setCounts, [3, 2])
        XCTAssertEqual(friday.exercises, ["bench"])
    }

    func testLibraryAndTemplateAndSessionCopiesAreIndependent() throws {
        let db = try store(), context = db.mainContext
        let video = "https://www.youtube.com/watch?v=abcdefghijk"
        let exercise = LibraryExercise(name: "Bench", videoURL: video)
        let template = WorkoutTemplate(name: "Monday", exercises: [exercise.name], setCounts: [3], videoURLs: [exercise.name: video])
        try context.commit { context.insert(exercise); context.insert(template) }
        let session = try WorkoutSession.start(template: template, unit: .kg, in: context)
        try context.commit {
            exercise.name = "Press"; exercise.videoURL = nil
            template.videoURLs = nil; template.setCounts = [5]
        }
        XCTAssertEqual(session.videoURLs, ["Bench": video])
        XCTAssertEqual(session.rows(for: "Bench").count, 3)
        XCTAssertEqual(template.exercises, ["Bench"])
        XCTAssertThrowsError(try LibraryExercise.checkUnique(" press ".trimmingCharacters(in: .whitespaces), in: context))
        XCTAssertNoThrow(try LibraryExercise.checkUnique("Press", excluding: exercise.id, in: context))
        try context.commit { context.delete(exercise) }
        XCTAssertEqual(template.exercises, ["Bench"])
        XCTAssertEqual(session.videoURLs, ["Bench": video])
        try context.commit {
            try session.record(LoggedSet(exercise: "Bench", weight: 20, reps: 8, rpe: 7))
            try session.finish()
        }
        template.videoURLs = ["Unknown": video]
        XCTAssertThrowsError(try WorkoutSession.start(template: template, unit: .kg, in: context))
    }

    func testLibraryNameAndLinkValidation() throws {
        let result = try LibraryExercise.validated(name: " Bench ", videoURL: "https://youtu.be/abcdefghijk?si=tracking")
        XCTAssertEqual(result.0, "Bench")
        XCTAssertEqual(result.1, "https://www.youtube.com/watch?v=abcdefghijk")
        XCTAssertThrowsError(try LibraryExercise.validated(name: " ", videoURL: nil))
        XCTAssertThrowsError(try LibraryExercise.validated(name: "Bench", videoURL: "https://example.com"))
    }

    private func writeVersionFour(_ url: URL, templateID: UUID, sessionID: UUID, row: PlannedSet) throws {
        let schema = Schema([VersionFourStore.WorkoutTemplate.self, VersionFourStore.WorkoutSession.self])
        let db = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        db.mainContext.autosaveEnabled = false
        db.mainContext.insert(VersionFourStore.WorkoutTemplate(id: templateID))
        db.mainContext.insert(VersionFourStore.WorkoutSession(id: sessionID, row: row))
        try db.mainContext.save()
    }

    func testVersionFourDiskUpgradePreservesRowsAndSeedsLibraryOnce() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutLog-v4-upgrade-\(UUID()).store")
        let templateID = UUID(), sessionID = UUID(), row = PlannedSet(exercise: "Bench")
        try writeVersionFour(url, templateID: templateID, sessionID: sessionID, row: row)
        do {
            let db = try store(url), context = db.mainContext
            try LibraryExercise.seedOnce(in: context)
            let template = try XCTUnwrap(context.fetch(FetchDescriptor<WorkoutTemplate>()).first)
            let session = try XCTUnwrap(context.fetch(FetchDescriptor<WorkoutSession>()).first)
            XCTAssertEqual(template.id, templateID)
            XCTAssertEqual(template.setCounts, [3])
            XCTAssertNil(template.videoURLs)
            XCTAssertEqual(session.id, sessionID)
            XCTAssertNil(session.videoURLs)
            XCTAssertNil(session.finishedAt)
            XCTAssertEqual(session.startedAt, Date(timeIntervalSince1970: 1_700_000_000))
            XCTAssertEqual(session.unit, "lb")
            XCTAssertEqual(session.sets.first?.id, row.id)
            XCTAssertEqual(session.sets.first?.rpe, 7.5)
            XCTAssertEqual(session.sets.first?.weight, 45.5)
            XCTAssertEqual(session.rows(for: "Bench").count, 2)
            let exercise = try XCTUnwrap(context.fetch(FetchDescriptor<LibraryExercise>()).first)
            XCTAssertEqual(exercise.name, "Bench")
            try context.commit { context.delete(exercise) }
        }
        let reopened = try store(url)
        try LibraryExercise.seedOnce(in: reopened.mainContext)
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<LibraryExercise>()), 0)
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<WorkoutTemplate>()), 1)
    }
}
