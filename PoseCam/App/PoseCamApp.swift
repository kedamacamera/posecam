import SwiftUI

@main
struct PoseCamApp: App {
    init() {
        Diagnostics.install()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
