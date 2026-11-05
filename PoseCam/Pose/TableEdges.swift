import CoreGraphics
import CoreImage

/// 料理・ドリンクの写真から、テーブルの縁（手前・奥の直線）を探す。構図の型に、器の輪郭と一緒に描く。
///
/// テーブルの縁は「写真の横幅の 3 割以上続く、横向きに近い、明暗のはっきりした直線」なので、
/// 写真を小さくして明暗の境目（Sobel）を求め、ハフ変換で直線を探す。
/// お皿・グラスの縁も境目になるので、器の輪郭の内側（と少し外側）の境目は数えない。
/// 真上から撮った写真のようにテーブルが画面いっぱいの写真では、何も返さない。
enum TableEdges {
    /// 結果は線ごとに [始点, 終点]（画像座標・左上原点・0...1）。最大 2 本
    static func find(in image: CIImage, excluding outlines: [[CGPoint]]) -> [[CGPoint]] {
        let width = 320
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return [] }
        let height = max(1, Int(CGFloat(width) * extent.height / extent.width))
        guard let gray = grayPixels(image, width: width, height: height) else { return [] }
        let excluded = exclusionMask(outlines, width: width, height: height)

        // Sobel で明暗の境目の強さと向きを求める
        var magnitude = [Float](repeating: 0, count: width * height)
        var gx = [Float](repeating: 0, count: width * height)
        var gy = [Float](repeating: 0, count: width * height)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                func p(_ dx: Int, _ dy: Int) -> Float { Float(gray[(y + dy) * width + x + dx]) }
                let sx = (p(1, -1) + 2 * p(1, 0) + p(1, 1)) - (p(-1, -1) + 2 * p(-1, 0) + p(-1, 1))
                let sy = (p(-1, 1) + 2 * p(0, 1) + p(1, 1)) - (p(-1, -1) + 2 * p(0, -1) + p(1, -1))
                let i = y * width + x
                gx[i] = sx
                gy[i] = sy
                magnitude[i] = (sx * sx + sy * sy).squareRoot()
            }
        }
        let threshold: Float = 70
        var edge = [Bool](repeating: false, count: width * height)
        for i in 0..<(width * height) where magnitude[i] > threshold && !excluded[i] { edge[i] = true }

        // ハフ変換: 線の法線の角度 θ（50°〜130°、90° が水平な線）と、原点からの距離 ρ
        let thetas = Array(stride(from: 50.0, through: 130.0, by: 1.0)).map { $0 * .pi / 180 }
        let maxRho = Int((Double(width * width + height * height)).squareRoot()) + 1
        let rhoCount = maxRho * 2
        var votes = [Int](repeating: 0, count: thetas.count * rhoCount)
        for y in 0..<height {
            for x in 0..<width where edge[y * width + x] {
                let i = y * width + x
                let gradientAngle = atan2(Double(gy[i]), Double(gx[i]))
                for (t, theta) in thetas.enumerated() {
                    // 境目の向きと線の法線がそろっているものだけ数える（斜めの模様に引っぱられない）
                    var difference = abs(gradientAngle - theta).truncatingRemainder(dividingBy: .pi)
                    difference = min(difference, .pi - difference)
                    guard difference < 0.35 else { continue }
                    let rho = Int((Double(x) * cos(theta) + Double(y) * sin(theta)).rounded()) + maxRho
                    votes[t * rhoCount + rho] += 1
                }
            }
        }

        var lines: [[CGPoint]] = []
        var used: [(Int, Int)] = []
        for _ in 0..<6 where lines.count < 2 {
            // まだ使っていない、いちばん票の多い直線
            var best = -1, bestVotes = 0
            for index in votes.indices where votes[index] > bestVotes {
                let t = index / rhoCount, r = index % rhoCount
                if used.contains(where: { abs($0.0 - t) <= 8 && abs($0.1 - r) <= 12 }) { continue }
                best = index
                bestVotes = votes[index]
            }
            guard best >= 0, bestVotes > width / 4 else { break }
            let t = best / rhoCount, r = best % rhoCount
            used.append((t, r))
            if let segment = longestRun(theta: thetas[t], rho: Double(r - maxRho), edge: edge,
                                        width: width, height: height),
               segment.length >= Double(width) * 0.35 {
                lines.append([CGPoint(x: segment.start.x / CGFloat(width), y: segment.start.y / CGFloat(height)),
                              CGPoint(x: segment.end.x / CGFloat(width), y: segment.end.y / CGFloat(height))])
            }
        }
        return lines
    }

    /// 直線に沿って境目が続いているいちばん長い区間（途中の 10 ピクセルまでの切れ目はつなぐ）
    private static func longestRun(theta: Double, rho: Double, edge: [Bool], width: Int, height: Int)
        -> (start: CGPoint, end: CGPoint, length: Double)? {
        let s = sin(theta), c = cos(theta)
        guard abs(s) > 0.3 else { return nil }
        var best: (start: Int, end: Int)?
        var runStart: Int?
        var lastHit = -100
        func y(at x: Int) -> Double { (rho - Double(x) * c) / s }
        func hit(_ x: Int) -> Bool {
            let center = Int(y(at: x).rounded())
            for dy in -2...2 {
                let yy = center + dy
                if yy >= 0, yy < height, edge[yy * width + x] { return true }
            }
            return false
        }
        for x in 0..<width {
            if hit(x) {
                if runStart == nil || x - lastHit > 10 { runStart = x }
                lastHit = x
                if let start = runStart, (best == nil || x - start > best!.end - best!.start) { best = (start, x) }
            }
        }
        guard let best else { return nil }
        let start = CGPoint(x: Double(best.start), y: y(at: best.start))
        let end = CGPoint(x: Double(best.end), y: y(at: best.end))
        return (start, end, hypot(end.x - start.x, end.y - start.y))
    }

    /// 写真を width × height の 8 ビットの灰色にする（少しぼかして細かい模様の境目を減らす）
    private static func grayPixels(_ image: CIImage, width: Int, height: Int) -> [UInt8]? {
        let e = image.extent
        let small = image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / e.width, y: CGFloat(height) / e.height))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 1.2)
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let context = CIContext()
        guard let cgImage = context.createCGImage(small, from: small.extent),
              let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                     bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        canvas.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = canvas.data else { return nil }
        // CGContext のメモリは上の行から並ぶ
        return Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: width * height),
                                         count: width * height))
    }

    /// 器の輪郭の内側と、その縁から少し外側までを true にしたマス（上の行から順）
    private static func exclusionMask(_ outlines: [[CGPoint]], width: Int, height: Int) -> [Bool] {
        guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                     bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return [Bool](repeating: false, count: width * height)
        }
        canvas.setFillColor(gray: 0, alpha: 1)
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // 画像座標（上が 0）で描けるよう上下を反転する
        canvas.translateBy(x: 0, y: CGFloat(height))
        canvas.scaleBy(x: 1, y: -1)
        canvas.setFillColor(gray: 1, alpha: 1)
        canvas.setStrokeColor(gray: 1, alpha: 1)
        canvas.setLineWidth(8)
        canvas.setLineJoin(.round)
        for outline in outlines where outline.count > 2 {
            canvas.beginPath()
            canvas.addLines(between: outline.map { CGPoint(x: $0.x * CGFloat(width), y: $0.y * CGFloat(height)) })
            canvas.closePath()
            canvas.drawPath(using: .fillStroke)
        }
        guard let data = canvas.data else { return [Bool](repeating: false, count: width * height) }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height)
        return (0..<(width * height)).map { bytes[$0] > 127 }
    }
}
