import SwiftData
import SwiftUI

struct LeaderboardView: View {
    @Environment(LeaderboardStore.self) private var store
    @Query private var rules: [CalendarRule]
    @Query private var walks: [WalkingCompletion]
    @Query private var sessions: [WorkoutSession]
    @Query(sort: \WorkoutTemplate.name) private var templates: [WorkoutTemplate]
    var routeID: UUID? = nil
    @State private var editingProfile = false
    @State private var editingServer = false
    @State private var error: String?

    private var localPayload: SharedProfilePayload? {
        try? store.profileConfig.buildPayload(
            rules: rules,
            sessions: sessions,
            walks: walks,
            templates: templates
        )
    }

    private var rankedEntries: [LeaderboardRankedEntry] {
        store.rankedEntries(localPayload: localPayload)
    }

    private var myEntry: LeaderboardRankedEntry? {
        rankedEntries.first { $0.member.userID == store.profileConfig.userID }
    }

    var body: some View {
        List {
            standingSection
            rankingsSection
        }
        .navigationTitle("Leaderboard")
        .onChange(of: routeID) { _, id in
            if id != nil {
                editingProfile = false
                editingServer = false
            }
        }
        .sheet(isPresented: $editingProfile) {
            NavigationStack {
                ProfileSettingsSheet(config: store.profileConfig) { updated in
                    store.updateProfileConfig(updated)
                }
            }
        }
        .sheet(isPresented: $editingServer) {
            NavigationStack {
                LeaderboardServerSettingsSheet(config: store.serverConfig) { updated in
                    store.updateServerConfig(updated)
                }
            }
        }
        .alert("Sync failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var standingSection: some View {
        Section("Your standing") {
            if let myEntry {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Rank #\(myEntry.rank) of \(rankedEntries.count) · \(myEntry.member.displayName)")
                        .font(.headline)
                        .accessibilityIdentifier("leaderboardMyStanding")
                    Text("Streak: \(myEntry.member.currentStreak)d (Best: \(myEntry.member.bestStreak)d) · 30-day adherence: \(myEntry.member.adherencePercent)%")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("leaderboardMyMetrics")
                }
            }
            Button("Edit profile & shared templates", systemImage: "person.crop.circle") {
                editingProfile = true
            }
            .accessibilityIdentifier("editLeaderboardProfile")

            Button("Server settings", systemImage: "server.rack") {
                editingServer = true
            }
            .accessibilityIdentifier("openServerSettings")

            if store.serverConfig.isConfigured {
                Button {
                    syncNow()
                } label: {
                    Label(store.isSyncing ? "Syncing…" : "Sync with server", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(store.isSyncing || localPayload == nil)
                .accessibilityIdentifier("syncLeaderboardNow")
            }

            if let syncedText = lastSyncedLabel {
                Text(syncedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("leaderboardLastSynced")
            }
        }
    }

    private var rankingsSection: some View {
        Section {
            ForEach(rankedEntries) { entry in
                NavigationLink {
                    LeaderboardProfileDetailView(
                        profile: entry.member,
                        isCurrentUser: entry.member.userID == store.profileConfig.userID
                    )
                } label: {
                    LeaderboardMemberRow(
                        entry: entry,
                        isCurrentUser: entry.member.userID == store.profileConfig.userID
                    )
                }
                .accessibilityIdentifier("leaderboardMember-\(entry.member.displayName)")
            }
        } header: {
            Text("Rankings")
        } footer: {
            Text("Ranked by current plan-adherence streak first, then 30-day relative adherence %, best streak, and completed planned days.")
        }
    }

    private var lastSyncedLabel: String? {
        guard let raw = store.lastSyncedAt,
              let date = try? DataTransfer.date(raw) else { return nil }
        return "Last synced \(ProgressFormat.shortDate(date))"
    }

    private func syncNow() {
        guard let payload = localPayload else { return }
        Task {
            do {
                try await store.sync(localPayload: payload)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct LeaderboardMemberRow: View {
    let entry: LeaderboardRankedEntry
    let isCurrentUser: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("#\(entry.rank)")
                .font(.headline.monospacedDigit())
                .frame(minWidth: 32, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.member.displayName)
                        .font(.headline)
                    if isCurrentUser {
                        Text("You")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
                Text("\(entry.member.currentStreak)d streak · \(entry.member.adherencePercent)% adherence (\(entry.member.completedLast30Days)/\(entry.member.assignedLast30Days))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("\(entry.member.personalRecords.count) PRs · \(entry.member.publishedTemplates.count) templates")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct LeaderboardServerSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let initialConfig: LeaderboardServerConfig
    let onSave: (LeaderboardServerConfig) -> Void
    @State private var baseURLString: String
    @State private var groupToken: String
    @State private var error: String?

    init(config: LeaderboardServerConfig, onSave: @escaping (LeaderboardServerConfig) -> Void) {
        self.initialConfig = config
        self.onSave = onSave
        _baseURLString = State(initialValue: config.baseURLString)
        _groupToken = State(initialValue: config.groupToken)
    }

    var body: some View {
        Form {
            Section {
                TextField("https://gym.example.com", text: $baseURLString)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("serverURLField")
                SecureField("Shared group token", text: $groupToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("serverTokenField")
            } header: {
                Text("Self-hosted server")
            } footer: {
                Text("Leave both fields blank to use the leaderboard locally offline.")
            }
            if !baseURLString.isEmpty || !groupToken.isEmpty {
                Section {
                    Button("Clear server settings", role: .destructive) {
                        onSave(LeaderboardServerConfig())
                        dismiss()
                    }
                    .accessibilityIdentifier("clearServerSettings")
                }
            }
            if let error {
                Section {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("serverValidationError")
                }
            }
        }
        .navigationTitle("Server settings")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .accessibilityIdentifier("saveServerSettings")
            }
        }
    }

    private func save() {
        let trimmedURL = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = groupToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedURL.isEmpty && trimmedToken.isEmpty {
            onSave(LeaderboardServerConfig())
            dismiss()
            return
        }
        let candidate = LeaderboardServerConfig(baseURLString: trimmedURL, groupToken: trimmedToken)
        do {
            _ = try candidate.validatedBaseURL()
            _ = try candidate.validatedToken()
            onSave(candidate)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
