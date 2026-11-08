import SwiftData
import SwiftUI

@main
struct MiMundoApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                // Rounded type everywhere; individual views pick text styles
                // so everything scales with the iPad's text-size setting.
                .fontDesign(.rounded)
        }
        .modelContainer(for: [Profile.self, Visit.self])
    }
}
