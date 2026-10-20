import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct TemplatesView: View {
    @Environment(\.modelContext) private var context
    @Environment(WorkoutActivityController.self) private var activities
    @Binding var resumeID: UUID?
    @Binding var routeMessage: String?
    @Query(sort: \WorkoutTemplate.name) private var templates: [WorkoutTemplate]
    @Query(filter: #Predicate<WorkoutSession> { $0.finishedAt == nil }, sort: \WorkoutSession.startedAt) private var drafts: [WorkoutSession]
    @AppStorage("weightUnit") private var unit = WeightUnit.kg.rawValue
    @State private var creating = false
    @State private var importing = false
    @State private var exportingTemplates = false
    @State private var isVisible = false
    #if DEBUG
    @State private var testDraftLoaded = false
    #endif
    @State private var editing: WorkoutTemplate?
    @State private var deleting: WorkoutTemplate?
    @State private var activeSession: WorkoutSession?
    @State private var error: String?

    var body: some View {
        List {
            if let routeMessage { Section { Text(routeMessage).accessibilityIdentifier("routeMessage") } }
            if let notice = activities.notice { Section { Text(notice).foregroundStyle(.secondary) } }
            if let draft = drafts.first {
                Section("In progress") {
                    Button {
                        resume(draft)
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
                        Text(template.exercises.enumerated().map { index, name in
                            template.setCounts.map { "\(name) × \($0[index])" } ?? name
                        }.joined(separator: " · "))
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
        .task {
            #if DEBUG
            if !testDraftLoaded,
               let testID = ProcessInfo.processInfo.environment["WORKOUT_LOG_TEST_STORE"], UUID(uuidString: testID) != nil,
               ProcessInfo.processInfo.environment["WORKOUT_LOG_TEST_TEMPLATE"] != nil {
                testDraftLoaded = true
                importing = true
            }
            #endif
        }
        .toolbar {
            Button { creating = true } label: { Label("New template", systemImage: "plus") }
                .accessibilityIdentifier("newTemplate")
            Menu {
                Button("Import template", systemImage: "square.and.arrow.down") { importing = true }
                Button("Export templates", systemImage: "square.and.arrow.up") { exportingTemplates = true }
                NavigationLink("Exercise library", value: HomeDestination.library)
                NavigationLink("Data and backups", value: HomeDestination.data)
            } label: { Label("More", systemImage: "ellipsis.circle") }
                .accessibilityIdentifier("templateActions")
        }
        .sheet(isPresented: $importing, onDismiss: openRequestedSession) {
            NavigationStack { TemplateImportView() }
        }
        .sheet(isPresented: $exportingTemplates, onDismiss: openRequestedSession) { NavigationStack { TemplateExportView() } }
        .sheet(isPresented: $creating, onDismiss: openRequestedSession) { NavigationStack { TemplateEditor() } }
        .sheet(item: $editing, onDismiss: openRequestedSession) { template in NavigationStack { TemplateEditor(template: template) } }
        .fullScreenCover(item: $activeSession) { session in NavigationStack { SessionView(session: session) } }
        .onAppear { isVisible = true; openRequestedSession() }
        .onDisappear { isVisible = false }
        .onChange(of: resumeID, initial: true) { _, id in
            guard let id else { return }
            if activeSession?.id == id { resumeID = nil; return }
            if creating || editing != nil || importing || exportingTemplates {
                creating = false
                editing = nil
                importing = false
                exportingTemplates = false
            } else { openRequestedSession() }
        }
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

    private func resume(_ session: WorkoutSession) {
        activeSession = session
        activities.resume(session.id)
    }

    private func openRequestedSession() {
        guard isVisible, let id = resumeID else { return }
        resumeID = nil
        do {
            guard let session = try context.fetch(FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.finishedAt == nil })).first(where: { $0.id == id }) else {
                routeMessage = "That unfinished workout is no longer available. Your data has not changed."
                return
            }
            if activeSession?.id != id { resume(session) }
        } catch { routeMessage = error.localizedDescription }
    }

    private func start(_ template: WorkoutTemplate) {
        do {
            let session = try WorkoutSession.start(template: template, unit: WeightUnit(rawValue: unit) ?? .kg, in: context)
            resume(session)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ExerciseDraft: Identifiable {
    let id = UUID()
    var name: String
    var sets = 3
    var video = ""
}

struct TemplateEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let template: WorkoutTemplate?
    private let onImport: ((TemplateDraft) -> Void)?
    private let onCancel: (() -> Void)?
    @State private var picking = false
    @State private var name: String
    @State private var exercises: [ExerciseDraft]
    @State private var error: String?

    init(template: WorkoutTemplate? = nil, draft: TemplateDraft? = nil, onImport: ((TemplateDraft) -> Void)? = nil, onCancel: (() -> Void)? = nil) {
        self.template = template
        self.onImport = onImport
        self.onCancel = onCancel
        _name = State(initialValue: template?.name ?? draft?.name ?? "")
        let names = template?.exercises ?? draft?.exercises ?? [""]
        let counts = template?.setCounts ?? draft?.setCounts
        _exercises = State(initialValue: names.enumerated().map { index, name in
            ExerciseDraft(name: name, sets: counts?[index] ?? 3, video: (template?.videoURLs ?? draft?.videoURLs)?[name] ?? "")
        })
    }

    var body: some View {
        Form {
            Section("Template name") {
                TextField("For example, Push day", text: $name)
                    .accessibilityIdentifier("templateName")
            }
            Section {
                ForEach($exercises) { $exercise in
                    VStack(alignment: .leading) {
                        TextField("Exercise name", text: $exercise.name)
                            .accessibilityIdentifier("exerciseName")
                        Stepper("Sets: \(exercise.sets)", value: $exercise.sets, in: 1...99)
                            .accessibilityIdentifier("exerciseSets")
                        VideoURLField(text: $exercise.video)
                    }
                }
                .onDelete { exercises.remove(atOffsets: $0) }
                .onMove { exercises.move(fromOffsets: $0, toOffset: $1) }
                Button("Add exercises", systemImage: "list.bullet") { picking = true }
                    .accessibilityIdentifier("addExercise")
            } header: {
                Text("Exercises")
            } footer: {
                Text("Swipe to remove an exercise. Use Reorder to change the order. Selected exercises are copies; edits here do not change the library.")
            }
            if let error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("validationError") } }
        }
        .navigationTitle(template == nil ? "New template" : "Edit template")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onCancel?(); dismiss() } }
            ToolbarItem(placement: .primaryAction) { EditButton().accessibilityLabel("Reorder exercises") }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.accessibilityIdentifier("saveTemplate")
            }
        }
        .sheet(isPresented: $picking) {
            NavigationStack {
                ExercisePicker(excluding: Set(exercises.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })) { selected in
                    exercises.removeAll { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    exercises.append(contentsOf: selected.map { ExerciseDraft(name: $0.name, video: $0.videoURL ?? "") })
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private func save() {
        do {
            let (name, exercises) = try WorkoutTemplate.validated(name: name, exercises: exercises.map(\.name))
            let counts = self.exercises.map(\.sets)
            try WorkoutTemplate.validateSetCounts(counts, exercises: exercises)
            var videos: [String: String] = [:]
            for (name, fields) in zip(exercises, self.exercises) {
                if let video = try VideoLink.normalized(fields.video) { videos[name] = video }
            }
            let links = videos.isEmpty ? nil : videos
            if let onImport {
                onImport(TemplateDraft(name: name, exercises: exercises, setCounts: counts, videoURLs: links))
                return
            }
            var names = Set(try context.fetch(FetchDescriptor<LibraryExercise>()).map { $0.name.lowercased() })
            let additions = exercises.filter { names.insert($0.lowercased()).inserted }.map { LibraryExercise(name: $0, videoURL: videos[$0]) }
            try context.commit {
                for exercise in additions { context.insert(exercise) }
                if let template {
                    template.name = name
                    template.exercises = exercises
                    template.setCounts = counts
                    template.videoURLs = links
                } else {
                    context.insert(WorkoutTemplate(name: name, exercises: exercises, setCounts: counts, videoURLs: links))
                }
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
