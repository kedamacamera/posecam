import CoreImage
import Metal
import QuartzCore
import SwiftUI

/// 加工済みの CIImage を画面に描く。
/// 映像のキューから直接 CAMetalLayer に描くので、メインスレッド（ボタンやスライダーの操作）を止めず、
/// コマが届いてから画面に出るまでの遅れも少ない。
final class PreviewRenderer {
    let device: MTLDevice
    /// 写真・動画の書き出しでも共用する（CIContext はスレッドセーフ）
    let ciContext: CIContext
    private let commandQueue: MTLCommandQueue
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private let lock = NSLock()
    private var layer: CAMetalLayer?
    private var drawableSize: CGSize = .zero
    private var frozen = false
    private var hasDrawnOnce = false

    init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal を利用できません")
        }
        self.device = device
        self.commandQueue = queue
        self.ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    }

    /// 表示先のレイヤーと、その実際の大きさ（ピクセル）。メインスレッドから呼ぶ。
    func attach(_ layer: CAMetalLayer, size: CGSize) {
        lock.lock()
        self.layer = layer
        drawableSize = size
        lock.unlock()
    }

    /// true の間は新しいコマを描かず、最後のコマを表示したままにする（撮影モードの切り替え中など）
    func setFrozen(_ value: Bool) {
        lock.lock()
        frozen = value
        lock.unlock()
    }

    /// 映像のキューから呼ぶ。
    func display(_ image: CIImage) {
        lock.lock()
        let layer = self.layer
        let size = drawableSize
        let frozen = self.frozen
        lock.unlock()

        guard !frozen, let layer, size.width > 0, size.height > 0,
              image.extent.width > 0, image.extent.height > 0,
              let drawable = layer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let extent = image.extent
        // 表示枠はフレームと同じ縦横比にしてあるので、ほぼ等倍で敷き詰める
        let scale = max(size.width / extent.width, size.height / extent.height)
        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(
                translationX: (size.width - extent.width * scale) / 2 - extent.minX * scale,
                y: (size.height - extent.height * scale) / 2 - extent.minY * scale))
        let bounds = CGRect(origin: .zero, size: size)
        let output = image.transformed(by: transform)
            .composited(over: CIImage(color: .black).cropped(to: bounds))

        let first = !hasDrawnOnce
        hasDrawnOnce = true
        if first { Diagnostics.mark("描画: 初回開始 \(Int(size.width))x\(Int(size.height))") }
        ciContext.render(output, to: drawable.texture, commandBuffer: commandBuffer,
                         bounds: bounds, colorSpace: colorSpace)
        commandBuffer.present(drawable)
        commandBuffer.commit()
        if first { Diagnostics.mark("描画: 初回完了") }
    }
}

/// CAMetalLayer を持つビュー。大きさが変わったら描画の大きさを renderer に伝える。
final class MetalPreviewView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    var renderer: PreviewRenderer? {
        didSet { configure() }
    }

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private func configure() {
        guard let renderer else { return }
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = true
        backgroundColor = .black
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = size
        renderer?.attach(metalLayer, size: size)
    }
}

struct CameraPreview: UIViewRepresentable {
    let renderer: PreviewRenderer

    func makeUIView(context: Context) -> MetalPreviewView {
        let view = MetalPreviewView()
        view.renderer = renderer
        return view
    }

    func updateUIView(_ uiView: MetalPreviewView, context: Context) {}
}
