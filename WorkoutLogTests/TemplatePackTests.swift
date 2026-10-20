import SwiftData
import XCTest
@testable import WorkoutLog

private func packMessage(_ error: Error) -> String {
    (error as? LogError)?.message ?? error.localizedDescription
}

@MainActor
final class TemplatePackTests: XCTestCase {
    private let videoID = "dQw4w9WgXcQ"
    private let otherVideoID = "abc_-ABC123"
    private var canonical: String { "https://www.youtube.com/watch?v=\(videoID)" }
    private var otherCanonical: String { "https://www.youtube.com/watch?v=\(otherVideoID)" }

    private func store(url: URL? = nil) throws -> ModelContainer {
        let schema = Schema([WorkoutTemplate.self, WorkoutSession.self, LibraryExercise.self, LibrarySetup.self, CalendarRule.self, WalkingCompletion.self])
        let config = url.map { ModelConfiguration(schema: schema, url: $0, cloudKitDatabase: .none) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        container.mainContext.autosaveEnabled = false
        return container
    }

    // A whole-plan pack: order is deliberately not alphabetical and one exercise uses the old string form.
    private var wholePlan: String {
        """
        {"templates":[
          {"name":"Zebra day","exercises":[{"name":"Bench press","sets":3,"videoURL":"https://youtu.be/\(videoID)"},{"name":"Row","sets":2}]},
          {"name":"Apple day","exercises":[{"name":"Bench press","sets":4,"videoURL":"https://youtu.be/\(videoID)"},"Squat"]}
        ]}
        """
    }

    private func singlePlan(video: String) -> String {
        "{\"name\":\"Push\",\"exercises\":[{\"name\":\"Bench\",\"sets\":3,\"videoURL\":\"\(video)\"}]}"
    }

    func testDecodesSingleLegacyAndObjectTemplate() throws {
        let legacy = try TemplatePack.decode(Data(#"{"name":"Push day","exercises":["Bench press","Overhead press"]}"#.utf8))
        XCTAssertEqual(legacy.count, 1)
        XCTAssertEqual(legacy[0].name, "Push day")
        XCTAssertEqual(legacy[0].exercises, ["Bench press", "Overhead press"])
        XCTAssertEqual(legacy[0].setCounts, [3, 3])
        XCTAssertNil(legacy[0].videoURLs)

        let modern = try TemplatePack.decode(Data(#"{"name":"Push day","exercises":[{"name":"Bench press","sets":3},{"name":"Overhead press","sets":2}]}"#.utf8))
        XCTAssertEqual(modern.count, 1)
        XCTAssertEqual(modern[0].exercises, ["Bench press", "Overhead press"])
        XCTAssertEqual(modern[0].setCounts, [3, 2])
        XCTAssertNil(modern[0].videoURLs)

        // The single-template helper refuses a pack with more than one template.
        XCTAssertNoThrow(try TemplateDraft.decode(Data(#"{"name":"Push day","exercises":["Bench press"]}"#.utf8)))
        XCTAssertThrowsError(try TemplateDraft.decode(Data(wholePlan.utf8)))
    }

    func testDecodesWholePlanWithOrderCountsAndCanonicalVideos() throws {
        let drafts = try TemplatePack.decode(Data(wholePlan.utf8))
        XCTAssertEqual(drafts.map(\.name), ["Zebra day", "Apple day"])
        XCTAssertEqual(drafts[0].exercises, ["Bench press", "Row"])
        XCTAssertEqual(drafts[0].setCounts, [3, 2])
        XCTAssertEqual(drafts[0].videoURLs ?? [:], ["Bench press": canonical])
        XCTAssertEqual(drafts[1].exercises, ["Bench press", "Squat"])
        XCTAssertEqual(drafts[1].setCounts, [4, 3])
        XCTAssertEqual(drafts[1].videoURLs ?? [:], ["Bench press": canonical])

        // The example shipped in the app decodes into two templates.
        let example = try TemplatePack.decode(Data(TemplateDraft.batchExample.utf8))
        XCTAssertEqual(example.map(\.name), ["Monday", "Tuesday"])
        XCTAssertEqual(example[0].setCounts, [3])
        XCTAssertEqual(example[0].videoURLs ?? [:], ["Bench press": "https://www.youtube.com/watch?v=XXXXXXXXXXX"])
        XCTAssertNil(example[1].videoURLs)
    }

    func testPastedTextMatchesTheBoundedFileRead() throws {
        let text = TemplateDraft.batchExample
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutLog-pack-\(UUID()).json")
        try Data(text.utf8).write(to: url)
        let read = try DataTransfer.read(url)
        XCTAssertEqual(read, Data(text.utf8))
        let fromFile = try TemplatePack.decode(read).map(\.name)
        let fromText = try TemplatePack.decode(Data(text.utf8)).map(\.name)
        XCTAssertEqual(fromFile, fromText)

        let big = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutLog-pack-big-\(UUID()).json")
        try Data(repeating: 32, count: DataTransfer.maximumBytes + 1).write(to: big)
        XCTAssertThrowsError(try DataTransfer.read(big))
        XCTAssertThrowsError(try TemplatePack.decode(Data(repeating: 32, count: DataTransfer.maximumBytes + 1)))
    }

    func testEncodeRoundTripOmitsHistoryIDsAndConfig() throws {
        let container = try store()
        let context = container.mainContext
        let template = WorkoutTemplate(name: "Push", exercises: ["Bench"], setCounts: [3], videoURLs: ["Bench": canonical])
        try context.commit { context.insert(template) }
        let session = try WorkoutSession.start(template: template, unit: .kg, in: context)
        try context.commit {
            try session.record(LoggedSet(exercise: "Bench", weight: 20, reps: 8, rpe: 7))
            try session.finish()
        }

        let data = try TemplatePack.encode([TemplatePack.draft(template)])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"templates\""))
        for forbidden in ["\"id\"", "sessions", "schemaVersion", "preferredWeightUnit", "startedAt", "finishedAt", "unit", "\"weight\"", "reps", "rpe"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        XCTAssertFalse(text.contains(template.id.uuidString))
        XCTAssertFalse(text.contains(session.id.uuidString))

        let back = try TemplatePack.decode(data)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].name, "Push")
        XCTAssertEqual(back[0].exercises, ["Bench"])
        XCTAssertEqual(back[0].setCounts, [3])
        XCTAssertEqual(back[0].videoURLs ?? [:], ["Bench": canonical])
    }

    func testApplySavesEveryTemplateAndReusesLibraryExercises() throws {
        let container = try store()
        let context = container.mainContext
        let drafts = try TemplatePack.decode(Data(wholePlan.utf8))
        try TemplatePack.apply(drafts, in: context)

        let templates = try context.fetch(FetchDescriptor<WorkoutTemplate>(sortBy: [SortDescriptor(\.name)]))
        XCTAssertEqual(templates.map(\.name), ["Apple day", "Zebra day"])
        XCTAssertEqual(templates[0].setCounts ?? [], [4, 3])
        XCTAssertEqual(templates[1].setCounts ?? [], [3, 2])
        XCTAssertEqual(templates[1].videoURLs ?? [:], ["Bench press": canonical])
        XCTAssertEqual(templates[0].videoURLs ?? [:], ["Bench press": canonical])

        let library = try context.fetch(FetchDescriptor<LibraryExercise>(sortBy: [SortDescriptor(\.name)]))
        XCTAssertEqual(library.map(\.name), ["Bench press", "Row", "Squat"])
        XCTAssertEqual(library[0].videoURL, canonical)
        XCTAssertNil(library[1].videoURL)
        XCTAssertNil(library[2].videoURL)

        // Importing the same plan again copies the templates but does not duplicate library entries.
        try TemplatePack.apply(drafts, in: context)
        let copied = try context.fetch(FetchDescriptor<WorkoutTemplate>())
        XCTAssertEqual(copied.count, 4)
        XCTAssertEqual(Set(copied.map(\.id)).count, 4)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LibraryExercise>()), 3)
    }

    func testMalformedPacksAreRejected() throws {
        for json in [#"{"name":"Bad","exercises":[{"name":"Bench","sets":0}]}"#,
                     #"{"name":"Bad","exercises":[{"name":"Bench","sets":100}]}"#,
                     #"{"name":"Bad","exercises":[{"name":"Bench","sets":2.5}]}"#,
                     #"{"name":"Bad","exercises":[{"name":"Bench","sets":"3"}]}"#,
                     #"{"name":"Bad","exercises":[{"name":"Bench","sets":3,"videoURL":"http://www.youtube.com/watch?v=dQw4w9WgXcQ"}]}"#,
                     #"{"name":"Bad","exercises":[{"name":"Bench","sets":3,"videoURL":"https://evil.com/watch?v=dQw4w9WgXcQ"}]}"#,
                     #"{"name":"Bad","exercises":[{"name":"Bench","sets":3,"videoURL":"https://www.youtube.com/watch?v=short"}]}"#] {
            XCTAssertThrowsError(try TemplatePack.decode(Data(json.utf8)), json)
        }

        // A backup file is not a template pack.
        for json in [#"{"schemaVersion":3,"preferredWeightUnit":"kg","templates":[],"sessions":[]}"#,
                     #"{"templates":[{"name":"Push","exercises":["Bench"]}],"sessions":[]}"#] {
            XCTAssertThrowsError(try TemplatePack.decode(Data(json.utf8)), json) { error in
                XCTAssertTrue(packMessage(error).contains("full backup"), packMessage(error))
            }
        }

        XCTAssertThrowsError(try TemplatePack.decode(Data(#"{"templates":[]}"#.utf8))) { error in
            XCTAssertTrue(packMessage(error).contains("at least one template"), packMessage(error))
        }

        // Two templates in one pack define the same exercise with different videos.
        let conflict = """
        {"templates":[
          {"name":"Monday","exercises":[{"name":"Bench","sets":3,"videoURL":"https://youtu.be/\(videoID)"}]},
          {"name":"Tuesday","exercises":[{"name":"Bench","sets":3,"videoURL":"https://youtu.be/\(otherVideoID)"}]}
        ]}
        """
        let drafts = try TemplatePack.decode(Data(conflict.utf8))
        let database = try store()
        let review = try TemplatePack.review(drafts, in: database.mainContext)
        XCTAssertEqual(review.conflicts.count, 1)
        XCTAssertThrowsError(try TemplatePack.apply(drafts, in: database.mainContext))
        XCTAssertEqual(try database.mainContext.fetchCount(FetchDescriptor<WorkoutTemplate>()), 0)
    }

    func testConflictingLibraryEntryRejectsImportAndTheStateIsRechecked() throws {
        let container = try store()
        let context = container.mainContext
        try context.commit { context.insert(LibraryExercise(name: "Bench", videoURL: canonical)) }

        let conflicting = try TemplatePack.decode(Data(singlePlan(video: "https://youtu.be/\(otherVideoID)").utf8))
        XCTAssertThrowsError(try TemplatePack.checkLibrary(conflicting, in: context)) { error in
            XCTAssertTrue(packMessage(error).contains("different video"), packMessage(error))
        }
        XCTAssertThrowsError(try TemplatePack.apply(conflicting, in: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkoutTemplate>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LibraryExercise>()), 1)
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LibraryExercise>()).first?.videoURL, canonical)

        // The library is checked again when the pack is applied, so a later change is caught.
        let matching = try TemplatePack.decode(Data(singlePlan(video: "https://youtu.be/\(videoID)").utf8))
        XCTAssertNoThrow(try TemplatePack.checkLibrary(matching, in: context))
        let saved = try XCTUnwrap(context.fetch(FetchDescriptor<LibraryExercise>()).first)
        try context.commit { saved.videoURL = otherCanonical }
        XCTAssertThrowsError(try TemplatePack.apply(matching, in: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkoutTemplate>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LibraryExercise>()), 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LibraryExercise>()).first?.videoURL, otherCanonical)
    }

    func testVersionThreeBackupKeepsLibraryAndVideoSnapshotsAcrossReopen() throws {
        let source = try store()
        let context = source.mainContext
        let template = WorkoutTemplate(name: "Push", exercises: ["Bench"], setCounts: [3], videoURLs: ["Bench": canonical])
        try context.commit { context.insert(template) }
        try context.commit {
            context.insert(LibraryExercise(name: "Bench", videoURL: canonical))
            context.insert(LibraryExercise(name: "Unused", videoURL: nil))
        }
        let session = try WorkoutSession.start(template: template, unit: .kg, in: context)
        try context.commit {
            try session.record(LoggedSet(exercise: "Bench", weight: 20, reps: 8, rpe: 7))
            try session.finish()
        }

        let backup = try DataTransfer.snapshot(in: context, unit: .kg)
        XCTAssertEqual(backup.schemaVersion, 4)
        XCTAssertEqual(backup.libraryExercises?.count, 2)
        XCTAssertEqual(backup.templates[0].videoURLs ?? [:], ["Bench": canonical])
        XCTAssertEqual(backup.sessions[0].videoURLs ?? [:], ["Bench": canonical])
        let decoded = try DataTransfer.decode(DataTransfer.encode(backup))
        XCTAssertEqual(decoded, backup)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutLog-pack-\(UUID()).store")
        do {
            let target = try store(url: url)
            let (preview, unit) = try DataTransfer.apply(decoded, in: target.mainContext)
            XCTAssertEqual(preview.templates.count, 1)
            XCTAssertEqual(preview.sessions.count, 1)
            XCTAssertEqual(preview.libraryExercises.count, 2)
            XCTAssertEqual(preview.skippedExercises, 0)
            XCTAssertEqual(unit, .kg)

            // Restoring the same backup again changes nothing.
            let (again, preference) = try DataTransfer.apply(decoded, in: target.mainContext)
            XCTAssertEqual(again.templates.count, 0)
            XCTAssertEqual(again.sessions.count, 0)
            XCTAssertEqual(again.libraryExercises.count, 0)
            XCTAssertEqual(again.skippedTemplates, 1)
            XCTAssertEqual(again.skippedSessions, 1)
            XCTAssertEqual(again.skippedExercises, 2)
            XCTAssertNil(preference)

            // A conflicting copy is rejected and the saved data stays as it was.
            var conflict = decoded
            conflict.templates[0].name = "Different copy"
            XCTAssertThrowsError(try DataTransfer.apply(conflict, in: target.mainContext))
            XCTAssertEqual(try target.mainContext.fetch(FetchDescriptor<WorkoutTemplate>()).first?.name, "Push")
            XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<LibraryExercise>()), 2)
        }

        let reopened = try store(url: url)
        let after = try DataTransfer.snapshot(in: reopened.mainContext, unit: .kg)
        XCTAssertEqual(after, backup)
        XCTAssertEqual(after.libraryExercises?.map(\.name), ["Bench", "Unused"])
        XCTAssertEqual(after.sessions[0].videoURLs ?? [:], ["Bench": canonical])
    }

    func testVersionOneAndTwoBackupsStillDecodeWithoutLibrary() throws {
        let v1 = try DataTransfer.decode(Data(#"{"schemaVersion":1,"preferredWeightUnit":"kg","templates":[{"id":"11111111-1111-4111-8111-111111111111","name":"Old","exercises":["Bench"]}],"sessions":[]}"#.utf8))
        XCTAssertNil(v1.libraryExercises)
        XCTAssertNil(v1.templates[0].setCounts)
        let v2 = try DataTransfer.decode(Data(#"{"schemaVersion":2,"preferredWeightUnit":"kg","templates":[{"id":"11111111-1111-4111-8111-111111111111","name":"Old","exercises":["Bench"],"setCounts":[2]}],"sessions":[]}"#.utf8))
        XCTAssertNil(v2.libraryExercises)
        XCTAssertEqual(v2.templates[0].setCounts ?? [], [2])

        for backup in [v1, v2] {
            let container = try store()
            try DataTransfer.apply(backup, in: container.mainContext)
            XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<WorkoutTemplate>()), 1)
            XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<LibraryExercise>()), 1)
            XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<WorkoutSession>()), 0)
        }
    }

    func testOptionalVideoOmissionDoesNotConflictOrDiscardAnExplicitLink() throws {
        let json = """
        {"templates":[
          {"name":"Monday","exercises":[{"name":"Bench","sets":3}]},
          {"name":"Friday","exercises":[{"name":"Bench","sets":5,"videoURL":"https://youtu.be/\(videoID)"}]}
        ]}
        """
        let drafts = try TemplatePack.decode(Data(json.utf8))
        let db = try store()
        try TemplatePack.apply(drafts, in: db.mainContext)
        let library = try XCTUnwrap(db.mainContext.fetch(FetchDescriptor<LibraryExercise>()).first)
        XCTAssertEqual(library.videoURL, canonical)
        let templates = try db.mainContext.fetch(FetchDescriptor<WorkoutTemplate>(sortBy: [SortDescriptor(\.name)]))
        XCTAssertNil(templates.first { $0.name == "Monday" }?.videoURLs)
        XCTAssertEqual(templates.first { $0.name == "Friday" }?.videoURLs?["Bench"], canonical)
        try TemplatePack.apply(drafts, in: db.mainContext)
        XCTAssertEqual(try db.mainContext.fetchCount(FetchDescriptor<LibraryExercise>()), 1)
    }

    func testExportsPreserveDifferentTemplateVideoSnapshots() throws {
        let first = TemplateDraft(name: "Monday", exercises: ["Bench"], setCounts: [3], videoURLs: ["Bench": canonical])
        let second = TemplateDraft(name: "Friday", exercises: ["Bench"], setCounts: [5], videoURLs: ["Bench": otherCanonical])
        let exported = try TemplatePack.encode([first, second])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        let templates = try XCTUnwrap(object["templates"] as? [[String: Any]])
        XCTAssertEqual(templates.count, 2)
        // Export keeps both snapshots; review, rather than decoding, resolves their differences.
        let imported = try TemplatePack.decode(exported)
        let database = try store()
        let review = try TemplatePack.review(imported, in: database.mainContext)
        XCTAssertEqual(review.conflicts.count, 1)
        XCTAssertThrowsError(try TemplatePack.apply(review, choices: [:], in: database.mainContext))
    }

    func testBackupReusesIdenticalLibraryDefinitionsWithDifferentIDs() throws {
        let source = try store(), target = try store()
        try source.mainContext.commit { source.mainContext.insert(LibraryExercise(name: "Bench", videoURL: canonical)) }
        let existing = LibraryExercise(name: "Bench", videoURL: canonical)
        try target.mainContext.commit { target.mainContext.insert(existing) }
        let backup = try DataTransfer.snapshot(in: source.mainContext, unit: .kg)
        let (preview, _) = try DataTransfer.apply(backup, in: target.mainContext)
        XCTAssertEqual(preview.libraryExercises.count, 0)
        XCTAssertEqual(preview.skippedExercises, 1)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<LibraryExercise>()), 1)
        XCTAssertEqual(try target.mainContext.fetch(FetchDescriptor<LibraryExercise>()).first?.id, existing.id)
        try target.mainContext.commit { existing.videoURL = otherCanonical }
        XCTAssertThrowsError(try DataTransfer.apply(backup, in: target.mainContext))
    }

    func testTimestampSurvivesTemplateLibrarySessionAndBackupTransfers() throws {
        let text = """
        {"name":"Monday","exercises":[{"name":"Bench","sets":3,"videoURL":"https://youtu.be/\(videoID)?t=1m30s&si=tracking"}]}
        """
        let drafts = try TemplatePack.decode(Data(text.utf8))
        let expected = canonical + "&t=90"
        XCTAssertEqual(drafts[0].videoURLs?["Bench"], expected)
        let source = try store()
        try TemplatePack.apply(drafts, in: source.mainContext)
        let template = try XCTUnwrap(source.mainContext.fetch(FetchDescriptor<WorkoutTemplate>()).first)
        let library = try XCTUnwrap(source.mainContext.fetch(FetchDescriptor<LibraryExercise>()).first)
        XCTAssertEqual(library.videoURL, expected)
        let session = try WorkoutSession.start(template: template, unit: .kg, in: source.mainContext)
        XCTAssertEqual(session.videoURLs?["Bench"], expected)
        let shared = try TemplatePack.decode(TemplatePack.encode([TemplatePack.draft(template)]))
        XCTAssertEqual(shared[0].videoURLs?["Bench"], expected)
        let backup = try DataTransfer.decode(DataTransfer.encode(DataTransfer.snapshot(in: source.mainContext, unit: .kg)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutLog-timestamp-\(UUID()).store")
        do {
            let target = try store(url: url)
            try DataTransfer.apply(backup, in: target.mainContext)
        }
        let reopened = try store(url: url)
        XCTAssertEqual(try reopened.mainContext.fetch(FetchDescriptor<LibraryExercise>()).first?.videoURL, expected)
        XCTAssertEqual(try reopened.mainContext.fetch(FetchDescriptor<WorkoutTemplate>()).first?.videoURLs?["Bench"], expected)
        XCTAssertEqual(try reopened.mainContext.fetch(FetchDescriptor<WorkoutSession>()).first?.videoURLs?["Bench"], expected)
    }

    func testFailedPackSaveLeavesTheSavedFileUnchanged() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutLog-pack-readonly-\(UUID()).store")
        do {
            let target = try store(url: url)
            try target.mainContext.commit { target.mainContext.insert(WorkoutTemplate(name: "Kept", exercises: ["Row"])) }
        }
        let schema = Schema([WorkoutTemplate.self, WorkoutSession.self, LibraryExercise.self, LibrarySetup.self, CalendarRule.self, WalkingCompletion.self])
        let config = ModelConfiguration(schema: schema, url: url, allowsSave: false, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let drafts = try TemplatePack.decode(Data(wholePlan.utf8))
        XCTAssertThrowsError(try TemplatePack.apply(drafts, in: context))
        XCTAssertFalse(context.hasChanges)

        let reopened = try store(url: url)
        XCTAssertEqual(try reopened.mainContext.fetch(FetchDescriptor<WorkoutTemplate>()).map(\.name), ["Kept"])
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<LibraryExercise>()), 0)
    }
}
