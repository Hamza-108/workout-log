import Foundation
import SwiftData
import XCTest
@testable import WorkoutLog

@MainActor
final class LeaderboardProfileTests: XCTestCase {
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

    func testProfilePayloadIncludesOnlySelectedTemplatesAndRespectsPRPrivacyToggle() throws {
        let store = try makeContainer()
        let context = store.mainContext
        let calendar = try utcCalendar()

        let push = WorkoutTemplate(
            name: "Push",
            exercises: ["Bench", "Overhead press"],
            setCounts: [4, 3],
            videoURLs: ["Bench": "https://www.youtube.com/watch?v=abcdefghijk&t=30"]
        )
        let secret = WorkoutTemplate(name: "Secret Legs", exercises: ["Squat"], setCounts: [5])
        try context.commit {
            context.insert(push)
            context.insert(secret)
        }

        try Schedule.assign(on: "2024-03-04", kind: .template, template: push, repeating: true, in: context)
        let session = try WorkoutSession.start(template: push, unit: .kg, in: context)
        let finishedDate = try XCTUnwrap(Schedule.date("2024-03-04", calendar: calendar))
        try context.commit {
            try session.record(LoggedSet(exercise: "Bench", weight: 105, reps: 5, rpe: 8))
            try session.finish(at: finishedDate, calendar: calendar)
        }

        // Also log a private body weight entry and ensure it never appears in the profile JSON.
        try BodyWeightEntry.save(day: "2024-03-04", weight: 82.4, unit: .kg, in: context, now: finishedDate, calendar: calendar)

        let deletedTemplateID = UUID()
        let configWithPRs = LeaderboardProfileConfig(
            displayName: "  Hamza  ",
            sharePersonalRecords: true,
            publishedTemplateIDs: [push.id, deletedTemplateID]
        )

        let rules = try context.fetch(FetchDescriptor<CalendarRule>())
        let sessions = try context.fetch(FetchDescriptor<WorkoutSession>())
        let walks = try context.fetch(FetchDescriptor<WalkingCompletion>())
        let templates = try context.fetch(FetchDescriptor<WorkoutTemplate>())

        let payload = try configWithPRs.buildPayload(
            rules: rules,
            sessions: sessions,
            walks: walks,
            templates: templates,
            today: "2024-03-05",
            now: finishedDate,
            calendar: calendar
        )

        XCTAssertEqual(payload.displayName, "Hamza")
        XCTAssertEqual(payload.currentStreak, 2)
        XCTAssertEqual(payload.bestStreak, 2)
        XCTAssertEqual(payload.adherencePercent, 100)
        XCTAssertEqual(payload.personalRecords.count, 1)
        XCTAssertEqual(payload.personalRecords.first?.exercise, "Bench")
        XCTAssertEqual(payload.personalRecords.first?.weight, 105)
        XCTAssertEqual(payload.publishedTemplates.map(\.name), ["Push"])
        XCTAssertEqual(payload.publishedTemplates.first?.exercises, [
            SharedTemplateExercise(name: "Bench", sets: 4, videoURL: "https://www.youtube.com/watch?v=abcdefghijk&t=30"),
            SharedTemplateExercise(name: "Overhead press", sets: 3, videoURL: nil)
        ])

        let encoded = try String(decoding: JSONEncoder().encode(payload), as: UTF8.self)
        XCTAssertFalse(encoded.contains("Secret Legs"))
        XCTAssertFalse(encoded.contains("82.4"))

        // Disabling sharePersonalRecords omits all PRs while keeping streak and published templates.
        var configPrivatePRs = configWithPRs
        configPrivatePRs.sharePersonalRecords = false
        let payloadNoPRs = try configPrivatePRs.buildPayload(
            rules: rules,
            sessions: sessions,
            walks: walks,
            templates: templates,
            today: "2024-03-05",
            now: finishedDate,
            calendar: calendar
        )
        XCTAssertTrue(payloadNoPRs.personalRecords.isEmpty)
        XCTAssertEqual(payloadNoPRs.publishedTemplates.map(\.name), ["Push"])
    }

    func testDisplayNameValidationRejectsEmptyOrOversizedNamesAndTrimsWhitespace() throws {
        XCTAssertEqual(try SharedProfilePayload.validateDisplayName("  Friend 3 \n"), "Friend 3")
        XCTAssertThrowsError(try SharedProfilePayload.validateDisplayName(""))
        XCTAssertThrowsError(try SharedProfilePayload.validateDisplayName("   \n\t "))
        let tooLong = String(repeating: "a", count: 41)
        XCTAssertThrowsError(try SharedProfilePayload.validateDisplayName(tooLong))
    }

    func testPublishedTemplateDraftImportCreatesLibraryEntriesAndDetectsVideoConflicts() throws {
        let store = try makeContainer()
        let context = store.mainContext

        // Local library already has Bench with a different video link.
        try context.commit {
            context.insert(LibraryExercise(name: "Bench", videoURL: "https://www.youtube.com/watch?v=11111111111"))
        }

        let friendTemplate = SharedTemplate(
            name: "Friend Push",
            exercises: [
                SharedTemplateExercise(name: "Bench", sets: 4, videoURL: "https://www.youtube.com/watch?v=22222222222&t=45"),
                SharedTemplateExercise(name: "Incline DB Press", sets: 3, videoURL: nil)
            ]
        )

        let draft = try friendTemplate.toDraft()
        let review = try TemplatePack.review([draft], in: context)
        XCTAssertEqual(review.conflicts.count, 1)
        XCTAssertEqual(review.conflicts.first?.existing.name, "Bench")

        // Choosing keepBoth creates "Bench (variation 1)" and imports the friend's template safely.
        try TemplatePack.apply(review, choices: [0: .keepBoth], in: context)
        let savedTemplates = try context.fetch(FetchDescriptor<WorkoutTemplate>())
        XCTAssertEqual(savedTemplates.count, 1)
        XCTAssertEqual(savedTemplates.first?.name, "Friend Push")
        XCTAssertEqual(savedTemplates.first?.exercises, ["Bench (variation 1)", "Incline DB Press"])
        XCTAssertEqual(savedTemplates.first?.setCounts, [4, 3])
    }

    func testProfileValidationRejectsInvalidStreaksAdherenceDuplicatePRsOrNonCanonicalVideoLinks() throws {
        let validBase = SharedProfilePayload(
            userID: UUID(),
            displayName: "Friend",
            updatedAt: "2026-01-01T12:00:00.000Z",
            currentStreak: 5,
            bestStreak: 5,
            adherencePercent: 100,
            completedLast30Days: 4,
            assignedLast30Days: 4,
            personalRecords: [
                SharedPersonalRecord(
                    exercise: "Bench",
                    weight: 100,
                    reps: 5,
                    rpe: 8,
                    unit: .kg,
                    achievedAt: "2026-01-01T12:00:00.000Z"
                )
            ],
            publishedTemplates: [
                SharedTemplate(
                    name: "Push",
                    exercises: [SharedTemplateExercise(name: "Bench", sets: 3, videoURL: "https://www.youtube.com/watch?v=abcdefghijk")]
                )
            ]
        )
        XCTAssertNoThrow(try validBase.validate())

        var bestLessThanCurrent = validBase
        bestLessThanCurrent.bestStreak = 4
        XCTAssertThrowsError(try bestLessThanCurrent.validate())

        var badAdherence = validBase
        badAdherence.completedLast30Days = 5
        badAdherence.assignedLast30Days = 4
        XCTAssertThrowsError(try badAdherence.validate())

        var duplicatePR = validBase
        duplicatePR.personalRecords.append(
            SharedPersonalRecord(
                exercise: "bench",
                weight: 110,
                reps: 3,
                rpe: 9,
                unit: .kg,
                achievedAt: "2026-01-01T12:00:00.000Z"
            )
        )
        XCTAssertThrowsError(try duplicatePR.validate())

        var nonCanonicalVideo = validBase
        nonCanonicalVideo.publishedTemplates = [
            SharedTemplate(
                name: "Push",
                exercises: [SharedTemplateExercise(name: "Bench", sets: 3, videoURL: "https://youtu.be/abcdefghijk")]
            )
        ]
        XCTAssertThrowsError(try nonCanonicalVideo.validate())
    }
}
