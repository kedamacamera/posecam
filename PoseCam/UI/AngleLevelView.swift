import CoreMotion
import SwiftUI

/// 水平器。画面の中央に、本当の水平を表す線を出す。線が画面の横（横持ちなら縦）とそろうと黄色になる。
/// 真上から撮る（スマホを水平に寝かせる）ときは、線の代わりに泡の水準器を出す（中心の丸に入ると黄色）。
/// 正解の角度は写真によって違うので、45 度・真横などの角度を「正解」として扱うことはしない。
struct LevelView: View {
    @StateObject private var motion = MotionReader()

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            Group {
                if motion.isFlat {
                    bubble
                } else {
                    horizon
                }
            }
            .position(center)
        }
        .allowsHitTesting(false)
        .onAppear { motion.start() }
        .onDisappear { motion.stop() }
    }

    /// 縦持ち・横持ちのどちらでも、近い方の向き（0・90・180・270 度）からのずれ
    private var tilt: Double {
        let roll = motion.roll
        return roll - (roll / 90).rounded() * 90
    }

    private var horizon: some View {
        let level = abs(tilt) < 1
        let color: Color = level ? .yellow : .white
        let axis = (motion.roll / 90).rounded() * 90
        return ZStack {
            // 画面の向きの基準（両端の短い線）
            HStack(spacing: 150) {
                Capsule().fill(color.opacity(0.9)).frame(width: 18, height: 2)
                Capsule().fill(color.opacity(0.9)).frame(width: 18, height: 2)
            }
            .rotationEffect(.degrees(-axis))
            // 本当の水平
            Capsule()
                .fill(color)
                .frame(width: level ? 150 : 120, height: level ? 2.5 : 1.5)
                .rotationEffect(.degrees(-motion.roll))
                .shadow(color: .black.opacity(0.5), radius: 1.5)
        }
        .animation(.easeOut(duration: 0.12), value: level)
    }

    private var bubble: some View {
        let range: CGFloat = 46
        let x = CGFloat(max(-1, min(1, motion.gravityX * 4))) * range
        let y = CGFloat(max(-1, min(1, -motion.gravityY * 4))) * range
        let level = hypot(motion.gravityX, motion.gravityY) < 0.026  // 約 1.5 度
        return ZStack {
            Circle().stroke(Color.white.opacity(0.8), lineWidth: 1.5).frame(width: 30, height: 30)
            Path { p in
                p.move(to: CGPoint(x: -10, y: 0)); p.addLine(to: CGPoint(x: 10, y: 0))
                p.move(to: CGPoint(x: 0, y: -10)); p.addLine(to: CGPoint(x: 0, y: 10))
            }
            .stroke(Color.white.opacity(0.6), lineWidth: 1)
            .frame(width: 0, height: 0)
            Circle()
                .stroke(level ? Color.yellow : .white, lineWidth: 2.5)
                .frame(width: 20, height: 20)
                .offset(x: x, y: y)
        }
        .frame(width: range * 2 + 24, height: range * 2 + 24)
    }
}

/// 端末の傾き（重力の向き）を 1 秒に 30 回読む。
final class MotionReader: ObservableObject {
    /// 画面の中での傾き（度）。縦持ちでまっすぐなら 0、時計回りに傾けると正
    @Published private(set) var roll: Double = 0
    /// スマホを水平に寝かせているか（真上・真下から撮る）
    @Published private(set) var isFlat = false
    @Published private(set) var gravityX: Double = 0
    @Published private(set) var gravityY: Double = 0

    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let g = data?.gravity else { return }
            let flat = abs(g.z) > 0.9
            if flat != self.isFlat { self.isFlat = flat }
            if flat {
                self.gravityX = g.x
                self.gravityY = g.y
            } else {
                // 縦持ちでまっすぐなら重力は (0, -1)。そこからの回転の角度
                let angle = atan2(g.x, -g.y) * 180 / .pi
                if abs(angle - self.roll) > 0.15 { self.roll = angle }
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}
