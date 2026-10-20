import SwiftData
import SwiftUI

@main
struct WorkoutLogApp: App {
    @State private var storage: Result<(container: ModelContainer, context: ModelContext), Error>
    @State private var saveError: String?
    @State private var activities = WorkoutActivityController()

    init() {
        _storage = State(initialValue: Result {
            let schema = Schema([WorkoutTemplate.self, WorkoutSession.self, LibraryExercise.self, LibrarySetup.self, CalendarRule.self, WalkingCompletion.self])
            let configuration: ModelConfiguration
            #if DEBUG
            // OS-initiated cold launches do not inherit XCTest's environment.
            if let testID = ProcessInfo.processInfo.environment["WORKOUT_LOG_TEST_STORE"], UUID(uuidString: testID) != nil {
                UserDefaults.standard.set(testID, forKey: "WorkoutLogUITestStore")
            }
            if let testID = ProcessInfo.processInfo.environment["WORKOUT_LOG_TEST_STORE"] ?? UserDefaults.standard.string(forKey: "WorkoutLogUITestStore"), UUID(uuidString: testID) != nil {
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
            #if DEBUG
            if let testID = ProcessInfo.processInfo.environment["WORKOUT_LOG_TEST_STORE"], UUID(uuidString: testID) != nil,
               let fixture = ProcessInfo.processInfo.environment["WORKOUT_LOG_TEST_BACKUP"],
               try context.fetchCount(FetchDescriptor<WorkoutTemplate>()) == 0,
               try context.fetchCount(FetchDescriptor<WorkoutSession>()) == 0 {
                let (_, preference) = try DataTransfer.apply(DataTransfer.decode(Data(fixture.utf8)), in: context)
                if let preference { UserDefaults.standard.set(preference.rawValue, forKey: "weightUnit") }
            }
            #endif
            try LibraryExercise.seedOnce(in: context)
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
                        WorkoutHomeView()
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
            .environment(activities)
            .onReceive(NotificationCenter.default.publisher(for: .workoutSaveFailed)) { notification in
                guard case .success(let data) = storage,
                      let failed = notification.object as? ModelContext, failed === data.context else { return }
                let replacement = ModelContext(data.container)
                replacement.autosaveEnabled = false
                storage = .success((data.container, replacement))
                if let drafts = try? replacement.fetch(FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.finishedAt == nil })) {
                    activities.reconcile(activeID: drafts.first?.id)
                }
                saveError = notification.userInfo?["error"] as? String ?? "The change could not be saved."
            }
        }
    }
}
