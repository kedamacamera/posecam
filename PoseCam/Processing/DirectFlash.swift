import CoreImage
import Vision

/// ダイレクトフラッシュ（写ルンです・昔のコンデジでフラッシュを焚いたような写り）。
///
/// 本物のカメラは「フラッシュの光量はそのまま、シャッター速度を上げて周りの光だけを減らす」ことで、
/// フラッシュが届く手前の人だけが明るく、届かない背景が暗く落ちる写りにする。
/// ただし iPhone のフラッシュは LED で、シャッターが開いている間ずっと光っているため、
/// シャッター速度を上げるとフラッシュの光も同じだけ減ってしまい、この写りにならない
/// （発光の強さもアプリからは指定できず、iOS が自動で決める）。
///
/// そこで、発光する直前の映像のコマ（周りの光だけ）と、フラッシュを焚いた写真（周りの光 + フラッシュ）を比べ、
/// 写真の明るさのうち「周りの光」の割合が大きい所ほど暗くする。
/// 結果は「フラッシュの光はそのまま、周りの光だけを ambientGain 倍（既定 1/8 = 3 段分シャッター速度を
/// 上げたのと同じ）」になる。
///
/// コマと写真の間には（発光前の測光のぶん）時間があり、手ぶれ・体の動きでずれる。ずれたまま比べると、
/// 椅子や体の縁に黒い影・白い縁が出ていたので、
/// 1. コマを写真に重なるよう位置合わせしてから比べる（Vision の画像の位置合わせ）
/// 2. 暗くする割合は縮めた画像で求め、なめらかに引き伸ばす（軽い）
/// 3. 写真の方がコマより大きく暗い所（動いた所）は、広い範囲の割合を使う
/// さらに、フラッシュらしい硬さ（パキッとした感じ）を出すため、輪郭のコントラスト（明瞭度）と全体のコントラストを上げる。
enum DirectFlash {
    static let kernel: CIKernel? = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? CIKernel(functionName: "directFlash", fromMetalLibraryData: data)
    }()

    /// 割合を求める縮小率
    private static let factor: CGFloat = 0.125

    /// photo と ambient は同じ大きさ・同じ切り抜きで、原点は (0, 0)。exposureRatio は（写真の露出）/（コマの露出）。
    static func apply(photo: CIImage, ambient: CIImage, exposureRatio: Double, ambientGain: Double = 0.125) -> CIImage {
        guard let kernel else { return photo }
        let extent = photo.extent
        let aligned = align(ambient, to: photo) ?? ambient
        let photoSmall = shrink(photo)
        let ambientSmall = shrink(aligned)
        let small = photoSmall.extent
        let longSide = max(small.width, small.height)
        func blur(_ image: CIImage, _ sigma: CGFloat) -> CIImage {
            image.clampedToExtent().applyingGaussianBlur(sigma: max(0.5, sigma)).cropped(to: small)
        }
        guard let gainSmall = kernel.apply(
            extent: small, roiCallback: { _, rect in rect },
            arguments: [blur(photoSmall, longSide * 0.004), blur(ambientSmall, longSide * 0.004),
                        blur(photoSmall, longSide * 0.05), blur(ambientSmall, longSide * 0.05),
                        Float(exposureRatio), Float(ambientGain)]) else { return photo }
        // 元の大きさへなめらかに引き伸ばす（輪郭に沿わせる CIEdgePreserveUpsampleFilter は、
        // 値が負になる・人の周りに色の付いた縁が出るので使わない。位置合わせ済みなので、なめらかで十分）
        let gain = gainSmall.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: extent.width / small.width, y: extent.height / small.height))
            .cropped(to: extent)
        let relit = photo.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: gain])
            .cropped(to: extent)
        // 明瞭度（大きめの半径のアンシャープマスク）とコントラストで硬い光にし、周辺の落ち込みを少し足す
        return relit
            .clampedToExtent()
            .applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: max(extent.width, extent.height) * 0.008,
                                                          kCIInputIntensityKey: 0.45])
            .cropped(to: extent)
            .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.12, kCIInputSaturationKey: 1.05,
                                                            kCIInputBrightnessKey: 0])
            .applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 0.45, kCIInputRadiusKey: 1.6])
            .cropped(to: extent)
    }

    /// 1/8 に縮めた画像（原点 (0, 0)）
    private static func shrink(_ image: CIImage) -> CIImage {
        let e = image.extent
        let size = CGRect(x: 0, y: 0, width: (e.width * factor).rounded(), height: (e.height * factor).rounded())
        return image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)
            .concatenating(CGAffineTransform(scaleX: factor, y: factor)))
            .clampedToExtent().cropped(to: size)
    }

    /// ambient を photo に重なるように動かす（どちらも原点 (0, 0)・同じ大きさ）。
    /// 長辺 512 に縮めた画像で、射影変換（手ぶれの平行移動・回転・傾き）を求める。
    /// 求まらない・動きが大きすぎて信用できないときは nil（そのまま比べる）
    static func align(_ ambient: CIImage, to photo: CIImage) -> CIImage? {
        guard let m = warp(ambient, to: photo) else { return nil }
        let extent = photo.extent
        let limit = max(extent.width, extent.height) * 0.08
        let padded = extent.insetBy(dx: -limit, dy: -limit)
        let corners = [CGPoint(x: padded.minX, y: padded.minY), CGPoint(x: padded.maxX, y: padded.minY),
                       CGPoint(x: padded.minX, y: padded.maxY), CGPoint(x: padded.maxX, y: padded.maxY)]
        let mapped = corners.compactMap(m)
        guard mapped.count == 4 else { return nil }
        return ambient.clampedToExtent().cropped(to: padded)
            .applyingFilter("CIPerspectiveTransform", parameters: [
                "inputBottomLeft": CIVector(cgPoint: mapped[0]),
                "inputBottomRight": CIVector(cgPoint: mapped[1]),
                "inputTopLeft": CIVector(cgPoint: mapped[2]),
                "inputTopRight": CIVector(cgPoint: mapped[3]),
            ])
            .clampedToExtent().cropped(to: extent)
    }

    /// ambient の点を photo の点へ移す変換（元の大きさの座標）。確認用のツールからも使う
    static func warp(_ ambient: CIImage, to photo: CIImage) -> ((CGPoint) -> CGPoint?)? {
        let extent = photo.extent
        let scale = 512 / max(extent.width, extent.height)
        let s = CGAffineTransform(scaleX: scale, y: scale)
        // 明るさの違い（フラッシュの有無）で合わせ方がずれにくいよう、どちらも白黒にして比べる
        func prepare(_ image: CIImage) -> CIImage {
            image.transformed(by: s).applyingFilter("CIPhotoEffectNoir")
        }
        let request = VNHomographicImageRegistrationRequest(targetedCIImage: prepare(ambient), options: [:])
        let handler = VNImageRequestHandler(ciImage: prepare(photo), options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first as? VNImageHomographicAlignmentObservation else { return nil }
        let m = observation.warpTransform
        let map: (CGPoint) -> CGPoint? = { p in
            let v = m * SIMD3<Float>(Float(p.x * scale), Float(p.y * scale), 1)
            guard abs(v.z) > 1e-4 else { return nil }
            return CGPoint(x: CGFloat(v.x / v.z) / scale, y: CGFloat(v.y / v.z) / scale)
        }
        // 手ぶれの範囲（四隅の動きが長辺の 8% 以内）を超える動きは、合わせ間違いとして使わない
        let w = extent.width, h = extent.height
        let limit = max(w, h) * 0.08
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: 0, y: h), CGPoint(x: w, y: h)] {
            guard let q = map(p), hypot(q.x - p.x, q.y - p.y) <= limit else { return nil }
        }
        return map
    }
}
