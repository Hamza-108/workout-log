import Foundation

struct PersonalRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String { ProgressData.key(exercise) }
    var exercise: String
    var weight: Double
    var reps: Int
    var rpe: Double
    var unit: WeightUnit
    var achievedAt: Date

    func convertedWeight(to target: WeightUnit) -> Double? {
        unit.convert(weight, to: target)
    }
}

struct StreakSummary: Codable, Equatable, Sendable {
    var currentStreak: Int
    var bestStreak: Int
    var adherencePercent: Int
    var completedLast30Days: Int
    var assignedLast30Days: Int
}

enum StreakCalculator {
    static let maxRestBridgeDays = 6
    static let adherenceWindowDays = 30
    private static let maxLookbackDays = 3650

    static func summary(
        rules: [CalendarRule],
        sessions: [WorkoutSession],
        walks: [WalkingCompletion],
        today: String? = nil,
        now: Date = Date(),
        calendar: Calendar = Schedule.calendar()
    ) -> StreakSummary {
        let todayKey = (today.flatMap { Schedule.validDay($0) ? $0 : nil }) ?? Schedule.day(now, calendar: calendar)
        guard let todayNoon = Schedule.date(todayKey, calendar: calendar) else {
            return StreakSummary(currentStreak: 0, bestStreak: 0, adherencePercent: 0, completedLast30Days: 0, assignedLast30Days: 0)
        }

        let adherenceCounts = computeAdherence(
            todayNoon: todayNoon,
            todayKey: todayKey,
            rules: rules,
            sessions: sessions,
            walks: walks,
            calendar: calendar
        )
        let streaks = computeStreaks(
            todayNoon: todayNoon,
            todayKey: todayKey,
            rules: rules,
            sessions: sessions,
            walks: walks,
            calendar: calendar
        )

        let percent = adherenceCounts.assigned > 0
            ? Int((Double(adherenceCounts.completed) / Double(adherenceCounts.assigned) * 100.0).rounded())
            : 0

        return StreakSummary(
            currentStreak: streaks.current,
            bestStreak: streaks.best,
            adherencePercent: percent,
            completedLast30Days: adherenceCounts.completed,
            assignedLast30Days: adherenceCounts.assigned
        )
    }

    static func personalRecords(sessions: [WorkoutSession]) -> [PersonalRecord] {
        let names = ProgressData.exercises(sessions: sessions)
        return names.compactMap { exerciseName in
            bestRecord(for: exerciseName, in: sessions)
        }
    }

    // MARK: - Internal Helpers

    private static func computeAdherence(
        todayNoon: Date,
        todayKey: String,
        rules: [CalendarRule],
        sessions: [WorkoutSession],
        walks: [WalkingCompletion],
        calendar: Calendar
    ) -> (completed: Int, assigned: Int) {
        var completed = 0
        var assigned = 0
        for offset in -(adherenceWindowDays - 1)...0 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: todayNoon) else { continue }
            let dayKey = Schedule.day(date, calendar: calendar)
            let status = Schedule.status(on: dayKey, rules: rules, sessions: sessions, walks: walks)
            switch status {
            case .completed:
                assigned += 1
                completed += 1
            case .pending:
                if dayKey < todayKey {
                    assigned += 1
                }
            case .unassigned:
                break
            }
        }
        return (completed, assigned)
    }

    private static func computeStreaks(
        todayNoon: Date,
        todayKey: String,
        rules: [CalendarRule],
        sessions: [WorkoutSession],
        walks: [WalkingCompletion],
        calendar: Calendar
    ) -> (current: Int, best: Int) {
        let candidates = rules.map(\.startDay)
            + walks.map(\.day)
            + sessions.compactMap(\.completedDay)
        let validPastOrToday = candidates.filter { Schedule.validDay($0) && $0 <= todayKey }
        guard let earliestCandidate = validPastOrToday.min(),
              let earliestNoon = Schedule.date(earliestCandidate, calendar: calendar) else {
            return (0, 0)
        }

        let floorNoon = calendar.date(byAdding: .day, value: -maxLookbackDays, to: todayNoon) ?? earliestNoon
        let startNoon = max(earliestNoon, floorNoon)

        var runningStreak = 0
        var bestStreak = 0
        var hasCompletedInRun = false
        var consecutiveUnassigned = 0

        var cursor = startNoon
        while cursor <= todayNoon {
            let dayKey = Schedule.day(cursor, calendar: calendar)
            let status = Schedule.status(on: dayKey, rules: rules, sessions: sessions, walks: walks)

            switch status {
            case .completed:
                runningStreak += 1
                hasCompletedInRun = true
                consecutiveUnassigned = 0
                bestStreak = max(bestStreak, runningStreak)

            case .pending:
                if dayKey < todayKey {
                    runningStreak = 0
                    hasCompletedInRun = false
                    consecutiveUnassigned = 0
                }

            case .unassigned:
                if hasCompletedInRun {
                    consecutiveUnassigned += 1
                    if consecutiveUnassigned <= maxRestBridgeDays {
                        let remainingBridge = maxRestBridgeDays - consecutiveUnassigned + 1
                        if hasAssignedDayAhead(
                            from: cursor,
                            withinDays: remainingBridge,
                            rules: rules,
                            sessions: sessions,
                            walks: walks,
                            calendar: calendar
                        ) {
                            runningStreak += 1
                            bestStreak = max(bestStreak, runningStreak)
                        }
                    } else {
                        runningStreak = 0
                        hasCompletedInRun = false
                        consecutiveUnassigned = 0
                    }
                }
            }

            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }

        return (runningStreak, bestStreak)
    }

    private static func hasAssignedDayAhead(
        from date: Date,
        withinDays limit: Int,
        rules: [CalendarRule],
        sessions: [WorkoutSession],
        walks: [WalkingCompletion],
        calendar: Calendar
    ) -> Bool {
        guard limit >= 1 else { return false }
        for step in 1...limit {
            guard let target = calendar.date(byAdding: .day, value: step, to: date) else { continue }
            let key = Schedule.day(target, calendar: calendar)
            if Schedule.status(on: key, rules: rules, sessions: sessions, walks: walks) != .unassigned {
                return true
            }
        }
        return false
    }

    private static func bestRecord(for exerciseName: String, in sessions: [WorkoutSession]) -> PersonalRecord? {
        let targetKey = ProgressData.key(exerciseName)
        var best: (record: PersonalRecord, kgWeight: Double, sessionID: String)?

        for session in sessions {
            guard let finishedAt = session.finishedAt,
                  let unit = WeightUnit(rawValue: session.unit) else { continue }
            let ordered = session.exercises.flatMap { exercise in
                session.rows(for: exercise).compactMap { row in session.sets.first { $0.id == row.id } }
            }
            let workingSets = ordered.filter {
                ProgressData.key($0.exercise) == targetKey && $0.effectiveKind == .working
            }
            for set in workingSets {
                guard let kg = unit.convert(set.weight, to: .kg) else { continue }
                let candidate = PersonalRecord(
                    exercise: exerciseName,
                    weight: set.weight,
                    reps: set.reps,
                    rpe: set.rpe,
                    unit: unit,
                    achievedAt: finishedAt
                )
                if let current = best {
                    if isBetter(
                        candidate: (candidate, kg, session.id.uuidString),
                        than: current
                    ) {
                        best = (candidate, kg, session.id.uuidString)
                    }
                } else {
                    best = (candidate, kg, session.id.uuidString)
                }
            }
        }
        return best?.record
    }

    private static func isBetter(
        candidate: (record: PersonalRecord, kgWeight: Double, sessionID: String),
        than current: (record: PersonalRecord, kgWeight: Double, sessionID: String)
    ) -> Bool {
        if abs(candidate.kgWeight - current.kgWeight) > 1e-9 {
            return candidate.kgWeight > current.kgWeight
        }
        if candidate.record.reps != current.record.reps {
            return candidate.record.reps > current.record.reps
        }
        if candidate.record.achievedAt != current.record.achievedAt {
            return candidate.record.achievedAt > current.record.achievedAt
        }
        return candidate.sessionID > current.sessionID
    }
}
