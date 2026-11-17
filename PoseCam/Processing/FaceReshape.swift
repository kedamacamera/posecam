import CoreImage

/// 顔の形の補正（小顔・目を大きく・小鼻を細く）。顔の 478 点（MediaPipe の顔のメッシュ）を目印に、
/// 画像を少しだけずらす（BeautyKernels.ci.metal の faceWarp）。動かす量は顔の幅の数 % まで
/// （それ以上は不自然になりやすい）。顔ごとに 1 回ずつかける。
///
/// 点の番号は MediaPipe の顔のメッシュの番号（画像の左右ではなく、写っている人から見た左右）:
/// 輪郭 234/454 = 耳の付け根の高さの左右端、132・58・172・136 / 361・288・397・365 = 頬の下〜あご、
/// 468 / 473 = 黒目の中心、33-133 / 362-263 = 目頭と目尻、129 / 358 = 小鼻の左右、4 = 鼻の先
enum FaceReshape {
    static let kernel: CIWarpKernel? = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? CIWarpKernel(functionName: "faceWarp", fromMetalLibraryData: data)
    }()

    /// 小顔で内側へ寄せる輪郭の点と、その点を動かす割合（あごの角ほど大きく、あご先の近くは小さく）
    private static let slimPoints: [(Int, CGFloat)] = [
        (132, 0.7), (58, 1.0), (172, 1.0), (136, 0.6),
        (361, 0.7), (288, 1.0), (397, 1.0), (365, 0.6),
    ]

    static func apply(_ image: CIImage, meshes: [[CGPoint]], settings: ProcessingSettings) -> CIImage {
        guard let kernel, settings.needsFaceMesh else { return image }
        var result = image
        for mesh in meshes where mesh.count >= 478 {
            result = warp(result, mesh: mesh, settings: settings, kernel: kernel)
        }
        return result
    }

    private static func warp(_ image: CIImage, mesh: [CGPoint], settings: ProcessingSettings,
                             kernel: CIWarpKernel) -> CIImage {
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        let faceWidth = distance(mesh[234], mesh[454])
        guard faceWidth > 8 else { return image }
        // 顔の横向き（写っている人の右 → 左。画像では左 → 右のことが多い）
        let axis = CGVector(dx: (mesh[454].x - mesh[234].x) / faceWidth, dy: (mesh[454].y - mesh[234].y) / faceWidth)
        let noseTip = mesh[4]

        // 小顔: 輪郭の点を顔の中心線の方へ、顔の幅の最大 4.5% 動かす
        let slim = CGFloat(settings.faceSlim)
        let slimVectors: [CIVector] = slimPoints.map { index, weight in
            let point = mesh[index]
            let side: CGFloat = (point.x - noseTip.x) * axis.dx + (point.y - noseTip.y) * axis.dy > 0 ? -1 : 1
            let amount = slim * faceWidth * 0.045 * weight
            return CIVector(x: point.x, y: point.y, z: side * axis.dx * amount, w: side * axis.dy * amount)
        }
        let slimRadius = faceWidth * 0.3

        // 目: 黒目の中心のまわり、目の幅ほどの範囲を最大 12% 中心寄りから取る
        let eye = CGFloat(settings.eyeSize)
        func eyeVector(center: Int, a: Int, b: Int) -> CIVector {
            guard eye > 0.01 else { return CIVector(x: 0, y: 0, z: 0, w: 0) }
            return CIVector(x: mesh[center].x, y: mesh[center].y, z: distance(mesh[a], mesh[b]) * 1.1, w: eye * 0.12)
        }
        let eyeR = eyeVector(center: 468, a: 33, b: 133)
        let eyeL = eyeVector(center: 473, a: 362, b: 263)

        // 鼻: 小鼻の間を中心に、横方向だけ最大 18% 外側から取る
        let nose = CGFloat(settings.noseSlim)
        let noseWidth = distance(mesh[129], mesh[358])
        let noseCenter = mid(mid(mesh[129], mesh[358]), noseTip)
        let noseA = nose > 0.01
            ? CIVector(x: noseCenter.x, y: noseCenter.y, z: noseWidth * 0.95, w: noseWidth * 1.3)
            : CIVector(x: 0, y: 0, z: 0, w: 0)
        let noseB = CIVector(x: axis.dx, y: axis.dy, z: nose * 0.18, w: 0)

        let maxShift = faceWidth * 0.1 + 2
        let output = kernel.apply(
            extent: image.extent,
            roiCallback: { _, rect in rect.insetBy(dx: -maxShift, dy: -maxShift) },
            image: image.clampedToExtent(),
            arguments: slimVectors + [slimRadius, eyeL, eyeR, noseA, noseB])
        return output?.cropped(to: image.extent) ?? image
    }
}
