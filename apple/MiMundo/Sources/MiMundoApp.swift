import SwiftData
import SwiftUI

@main
struct MiMundoApp: App {
    private let container = Persistence.makeContainer()

    init() {
        #if DEBUG
        FreehandSelfCheck.run()
        #endif
    }
    @State private var atlasStore = AtlasStore()
    @State private var cameraStore = MapCameraStore()
    @State private var gameDayClock = GameDayClock()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                // Rounded type everywhere; individual views pick text styles
                // so everything scales with the iPad's text-size setting.
                .fontDesign(.rounded)
                .environment(atlasStore)
                .environment(cameraStore)
                .environment(gameDayClock)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        gameDayClock.refresh()
                        QuizQueue.refresh(in: container.mainContext)
                    }
                }
                // A new game day (11 pm ET) can bring a new quiz of the day:
                // update the queue so no screen offers yesterday's.
                .onChange(of: gameDayClock.today) { _, _ in
                    QuizQueue.refresh(in: container.mainContext)
                }
                // Start loading the map while the kid is still picking a profile.
                .task { await atlasStore.loadIfNeeded() }
        }
        .modelContainer(container)
    }
}
