import Foundation
import SwiftData

struct LogError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum WeightUnit: String, CaseIterable, Codable, Hashable {
    case kg, lb
}

enum WeightInput {
    static func format(_ value: Double, locale: Locale = .current) -> String {
        value.formatted(.number.grouping(.never).precision(.significantDigits(1...17)).locale(locale))
    }

    static func parse(_ text: String, locale: Locale = .current) throws -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = locale.decimalSeparator ?? "."
        let parts = trimmed.components(separatedBy: separator)
        let digits = CharacterSet(charactersIn: "0123456789")
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(digits.contains) }),
              let value = Double(parts.joined(separator: ".")), value.isFinite, value >= 0 else {
            throw LogError(message: "Enter a weight of zero or more, using \(separator) for decimals (for example 20\(separator)5).")
        }
        return value
    }
}

enum SetKind: String, Codable, CaseIterable, Hashable {
    case working, warmup
    var title: String { self == .working ? "Working" : "Warm-up" }
    func label(_ number: Int) -> String { self == .working ? "Set \(number)" : "Warm-up \(number)" }
}

struct LoggedSet: Codable, Identifiable, Equatable {
    var id = UUID()
    var exercise: String
    var weight: Double
    var reps: Int
    var rpe: Double
    var kind: SetKind? = nil
    var effectiveKind: SetKind { kind ?? .working }

    func validate() throws {
        guard weight.isFinite, weight >= 0 else {
            throw LogError(message: "Weight must be a finite number of zero or more.")
        }
        guard reps > 0 else { throw LogError(message: "Reps must be a positive whole number.") }
        guard rpe.isFinite, (0...10).contains(rpe) else {
            throw LogError(message: "Exertion must be between 0 and 10.")
        }
    }
}

struct PlannedSet: Codable, Identifiable, Equatable {
    var id = UUID()
    var exercise: String
    var kind: SetKind? = nil
    var effectiveKind: SetKind { kind ?? .working }
}

@Model
final class LibraryExercise {
    var id: UUID
    var name: String
    var videoURL: String?

    init(name: String, videoURL: String? = nil) {
        id = UUID()
        self.name = name
        self.videoURL = videoURL
    }

    static func validated(name: String, videoURL: String?) throws -> (String, String?) {
        let (name, _) = try WorkoutTemplate.validated(name: name, exercises: [name])
        return (name, try VideoLink.normalized(videoURL))
    }

    static func checkUnique(_ name: String, excluding id: UUID? = nil, in context: ModelContext) throws {
        let saved = try context.fetch(FetchDescriptor<LibraryExercise>())
        guard !saved.contains(where: { $0.id != id && $0.name.lowercased() == name.lowercased() }) else {
            throw LogError(message: "An exercise with this name is already in the library.")
        }
    }

    // Keep the setup marker so clearing does not reseed entries from templates on launch.
    static func clear(in context: ModelContext, expectedIDs: Set<UUID>) throws {
        let saved = try context.fetch(FetchDescriptor<LibraryExercise>())
        let currentIDs = Set(saved.map(\.id))
        guard currentIDs == expectedIDs else {
            throw LogError(message: "The exercise library changed since you confirmed. Check the current list and confirm clearing again.")
        }
        guard !saved.isEmpty else { return }
        try context.commit {
            for exercise in saved { context.delete(exercise) }
        }
    }

    static func seedOnce(in context: ModelContext) throws {
        guard try context.fetchCount(FetchDescriptor<LibrarySetup>()) == 0 else { return }
        let templates = try context.fetch(FetchDescriptor<WorkoutTemplate>(sortBy: [SortDescriptor(\.name)]))
        var names = Set(try context.fetch(FetchDescriptor<LibraryExercise>()).map { $0.name.lowercased() })
        var additions: [LibraryExercise] = []
        for template in templates {
            for name in template.exercises where names.insert(name.lowercased()).inserted {
                additions.append(LibraryExercise(name: name, videoURL: template.videoURLs?[name]))
            }
        }
        try context.commit {
            for exercise in additions { context.insert(exercise) }
            context.insert(LibrarySetup())
        }
    }
}

// A store-local marker prevents deleted library entries reappearing on launch.
@Model
final class LibrarySetup {
    var complete: Bool
    init() { complete = true }
}

@Model
final class WorkoutTemplate {
    var id: UUID
    var name: String
    var exercises: [String]
    var setCounts: [Int]?
    var videoURLs: [String: String]?

    init(name: String, exercises: [String], setCounts: [Int]? = nil, videoURLs: [String: String]? = nil) {
        id = UUID()
        self.name = name
        self.exercises = exercises
        self.setCounts = setCounts
        self.videoURLs = videoURLs
    }

    static func validateSetCounts(_ counts: [Int]?, exercises: [String]) throws {
        if let counts {
            guard counts.count == exercises.count, counts.allSatisfy({ (1...99).contains($0) }) else {
                throw LogError(message: "Choose 1–99 sets for each exercise.")
            }
        }
    }

    static func validated(name: String, exercises: [String]) throws -> (String, [String]) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let exercises = exercises.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !name.isEmpty else { throw LogError(message: "Give the template a name.") }
        guard !exercises.isEmpty, exercises.allSatisfy({ !$0.isEmpty }) else {
            throw LogError(message: "Add at least one exercise and name every exercise.")
        }
        guard Set(exercises.map { $0.lowercased() }).count == exercises.count else {
            throw LogError(message: "Use each exercise name only once in a template.")
        }
        return (name, exercises)
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

    init(templateName: String, exercises: [String], unit: WeightUnit) {
        id = UUID()
        startedAt = Date()
        self.templateName = templateName
        self.exercises = exercises
        self.unit = unit.rawValue
        sets = []
    }

    static func start(template: WorkoutTemplate, unit: WeightUnit, in context: ModelContext) throws -> WorkoutSession {
        let drafts = try context.fetch(FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.finishedAt == nil }))
        guard drafts.isEmpty else { throw LogError(message: "Resume or discard your current workout before starting another.") }
        let (name, exercises) = try WorkoutTemplate.validated(name: template.name, exercises: template.exercises)
        try WorkoutTemplate.validateSetCounts(template.setCounts, exercises: exercises)
        try VideoLink.validate(template.videoURLs, exercises: exercises)
        let session = WorkoutSession(templateName: name, exercises: exercises, unit: unit)
        session.videoURLs = template.videoURLs
        session.sourceTemplateID = template.id
        if let counts = template.setCounts {
            session.plannedSets = zip(exercises, counts).flatMap { exercise, count in
                (0..<count).map { _ in PlannedSet(exercise: exercise) }
            }
        }
        try context.commit { context.insert(session) }
        return session
    }

    func record(_ set: LoggedSet) throws {
        guard finishedAt == nil else { throw LogError(message: "This workout is already finished.") }
        try set.validate()
        guard exercises.contains(set.exercise) else { throw LogError(message: "This exercise is not in the workout.") }
        if let slot = plannedSets?.first(where: { $0.id == set.id }), slot.exercise != set.exercise {
            throw LogError(message: "This set belongs to a different exercise.")
        }
        if set.effectiveKind == .warmup, plannedSets == nil {
            plannedSets = exercises.flatMap { rows(for: $0) }
        }
        if let index = plannedSets?.firstIndex(where: { $0.id == set.id }) {
            plannedSets?[index].kind = set.kind
        } else if plannedSets != nil {
            let row = PlannedSet(id: set.id, exercise: set.exercise, kind: set.kind)
            if set.effectiveKind == .warmup,
               let index = plannedSets?.firstIndex(where: { $0.exercise == set.exercise && $0.effectiveKind == .working }) {
                plannedSets?.insert(row, at: index)
            } else { plannedSets?.append(row) }
        }
        if let index = sets.firstIndex(where: { $0.id == set.id }) {
            sets[index] = set
        } else {
            sets.append(set)
        }
    }

    func rows(for exercise: String) -> [PlannedSet] {
        let planned = plannedSets ?? []
        let ids = Set(planned.map(\.id))
        return planned.filter { $0.exercise == exercise } + sets.filter {
            $0.exercise == exercise && !ids.contains($0.id)
        }.map { PlannedSet(id: $0.id, exercise: $0.exercise, kind: $0.kind) }
    }

    func ordinal(for row: PlannedSet) -> Int? {
        rows(for: row.exercise).filter { $0.effectiveKind == row.effectiveKind }
            .firstIndex(where: { $0.id == row.id }).map { $0 + 1 }
    }

    func classify(_ id: UUID, as kind: SetKind) throws {
        guard finishedAt == nil else { throw LogError(message: "This workout is already finished.") }
        guard plannedSets?.contains(where: { $0.id == id }) == true || sets.contains(where: { $0.id == id }) else {
            throw LogError(message: "This set is no longer available.")
        }
        if let index = plannedSets?.firstIndex(where: { $0.id == id }) { plannedSets?[index].kind = kind }
        if let index = sets.firstIndex(where: { $0.id == id }) { sets[index].kind = kind }
    }

    var setSummary: String {
        let warmups = sets.filter { $0.effectiveKind == .warmup }.count
        return "\(sets.count - warmups) working · \(warmups) warm-up sets"
    }

    func removeSet(_ id: UUID) throws {
        guard finishedAt == nil else { throw LogError(message: "This workout is already finished.") }
        sets.removeAll { $0.id == id }
        plannedSets?.removeAll { $0.id == id }
    }

    func finish(at date: Date = Date(), calendar: Calendar = Schedule.calendar()) throws {
        guard finishedAt == nil else { throw LogError(message: "This workout is already finished.") }
        guard !sets.isEmpty else { throw LogError(message: "Log at least one set before finishing.") }
        for set in sets { try set.validate() }
        finishedAt = date
        completedDay = Schedule.day(date, calendar: calendar)
    }
}

extension Notification.Name {
    static let workoutSaveFailed = Notification.Name("workoutSaveFailed")
}

extension ModelContext {
    // SwiftData rollback can leave stale model values; the UI must discard this context on failure.
    func commit(_ change: () throws -> Void) throws {
        do {
            try change()
            try save()
        } catch {
            rollback()
            NotificationCenter.default.post(name: .workoutSaveFailed, object: self, userInfo: ["error": error.localizedDescription])
            throw error
        }
    }
}
