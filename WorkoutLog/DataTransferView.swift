import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private struct BackupSelection: Identifiable {
    let id = UUID()
    let backup: DataTransfer.Backup
    let preview: DataTransfer.Preview
}

struct DataTransferView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("weightUnit") private var unit = WeightUnit.kg.rawValue
    @State private var exporting = false
    @State private var importing = false
    @State private var document: JSONDocument?
    @State private var selection: BackupSelection?
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Button("Export backup") { export() }.accessibilityIdentifier("exportBackup")
                Button("Import backup") { importing = true }.accessibilityIdentifier("importBackup")
            } footer: {
                Text("Backups include saved templates, history and the unfinished workout. Text in an unsaved editor is not included.")
            }
            .disabled(busy)
            Section {
                Text("Backups are plain-text JSON containing your workout history. Choose a private Files location. Import adds missing records; it never silently replaces existing data.")
            }
            if busy { ProgressView("Reading backup…") }
            if let message { Section { Text(message).accessibilityIdentifier("transferStatus") } }
        }
        .navigationTitle("Data")
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                      defaultFilename: "WorkoutLog-backup-\(Date().formatted(.iso8601.year().month().day()))") { result in
            switch result {
            case .success: message = "Backup exported. Keep it somewhere safe."
            case .failure(let error): message = DataTransfer.fileErrorMessage(error)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        let backup = try await Task.detached(priority: .userInitiated) {
                            try DataTransfer.decode(DataTransfer.read(url))
                        }.value
                        let preview = try DataTransfer.preview(backup, in: context)
                        selection = BackupSelection(backup: backup, preview: preview)
                    } catch { message = error.localizedDescription }
                }
            case .failure(let error): message = DataTransfer.fileErrorMessage(error)
            }
        }
        .sheet(item: $selection) { selection in
            NavigationStack {
                BackupPreviewView(backup: selection.backup, preview: selection.preview) { imported, preference in
                    if let preference { unit = preference.rawValue }
                    message = "Import complete.\n\(imported.summary)"
                }
            }
        }
    }

    private func export() {
        do {
            let backup = try DataTransfer.snapshot(in: context, unit: WeightUnit(rawValue: unit) ?? .kg)
            document = JSONDocument(data: try DataTransfer.encode(backup))
            exporting = true
        } catch { message = error.localizedDescription }
    }
}

private struct BackupPreviewView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let backup: DataTransfer.Backup
    let preview: DataTransfer.Preview
    let onImported: (DataTransfer.Preview, WeightUnit?) -> Void
    @State private var error: String?

    var body: some View {
        Form {
            Section("Import preview") { Text(preview.summary) }
            Section {
                Text("Existing records stay unchanged. Identical records are skipped. Conflicts or a second unfinished workout stop the entire import.")
                Text(preview.restorePreference ? "New-workout unit will be restored to \(backup.preferredWeightUnit.rawValue)." : "Your current new-workout unit preference will be kept.")
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Import backup")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Import") {
                    do {
                        let (actual, preference) = try DataTransfer.apply(backup, in: context)
                        onImported(actual, preference)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .accessibilityIdentifier("confirmImport")
            }
        }
    }
}
