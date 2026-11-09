import SwiftUI

/// Apple Watch の「ポーズカメラ」。ペアの iPhone の撮影画面を映し、シャッター・セルフタイマー・連続撮影の枚数を操作する
@main
struct PoseCamWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchMonitorView()
        }
    }
}
