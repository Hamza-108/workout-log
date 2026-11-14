import Foundation
import SwiftData
import XCTest
@testable import WorkoutLog

@MainActor
final class StreakTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            WorkoutTemplate.self,
            WorkoutSession.self,
            LibraryExercise.self,
            LibrarySetup.self,
            CalendarRule.self,
            WalkingCompletion.self,
            BodyWeightEntry.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        container.mainContext.autosaveEnabled = false
        return container
    }

    private func utcCalendar() throws -> Calendar {
        Schedule.calendar(timeZone: try XCTUnwrap(TimeZone(identifier: "UTC")))
    }

    @discardableResult
    private func makeTemplate(_ name: String, _ exercises: [String], in context: ModelContext) throws -> WorkoutTemplate {
        let template = WorkoutTemplate(name: name, exercises: exercises)
        try context.commit { context.insert(template) }
        return template
    }

    @discardableResult
    private func completeSession(
        from template: WorkoutTemplate,
        on day: String,
        calendar: Calendar,
        in context: ModelContext
    ) throws -> WorkoutSession {
        let session = try WorkoutSession.start(template: template, unit: .kg, in: context)
        let date = try XCTUnwrap(Schedule.date(day, calendar: calendar))
        try context.commit {
            try session.record(LoggedSet(exercise: template.exercises[0], weight: 60, reps: 8, rpe: 7))
            try session.finish(at: date, calendar: calendar)
        }
        return session
    }

    private func summary(on today: String, calendar: Calendar, in context: ModelContext) throws -> StreakSummary {
        let rules = try context.fetch(FetchDescriptor<CalendarRule>())
        let sessions = try context.fetch(FetchDescriptor<WorkoutSession>())
        let walks = try context.fetch(FetchDescriptor<WalkingCompletion>())
        return StreakCalculator.summary(rules: rules, sessions: sessions, walks: walks, today: today, calendar: calendar)
    }

    func testEmptyStoreHasZeroStreakAndZeroAdherence() throws {
        let store = try makeContainer()
        let calendar = try utcCalendar()
        let result = try summary(on: "2024-03-10", calendar: calendar, in: store.mainContext)
        XCTAssertEqual(result, StreakSummary(
            currentStreak: 0,
            bestStreak: 0,
            adherencePercent: 0,
            completedLast30Days: 0,
            assignedLast30Days: 0
        ))
    }

    func testThreeTimesPerWeekPlanBridgesRestDaysAndReachesFiveDayStreak() throws {
        let store = try makeContainer()
        let context = store.mainContext
        let calendar = try utcCalendar()
        let push = try makeTemplate("Push", ["Bench"], in: context)
        let pull = try makeTemplate("Pull", ["Row"], in: context)
        let legs = try makeTemplate("Legs", ["Squat"], in: context)

        try Schedule.assign(on: "2024-03-04", kind: .template, template: push, repeating: true, in: context)
        try Schedule.assign(on: "2024-03-06", kind: .template, template: pull, repeating: true, in: context)
        try Schedule.assign(on: "2024-03-08", kind: .template, template: legs, repeating: true, in: context)

        // Monday completed -> 1d streak.
        try completeSession(from: push, on: "2024-03-04", calendar: calendar, in: context)
        XCTAssertEqual(try summary(on: "2024-03-04", calendar: calendar, in: context).currentStreak, 1)

        // Tuesday is a scheduled rest day between Monday and Wednesday -> 2d streak.
        XCTAssertEqual(try summary(on: "2024-03-05", calendar: calendar, in: context).currentStreak, 2)

        // Wednesday before finishing Pull: today is in progress so streak stays 2 and adherence stays 100% (1/1).
        let wedPending = try summary(on: "2024-03-06", calendar: calendar, in: context)
        XCTAssertEqual(wedPending.currentStreak, 2)
        XCTAssertEqual(wedPending.adherencePercent, 100)
        XCTAssertEqual(wedPending.completedLast30Days, 1)
        XCTAssertEqual(wedPending.assignedLast30Days, 1)

        // Wednesday completed -> 3d streak.
        try completeSession(from: pull, on: "2024-03-06", calendar: calendar, in: context)
        XCTAssertEqual(try summary(on: "2024-03-06", calendar: calendar, in: context).currentStreak, 3)

        // Thursday rest day -> 4d streak.
        XCTAssertEqual(try summary(on: "2024-03-07", calendar: calendar, in: context).currentStreak, 4)

        // Friday completed -> 5d streak ("Friend 3 has a 5-day streak").
        try completeSession(from: legs, on: "2024-03-08", calendar: calendar, in: context)
        let friDone = try summary(on: "2024-03-08", calendar: calendar, in: context)
        XCTAssertEqual(friDone.currentStreak, 5)
        XCTAssertEqual(friDone.bestStreak, 5)
        XCTAssertEqual(friDone.adherencePercent, 100)
        XCTAssertEqual(friDone.completedLast30Days, 3)
        XCTAssertEqual(friDone.assignedLast30Days, 3)

        // Saturday and Sunday rest days bridge into next Monday's repeating assignment -> 6d and 7d.
        XCTAssertEqual(try summary(on: "2024-03-09", calendar: calendar, in: context).currentStreak, 6)
        XCTAssertEqual(try summary(on: "2024-03-10", calendar: calendar, in: context).currentStreak, 7)
    }

    func testOncePerWeekPlanBridgesSixUnassignedRestDays() throws {
        let store = try makeContainer()
        let context = store.mainContext
        let calendar = try utcCalendar()

        try Schedule.assign(on: "2024-03-04", kind: .walking, repeating: true, in: context)
        let firstMonday = try XCTUnwrap(Schedule.date("2024-03-04", calendar: calendar))
        try Schedule.markWalk(on: "2024-03-04", done: true, in: context, now: firstMonday, calendar: calendar)

        for (day, expected) in [
            ("2024-03-04", 1),
            ("2024-03-05", 2),
            ("2024-03-06", 3),
            ("2024-03-07", 4),
            ("2024-03-08", 5),
            ("2024-03-09", 6),
            ("2024-03-10", 7)
        ] {
            let result = try summary(on: day, calendar: calendar, in: context)
            XCTAssertEqual(result.currentStreak, expected, day)
            XCTAssertEqual(result.bestStreak, expected, day)
        }

        // Next Monday before walking is marked done keeps the 7-day streak alive.
        XCTAssertEqual(try summary(on: "2024-03-11", calendar: calendar, in: context).currentStreak, 7)

        let secondMonday = try XCTUnwrap(Schedule.date("2024-03-11", calendar: calendar))
        try Schedule.markWalk(on: "2024-03-11", done: true, in: context, now: secondMonday, calendar: calendar)
        let afterSecondMonday = try summary(on: "2024-03-11", calendar: calendar, in: context)
        XCTAssertEqual(afterSecondMonday.currentStreak, 8)
        XCTAssertEqual(afterSecondMonday.bestStreak, 8)
    }

    func testLoneOneOffWorkoutWithoutFollowUpDoesNotInflateStreakAndExpiresAfterSixRestDays() throws {
        let store = try makeContainer()
        let context = store.mainContext
        let calendar = try utcCalendar()
        let push = try makeTemplate("Push", ["Bench"], in: context)

        try Schedule.assign(on: "2024-03-04", kind: .template, template: push, repeating: false, in: context)
        try completeSession(from: push, on: "2024-03-04", calendar: calendar, in: context)

        // With no subsequent assignment within 6 days, the streak stays at 1 during the 6-day grace window.
        for day in ["2024-03-04", "2024-03-05", "2024-03-08", "2024-03-10"] {
            let result = try summary(on: day, calendar: calendar, in: context)
            XCTAssertEqual(result.currentStreak, 1, day)
            XCTAssertEqual(result.bestStreak, 1, day)
        }

        // On the 7th consecutive unassigned day with no scheduled plan, currentStreak expires to 0 while bestStreak stays 1.
        let expired = try summary(on: "2024-03-11", calendar: calendar, in: context)
        XCTAssertEqual(expired.currentStreak, 0)
        XCTAssertEqual(expired.bestStreak, 1)
    }

    func testMissedPastAssignmentResetsCurrentStreakAndPreservesBestStreak() throws {
        let store = try makeContainer()
        let context = store.mainContext
        let calendar = try utcCalendar()
        let push = try makeTemplate("Push", ["Bench"], in: context)

        try Schedule.assign(on: "2024-03-04", kind: .template, template: push, repeating: false, in: context)
        try Schedule.assign(on: "2024-03-06", kind: .template, template: push, repeating: false, in: context)
        try Schedule.assign(on: "2024-03-08", kind: .template, template: push, repeating: false, in: context)
        try Schedule.assign(on: "2024-03-10", kind: .template, template: push, repeating: false, in: context)

        try completeSession(from: push, on: "2024-03-04", calendar: calendar, in: context)
        try completeSession(from: push, on: "2024-03-06", calendar: calendar, in: context)

        // 2024-03-08 is missed. Checking on 2024-03-09 shows currentStreak == 0 and bestStreak == 4 (Mon..Thu).
        let afterMiss = try summary(on: "2024-03-09", calendar: calendar, in: context)
        XCTAssertEqual(afterMiss.currentStreak, 0)
        XCTAssertEqual(afterMiss.bestStreak, 4)
        XCTAssertEqual(afterMiss.completedLast30Days, 2)
        XCTAssertEqual(afterMiss.assignedLast30Days, 3)
        XCTAssertEqual(afterMiss.adherencePercent, 67)

        // Completing 2024-03-10 starts a new streak at 1 while preserving bestStreak == 4.
        try completeSession(from: push, on: "2024-03-10", calendar: calendar, in: context)
        let restarted = try summary(on: "2024-03-10", calendar: calendar, in: context)
        XCTAssertEqual(restarted.currentStreak, 1)
        XCTAssertEqual(restarted.bestStreak, 4)
        XCTAssertEqual(restarted.completedLast30Days, 3)
        XCTAssertEqual(restarted.assignedLast30Days, 4)
        XCTAssertEqual(restarted.adherencePercent, 75)
    }

    func testRelativeAdherenceScoresOneDayPerWeekAndFourDaysPerWeekFairly() throws {
        let calendar = try utcCalendar()

        // Planner A: 1x/week for 4 weeks, all 4 completed -> 100% (4/4).
        let storeA = try makeContainer()
        let contextA = storeA.mainContext
        try Schedule.assign(on: "2024-03-04", kind: .walking, repeating: true, in: contextA)
        for day in ["2024-03-04", "2024-03-11", "2024-03-18", "2024-03-25"] {
            let date = try XCTUnwrap(Schedule.date(day, calendar: calendar))
            try Schedule.markWalk(on: day, done: true, in: contextA, now: date, calendar: calendar)
        }
        let summaryA = try summary(on: "2024-03-30", calendar: calendar, in: contextA)
        XCTAssertEqual(summaryA.completedLast30Days, 4)
        XCTAssertEqual(summaryA.assignedLast30Days, 4)
        XCTAssertEqual(summaryA.adherencePercent, 100)

        // Planner B: 4x/week over the same 4 weeks (16 assigned), 12 completed -> 75% (12/16).
        let storeB = try makeContainer()
        let contextB = storeB.mainContext
        for start in ["2024-03-04", "2024-03-05", "2024-03-07", "2024-03-08"] {
            try Schedule.assign(on: start, kind: .walking, repeating: true, in: contextB)
        }
        let completedDaysB = [
            "2024-03-04", "2024-03-05", "2024-03-07",
            "2024-03-11", "2024-03-12", "2024-03-14",
            "2024-03-18", "2024-03-19", "2024-03-21",
            "2024-03-25", "2024-03-26", "2024-03-28"
        ]
        for day in completedDaysB {
            let date = try XCTUnwrap(Schedule.date(day, calendar: calendar))
            try Schedule.markWalk(on: day, done: true, in: contextB, now: date, calendar: calendar)
        }
        let summaryB = try summary(on: "2024-03-30", calendar: calendar, in: contextB)
        XCTAssertEqual(summaryB.completedLast30Days, 12)
        XCTAssertEqual(summaryB.assignedLast30Days, 16)
        XCTAssertEqual(summaryB.adherencePercent, 75)
    }

    func testPersonalRecordsIgnoreWarmupsAndDraftsAndNormalizeUnitsAndTieBreakByRepsThenDate() throws {
        let store = try makeContainer()
        let context = store.mainContext
        let calendar = try utcCalendar()
        let template = try makeTemplate("Upper", ["Bench", "Bench (variation 1)", "Row"], in: context)

        // Session 1: Bench 100 kg x 5 working, plus a 140 kg warmup (must be ignored), plus variation 1.
        let s1 = try WorkoutSession.start(template: template, unit: .kg, in: context)
        let d1 = try XCTUnwrap(Schedule.date("2024-03-01", calendar: calendar))
        try context.commit {
            try s1.record(LoggedSet(exercise: "Bench", weight: 140, reps: 1, rpe: 9, kind: .warmup))
            try s1.record(LoggedSet(exercise: "Bench", weight: 100, reps: 5, rpe: 8, kind: .working))
            try s1.record(LoggedSet(exercise: "Bench (variation 1)", weight: 90, reps: 6, rpe: 7.5, kind: .working))
            try s1.record(LoggedSet(exercise: "Row", weight: 80, reps: 8, rpe: 7, kind: .working))
            try s1.finish(at: d1, calendar: calendar)
        }

        // Session 2: Bench 225 lb (~102.06 kg) x 4 working (beats 100 kg), Row 80 kg x 10 (ties weight, wins on reps).
        let s2 = try WorkoutSession.start(template: template, unit: .lb, in: context)
        let d2 = try XCTUnwrap(Schedule.date("2024-03-05", calendar: calendar))
        try context.commit {
            try s2.record(LoggedSet(exercise: "Bench", weight: 225, reps: 4, rpe: 8.5, kind: .working))
            try s2.finish(at: d2, calendar: calendar)
        }

        let s3 = try WorkoutSession.start(template: template, unit: .kg, in: context)
        let d3 = try XCTUnwrap(Schedule.date("2024-03-06", calendar: calendar))
        try context.commit {
            try s3.record(LoggedSet(exercise: "Row", weight: 80, reps: 10, rpe: 8, kind: .working))
            try s3.finish(at: d3, calendar: calendar)
        }

        // Unfinished draft with 300 kg Bench must be ignored.
        let draft = try WorkoutSession.start(template: template, unit: .kg, in: context)
        try context.commit {
            try draft.record(LoggedSet(exercise: "Bench", weight: 300, reps: 10, rpe: 6, kind: .working))
        }

        let sessions = try context.fetch(FetchDescriptor<WorkoutSession>())
        let records = StreakCalculator.personalRecords(sessions: sessions)
        XCTAssertEqual(records.map(\.exercise), ["Bench", "Bench (variation 1)", "Row"])

        let bench = try XCTUnwrap(records.first { $0.exercise == "Bench" })
        XCTAssertEqual(bench.weight, 225)
        XCTAssertEqual(bench.unit, .lb)
        XCTAssertEqual(bench.reps, 4)
        XCTAssertEqual(bench.rpe, 8.5)
        XCTAssertEqual(bench.achievedAt, d2)

        let variation = try XCTUnwrap(records.first { $0.exercise == "Bench (variation 1)" })
        XCTAssertEqual(variation.weight, 90)
        XCTAssertEqual(variation.unit, .kg)
        XCTAssertEqual(variation.reps, 6)

        let row = try XCTUnwrap(records.first { $0.exercise == "Row" })
        XCTAssertEqual(row.weight, 80)
        XCTAssertEqual(row.unit, .kg)
        XCTAssertEqual(row.reps, 10)
        XCTAssertEqual(row.achievedAt, d3)
    }
}
