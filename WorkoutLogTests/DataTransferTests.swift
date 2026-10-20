import SwiftData
import XCTest
@testable import WorkoutLog

@MainActor
final class DataTransferTests: XCTestCase {
    private func store(url: URL? = nil) throws -> ModelContainer {
        let schema = Schema([WorkoutTemplate.self, WorkoutSession.self])
        let config = url.map { ModelConfiguration(schema: schema, url: $0, cloudKitDatabase: .none) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        container.mainContext.autosaveEnabled = false
        return container
    }

    private func populated(_ context: ModelContext) throws -> DataTransfer.Backup {
        let template = WorkoutTemplate(name: "Push", exercises: ["Bench", "Press"])
        try context.commit { context.insert(template) }
        let session = try WorkoutSession.start(template: template, unit: .kg, in: context)
        try context.commit {
            try session.record(LoggedSet(exercise: "Bench", weight: 20.5, reps: 8, rpe: 0))
            try session.record(LoggedSet(exercise: "Press", weight: 0, reps: 10, rpe: 10))
            try session.finish()
        }
        let draft = try WorkoutSession.start(template: template, unit: .lb, in: context)
        try context.commit {
            try draft.record(LoggedSet(exercise: "Bench", weight: 45, reps: 5, rpe: 7))
        }
        return try DataTransfer.snapshot(in: context, unit: .lb)
    }

    func testTemplateDraftValidationAndOrder() throws {
        let draft = try TemplateDraft.decode(Data(#"{"name":" Push ","exercises":[" Bench ","Press"]}"#.utf8))
        XCTAssertEqual(draft.name, "Push")
        XCTAssertEqual(draft.exercises, ["Bench", "Press"])
        for input in ["{}", "[]", "not json", #"{"name":"Push","exercises":[]}"#,
                      #"{"name":"Push","exercises":["Bench","bench"]}"#] {
            XCTAssertThrowsError(try TemplateDraft.decode(Data(input.utf8)))
        }
    }

    func testBackupRoundTripReopenAndIdempotency() throws {
        let source = try store()
        let original = try populated(source.mainContext)
        let decoded = try DataTransfer.decode(DataTransfer.encode(original))
        XCTAssertEqual(decoded, original)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutLog-transfer-\(UUID()).store")
        do {
            let target = try store(url: url)
            let (preview, unit) = try DataTransfer.apply(decoded, in: target.mainContext)
            XCTAssertEqual(preview.templates.count, 1)
            XCTAssertEqual(preview.sessions.count, 2)
            XCTAssertEqual(unit, .lb)
            XCTAssertEqual(try DataTransfer.snapshot(in: target.mainContext, unit: .lb), original)
            let (again, preference) = try DataTransfer.apply(decoded, in: target.mainContext)
            XCTAssertEqual(again.templates.count, 0)
            XCTAssertEqual(again.sessions.count, 0)
            XCTAssertEqual(again.skippedSessions, 2)
            XCTAssertNil(preference)
        }
        let reopened = try store(url: url)
        XCTAssertEqual(try DataTransfer.snapshot(in: reopened.mainContext, unit: .lb), original)
    }

    func testExistingBackupSkipsItsOwnMillisecondDates() throws {
        let container = try store()
        let backup = try populated(container.mainContext)
        let decoded = try DataTransfer.decode(DataTransfer.encode(backup))
        let preview = try DataTransfer.preview(decoded, in: container.mainContext)
        XCTAssertTrue(preview.sessions.isEmpty)
        XCTAssertEqual(preview.skippedSessions, 2)
    }

    func testMergeKeepsUnrelatedDataAndPreference() throws {
        let source = try store()
        var backup = try populated(source.mainContext)
        backup.sessions.removeAll { $0.finishedAt == nil }
        let target = try store()
        let unrelated = WorkoutTemplate(name: "Pull", exercises: ["Row"])
        try target.mainContext.commit { target.mainContext.insert(unrelated) }
        let (_, preference) = try DataTransfer.apply(backup, in: target.mainContext)
        XCTAssertNil(preference)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<WorkoutTemplate>()), 2)
        XCTAssertEqual(unrelated.name, "Pull")
        XCTAssertEqual(try target.mainContext.fetch(FetchDescriptor<WorkoutSession>()).first?.unit, "kg")
    }

    func testHistoryWithoutLiveTemplateCanRestore() throws {
        let source = try store()
        var backup = try populated(source.mainContext)
        backup.templates = []
        let target = try store()
        try DataTransfer.apply(backup, in: target.mainContext)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<WorkoutTemplate>()), 0)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<WorkoutSession>()), 2)
    }

    func testConflictsAndChangedStateAreAtomic() throws {
        let container = try store()
        let context = container.mainContext
        let backup = try populated(context)
        var conflicting = backup
        conflicting.templates[0].name = "Different copy"
        XCTAssertThrowsError(try DataTransfer.apply(conflicting, in: context))
        XCTAssertEqual(try DataTransfer.snapshot(in: context, unit: .lb), backup)
        XCTAssertFalse(context.hasChanges)
        _ = try DataTransfer.preview(backup, in: context)
        let existing = try XCTUnwrap(context.fetch(FetchDescriptor<WorkoutTemplate>()).first)
        try context.commit { existing.name = "Changed after preview" }
        XCTAssertThrowsError(try DataTransfer.apply(backup, in: context))
        XCTAssertEqual(existing.name, "Changed after preview")
    }

    func testAnotherDraftIsRejectedWithoutPartialImport() throws {
        let source = try store()
        let backup = try populated(source.mainContext)
        let target = try store()
        _ = try populated(target.mainContext)
        let before = try DataTransfer.snapshot(in: target.mainContext, unit: .kg)
        XCTAssertThrowsError(try DataTransfer.apply(backup, in: target.mainContext))
        XCTAssertEqual(try DataTransfer.snapshot(in: target.mainContext, unit: .kg), before)
        XCTAssertFalse(target.mainContext.hasChanges)
    }

    func testInvalidBackupsRejectBeforeMutation() throws {
        let source = try store()
        let backup = try populated(source.mainContext)
        var variants: [DataTransfer.Backup] = []
        var invalid = backup; invalid.schemaVersion = 99; variants.append(invalid)
        invalid = backup; invalid.templates.append(invalid.templates[0]); variants.append(invalid)
        invalid = backup; invalid.sessions.append(invalid.sessions[0]); variants.append(invalid)
        invalid = backup; invalid.templates[0].name = " "; variants.append(invalid)
        invalid = backup; invalid.sessions[0].sets[0].weight = -.infinity; variants.append(invalid)
        invalid = backup; invalid.sessions[0].sets[0].rpe = 11; variants.append(invalid)
        invalid = backup; invalid.sessions[0].sets[0].reps = 0; variants.append(invalid)
        invalid = backup; invalid.sessions[0].sets[0].exercise = "Missing"; variants.append(invalid)
        invalid = backup; invalid.sessions[0].sets.append(invalid.sessions[0].sets[0]); variants.append(invalid)
        invalid = backup; invalid.sessions[0].startedAt = "not a date"; variants.append(invalid)
        invalid = backup; invalid.sessions[0].finishedAt = "2026-01-01"; variants.append(invalid)
        invalid = backup; invalid.sessions[0].sets = []; variants.append(invalid)
        invalid = backup; invalid.sessions[0].finishedAt = nil; variants.append(invalid)
        let target = try store()
        for variant in variants {
            XCTAssertThrowsError(try DataTransfer.apply(variant, in: target.mainContext))
            XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<WorkoutTemplate>()), 0)
            XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<WorkoutSession>()), 0)
            XCTAssertFalse(target.mainContext.hasChanges)
        }
    }

    func testMalformedOversizedFilesAndStrictUnits() throws {
        XCTAssertThrowsError(try DataTransfer.decode(Data("garbage".utf8)))
        let source = try store()
        let backup = try populated(source.mainContext)
        let data = try DataTransfer.encode(backup)
        let badUnit = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"kg\"", with: "\"tons\"")
        XCTAssertThrowsError(try DataTransfer.decode(Data(badUnit.utf8)))
        let badID = String(decoding: data, as: UTF8.self).replacingOccurrences(of: backup.templates[0].id.uuidString, with: "not-a-uuid")
        XCTAssertThrowsError(try DataTransfer.decode(Data(badID.utf8)))
        let oversized = Data(repeating: 32, count: DataTransfer.maximumBytes + 1)
        XCTAssertThrowsError(try DataTransfer.decode(oversized))
        XCTAssertThrowsError(try TemplateDraft.decode(oversized))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutLog-size-\(UUID()).json")
        try oversized.write(to: url)
        XCTAssertThrowsError(try DataTransfer.read(url))
        XCTAssertThrowsError(try DataTransfer.read(url.appendingPathExtension("missing")))
    }
}
