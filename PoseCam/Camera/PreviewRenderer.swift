import CoreImage
import MetalKit
import SwiftUI

/// 加工済みの CIImage を Metal で画面に描く。最新の 1 枚だけを保持し、新しい画像が来たときだけ描画する。
final class PreviewRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    /// 写真・動画の書き出しでも共用する（CIContext はスレッドセーフ）
    let ciContext: CIContext
    private let commandQueue: MTLCommandQueue
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let lock = NSLock()
    private var pending: CIImage?
    private var hasDrawnOnce = false

    override init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal を利用できません")
        }
        self.device = device
        self.commandQueue = queue
        self.ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        super.init()
    }

    func display(_ image: CIImage) {
        lock.lock()
        pending = image
        lock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        lock.lock()
        let image = pending
        pending = nil
        lock.unlock()

        guard let image, image.extent.width > 0, image.extent.height > 0,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let size = view.drawableSize
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

struct CameraPreview: UIViewRepresentable {
    let renderer: PreviewRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.delegate = renderer
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 30
        view.isOpaque = true
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
