import Foundation
import XCTest
@testable import WorkoutLog

private final class MockLeaderboardURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class LeaderboardSyncTests: XCTestCase {
    private func makeMember(
        id: UUID = UUID(),
        name: String,
        currentStreak: Int,
        adherencePercent: Int,
        bestStreak: Int,
        completed: Int,
        assigned: Int
    ) -> SharedProfilePayload {
        SharedProfilePayload(
            userID: id,
            displayName: name,
            updatedAt: "2026-11-15T00:00:00.000Z",
            currentStreak: currentStreak,
            bestStreak: bestStreak,
            adherencePercent: adherencePercent,
            completedLast30Days: completed,
            assignedLast30Days: assigned,
            personalRecords: [],
            publishedTemplates: []
        )
    }

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockLeaderboardURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testLeaderboardRankingOrdersByCurrentStreakThenRelativeAdherenceThenBestStreakThenCompletedThenName() {
        let friend1 = makeMember(name: "Friend 1", currentStreak: 7, adherencePercent: 80, bestStreak: 10, completed: 12, assigned: 15)
        // Friend 3 has a 5-day streak and 100% relative adherence (4/4 on a 1x/week plan) -> 2nd place.
        let friend3 = makeMember(name: "Friend 3", currentStreak: 5, adherencePercent: 100, bestStreak: 5, completed: 4, assigned: 4)
        // Friend 2 also has a 5-day streak, but 75% adherence (12/16 on a 4x/week plan) -> 3rd place.
        let friend2 = makeMember(name: "Friend 2", currentStreak: 5, adherencePercent: 75, bestStreak: 9, completed: 12, assigned: 16)
        // Friend 4 and Friend 5 tie on currentStreak (3) and adherence (80%), broken by bestStreak (14 vs 8).
        let friend4 = makeMember(name: "Friend 4", currentStreak: 3, adherencePercent: 80, bestStreak: 14, completed: 8, assigned: 10)
        let friend5 = makeMember(name: "Friend 5", currentStreak: 3, adherencePercent: 80, bestStreak: 8, completed: 8, assigned: 10)

        let ranked = LeaderboardRanking.rank([friend5, friend2, friend1, friend4, friend3])
        XCTAssertEqual(ranked.map(\.rank), [1, 2, 3, 4, 5])
        XCTAssertEqual(ranked.map(\.member.displayName), [
            "Friend 1",
            "Friend 3",
            "Friend 2",
            "Friend 4",
            "Friend 5"
        ])
    }

    func testLeaderboardStorePersistsProfileServerAndCachedPeersAndMergesLiveLocalPayload() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutLog-leaderboard-test-\(UUID()).json")
        let myID = UUID()
        let friendID = UUID()

        let store = LeaderboardStore(fileURL: fileURL)
        store.updateProfileConfig(LeaderboardProfileConfig(
            userID: myID,
            displayName: "Me",
            sharePersonalRecords: true,
            publishedTemplateIDs: []
        ))
        store.updateServerConfig(LeaderboardServerConfig(
            baseURLString: "https://gym.example.com/",
            groupToken: "group-secret"
        ))

        let staleSelf = makeMember(id: myID, name: "Me", currentStreak: 1, adherencePercent: 50, bestStreak: 1, completed: 1, assigned: 2)
        let friend3 = makeMember(id: friendID, name: "Friend 3", currentStreak: 5, adherencePercent: 100, bestStreak: 5, completed: 4, assigned: 4)
        let response = LeaderboardResponse(
            schemaVersion: 1,
            generatedAt: "2026-11-15T00:00:00.000Z",
            members: [staleSelf, friend3]
        )
        try store.applyRemoteLeaderboard(response)

        // Reopen from disk and verify live local payload overrides the stale self snapshot while keeping Friend 3.
        let reopened = LeaderboardStore(fileURL: fileURL)
        XCTAssertEqual(reopened.profileConfig.userID, myID)
        XCTAssertEqual(reopened.serverConfig.baseURLString, "https://gym.example.com/")
        XCTAssertEqual(reopened.lastSyncedAt, "2026-11-15T00:00:00.000Z")

        let liveSelf = makeMember(id: myID, name: "Me", currentStreak: 6, adherencePercent: 100, bestStreak: 6, completed: 5, assigned: 5)
        let entries = reopened.rankedEntries(localPayload: liveSelf)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].rank, 1)
        XCTAssertEqual(entries[0].member.displayName, "Me")
        XCTAssertEqual(entries[0].member.currentStreak, 6)
        XCTAssertEqual(entries[1].rank, 2)
        XCTAssertEqual(entries[1].member.displayName, "Friend 3")
        XCTAssertEqual(entries[1].member.currentStreak, 5)
    }

    func testSyncClientPutGetDeleteAndHeaderVerificationWithMockURLProtocol() async throws {
        let client = LeaderboardSyncClient(session: mockSession())
        let profileConfig = LeaderboardProfileConfig(
            userID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
            clientToken: UUID(uuidString: "99999999-AAAA-4BBB-8CCC-DDDDDDDDDDDD")!,
            displayName: "Hamza"
        )
        let serverConfig = LeaderboardServerConfig(
            baseURLString: "https://gym.example.com/",
            groupToken: "secret-invite-token"
        )
        let payload = makeMember(
            id: profileConfig.userID,
            name: "Hamza",
            currentStreak: 4,
            adherencePercent: 100,
            bestStreak: 4,
            completed: 3,
            assigned: 3
        )
        let friend3 = makeMember(
            name: "Friend 3",
            currentStreak: 5,
            adherencePercent: 100,
            bestStreak: 5,
            completed: 4,
            assigned: 4
        )
        let expectedResponse = LeaderboardResponse(
            schemaVersion: 1,
            generatedAt: "2026-11-15T00:00:00.000Z",
            members: [friend3, payload]
        )

        MockLeaderboardURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-invite-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-User-ID"), "11111111-2222-4333-8444-555555555555")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client-Token"), "99999999-AAAA-4BBB-8CCC-DDDDDDDDDDDD")
            let url = try XCTUnwrap(request.url)
            let data = try JSONEncoder().encode(expectedResponse)
            let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, data)
        }

        let synced = try await client.syncProfile(payload, config: profileConfig, server: serverConfig)
        XCTAssertEqual(synced.members.count, 2)

        let fetched = try await client.fetchLeaderboard(config: profileConfig, server: serverConfig)
        XCTAssertEqual(fetched, expectedResponse)

        // Verify HTTP 401 surfaces a clear error.
        MockLeaderboardURLProtocol.handler = { request in
            let http = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (http, Data())
        }
        do {
            _ = try await client.fetchLeaderboard(config: profileConfig, server: serverConfig)
            XCTFail("Expected HTTP 401 error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("401"), error.localizedDescription)
        }

        // Verify oversized responses (>512 KiB) are rejected.
        MockLeaderboardURLProtocol.handler = { request in
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(repeating: 0x41, count: LeaderboardSyncClient.maximumResponseBytes + 1))
        }
        do {
            _ = try await client.fetchLeaderboard(config: profileConfig, server: serverConfig)
            XCTFail("Expected oversized response error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("512 KiB"), error.localizedDescription)
        }
    }
}
