import Foundation
import SwiftData
import XCTest
@testable import WorkoutLog

// The training-progress and body-weight rules: optional set kinds (working and
// warm-up) on planned and logged rows, per-kind row numbers, the last-session
// hint, the lifting progress list and the body-weight tracker. The backup
// transfer of the same records is covered by another file.
@MainActor
final class TrainingProgressTests: XCTestCase {
    // MARK: - Helpers

    private func container(url: URL? = nil) throws -> ModelContainer {
        let schema = Schema([WorkoutTemplate.self, WorkoutSession.self, LibraryExercise.self, LibrarySetup.self, CalendarRule.self, WalkingCompletion.self, BodyWeightEntry.self])
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

    private func zone(_ identifier: String) throws -> TimeZone {
        try XCTUnwrap(TimeZone(identifier: identifier))
    }

    /// A noon date, so a day key and an instant never drift into each other.
    private func noon(_ day: String, calendar: Calendar) throws -> Date {
        try XCTUnwrap(Schedule.date(day, calendar: calendar), day)
    }

    @discardableResult
    private func makeTemplate(_ name: String, _ exercises: [String], counts: [Int]? = nil,
                              in context: ModelContext) throws -> WorkoutTemplate {
        let template = WorkoutTemplate(name: name, exercises: exercises, setCounts: counts)
        try context.commit { context.insert(template) }
        return template
    }

    /// A workout written straight into the store, so the test controls every
    /// row, every date and the order of the logged sets.
    @discardableResult
    private func makeSession(template: String, exercises: [String], unit: WeightUnit = .kg,
                             startedAt: Date, finishedAt: Date?, sets: [LoggedSet],
                             planned: [PlannedSet]? = nil, in context: ModelContext) throws -> WorkoutSession {
        let session = WorkoutSession(templateName: template, exercises: exercises, unit: unit)
        session.startedAt = startedAt
        session.finishedAt = finishedAt
        session.sets = sets
        session.plannedSets = planned
        try context.commit { context.insert(session) }
        return session
    }

    // MARK: - Stored kinds

    func testStoredSetsWithoutAKindDecodeAsWorkingAndUnknownKindsAreRejected() throws {
        // A row saved before the kinds existed carries no kind at all.
        let legacy = """
        {"id":"11111111-1111-4111-8111-111111111111","exercise":"Bench","weight":45,"reps":8,"rpe":7.5}
        """
        let logged = try JSONDecoder().decode(LoggedSet.self, from: Data(legacy.utf8))
        XCTAssertNil(logged.kind)
        XCTAssertEqual(logged.effectiveKind, .working)
        XCTAssertEqual(logged.id.uuidString, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(logged.exercise, "Bench")
        XCTAssertEqual(logged.weight, 45)
        XCTAssertEqual(logged.reps, 8)
        XCTAssertEqual(logged.rpe, 7.5)

        let planned = try JSONDecoder().decode(PlannedSet.self, from: Data(#"{"id":"22222222-2222-4222-8222-222222222222","exercise":"Bench"}"#.utf8))
        XCTAssertNil(planned.kind)
        XCTAssertEqual(planned.effectiveKind, .working)

        // A kind the app does not know is refused instead of being ignored.
        let unknown = """
        {"id":"11111111-1111-4111-8111-111111111111","exercise":"Bench","weight":45,"reps":8,"rpe":7.5,"kind":"superset"}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(LoggedSet.self, from: Data(unknown.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(PlannedSet.self, from: Data(#"{"id":"22222222-2222-4222-8222-222222222222","exercise":"Bench","kind":"superset"}"#.utf8)))

        // A known kind survives a round trip.
        let warmup = try JSONDecoder().decode(LoggedSet.self, from: Data(#"{"id":"11111111-1111-4111-8111-111111111111","exercise":"Bench","weight":20,"reps":10,"rpe":4,"kind":"warmup"}"#.utf8))
        XCTAssertEqual(warmup.kind, .warmup)
        XCTAssertEqual(warmup.effectiveKind, .warmup)
        let encoder = JSONEncoder()
        let roundTrip = try JSONDecoder().decode(LoggedSet.self, from: encoder.encode(warmup))
        XCTAssertEqual(roundTrip, warmup)

        // A working set is stored without a kind, exactly like the older rows.
        let working = try encoder.encode(LoggedSet(exercise: "Bench", weight: 45, reps: 8, rpe: 7.5))
        XCTAssertFalse(String(decoding: working, as: UTF8.self).contains("kind"))
    }

    func testRecordingAWarmupExtraKeepsThePlannedWorkingRowsAndStoresBothKinds() throws {
        let store = try container()
        let context = store.mainContext
        let template = try makeTemplate("Push", ["Bench", "Press"], counts: [3, 2], in: context)
        let session = try WorkoutSession.start(template: template, unit: .kg, in: context)
        let plannedIDs = try XCTUnwrap(session.plannedSets).map(\.id)
        XCTAssertEqual(plannedIDs.count, 5)
        let benchRows = session.rows(for: "Bench")
        XCTAssertEqual(benchRows.count, 3)
        XCTAssertTrue(benchRows.allSatisfy { $0.effectiveKind == .working })

        let warmup = LoggedSet(exercise: "Bench", weight: 20, reps: 10, rpe: 4, kind: .warmup)
        try context.commit { try session.record(warmup) }

        // The extra warm-up row does not consume a planned working row.
        let workingRows = try XCTUnwrap(session.plannedSets).filter { $0.effectiveKind == .working }
        XCTAssertEqual(workingRows.map(\.id), plannedIDs)
        XCTAssertEqual(session.rows(for: "Bench").filter { $0.effectiveKind == .working }.map(\.id), Array(plannedIDs.prefix(3)))

        // The warm-up row sits in front of the first working row of its exercise.
        let allRows = try XCTUnwrap(session.plannedSets)
        let warmupIndex = try XCTUnwrap(allRows.firstIndex { $0.id == warmup.id })
        let firstWorkingIndex = try XCTUnwrap(allRows.firstIndex { $0.id == benchRows[0].id })
        XCTAssertLessThan(warmupIndex, firstWorkingIndex)
        // Working rows and warm-up rows are numbered apart.
        XCTAssertEqual(session.ordinal(for: allRows[warmupIndex]), 1)
        XCTAssertEqual(session.ordinal(for: allRows[firstWorkingIndex]), 1)

        // Logging the first planned working row keeps that row's identity.
        let working = LoggedSet(id: benchRows[0].id, exercise: "Bench", weight: 60, reps: 5, rpe: 8)
        try context.commit { try session.record(working) }
        XCTAssertEqual(session.sets.count, 2)
        XCTAssertEqual(session.sets.map(\.effectiveKind), [.warmup, .working])
        XCTAssertEqual(session.sets.map(\.id), [warmup.id, benchRows[0].id])
        XCTAssertEqual(session.setSummary, "1 working · 1 warm-up sets")
        XCTAssertEqual(session.rows(for: "Bench").filter { $0.effectiveKind == .working }.map(\.id), Array(plannedIDs.prefix(3)))
        XCTAssertEqual(session.rows(for: "Press").map(\.id), Array(plannedIDs.suffix(2)))
    }

    func testClassifyChangesThePlannedAndLoggedRowTogetherAndKeepsTheirIDs() throws {
        let store = try container()
        let context = store.mainContext
        let template = try makeTemplate("Push", ["Bench"], counts: [2], in: context)
        let session = try WorkoutSession.start(template: template, unit: .kg, in: context)
        let rows = session.rows(for: "Bench")
        XCTAssertEqual(rows.count, 2)
        let first = rows[0], second = rows[1]
        try context.commit { try session.record(LoggedSet(id: first.id, exercise: "Bench", weight: 60, reps: 5, rpe: 8)) }

        try context.commit { try session.classify(first.id, as: .warmup) }

        // The planned row and the logged row change together and keep their IDs.
        let planned = try XCTUnwrap(session.plannedSets)
        XCTAssertEqual(planned.map(\.id), [first.id, second.id])
        XCTAssertEqual(planned.map(\.kind), [SetKind.warmup, nil])
        XCTAssertEqual(session.sets.count, 1)
        XCTAssertEqual(session.sets[0].id, first.id)
        XCTAssertEqual(session.sets[0].kind, .warmup)
        XCTAssertEqual(session.sets[0].effectiveKind, .warmup)
        XCTAssertEqual(session.sets[0].weight, 60)
        // The other row is untouched.
        XCTAssertNil(planned[1].kind)
        XCTAssertEqual(session.rows(for: "Bench").count, 2)

        // A row that is gone cannot be classified.
        XCTAssertThrowsError(try session.classify(UUID(), as: .warmup))
        XCTAssertEqual(session.sets.count, 1)

        // Classifying back keeps the same identity.
        try context.commit { try session.classify(first.id, as: .working) }
        XCTAssertEqual(session.sets[0].kind, .working)
        XCTAssertEqual(try XCTUnwrap(session.plannedSets)[0].kind, .working)
        XCTAssertEqual(session.sets[0].id, first.id)
        XCTAssertEqual(session.rows(for: "Bench").map(\.id), [first.id, second.id])
    }

    func testClassifyWorksOnLegacyLoggedOnlyRowsAndRefusesFinishedWorkouts() throws {
        let store = try container()
        let context = store.mainContext
        // A workout saved before the planned rows existed has no plan at all.
        let legacy = WorkoutSession(templateName: "Old push", exercises: ["Bench"], unit: .kg)
        let set = LoggedSet(exercise: "Bench", weight: 40, reps: 8, rpe: 7)
        try context.commit {
            context.insert(legacy)
            try legacy.record(set)
        }
        XCTAssertNil(legacy.plannedSets)
        XCTAssertEqual(legacy.sets.count, 1)

        try context.commit { try legacy.classify(set.id, as: .warmup) }
        XCTAssertEqual(legacy.sets[0].kind, .warmup)
        XCTAssertEqual(legacy.sets[0].id, set.id)
        XCTAssertNil(legacy.plannedSets)
        // The legacy row counts as a warm-up row of its own.
        XCTAssertEqual(legacy.rows(for: "Bench").count, 1)
        let row = PlannedSet(id: set.id, exercise: "Bench", kind: .warmup)
        XCTAssertEqual(legacy.ordinal(for: row), 1)

        // A finished workout cannot be reclassified any more.
        try context.commit { try legacy.finish() }
        XCTAssertThrowsError(try legacy.classify(set.id, as: .working))
        XCTAssertEqual(legacy.sets[0].kind, .warmup)
    }

    func testRowNumbersCountPerKindAfterReclassifyingAndDeletingRows() throws {
        let store = try container()
        let context = store.mainContext
        let template = try makeTemplate("Push", ["Bench"], counts: [3], in: context)
        let session = try WorkoutSession.start(template: template, unit: .kg, in: context)
        let working = session.rows(for: "Bench")
        XCTAssertEqual(working.count, 3)
        let warmup = LoggedSet(exercise: "Bench", weight: 20, reps: 10, rpe: 4, kind: .warmup)
        try context.commit { try session.record(warmup) }

        let rows = session.rows(for: "Bench")
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.map(\.effectiveKind), [.warmup, .working, .working, .working])
        XCTAssertEqual(session.ordinal(for: rows[0]), 1)
        XCTAssertEqual(session.ordinal(for: rows[1]), 1)
        XCTAssertEqual(session.ordinal(for: rows[2]), 2)
        XCTAssertEqual(session.ordinal(for: rows[3]), 3)

        // The second working row becomes a warm-up row.
        try context.commit { try session.classify(working[1].id, as: .warmup) }
        let reclassified = session.rows(for: "Bench")
        XCTAssertEqual(reclassified.map(\.effectiveKind), [.warmup, .working, .warmup, .working])
        XCTAssertEqual(session.ordinal(for: reclassified[0]), 1)
        XCTAssertEqual(session.ordinal(for: reclassified[2]), 2)
        XCTAssertEqual(session.ordinal(for: reclassified[1]), 1)
        XCTAssertEqual(session.ordinal(for: reclassified[3]), 2)

        // Deleting the first working row moves the remaining numbers up.
        try context.commit { try session.removeSet(working[0].id) }
        let deleted = session.rows(for: "Bench")
        XCTAssertEqual(deleted.map(\.effectiveKind), [.warmup, .warmup, .working])
        XCTAssertEqual(session.ordinal(for: deleted[0]), 1)
        XCTAssertEqual(session.ordinal(for: deleted[1]), 2)
        XCTAssertEqual(session.ordinal(for: deleted[2]), 1)
    }

    func testDraftKindsSurviveClosingAndReopeningTheStoreOnDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutLog-training-kinds-\(UUID()).store")
        var loggedID = UUID()
        do {
            let store = try container(url: url)
            let context = store.mainContext
            let template = try makeTemplate("Push", ["Bench"], counts: [2], in: context)
            let session = try WorkoutSession.start(template: template, unit: .kg, in: context)
            let row = try XCTUnwrap(session.rows(for: "Bench").first)
            loggedID = row.id
            try context.commit {
                try session.record(LoggedSet(id: row.id, exercise: "Bench", weight: 60, reps: 5, rpe: 8))
                try session.record(LoggedSet(exercise: "Bench", weight: 20, reps: 10, rpe: 4, kind: .warmup))
            }
        }

        let reopened = try container(url: url)
        let context = reopened.mainContext
        let sessions = try context.fetch(FetchDescriptor<WorkoutSession>())
        XCTAssertEqual(sessions.count, 1)
        let draft = try XCTUnwrap(sessions.first)
        XCTAssertNil(draft.finishedAt)
        XCTAssertEqual(draft.sets.count, 2)
        XCTAssertEqual(draft.sets.map(\.effectiveKind), [.working, .warmup])
        XCTAssertEqual(draft.sets[0].id, loggedID)
        XCTAssertNil(draft.sets[0].kind)
        XCTAssertEqual(draft.sets[1].kind, .warmup)
        let rows = draft.rows(for: "Bench")
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.effectiveKind), [.warmup, .working, .working])
        XCTAssertEqual(draft.ordinal(for: rows[0]), 1)
        XCTAssertEqual(draft.ordinal(for: rows[1]), 1)
        XCTAssertEqual(draft.ordinal(for: rows[2]), 2)
    }

    // MARK: - The last session hint

    func testPreviousSessionPicksTheLatestFinishedMatchBeforeTheCurrentWorkout() throws {
        let store = try container()
        let context = store.mainContext
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let current = try makeSession(template: "Push", exercises: ["Bench"], startedAt: start, finishedAt: nil,
                                      sets: [], in: context)
        let earlier = try makeSession(template: "Push", exercises: ["Bench"], startedAt: start - 10_000,
                                      finishedAt: start - 5_000, sets: [LoggedSet(exercise: "Bench", weight: 40, reps: 8, rpe: 7)],
                                      in: context)
        _ = try makeSession(template: "Pull", exercises: ["bench"], startedAt: start - 4_000,
                            finishedAt: start - 3_000, sets: [LoggedSet(exercise: "bench", weight: 42, reps: 8, rpe: 7)],
                            in: context)
        // A draft is not a past workout.
        _ = try makeSession(template: "Push", exercises: ["Bench"], startedAt: start - 2_000, finishedAt: nil,
                            sets: [LoggedSet(exercise: "Bench", weight: 45, reps: 8, rpe: 7)], in: context)
        // A workout that finished after this one started is not in the past.
        _ = try makeSession(template: "Push", exercises: ["Bench"], startedAt: start - 1_000, finishedAt: start + 1_000,
                            sets: [LoggedSet(exercise: "Bench", weight: 50, reps: 8, rpe: 7)], in: context)
        // A different exercise is a different series.
        _ = try makeSession(template: "Push", exercises: ["Bench Press"], startedAt: start - 6_000,
                            finishedAt: start - 5_500, sets: [LoggedSet(exercise: "Bench Press", weight: 30, reps: 8, rpe: 7)],
                            in: context)

        let sessions = try context.fetch(FetchDescriptor<WorkoutSession>())
        // The name is matched without regard to case, and the template does not matter.
        let previous = ProgressData.previousSession(exercise: "BENCH", before: current.startedAt, sessions: sessions)
        XCTAssertEqual(previous?.finishedAt, start - 3_000)
        XCTAssertNotEqual(previous?.id, earlier.id)

        // Two workouts that finished at the same moment are ordered by their ID.
        let tieA = try makeSession(template: "Push", exercises: ["Bench"], startedAt: start - 2_000, finishedAt: start - 1_000,
                                  sets: [LoggedSet(exercise: "Bench", weight: 51, reps: 8, rpe: 7)], in: context)
        let tieB = try makeSession(template: "Push", exercises: ["Bench"], startedAt: start - 2_000, finishedAt: start - 1_000,
                                  sets: [LoggedSet(exercise: "Bench", weight: 52, reps: 8, rpe: 7)], in: context)
        let tied = try context.fetch(FetchDescriptor<WorkoutSession>())
        let winner = ProgressData.previousSession(exercise: "Bench", before: current.startedAt, sessions: tied)
        let expected = tieA.id.uuidString > tieB.id.uuidString ? tieA : tieB
        XCTAssertEqual(winner?.id, expected.id)
    }

    func testPreviousSetUsesTheKindAndTheNumberWithoutBorrowingUnloggedRows() throws {
        let store = try container()
        let context = store.mainContext
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let warmupID = UUID(), firstID = UUID(), secondID = UUID(), thirdID = UUID()
        // The previous workout logged its last working set first.
        let previous = try makeSession(template: "Push", exercises: ["Bench"], startedAt: start - 10_000,
                                       finishedAt: start - 5_000,
                                       sets: [LoggedSet(id: warmupID, exercise: "Bench", weight: 20, reps: 10, rpe: 4, kind: .warmup),
                                              LoggedSet(id: thirdID, exercise: "Bench", weight: 100, reps: 3, rpe: 9)],
                                       planned: [PlannedSet(id: warmupID, exercise: "Bench", kind: .warmup),
                                                 PlannedSet(id: firstID, exercise: "Bench"),
                                                 PlannedSet(id: secondID, exercise: "Bench"),
                                                 PlannedSet(id: thirdID, exercise: "Bench")],
                                       in: context)
        let currentWarmupID = UUID(), currentFirstID = UUID(), currentSecondID = UUID(), currentThirdID = UUID()
        let current = try makeSession(template: "Push", exercises: ["Bench"], startedAt: start, finishedAt: nil,
                                      sets: [],
                                      planned: [PlannedSet(id: currentWarmupID, exercise: "Bench", kind: .warmup),
                                                PlannedSet(id: currentFirstID, exercise: "Bench"),
                                                PlannedSet(id: currentSecondID, exercise: "Bench"),
                                                PlannedSet(id: currentThirdID, exercise: "Bench")],
                                      in: context)

        // The warm-up row looks at the warm-up rows of the previous workout.
        let warmupHint = ProgressData.previousSet(row: PlannedSet(id: currentWarmupID, exercise: "Bench", kind: .warmup),
                                                  current: current, previous: previous)
        XCTAssertEqual(warmupHint?.id, warmupID)
        XCTAssertEqual(warmupHint?.weight, 20)

        // The third working row finds the set that was logged out of order.
        let thirdHint = ProgressData.previousSet(row: PlannedSet(id: currentThirdID, exercise: "Bench"),
                                                 current: current, previous: previous)
        XCTAssertEqual(thirdHint?.id, thirdID)
        XCTAssertEqual(thirdHint?.weight, 100)

        // The rows that were never logged stay empty; no other row is borrowed.
        XCTAssertNil(ProgressData.previousSet(row: PlannedSet(id: currentFirstID, exercise: "Bench"),
                                               current: current, previous: previous))
        XCTAssertNil(ProgressData.previousSet(row: PlannedSet(id: currentSecondID, exercise: "Bench"),
                                               current: current, previous: previous))

        // A previous workout without warm-up rows has no warm-up hint.
        let plainID = UUID(), plainOtherID = UUID()
        let plain = try makeSession(template: "Push", exercises: ["Bench"], startedAt: start - 10_000,
                                    finishedAt: start - 4_000,
                                    sets: [LoggedSet(id: plainID, exercise: "Bench", weight: 55, reps: 5, rpe: 7)],
                                    planned: [PlannedSet(id: plainID, exercise: "Bench"),
                                              PlannedSet(id: plainOtherID, exercise: "Bench")],
                                    in: context)
        XCTAssertNil(ProgressData.previousSet(row: PlannedSet(id: currentWarmupID, exercise: "Bench", kind: .warmup),
                                               current: current, previous: plain))
        XCTAssertEqual(ProgressData.previousSet(row: PlannedSet(id: currentFirstID, exercise: "Bench"),
                                                 current: current, previous: plain)?.id, plainID)
    }

    // MARK: - The lifting progress list

    func testLiftingUsesTheHeaviestWorkingSetOfEachFinishedWorkout() throws {
        let store = try container()
        let context = store.mainContext
        let calendar = Schedule.calendar(timeZone: try zone("UTC"))
        let first = try noon("2024-03-01", calendar: calendar)
        let second = try noon("2024-03-02", calendar: calendar)
        let third = try noon("2024-03-03", calendar: calendar)

        // The warm-up set is heavier than every working set and stays out.
        _ = try makeSession(template: "Push", exercises: ["Bench"], startedAt: first, finishedAt: first,
                            sets: [LoggedSet(exercise: "Bench", weight: 60, reps: 5, rpe: 7),
                                   LoggedSet(exercise: "Bench", weight: 70, reps: 3, rpe: 9),
                                   LoggedSet(exercise: "Bench", weight: 100, reps: 10, rpe: 4, kind: .warmup)],
                            in: context)
        // Two sets with the same weight keep the first one.
        _ = try makeSession(template: "Push", exercises: ["Bench"], startedAt: second, finishedAt: second,
                            sets: [LoggedSet(exercise: "Bench", weight: 60, reps: 5, rpe: 7),
                                   LoggedSet(exercise: "Bench", weight: 60, reps: 9, rpe: 8)],
                            in: context)
        // A workout saved in pounds.
        _ = try makeSession(template: "Pull", exercises: ["bench"], unit: .lb, startedAt: third, finishedAt: third,
                            sets: [LoggedSet(exercise: "bench", weight: 220, reps: 5, rpe: 7)],
                            in: context)
        // A draft is not history yet.
        _ = try makeSession(template: "Push", exercises: ["Bench"], startedAt: third, finishedAt: nil,
                            sets: [LoggedSet(exercise: "Bench", weight: 200, reps: 5, rpe: 7)], in: context)
        // A workout with planned but unlogged rows has nothing to show.
        let emptyID = UUID()
        _ = try makeSession(template: "Push", exercises: ["Bench"], startedAt: third, finishedAt: third,
                            sets: [], planned: [PlannedSet(id: emptyID, exercise: "Bench")], in: context)

        let sessions = try context.fetch(FetchDescriptor<WorkoutSession>())
        let points = ProgressData.lifting(exercise: "bench", sessions: sessions, unit: .kg)
        XCTAssertEqual(points.count, 3)
        // The list is sorted by date.
        XCTAssertEqual(points.map(\.date), [first, second, third])

        XCTAssertEqual(points[0].weight, 70)
        XCTAssertEqual(points[0].reps, 3)
        XCTAssertEqual(points[0].rpe, 9)
        XCTAssertEqual(points[0].originalWeight, 70)
        XCTAssertEqual(points[0].originalUnit, .kg)

        XCTAssertEqual(points[1].weight, 60)
        XCTAssertEqual(points[1].reps, 5)
        XCTAssertEqual(points[1].rpe, 7)

        XCTAssertEqual(points[2].weight, 220 * 0.45359237, accuracy: 1e-9)
        XCTAssertEqual(points[2].originalWeight, 220)
        XCTAssertEqual(points[2].originalUnit, .lb)
    }

    func testLiftingSortsSameDayWorkoutsDeterministicallyAndKeepsEveryValue() throws {
        let store = try container()
        let context = store.mainContext
        let calendar = Schedule.calendar(timeZone: try zone("UTC"))
        let day = try noon("2024-04-10", calendar: calendar)

        // Two workouts finished on the same day are ordered by their ID.
        let first = try makeSession(template: "Push", exercises: ["Bench"], startedAt: day, finishedAt: day,
                                    sets: [LoggedSet(exercise: "Bench", weight: 40, reps: 5, rpe: 6)], in: context)
        let second = try makeSession(template: "Push", exercises: ["Bench"], startedAt: day, finishedAt: day,
                                     sets: [LoggedSet(exercise: "Bench", weight: 45, reps: 6, rpe: 7)], in: context)
        // A move without weight, logged with the lowest exertion.
        let zero = try makeSession(template: "Core", exercises: ["Plank"], startedAt: day, finishedAt: day,
                                   sets: [LoggedSet(exercise: "Plank", weight: 0, reps: 12, rpe: 0)], in: context)
        let hardest = try makeSession(template: "Push", exercises: ["Bench"], startedAt: day, finishedAt: day,
                                      sets: [LoggedSet(exercise: "Bench", weight: 52.5, reps: 5, rpe: 10)], in: context)

        let sessions = try context.fetch(FetchDescriptor<WorkoutSession>())
        let points = ProgressData.lifting(exercise: "Bench", sessions: sessions, unit: .kg)
        let sameDay = points.filter { $0.date == day }
        XCTAssertEqual(sameDay.count, 3)
        let expected = [first, second, hardest].sorted { $0.id.uuidString < $1.id.uuidString }.map(\.id)
        XCTAssertEqual(sameDay.map(\.id), expected)

        // Every saved value stays readable.
        let heaviest = try XCTUnwrap(points.first { $0.id == hardest.id })
        XCTAssertEqual(heaviest.weight, 52.5)
        XCTAssertEqual(heaviest.reps, 5)
        XCTAssertEqual(heaviest.rpe, 10)
        let plank = try XCTUnwrap(ProgressData.lifting(exercise: "Plank", sessions: sessions, unit: .kg).first)
        XCTAssertEqual(plank.id, zero.id)
        XCTAssertEqual(plank.weight, 0)
        XCTAssertEqual(plank.reps, 12)
        XCTAssertEqual(plank.rpe, 0)
        XCTAssertEqual(plank.originalWeight, 0)

        // The conversion keeps the stored unit and value next to the shown one.
        let pounds = try XCTUnwrap(WeightUnit.lb.convert(220, to: .kg))
        XCTAssertEqual(pounds, 220 * 0.45359237, accuracy: 1e-12)
        let kilos = try XCTUnwrap(WeightUnit.kg.convert(100, to: .lb))
        XCTAssertEqual(kilos, 100 / 0.45359237, accuracy: 1e-9)
    }

    func testProgressRangesUseCalendarMonthsAcrossMonthEndsLeapYearsAndDaylightSaving() throws {
        let utc = Schedule.calendar(timeZone: try zone("UTC"))
        let march31 = try noon("2024-03-31", calendar: utc)
        let february29 = try noon("2024-02-29", calendar: utc)
        let december31 = try noon("2023-12-31", calendar: utc)
        let september30 = try noon("2023-09-30", calendar: utc)
        XCTAssertEqual(ProgressRange.month.start(now: march31, calendar: utc), february29)
        XCTAssertEqual(ProgressRange.threeMonths.start(now: march31, calendar: utc), december31)
        XCTAssertEqual(ProgressRange.sixMonths.start(now: march31, calendar: utc), september30)
        XCTAssertNil(ProgressRange.all.start(now: march31, calendar: utc))

        // The end of a month moves back to the end of the shorter month.
        let may31 = try noon("2024-05-31", calendar: utc)
        XCTAssertEqual(ProgressRange.threeMonths.start(now: may31, calendar: utc), february29)
        let may31of2023 = try noon("2023-05-31", calendar: utc)
        let february28 = try noon("2023-02-28", calendar: utc)
        XCTAssertEqual(ProgressRange.threeMonths.start(now: may31of2023, calendar: utc), february28)
        let january31 = try noon("2024-01-31", calendar: utc)
        let july31 = try noon("2023-07-31", calendar: utc)
        XCTAssertEqual(ProgressRange.sixMonths.start(now: january31, calendar: utc), july31)
        let august31 = try noon("2024-08-31", calendar: utc)
        XCTAssertEqual(ProgressRange.sixMonths.start(now: august31, calendar: utc), february29)

        // Calendar months retain local time across a real DST boundary.
        let newYork = Schedule.calendar(timeZone: try zone("America/New_York"))
        let dstStart = try noon("2024-03-31", calendar: newYork)
        let start = try XCTUnwrap(ProgressRange.month.start(now: dstStart, calendar: newYork))
        let parts = newYork.dateComponents([.year, .month, .day, .hour], from: start)
        XCTAssertEqual(parts.year, 2024)
        XCTAssertEqual(parts.month, 2)
        XCTAssertEqual(parts.day, 29)
        XCTAssertEqual(parts.hour, 12)
        XCTAssertEqual(start.timeIntervalSince(dstStart), -(31 * 24 - 1) * 3600)
        let afterFallBack = try noon("2024-11-30", calendar: newYork)
        let fallStart = try XCTUnwrap(ProgressRange.month.start(now: afterFallBack, calendar: newYork))
        XCTAssertEqual(Schedule.day(fallStart, calendar: newYork), "2024-10-30")
        XCTAssertEqual(fallStart.timeIntervalSince(afterFallBack), -(31 * 24 + 1) * 3600)

        // The list only shows the workouts inside the chosen range.
        let store = try container()
        let context = store.mainContext
        let onStart = try noon("2024-02-29", calendar: utc)
        let inside = try noon("2024-03-15", calendar: utc)
        let outside = try noon("2024-01-10", calendar: utc)
        for date in [onStart, inside, outside] {
            _ = try makeSession(template: "Push", exercises: ["Bench"], startedAt: date, finishedAt: date,
                                sets: [LoggedSet(exercise: "Bench", weight: 50, reps: 5, rpe: 7)], in: context)
        }
        let sessions = try context.fetch(FetchDescriptor<WorkoutSession>())
        let points = ProgressData.lifting(exercise: "Bench", sessions: sessions, unit: .kg,
                                          range: .month, now: march31, calendar: utc)
        XCTAssertEqual(points.map(\.date), [onStart, inside])
    }

    func testUnitConversionOverflowIsRejectedAndKeepsTheStoredUnit() throws {
        let store = try container()
        let context = store.mainContext
        XCTAssertNil(WeightUnit.kg.convert(Double.greatestFiniteMagnitude, to: .lb))
        XCTAssertNotNil(WeightUnit.lb.convert(Double.greatestFiniteMagnitude, to: .kg))
        XCTAssertEqual(WeightUnit.kg.convert(100, to: .kg), 100)
        XCTAssertEqual(WeightUnit.lb.convert(100, to: .lb), 100)

        // A workout whose weight cannot be converted is left out of the list,
        // and the unit it was saved with stays untouched.
        let session = try makeSession(template: "Push", exercises: ["Bench"], startedAt: Date(), finishedAt: Date(),
                                      sets: [LoggedSet(exercise: "Bench", weight: Double.greatestFiniteMagnitude, reps: 1, rpe: 1)],
                                      in: context)
        let sessions = try context.fetch(FetchDescriptor<WorkoutSession>())
        XCTAssertTrue(ProgressData.lifting(exercise: "Bench", sessions: sessions, unit: .lb).isEmpty)
        XCTAssertEqual(session.unit, "kg")
        XCTAssertEqual(session.sets[0].weight, Double.greatestFiniteMagnitude)
    }

    // MARK: - Body weight

    func testBodyWeightSaveNeedsARealDayAPositiveWeightAndTheIDOfADuplicateDay() throws {
        let store = try container()
        let context = store.mainContext
        let calendar = Schedule.calendar(timeZone: try zone("UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 5, day: 10, hour: 18)))

        // Only a real day, a positive finite weight and a known unit are accepted.
        XCTAssertNoThrow(try BodyWeightEntry.validate(day: "2024-05-01", weight: 80, unit: "kg"))
        XCTAssertNoThrow(try BodyWeightEntry.validate(day: "2024-05-01", weight: 176.4, unit: "lb"))
        for day in ["", "2024-13-01", "2024-02-30", "2023-02-29", "2024-5-1", "not-a-day"] {
            XCTAssertThrowsError(try BodyWeightEntry.validate(day: day, weight: 80, unit: "kg"), day)
        }
        for weight in [0.0, -1.0, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertThrowsError(try BodyWeightEntry.validate(day: "2024-05-01", weight: weight, unit: "kg"), "\(weight)")
        }
        XCTAssertThrowsError(try BodyWeightEntry.validate(day: "2024-05-01", weight: 80, unit: "stone"))
        XCTAssertThrowsError(try BodyWeightEntry.validate(day: "2024-05-01", weight: 80, unit: ""))

        // Today and the past are allowed, the future is not.
        let entry = try BodyWeightEntry.save(day: "2024-05-10", weight: 80.5, unit: .kg, in: context, now: now, calendar: calendar)
        XCTAssertEqual(entry.day, "2024-05-10")
        XCTAssertEqual(entry.weight, 80.5)
        XCTAssertEqual(entry.unit, "kg")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BodyWeightEntry>()), 1)
        XCTAssertThrowsError(try BodyWeightEntry.save(day: "2024-05-11", weight: 80, unit: .kg, in: context, now: now, calendar: calendar))
        let past = try BodyWeightEntry.save(day: "2024-05-01", weight: 79, unit: .kg, in: context, now: now, calendar: calendar)
        XCTAssertEqual(past.day, "2024-05-01")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BodyWeightEntry>()), 2)

        // A second weigh-in on the same day needs the ID of the saved entry.
        XCTAssertThrowsError(try BodyWeightEntry.save(day: "2024-05-10", weight: 81, unit: .kg, in: context, now: now, calendar: calendar))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BodyWeightEntry>()), 2)
        let updated = try BodyWeightEntry.save(day: "2024-05-10", weight: 81.2, unit: .kg, existingID: entry.id,
                                               in: context, now: now, calendar: calendar)
        XCTAssertEqual(updated.id, entry.id)
        XCTAssertEqual(updated.weight, 81.2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BodyWeightEntry>()), 2)

        // Moving an entry onto a day that already has one is refused.
        XCTAssertThrowsError(try BodyWeightEntry.save(day: "2024-05-10", weight: 78, unit: .kg, existingID: past.id,
                                                      in: context, now: now, calendar: calendar))
        XCTAssertEqual(try XCTUnwrap(context.fetch(FetchDescriptor<BodyWeightEntry>()).first { $0.id == past.id }).day, "2024-05-01")

        // An ID that is not saved any more is refused.
        XCTAssertThrowsError(try BodyWeightEntry.save(day: "2024-05-02", weight: 78, unit: .kg, existingID: UUID(),
                                                      in: context, now: now, calendar: calendar))

        // The unit only changes when the caller asks for it; the weight is not converted.
        let switched = try BodyWeightEntry.save(day: "2024-05-01", weight: 79, unit: .lb, existingID: past.id,
                                                in: context, now: now, calendar: calendar)
        XCTAssertEqual(switched.id, past.id)
        XCTAssertEqual(switched.unit, "lb")
        XCTAssertEqual(switched.weight, 79)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BodyWeightEntry>()), 2)
    }

    func testBodyWeightEntriesSurviveReopenAndCanBeDeleted() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutLog-training-body-\(UUID()).store")
        var entryID = UUID()
        do {
            let store = try container(url: url)
            let context = store.mainContext
            let calendar = Schedule.calendar(timeZone: try zone("UTC"))
            let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 5, day: 9, hour: 9)))
            let entry = try BodyWeightEntry.save(day: "2024-05-09", weight: 79.5, unit: .kg, in: context, now: now, calendar: calendar)
            entryID = entry.id
        }
        do {
            let reopened = try container(url: url)
            let context = reopened.mainContext
            let entries = try context.fetch(FetchDescriptor<BodyWeightEntry>())
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entries[0].id, entryID)
            XCTAssertEqual(entries[0].day, "2024-05-09")
            XCTAssertEqual(entries[0].weight, 79.5)
            XCTAssertEqual(entries[0].unit, "kg")
            try context.commit { context.delete(entries[0]) }
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<BodyWeightEntry>()), 0)
        }
        let final = try container(url: url)
        XCTAssertEqual(try final.mainContext.fetchCount(FetchDescriptor<BodyWeightEntry>()), 0)
    }

    func testBodyWeightSaveOnAReadOnlyStoreRollsBackAndKeepsTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutLog-training-readonly-\(UUID()).store")
        do {
            let store = try container(url: url)
            try store.mainContext.commit {
                store.mainContext.insert(BodyWeightEntry(day: "2024-05-01", weight: 80, unit: .kg))
            }
        }
        let schema = Schema([WorkoutTemplate.self, WorkoutSession.self, LibraryExercise.self, LibrarySetup.self, CalendarRule.self, WalkingCompletion.self, BodyWeightEntry.self])
        let config = ModelConfiguration(schema: schema, url: url, allowsSave: false, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let failure = expectation(forNotification: .workoutSaveFailed, object: context)
        XCTAssertThrowsError(try BodyWeightEntry.save(day: "2000-05-02", weight: 81, unit: .kg, in: context))
        wait(for: [failure], timeout: 1)
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BodyWeightEntry>()), 1)

        // The file on disk still holds the state from before the failed save.
        let reopened = try container(url: url)
        let entries = try reopened.mainContext.fetch(FetchDescriptor<BodyWeightEntry>())
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].day, "2024-05-01")
        XCTAssertEqual(entries[0].weight, 80)
    }

    // MARK: - The store of a version without kinds

    func testAStoreWithoutKindsOpensWithTheCurrentSchemaAndKeepsItsRows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutLog-training-prekind-\(UUID()).store")
        let templateID = UUID(), historyID = UUID(), draftID = UUID(), rowID = UUID()
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let finished = Date(timeIntervalSince1970: 1_700_003_600)
        do {
            let schema = Schema([PreKindStore.WorkoutTemplate.self, PreKindStore.WorkoutSession.self])
            XCTAssertEqual(Set(schema.entities.map(\.name)), ["WorkoutTemplate", "WorkoutSession"])
            let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            let legacy = try ModelContainer(for: schema, configurations: [config])
            legacy.mainContext.autosaveEnabled = false
            legacy.mainContext.insert(PreKindStore.WorkoutTemplate(id: templateID, name: "Old push",
                                                                    exercises: ["Bench", "Press"], setCounts: [3, 2]))
            legacy.mainContext.insert(PreKindStore.WorkoutSession(id: historyID, startedAt: started, finishedAt: finished,
                                                                    templateName: "Old push", exercises: ["Bench", "Press"],
                                                                    unit: "kg",
                                                                    sets: [PreKindStore.LoggedSet(id: rowID, exercise: "Bench", weight: 45, reps: 8, rpe: 7.5)],
                                                                    plannedSets: [PreKindStore.PlannedSet(id: rowID, exercise: "Bench")]))
            legacy.mainContext.insert(PreKindStore.WorkoutSession(id: draftID, startedAt: started, finishedAt: nil,
                                                                    templateName: "Old push", exercises: ["Bench"],
                                                                    unit: "lb",
                                                                    sets: [PreKindStore.LoggedSet(id: UUID(), exercise: "Bench", weight: 40, reps: 8, rpe: 7)],
                                                                    plannedSets: nil))
            try legacy.mainContext.save()
        }

        // The same file opens with the current schema of the app.
        let current = try container(url: url)
        let context = current.mainContext
        let template = try XCTUnwrap(context.fetch(FetchDescriptor<WorkoutTemplate>()).first)
        XCTAssertEqual(template.id, templateID)
        XCTAssertEqual(template.name, "Old push")
        XCTAssertEqual(template.exercises, ["Bench", "Press"])
        XCTAssertEqual(template.setCounts ?? [], [3, 2])

        let sessions = try context.fetch(FetchDescriptor<WorkoutSession>())
        XCTAssertEqual(Set(sessions.map(\.id)), [historyID, draftID])
        let history = try XCTUnwrap(sessions.first { $0.id == historyID })
        XCTAssertEqual(history.startedAt, started)
        XCTAssertEqual(history.finishedAt, finished)
        XCTAssertEqual(history.templateName, "Old push")
        XCTAssertEqual(history.exercises, ["Bench", "Press"])
        XCTAssertEqual(history.unit, "kg")
        XCTAssertEqual(history.sets.count, 1)
        XCTAssertEqual(history.sets[0].id, rowID)
        XCTAssertEqual(history.sets[0].exercise, "Bench")
        XCTAssertEqual(history.sets[0].weight, 45)
        XCTAssertEqual(history.sets[0].reps, 8)
        XCTAssertEqual(history.sets[0].rpe, 7.5)
        // Rows saved before the kinds existed keep working as working sets.
        XCTAssertNil(history.sets[0].kind)
        XCTAssertEqual(history.sets[0].effectiveKind, .working)
        let planned = try XCTUnwrap(history.plannedSets)
        XCTAssertEqual(planned.count, 1)
        XCTAssertEqual(planned[0].id, rowID)
        XCTAssertEqual(planned[0].exercise, "Bench")
        XCTAssertNil(planned[0].kind)
        XCTAssertEqual(planned[0].effectiveKind, .working)
        XCTAssertEqual(history.rows(for: "Bench").count, 1)
        XCTAssertEqual(history.ordinal(for: history.rows(for: "Bench")[0]), 1)

        let draft = try XCTUnwrap(sessions.first { $0.id == draftID })
        XCTAssertNil(draft.finishedAt)
        XCTAssertEqual(draft.unit, "lb")
        XCTAssertEqual(draft.sets.count, 1)
        XCTAssertNil(draft.sets[0].kind)
        XCTAssertEqual(draft.sets[0].effectiveKind, .working)
    }
}

// The stored shape of a version without set kinds. The rows hold no kind at
// all, so the file really contains the older values.
private enum PreKindStore {
    struct LoggedSet: Codable {
        var id: UUID
        var exercise: String
        var weight: Double
        var reps: Int
        var rpe: Double
    }

    struct PlannedSet: Codable {
        var id: UUID
        var exercise: String
    }

    @Model
    final class WorkoutTemplate {
        var id: UUID
        var name: String
        var exercises: [String]
        var setCounts: [Int]?
        var videoURLs: [String: String]?

        init(id: UUID, name: String, exercises: [String], setCounts: [Int]?, videoURLs: [String: String]? = nil) {
            self.id = id
            self.name = name
            self.exercises = exercises
            self.setCounts = setCounts
            self.videoURLs = videoURLs
        }
    }

    @Model
    final class WorkoutSession {
        var id: UUID
        var startedAt: Date
        var finishedAt: Date?
        var templateName: String
        var exercises: [String]
        var unit: String
        var sets: [LoggedSet]
        var plannedSets: [PlannedSet]?
        var videoURLs: [String: String]?
        var sourceTemplateID: UUID?
        var completedDay: String?

        init(id: UUID, startedAt: Date, finishedAt: Date?, templateName: String, exercises: [String],
             unit: String, sets: [LoggedSet], plannedSets: [PlannedSet]?, videoURLs: [String: String]? = nil,
             sourceTemplateID: UUID? = nil, completedDay: String? = nil) {
            self.id = id
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.templateName = templateName
            self.exercises = exercises
            self.unit = unit
            self.sets = sets
            self.plannedSets = plannedSets
            self.videoURLs = videoURLs
            self.sourceTemplateID = sourceTemplateID
            self.completedDay = completedDay
        }
    }
}
