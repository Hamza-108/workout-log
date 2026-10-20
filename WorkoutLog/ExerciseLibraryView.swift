import SwiftData
import SwiftUI

struct VideoButton: View {
    let name: String
    let link: String?
    var body: some View {
        if let link, let url = URL(string: link) {
            Link(destination: url) {
                Image(systemName: "play.circle").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Watch \(name) tutorial")
            .accessibilityIdentifier("video-\(name)")
        }
    }
}

struct VideoURLField: View {
    @Binding var text: String
    @State private var expanded = false
    var body: some View {
        if expanded || !text.isEmpty {
            TextField("YouTube video URL (optional)", text: $text)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("exerciseVideoURL")
            Button("Remove video", role: .destructive) { text = ""; expanded = false }
        } else {
            Button("Add video", systemImage: "play.circle") { expanded = true }
        }
    }
}

struct ExerciseLibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LibraryExercise.name) private var exercises: [LibraryExercise]
    @State private var search = ""
    @State private var creating = false
    @State private var editing: LibraryExercise?
    @State private var deleting: LibraryExercise?
    @State private var clearIDs: Set<UUID> = []
    @State private var confirmingClear = false
    @State private var error: String?

    var body: some View {
        exerciseList
        .searchable(text: $search, prompt: "Find an exercise")
        .navigationTitle("Exercise library")
        .toolbar {
            Button("New exercise", systemImage: "plus") { creating = true }
                .accessibilityIdentifier("newLibraryExercise")
            Menu {
                Button("Clear library", systemImage: "trash", role: .destructive) { prepareClear() }
                    .disabled(exercises.isEmpty)
                    .accessibilityIdentifier("clearLibrary")
            } label: { Label("More", systemImage: "ellipsis.circle") }
                .accessibilityIdentifier("libraryActions")
        }
        .sheet(isPresented: $creating) { NavigationStack { LibraryExerciseEditor() } }
        .sheet(item: $editing) { exercise in NavigationStack { LibraryExerciseEditor(exercise: exercise) } }
        .confirmationDialog("Delete library exercise?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete exercise", role: .destructive) {
                guard let deleting else { return }
                do { try context.commit { context.delete(deleting) } }
                catch { self.error = error.localizedDescription }
                self.deleting = nil
            }
        } message: { Text("Existing templates and saved workouts keep their own copies.") }
        .confirmationDialog("Clear exercise library?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear library", role: .destructive) { performClear() }
                .accessibilityIdentifier("confirmClearLibrary")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \(clearIDs.count) \(clearIDs.count == 1 ? "exercise" : "exercises") from the library. Export a backup first: this cannot be undone. Templates, saved workouts and calendar are not affected.")
        }
        .alert("Could not save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var exerciseList: some View {
        List {
            if exercises.isEmpty { Text("Save exercises here, then select them when building a template.") }
            ForEach(filteredExercises) { exercise in exerciseRow(exercise) }
        }
    }

    private var filteredExercises: [LibraryExercise] {
        exercises.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    private func prepareClear() {
        clearIDs = Set(exercises.map(\.id))
        confirmingClear = true
    }

    private func performClear() {
        do { try LibraryExercise.clear(in: context, expectedIDs: clearIDs) }
        catch { self.error = error.localizedDescription }
    }

    private func exerciseRow(_ exercise: LibraryExercise) -> some View {
        HStack {
            Button(exercise.name) { editing = exercise }
                .accessibilityIdentifier("libraryExercise-\(exercise.name)")
            Spacer()
            VideoButton(name: exercise.name, link: exercise.videoURL)
        }
        .buttonStyle(.borderless)
        .swipeActions { Button("Delete", role: .destructive) { deleting = exercise } }
    }

}

struct LibraryExerciseEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    var exercise: LibraryExercise?
    @State private var name: String
    @State private var video: String
    @State private var error: String?

    init(exercise: LibraryExercise? = nil) {
        self.exercise = exercise
        _name = State(initialValue: exercise?.name ?? "")
        _video = State(initialValue: exercise?.videoURL ?? "")
    }

    var body: some View {
        Form {
            Section("Exercise") {
                TextField("Exercise name", text: $name).accessibilityIdentifier("libraryExerciseName")
                VideoURLField(text: $video)
            }
            Section { Text("Templates receive a copy when you select this exercise. Editing this entry will not change existing templates or workouts.") }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle(exercise == nil ? "New exercise" : "Edit exercise")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.accessibilityIdentifier("saveLibraryExercise")
            }
        }
        .interactiveDismissDisabled()
    }

    private func save() {
        do {
            let (name, video) = try LibraryExercise.validated(name: name, videoURL: video)
            try LibraryExercise.checkUnique(name, excluding: exercise?.id, in: context)
            try context.commit {
                if let exercise { exercise.name = name; exercise.videoURL = video }
                else { context.insert(LibraryExercise(name: name, videoURL: video)) }
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct ExercisePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LibraryExercise.name) private var exercises: [LibraryExercise]
    let excluding: Set<String>
    let onAdd: ([LibraryExercise]) -> Void
    @State private var selected: [UUID] = []
    @State private var search = ""
    @State private var creating = false

    var body: some View {
        List {
            Button("Create new exercise", systemImage: "plus") { creating = true }
                .accessibilityIdentifier("createExerciseInPicker")
            ForEach(exercises.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { exercise in
                Button {
                    if selected.contains(exercise.id) { selected.removeAll { $0 == exercise.id } }
                    else { selected.append(exercise.id) }
                } label: {
                    HStack {
                        Text(exercise.name)
                        Spacer()
                        if exercise.videoURL != nil { Image(systemName: "play.circle").accessibilityLabel("Has video") }
                        if selected.contains(exercise.id) { Image(systemName: "checkmark") }
                    }
                }
                .disabled(excluding.contains(exercise.name.lowercased()))
                .accessibilityIdentifier("pickExercise-\(exercise.name)")
                .accessibilityValue(selected.contains(exercise.id) ? "Selected" : "Not selected")
            }
        }
        .searchable(text: $search, prompt: "Find an exercise")
        .navigationTitle("Add exercises")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add selected") {
                    onAdd(selected.compactMap { id in exercises.first { $0.id == id } })
                    dismiss()
                }
                .disabled(selected.isEmpty)
                .accessibilityIdentifier("addSelectedExercises")
            }
        }
        .sheet(isPresented: $creating) { NavigationStack { LibraryExerciseEditor() } }
    }
}
