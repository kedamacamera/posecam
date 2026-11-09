import SwiftUI

@main
struct PoseCamApp: App {
    init() {
        Diagnostics.install()
        Diagnostics.startHangWatch()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
