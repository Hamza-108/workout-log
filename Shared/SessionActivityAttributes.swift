import ActivityKit
import Foundation

struct SessionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {}
    let sessionID: UUID
}

enum SessionRoute {
    static func url(for id: UUID) -> URL? {
        URL(string: "workoutlog://session/\(id.uuidString)")
    }

    static func sessionID(from url: URL) -> UUID? {
        guard url.scheme == "workoutlog", url.host == "session",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              url.pathComponents.count == 2 else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}
