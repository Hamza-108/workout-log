import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct TemplateImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var drafts: [TemplateDraft]?
    @State private var text = ""
    @State private var choosingFile = false
    @State private var busy = false
    @State private var message: String?
    @FocusState private var enteringText: Bool

    var body: some View {
        Group {
            if let drafts {
                if drafts.count == 1 { TemplateEditor(draft: drafts[0]) }
                else { TemplateBatchPreview(drafts: drafts) { self.drafts = nil } }
            } else {
                inputForm
            }
        }
        .task {
            #if DEBUG
            if let testID = ProcessInfo.processInfo.environment["WORKOUT_LOG_TEST_STORE"], UUID(uuidString: testID) != nil,
               let fixture = ProcessInfo.processInfo.environment["WORKOUT_LOG_TEST_TEMPLATE"] {
                load(Data(fixture.utf8))
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
                        try TemplatePack.checkLibrary(decoded, in: context)
                        drafts = decoded
                        message = nil
                    } catch { message = error.localizedDescription }
                }
            case .failure(let error): message = DataTransfer.fileErrorMessage(error)
            }
        }
        .interactiveDismissDisabled(busy || drafts != nil)
    }

    private var inputForm: some View {
        Form {
            Section {
                Button("Choose JSON file", systemImage: "doc") { choosingFile = true }
                    .disabled(busy).accessibilityIdentifier("chooseTemplateJSON")
                if busy { ProgressView("Reading templates…") }
            }
            Section("Or enter / paste JSON") {
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($enteringText).frame(minHeight: 150)
                    .accessibilityLabel("Template JSON text")
                    .accessibilityIdentifier("templateJSONInput")
                Button("Review JSON") {
                    enteringText = false
                    do {
                        try DataTransfer.checkSize(text.utf8.count)
                        load(Data(text.utf8))
                    } catch { message = error.localizedDescription }
                }
                .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                Text("Review before saving. Cancel changes nothing. Imports create new templates and reuse matching library exercises; conflicting exercise videos stop the import.")
            }
            if let message { Section { Text(message).accessibilityIdentifier("templateImportStatus") } }
        }
        .navigationTitle("Import template")
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { enteringText = false } }
        }
    }

    private func example(_ value: String, identifier: String) -> some View {
        Text(value).font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled).accessibilityIdentifier(identifier)
    }

    private func load(_ data: Data) {
        do {
            let decoded = try TemplatePack.decode(data)
            try TemplatePack.checkLibrary(decoded, in: context)
            drafts = decoded
            message = nil
        } catch { message = error.localizedDescription }
    }
}

private struct TemplateBatchPreview: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var saved: [WorkoutTemplate]
    let drafts: [TemplateDraft]
    let onBack: () -> Void
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Text("\(drafts.count) templates. Import all creates new templates and saves all exercises together. Existing templates and workouts are never replaced.")
                if hasDuplicateNames {
                    Text("Some template names are repeated or already saved. Importing creates additional copies.")
                        .foregroundStyle(.orange).accessibilityIdentifier("duplicateTemplateWarning")
                }
            }
            ForEach(Array(drafts.enumerated()), id: \.offset) { _, draft in
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
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Review plan")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Back") { onBack() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Import all") {
                    do { try TemplatePack.apply(drafts, in: context); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.accessibilityIdentifier("importAllTemplates")
            }
        }
    }

    private var hasDuplicateNames: Bool {
        let names = drafts.map { $0.name.lowercased() }
        let existing = Set(saved.map { $0.name.lowercased() })
        return Set(names).count != names.count || names.contains { existing.contains($0) }
    }
}
