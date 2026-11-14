import SwiftData
import SwiftUI

struct LeaderboardProfileDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(TemplateImportState.self) private var importState
    @AppStorage("weightUnit") private var preferredUnit = WeightUnit.kg.rawValue
    let profile: SharedProfilePayload
    let isCurrentUser: Bool
    @State private var importingTemplates = false
    @State private var error: String?

    private var unit: WeightUnit {
        WeightUnit(rawValue: preferredUnit) ?? .kg
    }

    private var adherenceLabel: String {
        if profile.assignedLast30Days > 0 {
            return "30-day adherence: \(profile.adherencePercent)% (\(profile.completedLast30Days)/\(profile.assignedLast30Days) planned days)"
        }
        return "30-day adherence: No past assigned days yet"
    }

    var body: some View {
        List {
            overviewSection
            personalRecordsSection
            publishedTemplatesSection
        }
        .navigationTitle(profile.displayName)
        .sheet(isPresented: $importingTemplates) {
            NavigationStack { TemplateImportView() }
        }
        .alert("Could not import", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var overviewSection: some View {
        Section("Overview") {
            HStack {
                Text(profile.displayName).font(.headline)
                    .accessibilityIdentifier("profileDisplayName")
                if isCurrentUser {
                    Text("You")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
            }
            Text("Current streak: \(profile.currentStreak)d · Best: \(profile.bestStreak)d")
                .font(.subheadline.weight(.medium))
                .accessibilityIdentifier("profileStreak")
            Text(adherenceLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("profileAdherence")
            if let updated = try? DataTransfer.date(profile.updatedAt) {
                Text("Updated \(ProgressFormat.shortDate(updated))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var personalRecordsSection: some View {
        Section("Personal records") {
            if profile.personalRecords.isEmpty {
                Text("No personal records shared.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("profileNoPRs")
            } else {
                ForEach(profile.personalRecords) { record in
                    ProfilePersonalRecordRow(record: record, displayUnit: unit)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("profilePR-\(record.exercise)")
                }
            }
        }
    }

    private var publishedTemplatesSection: some View {
        Section("Published templates") {
            if profile.publishedTemplates.isEmpty {
                Text("No templates published.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("profileNoTemplates")
            } else {
                if profile.publishedTemplates.count > 1 {
                    Button {
                        importAllTemplates()
                    } label: {
                        Label("Import all templates (\(profile.publishedTemplates.count))", systemImage: "square.and.arrow.down.on.square")
                    }
                    .accessibilityIdentifier("importAllProfileTemplates")
                }
                ForEach(Array(profile.publishedTemplates.enumerated()), id: \.offset) { _, shared in
                    ProfilePublishedTemplateRow(shared: shared) {
                        importSingleTemplate(shared)
                    }
                }
            }
        }
    }

    private func importSingleTemplate(_ shared: SharedTemplate) {
        do {
            let draft = try shared.toDraft()
            importState.reset()
            importState.drafts = [draft]
            importingTemplates = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func importAllTemplates() {
        do {
            let drafts = try profile.validatedTemplateDrafts()
            importState.reset()
            importState.drafts = drafts
            if drafts.count > 1 {
                importState.review = try TemplatePack.review(drafts, in: context)
            }
            importingTemplates = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ProfilePersonalRecordRow: View {
    let record: SharedPersonalRecord
    let displayUnit: WeightUnit

    private var convertedWeight: Double {
        record.unit.convert(record.weight, to: displayUnit) ?? record.weight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(record.exercise).font(.headline)
            Text("\(ProgressFormat.weight(convertedWeight, displayUnit)) · \(record.reps) reps · RPE \(ProgressFormat.number(record.rpe))")
                .font(.subheadline)
            if record.unit != displayUnit {
                Text("Logged as \(ProgressFormat.weight(record.weight, record.unit))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ProfilePublishedTemplateRow: View {
    let shared: SharedTemplate
    let onImport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(shared.name).font(.headline)
            Text(shared.exercises.map { "\($0.name) × \($0.sets)" }.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Import template", systemImage: "square.and.arrow.down", action: onImport)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("importProfileTemplate-\(shared.name)")
        }
        .padding(.vertical, 2)
    }
}

struct ProfileSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \WorkoutTemplate.name) private var templates: [WorkoutTemplate]
    @Query private var rules: [CalendarRule]
    @Query private var walks: [WalkingCompletion]
    @Query private var sessions: [WorkoutSession]
    let initialConfig: LeaderboardProfileConfig
    let onSave: (LeaderboardProfileConfig) -> Void
    @State private var displayName: String
    @State private var sharePRs: Bool
    @State private var selectedTemplateIDs: Set<UUID>
    @State private var error: String?

    init(config: LeaderboardProfileConfig, onSave: @escaping (LeaderboardProfileConfig) -> Void) {
        self.initialConfig = config
        self.onSave = onSave
        _displayName = State(initialValue: config.displayName)
        _sharePRs = State(initialValue: config.sharePersonalRecords)
        _selectedTemplateIDs = State(initialValue: Set(config.publishedTemplateIDs))
    }

    private var draftConfig: LeaderboardProfileConfig {
        let cleanName = (try? SharedProfilePayload.validateDisplayName(displayName)) ?? initialConfig.displayName
        return LeaderboardProfileConfig(
            userID: initialConfig.userID,
            clientToken: initialConfig.clientToken,
            displayName: cleanName,
            sharePersonalRecords: sharePRs,
            publishedTemplateIDs: Array(selectedTemplateIDs)
        )
    }

    private var previewPayload: SharedProfilePayload? {
        try? draftConfig.buildPayload(
            rules: rules,
            sessions: sessions,
            walks: walks,
            templates: templates
        )
    }

    var body: some View {
        Form {
            Section("Display name") {
                TextField("Your name on the leaderboard", text: $displayName)
                    .accessibilityIdentifier("profileDisplayNameField")
            }
            Section {
                Toggle("Share personal records (PRs)", isOn: $sharePRs)
                    .accessibilityIdentifier("profileSharePRsToggle")
            } header: {
                Text("Privacy")
            } footer: {
                Text("Only your heaviest completed working set per exercise is shared when enabled. Body weights and unfinished workouts are never shared.")
            }
            Section {
                if templates.isEmpty {
                    Text("No saved templates yet. Create a template in Templates to publish it.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(templates) { template in
                        Button {
                            toggleTemplate(template.id)
                        } label: {
                            HStack {
                                Text(template.name).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: selectedTemplateIDs.contains(template.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedTemplateIDs.contains(template.id) ? Color.accentColor : .secondary)
                            }
                        }
                        .accessibilityIdentifier("profileTemplateToggle-\(template.name)")
                        .accessibilityValue(selectedTemplateIDs.contains(template.id) ? "Selected" : "Not selected")
                    }
                }
            } header: {
                Text("Published templates")
            } footer: {
                Text("Friends can view and import only the templates you select here.")
            }
            if let previewPayload {
                Section {
                    NavigationLink("Preview shared profile") {
                        LeaderboardProfileDetailView(profile: previewPayload, isCurrentUser: true)
                    }
                    .accessibilityIdentifier("previewSharedProfile")
                }
            }
            if let error {
                Section {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("profileValidationError")
                }
            }
        }
        .navigationTitle("My profile")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .accessibilityIdentifier("saveProfileSettings")
            }
        }
    }

    private func toggleTemplate(_ id: UUID) {
        if selectedTemplateIDs.contains(id) {
            selectedTemplateIDs.remove(id)
        } else {
            selectedTemplateIDs.insert(id)
        }
    }

    private func save() {
        do {
            let cleanName = try SharedProfilePayload.validateDisplayName(displayName)
            let validIDs = templates.map(\.id).filter { selectedTemplateIDs.contains($0) }
            let updated = LeaderboardProfileConfig(
                userID: initialConfig.userID,
                clientToken: initialConfig.clientToken,
                displayName: cleanName,
                sharePersonalRecords: sharePRs,
                publishedTemplateIDs: validIDs
            )
            onSave(updated)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
