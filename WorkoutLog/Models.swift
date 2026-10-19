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

struct LoggedSet: Codable, Identifiable, Equatable {
    var id = UUID()
    var exercise: String
    var weight: Double
    var reps: Int
    var rpe: Double

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

@Model
final class WorkoutTemplate {
    var id: UUID
    var name: String
    var exercises: [String]

    init(name: String, exercises: [String]) {
        id = UUID()
        self.name = name
        self.exercises = exercises
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
        let session = WorkoutSession(templateName: name, exercises: exercises, unit: unit)
        try context.commit { context.insert(session) }
        return session
    }

    func record(_ set: LoggedSet) throws {
        guard finishedAt == nil else { throw LogError(message: "This workout is already finished.") }
        try set.validate()
        guard exercises.contains(set.exercise) else { throw LogError(message: "This exercise is not in the workout.") }
        if let index = sets.firstIndex(where: { $0.id == set.id }) {
            sets[index] = set
        } else {
            sets.append(set)
        }
    }

    func finish() throws {
        guard finishedAt == nil else { throw LogError(message: "This workout is already finished.") }
        guard !sets.isEmpty else { throw LogError(message: "Log at least one set before finishing.") }
        for set in sets { try set.validate() }
        finishedAt = Date()
    }
}

extension ModelContext {
    // Explicit saves and rollback keep a failed change from looking successful or autosaving later.
    func commit(_ change: () throws -> Void) throws {
        do {
            try change()
            try save()
        } catch {
            processPendingChanges()
            rollback()
            throw error
        }
    }
}
