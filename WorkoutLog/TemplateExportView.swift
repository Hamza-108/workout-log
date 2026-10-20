import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct TemplateExportView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \WorkoutTemplate.name) private var templates: [WorkoutTemplate]
    @State private var selected: Set<UUID> = []
    @State private var initialized = false
    @State private var exporting = false
    @State private var document: JSONDocument?
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Button("Select all") { selected = Set(templates.map(\.id)) }
                Button("Deselect all") { selected = [] }
            }
            Section("Templates to export") {
                ForEach(templates) { template in
                    Button {
                        if selected.contains(template.id) { selected.remove(template.id) }
                        else { selected.insert(template.id) }
                    } label: {
                        HStack {
                            Text(template.name)
                            Spacer()
                            if selected.contains(template.id) { Image(systemName: "checkmark") }
                        }
                    }
                    .accessibilityIdentifier("exportTemplate-\(template.name)")
                    .accessibilityValue(selected.contains(template.id) ? "Selected" : "Not selected")
                }
            }
            Section {
                Button("Save JSON file", systemImage: "doc") {
                    do {
                        document = JSONDocument(data: try exportData())
                        exporting = true
                    } catch { message = error.localizedDescription }
                }.accessibilityIdentifier("saveTemplateJSON")
                Button("Copy JSON", systemImage: "doc.on.doc") {
                    do {
                        UIPasteboard.general.string = String(decoding: try exportData(), as: UTF8.self)
                        message = "Template JSON copied."
                    } catch { message = error.localizedDescription }
                }.accessibilityIdentifier("copyTemplateJSON")
            } footer: {
                Text("Only selected templates, exercise definitions, set counts and video links are shared. No workout history, database IDs or app identity is included. Import creates new copies. Legacy name-only exercises export with 3 sets.")
            }
            .disabled(selected.isEmpty)
            if let message { Section { Text(message).accessibilityIdentifier("templateExportStatus") } }
        }
        .navigationTitle("Export templates")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .onAppear {
            if !initialized { selected = Set(templates.map(\.id)); initialized = true }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "WorkoutLog-templates") { result in
            switch result {
            case .success: message = "Templates exported."
            case .failure(let error): message = DataTransfer.fileErrorMessage(error)
            }
        }
    }

    private func exportData() throws -> Data {
        let drafts = templates.filter { selected.contains($0.id) }.map(TemplatePack.draft)
        return try TemplatePack.encode(drafts)
    }
}
