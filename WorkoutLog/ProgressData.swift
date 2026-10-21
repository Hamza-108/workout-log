import Foundation
import SwiftData

extension WeightUnit {
    func convert(_ value: Double, to target: WeightUnit) -> Double? {
        let converted = self == target ? value : (self == .lb ? value * 0.45359237 : value / 0.45359237)
        return converted.isFinite ? converted : nil
    }
}

enum ProgressRange: String, CaseIterable, Hashable {
    case month = "1M", threeMonths = "3M", sixMonths = "6M", all = "All"

    func start(now: Date = Date(), calendar: Calendar = Schedule.calendar()) -> Date? {
        let months: Int
        switch self {
        case .month: months = 1
        case .threeMonths: months = 3
        case .sixMonths: months = 6
        case .all: return nil
        }
        return calendar.date(byAdding: .month, value: -months, to: now).map { calendar.startOfDay(for: $0) }
    }
}

enum ProgressData {
    struct LiftPoint: Identifiable {
        let id: UUID
        let date: Date
        let weight: Double
        let reps: Int
        let rpe: Double
        let originalWeight: Double
        let originalUnit: WeightUnit
    }

    static func key(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    static func previousSession(exercise: String, before: Date, sessions: [WorkoutSession]) -> WorkoutSession? {
        sessions.filter { session in
            guard let finish = session.finishedAt, finish < before else { return false }
            return session.sets.contains { key($0.exercise) == key(exercise) }
        }.max {
            if $0.finishedAt == $1.finishedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.finishedAt! < $1.finishedAt!
        }
    }

    static func previousSet(row: PlannedSet, current: WorkoutSession, previous: WorkoutSession) -> LoggedSet? {
        guard let number = current.ordinal(for: row),
              let exercise = previous.exercises.first(where: { key($0) == key(row.exercise) }) else { return nil }
        let rows = previous.rows(for: exercise).filter { $0.effectiveKind == row.effectiveKind }
        guard rows.indices.contains(number - 1) else { return nil }
        return previous.sets.first { $0.id == rows[number - 1].id }
    }

    static func exercises(sessions: [WorkoutSession]) -> [String] {
        var names: [String: String] = [:]
        for session in sessions where session.finishedAt != nil {
            for set in session.sets where set.effectiveKind == .working {
                let normalized = key(set.exercise)
                names[normalized] = min(names[normalized] ?? set.exercise, set.exercise)
            }
        }
        return names.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func lifting(exercise: String, sessions: [WorkoutSession], unit: WeightUnit,
                        range: ProgressRange = .all, now: Date = Date(), calendar: Calendar = Schedule.calendar()) -> [LiftPoint] {
        let start = range.start(now: now, calendar: calendar)
        return sessions.compactMap { session -> LiftPoint? in
            guard let date = session.finishedAt, start.map({ date >= $0 }) ?? true,
                  let originalUnit = WeightUnit(rawValue: session.unit) else { return nil }
            // Rows, not log-entry order, make equal-weight selection deterministic.
            let ordered = session.exercises.flatMap { exercise in
                session.rows(for: exercise).compactMap { row in session.sets.first { $0.id == row.id } }
            }
            let sets = ordered.filter { key($0.exercise) == key(exercise) && $0.effectiveKind == .working }
            guard let best = sets.max(by: { $0.weight < $1.weight }),
                  let weight = originalUnit.convert(best.weight, to: unit) else { return nil }
            return LiftPoint(id: session.id, date: date, weight: weight, reps: best.reps, rpe: best.rpe,
                             originalWeight: best.weight, originalUnit: originalUnit)
        }.sorted {
            $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date
        }
    }
}

@Model
final class BodyWeightEntry {
    var id: UUID
    var day: String
    var weight: Double
    var unit: String

    init(day: String, weight: Double, unit: WeightUnit) {
        id = UUID()
        self.day = day
        self.weight = weight
        self.unit = unit.rawValue
    }

    static func validate(day: String, weight: Double, unit: String) throws {
        guard Schedule.validDay(day), WeightUnit(rawValue: unit) != nil,
              weight.isFinite, weight > 0 else {
            throw LogError(message: "Enter a valid date, kg or lb, and a finite body weight greater than zero.")
        }
    }

    @discardableResult
    static func save(day: String, weight: Double, unit: WeightUnit, existingID: UUID? = nil,
                     in context: ModelContext, now: Date = Date(), calendar: Calendar = Schedule.calendar()) throws -> BodyWeightEntry {
        try validate(day: day, weight: weight, unit: unit.rawValue)
        guard day <= Schedule.day(now, calendar: calendar) else { throw LogError(message: "Weigh-ins must be today or earlier.") }
        let entries = try context.fetch(FetchDescriptor<BodyWeightEntry>())
        guard !entries.contains(where: { $0.day == day && $0.id != existingID }) else {
            throw LogError(message: "A weigh-in already exists on that day. Open that entry to update it.")
        }
        let existing = existingID.flatMap { id in entries.first { $0.id == id } }
        guard existingID == nil || existing != nil else { throw LogError(message: "This weigh-in is no longer available. Reopen the tracker and try again.") }
        let entry = existing ?? BodyWeightEntry(day: day, weight: weight, unit: unit)
        try context.commit {
            if existing == nil { context.insert(entry) }
            entry.day = day
            entry.weight = weight
            entry.unit = unit.rawValue
        }
        return entry
    }
}
