import SwiftData
import SwiftUI

private struct SetSelection: Identifiable {
    let id = UUID()
    let exercise: String
    var existing: LoggedSet?
}

struct SessionView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: WorkoutSession
    @State private var selection: SetSelection?
    @State private var deleting: LoggedSet?
    @State private var discarding = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Text(session.startedAt, format: .dateTime.day().month().year().hour().minute())
                Text("\(session.sets.count) sets saved · \(session.unit)")
                    .foregroundStyle(.secondary)
            } footer: {
                Text("Logged sets save immediately. You can close and resume this workout later.")
            }
            ForEach(session.exercises, id: \.self) { exercise in
                Section(exercise) {
                    ForEach(session.sets.filter { $0.exercise == exercise }) { set in
                        Button {
                            selection = SetSelection(exercise: exercise, existing: set)
                        } label: {
                            SetRow(set: set, unit: session.unit)
                                .foregroundStyle(.primary)
                        }
                        .accessibilityHint("Edit this set")
                        .swipeActions {
                            Button("Delete", role: .destructive) { deleting = set }
                        }
                    }
                    Button {
                        selection = SetSelection(exercise: exercise)
                    } label: { Label("Add set", systemImage: "plus.circle") }
                        .accessibilityIdentifier("addSet-\(exercise)")
                }
            }
            Section {
                Button("Discard workout", role: .destructive) { discarding = true }
            }
        }
        .navigationTitle(session.templateName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Finish") { finish() }
                    .disabled(session.sets.isEmpty)
                    .accessibilityIdentifier("finishWorkout")
            }
        }
        .sheet(item: $selection) { selection in
            NavigationStack { SetEditor(session: session, exercise: selection.exercise, existing: selection.existing) }
        }
        .confirmationDialog("Delete this set?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete set", role: .destructive) {
                guard let set = deleting else { return }
                do { try context.commit { session.sets.removeAll { $0.id == set.id } } }
                catch { self.error = error.localizedDescription }
                deleting = nil
            }
        }
        .confirmationDialog("Discard this workout?", isPresented: $discarding, titleVisibility: .visible) {
            Button("Discard workout", role: .destructive) {
                do {
                    try context.commit { context.delete(session) }
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }
        } message: { Text("This removes the current workout and its saved sets, not the template.") }
        .alert("Could not save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func finish() {
        do {
            try context.commit { try session.finish() }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct SetRow: View {
    let set: LoggedSet
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(set.weight.formatted()) \(unit) × \(set.reps)")
                .font(.headline)
            Text("Exertion (RPE) \(set.rpe.formatted()) / 10")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(set.weight.formatted()) \(unit), \(set.reps) reps, exertion \(set.rpe.formatted()) out of 10")
        .accessibilityIdentifier("loggedSet")
    }
}

private struct SetEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let session: WorkoutSession
    let exercise: String
    let existing: LoggedSet?
    @State private var weight: String
    @State private var reps: String
    @State private var rpe: Int
    @State private var error: String?

    init(session: WorkoutSession, exercise: String, existing: LoggedSet?) {
        self.session = session
        self.exercise = exercise
        self.existing = existing
        _weight = State(initialValue: existing.map { WeightInput.format($0.weight) } ?? "")
        _reps = State(initialValue: existing.map { String($0.reps) } ?? "")
        _rpe = State(initialValue: existing.map { Int($0.rpe) } ?? 7)
    }

    var body: some View {
        Form {
            Section(exercise) {
                TextField("Weight (\(session.unit))", text: $weight)
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("setWeight")
                TextField("Reps", text: $reps)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("setReps")
                Stepper("Exertion (RPE): \(rpe) / 10", value: $rpe, in: 0...10)
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
            let set = LoggedSet(id: existing?.id ?? UUID(), exercise: exercise, weight: parsedWeight, reps: parsedReps, rpe: Double(rpe))
            try context.commit { try session.record(set) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
