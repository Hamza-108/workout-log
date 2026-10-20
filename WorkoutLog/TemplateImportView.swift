import Observation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct TemplateImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(TemplateImportState.self) private var importState
    @State private var choosingFile = false
    @State private var busy = false
    @State private var message: String?
    @State private var error: String?
    @FocusState private var enteringText: Bool

    var body: some View {
        Group {
            if let review = importState.review {
                TemplateImportComparison(review: review) { importState.review = nil }
            } else if let draft = importState.drafts?.first, importState.drafts?.count == 1 {
                TemplateEditor(draft: draft, onImport: stageSingle, onCancel: { importState.reset() })
            } else { inputForm }
        }
        .task {
            #if DEBUG
            if !importState.hasPending, let testID = ProcessInfo.processInfo.environment["WORKOUT_LOG_TEST_STORE"], UUID(uuidString: testID) != nil,
               let fixture = ProcessInfo.processInfo.environment["WORKOUT_LOG_TEST_TEMPLATE"] {
                do { try accept(TemplatePack.decode(Data(fixture.utf8))) }
                catch { showError(error) }
            }
            #endif
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        let decoded = try await Task.detached(priority: .userInitiated) {
                            try TemplatePack.decode(DataTransfer.read(url))
                        }.value
                        try accept(decoded)
                    } catch { showError(error) }
                }
            case .failure(let error):
                if DataTransfer.fileErrorMessage(error) != nil { showError(error) }
            }
        }
        .alert("Could not import", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .interactiveDismissDisabled(busy || importState.drafts != nil)
    }

    private var inputForm: some View {
        @Bindable var state = importState
        return Form {
            if let message { Section { Text(message).accessibilityIdentifier("templateImportStatus") } }
            Section {
                Button("Choose JSON file", systemImage: "doc") { choosingFile = true }
                    .disabled(busy).accessibilityIdentifier("chooseTemplateJSON")
                if busy { ProgressView("Reading templates…") }
            }
            Section("Or enter / paste JSON") {
                TextEditor(text: $state.text)
                    .font(.system(.footnote, design: .monospaced))
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($enteringText).frame(minHeight: 150)
                    .accessibilityLabel("Template JSON text")
                    .accessibilityIdentifier("templateJSONInput")
                Button("Review JSON") { readText() }
                    .disabled(busy || importState.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("reviewTemplateJSON")
            }
            .disabled(busy)
            Section("Template JSON format") {
                example(TemplateDraft.example, identifier: "templateJSONExample")
                Button("Copy example", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = TemplateDraft.example
                    message = "Example copied."
                }.accessibilityIdentifier("copyTemplateExample")
                Text("name: the template name. exercises: an ordered list. Each exercise needs a name and sets (a whole number from 1 to 99). videoURL is an optional HTTPS YouTube link.")
            }
            Section("Whole-plan JSON format") {
                example(TemplateDraft.batchExample, identifier: "batchJSONExample")
                Button("Copy whole-plan example", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = TemplateDraft.batchExample
                    message = "Whole-plan example copied. Replace XXXXXXXXXXX with your YouTube video ID."
                }.accessibilityIdentifier("copyBatchExample")
                Text("Wrap multiple templates in templates: […]. Monday and Tuesday are names, not calendar events. Replace XXXXXXXXXXX with your video ID, or omit videoURL.")
            }
            Section {
                Text("The old exercise-name list still works, with 3 sets per exercise. File and text imports are limited to 25 MiB. Full backups belong in Data and backups.")
                Text("Review before saving. Cancel changes nothing. Different videos open a comparison: reject the incoming change, override the library entry or keep both with a variation name. Existing templates and workouts keep their copies.")
            }
        }
        .navigationTitle("Import template")
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { importState.reset(); dismiss() } }
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { enteringText = false } }
        }
    }

    private func readText() {
        enteringText = false
        do {
            try DataTransfer.checkSize(importState.text.utf8.count)
            let data = Data(importState.text.utf8)
            busy = true
            Task {
                defer { busy = false }
                do {
                    let decoded = try await Task.detached(priority: .userInitiated) { try TemplatePack.decode(data) }.value
                    try accept(decoded)
                } catch { showError(error) }
            }
        } catch { showError(error) }
    }

    private func accept(_ decoded: [TemplateDraft]) throws {
        if decoded.count > 1 { importState.review = try TemplatePack.review(decoded, in: context) }
        importState.drafts = decoded
        importState.choices = [:]
        message = nil
    }

    private func stageSingle(_ draft: TemplateDraft) {
        importState.drafts = [draft]
        importState.choices = [:]
        do {
            let comparison = try TemplatePack.review([draft], in: context)
            if comparison.conflicts.isEmpty {
                try TemplatePack.apply(comparison, choices: [:], in: context)
                importState.reset()
                dismiss()
            } else { importState.review = comparison }
        } catch { showError(error) }
    }

    private func showError(_ failure: Error) {
        message = failure.localizedDescription
        error = message
    }

    private func example(_ value: String, identifier: String) -> some View {
        Text(value).font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled).accessibilityIdentifier(identifier)
    }
}

private struct TemplateImportComparison: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var saved: [WorkoutTemplate]
    @State private var review: TemplatePack.Review
    @Environment(TemplateImportState.self) private var importState
    @State private var error: String?
    @State private var showingError = false
    let onBack: () -> Void

    init(review: TemplatePack.Review, onBack: @escaping () -> Void) {
        _review = State(initialValue: review)
        self.onBack = onBack
    }

    private var resolution: TemplatePack.Resolution? { try? TemplatePack.resolve(review, choices: importState.choices) }

    var body: some View {
        List {
            Section {
                Text("\(review.drafts.count) templates. New templates and library changes save together. Existing templates, workouts and calendar assignments are never replaced.")
                if !review.conflicts.isEmpty {
                    Text("\(review.conflicts.count - importState.choices.count) unresolved video differences. Choose an action for each; nothing changes until Import.")
                        .accessibilityIdentifier("importConflictSummary")
                }
                if hasDuplicateNames {
                    Text("Some template names are repeated or already saved. Importing creates additional copies.")
                        .foregroundStyle(.orange).accessibilityIdentifier("duplicateTemplateWarning")
                }
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("importReviewError") }
                Button("Refresh comparisons") { refresh() }.accessibilityIdentifier("refreshImportComparisons")
                Button("Cancel import", role: .cancel) { importState.reset(); dismiss() }.accessibilityIdentifier("cancelTemplateImport")
            }
            ForEach(review.conflicts) { conflict in conflictSection(conflict) }
            preview
        }
        .navigationTitle("Review plan")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Back") { onBack() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Import all") {
                    do { try TemplatePack.apply(review, choices: importState.choices, in: context); importState.reset(); dismiss() }
                    catch { self.error = error.localizedDescription; showingError = true }
                }
                .disabled(resolution == nil)
                .accessibilityIdentifier("importAllTemplates")
            }
        }
        .alert("Could not import", isPresented: $showingError) { Button("OK", role: .cancel) {} } message: { Text(error ?? "") }
    }

    private func conflictSection(_ conflict: TemplatePack.Conflict) -> some View {
        Section {
            definition(conflict.existing, title: conflict.isLibraryEntry ? "Saved library version" : "Other incoming version")
            definition(conflict.incoming, title: "Incoming: \(conflict.templates.joined(separator: ", "))")
            ForEach(TemplatePack.Choice.allCases, id: \.self) { choice in
                Button { select(choice, for: conflict) } label: {
                    Label(choice.title, systemImage: importState.choices[conflict.id] == choice ? "checkmark.circle.fill" : "circle")
                }
                .accessibilityIdentifier("conflictChoice-\(conflict.id)-\(choice.rawValue)")
                .accessibilityValue(importState.choices[conflict.id] == choice ? "Selected" : "Not selected")
            }
        } header: {
            Text(conflict.incoming.name).textCase(nil)
        } footer: {
            Text("Reject uses the saved version in new templates. Override changes the library for future selections, not old templates/workouts. Keep both creates a unique variation name. The preview shows final names once every difference is resolved. Only one version can override a given entry.")
        }
    }

    private func definition(_ definition: TemplatePack.Definition, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(definition.name)
            Text(definition.videoURL ?? "No video").font(.footnote).textSelection(.enabled)
        }
    }

    private var preview: some View {
        ForEach(Array((resolution?.drafts ?? review.drafts).enumerated()), id: \.offset) { _, draft in
            Section(draft.name) {
                ForEach(Array(draft.exercises.enumerated()), id: \.offset) { index, name in
                    HStack {
                        Text("\(name) × \(draft.setCounts[index])")
                        Spacer()
                        VideoButton(name: name, link: draft.videoURLs?[name])
                    }
                }
            }
        }
    }

    private func select(_ choice: TemplatePack.Choice, for conflict: TemplatePack.Conflict) {
        if choice == .replace {
            for other in review.conflicts where other.existing.key == conflict.existing.key && importState.choices[other.id] == .replace {
                importState.choices[other.id] = nil
            }
        }
        importState.choices[conflict.id] = choice
    }

    private func refresh() {
        do {
            review = try TemplatePack.review(review.drafts, in: context)
            importState.review = review
            importState.choices = [:]
            error = nil
        } catch { self.error = error.localizedDescription; showingError = true }
    }

    private var hasDuplicateNames: Bool {
        let names = review.drafts.map { $0.name.lowercased() }
        let existing = Set(saved.map { $0.name.lowercased() })
        return Set(names).count != names.count || names.contains { existing.contains($0) }
    }
}
