import SwiftData
import SwiftUI

@main
struct WorkoutLogApp: App {
    @State private var storage: Result<(container: ModelContainer, context: ModelContext), Error>
    @State private var saveError: String?

    init() {
        _storage = State(initialValue: Result {
            let schema = Schema([WorkoutTemplate.self, WorkoutSession.self])
            let configuration: ModelConfiguration
            #if DEBUG
            if let testID = ProcessInfo.processInfo.environment["WORKOUT_LOG_TEST_STORE"], UUID(uuidString: testID) != nil {
                configuration = ModelConfiguration(schema: schema, url: FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutLog-\(testID).store"), cloudKitDatabase: .none)
            } else {
                configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            }
            #else
            configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            #endif
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            return (container, context)
        })
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let saveError {
                    ContentUnavailableView {
                        Label("Change not saved", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("\(saveError)\n\nYour previously saved data has been reloaded. The failed change was not kept.")
                    } actions: {
                        Button("Return to templates") { self.saveError = nil }
                    }
                } else {
                    switch storage {
                    case .success(let data):
                        TabView {
                            NavigationStack { TemplatesView() }
                                .tabItem { Label("Templates", systemImage: "list.bullet.rectangle") }
                            NavigationStack { HistoryView() }
                                .tabItem { Label("History", systemImage: "clock") }
                        }
                        .environment(\.modelContext, data.context)
                        .modelContainer(data.container)
                        .id(ObjectIdentifier(data.context))
                    case .failure(let error):
                        ContentUnavailableView {
                            Label("Could not open workout data", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text("Your data has not been reset. Close and reopen the app to try again. Do not uninstall the app.\n\n\(error.localizedDescription)")
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .workoutSaveFailed)) { notification in
                guard case .success(let data) = storage,
                      let failed = notification.object as? ModelContext, failed === data.context else { return }
                let replacement = ModelContext(data.container)
                replacement.autosaveEnabled = false
                storage = .success((data.container, replacement))
                saveError = notification.userInfo?["error"] as? String ?? "The change could not be saved."
            }
        }
    }
}
