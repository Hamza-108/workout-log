import Charts
import Foundation
import SwiftData
import SwiftUI

enum ProgressMode: String, CaseIterable, Identifiable {
    case lifting = "Lifting"
    case bodyWeight = "Body weight"
    var id: String { rawValue }
}

enum ProgressFormat {
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "Unavailable" }
        return value.formatted(.number.grouping(.never).precision(.fractionLength(0...2)))
    }

    static func weight(_ value: Double, _ unit: WeightUnit) -> String {
        "\(number(value)) \(unit.rawValue)"
    }

    /// Neutral, signed change. No good or bad framing.
    static func signed(_ value: Double) -> String {
        if abs(value) < 0.005 { return "0" }
        let magnitude = number(abs(value))
        if value > 0 { return "+" + magnitude }
        if value < 0 { return "-" + magnitude }
        return magnitude
    }

    static func shortDate(_ value: Date) -> String {
        value.formatted(date: .abbreviated, time: .omitted)
    }
}

private enum BodyWeightEditorTarget: Identifiable {
    case create(UUID)
    case edit(BodyWeightEntry)

    var id: String {
        switch self {
        case .create(let token): return "create-\(token.uuidString)"
        case .edit(let entry): return "edit-\(entry.id.uuidString)"
        }
    }

    var entry: BodyWeightEntry? {
        switch self {
        case .create: return nil
        case .edit(let entry): return entry
        }
    }
}

struct ProgressViewScreen: View {
    @AppStorage("weightUnit") private var preferredUnit = WeightUnit.kg.rawValue
    @Query(filter: #Predicate<WorkoutSession> { $0.finishedAt != nil }) private var sessions: [WorkoutSession]
    @Query(sort: \BodyWeightEntry.day, order: .reverse) private var bodyWeights: [BodyWeightEntry]
    @State private var mode: ProgressMode = .lifting
    @State private var range: ProgressRange = .all
    @State private var displayUnit: WeightUnit = .kg
    @State private var appliedPreference = false
    @State private var editorTarget: BodyWeightEditorTarget?
    var body: some View {
        List {
            controls
            content
        }
        .navigationTitle("Progress")
        .onAppear { applyPreferenceOnce() }
        .sheet(item: $editorTarget) { target in
            NavigationStack {
                BodyWeightEditor(entry: target.entry, defaultUnit: displayUnit) {
                    editorTarget = nil
                }
            }
        }
    }

    private var controls: some View {
        Section {
            Picker("Progress", selection: $mode) {
                ForEach(ProgressMode.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("progressMode")

            Picker("Range", selection: $range) {
                ForEach(ProgressRange.allCases, id: \.self) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("progressRange")

            Picker("Display unit", selection: $displayUnit) {
                ForEach(WeightUnit.allCases, id: \.self) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("progressUnit")
        } footer: {
            Text("The display unit only changes this screen. New workouts and saved weigh-ins keep their own units.")
        }
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .lifting:
            LiftingProgressSection(sessions: sessions, range: range, unit: displayUnit)
        case .bodyWeight:
            BodyWeightProgressSection(entries: bodyWeights, range: range, unit: displayUnit,
                                      onAdd: { editorTarget = .create(UUID()) },
                                      onEdit: { editorTarget = .edit($0) })
        }
    }

    /// The screen starts on the app's stored weight unit and never writes back to it.
    private func applyPreferenceOnce() {
        guard !appliedPreference else { return }
        appliedPreference = true
        displayUnit = WeightUnit(rawValue: preferredUnit) ?? displayUnit
    }
}

// MARK: - Lifting

private struct LiftingProgressSection: View {
    let sessions: [WorkoutSession]
    let range: ProgressRange
    let unit: WeightUnit
    @State private var exercise: String?
    @State private var selectedDate: Date?

    private var names: [String] { ProgressData.exercises(sessions: sessions) }

    private var points: [ProgressData.LiftPoint] {
        guard let exercise else { return [] }
        return ProgressData.lifting(exercise: exercise, sessions: sessions, unit: unit, range: range)
    }

    private var selectedPoint: ProgressData.LiftPoint? {
        guard let selectedDate else { return nil }
        return points.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    var body: some View {
        Section("Lifting") {
            picker
            caption
            if points.isEmpty {
                Text(emptyMessage).foregroundStyle(.secondary)
            } else {
                chart
                delta
                selection
                pointList
            }
        }
        .onAppear { syncExercise() }
        .onChange(of: names) { _, _ in syncExercise() }
    }

    private var picker: some View {
        Picker("Exercise", selection: $exercise) {
            Text("Choose an exercise").tag(String?.none)
            ForEach(names, id: \.self) { name in
                Text(name).tag(String?.some(name))
            }
        }
        .accessibilityIdentifier("progressExercise")
    }

    private var caption: some View {
        Text("Heaviest working set per finished session. Warm-up sets are excluded. Rep counts can differ: this is load, not equivalent strength. Each exercise name is tracked separately, so a rename or a variation starts a new series.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var chart: some View {
        LiftingChart(points: points, selection: $selectedDate)
            .frame(height: 220)
            .padding(.vertical, 4)
    }

    private var delta: some View {
        Text(deltaText)
            .font(.subheadline)
            .accessibilityIdentifier("liftingDelta")
    }

    private var deltaText: String {
        guard points.count > 1, let first = points.first, let last = points.last else {
            return "Only one session in this range, so there is no change to compare."
        }
        return "Change from \(ProgressFormat.shortDate(first.date)) to \(ProgressFormat.shortDate(last.date)): "
            + "\(ProgressFormat.signed(last.weight - first.weight)) \(unit.rawValue)"
    }

    @ViewBuilder private var selection: some View {
        if let point = selectedPoint {
            LiftingPointDetail(point: point, unit: unit)
        } else {
            Text("Touch the chart to see the closest session.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var pointList: some View {
        ForEach(points) { point in
            LiftingPointRow(point: point, unit: unit)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("liftingPoint-\(point.id.uuidString)")
        }
    }

    private var emptyMessage: String {
        names.isEmpty
            ? "No finished workouts yet. Finish a workout to see it here."
            : "No finished sessions for this exercise in the selected range."
    }

    private func syncExercise() {
        if let exercise, names.contains(exercise) { return }
        exercise = names.first
    }
}

private struct LiftingChart: View {
    let points: [ProgressData.LiftPoint]
    @Binding var selection: Date?

    var body: some View {
        Chart(points) { point in
            LineMark(x: .value("Date", point.date), y: .value("Weight", point.weight))
            PointMark(x: .value("Date", point.date), y: .value("Weight", point.weight))
        }
        .chartXSelection(value: $selection)
        .chartYAxisLabel("Weight")
        .chartLegend(.hidden)
        .accessibilityIdentifier("liftingChart")
    }
}

private struct LiftingPointDetail: View {
    let point: ProgressData.LiftPoint
    let unit: WeightUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(point.date, format: .dateTime.day().month().year()).font(.headline)
            Text("Weight: \(ProgressFormat.weight(point.weight, unit))")
            Text("Reps: \(point.reps) · RPE: \(ProgressFormat.number(point.rpe))")
            if point.originalUnit != unit {
                Text("Logged as \(ProgressFormat.weight(point.originalWeight, point.originalUnit))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("liftingSelection")
    }
}

private struct LiftingPointRow: View {
    let point: ProgressData.LiftPoint
    let unit: WeightUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(point.date, format: .dateTime.day().month().year())
            Text("\(ProgressFormat.weight(point.weight, unit)) · \(point.reps) reps · RPE \(ProgressFormat.number(point.rpe))")
                .font(.subheadline)
            if point.originalUnit != unit {
                Text("Logged as \(ProgressFormat.weight(point.originalWeight, point.originalUnit))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Body weight

private struct BodyWeightChartPoint: Identifiable {
    let id: UUID
    let date: Date
    let weight: Double
}

private struct BodyWeightProgressSection: View {
    @Environment(\.modelContext) private var context
    let entries: [BodyWeightEntry]
    let range: ProgressRange
    let unit: WeightUnit
    let onAdd: () -> Void
    let onEdit: (BodyWeightEntry) -> Void
    @State private var deleting: BodyWeightEntry?
    @State private var error: String?

    /// The range start is converted to a day key, so the whole start day is included.
    private var filtered: [BodyWeightEntry] {
        guard let start = range.start(now: Date(), calendar: Schedule.calendar()) else { return entries }
        let key = Schedule.day(start, calendar: Schedule.calendar())
        return entries.filter { $0.day >= key }
    }

    private var chartPoints: [BodyWeightChartPoint] {
        filtered.compactMap { entry in
            guard let date = Schedule.date(entry.day, calendar: Schedule.calendar()) else { return nil }
            guard let value = WeightUnit(rawValue: entry.unit)?.convert(entry.weight, to: unit), value.isFinite else { return nil }
            return BodyWeightChartPoint(id: entry.id, date: date, weight: value)
        }.sorted { $0.date < $1.date }
    }

    var body: some View {
        Section("Body weight") {
            Button("Add weigh-in", systemImage: "plus", action: onAdd)
                .accessibilityIdentifier("addBodyWeight")
            summary
            if !chartPoints.isEmpty {
                chart
            }
            if filtered.isEmpty {
                Text("No weigh-ins in this range.").foregroundStyle(.secondary)
            }
            ForEach(filtered) { entry in
                row(entry)
            }
        }
        .confirmationDialog("Delete weigh-in?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete weigh-in", role: .destructive) { deleteEntry() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let deleting {
                Text("Delete the weigh-in for \(deleting.day) (\(ProgressFormat.weight(deleting.weight, originalUnit(deleting))))? This cannot be undone.")
            }
        }
        .alert("Could not save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            latest
            Text(deltaText)
                .font(.subheadline)
                .accessibilityIdentifier("bodyWeightDelta")
        }
    }

    @ViewBuilder private var latest: some View {
        if let entry = filtered.first {
            if let weight = converted(entry) {
                Text("Latest: \(ProgressFormat.weight(weight, unit))").font(.headline)
            } else {
                Text("Latest: \(ProgressFormat.number(entry.weight)) \(entry.unit)").font(.headline)
                Text("Cannot convert this value to the selected display unit.").font(.caption)
            }
            if let note = originalNote(entry) {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("No weigh-ins yet.").font(.headline)
        }
    }

    private var deltaText: String {
        if filtered.isEmpty { return "Add a weigh-in to start tracking change." }
        guard filtered.count > 1, let first = filtered.last, let last = filtered.first else {
            return "Only one weigh-in in this range, so there is no change to compare."
        }
        guard let lastWeight = converted(last), let firstWeight = converted(first) else {
            return "Change unavailable in the selected unit. Recorded values are listed below."
        }
        let difference = lastWeight - firstWeight
        return "Change since \(first.day): \(ProgressFormat.signed(difference)) \(unit.rawValue)"
    }

    private var chart: some View {
        BodyWeightChart(points: chartPoints)
            .frame(height: 220)
            .padding(.vertical, 4)
    }

    private func row(_ entry: BodyWeightEntry) -> some View {
        BodyWeightRow(entry: entry, unit: unit, onEdit: { onEdit(entry) }, onDelete: { deleting = entry })
    }

    private func converted(_ entry: BodyWeightEntry) -> Double? {
        guard let value = WeightUnit(rawValue: entry.unit)?.convert(entry.weight, to: unit), value.isFinite else { return nil }
        return value
    }

    private func originalUnit(_ entry: BodyWeightEntry) -> WeightUnit {
        WeightUnit(rawValue: entry.unit) ?? unit
    }

    private func originalNote(_ entry: BodyWeightEntry) -> String? {
        let original = originalUnit(entry)
        guard original != unit else { return nil }
        return "Logged as \(ProgressFormat.weight(entry.weight, original))"
    }

    private func deleteEntry() {
        guard let deleting else { return }
        do { try context.commit { context.delete(deleting) } }
        catch { self.error = error.localizedDescription }
        self.deleting = nil
    }
}

private struct BodyWeightChart: View {
    let points: [BodyWeightChartPoint]

    var body: some View {
        Chart(points) { point in
            LineMark(x: .value("Date", point.date), y: .value("Weight", point.weight))
            PointMark(x: .value("Date", point.date), y: .value("Weight", point.weight))
        }
        .chartYAxisLabel("Weight")
        .chartLegend(.hidden)
        .accessibilityIdentifier("bodyWeightChart")
    }
}

private struct BodyWeightRow: View {
    let entry: BodyWeightEntry
    let unit: WeightUnit
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.day).font(.headline)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("bodyWeightEntry-\(entry.day)")
            Spacer()
            Button("Delete", role: .destructive, action: onDelete)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("deleteBodyWeight")
        }
    }

    /// The list always shows the values as they were recorded.
    private var subtitle: String {
        let original = WeightUnit(rawValue: entry.unit) ?? unit
        return "\(ProgressFormat.weight(entry.weight, original)) · \(displayDate)"
    }

    private var displayDate: String {
        guard let date = Schedule.date(entry.day, calendar: Schedule.calendar()) else { return entry.day }
        return ProgressFormat.shortDate(date)
    }
}

// MARK: - Body weight editor

struct BodyWeightEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BodyWeightEntry.day) private var entries: [BodyWeightEntry]
    let entry: BodyWeightEntry?
    let onSaved: () -> Void
    @State private var date: Date
    @State private var weightText: String
    @State private var unit: WeightUnit
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var pending: PendingWeighIn?

    init(entry: BodyWeightEntry? = nil, defaultUnit: WeightUnit = .kg, onSaved: @escaping () -> Void = {}) {
        self.entry = entry
        self.onSaved = onSaved
        _date = State(initialValue: entry.flatMap { Schedule.date($0.day, calendar: Schedule.calendar()) } ?? Date())
        _weightText = State(initialValue: entry.map { WeightInput.format($0.weight) } ?? "")
        _unit = State(initialValue: entry.flatMap { WeightUnit(rawValue: $0.unit) } ?? defaultUnit)
    }

    var body: some View {
        Form {
            Section("Weigh-in") {
                DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date)
                    .accessibilityIdentifier("bodyWeightDate")
                TextField("Body weight", text: $weightText)
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("bodyWeightValue")
                Picker("Unit", selection: $unit) {
                    ForEach(WeightUnit.allCases, id: \.self) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("bodyWeightUnit")
            }
            Section {
                Text("Weigh-ins are stored in the unit chosen here. The display unit on the progress screen does not change saved weigh-ins.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red).accessibilityIdentifier("bodyWeightError")
                }
            }
        }
        .navigationTitle(entry == nil ? "Add weigh-in" : "Edit weigh-in")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.accessibilityIdentifier("cancelBodyWeight")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.accessibilityIdentifier("saveBodyWeight")
            }
        }
        .confirmationDialog("Update existing weigh-in?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("Update weigh-in") { confirmUpdate() }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            if let pending {
                Text("A weigh-in already exists for \(pending.day): \(pending.oldValue). Saving replaces it with \(pending.newValue).")
            }
        }
        .alert("Could not save", isPresented: $showingError) {
            Button("OK") { showingError = false }
        } message: { Text(errorMessage ?? "") }
        .interactiveDismissDisabled()
    }

    private func save() {
        errorMessage = nil
        let day = Schedule.day(date, calendar: Schedule.calendar())
        let weight: Double
        do {
            weight = try WeightInput.parse(weightText)
        } catch {
            fail(error.localizedDescription)
            return
        }
        guard weight > 0, weight.isFinite else {
            fail("Enter a body weight greater than zero.")
            return
        }
        if entry == nil, let existing = entries.first(where: { $0.day == day }) {
            pending = PendingWeighIn(id: existing.id, day: day,
                                     oldValue: ProgressFormat.weight(existing.weight, WeightUnit(rawValue: existing.unit) ?? unit),
                                     newValue: ProgressFormat.weight(weight, unit),
                                     weight: weight, unit: unit)
            return
        }
        performSave(day: day, weight: weight, unit: unit, existingID: entry?.id)
    }

    /// Only an explicit confirmation updates a weigh-in that already exists on the chosen day.
    private func confirmUpdate() {
        guard let pending else { return }
        self.pending = nil
        performSave(day: pending.day, weight: pending.weight, unit: pending.unit, existingID: pending.id)
    }

    private func performSave(day: String, weight: Double, unit: WeightUnit, existingID: UUID?) {
        do {
            try BodyWeightEntry.save(day: day, weight: weight, unit: unit, existingID: existingID, in: context)
            dismiss()
            onSaved()
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        showingError = true
    }
}

private struct PendingWeighIn {
    let id: UUID
    let day: String
    let oldValue: String
    let newValue: String
    let weight: Double
    let unit: WeightUnit
}
