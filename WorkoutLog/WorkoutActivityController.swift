import ActivityKit
import Foundation
import Observation

@MainActor
@Observable
final class WorkoutActivityController {
    var notice: String?

    static func needsStart(sessionID: UUID, activeIDs: Set<UUID>, enabled: Bool) -> Bool {
        enabled && !activeIDs.contains(sessionID)
    }

    static func needsEnd(sessionID: UUID, activeID: UUID?, isOngoing: Bool) -> Bool {
        sessionID != activeID || !isOngoing
    }

    func resume(_ sessionID: UUID) {
        reconcile(activeID: sessionID)
        let enabled = ActivityAuthorizationInfo().areActivitiesEnabled
        let activeIDs = Set(Activity<SessionActivityAttributes>.activities.filter {
            $0.activityState == .active || $0.activityState == .stale
        }.map { $0.attributes.sessionID })
        guard Self.needsStart(sessionID: sessionID, activeIDs: activeIDs, enabled: enabled) else {
            notice = enabled ? nil : "Lock Screen Live Activities are unavailable or disabled. Your workout is still saved; use Resume here."
            return
        }
        do {
            // Request is synchronous: finish cannot race past a pending asynchronous start.
            _ = try Activity.request(attributes: SessionActivityAttributes(sessionID: sessionID),
                                     content: ActivityContent(state: SessionActivityAttributes.ContentState(), staleDate: nil),
                                     pushType: nil)
            notice = nil
        } catch {
            notice = "Could not show Lock Screen status. Logging still works: \(error.localizedDescription)"
        }
    }

    func end(_ sessionID: UUID) {
        endActivities(Activity<SessionActivityAttributes>.activities.filter { $0.attributes.sessionID == sessionID })
    }

    func reconcile(activeID: UUID?) {
        // Capture now, so delayed cleanup cannot end a newly started session's activity.
        endActivities(Activity<SessionActivityAttributes>.activities.filter {
            Self.needsEnd(sessionID: $0.attributes.sessionID, activeID: activeID,
                          isOngoing: $0.activityState == .active || $0.activityState == .stale)
        })
    }

    private func endActivities(_ activities: [Activity<SessionActivityAttributes>]) {
        Task {
            for activity in activities { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
