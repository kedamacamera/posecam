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
/// 仕上げは、フィルムカメラのフラッシュ（BeautyCam の「フジフラッシュ」のような写り）に寄せる。
/// 以前は明瞭度（大きな半径のアンシャープマスク）・コントラスト・彩度を上げていたが、部屋の電球の色が残って
/// オレンジに転び、暗い所は真っ黒に潰れ、輪郭に縁が出ていた（実際の写真で顔 R190 G115 B83、
/// フジフラッシュは R220 G175 B153）。そこで
/// 1. 写真全体の平均の色から、電球のオレンジを打ち消す（白い物が白に近づく。肌の血色は少し残す）
/// 2. 少し明るくし、黒を少し持ち上げ、白飛びをなだらかにするトーンカーブ
/// 3. 彩度を少し落とし、暗い所をわずかに青く、細かい粒子を足す
enum DirectFlash {
    static let finishKernel: CIKernel? = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? CIKernel(functionName: "flashFinish", fromMetalLibraryData: data)
    }()

    /// 平均の色を読むだけに使う（1 画素だけ描く）
    private static let context = CIContext(options: [.cacheIntermediates: false])

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
        return finish(relit, extent: extent)
    }

    /// フィルムのフラッシュ風の仕上げ（色の偏りの打ち消し・明るさ・トーンカーブ・彩度・粒子・周辺の落ち込み）
    static func finish(_ image: CIImage, extent: CGRect) -> CIImage {
        var result = image
        // 1. 平均の色（リニア）を、緑に対して赤 1.04 倍・青 0.97 倍（ほんのり暖かい）に近づける。
        //    全部は直さず 0.85 乗にとどめ、極端な色の場所（夕日・単色の壁）で大きく転ばないよう倍率を制限する
        var pixel = [Float](repeating: 0, count: 4)
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: extent)])
        context.render(average, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: nil)
        if pixel[0] > 1e-4, pixel[1] > 1e-4, pixel[2] > 1e-4 {
            let gainR = pow(min(max(1.04 * pixel[1] / pixel[0], 0.7), 1.3), 0.85)
            let gainB = pow(min(max(0.97 * pixel[1] / pixel[2], 0.7), 1.5), 0.85)
            result = result.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(gainR), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(gainB), w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        }
        // 2. 少し明るく（1/3 段）
        result = result.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.32])
        // 3. トーンカーブ・彩度・暗部の青み・粒子（粒子は長辺 4000 で 1 画素ほどの細かさ）
        if let finishKernel {
            let grainScale = max(1, max(extent.width, extent.height) / 4000)
            let noise = (CIFilter(name: "CIRandomGenerator")?.outputImage ?? CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)))
                .transformed(by: CGAffineTransform(scaleX: grainScale, y: grainScale))
                .cropped(to: extent)
            result = finishKernel.apply(extent: extent, roiCallback: { _, rect in rect },
                                        arguments: [result, noise, Float(0.82), Float(0.024)]) ?? result
        }
        return result
            .applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 0.25, kCIInputRadiusKey: 1.6])
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
