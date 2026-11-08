import SwiftUI

@main
struct MiMundoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // Rounded type everywhere; individual views pick text styles
                // so everything scales with the iPad's text-size setting.
                .fontDesign(.rounded)
        }
    }
}
