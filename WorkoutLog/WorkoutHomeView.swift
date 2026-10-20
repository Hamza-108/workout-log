import SwiftData
import SwiftUI

enum HomeDestination: Hashable { case data, library }

struct WorkoutHomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(WorkoutActivityController.self) private var activities
    @Query(filter: #Predicate<WorkoutSession> { $0.finishedAt == nil }) private var drafts: [WorkoutSession]
    @State private var tab = 0
    @State private var templatesPath: [HomeDestination] = []
    @State private var resumeID: UUID?
    @State private var routeMessage: String?

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $templatesPath) {
                TemplatesView(resumeID: $resumeID, routeMessage: $routeMessage)
                    .navigationDestination(for: HomeDestination.self) { destination in
                        switch destination {
                        case .data: DataTransferView()
                        case .library: ExerciseLibraryView()
                        }
                    }
            }
                .tabItem { Label("Templates", systemImage: "list.bullet.rectangle") }.tag(0)
            NavigationStack {
                CalendarView(routeID: resumeID) { id in
                    tab = 0
                    templatesPath = []
                    resumeID = id
                }
            }
                .tabItem { Label("Calendar", systemImage: "calendar") }.tag(2)
            NavigationStack { HistoryView() }
                .tabItem { Label("History", systemImage: "clock") }.tag(1)
        }
        .onOpenURL { url in
            tab = 0
            templatesPath = []
            do {
                guard let id = SessionRoute.sessionID(from: url),
                      let session = try context.fetch(FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.finishedAt == nil })).first(where: { $0.id == id }),
                      session.finishedAt == nil else {
                    routeMessage = "That link does not match a saved unfinished workout. Your data has not changed."
                    return
                }
                routeMessage = nil
                resumeID = id
            } catch { routeMessage = "Could not open the saved workout: \(error.localizedDescription)" }
        }
        .onChange(of: drafts.first?.id, initial: true) { _, id in activities.reconcile(activeID: id) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { activities.reconcile(activeID: drafts.first?.id) }
        }
    }
}
