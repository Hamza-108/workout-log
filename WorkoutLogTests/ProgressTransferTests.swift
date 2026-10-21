import SwiftData
import XCTest
@testable import WorkoutLog

@MainActor
final class ProgressTransferTests: XCTestCase {
    private let bodyID = "44444444-4444-4444-8444-444444444444"
    private let otherBodyID = "55555555-5555-4555-8555-555555555555"

    private func store(url: URL? = nil) throws -> ModelContainer {
        let schema = Schema([WorkoutTemplate.self, WorkoutSession.self, LibraryExercise.self, LibrarySetup.self, CalendarRule.self, WalkingCompletion.self, BodyWeightEntry.self])
        let config = url.map { ModelConfiguration(schema: schema, url: $0, cloudKitDatabase: .none) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        container.mainContext.autosaveEnabled = false
        return container
    }

    private func populated(_ context: ModelContext) throws -> DataTransfer.Backup {
        let template = WorkoutTemplate(name: "Push", exercises: ["Bench"], setCounts: [2])
        try context.commit { context.insert(template) }
        let session = try WorkoutSession.start(template: template, unit: .kg, in: context)
        let warmupSlot = try XCTUnwrap(session.plannedSets?.first)
        try context.commit {
            try session.record(LoggedSet(id: warmupSlot.id, exercise: "Bench", weight: 10, reps: 8, rpe: 5, kind: .warmup))
            try session.record(LoggedSet(exercise: "Bench", weight: 22.5, reps: 5, rpe: 8, kind: .working))
            try session.finish()
        }
        try context.commit {
            context.insert(BodyWeightEntry(day: "2026-01-02", weight: 80.5, unit: .kg))
            context.insert(BodyWeightEntry(day: "2026-01-03", weight: 176.9, unit: .lb))
        }
        return try DataTransfer.snapshot(in: context, unit: .lb)
    }

    // MARK: - JSON helpers

    private func bodyJSON(id: String, day: String, weight: String, unit: String = "kg") -> String {
        "{\"id\": \"\(id)\", \"day\": \"\(day)\", \"weight\": \(weight), \"unit\": \"\(unit)\"}"
    }

    private func sessionJSON(setKind: String? = nil, plannedKind: String? = nil) -> String {
        let kindField = setKind.map { ", \"kind\": \"\($0)\"" } ?? ""
        let planned = plannedKind.map {
            ", \"plannedSets\": [{\"id\": \"33333333-3333-4333-8333-333333333333\", \"exercise\": \"Bench\", \"kind\": \"\($0)\"}]"
        } ?? ""
        return "{\"id\": \"22222222-2222-4222-8222-222222222222\", \"startedAt\": \"2026-01-01T12:00:00.000Z\", \"finishedAt\": \"2026-01-01T13:00:00.000Z\", \"templateName\": \"Old\", \"exercises\": [\"Bench\"], \"unit\": \"kg\", \"sets\": [{\"id\": \"33333333-3333-4333-8333-333333333333\", \"exercise\": \"Bench\", \"weight\": 20, \"reps\": 5, \"rpe\": 6\(kindField)}]\(planned)}"
    }

    private func backupJSON(version: Int, sessions: String = "", body: String = "") -> String {
        let bodyField = body.isEmpty ? "" : ", \"bodyWeights\": [\(body)]"
        return "{\"schemaVersion\": \(version), \"preferredWeightUnit\": \"kg\", \"templates\": [], \"sessions\": [\(sessions)]\(bodyField)}"
    }

    private func legacyJSON(version: Int) -> String {
        let counts = version == 1 ? "" : ", \"setCounts\": [2]"
        let planned = version == 1 ? "" : ", \"plannedSets\": [{\"id\": \"33333333-3333-4333-8333-333333333333\", \"exercise\": \"Bench\"}]"
        return "{\"schemaVersion\": \(version), \"preferredWeightUnit\": \"kg\", \"templates\": [{\"id\": \"11111111-1111-4111-8111-111111111111\", \"name\": \"Old\", \"exercises\": [\"Bench\"]\(counts)}], \"sessions\": [{\"id\": \"22222222-2222-4222-8222-222222222222\", \"startedAt\": \"2026-01-01T12:00:00.000Z\", \"finishedAt\": \"2026-01-01T13:00:00.000Z\", \"templateName\": \"Old\", \"exercises\": [\"Bench\"], \"unit\": \"kg\", \"sets\": [{\"id\": \"33333333-3333-4333-8333-333333333333\", \"exercise\": \"Bench\", \"weight\": 20, \"reps\": 5, \"rpe\": 6}]\(planned)}]}"
    }

    // MARK: - Round trip

    func testVersionFiveBackupKeepsKindsAndBodyWeightsAcrossReopen() throws {
        let source = try store()
        let original = try populated(source.mainContext)
        XCTAssertEqual(original.schemaVersion, 5)
        let body = try XCTUnwrap(original.bodyWeights)
        XCTAssertEqual(body.count, 2)
        XCTAssertEqual(body.map(\.day), ["2026-01-02", "2026-01-03"])
        XCTAssertEqual(body.map(\.unit), [.kg, .lb])
        XCTAssertEqual(original.sessions[0].sets.map(\.kind), [.warmup, .working])
        let originalPlanned = try XCTUnwrap(original.sessions[0].plannedSets)
        XCTAssertEqual(originalPlanned.map(\.kind), [.warmup, nil, .working])

        let decoded = try DataTransfer.decode(DataTransfer.encode(original))
        XCTAssertEqual(decoded, original)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutLog-progress-\(UUID()).store")
        do {
            let target = try store(url: url)
            let (preview, preference) = try DataTransfer.apply(decoded, in: target.mainContext)
            XCTAssertEqual(preview.bodyWeights.count, 2)
            XCTAssertEqual(preview.skippedBodyWeights, 0)
            XCTAssertTrue(preview.summary.contains("Body weights: 2 new, 0 already saved."))
            XCTAssertEqual(preference, .lb)
            XCTAssertEqual(try DataTransfer.snapshot(in: target.mainContext, unit: .lb), original)
            let (again, secondPreference) = try DataTransfer.apply(decoded, in: target.mainContext)
            XCTAssertTrue(again.bodyWeights.isEmpty)
            XCTAssertEqual(again.skippedBodyWeights, 2)
            XCTAssertNil(secondPreference)
        }
        let reopened = try store(url: url)
        XCTAssertEqual(try DataTransfer.snapshot(in: reopened.mainContext, unit: .lb), original)
        let entries = try reopened.mainContext.fetch(FetchDescriptor<BodyWeightEntry>(sortBy: [SortDescriptor(\.day)]))
        XCTAssertEqual(entries.map(\.day), ["2026-01-02", "2026-01-03"])
        XCTAssertEqual(entries.map(\.weight), [80.5, 176.9])
        XCTAssertEqual(entries.map(\.unit), ["kg", "lb"])
        let sessions = try reopened.mainContext.fetch(FetchDescriptor<WorkoutSession>())
        let stored = try XCTUnwrap(sessions.first)
        XCTAssertEqual(stored.sets.map(\.kind), [.warmup, .working])
        XCTAssertEqual(stored.sets.map(\.effectiveKind), [.warmup, .working])
        let storedPlanned = try XCTUnwrap(stored.plannedSets)
        XCTAssertEqual(storedPlanned.map(\.kind), [.warmup, nil, .working])
    }

    func testLegacyBackupsImportAsWorkingSetsWithoutBodyWeights() throws {
        for version in 1...4 {
            let backup = try DataTransfer.decode(Data(legacyJSON(version: version).utf8))
            XCTAssertEqual(backup.schemaVersion, version)
            XCTAssertNil(backup.bodyWeights)
            let sets = try XCTUnwrap(backup.sessions.first).sets
            XCTAssertFalse(sets.isEmpty)
            for set in sets {
                XCTAssertNil(set.kind)
                XCTAssertEqual(set.effectiveKind, .working)
            }
            let target = try store()
            try DataTransfer.apply(backup, in: target.mainContext)
            let sessions = try target.mainContext.fetch(FetchDescriptor<WorkoutSession>())
            let stored = try XCTUnwrap(sessions.first)
            XCTAssertEqual(stored.sets.count, 1)
            XCTAssertNil(stored.sets.first?.kind)
            XCTAssertEqual(stored.sets.first?.effectiveKind, .working)
            XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<BodyWeightEntry>()), 0)
        }
    }

    // MARK: - Rejections

    func testMalformedBodyWeightsAreRejected() throws {
        XCTAssertNoThrow(try DataTransfer.decode(Data(backupJSON(version: 5, body: bodyJSON(id: bodyID, day: "2026-01-02", weight: "80.5")).utf8)))
        for entry in [bodyJSON(id: bodyID, day: "2026-01-02", weight: "0"),
                      bodyJSON(id: bodyID, day: "2026-01-02", weight: "-80.5"),
                      bodyJSON(id: bodyID, day: "2026-02-30", weight: "80.5"),
                      bodyJSON(id: bodyID, day: "2026-1-2", weight: "80.5"),
                      bodyJSON(id: bodyID, day: "tomorrow", weight: "80.5"),
                      bodyJSON(id: bodyID, day: "2026-01-02", weight: "80.5", unit: "tons")] {
            XCTAssertThrowsError(try DataTransfer.decode(Data(backupJSON(version: 5, body: entry).utf8)))
        }
        let duplicateID = bodyJSON(id: bodyID, day: "2026-01-02", weight: "80.5") + ", " + bodyJSON(id: bodyID, day: "2026-01-03", weight: "80.6")
        XCTAssertThrowsError(try DataTransfer.decode(Data(backupJSON(version: 5, body: duplicateID).utf8)))
        let duplicateDay = bodyJSON(id: bodyID, day: "2026-01-02", weight: "80.5") + ", " + bodyJSON(id: otherBodyID, day: "2026-01-02", weight: "80.6")
        XCTAssertThrowsError(try DataTransfer.decode(Data(backupJSON(version: 5, body: duplicateDay).utf8)))

        let source = try store()
        var backup = try populated(source.mainContext)
        backup.bodyWeights = [DataTransfer.BodyWeight(id: UUID(), day: "2026-01-02", weight: .infinity, unit: .kg)]
        XCTAssertThrowsError(try backup.validate())
        backup.bodyWeights = [DataTransfer.BodyWeight(id: UUID(), day: "2026-01-02", weight: .nan, unit: .kg)]
        XCTAssertThrowsError(try backup.validate())
        backup.bodyWeights = [DataTransfer.BodyWeight(id: UUID(), day: "2026-01-02", weight: 0, unit: .kg)]
        XCTAssertThrowsError(try backup.validate())
        backup.bodyWeights = [DataTransfer.BodyWeight(id: UUID(), day: "2026-01-02", weight: -1, unit: .kg)]
        XCTAssertThrowsError(try backup.validate())
        backup.bodyWeights = [DataTransfer.BodyWeight(id: UUID(), day: "2026-02-30", weight: 80, unit: .kg)]
        XCTAssertThrowsError(try backup.validate())
    }

    func testOlderVersionsCannotClaimBodyWeightsOrSetKinds() throws {
        let body = bodyJSON(id: bodyID, day: "2026-01-02", weight: "80.5")
        XCTAssertThrowsError(try DataTransfer.decode(Data(backupJSON(version: 4, body: body).utf8)))
        XCTAssertThrowsError(try DataTransfer.decode(Data(backupJSON(version: 4, sessions: sessionJSON(setKind: "warmup")).utf8)))
        XCTAssertThrowsError(try DataTransfer.decode(Data(backupJSON(version: 4, sessions: sessionJSON(plannedKind: "warmup")).utf8)))
        XCTAssertNoThrow(try DataTransfer.decode(Data(backupJSON(version: 5, body: body).utf8)))
        XCTAssertNoThrow(try DataTransfer.decode(Data(backupJSON(version: 5, sessions: sessionJSON(setKind: "warmup")).utf8)))
        // An unknown set kind never decodes.
        XCTAssertThrowsError(try DataTransfer.decode(Data(backupJSON(version: 5, sessions: sessionJSON(setKind: "bogus")).utf8)))

        let source = try store()
        let original = try populated(source.mainContext)
        XCTAssertNoThrow(try original.validate())
        var lying = original
        lying.schemaVersion = 4
        XCTAssertThrowsError(try lying.validate())
    }

    func testLoggedSetMustMatchItsPlannedSet() throws {
        let kindMismatch = backupJSON(version: 5, sessions: sessionJSON(setKind: "working", plannedKind: "warmup"))
        XCTAssertThrowsError(try DataTransfer.decode(Data(kindMismatch.utf8)))
        let exerciseMismatch = "{\"id\": \"22222222-2222-4222-8222-222222222222\", \"startedAt\": \"2026-01-01T12:00:00.000Z\", \"finishedAt\": \"2026-01-01T13:00:00.000Z\", \"templateName\": \"Old\", \"exercises\": [\"Bench\", \"Row\"], \"unit\": \"kg\", \"sets\": [{\"id\": \"33333333-3333-4333-8333-333333333333\", \"exercise\": \"Row\", \"weight\": 20, \"reps\": 5, \"rpe\": 6}], \"plannedSets\": [{\"id\": \"33333333-3333-4333-8333-333333333333\", \"exercise\": \"Bench\"}]}"
        XCTAssertThrowsError(try DataTransfer.decode(Data(backupJSON(version: 5, sessions: exerciseMismatch).utf8)))
    }

    // MARK: - Merging

    func testBodyWeightMergeConflictsAreAllOrNothing() throws {
        let source = try store()
        let original = try populated(source.mainContext)
        let target = try store()
        let existing = BodyWeightEntry(day: "2026-01-02", weight: 80.5, unit: .kg)
        try target.mainContext.commit { target.mainContext.insert(existing) }

        // Same day, different ID: the whole import is rejected.
        var sameDay = original
        sameDay.bodyWeights = [DataTransfer.BodyWeight(id: UUID(), day: "2026-01-02", weight: 81, unit: .kg)]
        XCTAssertThrowsError(try DataTransfer.apply(sameDay, in: target.mainContext))
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<BodyWeightEntry>()), 1)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<WorkoutTemplate>()), 0)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<WorkoutSession>()), 0)

        // Same ID, different weight: also rejected, without overwriting.
        var sameID = original
        sameID.bodyWeights = [DataTransfer.BodyWeight(id: existing.id, day: "2026-01-02", weight: 81, unit: .kg)]
        XCTAssertThrowsError(try DataTransfer.apply(sameID, in: target.mainContext))
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<BodyWeightEntry>()), 1)
        let kept = try XCTUnwrap(target.mainContext.fetch(FetchDescriptor<BodyWeightEntry>()).first)
        XCTAssertEqual(kept.weight, 80.5)

        // An identical record is skipped while the rest of the backup still imports.
        let originalBody = try XCTUnwrap(original.bodyWeights?.first)
        let identical = BodyWeightEntry(day: "2026-01-02", weight: 80.5, unit: .kg)
        identical.id = originalBody.id
        try target.mainContext.commit { target.mainContext.delete(existing) }
        try target.mainContext.commit { target.mainContext.insert(identical) }
        let (preview, preference) = try DataTransfer.apply(original, in: target.mainContext)
        XCTAssertEqual(preview.bodyWeights.count, 1)
        XCTAssertEqual(preview.skippedBodyWeights, 1)
        XCTAssertNil(preference)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<BodyWeightEntry>()), 2)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<WorkoutTemplate>()), 1)
    }

    func testBodyOnlyStoreKeepsTheCurrentUnitPreference() throws {
        let source = try store()
        let original = try populated(source.mainContext)
        let target = try store()
        try target.mainContext.commit { target.mainContext.insert(BodyWeightEntry(day: "2025-12-01", weight: 79, unit: .kg)) }
        let (preview, preference) = try DataTransfer.apply(original, in: target.mainContext)
        XCTAssertNil(preference)
        XCTAssertFalse(preview.restorePreference)
        XCTAssertEqual(preview.bodyWeights.count, 2)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<BodyWeightEntry>()), 3)

        let empty = try store()
        let (_, restored) = try DataTransfer.apply(original, in: empty.mainContext)
        XCTAssertEqual(restored, .lb)
    }

    func testBackupAcceptsFutureBodyWeightDays() throws {
        let json = backupJSON(version: 5, body: bodyJSON(id: bodyID, day: "2099-12-31", weight: "80.5"))
        let backup = try DataTransfer.decode(Data(json.utf8))
        let target = try store()
        try DataTransfer.apply(backup, in: target.mainContext)
        let entries = try target.mainContext.fetch(FetchDescriptor<BodyWeightEntry>())
        XCTAssertEqual(entries.map(\.day), ["2099-12-31"])
        XCTAssertEqual(entries.map(\.weight), [80.5])
    }

    // MARK: - Failure handling

    func testReadOnlyStoreRollsBackAFailedImport() throws {
        let source = try store()
        let backup = try populated(source.mainContext)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutLog-progress-readonly-\(UUID()).store")
        do {
            let target = try store(url: url)
            try target.mainContext.commit { target.mainContext.insert(WorkoutTemplate(name: "Kept", exercises: ["Row"])) }
        }
        let schema = Schema([WorkoutTemplate.self, WorkoutSession.self, LibraryExercise.self, LibrarySetup.self, CalendarRule.self, WalkingCompletion.self, BodyWeightEntry.self])
        let config = ModelConfiguration(schema: schema, url: url, allowsSave: false, cloudKitDatabase: .none)
        do {
            let target = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(target)
            context.autosaveEnabled = false
            let failure = expectation(forNotification: .workoutSaveFailed, object: context)
            XCTAssertThrowsError(try DataTransfer.apply(backup, in: context))
            wait(for: [failure], timeout: 1)
            XCTAssertFalse(context.hasChanges)
            let fresh = ModelContext(target)
            XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<WorkoutSession>()), 0)
            XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<BodyWeightEntry>()), 0)
            XCTAssertEqual(try fresh.fetch(FetchDescriptor<WorkoutTemplate>()).map(\.name), ["Kept"])
        }
        let reopened = try store(url: url)
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<WorkoutSession>()), 0)
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<BodyWeightEntry>()), 0)
        XCTAssertEqual(try reopened.mainContext.fetch(FetchDescriptor<WorkoutTemplate>()).map(\.name), ["Kept"])
    }
}
