import SwiftData
import SwiftUI

@main
struct MiMundoApp: App {
    private let container = Persistence.makeContainer()
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
                    if phase == .active { gameDayClock.refresh() }
                }
                // Start loading the map while the kid is still picking a profile.
                .task { await atlasStore.loadIfNeeded() }
        }
        .modelContainer(container)
    }
}
