import Foundation
import SwiftData

struct SharedTemplateExercise: Codable, Equatable, Sendable {
    var name: String
    var sets: Int
    var videoURL: String? = nil
}

struct SharedTemplate: Codable, Equatable, Identifiable, Sendable {
    var id: String { "\(name)-\(exercises.map(\.name).joined(separator: ","))" }
    var name: String
    var exercises: [SharedTemplateExercise]

    init(name: String, exercises: [SharedTemplateExercise]) {
        self.name = name
        self.exercises = exercises
    }

    init(draft: TemplateDraft) {
        self.name = draft.name
        self.exercises = draft.exercises.enumerated().map { index, exerciseName in
            let sets = draft.setCounts.indices.contains(index) ? draft.setCounts[index] : 3
            return SharedTemplateExercise(name: exerciseName, sets: sets, videoURL: draft.videoURLs?[exerciseName])
        }
    }

    init(template: WorkoutTemplate) {
        self.init(draft: TemplatePack.draft(template))
    }

    func toDraft() throws -> TemplateDraft {
        let (cleanName, cleanExercises) = try WorkoutTemplate.validated(
            name: name,
            exercises: exercises.map(\.name)
        )
        guard cleanName == name, cleanExercises == exercises.map(\.name) else {
            throw LogError(message: "Published template names must not have leading or trailing whitespace.")
        }
        let counts = exercises.map(\.sets)
        try WorkoutTemplate.validateSetCounts(counts, exercises: cleanExercises)
        var videos: [String: String] = [:]
        for (exerciseName, item) in zip(cleanExercises, exercises) {
            if let normalized = try VideoLink.normalized(item.videoURL) {
                guard normalized == item.videoURL else {
                    throw LogError(message: "Published template video links must be canonical YouTube URLs.")
                }
                videos[exerciseName] = normalized
            }
        }
        let draft = TemplateDraft(
            name: cleanName,
            exercises: cleanExercises,
            setCounts: counts,
            videoURLs: videos.isEmpty ? nil : videos
        )
        try TemplatePack.validate([draft])
        return draft
    }
}

struct SharedPersonalRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String { ProgressData.key(exercise) }
    var exercise: String
    var weight: Double
    var reps: Int
    var rpe: Double
    var unit: WeightUnit
    var achievedAt: String

    init(_ record: PersonalRecord) {
        self.exercise = record.exercise
        self.weight = record.weight
        self.reps = record.reps
        self.rpe = record.rpe
        self.unit = record.unit
        self.achievedAt = DataTransfer.dateString(record.achievedAt)
    }

    init(exercise: String, weight: Double, reps: Int, rpe: Double, unit: WeightUnit, achievedAt: String) {
        self.exercise = exercise
        self.weight = weight
        self.reps = reps
        self.rpe = rpe
        self.unit = unit
        self.achievedAt = achievedAt
    }

    func toPersonalRecord() throws -> PersonalRecord {
        try validate()
        let date = try DataTransfer.date(achievedAt)
        return PersonalRecord(
            exercise: exercise,
            weight: weight,
            reps: reps,
            rpe: rpe,
            unit: unit,
            achievedAt: date
        )
    }

    func validate() throws {
        let trimmed = exercise.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == exercise else {
            throw LogError(message: "Personal record exercise name is invalid.")
        }
        guard weight.isFinite, weight >= 0, reps > 0, rpe.isFinite, (0...10).contains(rpe) else {
            throw LogError(message: "Personal record values are out of range.")
        }
        _ = try DataTransfer.date(achievedAt)
    }
}

struct SharedProfilePayload: Codable, Equatable, Identifiable, Sendable {
    static let maxDisplayNameLength = 40

    var id: UUID { userID }
    var schemaVersion: Int = 1
    var userID: UUID
    var displayName: String
    var updatedAt: String
    var currentStreak: Int
    var bestStreak: Int
    var adherencePercent: Int
    var completedLast30Days: Int
    var assignedLast30Days: Int
    var personalRecords: [SharedPersonalRecord]
    var publishedTemplates: [SharedTemplate]

    static func validateDisplayName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LogError(message: "Enter a display name.")
        }
        guard trimmed.count <= maxDisplayNameLength else {
            throw LogError(message: "Display name must be \(maxDisplayNameLength) characters or fewer.")
        }
        return trimmed
    }

    func validate() throws {
        guard schemaVersion == 1 else {
            throw LogError(message: "Unsupported leaderboard profile version: \(schemaVersion).")
        }
        let cleanName = try Self.validateDisplayName(displayName)
        guard cleanName == displayName else {
            throw LogError(message: "Display name must not contain leading or trailing whitespace.")
        }
        _ = try DataTransfer.date(updatedAt)
        guard currentStreak >= 0, bestStreak >= currentStreak else {
            throw LogError(message: "Invalid streak values.")
        }
        guard (0...100).contains(adherencePercent),
              completedLast30Days >= 0,
              assignedLast30Days >= completedLast30Days else {
            throw LogError(message: "Invalid 30-day adherence values.")
        }
        var seenExercises: Set<String> = []
        for record in personalRecords {
            try record.validate()
            guard seenExercises.insert(ProgressData.key(record.exercise)).inserted else {
                throw LogError(message: "Duplicate exercise in personal records.")
            }
        }
        for template in publishedTemplates {
            _ = try template.toDraft()
        }
    }

    func validatedTemplateDrafts() throws -> [TemplateDraft] {
        let drafts = try publishedTemplates.map { try $0.toDraft() }
        try TemplatePack.validate(drafts)
        return drafts
    }
}

struct LeaderboardProfileConfig: Codable, Equatable, Sendable {
    var userID: UUID
    var clientToken: UUID
    var displayName: String
    var sharePersonalRecords: Bool
    var publishedTemplateIDs: [UUID]

    init(
        userID: UUID = UUID(),
        clientToken: UUID = UUID(),
        displayName: String = "Athlete",
        sharePersonalRecords: Bool = true,
        publishedTemplateIDs: [UUID] = []
    ) {
        self.userID = userID
        self.clientToken = clientToken
        self.displayName = displayName
        self.sharePersonalRecords = sharePersonalRecords
        self.publishedTemplateIDs = publishedTemplateIDs
    }

    func buildPayload(
        rules: [CalendarRule],
        sessions: [WorkoutSession],
        walks: [WalkingCompletion],
        templates: [WorkoutTemplate],
        today: String? = nil,
        now: Date = Date(),
        calendar: Calendar = Schedule.calendar()
    ) throws -> SharedProfilePayload {
        let cleanName = try SharedProfilePayload.validateDisplayName(displayName)
        let summary = StreakCalculator.summary(
            rules: rules,
            sessions: sessions,
            walks: walks,
            today: today,
            now: now,
            calendar: calendar
        )
        let records = sharePersonalRecords
            ? StreakCalculator.personalRecords(sessions: sessions).map(SharedPersonalRecord.init)
            : []
        let publishedIDSet = Set(publishedTemplateIDs)
        let selectedTemplates = templates
            .filter { publishedIDSet.contains($0.id) }
            .sorted {
                let cmp = $0.name.localizedStandardCompare($1.name)
                return cmp == .orderedSame ? $0.id.uuidString < $1.id.uuidString : cmp == .orderedAscending
            }
            .map(SharedTemplate.init(template:))

        let payload = SharedProfilePayload(
            schemaVersion: 1,
            userID: userID,
            displayName: cleanName,
            updatedAt: DataTransfer.dateString(now),
            currentStreak: summary.currentStreak,
            bestStreak: summary.bestStreak,
            adherencePercent: summary.adherencePercent,
            completedLast30Days: summary.completedLast30Days,
            assignedLast30Days: summary.assignedLast30Days,
            personalRecords: records,
            publishedTemplates: selectedTemplates
        )
        try payload.validate()
        return payload
    }
}

struct LeaderboardRankedEntry: Equatable, Identifiable, Sendable {
    var id: UUID { member.userID }
    var rank: Int
    var member: SharedProfilePayload
}

struct LeaderboardResponse: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    var generatedAt: String
    var members: [SharedProfilePayload]

    func validate() throws {
        guard schemaVersion == 1 else {
            throw LogError(message: "Unsupported leaderboard response version: \(schemaVersion).")
        }
        _ = try DataTransfer.date(generatedAt)
        var seen: Set<UUID> = []
        for member in members {
            try member.validate()
            guard seen.insert(member.userID).inserted else {
                throw LogError(message: "Duplicate user ID in leaderboard response.")
            }
        }
    }
}

enum LeaderboardRanking {
    static func rank(_ members: [SharedProfilePayload]) -> [LeaderboardRankedEntry] {
        let sorted = members.sorted(by: comesBefore)
        return sorted.enumerated().map { index, member in
            LeaderboardRankedEntry(rank: index + 1, member: member)
        }
    }

    static func comesBefore(_ lhs: SharedProfilePayload, _ rhs: SharedProfilePayload) -> Bool {
        if lhs.currentStreak != rhs.currentStreak {
            return lhs.currentStreak > rhs.currentStreak
        }
        if lhs.adherencePercent != rhs.adherencePercent {
            return lhs.adherencePercent > rhs.adherencePercent
        }
        if lhs.bestStreak != rhs.bestStreak {
            return lhs.bestStreak > rhs.bestStreak
        }
        if lhs.completedLast30Days != rhs.completedLast30Days {
            return lhs.completedLast30Days > rhs.completedLast30Days
        }
        let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        return lhs.userID.uuidString < rhs.userID.uuidString
    }
}

struct LeaderboardServerConfig: Codable, Equatable, Sendable {
    var baseURLString: String
    var groupToken: String

    init(baseURLString: String = "", groupToken: String = "") {
        self.baseURLString = baseURLString
        self.groupToken = groupToken
    }

    var isConfigured: Bool {
        !baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !groupToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func validatedBaseURL() throws -> URL {
        var trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else {
            throw LogError(message: "Enter a valid server URL starting with https:// or http://.")
        }
        return url
    }

    func validatedToken() throws -> String {
        let trimmed = groupToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isNewline }) else {
            throw LogError(message: "Enter a valid group token.")
        }
        return trimmed
    }
}

