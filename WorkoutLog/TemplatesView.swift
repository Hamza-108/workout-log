import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct TemplatesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \WorkoutTemplate.name) private var templates: [WorkoutTemplate]
    @Query(filter: #Predicate<WorkoutSession> { $0.finishedAt == nil }, sort: \WorkoutSession.startedAt) private var drafts: [WorkoutSession]
    @AppStorage("weightUnit") private var unit = WeightUnit.kg.rawValue
    @State private var creating = false
    @State private var importing = false
    @State private var readingTemplate = false
    @State private var importedDraft: TemplateDraft?
    @State private var editing: WorkoutTemplate?
    @State private var deleting: WorkoutTemplate?
    @State private var activeSession: WorkoutSession?
    @State private var error: String?

    var body: some View {
        List {
            if readingTemplate { ProgressView("Reading template…") }
            if let draft = drafts.first {
                Section("In progress") {
                    Button {
                        activeSession = draft
                    } label: {
                        Label("Resume \(draft.templateName)", systemImage: "play.fill")
                    }
                    .accessibilityIdentifier("resumeWorkout")
                    Text("\(draft.sets.count) sets saved · \(draft.unit)")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("Weight unit for new workouts", selection: $unit) {
                    ForEach(WeightUnit.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Weight unit for new workouts")
            } footer: {
                Text("Saved workouts keep their original units.")
            }
            Section("Templates") {
                if templates.isEmpty {
                    Text("Create a template with the exercises you want to log.")
                        .foregroundStyle(.secondary)
                }
                ForEach(templates) { template in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(template.name).font(.headline)
                        Text(template.exercises.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary)
                        HStack {
                            Button("Start workout") { start(template) }
                                .disabled(!drafts.isEmpty)
                                .accessibilityIdentifier("startWorkout-\(template.name)")
                            Spacer()
                            Button("Edit") { editing = template }
                                .accessibilityLabel("Edit \(template.name)")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                    .swipeActions {
                        Button("Delete", role: .destructive) { deleting = template }
                    }
                }
            }
        }
        .navigationTitle("Templates")
        .toolbar {
            Button { creating = true } label: { Label("New template", systemImage: "plus") }
                .accessibilityIdentifier("newTemplate")
            Menu {
                Button("Import template", systemImage: "square.and.arrow.down") { importing = true }
                    .disabled(readingTemplate)
                NavigationLink("Data and backups") { DataTransferView() }
            } label: { Label("More", systemImage: "ellipsis.circle") }
                .accessibilityIdentifier("templateActions")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                readingTemplate = true
                Task {
                    defer { readingTemplate = false }
                    do {
                        importedDraft = try await Task.detached(priority: .userInitiated) {
                            try TemplateDraft.decode(DataTransfer.read(url))
                        }.value
                    } catch { self.error = error.localizedDescription }
                }
            case .failure(let error): self.error = error.localizedDescription
            }
        }
        .sheet(item: $importedDraft) { draft in NavigationStack { TemplateEditor(draft: draft) } }
        .sheet(isPresented: $creating) { NavigationStack { TemplateEditor() } }
        .sheet(item: $editing) { template in NavigationStack { TemplateEditor(template: template) } }
        .fullScreenCover(item: $activeSession) { session in NavigationStack { SessionView(session: session) } }
        .confirmationDialog("Delete template?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete template", role: .destructive) {
                guard let template = deleting else { return }
                do { try context.commit { context.delete(template) } }
                catch { self.error = error.localizedDescription }
                deleting = nil
            }
        } message: {
            Text("Saved workouts and your current workout will not be changed.")
        }
        .alert("Could not complete action", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func start(_ template: WorkoutTemplate) {
        do {
            activeSession = try WorkoutSession.start(template: template, unit: WeightUnit(rawValue: unit) ?? .kg, in: context)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ExerciseDraft: Identifiable {
    let id = UUID()
    var name: String
}

struct TemplateEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let template: WorkoutTemplate?
    @State private var name: String
    @State private var exercises: [ExerciseDraft]
    @State private var error: String?

    init(template: WorkoutTemplate? = nil, draft: TemplateDraft? = nil) {
        self.template = template
        _name = State(initialValue: template?.name ?? draft?.name ?? "")
        _exercises = State(initialValue: (template?.exercises ?? draft?.exercises ?? [""]).map { ExerciseDraft(name: $0) })
    }

    var body: some View {
        Form {
            Section("Template name") {
                TextField("For example, Push day", text: $name)
                    .accessibilityIdentifier("templateName")
            }
            Section {
                ForEach($exercises) { $exercise in
                    TextField("Exercise name", text: $exercise.name)
                        .accessibilityIdentifier("exerciseName")
                }
                .onDelete { exercises.remove(atOffsets: $0) }
                .onMove { exercises.move(fromOffsets: $0, toOffset: $1) }
                Button("Add exercise") { exercises.append(ExerciseDraft(name: "")) }
                    .accessibilityIdentifier("addExercise")
            } header: {
                Text("Exercises")
            } footer: {
                Text("Swipe to remove an exercise. Use Reorder to change the order.")
            }
            if let error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("validationError") } }
        }
        .navigationTitle(template == nil ? "New template" : "Edit template")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .primaryAction) { EditButton().accessibilityLabel("Reorder exercises") }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.accessibilityIdentifier("saveTemplate")
            }
        }
        .interactiveDismissDisabled()
    }

    private func save() {
        do {
            let (name, exercises) = try WorkoutTemplate.validated(name: name, exercises: exercises.map(\.name))
            try context.commit {
                if let template {
                    template.name = name
                    template.exercises = exercises
                } else {
                    context.insert(WorkoutTemplate(name: name, exercises: exercises))
                }
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
