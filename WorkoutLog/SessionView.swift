import SwiftData
import SwiftUI

private struct SetSelection: Identifiable {
    var id = UUID()
    let exercise: String
    var existing: LoggedSet?
    var kind: SetKind = .working
}

struct SessionView: View {
    @Environment(\.modelContext) private var context
    @Environment(WorkoutActivityController.self) private var activities
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: WorkoutSession
    @Query(filter: #Predicate<WorkoutSession> { $0.finishedAt != nil }) private var history: [WorkoutSession]
    @State private var selection: SetSelection?
    @State private var deleting: PlannedSet?
    @State private var discarding = false
    @State private var finishing = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Text(session.startedAt, format: .dateTime.day().month().year().hour().minute())
                Text("\(session.setSummary) · \(session.unit)")
                    .foregroundStyle(.secondary)
            } footer: {
                Text("Logged sets save immediately. You can close and resume this workout later.")
            }
            ForEach(session.exercises, id: \.self) { exercise in
                exerciseSection(exercise)
            }
            Section {
                Button("Discard workout", role: .destructive) { discarding = true }
                    .accessibilityIdentifier("discardWorkout")
            }
        }
        .navigationTitle(session.templateName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Finish") { finishing = true }
                    .disabled(session.sets.isEmpty)
                    .accessibilityIdentifier("finishWorkout")
            }
        }
        .sheet(item: $selection) { selection in
            NavigationStack { SetEditor(session: session, exercise: selection.exercise, existing: selection.existing, setID: selection.id, kind: selection.kind) }
        }
        .confirmationDialog("Delete this set?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let set = deleting {
                Button("Delete set", role: .destructive) {
                    do { try context.commit { try session.removeSet(set.id) } }
                    catch { self.error = error.localizedDescription }
                    deleting = nil
                }
                .accessibilityIdentifier("confirmDeleteSet")
            }
        }
        .confirmationDialog("Finish this workout?", isPresented: $finishing, titleVisibility: .visible) {
            Button("Finish workout") { finish() }
            Button("Keep logging", role: .cancel) {}
        } message: { Text("This saves the workout to History. Close instead to keep it in progress.") }
        .confirmationDialog("Discard this workout?", isPresented: $discarding, titleVisibility: .visible) {
            Button("Discard workout", role: .destructive) {
                do {
                    let id = session.id
                    try context.commit { context.delete(session) }
                    activities.end(id)
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }
        } message: { Text("This removes the current workout and its saved sets, not the template.") }
        .alert("Could not save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func exerciseSection(_ exercise: String) -> some View {
        let previous = ProgressData.previousSession(exercise: exercise, before: session.startedAt, sessions: history)
        return Section {
            ForEach(session.rows(for: exercise)) { row in setButton(row, previous: previous) }
            Button {
                selection = SetSelection(exercise: exercise)
            } label: { Label("Add set", systemImage: "plus.circle") }
                .accessibilityIdentifier("addSet-\(exercise)")
            Button {
                selection = SetSelection(exercise: exercise, kind: .warmup)
            } label: { Label("Add warm-up set", systemImage: "plus.circle") }
                .accessibilityIdentifier("addWarmup-\(exercise)")
        } header: {
            VStack(alignment: .leading) {
                HStack {
                    Text(exercise)
                    Spacer()
                    VideoButton(name: exercise, link: session.videoURLs?[exercise])
                }
                if let finish = previous?.finishedAt {
                    Text("Last session: \(finish.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .textCase(nil)
        }
    }

    private func setButton(_ row: PlannedSet, previous: WorkoutSession?) -> some View {
        let number = session.ordinal(for: row) ?? 1
        let logged = session.sets.first { $0.id == row.id }
        let prior = previous.flatMap { ProgressData.previousSet(row: row, current: session, previous: $0) }
        return Button {
            selection = SetSelection(id: row.id, exercise: row.exercise, existing: logged, kind: row.effectiveKind)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                if let logged {
                    SetRow(set: logged, unit: session.unit, number: number).foregroundStyle(.primary)
                } else {
                    HStack {
                        Text(row.effectiveKind.label(number))
                        Spacer()
                        Text("Not logged").foregroundStyle(.secondary)
                    }
                }
                Text(lastResult(prior, previousUnit: previous?.unit)).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("previousSet-\(row.exercise)-\(row.effectiveKind.rawValue)-\(number)")
            }
        }
        .accessibilityHint(logged == nil ? "Log this planned set" : "Edit this set")
        .accessibilityIdentifier(logged == nil ? "plannedSet-\(row.exercise)-\(row.effectiveKind == .warmup ? "warmup-" : "")\(number)" : "loggedSet")
        .swipeActions {
            Button("Delete", role: .destructive) { deleting = row }
            Button(row.effectiveKind == .working ? "Make warm-up" : "Make working") {
                do { try context.commit { try session.classify(row.id, as: row.effectiveKind == .working ? .warmup : .working) } }
                catch { self.error = error.localizedDescription }
            }
        }
    }

    private func lastResult(_ set: LoggedSet?, previousUnit: String?) -> String {
        guard let set, let previousUnit else { return "Last: —" }
        let original = "\(set.weight.formatted()) \(previousUnit)"
        var weight = original
        if let source = WeightUnit(rawValue: previousUnit), let target = WeightUnit(rawValue: session.unit), source != target,
           let converted = source.convert(set.weight, to: target) {
            weight = "\(converted.formatted(.number.precision(.fractionLength(0...2)))) \(target.rawValue) (logged \(original))"
        }
        return "Last: \(weight) × \(set.reps) · RPE \(set.rpe.formatted())"
    }

    private func finish() {
        do {
            try context.commit { try session.finish() }
            activities.end(session.id)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct SetRow: View {
    let set: LoggedSet
    let unit: String
    var number: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let number { Text(set.effectiveKind.label(number)).font(.subheadline) }
            Text("\(set.weight.formatted()) \(unit) × \(set.reps)")
                .font(.headline)
            Text("Exertion (RPE) \(set.rpe.formatted()) / 10")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(number.map { set.effectiveKind.label($0) + ", " } ?? "")\(set.weight.formatted()) \(unit), \(set.reps) reps, exertion \(set.rpe.formatted()) out of 10")
        .accessibilityIdentifier("loggedSet")
    }
}

private struct SetEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let session: WorkoutSession
    let exercise: String
    let existing: LoggedSet?
    let setID: UUID
    @State private var weight: String
    @State private var reps: String
    @State private var rpe: Double
    @State private var kind: SetKind
    @State private var error: String?

    init(session: WorkoutSession, exercise: String, existing: LoggedSet?, setID: UUID, kind: SetKind) {
        self.session = session
        self.exercise = exercise
        self.existing = existing
        self.setID = setID
        _weight = State(initialValue: existing.map { WeightInput.format($0.weight) } ?? "")
        _reps = State(initialValue: existing.map { String($0.reps) } ?? "")
        _rpe = State(initialValue: existing?.rpe ?? 7)
        _kind = State(initialValue: kind)
    }

    var body: some View {
        Form {
            Section(exercise) {
                Picker("Set type", selection: $kind) {
                    ForEach(SetKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("setKind")
                TextField("Weight (\(session.unit))", text: $weight)
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("setWeight")
                TextField("Reps", text: $reps)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("setReps")
                Stepper("Exertion (RPE): \(rpe.formatted()) / 10", value: $rpe, in: 0...10)
                    .accessibilityIdentifier("setRPE")
            }
            Section {
                Text("0 = no effort · 10 = maximum effort. Zero weight is allowed for bodyweight exercises.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("validationError") } }
        }
        .navigationTitle(existing == nil ? "Add set" : "Edit set")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save set") { save() }.accessibilityIdentifier("saveSet")
            }
        }
        .interactiveDismissDisabled()
    }

    private func save() {
        do {
            let parsedWeight = try WeightInput.parse(weight)
            guard let parsedReps = Int(reps.trimmingCharacters(in: .whitespacesAndNewlines)), parsedReps > 0 else {
                throw LogError(message: "Reps must be a positive whole number.")
            }
            let set = LoggedSet(id: existing?.id ?? setID, exercise: exercise, weight: parsedWeight, reps: parsedReps, rpe: rpe, kind: kind)
            try context.commit { try session.record(set) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
