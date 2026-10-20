import SwiftData
import SwiftUI

struct CalendarView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query private var rules: [CalendarRule]
    @Query private var walks: [WalkingCompletion]
    @Query private var sessions: [WorkoutSession]
    @Query(sort: \WorkoutTemplate.name) private var templates: [WorkoutTemplate]
    @AppStorage("weightUnit") private var unit = WeightUnit.kg.rawValue
    var routeID: UUID? = nil
    let onOpen: (UUID) -> Void
    @State private var month = Date()
    @State private var selected = Schedule.day(Date())
    @State private var today = Schedule.day(Date())
    @State private var assigning = false
    @State private var error: String?

    private var calendar: Calendar { Schedule.calendar() }
    private var assignment: CalendarRule? { Schedule.rule(on: selected, rules: rules) }
    private var draft: WorkoutSession? { sessions.first { $0.finishedAt == nil } }
    private var assignedTemplate: WorkoutTemplate? { templates.first { $0.id == assignment?.templateID } }

    var body: some View {
        List {
            Section { monthGrid }
            selectedDay
            Section {
                Text("Blue: completed. Red: assigned, not completed. Future red dates are scheduled, not missed. Unassigned dates are neutral.")
                Text("Workouts count on the actual local day you finish, not the date selected here. Older workouts without a source-template ID are not matched by name.")
            }.font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("Calendar")
        .toolbar { Button("Today") { showToday() }.accessibilityIdentifier("calendarToday") }
        .sheet(isPresented: $assigning) {
            NavigationStack { CalendarAssignmentEditor(day: selected, current: assignment) }
        }
        .onChange(of: routeID) { _, id in if id != nil { assigning = false } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { today = Schedule.day(Date()) } }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in today = Schedule.day(Date()) }
        .alert("Could not save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var monthGrid: some View {
        VStack(spacing: 8) {
            HStack {
                Button { moveMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .accessibilityLabel("Previous month").accessibilityIdentifier("calendarPreviousMonth")
                Spacer()
                Text(monthTitle).font(.headline)
                Spacer()
                Button { moveMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .accessibilityLabel("Next month").accessibilityIdentifier("calendarNextMonth")
            }.buttonStyle(.borderless)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
                ForEach(0..<7, id: \.self) { index in
                    Text(calendar.veryShortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1 + index) % 7])
                        .font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                }
                ForEach(Array(monthDates.enumerated()), id: \.offset) { _, date in
                    if let date { dayButton(date) }
                    else { Color.clear.frame(height: 44).accessibilityHidden(true) }
                }
            }
        }
    }

    private func dayButton(_ date: Date) -> some View {
        let day = Schedule.day(date, calendar: calendar)
        let status = Schedule.status(on: day, rules: rules, sessions: sessions, walks: walks)
        let colour: Color = status == .completed ? .blue : status == .pending ? .red : .secondary
        let target = Schedule.rule(on: day, rules: rules)
        return Button { selected = day } label: {
            VStack(spacing: 1) {
                Text("\(calendar.component(.day, from: date))")
                Image(systemName: status == .completed ? "checkmark" : status == .pending ? "circle" : "minus")
                    .font(.system(size: 8))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(colour.opacity(status == .unassigned ? 0.05 : 0.2), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(selected == day ? Color.primary : .clear, lineWidth: 2) }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("calendarDay-\(day)")
        .accessibilityLabel("\(day), \(title(target)), \(statusText(status, day: day))")
        .accessibilityValue(selected == day ? "Selected, \(status.rawValue)" : status.rawValue)
    }

    private var selectedDay: some View {
        Section(selected) {
            Text(title(assignment)).font(.headline).accessibilityIdentifier("calendarAssignment")
            Text(statusText(Schedule.status(on: selected, rules: rules, sessions: sessions, walks: walks), day: selected))
                .accessibilityIdentifier("calendarStatus")
            if let assignment, assignment.kind != PlanKind.none.rawValue {
                Text(assignment.weekday == nil ? "This date only" : "Weekly assignment").foregroundStyle(.secondary)
            }
            Button("Assign / change day") { assigning = true }.accessibilityIdentifier("calendarAssign")
            if assignment?.kind == PlanKind.walking.rawValue {
                walkingActions
            } else if assignment?.kind == PlanKind.template.rawValue {
                workoutActions
            }
        }
    }

    @ViewBuilder private var walkingActions: some View {
        let done = walks.contains { $0.day == selected }
        Button(done ? "Undo completion" : "Mark walk done") {
            do { try Schedule.markWalk(on: selected, done: !done, in: context) }
            catch { self.error = error.localizedDescription }
        }
        .disabled(selected > today)
        .accessibilityIdentifier(done ? "undoWalkDone" : "markWalkDone")
    }

    @ViewBuilder private var workoutActions: some View {
        if let draft {
            Button("Resume \(draft.templateName)") { onOpen(draft.id) }.accessibilityIdentifier("calendarResume")
        } else {
            Button("Start workout") { start() }
                .disabled(assignedTemplate == nil).accessibilityIdentifier("calendarStart")
        }
        if assignedTemplate == nil { Text("Template unavailable. Assign another template to start.").foregroundStyle(.secondary) }
    }

    private func title(_ rule: CalendarRule?) -> String {
        guard let rule else { return "Unassigned" }
        switch PlanKind(rawValue: rule.kind) {
        case .walking: return "Walking"
        case .template: return templates.first { $0.id == rule.templateID }?.name ?? "\(rule.templateName ?? "Template") (unavailable)"
        default: return "Unassigned"
        }
    }

    private func statusText(_ status: DayStatus, day: String) -> String {
        switch status {
        case .completed: return "Completed"
        case .pending: return day > today ? "Scheduled" : "Not completed"
        case .unassigned: return "No assignment"
        }
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter.string(from: month)
    }

    private var monthDates: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let first = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: interval.start),
              let range = calendar.range(of: .day, in: .month, for: first) else { return [] }
        let leading = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        var dates: [Date?] = Array(repeating: nil, count: leading)
        dates += range.map { calendar.date(byAdding: .day, value: $0 - 1, to: first) }
        while dates.count % 7 != 0 { dates.append(nil) }
        return dates
    }

    private func moveMonth(_ value: Int) {
        guard let first = calendar.dateInterval(of: .month, for: month)?.start,
              let moved = calendar.date(byAdding: .month, value: value, to: first) else { return }
        month = moved
        if let firstDate = monthDates.compactMap({ $0 }).first { selected = Schedule.day(firstDate, calendar: calendar) }
    }

    private func showToday() { month = Date(); today = Schedule.day(Date()); selected = today }

    private func start() {
        guard let template = assignedTemplate else { return }
        do {
            let session = try WorkoutSession.start(template: template, unit: WeightUnit(rawValue: unit) ?? .kg, in: context)
            onOpen(session.id)
        } catch { self.error = error.localizedDescription }
    }
}

private struct CalendarAssignmentEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \WorkoutTemplate.name) private var templates: [WorkoutTemplate]
    let day: String
    @State private var kind: PlanKind
    @State private var templateID: UUID?
    @State private var repeating: Bool
    @State private var error: String?

    init(day: String, current: CalendarRule?) {
        self.day = day
        _kind = State(initialValue: current.flatMap { PlanKind(rawValue: $0.kind) } ?? .template)
        _templateID = State(initialValue: current?.templateID)
        _repeating = State(initialValue: current?.weekday != nil)
    }

    var body: some View {
        Form {
            Section(day) {
                Picker("Assignment", selection: $kind) {
                    Text("Template").tag(PlanKind.template)
                    Text("Walking").tag(PlanKind.walking)
                    Text("Clear").tag(PlanKind.none)
                }.pickerStyle(.segmented).accessibilityIdentifier("calendarKind")
                if kind == .template {
                    Picker("Template", selection: $templateID) {
                        Text("Choose a template").tag(Optional<UUID>.none)
                        ForEach(templates) { template in Text(template.name).tag(Optional(template.id)) }
                    }.accessibilityIdentifier("calendarTemplate")
                    if templates.isEmpty { Text("Create a template in the Templates tab first.") }
                }
            }
            Section {
                Toggle("Repeat every \(weekdayTitle) from this date onward", isOn: $repeating)
                    .accessibilityIdentifier("calendarRepeating")
            } footer: {
                Text(repeating ? "Earlier weekly plans stay unchanged. Future date-specific overrides remain. The selected date uses this new weekly plan." : "This date only. It overrides a weekly plan, including when cleared.")
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Assign day")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(kind == .template && templateID == nil)
                    .accessibilityIdentifier("saveCalendarAssignment")
            }
        }
        .onAppear { if templateID == nil { templateID = templates.first?.id } }
        .interactiveDismissDisabled()
    }

    private var weekdayTitle: String {
        let weekday = Schedule.weekday(day) ?? 1
        return Schedule.calendar().weekdaySymbols[weekday - 1]
    }

    private func save() {
        do {
            try Schedule.assign(on: day, kind: kind, template: templates.first { $0.id == templateID }, repeating: repeating, in: context)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
