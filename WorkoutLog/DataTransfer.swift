import Foundation
import SwiftData

struct TemplateDraft: Codable, Identifiable {
    var name: String
    var exercises: [String]
    var id: String { name + exercises.joined(separator: "\n") }

    static func decode(_ data: Data) throws -> TemplateDraft {
        try DataTransfer.checkSize(data.count)
        let draft = try JSONDecoder().decode(Self.self, from: data)
        let (name, exercises) = try WorkoutTemplate.validated(name: draft.name, exercises: draft.exercises)
        return Self(name: name, exercises: exercises)
    }
}

enum DataTransfer {
    static let maximumBytes = 25 * 1024 * 1024

    struct Template: Codable, Identifiable, Equatable {
        var id: UUID
        var name: String
        var exercises: [String]

        init(_ model: WorkoutTemplate) {
            id = model.id
            name = model.name
            exercises = model.exercises
        }
    }

    struct Session: Codable, Identifiable, Equatable {
        var id: UUID
        var startedAt: String
        var finishedAt: String?
        var templateName: String
        var exercises: [String]
        var unit: WeightUnit
        var sets: [LoggedSet]

        init(_ model: WorkoutSession) throws {
            guard let unit = WeightUnit(rawValue: model.unit) else { throw LogError(message: "Unknown workout weight unit.") }
            id = model.id
            startedAt = DataTransfer.dateString(model.startedAt)
            finishedAt = model.finishedAt.map(DataTransfer.dateString)
            templateName = model.templateName
            exercises = model.exercises
            self.unit = unit
            sets = model.sets
        }
    }

    struct Backup: Codable, Equatable {
        var schemaVersion = 1
        var preferredWeightUnit: WeightUnit
        var templates: [Template]
        var sessions: [Session]

        func validate() throws {
            guard schemaVersion == 1 else { throw LogError(message: "Unsupported backup version: \(schemaVersion).") }
            guard Set(templates.map(\.id)).count == templates.count,
                  Set(sessions.map(\.id)).count == sessions.count else {
                throw LogError(message: "The backup contains duplicate template or workout IDs.")
            }
            for template in templates {
                try DataTransfer.validateNames(template.name, exercises: template.exercises)
            }
            for session in sessions {
                try DataTransfer.validateNames(session.templateName, exercises: session.exercises)
                _ = try DataTransfer.date(session.startedAt)
                if let finishedAt = session.finishedAt {
                    _ = try DataTransfer.date(finishedAt)
                    guard !session.sets.isEmpty else { throw LogError(message: "A completed workout must contain at least one set.") }
                }
                guard Set(session.sets.map(\.id)).count == session.sets.count else {
                    throw LogError(message: "A workout contains duplicate set IDs.")
                }
                for set in session.sets {
                    try set.validate()
                    guard session.exercises.contains(set.exercise) else {
                        throw LogError(message: "A set refers to an exercise missing from its workout.")
                    }
                }
            }
            guard sessions.filter({ $0.finishedAt == nil }).count <= 1 else {
                throw LogError(message: "The backup contains more than one unfinished workout.")
            }
        }
    }

    struct Preview {
        var templates: [Template]
        var sessions: [Session]
        var skippedTemplates: Int
        var skippedSessions: Int
        var restorePreference: Bool

        var summary: String {
            "Templates: \(templates.count) new, \(skippedTemplates) already saved.\nWorkouts: \(sessions.count) new, \(skippedSessions) already saved.\nUnfinished workouts to add: \(sessions.filter { $0.finishedAt == nil }.count)."
        }
    }

    static func fileErrorMessage(_ error: Error) -> String? {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSUserCancelledError { return nil }
        return error.localizedDescription
    }

    static func checkSize(_ count: Int) throws {
        guard count <= maximumBytes else { throw LogError(message: "JSON files must be 25 MiB or smaller.") }
    }

    static func read(_ url: URL) throws -> Data {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let stream = InputStream(url: url) else { throw LogError(message: "Could not open the selected JSON file.") }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError ?? LogError(message: "Could not read the JSON file.") }
            if count == 0 { break }
            try checkSize(data.count + count)
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    static func dateString(_ date: Date) -> String {
        formatter().string(from: date)
    }

    static func date(_ text: String) throws -> Date {
        let formatter = formatter()
        guard let date = formatter.date(from: text), date.timeIntervalSince1970.isFinite,
              formatter.string(from: date) == text else {
            throw LogError(message: "Backup dates must use UTC ISO-8601 with milliseconds, for example 2026-01-01T12:00:00.000Z.")
        }
        return date
    }

    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    private static func validateNames(_ name: String, exercises: [String]) throws {
        let (cleanName, cleanExercises) = try WorkoutTemplate.validated(name: name, exercises: exercises)
        guard cleanName == name, cleanExercises == exercises else {
            throw LogError(message: "Backup names must not contain leading or trailing whitespace.")
        }
    }

    static func snapshot(in context: ModelContext, unit: WeightUnit) throws -> Backup {
        let templates = try context.fetch(FetchDescriptor<WorkoutTemplate>(sortBy: [SortDescriptor(\.name)]))
        let sessions = try context.fetch(FetchDescriptor<WorkoutSession>(sortBy: [SortDescriptor(\.startedAt)]))
        let backup = try Backup(preferredWeightUnit: unit, templates: templates.map(Template.init), sessions: sessions.map(Session.init))
        try backup.validate()
        return backup
    }

    static func encode(_ backup: Backup) throws -> Data {
        try backup.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(backup)
        try checkSize(data.count)
        return data
    }

    static func decode(_ data: Data) throws -> Backup {
        try checkSize(data.count)
        let backup = try JSONDecoder().decode(Backup.self, from: data)
        try backup.validate()
        return backup
    }

    private static func additions<T: Identifiable & Equatable>(_ incoming: [T], existing: [T]) throws -> [T] where T.ID == UUID {
        let saved = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        return try incoming.filter { record in
            guard let existing = saved[record.id] else { return true }
            guard existing == record else {
                throw LogError(message: "Backup conflict for ID \(record.id). No records were imported. Export your current data before resolving the different copies.")
            }
            return false
        }
    }

    static func preview(_ backup: Backup, in context: ModelContext) throws -> Preview {
        try backup.validate()
        let existing = try snapshot(in: context, unit: .kg)
        let templates = try additions(backup.templates, existing: existing.templates)
        let sessions = try additions(backup.sessions, existing: existing.sessions)
        guard (existing.sessions + sessions).filter({ $0.finishedAt == nil }).count <= 1 else {
            throw LogError(message: "Finish or discard your current workout before importing a different unfinished workout.")
        }
        return Preview(templates: templates, sessions: sessions,
                       skippedTemplates: backup.templates.count - templates.count,
                       skippedSessions: backup.sessions.count - sessions.count,
                       restorePreference: existing.templates.isEmpty && existing.sessions.isEmpty)
    }

    @discardableResult
    static func apply(_ backup: Backup, in context: ModelContext) throws -> (Preview, WeightUnit?) {
        let preview = try preview(backup, in: context)
        // Construct and validate every record before changing the editing context.
        let sessions = try preview.sessions.map { record in
            let session = WorkoutSession(templateName: record.templateName, exercises: record.exercises, unit: record.unit)
            session.id = record.id
            session.startedAt = try date(record.startedAt)
            session.finishedAt = try record.finishedAt.map(date)
            session.sets = record.sets
            return session
        }
        let templates = preview.templates.map { record in
            let template = WorkoutTemplate(name: record.name, exercises: record.exercises)
            template.id = record.id
            return template
        }
        try context.commit {
            for template in templates { context.insert(template) }
            for session in sessions { context.insert(session) }
        }
        return (preview, preview.restorePreference ? backup.preferredWeightUnit : nil)
    }
}
