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
    /// 本体のボタンでシャッターを切ってよいか（アルバム・編集などの画面を開いている間は、押されても無視する）
    var hardwareShutterEnabled: Bool
    /// この高さより下（この面の座標）に触れた指は受け取らない（上に重なっているボタンに任せる）
    var ignoreBelow: CGFloat = .infinity
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
        let view = PassThroughView()
        view.backgroundColor = .clear
        view.ignoreBelow = ignoreBelow
        let c = context.coordinator
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        let long = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.longPress(_:)))
        long.minimumPressDuration = 0.6
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        for recognizer in [tap, long, pan, pinch] as [UIGestureRecognizer] {
            recognizer.delegate = c
            view.addGestureRecognizer(recognizer)
        }
        if #available(iOS 17.2, *) {
            let interaction = AVCaptureEventInteraction { [weak c] event in
                // 画面を開いている間は、押されても何もしない
                guard let c, c.parent.hardwareShutterEnabled else { return }
                switch event.phase {
                case .began: c.parent.onHardwareButton(true)
                case .ended: c.parent.onHardwareButton(false)
                default: break
                }
            }
            view.addInteraction(interaction)
            c.interaction = interaction
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        // 以前は画面（シート）を開くたびに isEnabled を切り替えていたが、iPhone ではシートを開くと
        // 表示されないまま画面が固まり、iPad では固まらなかった。切り替えをやめ、受け取った側で無視する
        // （そのため、画面を開いている間は音量ボタンで音量が変わらない）
        context.coordinator.parent = self
        (view as? PassThroughView)?.ignoreBelow = ignoreBelow
    }

    /// ignoreBelow より下では指を受け取らない面。
    /// 以前は指を受け取ったうえで操作（タップなど）だけを無視していたが、9:16・フルの比率で映像が下のボタンの
    /// 後ろまで広がると、撮影モード・倍率などのボタンを押した指をこの面が先に取り、ボタンが反応しないことがあった。
    /// ここで受け取らなければ、指はそのまま上に重なったボタンに届く
    final class PassThroughView: UIView {
        var ignoreBelow: CGFloat = .infinity

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            point.y < ignoreBelow && super.point(inside: point, with: event)
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

        /// 下のボタン（撮影モード・シャッターなど）の所に触れた指は受け取らない
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view = recognizer.view else { return true }
            return touch.location(in: view).y < parent.ignoreBelow
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
            // 露出の目盛り（縦の線）は動かさず、太陽の印だけが補正の量で上下する（±2 段で線の端まで）
            ZStack {
                Rectangle().fill(Color.yellow.opacity(0.7)).frame(width: 1, height: side * 1.2)
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.yellow)
                    .background(Circle().fill(Color.black.opacity(0.25)).frame(width: 20, height: 20))
                    .offset(y: -CGFloat(bias) / 2 * side * 0.6)
            }
            .offset(x: side / 2 + 16)
            .opacity(bias != 0 || !dimmed ? 1 : 0)
        }
        .opacity(dimmed ? 0.45 : 1)
        .position(point)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.2), value: dimmed)
    }
}
