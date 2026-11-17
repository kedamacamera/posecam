import SwiftUI
import UIKit

/// モニター（別の iPhone・ブラウザ・Apple Watch）で見ている間は、撮る側の画面を黒くして明るさを下げ、
/// プレビューの描画も止める。撮る側の画面はほとんど見ないので、画面の明るさと描画の発熱を減らす。
/// 撮影・モニターへの映像は今まで通り。タップすると元の画面に戻り、モニターをつなぎ直すまで暗くしない
/// （撮る人がこの画面を見ながら撮り、写る人がモニターを見るときのため）。
struct MonitorPowerSaveCover: View {
    @ObservedObject var remote: RemoteHost
    /// 暗くした（true）・戻した（false）
    let onActiveChange: (Bool) -> Void

    @Environment(\.scenePhase) private var scenePhase
    /// モニターで見始めてから少し待ってから暗くする（つないだ直後に画面が消えると、つながったか分かりにくい）
    @State private var armed = false
    /// タップで元の画面に戻した（モニターが切れるまで暗くしない）
    @State private var dismissed = false
    /// 暗くする前の画面の明るさ（戻すときに使う）
    @State private var savedBrightness: CGFloat?

    private static let armDelay: Duration = .seconds(5)

    private var active: Bool {
        remote.isStreaming && armed && !dismissed && scenePhase == .active
    }

    var body: some View {
        ZStack {
            if active {
                Color.black
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 34))
                    Text("モニターで表示中")
                        .font(.headline)
                    Text("発熱を抑えるため、この画面を暗くしています\nタップすると元の画面に戻ります")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(0.45))
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .allowsHitTesting(active)
        .onTapGesture { dismissed = true }
        .onChange(of: active) { apply(active) }
        .task(id: remote.isStreaming) {
            armed = false
            dismissed = false
            guard remote.isStreaming else { return }
            try? await Task.sleep(for: Self.armDelay)
            if !Task.isCancelled { armed = true }
        }
        .onDisappear { apply(false) }
    }

    /// 明るさを下げる・戻す。iOS はアプリが変えた明るさを、アプリを閉じても画面をロックするまで残すので、
    /// アプリが前面でなくなったとき（scenePhase が active でない）にも必ず戻す
    private func apply(_ on: Bool) {
        let screen = UIScreen.main
        if on {
            if savedBrightness == nil { savedBrightness = screen.brightness }
            screen.brightness = min(screen.brightness, 0.1)
        } else if let saved = savedBrightness {
            screen.brightness = saved
            savedBrightness = nil
        }
        onActiveChange(on)
    }
}
