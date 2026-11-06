import CoreImage
import CoreVideo

extension CIContext {
    /// 加工したコマを入れ物（CVPixelBuffer）に描き、GPU が描き終わるまで待つ。描けなかったら false。
    ///
    /// 以前は render(_:to:bounds:colorSpace:) で描いてすぐ録画に渡していた。加工が重いと GPU が描き終わる前に
    /// 書き込まれ、真っ黒なコマ（まだ何も描かれていない入れ物）が動画に入っていた（1 本で 3 割ほど）。
    /// ここでは描き終わるのを待ち、さらに入れ物の数か所に「未描画」の印（透明）を付けておいて、
    /// 描いた後に印が残っていたら失敗として捨てる。
    func renderAndWait(_ image: CIImage, to buffer: CVPixelBuffer, size: CGSize) -> Bool {
        let probes = Self.probePoints(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        Self.setAlpha(buffer, at: probes, to: 0)
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        do {
            // 加工の結果は不透明。端まで確実に塗るため黒の上に重ねる
            let opaque = image.composited(over: CIImage(color: .black)).cropped(to: CGRect(origin: .zero, size: size))
            let task = try startTask(toRender: opaque, from: CGRect(origin: .zero, size: size), to: destination, at: .zero)
            _ = try task.waitUntilCompleted()
        } catch {
            return false
        }
        return Self.allOpaque(buffer, at: probes)
    }

    /// 印を付ける場所（中央と四隅の近く）
    private static func probePoints(width: Int, height: Int) -> [(Int, Int)] {
        guard width > 4, height > 4 else { return [] }
        return [(width / 2, height / 2), (2, 2), (width - 3, 2), (2, height - 3), (width - 3, height - 3)]
    }

    /// BGRA の入れ物だけが対象。それ以外の形式では何もしない
    private static func setAlpha(_ buffer: CVPixelBuffer, at points: [(Int, Int)], to value: UInt8) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA, !points.isEmpty else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for (x, y) in points { bytes[y * row + x * 4 + 3] = value }
    }

    private static func allOpaque(_ buffer: CVPixelBuffer, at points: [(Int, Int)]) -> Bool {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA, !points.isEmpty else { return true }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return true }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        return points.allSatisfy { bytes[$0.1 * row + $0.0 * 4 + 3] == 255 }
    }
}
