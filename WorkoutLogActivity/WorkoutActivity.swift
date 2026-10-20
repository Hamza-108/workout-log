import ActivityKit
import SwiftUI
import WidgetKit

@main
struct WorkoutActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: "dumbbell.fill").font(.title)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Session in Progress").font(.headline)
                    Text("Tap to resume logging").font(.subheadline)
                }
                Spacer()
                Image(systemName: "chevron.right")
            }
            .padding()
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
            .foregroundStyle(.white)
            .widgetURL(SessionRoute.url(for: context.attributes.sessionID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "dumbbell.fill") }
                DynamicIslandExpandedRegion(.center) { Text("Session in Progress").font(.headline) }
                DynamicIslandExpandedRegion(.bottom) { Text("Tap to resume logging") }
            } compactLeading: {
                Image(systemName: "dumbbell.fill")
            } compactTrailing: {
                Image(systemName: "record.circle").foregroundStyle(.green)
            } minimal: {
                Image(systemName: "dumbbell.fill")
            }
            .widgetURL(SessionRoute.url(for: context.attributes.sessionID))
        }
    }
}
