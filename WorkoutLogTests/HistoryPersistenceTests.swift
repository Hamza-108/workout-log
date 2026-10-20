import SwiftData
import XCTest
@testable import WorkoutLog

@MainActor
final class HistoryPersistenceTests: XCTestCase {
    func testDeletingHistoryKeepsTemplateAndDraftAfterReopen() throws {
        let schema = Schema([WorkoutTemplate.self, WorkoutSession.self])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutLog-delete-\(UUID()).store")
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        var expectedDraft: UUID?
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let template = WorkoutTemplate(name: "Push", exercises: ["Bench"])
            try context.commit { context.insert(template) }
            let completed = try WorkoutSession.start(template: template, unit: .kg, in: context)
            try context.commit {
                try completed.record(LoggedSet(exercise: "Bench", weight: 20, reps: 8, rpe: 7))
                try completed.finish()
            }
            let other = try WorkoutSession.start(template: template, unit: .kg, in: context)
            try context.commit {
                try other.record(LoggedSet(exercise: "Bench", weight: 25, reps: 5, rpe: 8))
                try other.finish()
            }
            let draft = try WorkoutSession.start(template: template, unit: .lb, in: context)
            try context.commit { try draft.record(LoggedSet(exercise: "Bench", weight: 45, reps: 5, rpe: 6)) }
            expectedDraft = draft.id
            try context.commit { context.delete(completed) }
        }
        let reopened = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(reopened)
        let sessions = try context.fetch(FetchDescriptor<WorkoutSession>())
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.first(where: { $0.finishedAt != nil })?.sets.first?.weight, 25)
        let draft = try XCTUnwrap(sessions.first(where: { $0.finishedAt == nil }))
        XCTAssertEqual(draft.id, expectedDraft)
        XCTAssertNil(draft.finishedAt)
        XCTAssertEqual(draft.unit, "lb")
        XCTAssertEqual(draft.sets.first?.weight, 45)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WorkoutTemplate>()).first?.name, "Push")
    }
}
