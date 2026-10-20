import SwiftData
import XCTest
@testable import WorkoutLog

// The user's own import: 3 training days, 21 exercises and 16 YouTube links,
// 13 of which carry a start time. The file is embedded verbatim so the test
// never depends on a temporary file on disk.
private let userImportPack = """
    {
      "templates": [
        {
          "name": "Monday",
          "exercises": [
            {
              "name": "Back Squat",
              "sets": 3,
              "videoURL": "https://www.youtube.com/watch?v=bEv6CCg2BC8&t=147s"
            },
            {
              "name": "Barbell Bench Press",
              "sets": 3,
              "videoURL": "https://www.youtube.com/watch?v=vcBig73ojpE&t=134s"
            },
            {
              "name": "Lat Pulldown",
              "sets": 3,
              "videoURL": "https://www.youtube.com/watch?v=O94yEoGXtBY&t=150s"
            },
            {
              "name": "Romanian Deadlift",
              "sets": 2,
              "videoURL": "https://www.youtube.com/watch?v=_oyxCn2iSjU&t=95s"
            },
            {
              "name": "Assisted Dip",
              "sets": 2,
              "videoURL": "https://www.youtube.com/watch?v=yN6Q1UI_xkE&t=374s"
            },
            {
              "name": "Standing Calf Raise",
              "sets": 2,
              "videoURL": "https://www.youtube.com/watch?v=-qsRtp_PbVM&t=162s"
            },
            {
              "name": "Dumbbell Biceps Curl",
              "sets": 2,
              "videoURL": "https://www.youtube.com/watch?v=i1YgFZB6alI&t=485s"
            }
          ]
        },
        {
          "name": "Wednesday",
          "exercises": [
            {
              "name": "Trap-Bar Deadlift",
              "sets": 2
            },
            {
              "name": "Overhead Press",
              "sets": 3,
              "videoURL": "https://www.youtube.com/watch?v=_RlRDWO2jfg&t=121s"
            },
            {
              "name": "Chest-Supported T-Bar Row",
              "sets": 3,
              "videoURL": "https://www.youtube.com/watch?v=160n9FBX84s"
            },
            {
              "name": "Leg Extension",
              "sets": 2,
              "videoURL": "https://www.youtube.com/watch?v=ljO4jkwv8wQ&t=202s"
            },
            {
              "name": "Cable Chest Fly",
              "sets": 2,
              "videoURL": "https://www.youtube.com/watch?v=-EIhKMDSjBY&t=169s"
            },
            {
              "name": "Cable Crunch",
              "sets": 2,
              "videoURL": "https://www.youtube.com/watch?v=2RrGnjxSsiA&t=70s"
            },
            {
              "name": "Cable Triceps Pushdown",
              "sets": 2
            }
          ]
        },
        {
          "name": "Friday",
          "exercises": [
            {
              "name": "Dumbbell Reverse Lunge",
              "sets": 2
            },
            {
              "name": "Incline Dumbbell Press",
              "sets": 3,
              "videoURL": "https://www.youtube.com/watch?v=p2t9daxLpB8"
            },
            {
              "name": "Reverse-Grip Lat Pulldown",
              "sets": 3,
              "videoURL": "https://www.youtube.com/watch?v=O94yEoGXtBY&t=314s"
            },
            {
              "name": "Hip Thrust Machine",
              "sets": 2
            },
            {
              "name": "Cable Face Pull",
              "sets": 2
            },
            {
              "name": "Dumbbell Lateral Raise",
              "sets": 2,
              "videoURL": "https://www.youtube.com/watch?v=v_ZkxWzYnMc&t=215s"
            },
            {
              "name": "Seated Leg Curl",
              "sets": 2,
              "videoURL": "https://www.youtube.com/watch?v=2CMmuH4qJh0"
            }
          ]
        }
      ]
    }
"""

private func reviewMessage(_ error: Error) -> String {
    (error as? LogError)?.message ?? error.localizedDescription
}

@MainActor
final class ImportReviewTests: XCTestCase {
    // MARK: - Helpers

    private func store(url: URL? = nil) throws -> ModelContainer {
        let schema = Schema([WorkoutTemplate.self, WorkoutSession.self, LibraryExercise.self, LibrarySetup.self, CalendarRule.self, WalkingCompletion.self])
        let config = url.map { ModelConfiguration(schema: schema, url: $0, cloudKitDatabase: .none) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        container.mainContext.autosaveEnabled = false
        return container
    }

    private func link(_ id: String, seconds: Int? = nil) -> String {
        "https://www.youtube.com/watch?v=\(id)" + (seconds.map { "&t=\($0)" } ?? "")
    }

    // The saved library holds the same videos without their start time, like the
    // library of version 0.5 the user had before the timestamps were added.
    private func strippingTimestamp(_ video: String) -> String {
        guard let range = video.range(of: "&t=") else { return video }
        return String(video[video.startIndex..<range.lowerBound])
    }

    private func videoID(_ video: String) -> String? {
        guard let range = video.range(of: "v=") else { return nil }
        return video[range.upperBound...].split(separator: "&").first.map(String.init)
    }

    // The link of one exercise of a draft, if the draft has one.
    private func video(_ draft: TemplateDraft, _ name: String) -> String? {
        guard let videos = draft.videoURLs else { return nil }
        return videos[name]
    }

    // The link of one exercise of a saved template, if the template has one.
    private func video(_ template: WorkoutTemplate, _ name: String) -> String? {
        guard let videos = template.videoURLs else { return nil }
        return videos[name]
    }

    private func seedLibrary(_ drafts: [TemplateDraft], in context: ModelContext) throws {
        var seen = Set(try context.fetch(FetchDescriptor<LibraryExercise>()).map { $0.name.lowercased() })
        for draft in drafts {
            for name in draft.exercises where seen.insert(name.lowercased()).inserted {
                let savedVideo = video(draft, name).map { strippingTimestamp($0) }
                context.insert(LibraryExercise(name: name, videoURL: savedVideo))
            }
        }
        try context.save()
    }

    private func userDrafts() throws -> [TemplateDraft] {
        try TemplatePack.decode(Data(userImportPack.utf8))
    }

    private func replaceAll(_ review: TemplatePack.Review) -> [Int: TemplatePack.Choice] {
        Dictionary(uniqueKeysWithValues: review.conflicts.map { ($0.id, TemplatePack.Choice.replace) })
    }

    // MARK: - The pack itself

    func testUserPackDecodesToThreeDaysWithTwentyOneExercisesAndSixteenLinks() throws {
        let drafts = try userDrafts()
        XCTAssertEqual(drafts.map { $0.name }, ["Monday", "Wednesday", "Friday"])
        XCTAssertEqual(drafts.map { $0.exercises.count }, [7, 7, 7])
        XCTAssertEqual(drafts.flatMap { $0.exercises }.count, 21)
        let videos = drafts.flatMap { Array(($0.videoURLs ?? [:]).values) }
        XCTAssertEqual(videos.count, 16)
        XCTAssertEqual(videos.filter { $0.contains("&t=") }.count, 13)

        // Order, set counts and canonical links of the first day.
        XCTAssertEqual(drafts[0].exercises, ["Back Squat", "Barbell Bench Press", "Lat Pulldown", "Romanian Deadlift",
                                             "Assisted Dip", "Standing Calf Raise", "Dumbbell Biceps Curl"])
        XCTAssertEqual(drafts[0].setCounts, [3, 3, 3, 2, 2, 2, 2])
        XCTAssertEqual(video(drafts[0], "Back Squat"), "https://www.youtube.com/watch?v=bEv6CCg2BC8&t=147")
        XCTAssertEqual(drafts[1].setCounts, [2, 3, 3, 2, 2, 2, 2])
        XCTAssertNil(video(drafts[1], "Trap-Bar Deadlift"))
        XCTAssertEqual(video(drafts[1], "Chest-Supported T-Bar Row"), "https://www.youtube.com/watch?v=160n9FBX84s")
        XCTAssertEqual(drafts[2].setCounts, [2, 3, 3, 2, 2, 2, 2])
        XCTAssertEqual(video(drafts[2], "Seated Leg Curl"), "https://www.youtube.com/watch?v=2CMmuH4qJh0")
        XCTAssertNil(video(drafts[2], "Hip Thrust Machine"))
    }

    // MARK: - Comparing the pack with the saved library

    func testTimestampOnlyLibraryMismatchIsReportedAsAConflict() throws {
        let container = try store()
        let context = container.mainContext
        let drafts = try userDrafts()
        try seedLibrary(drafts, in: context)

        let review = try TemplatePack.review(drafts, in: context)
        XCTAssertEqual(review.bases.count, 21)
        XCTAssertEqual(review.library.count, 21)
        // Only the 13 exercises with a start time differ from the saved library.
        XCTAssertEqual(review.conflicts.count, 13)
        XCTAssertEqual(review.conflicts.map { $0.id }, Array(0..<13))
        for conflict in review.conflicts {
            XCTAssertTrue(conflict.isLibraryEntry)
            let existing = try XCTUnwrap(conflict.existing.videoURL)
            let incoming = try XCTUnwrap(conflict.incoming.videoURL)
            XCTAssertFalse(existing.contains("&t="))
            XCTAssertTrue(incoming.contains("&t="))
            XCTAssertEqual(videoID(existing), videoID(incoming))
            XCTAssertEqual(conflict.templates.count, 1)
        }

        // The review keeps a snapshot of every library entry.
        let saved = try context.fetch(FetchDescriptor<LibraryExercise>())
        XCTAssertEqual(Set(review.library.map { $0.id }), Set(saved.map { $0.id }))
        XCTAssertEqual(review.library.map { $0.name }.sorted(), saved.map { $0.name }.sorted())
        let squat = try XCTUnwrap(review.library.first { $0.name == "Back Squat" })
        XCTAssertEqual(squat.videoURL, "https://www.youtube.com/watch?v=bEv6CCg2BC8")

        // The pack itself is accepted, but the strict import still refuses it
        // until every conflict has been answered.
        XCTAssertThrowsError(try TemplatePack.apply(drafts, in: context)) { error in
            XCTAssertTrue(reviewMessage(error).contains("choose Reject incoming change"), reviewMessage(error))
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkoutTemplate>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LibraryExercise>()), 21)
    }

    func testReplaceOverridesTheLibraryAndImportsTheThreeTemplates() throws {
        let container = try store()
        let context = container.mainContext
        let drafts = try userDrafts()
        try seedLibrary(drafts, in: context)
        let review = try TemplatePack.review(drafts, in: context)
        let choices = replaceAll(review)

        let resolution = try TemplatePack.resolve(review, choices: choices)
        XCTAssertEqual(resolution.additions.count, 0)
        XCTAssertEqual(resolution.overrides.count, 13)
        XCTAssertEqual(resolution.drafts.map { $0.name }, ["Monday", "Wednesday", "Friday"])
        for (resolved, original) in zip(resolution.drafts, drafts) {
            XCTAssertEqual(resolved.exercises, original.exercises)
            XCTAssertEqual(resolved.setCounts, original.setCounts)
            XCTAssertEqual(resolved.videoURLs ?? [:], original.videoURLs ?? [:])
        }

        try TemplatePack.apply(review, choices: choices, in: context)

        let templates = try context.fetch(FetchDescriptor<WorkoutTemplate>(sortBy: [SortDescriptor(\.name)]))
        XCTAssertEqual(templates.map { $0.name }, ["Friday", "Monday", "Wednesday"])
        for template in templates {
            let original = try XCTUnwrap(drafts.first { $0.name == template.name })
            XCTAssertEqual(template.exercises, original.exercises)
            XCTAssertEqual(template.setCounts ?? [], original.setCounts)
            XCTAssertEqual(template.videoURLs ?? [:], original.videoURLs ?? [:])
        }

        // Every library entry now holds the link of the pack, timestamps included.
        let library = try context.fetch(FetchDescriptor<LibraryExercise>())
        XCTAssertEqual(library.count, 21)
        for draft in drafts {
            for name in draft.exercises {
                let entry = try XCTUnwrap(library.first { $0.name == name })
                XCTAssertEqual(entry.videoURL, video(draft, name), name)
            }
        }
        XCTAssertEqual(library.filter { ($0.videoURL ?? "").contains("&t=") }.count, 13)
    }

    func testRejectKeepsTheSavedDefinitionAndDropsTheIncomingStartTime() throws {
        let container = try store()
        let context = container.mainContext
        let drafts = try userDrafts()
        try seedLibrary(drafts, in: context)
        let review = try TemplatePack.review(drafts, in: context)
        let choices = Dictionary(uniqueKeysWithValues: review.conflicts.map { ($0.id, TemplatePack.Choice.reject) })

        let resolution = try TemplatePack.resolve(review, choices: choices)
        XCTAssertEqual(resolution.additions.count, 0)
        XCTAssertEqual(resolution.overrides.count, 0)
        for (resolved, original) in zip(resolution.drafts, drafts) {
            XCTAssertEqual(resolved.exercises, original.exercises)
            XCTAssertEqual(resolved.setCounts, original.setCounts)
            for name in original.exercises {
                XCTAssertEqual(video(resolved, name), video(original, name).map { strippingTimestamp($0) }, name)
            }
        }

        try TemplatePack.apply(review, choices: choices, in: context)

        // The saved library is untouched and still has no start times.
        let library = try context.fetch(FetchDescriptor<LibraryExercise>())
        XCTAssertEqual(library.count, 21)
        XCTAssertEqual(library.filter { ($0.videoURL ?? "").contains("&t=") }.count, 0)
        let templates = try context.fetch(FetchDescriptor<WorkoutTemplate>())
        XCTAssertEqual(templates.count, 3)
        for template in templates {
            let original = try XCTUnwrap(drafts.first { $0.name == template.name })
            for name in original.exercises {
                XCTAssertEqual(video(template, name), video(original, name).map { strippingTimestamp($0) }, name)
            }
        }
    }

    func testKeepBothAddsOneVariationAndKeepsTheSavedEntry() throws {
        let container = try store()
        let context = container.mainContext
        let drafts = try userDrafts()
        try seedLibrary(drafts, in: context)
        let review = try TemplatePack.review(drafts, in: context)
        let first = try XCTUnwrap(review.conflicts.first)
        XCTAssertEqual(first.incoming.name, "Back Squat")

        var choices: [Int: TemplatePack.Choice] = [:]
        for conflict in review.conflicts { choices[conflict.id] = .reject }
        choices[first.id] = .keepBoth

        let resolution = try TemplatePack.resolve(review, choices: choices)
        XCTAssertEqual(resolution.additions.map { $0.name }, ["Back Squat (variation 1)"])
        XCTAssertEqual(resolution.additions.first?.videoURL, "https://www.youtube.com/watch?v=bEv6CCg2BC8&t=147")
        XCTAssertEqual(resolution.overrides.count, 0)
        let monday = try XCTUnwrap(resolution.drafts.first { $0.name == "Monday" })
        XCTAssertEqual(monday.exercises.first, "Back Squat (variation 1)")
        XCTAssertEqual(video(monday, "Back Squat (variation 1)"), "https://www.youtube.com/watch?v=bEv6CCg2BC8&t=147")
        XCTAssertEqual(monday.setCounts, [3, 3, 3, 2, 2, 2, 2])

        try TemplatePack.apply(review, choices: choices, in: context)

        let library = try context.fetch(FetchDescriptor<LibraryExercise>())
        XCTAssertEqual(library.count, 22)
        XCTAssertEqual(library.first { $0.name == "Back Squat" }?.videoURL, "https://www.youtube.com/watch?v=bEv6CCg2BC8")
        XCTAssertEqual(library.first { $0.name == "Back Squat (variation 1)" }?.videoURL, "https://www.youtube.com/watch?v=bEv6CCg2BC8&t=147")
        let templates = try context.fetch(FetchDescriptor<WorkoutTemplate>())
        XCTAssertEqual(templates.count, 3)
        let saved = try XCTUnwrap(templates.first { $0.name == "Monday" })
        XCTAssertEqual(saved.exercises.first, "Back Squat (variation 1)")
    }

    func testExistingTemplatesAndSessionsKeepTheirOwnSnapshots() throws {
        let container = try store()
        let context = container.mainContext
        let existing = WorkoutTemplate(name: "Old plan", exercises: ["Back Squat"], setCounts: [4], videoURLs: ["Back Squat": link("bEv6CCg2BC8")])
        try context.commit { context.insert(existing) }
        try context.commit { context.insert(LibraryExercise(name: "Back Squat", videoURL: link("bEv6CCg2BC8"))) }
        let session = try WorkoutSession.start(template: existing, unit: .kg, in: context)
        try context.commit {
            try session.record(LoggedSet(exercise: "Back Squat", weight: 20, reps: 8, rpe: 7))
            try session.finish()
        }

        let drafts = try userDrafts()
        try seedLibrary(drafts, in: context)
        let review = try TemplatePack.review(drafts, in: context)
        XCTAssertEqual(review.library.count, 21)
        try TemplatePack.apply(review, choices: replaceAll(review), in: context)

        let templates = try context.fetch(FetchDescriptor<WorkoutTemplate>())
        XCTAssertEqual(templates.count, 4)
        let kept = try XCTUnwrap(templates.first { $0.name == "Old plan" })
        XCTAssertEqual(kept.exercises, ["Back Squat"])
        XCTAssertEqual(kept.setCounts ?? [], [4])
        XCTAssertEqual(kept.videoURLs ?? [:], ["Back Squat": link("bEv6CCg2BC8")])

        let sessions = try context.fetch(FetchDescriptor<WorkoutSession>())
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].exercises, ["Back Squat"])
        XCTAssertEqual(sessions[0].videoURLs ?? [:], ["Back Squat": link("bEv6CCg2BC8")])

        let library = try context.fetch(FetchDescriptor<LibraryExercise>())
        XCTAssertEqual(library.count, 21)
        XCTAssertEqual(library.first { $0.name == "Back Squat" }?.videoURL, link("bEv6CCg2BC8", seconds: 147))
    }

    // MARK: - Links that are missing on one side

    func testNilSavedLinkConflictsAndAnOmittedLinkStaysUnlinked() throws {
        let container = try store()
        let context = container.mainContext
        try context.commit {
            context.insert(LibraryExercise(name: "Bench", videoURL: nil))
            context.insert(LibraryExercise(name: "Row", videoURL: link("bbbbbbbbbbb")))
        }
        let draft = TemplateDraft(name: "Push", exercises: ["Bench", "Row"], setCounts: [3, 3],
                                  videoURLs: ["Bench": link("aaaaaaaaaaa")])

        let review = try TemplatePack.review([draft], in: context)
        // Only the exercise with a new link conflicts; the omitted link is not a change.
        XCTAssertEqual(review.conflicts.count, 1)
        let conflict = try XCTUnwrap(review.conflicts.first)
        XCTAssertTrue(conflict.isLibraryEntry)
        XCTAssertNil(conflict.existing.videoURL)
        XCTAssertEqual(conflict.incoming.videoURL, link("aaaaaaaaaaa"))

        let rejected = try TemplatePack.resolve(review, choices: [conflict.id: .reject])
        XCTAssertEqual(rejected.overrides.count, 0)
        XCTAssertEqual(rejected.additions.count, 0)
        XCTAssertEqual(rejected.drafts[0].videoURLs ?? [:], [:])
        XCTAssertEqual(rejected.drafts[0].exercises, ["Bench", "Row"])

        try TemplatePack.apply(review, choices: [conflict.id: .reject], in: context)
        let library = try context.fetch(FetchDescriptor<LibraryExercise>())
        XCTAssertEqual(library.count, 2)
        XCTAssertNil(library.first { $0.name == "Bench" }?.videoURL)
        // The saved link of the other exercise is not erased by the import.
        XCTAssertEqual(library.first { $0.name == "Row" }?.videoURL, link("bbbbbbbbbbb"))
        let templates = try context.fetch(FetchDescriptor<WorkoutTemplate>())
        XCTAssertEqual(templates.count, 1)
        XCTAssertNil(templates[0].videoURLs)

        // Overriding adds the missing link to the library and to the template.
        let other = try store()
        try other.mainContext.commit {
            other.mainContext.insert(LibraryExercise(name: "Bench", videoURL: nil))
            other.mainContext.insert(LibraryExercise(name: "Row", videoURL: link("bbbbbbbbbbb")))
        }
        let otherReview = try TemplatePack.review([draft], in: other.mainContext)
        try TemplatePack.apply(otherReview, choices: [0: .replace], in: other.mainContext)
        let otherLibrary = try other.mainContext.fetch(FetchDescriptor<LibraryExercise>())
        XCTAssertEqual(otherLibrary.count, 2)
        XCTAssertEqual(otherLibrary.first { $0.name == "Bench" }?.videoURL, link("aaaaaaaaaaa"))
        XCTAssertEqual(otherLibrary.first { $0.name == "Row" }?.videoURL, link("bbbbbbbbbbb"))
        let otherTemplates = try other.mainContext.fetch(FetchDescriptor<WorkoutTemplate>())
        XCTAssertEqual(otherTemplates[0].videoURLs ?? [:], ["Bench": link("aaaaaaaaaaa")])
    }

    // MARK: - The same variant in several templates

    func testRepeatedVariantAcrossTemplatesIsOneConflictAndOneVariation() throws {
        let container = try store()
        let context = container.mainContext
        try context.commit { context.insert(LibraryExercise(name: "Bench", videoURL: link("aaaaaaaaaaa"))) }
        let monday = TemplateDraft(name: "Monday", exercises: ["Bench"], setCounts: [3], videoURLs: ["Bench": link("bbbbbbbbbbb")])
        let friday = TemplateDraft(name: "Friday", exercises: ["Bench"], setCounts: [5], videoURLs: ["Bench": link("bbbbbbbbbbb")])

        let review = try TemplatePack.review([monday, friday], in: context)
        XCTAssertEqual(review.conflicts.count, 1)
        let conflict = try XCTUnwrap(review.conflicts.first)
        XCTAssertTrue(conflict.isLibraryEntry)
        XCTAssertEqual(conflict.existing.videoURL, link("aaaaaaaaaaa"))
        XCTAssertEqual(conflict.incoming.videoURL, link("bbbbbbbbbbb"))
        XCTAssertEqual(conflict.templates, ["Monday", "Friday"])

        let resolution = try TemplatePack.resolve(review, choices: [conflict.id: .keepBoth])
        XCTAssertEqual(resolution.additions.map { $0.name }, ["Bench (variation 1)"])
        XCTAssertEqual(resolution.drafts.map { $0.exercises }, [["Bench (variation 1)"], ["Bench (variation 1)"]])
        XCTAssertEqual(resolution.drafts.map { $0.videoURLs ?? [:] },
                       [["Bench (variation 1)": link("bbbbbbbbbbb")], ["Bench (variation 1)": link("bbbbbbbbbbb")]])

        try TemplatePack.apply(review, choices: [conflict.id: .keepBoth], in: context)
        let library = try context.fetch(FetchDescriptor<LibraryExercise>())
        XCTAssertEqual(library.count, 2)
        XCTAssertEqual(library.first { $0.name == "Bench" }?.videoURL, link("aaaaaaaaaaa"))
        XCTAssertEqual(library.first { $0.name == "Bench (variation 1)" }?.videoURL, link("bbbbbbbbbbb"))
        let templates = try context.fetch(FetchDescriptor<WorkoutTemplate>(sortBy: [SortDescriptor(\.name)]))
        XCTAssertEqual(templates.map { $0.exercises }, [["Bench (variation 1)"], ["Bench (variation 1)"]])
        XCTAssertEqual(templates.map { $0.setCounts ?? [] }, [[5], [3]])
    }

    func testVariantsInsideThePackAreSupportedWithoutALibraryEntry() throws {
        // The decoder accepts a pack that holds two versions of the same exercise.
        let json = """
        {"templates":[
          {"name":"Monday","exercises":[{"name":"Squat","sets":3,"videoURL":"https://youtu.be/aaaaaaaaaaa"}]},
          {"name":"Friday","exercises":[{"name":"Squat","sets":4,"videoURL":"https://youtu.be/bbbbbbbbbbb"}]}
        ]}
        """
        let decoded = try TemplatePack.decode(Data(json.utf8))
        XCTAssertEqual(decoded.map { $0.name }, ["Monday", "Friday"])
        XCTAssertEqual(video(decoded[0], "Squat"), link("aaaaaaaaaaa"))
        XCTAssertEqual(video(decoded[1], "Squat"), link("bbbbbbbbbbb"))

        let container = try store()
        let context = container.mainContext
        let monday = TemplateDraft(name: "Monday", exercises: ["Squat"], setCounts: [3], videoURLs: ["Squat": link("aaaaaaaaaaa")])
        let friday = TemplateDraft(name: "Friday", exercises: ["Squat"], setCounts: [4], videoURLs: ["Squat": link("bbbbbbbbbbb")])

        let review = try TemplatePack.review([monday, friday], in: context)
        XCTAssertEqual(review.library.count, 0)
        XCTAssertEqual(review.conflicts.count, 1)
        let conflict = try XCTUnwrap(review.conflicts.first)
        XCTAssertFalse(conflict.isLibraryEntry)
        XCTAssertEqual(conflict.existing.videoURL, link("aaaaaaaaaaa"))
        XCTAssertEqual(conflict.incoming.videoURL, link("bbbbbbbbbbb"))
        XCTAssertEqual(conflict.templates, ["Friday"])

        let resolution = try TemplatePack.resolve(review, choices: [conflict.id: .keepBoth])
        XCTAssertEqual(resolution.additions.map { $0.name }, ["Squat", "Squat (variation 1)"])
        XCTAssertEqual(resolution.drafts.map { $0.exercises }, [["Squat"], ["Squat (variation 1)"]])
        XCTAssertEqual(resolution.drafts.map { $0.videoURLs ?? [:] },
                       [["Squat": link("aaaaaaaaaaa")], ["Squat (variation 1)": link("bbbbbbbbbbb")]])

        try TemplatePack.apply(review, choices: [conflict.id: .keepBoth], in: context)
        let library = try context.fetch(FetchDescriptor<LibraryExercise>())
        XCTAssertEqual(library.count, 2)
        XCTAssertEqual(library.first { $0.name == "Squat" }?.videoURL, link("aaaaaaaaaaa"))
        XCTAssertEqual(library.first { $0.name == "Squat (variation 1)" }?.videoURL, link("bbbbbbbbbbb"))

        // Rejecting the variant keeps the first definition of the pack.
        let other = try store()
        let otherReview = try TemplatePack.review([monday, friday], in: other.mainContext)
        let otherResolution = try TemplatePack.resolve(otherReview, choices: [0: .reject])
        XCTAssertEqual(otherResolution.additions.map { $0.name }, ["Squat"])
        XCTAssertEqual(otherResolution.drafts.map { $0.exercises }, [["Squat"], ["Squat"]])
        XCTAssertEqual(otherResolution.drafts.map { $0.videoURLs ?? [:] },
                       [["Squat": link("aaaaaaaaaaa")], ["Squat": link("aaaaaaaaaaa")]])
    }

    // MARK: - One override per library entry

    func testOnlyOneIncomingVersionMayOverrideALibraryEntry() throws {
        let container = try store()
        let context = container.mainContext
        try context.commit { context.insert(LibraryExercise(name: "Bench", videoURL: link("aaaaaaaaaaa"))) }
        let monday = TemplateDraft(name: "Monday", exercises: ["Bench"], setCounts: [3], videoURLs: ["Bench": link("bbbbbbbbbbb")])
        let friday = TemplateDraft(name: "Friday", exercises: ["Bench"], setCounts: [4], videoURLs: ["Bench": link("ccccccccccc")])

        let review = try TemplatePack.review([monday, friday], in: context)
        XCTAssertEqual(review.conflicts.count, 2)
        XCTAssertEqual(review.conflicts.map { $0.existing.name }, ["Bench", "Bench"])

        XCTAssertThrowsError(try TemplatePack.resolve(review, choices: [0: .replace, 1: .replace])) { error in
            XCTAssertTrue(reviewMessage(error).contains("Only one incoming version"), reviewMessage(error))
        }
        XCTAssertThrowsError(try TemplatePack.apply(review, choices: [0: .replace, 1: .replace], in: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkoutTemplate>()), 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LibraryExercise>()).first?.videoURL, link("aaaaaaaaaaa"))

        // One override together with one variation is allowed.
        try TemplatePack.apply(review, choices: [0: .replace, 1: .keepBoth], in: context)
        let library = try context.fetch(FetchDescriptor<LibraryExercise>())
        XCTAssertEqual(library.count, 2)
        XCTAssertEqual(library.first { $0.name == "Bench" }?.videoURL, link("bbbbbbbbbbb"))
        XCTAssertEqual(library.first { $0.name == "Bench (variation 1)" }?.videoURL, link("ccccccccccc"))
        let templates = try context.fetch(FetchDescriptor<WorkoutTemplate>())
        XCTAssertEqual(templates.count, 2)
    }

    // MARK: - Incomplete answers and cancellations

    func testDuplicateSavedNamesProduceAnErrorInsteadOfCrashing() throws {
        let container = try store()
        let context = container.mainContext
        try context.commit {
            context.insert(LibraryExercise(name: "Bench"))
            context.insert(LibraryExercise(name: "BENCH"))
        }
        let draft = TemplateDraft(name: "Push", exercises: ["Bench"], setCounts: [3])
        XCTAssertThrowsError(try TemplatePack.review([draft], in: context)) { error in
            XCTAssertTrue(reviewMessage(error).contains("duplicate exercise names"))
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LibraryExercise>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkoutTemplate>()), 0)
    }

    func testMissingChoiceIsRejectedAndNothingIsImported() throws {
        let container = try store()
        let context = container.mainContext
        let drafts = try userDrafts()
        try seedLibrary(drafts, in: context)
        let review = try TemplatePack.review(drafts, in: context)

        XCTAssertThrowsError(try TemplatePack.resolve(review, choices: [:])) { error in
            XCTAssertTrue(reviewMessage(error).contains("choose Reject incoming change"), reviewMessage(error))
        }
        XCTAssertThrowsError(try TemplatePack.resolve(review, choices: [0: .replace])) { error in
            XCTAssertTrue(reviewMessage(error).contains("Nothing was imported"), reviewMessage(error))
        }
        XCTAssertThrowsError(try TemplatePack.apply(review, choices: [:], in: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkoutTemplate>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LibraryExercise>()), 21)
    }

    func testReviewAndResolveDoNotChangeAnything() throws {
        let container = try store()
        let context = container.mainContext
        let drafts = try userDrafts()
        try seedLibrary(drafts, in: context)
        let review = try TemplatePack.review(drafts, in: context)
        _ = try TemplatePack.resolve(review, choices: replaceAll(review))

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkoutTemplate>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LibraryExercise>()), 21)
        XCTAssertFalse(context.hasChanges)
        let library = try context.fetch(FetchDescriptor<LibraryExercise>())
        XCTAssertEqual(library.filter { ($0.videoURL ?? "").contains("&t=") }.count, 0)
    }

    func testStaleLibraryChangesRejectTheImportWithoutPartialWrites() throws {
        // The saved link of an exercise is edited after the comparison.
        try assertStaleImportIsRejected(expectedLibraryCount: 21) { context in
            let entry = try XCTUnwrap(context.fetch(FetchDescriptor<LibraryExercise>()).first { $0.name == "Back Squat" })
            entry.videoURL = "https://www.youtube.com/watch?v=aaaaaaaaaaa"
            try context.save()
        }
        // A new exercise is added after the comparison.
        try assertStaleImportIsRejected(expectedLibraryCount: 22) { context in
            context.insert(LibraryExercise(name: "New move", videoURL: nil))
            try context.save()
        }
        // An exercise is deleted after the comparison.
        try assertStaleImportIsRejected(expectedLibraryCount: 20) { context in
            let entry = try XCTUnwrap(context.fetch(FetchDescriptor<LibraryExercise>()).first { $0.name == "Back Squat" })
            context.delete(entry)
            try context.save()
        }
    }

    private func assertStaleImportIsRejected(expectedLibraryCount: Int, _ mutate: (ModelContext) throws -> Void) throws {
        let container = try store()
        let context = container.mainContext
        let drafts = try userDrafts()
        try seedLibrary(drafts, in: context)
        let review = try TemplatePack.review(drafts, in: context)
        let choices = replaceAll(review)

        try mutate(context)

        XCTAssertThrowsError(try TemplatePack.apply(review, choices: choices, in: context)) { error in
            XCTAssertTrue(reviewMessage(error).contains("library changed"), reviewMessage(error))
        }
        // Nothing was imported and the change that made the comparison stale is kept.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkoutTemplate>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LibraryExercise>()), expectedLibraryCount)
    }

    // MARK: - Names of the variations

    func testKeepBothAvoidsCollidingSuffixesAndReservedNames() throws {
        // The library already holds a variation with the same name in another case.
        let first = try store()
        try first.mainContext.commit {
            first.mainContext.insert(LibraryExercise(name: "Bench", videoURL: link("aaaaaaaaaaa")))
            first.mainContext.insert(LibraryExercise(name: "Bench (VARIATION 1)", videoURL: link("ccccccccccc")))
        }
        let firstDraft = TemplateDraft(name: "Push", exercises: ["Bench"], setCounts: [3], videoURLs: ["Bench": link("bbbbbbbbbbb")])
        let firstReview = try TemplatePack.review([firstDraft], in: first.mainContext)
        XCTAssertEqual(firstReview.conflicts.count, 1)
        let firstResolution = try TemplatePack.resolve(firstReview, choices: [0: .keepBoth])
        XCTAssertEqual(firstResolution.additions.map { $0.name }, ["Bench (variation 2)"])
        XCTAssertEqual(firstResolution.additions.first?.videoURL, link("bbbbbbbbbbb"))
        XCTAssertEqual(firstResolution.drafts[0].exercises, ["Bench (variation 2)"])

        // The name of the variation is reserved by an exercise of the pack.
        let second = try store()
        try second.mainContext.commit { second.mainContext.insert(LibraryExercise(name: "Bench", videoURL: link("aaaaaaaaaaa"))) }
        let secondDraft = TemplateDraft(name: "Push", exercises: ["Bench", "Bench (variation 1)"], setCounts: [3, 3],
                                        videoURLs: ["Bench": link("bbbbbbbbbbb")])
        let secondReview = try TemplatePack.review([secondDraft], in: second.mainContext)
        XCTAssertEqual(secondReview.conflicts.count, 1)
        let secondResolution = try TemplatePack.resolve(secondReview, choices: [0: .keepBoth])
        XCTAssertEqual(secondResolution.additions.map { $0.name }, ["Bench (variation 1)", "Bench (variation 2)"])
        XCTAssertEqual(secondResolution.additions.last?.videoURL, link("bbbbbbbbbbb"))
        XCTAssertEqual(secondResolution.drafts[0].exercises, ["Bench (variation 2)", "Bench (variation 1)"])
    }

    // MARK: - Saving

    func testReadOnlyStoreRollsBackTheImportAndKeepsTheSavedFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutLog-import-readonly-\(UUID()).store")
        do {
            let target = try store(url: url)
            try target.mainContext.commit {
                target.mainContext.insert(LibraryExercise(name: "Bench", videoURL: link("aaaaaaaaaaa")))
                target.mainContext.insert(LibraryExercise(name: "Row", videoURL: nil))
            }
        }
        let schema = Schema([WorkoutTemplate.self, WorkoutSession.self, LibraryExercise.self, LibrarySetup.self, CalendarRule.self, WalkingCompletion.self])
        let config = ModelConfiguration(schema: schema, url: url, allowsSave: false, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        context.autosaveEnabled = false

        // One override for "Bench" and one new exercise "Squat".
        let draft = TemplateDraft(name: "Push", exercises: ["Bench", "Squat"], setCounts: [3, 3],
                                  videoURLs: ["Bench": link("bbbbbbbbbbb"), "Squat": link("ccccccccccc")])
        let review = try TemplatePack.review([draft], in: context)
        XCTAssertEqual(review.conflicts.count, 1)
        let pending = TemplateImportState()
        pending.text = "original JSON"
        pending.drafts = [draft]
        pending.review = review
        pending.choices = [0: .replace]
        XCTAssertThrowsError(try TemplatePack.apply(review, choices: pending.choices, in: context))
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(pending.text, "original JSON")
        XCTAssertEqual(pending.review?.conflicts.count, 1)
        XCTAssertEqual(pending.choices, [0: .replace])
        XCTAssertTrue(pending.hasPending)
        pending.reset()
        XCTAssertFalse(pending.hasPending)
        XCTAssertTrue(pending.choices.isEmpty)

        // The file on disk still holds the state from before the import.
        let reopened = try store(url: url)
        let library = try reopened.mainContext.fetch(FetchDescriptor<LibraryExercise>())
        XCTAssertEqual(library.count, 2)
        XCTAssertEqual(library.first { $0.name == "Bench" }?.videoURL, link("aaaaaaaaaaa"))
        XCTAssertNil(library.first { $0.name == "Row" }?.videoURL)
        XCTAssertFalse(library.contains { $0.name == "Squat" })
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<WorkoutTemplate>()), 0)
    }

    func testImportedDataSurvivesReopenAndBackupRoundtrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutLog-import-\(UUID()).store")
        let drafts = try userDrafts()
        do {
            let target = try store(url: url)
            let context = target.mainContext
            try seedLibrary(drafts, in: context)
            let review = try TemplatePack.review(drafts, in: context)
            try TemplatePack.apply(review, choices: replaceAll(review), in: context)
        }

        let reopened = try store(url: url)
        let context = reopened.mainContext
        let templates = try context.fetch(FetchDescriptor<WorkoutTemplate>(sortBy: [SortDescriptor(\.name)]))
        XCTAssertEqual(templates.map { $0.name }, ["Friday", "Monday", "Wednesday"])
        for template in templates {
            let original = try XCTUnwrap(drafts.first { $0.name == template.name })
            XCTAssertEqual(template.exercises, original.exercises)
            XCTAssertEqual(template.setCounts ?? [], original.setCounts)
            XCTAssertEqual(template.videoURLs ?? [:], original.videoURLs ?? [:])
        }
        let library = try context.fetch(FetchDescriptor<LibraryExercise>())
        XCTAssertEqual(library.count, 21)
        for draft in drafts {
            for name in draft.exercises {
                XCTAssertEqual(library.first { $0.name == name }?.videoURL, video(draft, name), name)
            }
        }

        let backup = try DataTransfer.snapshot(in: context, unit: .kg)
        let decoded = try DataTransfer.decode(DataTransfer.encode(backup))
        XCTAssertEqual(decoded, backup)
        XCTAssertEqual(decoded.templates.count, 3)
        XCTAssertEqual(decoded.libraryExercises?.count, 21)
    }
}
