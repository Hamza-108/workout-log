import XCTest
@testable import WorkoutLog

@MainActor
final class SessionRouteTests: XCTestCase {
    func testHostAppDeclaresSceneLifecycleAndURLScheme() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let manifest = try XCTUnwrap(info["UIApplicationSceneManifest"] as? [String: Any])
        XCTAssertNotNil(manifest["UISceneConfigurations"])
        let types = try XCTUnwrap(info["CFBundleURLTypes"] as? [[String: Any]])
        XCTAssertEqual(types.first?["CFBundleURLSchemes"] as? [String], ["workoutlog"])
    }

    func testSessionURLRoundTrip() throws {
        let id = UUID()
        let url = try XCTUnwrap(SessionRoute.url(for: id))
        XCTAssertEqual(SessionRoute.sessionID(from: url), id)
    }

    func testRejectMalformedAndAmbiguousRoutes() throws {
        for text in ["https://session/\(UUID())", "workoutlog://other/\(UUID())",
                     "workoutlog://session", "workoutlog://session/not-a-uuid",
                     "workoutlog://session/\(UUID())/extra", "workoutlog://session/\(UUID())?finish=true",
                     "workoutlog://session/\(UUID())#finish", "workoutlog://user@session/\(UUID())",
                     "workoutlog://session:1234/\(UUID())"] {
            XCTAssertNil(SessionRoute.sessionID(from: try XCTUnwrap(URL(string: text))), text)
        }
    }

    func testDisabledActivitiesAndDuplicateResumeDoNotStart() {
        let id = UUID()
        XCTAssertFalse(WorkoutActivityController.needsStart(sessionID: id, activeIDs: [], enabled: false))
        XCTAssertFalse(WorkoutActivityController.needsStart(sessionID: id, activeIDs: [id], enabled: true))
        XCTAssertTrue(WorkoutActivityController.needsStart(sessionID: id, activeIDs: [UUID()], enabled: true))
        XCTAssertTrue(WorkoutActivityController.needsStart(sessionID: id, activeIDs: [], enabled: true))
    }

    func testActivityOnlyCarriesSessionID() throws {
        let id = UUID()
        let data = try JSONEncoder().encode(SessionActivityAttributes(sessionID: id))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["sessionID"])
        XCTAssertEqual(object["sessionID"] as? String, id.uuidString)
        let state = try JSONEncoder().encode(SessionActivityAttributes.ContentState())
        XCTAssertEqual(String(decoding: state, as: UTF8.self), "{}")
    }
}
