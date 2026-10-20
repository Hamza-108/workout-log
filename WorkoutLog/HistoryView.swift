import SwiftData
import SwiftUI

struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<WorkoutSession> { $0.finishedAt != nil }, sort: \WorkoutSession.startedAt, order: .reverse) private var sessions: [WorkoutSession]
    @State private var deleting: WorkoutSession?
    @State private var error: String?

    var body: some View {
        List {
            if sessions.isEmpty {
                ContentUnavailableView("No workouts yet", systemImage: "dumbbell", description: Text("Finish a workout to see your sets here."))
            }
            ForEach(sessions) { session in
                NavigationLink {
                    WorkoutDetailView(session: session)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.templateName).font(.headline)
                        Text(session.startedAt, format: .dateTime.day().month().year().hour().minute())
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("\(session.sets.count) sets · \(session.unit)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("history-\(session.templateName)")
                .swipeActions {
                    Button("Delete", role: .destructive) { deleting = session }
                }
            }
        }
        .navigationTitle("History")
        .confirmationDialog("Delete saved workout?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete workout", role: .destructive) {
                guard let session = deleting else { return }
                do { try context.commit { context.delete(session) } }
                catch { self.error = error.localizedDescription }
                deleting = nil
            }
        } message: {
            if let deleting {
                Text("Delete \(deleting.templateName) from \(deleting.startedAt.formatted(date: .abbreviated, time: .shortened))? This removes its sets, not the template or another workout.")
            }
        }
        .alert("Could not save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}

private struct WorkoutDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let session: WorkoutSession
    private let title: String
    private let deletionMessage: String
    @State private var deleting = false
    @State private var deleted = false
    @State private var error: String?

    init(session: WorkoutSession) {
        self.session = session
        title = session.templateName
        deletionMessage = "Delete \(session.templateName) from \(session.startedAt.formatted(date: .abbreviated, time: .shortened))? This removes its sets, not the template or another workout. Export a backup first if you want to keep a copy."
    }

    var body: some View {
        List {
            if !deleted {
                Section("Started") {
                    Text(session.startedAt, format: .dateTime.day().month().year().hour().minute())
                }
                if let finishedAt = session.finishedAt {
                    Section("Finished") { Text(finishedAt, format: .dateTime.day().month().year().hour().minute()) }
                }
                ForEach(session.exercises, id: \.self) { exercise in
                    Section(exercise) {
                        let sets = session.sets.filter { $0.exercise == exercise }
                        if sets.isEmpty { Text("No sets logged").foregroundStyle(.secondary) }
                        ForEach(sets) { set in SetRow(set: set, unit: session.unit) }
                    }
                }
                Section {
                    Button("Delete workout", role: .destructive) { deleting = true }
                        .accessibilityIdentifier("deleteSavedWorkout")
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete saved workout?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete workout", role: .destructive) {
                do {
                    try context.commit { context.delete(session) }
                    deleted = true
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }
        } message: { Text(deletionMessage) }
        .alert("Could not save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}
