import Foundation

struct LeaderboardSyncClient: Sendable {
    static let maximumResponseBytes = 512 * 1024

    private let session: URLSession

    init(session: URLSession = Self.defaultSession()) {
        self.session = session
    }

    static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }

    static func endpointURL(baseURL: URL, path: String) throws -> URL {
        let baseString = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanPath = path.hasPrefix("/") ? path : "/" + path
        guard let url = URL(string: baseString + cleanPath) else {
            throw LogError(message: "Could not construct endpoint URL.")
        }
        return url
    }

    func syncProfile(
        _ payload: SharedProfilePayload,
        config: LeaderboardProfileConfig,
        server: LeaderboardServerConfig
    ) async throws -> LeaderboardResponse {
        try payload.validate()
        let baseURL = try server.validatedBaseURL()
        let token = try server.validatedToken()
        let url = try Self.endpointURL(baseURL: baseURL, path: "/api/v1/profile")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(payload)
        guard body.count <= Self.maximumResponseBytes else {
            throw LogError(message: "Profile payload exceeds the 512 KiB limit.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthHeaders(to: &request, config: config, token: token)

        return try await performLeaderboardRequest(request)
    }

    func fetchLeaderboard(
        config: LeaderboardProfileConfig,
        server: LeaderboardServerConfig
    ) async throws -> LeaderboardResponse {
        let baseURL = try server.validatedBaseURL()
        let token = try server.validatedToken()
        let url = try Self.endpointURL(baseURL: baseURL, path: "/api/v1/leaderboard")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuthHeaders(to: &request, config: config, token: token)

        return try await performLeaderboardRequest(request)
    }

    func deleteProfile(
        config: LeaderboardProfileConfig,
        server: LeaderboardServerConfig
    ) async throws {
        let baseURL = try server.validatedBaseURL()
        let token = try server.validatedToken()
        let url = try Self.endpointURL(baseURL: baseURL, path: "/api/v1/profile")

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        applyAuthHeaders(to: &request, config: config, token: token)

        let (data, response) = try await session.data(for: request)
        guard data.count <= Self.maximumResponseBytes else {
            throw LogError(message: "Server response exceeds the 512 KiB limit.")
        }
        guard let http = response as? HTTPURLResponse else {
            throw LogError(message: "Invalid response from server.")
        }
        guard (200...204).contains(http.statusCode) else {
            throw statusError(http.statusCode)
        }
    }

    // MARK: - Private

    private func applyAuthHeaders(
        to request: inout URLRequest,
        config: LeaderboardProfileConfig,
        token: String
    ) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(config.userID.uuidString, forHTTPHeaderField: "X-User-ID")
        request.setValue(config.clientToken.uuidString, forHTTPHeaderField: "X-Client-Token")
    }

    private func performLeaderboardRequest(_ request: URLRequest) async throws -> LeaderboardResponse {
        let (data, response) = try await session.data(for: request)
        guard data.count <= Self.maximumResponseBytes else {
            throw LogError(message: "Server response exceeds the 512 KiB limit.")
        }
        guard let http = response as? HTTPURLResponse else {
            throw LogError(message: "Invalid response from server.")
        }
        guard http.statusCode == 200 else {
            throw statusError(http.statusCode)
        }
        let decoded = try JSONDecoder().decode(LeaderboardResponse.self, from: data)
        try decoded.validate()
        return decoded
    }

    private func statusError(_ code: Int) -> LogError {
        switch code {
        case 401:
            return LogError(message: "Unauthorized (HTTP 401). Check your group token.")
        case 403:
            return LogError(message: "Forbidden (HTTP 403). Client token does not match this user ID.")
        case 413:
            return LogError(message: "Profile payload is too large (HTTP 413).")
        case 422:
            return LogError(message: "Server rejected the profile payload (HTTP 422).")
        default:
            return LogError(message: "Server returned HTTP \(code).")
        }
    }
}
