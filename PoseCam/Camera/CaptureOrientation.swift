import CoreGraphics
import CoreMotion
import ImageIO

/// 撮るときの端末の向き（縦・横・逆さ）。画面は縦で固定しているので、加速度センサーの重力の向きで決める
/// （画面の向きのロックをしていても分かる）。
/// 保存する写真・動画の画素は縦向きのまま作り、この向きを写真の「向き（Orientation）」・動画の回転として付ける。
/// 写真アプリなどは、それを見て横向きに表示する（標準のカメラと同じ）。
final class CaptureOrientation {
    static let shared = CaptureOrientation()

    /// 保存する写真に付ける向き。縦向きに持っていれば .up
    var current: CGImagePropertyOrientation { box.value }

    private let box = Locked<CGImagePropertyOrientation>(.up)
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private var running = false

    private init() {
        queue.maxConcurrentOperationCount = 1
        queue.name = "CaptureOrientation"
    }

    /// 向きを調べ始める（何度呼んでもよい。メインスレッドから呼ぶ）
    func start() {
        guard !running, manager.isAccelerometerAvailable else { return }
        running = true
        manager.accelerometerUpdateInterval = 0.2
        manager.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
            guard let self, let a = data?.acceleration else { return }
            if let orientation = Self.orientation(x: a.x, y: a.y, z: a.z) { self.box.value = orientation }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        manager.stopAccelerometerUpdates()
    }

    /// 重力の向きから、写真の向きを決める。机に平らに置いているなど、どちらとも言えないときは nil（前の向きのまま）。
    /// 縦向きに持つと y が -1。上端を左に倒す（横向き・左に上端）と x が -1 で、写真は反時計回りに 90 度回して見る（8）。
    /// （最初は逆にしていて、横向きの写真・動画が 180 度ずれていた。実機で確認）
    static func orientation(x: Double, y: Double, z: Double) -> CGImagePropertyOrientation? {
        // ほぼ水平（画面が上か下を向いている）なら決めない
        guard abs(z) < 0.8 else { return nil }
        // 縦と横の境目では前の向きのまま（少し傾けただけで切り替わらないように）
        if abs(x) > abs(y) + 0.25 {
            return x < 0 ? .left : .right
        }
        if abs(y) > abs(x) + 0.25 {
            return y < 0 ? .up : .down
        }
        return nil
    }

    /// 動画のトラックに付ける回転（写真の向きと同じ意味）
    static func videoTransform(for orientation: CGImagePropertyOrientation) -> CGAffineTransform {
        switch orientation {
        case .right: return CGAffineTransform(rotationAngle: .pi / 2)
        case .left: return CGAffineTransform(rotationAngle: -.pi / 2)
        case .down: return CGAffineTransform(rotationAngle: .pi)
        default: return .identity
        }
    }
}
