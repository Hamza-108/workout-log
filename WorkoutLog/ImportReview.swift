import Foundation
import Observation
import SwiftData

// Value-only import drafts survive the app's replacement context after a failed save.
@Observable
final class TemplateImportState {
    var drafts: [TemplateDraft]?
    var review: TemplatePack.Review?
    var text = ""
    var choices: [Int: TemplatePack.Choice] = [:]
    var hasPending: Bool { drafts != nil || review != nil || !text.isEmpty }

    func reset() { drafts = nil; review = nil; text = ""; choices = [:] }
}

extension TemplatePack {
    struct Definition: Equatable {
        var name: String
        var videoURL: String?
        var key: String { name.lowercased() }
    }

    enum Choice: String, CaseIterable, Hashable {
        case reject, replace, keepBoth
        var title: String {
            switch self {
            case .reject: "Reject incoming change"
            case .replace: "Override"
            case .keepBoth: "Keep both"
            }
        }
    }

    struct Conflict: Identifiable {
        let id: Int
        let existing: Definition
        let incoming: Definition
        let isLibraryEntry: Bool
        var templates: [String]
    }

    struct Review {
        let drafts: [TemplateDraft]
        let library: [DataTransfer.Exercise]
        let bases: [String: Definition]
        let conflicts: [Conflict]
    }

    struct Resolution {
        let drafts: [TemplateDraft]
        let additions: [Definition]
        let overrides: [UUID: Definition]
    }

    private struct Variant: Hashable {
        let name: String
        let video: String
    }

    private static func librarySnapshot(_ entries: [LibraryExercise]) throws -> [DataTransfer.Exercise] {
        guard Set(entries.map { $0.name.lowercased() }).count == entries.count else {
            throw LogError(message: "The library contains duplicate exercise names. Rename or remove the duplicate entries before importing. Nothing was imported.")
        }
        return entries.map(DataTransfer.Exercise.init).sorted { $0.id.uuidString < $1.id.uuidString }
    }

    static func review(_ drafts: [TemplateDraft], in context: ModelContext) throws -> Review {
        try validate(drafts)
        let library = try librarySnapshot(context.fetch(FetchDescriptor<LibraryExercise>()))
        let saved = Dictionary(uniqueKeysWithValues: library.map { ($0.name.lowercased(), Definition(name: $0.name, videoURL: $0.videoURL)) })
        var bases: [String: Definition] = [:]
        for draft in drafts {
            for name in draft.exercises {
                let incoming = Definition(name: name, videoURL: draft.videoURLs?[name])
                if let existing = saved[incoming.key] { bases[incoming.key] = existing }
                else if let base = bases[incoming.key] {
                    // An omitted video stays omitted in its template, but doesn't hide an explicit library definition.
                    if base.videoURL == nil, incoming.videoURL != nil {
                        bases[incoming.key] = Definition(name: base.name, videoURL: incoming.videoURL)
                    }
                } else { bases[incoming.key] = incoming }
            }
        }
        var conflicts: [Conflict] = []
        var variants: [Variant: Int] = [:]
        for draft in drafts {
            for name in draft.exercises {
                guard let video = draft.videoURLs?[name], let base = bases[name.lowercased()], base.videoURL != video else { continue }
                let variant = Variant(name: name.lowercased(), video: video)
                if let index = variants[variant] {
                    if !conflicts[index].templates.contains(draft.name) { conflicts[index].templates.append(draft.name) }
                } else {
                    variants[variant] = conflicts.count
                    conflicts.append(Conflict(id: conflicts.count, existing: base,
                                              incoming: Definition(name: name, videoURL: video),
                                              isLibraryEntry: saved[base.key] != nil, templates: [draft.name]))
                }
            }
        }
        return Review(drafts: drafts, library: library, bases: bases, conflicts: conflicts)
    }

    static func resolve(_ review: Review, choices: [Int: Choice]) throws -> Resolution {
        guard Set(choices.keys) == Set(review.conflicts.map(\.id)) else {
            throw LogError(message: "Compare the different video links and choose Reject incoming change, Override or Keep both for every conflict. Nothing was imported.")
        }
        let saved = Dictionary(uniqueKeysWithValues: review.library.map { ($0.name.lowercased(), $0) })
        var additions = review.bases.filter { saved[$0.key] == nil }
        var overrides: [UUID: Definition] = [:]
        var substitutions: [Variant: Definition] = [:]
        var replaced: Set<String> = []
        var reserved = Set(review.library.map { $0.name.lowercased() } + review.drafts.flatMap { $0.exercises.map { $0.lowercased() } })
        for conflict in review.conflicts {
            let base = conflict.existing
            let variant = Variant(name: conflict.incoming.key, video: conflict.incoming.videoURL!)
            switch choices[conflict.id]! {
            case .reject:
                substitutions[variant] = base
            case .replace:
                guard replaced.insert(base.key).inserted else {
                    throw LogError(message: "Only one incoming version of \(base.name) can override its library entry. Reject or keep both for the other versions.")
                }
                let definition = Definition(name: base.name, videoURL: conflict.incoming.videoURL)
                substitutions[variant] = definition
                if let existing = saved[base.key] { overrides[existing.id] = definition }
                else { additions[base.key] = definition }
            case .keepBoth:
                var number = 1
                var name = "\(base.name) (variation \(number))"
                while !reserved.insert(name.lowercased()).inserted {
                    number += 1
                    name = "\(base.name) (variation \(number))"
                }
                let definition = Definition(name: name, videoURL: conflict.incoming.videoURL)
                additions[definition.key] = definition
                substitutions[variant] = definition
            }
        }
        let drafts = review.drafts.map { draft in
            var names: [String] = []
            var videos: [String: String] = [:]
            for name in draft.exercises {
                let video = draft.videoURLs?[name]
                let replacement = video.flatMap { substitutions[Variant(name: name.lowercased(), video: $0)] }
                let definition = replacement ?? Definition(name: name, videoURL: video)
                names.append(definition.name)
                if let link = definition.videoURL { videos[definition.name] = link }
            }
            return TemplateDraft(name: draft.name, exercises: names, setCounts: draft.setCounts, videoURLs: videos.isEmpty ? nil : videos)
        }
        try validate(drafts)
        return Resolution(drafts: drafts, additions: additions.values.sorted { $0.key < $1.key }, overrides: overrides)
    }

    static func apply(_ review: Review, choices: [Int: Choice], in context: ModelContext) throws {
        let entries = try context.fetch(FetchDescriptor<LibraryExercise>())
        guard try librarySnapshot(entries) == review.library else {
            throw LogError(message: "The exercise library changed after this comparison. Refresh comparisons and choose again. Nothing was imported.")
        }
        let result = try resolve(review, choices: choices)
        try context.commit {
            for entry in entries {
                if let definition = result.overrides[entry.id] { entry.videoURL = definition.videoURL }
            }
            for definition in result.additions { context.insert(LibraryExercise(name: definition.name, videoURL: definition.videoURL)) }
            for draft in result.drafts {
                context.insert(WorkoutTemplate(name: draft.name, exercises: draft.exercises, setCounts: draft.setCounts, videoURLs: draft.videoURLs))
            }
        }
    }
}
