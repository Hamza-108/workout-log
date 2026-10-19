import SwiftData
import SwiftUI

@main
struct WorkoutLogApp: App {
    private let storage: Result<ModelContainer, Error>

    init() {
        storage = Result {
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
            container.mainContext.autosaveEnabled = false
            return container
        }
    }

    var body: some Scene {
        WindowGroup {
            switch storage {
            case .success(let container):
                TabView {
                    NavigationStack { TemplatesView() }
                        .tabItem { Label("Templates", systemImage: "list.bullet.rectangle") }
                    NavigationStack { HistoryView() }
                        .tabItem { Label("History", systemImage: "clock") }
                }
                .modelContainer(container)
            case .failure(let error):
                ContentUnavailableView {
                    Label("Could not open workout data", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Your data has not been reset. Close and reopen the app to try again. Do not uninstall the app.\n\n\(error.localizedDescription)")
                }
            }
        }
    }
}
