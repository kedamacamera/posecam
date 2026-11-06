import AVKit
import SwiftUI
import UIKit

/// プレビューの上の、指の操作と本体のボタンを受け取る透明な層。
/// - タップ: ピント・露出を合わせる（パネルが開いていれば閉じる）
/// - 長押し: ピント・露出を固定（AE/AF ロック）
/// - 上下になぞる: 露出の補正
/// - 2 本指でつまむ: ズーム
/// - 音量ボタン・有線イヤホンのボタン・Bluetooth のリモコン（音量ボタンとして届くもの）・AirPods（iOS 26 以降の
///   カメラリモート）: シャッター。iOS 17.2 以降の AVCaptureEventInteraction で受け取る。
///   これを使うと、押しても音量は変わらず、音量の表示も出ない。
struct CameraGestureView: UIViewRepresentable {
    /// 本体のボタンでシャッターを切ってよいか（アルバム・編集などの画面を開いている間は、ふつうの音量ボタンに戻す）
    var hardwareShutterEnabled: Bool
    let onTap: (CGPoint, CGSize) -> Void
    let onLongPress: (CGPoint, CGSize) -> Void
    /// 上下になぞった量（ポイント、上が負）。指を離したら nil
    let onVerticalPan: (CGFloat?) -> Void
    /// つまんだ倍率。指を離したら nil
    let onPinch: (CGFloat?) -> Void
    /// 本体のボタン。true で押し始め、false で離した
    let onHardwareButton: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let c = context.coordinator
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        let long = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.longPress(_:)))
        long.minimumPressDuration = 0.6
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = c
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        for recognizer in [tap, long, pan, pinch] as [UIGestureRecognizer] { view.addGestureRecognizer(recognizer) }
        if #available(iOS 17.2, *) {
            let interaction = AVCaptureEventInteraction { [weak c] event in
                switch event.phase {
                case .began: c?.parent.onHardwareButton(true)
                case .ended: c?.parent.onHardwareButton(false)
                default: break
                }
            }
            interaction.isEnabled = hardwareShutterEnabled
            view.addInteraction(interaction)
            c.interaction = interaction
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        if #available(iOS 17.2, *), let interaction = context.coordinator.interaction as? AVCaptureEventInteraction {
            interaction.isEnabled = hardwareShutterEnabled
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: CameraGestureView
        var interaction: AnyObject?

        init(parent: CameraGestureView) { self.parent = parent }

        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            parent.onTap(recognizer.location(in: view), view.bounds.size)
        }

        @objc func longPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let view = recognizer.view else { return }
            parent.onLongPress(recognizer.location(in: view), view.bounds.size)
        }

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .changed: parent.onVerticalPan(recognizer.translation(in: recognizer.view).y)
            case .ended, .cancelled, .failed: parent.onVerticalPan(nil)
            default: break
            }
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed: parent.onPinch(recognizer.scale)
            default: parent.onPinch(nil)
            }
        }

        /// 上下になぞったときだけ露出の補正にする（横になぞったときは何もしない）
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let v = pan.velocity(in: pan.view)
            return abs(v.y) > abs(v.x)
        }
    }
}

/// タップした所に出す、ピント・露出の枠。右の太陽の印が露出の補正の量で上下する。
struct FocusIndicator: View {
    let point: CGPoint
    let locked: Bool
    let bias: Float
    /// しばらく操作しないと薄くする
    let dimmed: Bool

    var body: some View {
        let side: CGFloat = 72
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.yellow, lineWidth: 1.2)
                .frame(width: side, height: side)
            // 太陽の印（露出）。補正 ±2 で、枠の高さの ±0.8 倍動く
            VStack(spacing: 0) {
                Rectangle().fill(Color.yellow.opacity(0.7)).frame(width: 1, height: side * 0.8)
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.yellow)
                Rectangle().fill(Color.yellow.opacity(0.7)).frame(width: 1, height: side * 0.8)
            }
            .offset(x: side / 2 + 16, y: -CGFloat(bias) / 2 * side * 0.8)
            .opacity(bias != 0 || !dimmed ? 1 : 0)
        }
        .opacity(dimmed ? 0.45 : 1)
        .position(point)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.2), value: dimmed)
    }
}
