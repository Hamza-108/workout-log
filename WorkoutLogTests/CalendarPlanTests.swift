import Foundation
import SwiftData
import XCTest
@testable import WorkoutLog

// Covers the calendar planning model only: day keys, rule resolution, one-off
// overrides, weekly recurrence, completion matching, walking days and the
// rollback behaviour of the shared save helper. UI rendering and the backup
// codec are owned elsewhere.
@MainActor
final class CalendarPlanTests: XCTestCase {
    // MARK: - Helpers

    private func container(url: URL? = nil) throws -> ModelContainer {
        let schema = Schema([WorkoutTemplate.self, WorkoutSession.self, LibraryExercise.self, LibrarySetup.self, CalendarRule.self, WalkingCompletion.self])
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

    private func rules(in context: ModelContext) throws -> [CalendarRule] {
        try context.fetch(FetchDescriptor<CalendarRule>())
    }

    /// The status of a day as the plain text of `DayStatus`, so expectations stay readable.
    private func status(_ day: String, in context: ModelContext) throws -> String {
        Schedule.status(on: day,
                        rules: try rules(in: context),
                        sessions: try context.fetch(FetchDescriptor<WorkoutSession>()),
                        walks: try context.fetch(FetchDescriptor<WalkingCompletion>())).rawValue
    }

    private func plannedTemplate(_ day: String, in context: ModelContext) throws -> UUID? {
        Schedule.rule(on: day, rules: try rules(in: context))?.templateID
    }

    private func plannedKind(_ day: String, in context: ModelContext) throws -> String? {
        Schedule.rule(on: day, rules: try rules(in: context))?.kind
    }

    @discardableResult
    private func makeTemplate(_ name: String, _ exercises: [String], in context: ModelContext) throws -> WorkoutTemplate {
        let template = WorkoutTemplate(name: name, exercises: exercises)
        try context.commit { context.insert(template) }
        return template
    }

    private func completeSession(from template: WorkoutTemplate, on day: String, calendar: Calendar, in context: ModelContext) throws -> WorkoutSession {
        let session = try WorkoutSession.start(template: template, unit: .kg, in: context)
        let moment = try XCTUnwrap(Schedule.date(day, calendar: calendar), day)
        try context.commit {
            try session.record(LoggedSet(exercise: template.exercises[0], weight: 20, reps: 8, rpe: 7))
            try session.finish(at: moment, calendar: calendar)
        }
        return session
    }

    // MARK: - Day keys

    func testDayKeysRoundTripAndRejectMalformedValues() throws {
        let calendar = Schedule.calendar(timeZone: try zone("UTC"))
        for day in ["2024-01-01", "2024-02-29", "2024-03-31", "2024-04-30", "2024-12-31", "2025-01-01",
                    "2023-12-31", "2000-02-29", "1999-12-31", "0001-01-01", "9999-12-31"] {
            let date = try XCTUnwrap(Schedule.date(day, calendar: calendar), day)
            XCTAssertEqual(Schedule.day(date, calendar: calendar), day, day)
            XCTAssertTrue(Schedule.validDay(day), day)
        }
        for day in ["", " ", "2024-13-01", "2024-00-10", "2024-01-32", "2024-01-00",
                    "2024-2-1", "20240101", "2024-01-01T00:00:00", "2024-01-01 ", " 2024-01-01",
                    "2024-01-01-", "2024--01-01", "abcd-ef-gh", "2024-01-0a", "2024-01-01\n",
                    "2023-02-29", "1900-02-29", "2100-02-29", "0000-01-01", "9999-13-01", "9999-12-32",
                    "2024-02-30", "2024-04-31"] {
            XCTAssertNil(Schedule.date(day, calendar: calendar), day)
            XCTAssertFalse(Schedule.validDay(day), day)
            XCTAssertNil(Schedule.weekday(day), day)
        }
        // The Gregorian weekday is stable and independent of the local calendar.
        XCTAssertEqual(Schedule.weekday("2024-01-01"), 2)
        XCTAssertEqual(Schedule.weekday("2024-03-03"), 1)
        XCTAssertEqual(Schedule.weekday("2024-03-04"), 2)
        XCTAssertEqual(Schedule.weekday("2024-03-10"), 1)
    }

    func testMonthAndYearBoundariesAreContiguous() throws {
        let calendar = Schedule.calendar(timeZone: try zone("UTC"))
        let pairs = [("2024-01-31", "2024-02-01"), ("2024-02-28", "2024-02-29"), ("2024-02-29", "2024-03-01"),
                     ("2024-04-30", "2024-05-01"), ("2024-12-31", "2025-01-01"), ("2023-12-31", "2024-01-01"),
                     ("2023-02-28", "2023-03-01")]
        for (previous, next) in pairs {
            let first = try XCTUnwrap(Schedule.date(previous, calendar: calendar), previous)
            let second = try XCTUnwrap(Schedule.date(next, calendar: calendar), next)
            XCTAssertEqual(second.timeIntervalSince(first), 24 * 3600, "\(previous) -> \(next)")
            XCTAssertEqual(Schedule.day(first.addingTimeInterval(12 * 3600), calendar: calendar), next)
        }
    }

    func testLocalMidnightAndUTCDayKeysCanDiffer() throws {
        let berlin = Schedule.calendar(timeZone: try zone("Europe/Berlin"))
        let utc = Schedule.calendar(timeZone: try zone("UTC"))
        let localMidnight = try XCTUnwrap(berlin.date(from: DateComponents(year: 2024, month: 3, day: 31, hour: 0)))
        XCTAssertEqual(Schedule.day(localMidnight, calendar: berlin), "2024-03-31")
        XCTAssertEqual(Schedule.day(localMidnight, calendar: utc), "2024-03-30")
        // The same instant rendered with a far eastern offset lands on the previous UTC day.
        let east = Schedule.calendar(timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 14 * 3600)))
        let noon = try XCTUnwrap(Schedule.date("2024-03-31", calendar: east))
        XCTAssertEqual(Schedule.day(noon, calendar: east), "2024-03-31")
        XCTAssertEqual(Schedule.day(noon, calendar: utc), "2024-03-30")
    }

    func testDaylightSavingDaysHaveTwentyThreeAndTwentyFiveHours() throws {
        let newYork = Schedule.calendar(timeZone: try zone("America/New_York"))
        let startMarch = try XCTUnwrap(newYork.date(from: DateComponents(year: 2024, month: 3, day: 10, hour: 0)))
        let endMarch = try XCTUnwrap(newYork.date(from: DateComponents(year: 2024, month: 3, day: 11, hour: 0)))
        XCTAssertEqual(endMarch.timeIntervalSince(startMarch), 23 * 3600)
        let startNovember = try XCTUnwrap(newYork.date(from: DateComponents(year: 2024, month: 11, day: 3, hour: 0)))
        let endNovember = try XCTUnwrap(newYork.date(from: DateComponents(year: 2024, month: 11, day: 4, hour: 0)))
        XCTAssertEqual(endNovember.timeIntervalSince(startNovember), 25 * 3600)
        // Day keys keep working on both transition days.
        for day in ["2024-03-10", "2024-03-11", "2024-11-03", "2024-11-04"] {
            let date = try XCTUnwrap(Schedule.date(day, calendar: newYork), day)
            XCTAssertEqual(Schedule.day(date, calendar: newYork), day, day)
            XCTAssertTrue(Schedule.validDay(day), day)
        }
        // Month lengths account for the transition.
        let march = try XCTUnwrap(newYork.date(from: DateComponents(year: 2024, month: 3, day: 1, hour: 0)))
        let april = try XCTUnwrap(newYork.date(from: DateComponents(year: 2024, month: 4, day: 1, hour: 0)))
        XCTAssertEqual(april.timeIntervalSince(march), 743 * 3600)
        let november = try XCTUnwrap(newYork.date(from: DateComponents(year: 2024, month: 11, day: 1, hour: 0)))
        let december = try XCTUnwrap(newYork.date(from: DateComponents(year: 2024, month: 12, day: 1, hour: 0)))
        XCTAssertEqual(december.timeIntervalSince(november), 719 * 3600)
    }

    func testDayKeysSurviveZonesWhereMidnightIsSkipped() throws {
        let santiago = Schedule.calendar(timeZone: try zone("America/Santiago"))
        for day in ["2024-09-07", "2024-09-08", "2024-09-09"] {
            let date = try XCTUnwrap(Schedule.date(day, calendar: santiago), day)
            XCTAssertEqual(Schedule.day(date, calendar: santiago), day, day)
        }
        // The transition happens on that date even though local midnight never occurs.
        let before = santiago.timeZone.secondsFromGMT(for: try XCTUnwrap(Schedule.date("2024-09-07", calendar: santiago)))
        let after = santiago.timeZone.secondsFromGMT(for: try XCTUnwrap(Schedule.date("2024-09-08", calendar: santiago)))
        XCTAssertEqual(after - before, 3600)
        if let start = santiago.date(from: DateComponents(year: 2024, month: 9, day: 8, hour: 0)),
           let end = santiago.date(from: DateComponents(year: 2024, month: 9, day: 9, hour: 0)),
           santiago.component(.hour, from: start) == 1 {
            XCTAssertEqual(end.timeIntervalSince(start), 23 * 3600)
        }
    }

    // MARK: - Assignments

    func testSpecificDateAssignmentOnlyCoversThatDay() throws {
        let store = try container()
        let context = store.mainContext
        let template = try makeTemplate("Push", ["Bench"], in: context)
        try Schedule.assign(on: "2024-03-04", kind: .template, template: template, repeating: false, in: context)
        XCTAssertEqual(try rules(in: context).count, 1)
        let rule = try XCTUnwrap(Schedule.rule(on: "2024-03-04", rules: try rules(in: context)))
        XCTAssertNil(rule.weekday)
        XCTAssertEqual(rule.kind, PlanKind.template.rawValue)
        XCTAssertEqual(rule.templateID, template.id)
        XCTAssertEqual(rule.templateName, "Push")
        XCTAssertEqual(try status("2024-03-04", in: context), DayStatus.pending)
        XCTAssertEqual(try status("2024-03-05", in: context), DayStatus.unassigned)
        XCTAssertEqual(try status("2024-03-11", in: context), DayStatus.unassigned)
        // Assigning the same day again replaces the plan instead of duplicating it.
        let other = try makeTemplate("Pull", ["Row"], in: context)
        try Schedule.assign(on: "2024-03-04", kind: .template, template: other, repeating: false, in: context)
        XCTAssertEqual(try rules(in: context).count, 1)
        XCTAssertEqual(try plannedTemplate("2024-03-04", in: context), other.id)
    }

    func testWeeklyAssignmentRepeatsOnTheSameWeekday() throws {
        let store = try container()
        let context = store.mainContext
        let template = try makeTemplate("Push", ["Bench"], in: context)
        try Schedule.assign(on: "2024-03-04", kind: .template, template: template, repeating: true, in: context)
        let rule = try XCTUnwrap(Schedule.rule(on: "2024-03-04", rules: try rules(in: context)))
        XCTAssertEqual(rule.weekday, 2)
        XCTAssertEqual(rule.startDay, "2024-03-04")
        XCTAssertNil(rule.endDay)
        for day in ["2024-03-04", "2024-03-11", "2024-03-18", "2024-03-25", "2024-04-01", "2024-04-08"] {
            XCTAssertEqual(try plannedTemplate(day, in: context), template.id, day)
            XCTAssertEqual(try status(day, in: context), DayStatus.pending, day)
        }
        for day in ["2024-03-03", "2024-03-05", "2024-03-10", "2024-03-12", "2024-03-31", "2024-04-02"] {
            XCTAssertEqual(try status(day, in: context), DayStatus.unassigned, day)
        }
    }

    func testOneOffOverrideAndClearLeaveOtherWeeklyDaysUntouched() throws {
        let store = try container()
        let context = store.mainContext
        let weekly = try makeTemplate("Push", ["Bench"], in: context)
        let single = try makeTemplate("Pull", ["Row"], in: context)
        try Schedule.assign(on: "2024-03-04", kind: .template, template: weekly, repeating: true, in: context)
        try Schedule.assign(on: "2024-03-11", kind: .template, template: single, repeating: false, in: context)
        XCTAssertEqual(try plannedTemplate("2024-03-11", in: context), single.id)
        XCTAssertEqual(try plannedTemplate("2024-03-04", in: context), weekly.id)
        XCTAssertEqual(try plannedTemplate("2024-03-18", in: context), weekly.id)
        XCTAssertEqual(try plannedTemplate("2024-03-25", in: context), weekly.id)
        // A different kind on the same day replaces the plan as well.
        try Schedule.assign(on: "2024-03-11", kind: .walking, repeating: false, in: context)
        XCTAssertEqual(try plannedKind("2024-03-11", in: context), PlanKind.walking.rawValue)
        XCTAssertEqual(try plannedTemplate("2024-03-18", in: context), weekly.id)
        // Clearing the overridden day hides it without touching the weekly plan.
        try Schedule.assign(on: "2024-03-11", kind: .none, repeating: false, in: context)
        XCTAssertEqual(try plannedKind("2024-03-11", in: context), PlanKind.none.rawValue)
        XCTAssertEqual(try status("2024-03-11", in: context), DayStatus.unassigned)
        XCTAssertEqual(try plannedTemplate("2024-03-04", in: context), weekly.id)
        XCTAssertEqual(try plannedTemplate("2024-03-18", in: context), weekly.id)
        XCTAssertEqual(try plannedTemplate("2024-03-25", in: context), weekly.id)
        XCTAssertEqual(try status("2024-03-18", in: context), DayStatus.pending)
    }

    func testEditingWeeklyFromSelectedDateKeepsPastAndFutureOverrides() throws {
        let store = try container()
        let context = store.mainContext
        let first = try makeTemplate("Push", ["Bench"], in: context)
        let second = try makeTemplate("Pull", ["Row"], in: context)
        let third = try makeTemplate("Legs", ["Squat"], in: context)
        let edited = try makeTemplate("Core", ["Plank"], in: context)
        try Schedule.assign(on: "2024-03-04", kind: .template, template: first, repeating: true, in: context)
        try Schedule.assign(on: "2024-03-11", kind: .template, template: second, repeating: false, in: context)
        try Schedule.assign(on: "2024-03-25", kind: .template, template: third, repeating: false, in: context)
        // Editing the weekly plan from 2024-03-18 forward only replaces that range.
        try Schedule.assign(on: "2024-03-18", kind: .template, template: edited, repeating: true, in: context)
        XCTAssertEqual(try plannedTemplate("2024-03-04", in: context), first.id)
        XCTAssertEqual(try plannedTemplate("2024-03-11", in: context), second.id)
        XCTAssertEqual(try plannedTemplate("2024-03-18", in: context), edited.id)
        XCTAssertEqual(try plannedTemplate("2024-03-25", in: context), third.id)
        XCTAssertEqual(try plannedTemplate("2024-04-01", in: context), edited.id)
        XCTAssertEqual(try plannedTemplate("2024-04-08", in: context), edited.id)
        // The past window keeps its own rule and its end is exclusive.
        let windows = try rules(in: context).filter { $0.weekday == 2 }
        XCTAssertEqual(windows.count, 2)
        let past = try XCTUnwrap(windows.first { $0.startDay == "2024-03-04" })
        XCTAssertEqual(past.endDay, "2024-03-18")
        XCTAssertEqual(past.templateID, first.id)
    }

    func testInvalidOrUnavailableAssignmentsAreRejectedWithoutChanges() throws {
        let store = try container()
        let context = store.mainContext
        let template = try makeTemplate("Push", ["Bench"], in: context)
        for day in ["", "2024-13-01", "2024-02-30", "not-a-day"] {
            XCTAssertThrowsError(try Schedule.assign(on: day, kind: .template, template: template, repeating: false, in: context), day)
            XCTAssertThrowsError(try Schedule.assign(on: day, kind: .walking, repeating: false, in: context), day)
        }
        XCTAssertThrowsError(try Schedule.assign(on: "2024-03-04", kind: .template, repeating: false, in: context))
        let stale = WorkoutTemplate(name: "Ghost", exercises: ["Bench"])
        XCTAssertThrowsError(try Schedule.assign(on: "2024-03-04", kind: .template, template: stale, repeating: false, in: context))
        XCTAssertTrue(try rules(in: context).isEmpty)
        XCTAssertEqual(try status("2024-03-04", in: context), DayStatus.unassigned)
    }

    // MARK: - Completion

    func testDayCompletesOnlyForFinishedSessionWithSameTemplateAndDay() throws {
        let store = try container()
        let context = store.mainContext
        let calendar = Schedule.calendar(timeZone: try zone("UTC"))
        let template = try makeTemplate("Push", ["Bench"], in: context)
        let other = try makeTemplate("Pull", ["Row"], in: context)
        try Schedule.assign(on: "2024-03-04", kind: .template, template: template, repeating: false, in: context)

        // A draft never completes the day.
        let draft = try WorkoutSession.start(template: template, unit: .kg, in: context)
        XCTAssertEqual(try status("2024-03-04", in: context), DayStatus.pending)
        try context.commit { try draft.record(LoggedSet(exercise: "Bench", weight: 20, reps: 8, rpe: 7)) }
        XCTAssertEqual(try status("2024-03-04", in: context), DayStatus.pending)

        // Finishing on another local day leaves the planned day pending.
        let otherDay = try XCTUnwrap(Schedule.date("2024-03-05", calendar: calendar))
        try context.commit { try draft.finish(at: otherDay, calendar: calendar) }
        XCTAssertEqual(draft.completedDay, "2024-03-05")
        XCTAssertEqual(try status("2024-03-04", in: context), DayStatus.pending)

        // A finished session from a different template does not complete the day.
        let foreign = try completeSession(from: other, on: "2024-03-04", calendar: calendar, in: context)
        XCTAssertEqual(foreign.completedDay, "2024-03-04")
        XCTAssertEqual(try status("2024-03-04", in: context), DayStatus.pending)

        // The matching template finishing on the planned day completes it.
        let matching = try completeSession(from: template, on: "2024-03-04", calendar: calendar, in: context)
        XCTAssertEqual(try status("2024-03-04", in: context), DayStatus.completed)

        // Legacy rows without a source template are never matched by name.
        try context.commit { matching.sourceTemplateID = nil }
        XCTAssertEqual(matching.templateName, "Push")
        XCTAssertEqual(try status("2024-03-04", in: context), DayStatus.pending)
        try context.commit { matching.sourceTemplateID = template.id }
        XCTAssertEqual(try status("2024-03-04", in: context), DayStatus.completed)
    }

    func testDeletingCompletedSessionReturnsTheDayToPending() throws {
        let store = try container()
        let context = store.mainContext
        let calendar = Schedule.calendar(timeZone: try zone("UTC"))
        let template = try makeTemplate("Push", ["Bench"], in: context)
        try Schedule.assign(on: "2024-03-04", kind: .template, template: template, repeating: false, in: context)
        let session = try completeSession(from: template, on: "2024-03-04", calendar: calendar, in: context)
        XCTAssertEqual(try status("2024-03-04", in: context), DayStatus.completed)
        try context.commit { context.delete(session) }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkoutSession>()), 0)
        XCTAssertEqual(try status("2024-03-04", in: context), DayStatus.pending)
        XCTAssertEqual(try rules(in: context).count, 1)
    }

    func testRenamingOrDeletingTemplateKeepsHistoryAndBlocksNewAssignments() throws {
        let store = try container()
        let context = store.mainContext
        let calendar = Schedule.calendar(timeZone: try zone("UTC"))
        let template = try makeTemplate("Push", ["Bench"], in: context)
        try Schedule.assign(on: "2024-03-04", kind: .template, template: template, repeating: false, in: context)
        let session = try completeSession(from: template, on: "2024-03-04", calendar: calendar, in: context)
        let templateID = template.id

        try context.commit { template.name = "Push Day" }
        XCTAssertEqual(session.templateName, "Push")
        XCTAssertEqual(session.exercises, ["Bench"])
        XCTAssertEqual(session.sourceTemplateID, templateID)
        XCTAssertEqual(try status("2024-03-04", in: context), DayStatus.completed)

        try context.commit { context.delete(template) }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkoutTemplate>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkoutSession>()), 1)
        XCTAssertEqual(session.templateName, "Push")
        XCTAssertEqual(session.exercises, ["Bench"])
        XCTAssertEqual(session.sets.count, 1)
        XCTAssertEqual(session.completedDay, "2024-03-04")
        // The saved history still belongs to the planned day.
        XCTAssertEqual(try status("2024-03-04", in: context), DayStatus.completed)

        // A deleted template is no longer an available assignment target.
        let stale = WorkoutTemplate(name: "Push", exercises: ["Bench"])
        stale.id = templateID
        XCTAssertThrowsError(try Schedule.assign(on: "2024-03-11", kind: .template, template: stale, repeating: false, in: context))
        XCTAssertNil(try plannedTemplate("2024-03-11", in: context))
        XCTAssertEqual(try rules(in: context).count, 1)
    }

    func testCompletedDayIsStoredAndStableAcrossTimeZoneChanges() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutLog-calendar-day-\(UUID()).store")
        let newYork = Schedule.calendar(timeZone: try zone("America/New_York"))
        let tokyo = Schedule.calendar(timeZone: try zone("Asia/Tokyo"))
        do {
            let store = try container(url: url)
            let context = store.mainContext
            let template = try makeTemplate("Push", ["Bench"], in: context)
            try Schedule.assign(on: "2024-03-04", kind: .template, template: template, repeating: false, in: context)
            try Schedule.assign(on: "2024-03-05", kind: .template, template: template, repeating: false, in: context)
            let instant = try XCTUnwrap(Schedule.date("2024-03-04", calendar: newYork))
            XCTAssertEqual(Schedule.day(instant, calendar: newYork), "2024-03-04")
            XCTAssertEqual(Schedule.day(instant, calendar: tokyo), "2024-03-05")
            let session = try WorkoutSession.start(template: template, unit: .kg, in: context)
            try context.commit {
                try session.record(LoggedSet(exercise: "Bench", weight: 20, reps: 8, rpe: 7))
                try session.finish(at: instant, calendar: newYork)
            }
            XCTAssertEqual(session.completedDay, "2024-03-04")
            XCTAssertEqual(try status("2024-03-04", in: context), DayStatus.completed)
            XCTAssertEqual(try status("2024-03-05", in: context), DayStatus.pending)
        }
        let reopened = try container(url: url)
        let context = reopened.mainContext
        let session = try XCTUnwrap(context.fetch(FetchDescriptor<WorkoutSession>()).first)
        XCTAssertEqual(session.completedDay, "2024-03-04")
        XCTAssertEqual(try status("2024-03-04", in: context), DayStatus.completed)
    }

    // MARK: - Walking

    func testWalkingCompletionIsIdempotentAndReversible() throws {
        let store = try container()
        let context = store.mainContext
        let calendar = Schedule.calendar(timeZone: try zone("UTC"))
        try Schedule.assign(on: "2024-03-04", kind: .walking, repeating: true, in: context)
        let now = try XCTUnwrap(Schedule.date("2024-03-06", calendar: calendar))
        XCTAssertEqual(try status("2024-03-04", in: context), DayStatus.pending)
        XCTAssertEqual(try status("2024-03-05", in: context), DayStatus.unassigned)

        try Schedule.markWalk(on: "2024-03-04", done: true, in: context, now: now, calendar: calendar)
        XCTAssertEqual(try status("2024-03-04", in: context), DayStatus.completed)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WalkingCompletion>()), 1)

        // Marking twice keeps a single entry.
        try Schedule.markWalk(on: "2024-03-04", done: true, in: context, now: now, calendar: calendar)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WalkingCompletion>()), 1)
        XCTAssertEqual(try status("2024-03-04", in: context), DayStatus.completed)

        // Undoing removes the entry and repeating the undo is harmless.
        try Schedule.markWalk(on: "2024-03-04", done: false, in: context, now: now, calendar: calendar)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WalkingCompletion>()), 0)
        XCTAssertEqual(try status("2024-03-04", in: context), DayStatus.pending)
        try Schedule.markWalk(on: "2024-03-04", done: false, in: context, now: now, calendar: calendar)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WalkingCompletion>()), 0)
        XCTAssertEqual(try status("2024-03-04", in: context), DayStatus.pending)

        // A walking day planned for one specific date behaves the same way.
        try Schedule.assign(on: "2024-03-05", kind: .walking, repeating: false, in: context)
        XCTAssertEqual(try plannedKind("2024-03-05", in: context), PlanKind.walking.rawValue)
        try Schedule.markWalk(on: "2024-03-05", done: true, in: context, now: now, calendar: calendar)
        XCTAssertEqual(try status("2024-03-05", in: context), DayStatus.completed)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WalkingCompletion>()), 1)
        // The weekly Monday plan is not affected by the extra Tuesday entry.
        XCTAssertEqual(try status("2024-03-04", in: context), DayStatus.pending)
    }

    func testWalkingCannotBeMarkedInTheFutureOrOnOtherDays() throws {
        let store = try container()
        let context = store.mainContext
        let calendar = Schedule.calendar(timeZone: try zone("UTC"))
        let template = try makeTemplate("Push", ["Bench"], in: context)
        try Schedule.assign(on: "2024-03-04", kind: .walking, repeating: true, in: context)
        try Schedule.assign(on: "2024-03-05", kind: .template, template: template, repeating: false, in: context)
        let now = try XCTUnwrap(Schedule.date("2024-03-06", calendar: calendar))
        // 2024-03-11 is a planned walking day but still in the future.
        XCTAssertThrowsError(try Schedule.markWalk(on: "2024-03-11", done: true, in: context, now: now, calendar: calendar))
        // 2024-03-05 is a template day, 2024-03-07 is not planned at all.
        XCTAssertThrowsError(try Schedule.markWalk(on: "2024-03-05", done: true, in: context, now: now, calendar: calendar))
        XCTAssertThrowsError(try Schedule.markWalk(on: "2024-03-07", done: true, in: context, now: now, calendar: calendar))
        XCTAssertThrowsError(try Schedule.markWalk(on: "2024-02-30", done: true, in: context, now: now, calendar: calendar))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WalkingCompletion>()), 0)
        // Clearing a walking day also stops it from being marked.
        try Schedule.assign(on: "2024-03-04", kind: .none, repeating: false, in: context)
        XCTAssertThrowsError(try Schedule.markWalk(on: "2024-03-04", done: true, in: context, now: now, calendar: calendar))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WalkingCompletion>()), 0)
    }

    // MARK: - Saving

    func testFailedSaveRollsBackRulesAndWalkingEntries() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutLog-calendar-rollback-\(UUID()).store")
        let store = try container(url: url)
        let context = store.mainContext
        let calendar = Schedule.calendar(timeZone: try zone("UTC"))
        let template = try makeTemplate("Push", ["Bench"], in: context)
        try Schedule.assign(on: "2024-03-04", kind: .template, template: template, repeating: false, in: context)
        try Schedule.assign(on: "2024-03-05", kind: .walking, repeating: false, in: context)
        let now = try XCTUnwrap(Schedule.date("2024-03-06", calendar: calendar))
        try Schedule.markWalk(on: "2024-03-05", done: true, in: context, now: now, calendar: calendar)
        XCTAssertEqual(try rules(in: context).count, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WalkingCompletion>()), 1)

        let failure = expectation(forNotification: .workoutSaveFailed, object: context)
        XCTAssertThrowsError(try context.commit {
            context.insert(CalendarRule(startDay: "2024-03-18", kind: .template, templateID: template.id, templateName: "Push"))
            context.insert(WalkingCompletion(day: "2024-03-19"))
            throw LogError(message: "Simulated failure")
        })
        wait(for: [failure], timeout: 1)
        XCTAssertFalse(context.hasChanges)

        // A fresh context only sees the committed rows.
        let fresh = ModelContext(store)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<CalendarRule>()), 2)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<WalkingCompletion>()), 1)
        let reopened = try container(url: url)
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<CalendarRule>()), 2)
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<WalkingCompletion>()), 1)
    }
}
