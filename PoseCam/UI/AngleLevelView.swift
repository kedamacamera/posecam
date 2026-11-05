import CoreMotion
import SwiftUI

/// 料理・ドリンクを撮る角度の水準器。
///
/// 料理写真の定番の角度は 3 つ:
/// - 真上（俯瞰・90°）: ピザ・定食・テーブル全体など、平らな物や並べた物
/// - 45°: 丼・サラダ・パフェなど、高さと上面の両方を見せたい物（いちばん万能）
/// - 真横（0°）: バーガー・重ねたケーキ・グラスのドリンクなど、高さ・断面が主役の物
/// スマホの広角レンズは 45° だと料理が奥へ滑って見えやすいので、迷ったら真上か真横がおすすめ。
///
/// 画面には、いまのカメラの下向きの角度と、近い定番の角度を出す。定番の角度から 3° 以内で緑になる。
/// 真上のときは、左右・前後の傾きを泡で表す（中心の丸に入れば水平）。
struct AngleLevelView: View {
    @StateObject private var motion = MotionReader()

    private static let presets: [(angle: Double, name: String)] = [(90, "真上"), (45, "45°"), (0, "真横")]

    var body: some View {
        let angle = motion.downAngle
        let nearest = Self.presets.min { abs($0.angle - angle) < abs($1.angle - angle) }!
        let matched = abs(nearest.angle - angle) < 3

        VStack(spacing: 8) {
            Spacer()
            if nearest.angle == 90 && abs(90 - angle) < 15 {
                bubble(matched: matched)
            }
            HStack(spacing: 6) {
                Image(systemName: matched ? "checkmark.circle.fill" : "camera.rotate")
                Text("角度 \(Int(angle.rounded()))°")
                    .monospacedDigit()
                Text("→ \(nearest.name)")
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(matched ? Color.green.opacity(0.85) : Color.black.opacity(0.55)))
            .foregroundStyle(.white)
            .padding(.bottom, 12)
        }
        .allowsHitTesting(false)
        .onAppear { motion.start() }
        .onDisappear { motion.stop() }
    }

    private func bubble(matched: Bool) -> some View {
        let range: CGFloat = 50
        let x = CGFloat(max(-1, min(1, motion.tiltX * 4))) * range
        let y = CGFloat(max(-1, min(1, -motion.tiltY * 4))) * range
        return ZStack {
            Circle().stroke(Color.white.opacity(0.8), lineWidth: 1.5).frame(width: 26, height: 26)
            Circle()
                .fill(matched ? Color.green : Color.yellow)
                .frame(width: 16, height: 16)
                .offset(x: x, y: y)
        }
        .frame(width: range * 2 + 20, height: range * 2 + 20)
        .frame(maxHeight: .infinity, alignment: .center)
    }
}

/// 端末の傾き（重力の向き）を 1 秒に 20 回読む。
final class MotionReader: ObservableObject {
    /// カメラが水平から何度下を向いているか（真上から撮ると 90）
    @Published private(set) var downAngle: Double = 0
    /// 真上から撮るときの左右・前後の傾き（重力の x・y 成分）
    @Published private(set) var tiltX: Double = 0
    @Published private(set) var tiltY: Double = 0

    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 20
        manager.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let g = data?.gravity else { return }
            // 画面を上に向けて置く（カメラが真下を向く）と重力の z は -1
            let angle = asin(max(-1, min(1, -g.z))) * 180 / .pi
            if abs(angle - self.downAngle) > 0.3 { self.downAngle = angle }
            self.tiltX = g.x
            self.tiltY = g.y
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}
