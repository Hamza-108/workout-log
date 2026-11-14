import Foundation
import Observation

@Observable
@MainActor
final class LeaderboardStore {
    struct PersistedState: Codable, Equatable, Sendable {
        var schemaVersion: Int = 1
        var profileConfig: LeaderboardProfileConfig
        var serverConfig: LeaderboardServerConfig
        var cachedMembers: [SharedProfilePayload]
        var lastSyncedAt: String?
    }

    private let fileURL: URL
    var profileConfig: LeaderboardProfileConfig
    var serverConfig: LeaderboardServerConfig
    var cachedMembers: [SharedProfilePayload]
    var lastSyncedAt: String?
    var isSyncing = false

    init(fileURL: URL? = nil) {
        let resolvedURL = fileURL ?? Self.defaultFileURL()
        self.fileURL = resolvedURL
        if let data = try? Data(contentsOf: resolvedURL),
           let decoded = try? JSONDecoder().decode(PersistedState.self, from: data),
           decoded.schemaVersion == 1 {
            self.profileConfig = decoded.profileConfig
            self.serverConfig = decoded.serverConfig
            self.cachedMembers = decoded.cachedMembers.filter { (try? $0.validate()) != nil }
            self.lastSyncedAt = decoded.lastSyncedAt
        } else {
            self.profileConfig = LeaderboardProfileConfig()
            self.serverConfig = LeaderboardServerConfig()
            self.cachedMembers = []
            self.lastSyncedAt = nil
        }
    }

    static func defaultFileURL() -> URL {
        #if DEBUG
        if let testID = ProcessInfo.processInfo.environment["WORKOUT_LOG_TEST_STORE"]
            ?? UserDefaults.standard.string(forKey: "WorkoutLogUITestStore"),
           UUID(uuidString: testID) != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutLog-leaderboard-\(testID).json")
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("leaderboard-state.json")
    }

    func updateProfileConfig(_ updated: LeaderboardProfileConfig) {
        profileConfig = updated
        persist()
    }

    func updateServerConfig(_ updated: LeaderboardServerConfig) {
        serverConfig = updated
        persist()
    }

    func applyRemoteLeaderboard(_ response: LeaderboardResponse) throws {
        try response.validate()
        cachedMembers = response.members
        lastSyncedAt = response.generatedAt
        persist()
    }

    func rankedEntries(localPayload: SharedProfilePayload?) -> [LeaderboardRankedEntry] {
        var members = cachedMembers.filter { $0.userID != profileConfig.userID }
        if let localPayload, (try? localPayload.validate()) != nil {
            members.append(localPayload)
        }
        return LeaderboardRanking.rank(members)
    }

    func sync(
        localPayload: SharedProfilePayload,
        using client: LeaderboardSyncClient = LeaderboardSyncClient()
    ) async throws {
        isSyncing = true
        defer { isSyncing = false }
        let response = try await client.syncProfile(localPayload, config: profileConfig, server: serverConfig)
        try applyRemoteLeaderboard(response)
    }

    private func persist() {
        let state = PersistedState(
            schemaVersion: 1,
            profileConfig: profileConfig,
            serverConfig: serverConfig,
            cachedMembers: cachedMembers,
            lastSyncedAt: lastSyncedAt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
