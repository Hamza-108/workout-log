import SwiftUI
import UniformTypeIdentifiers

struct TemplateImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TemplateDraft?
    @State private var choosingFile = false
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        Group {
            if let draft {
                TemplateEditor(draft: draft)
            } else {
                Form {
                    Section {
                        Button("Choose JSON file", systemImage: "doc") { choosingFile = true }
                            .disabled(busy)
                            .accessibilityIdentifier("chooseTemplateJSON")
                        if busy { ProgressView("Reading template…") }
                    }
                    Section("Template JSON format") {
                        Text(TemplateDraft.example)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("templateJSONExample")
                        Button("Copy example", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = TemplateDraft.example
                            message = "Example copied."
                        }
                        .accessibilityIdentifier("copyTemplateExample")
                        Text("name: the workout template name. exercises: an ordered list of exercises. Each exercise needs a name and sets (a whole number from 1 to 99).")
                        Text("The old exercise-name list is also accepted, with 3 sets per exercise. Names must not be empty or repeated. JSON files must be 25 MiB or smaller.")
                        Text("After choosing a file, review and edit it. Only Save creates a new template; Cancel changes nothing.")
                    }
                    if let message { Section { Text(message).accessibilityIdentifier("templateImportStatus") } }
                }
                .navigationTitle("Import template")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
            }
        }
        .task {
            #if DEBUG
            if let testID = ProcessInfo.processInfo.environment["WORKOUT_LOG_TEST_STORE"], UUID(uuidString: testID) != nil,
               let fixture = ProcessInfo.processInfo.environment["WORKOUT_LOG_TEST_TEMPLATE"] {
                do { draft = try TemplateDraft.decode(Data(fixture.utf8)) }
                catch { message = error.localizedDescription }
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
                        draft = try await Task.detached(priority: .userInitiated) {
                            try TemplateDraft.decode(DataTransfer.read(url))
                        }.value
                    } catch { message = error.localizedDescription }
                }
            case .failure(let error): message = DataTransfer.fileErrorMessage(error)
            }
        }
        .interactiveDismissDisabled(busy || draft != nil)
    }
}
