import SwiftUI

@main
struct WorkoutLogApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                VStack(spacing: 16) {
                    Image(systemName: "dumbbell.fill")
                        .font(.system(size: 48))
                        .accessibilityHidden(true)
                    Text("Ready to log your workouts")
                        .font(.title2)
                        .multilineTextAlignment(.center)
                    Text("Setup build — workout logging and templates are coming next.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .navigationTitle("Workout Log")
            }
        }
    }
}
