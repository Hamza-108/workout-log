import Foundation
import SwiftData

enum PlanKind: String, CaseIterable, Codable, Hashable { case template, walking, none }
enum DayStatus: String { case unassigned, pending, completed }

@Model
final class CalendarRule {
    var id: UUID
    var startDay: String
    var endDay: String?
    var weekday: Int?
    var kind: String
    var templateID: UUID?
    var templateName: String?

    init(startDay: String, weekday: Int? = nil, kind: PlanKind, templateID: UUID? = nil, templateName: String? = nil) {
        id = UUID()
        self.startDay = startDay
        self.weekday = weekday
        self.kind = kind.rawValue
        self.templateID = templateID
        self.templateName = templateName
    }
}

@Model
final class WalkingCompletion {
    var id: UUID
    var day: String
    init(day: String) { id = UUID(); self.day = day }
}

enum Schedule {
    static func calendar(timeZone: TimeZone = .autoupdatingCurrent) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .current
        calendar.timeZone = timeZone
        calendar.firstWeekday = Calendar.current.firstWeekday
        return calendar
    }

    static func day(_ date: Date, calendar: Calendar = Schedule.calendar()) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func date(_ day: String, calendar: Calendar = Schedule.calendar()) -> Date? {
        let pieces = day.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces.map(String.init).joined(separator: "-") == day,
              pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              day.allSatisfy({ ($0 >= "0" && $0 <= "9") || $0 == "-" }),
              let year = Int(pieces[0]), (1...9999).contains(year), let month = Int(pieces[1]), let date = Int(pieces[2]),
              let result = calendar.date(from: DateComponents(year: year, month: month, day: date, hour: 12)),
              self.day(result, calendar: calendar) == day else { return nil }
        return result
    }

    static func validDay(_ day: String) -> Bool {
        date(day, calendar: calendar(timeZone: TimeZone(secondsFromGMT: 0)!)) != nil
    }

    static func weekday(_ day: String) -> Int? {
        let utc = calendar(timeZone: TimeZone(secondsFromGMT: 0)!)
        return date(day, calendar: utc).map { utc.component(.weekday, from: $0) }
    }

    static func rule(on day: String, rules: [CalendarRule]) -> CalendarRule? {
        if let exact = rules.first(where: { $0.weekday == nil && $0.startDay == day }) { return exact }
        let weekday = self.weekday(day)
        return rules.filter {
            $0.weekday != nil && $0.weekday == weekday && $0.startDay <= day && ($0.endDay == nil || day < $0.endDay!)
        }.max { $0.startDay < $1.startDay }
    }

    static func status(on day: String, rules: [CalendarRule], sessions: [WorkoutSession], walks: [WalkingCompletion]) -> DayStatus {
        guard let rule = rule(on: day, rules: rules), rule.kind != PlanKind.none.rawValue else { return .unassigned }
        if rule.kind == PlanKind.walking.rawValue { return walks.contains { $0.day == day } ? .completed : .pending }
        return sessions.contains {
            $0.finishedAt != nil && $0.sourceTemplateID == rule.templateID && $0.completedDay == day
        } ? .completed : .pending
    }

    static func validate(_ rules: [CalendarRule]) throws {
        var exactDays: Set<String> = []
        for rule in rules {
            guard validDay(rule.startDay), let kind = PlanKind(rawValue: rule.kind) else { throw LogError(message: "Invalid calendar assignment.") }
            if kind == .template {
                guard rule.templateID != nil, let name = rule.templateName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw LogError(message: "A scheduled template needs its ID and saved name.")
                }
            } else if rule.templateID != nil || rule.templateName != nil { throw LogError(message: "Walking and clear dates cannot reference a template.") }
            if let weekday = rule.weekday {
                guard (1...7).contains(weekday), self.weekday(rule.startDay) == weekday else { throw LogError(message: "Invalid weekly assignment weekday.") }
                if let end = rule.endDay {
                    guard validDay(end), end > rule.startDay else { throw LogError(message: "Invalid weekly assignment interval.") }
                }
            } else {
                guard rule.endDay == nil, exactDays.insert(rule.startDay).inserted else { throw LogError(message: "Duplicate or invalid date-specific assignment.") }
            }
        }
        for weekday in 1...7 {
            let weekly = rules.filter { $0.weekday == weekday }.sorted { $0.startDay < $1.startDay }
            for index in weekly.indices.dropFirst() {
                guard let end = weekly[index - 1].endDay, end <= weekly[index].startDay else {
                    throw LogError(message: "Weekly assignments overlap. No records were imported.")
                }
            }
        }
    }

    static func assign(on day: String, kind: PlanKind, template: WorkoutTemplate? = nil, repeating: Bool, in context: ModelContext) throws {
        guard validDay(day), let weekday = weekday(day) else { throw LogError(message: "Choose a valid calendar day.") }
        if kind == .template {
            guard let template,
                  try context.fetch(FetchDescriptor<WorkoutTemplate>()).contains(where: { $0.id == template.id }) else {
                throw LogError(message: "That template is unavailable. Choose another template.")
            }
        }
        let rules = try context.fetch(FetchDescriptor<CalendarRule>())
        let new = CalendarRule(startDay: day, weekday: repeating ? weekday : nil, kind: kind,
                               templateID: kind == .template ? template?.id : nil,
                               templateName: kind == .template ? template?.name : nil)
        try context.commit {
            for rule in rules {
                if rule.weekday == nil && rule.startDay == day { context.delete(rule) }
                else if repeating, rule.weekday == weekday {
                    if rule.startDay >= day { context.delete(rule) }
                    else if rule.endDay == nil || day < rule.endDay! { rule.endDay = day }
                }
            }
            context.insert(new)
        }
    }

    static func markWalk(on day: String, done: Bool, in context: ModelContext, now: Date = Date(), calendar: Calendar = Schedule.calendar()) throws {
        let rules = try context.fetch(FetchDescriptor<CalendarRule>())
        guard validDay(day), day <= self.day(now, calendar: calendar), rule(on: day, rules: rules)?.kind == PlanKind.walking.rawValue else {
            throw LogError(message: "Walking can be marked done only on an assigned walking day, today or earlier.")
        }
        let entries = try context.fetch(FetchDescriptor<WalkingCompletion>()).filter { $0.day == day }
        try context.commit {
            if done, entries.isEmpty { context.insert(WalkingCompletion(day: day)) }
            if !done { for entry in entries { context.delete(entry) } }
        }
    }
}
