import CoreImage

/// 1 枚の画像に 美肌 → フィルター → 脚長 の順で加工をかける。
/// 状態を持たないので、プレビュー（映像キュー）と写真（写真キュー）から同時に使ってよい。
final class FrameProcessor {
    private static let cubeSize = 32
    private let skinCube: Data
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    init() {
        skinCube = Self.makeSkinCube(size: Self.cubeSize)
    }

    /// hipY: 腰の高さ（画像座標・上が 0）。masks: 人物の領域と顔のパーツ。
    /// どちらも人物が見つからないときは nil で、そのときは美肌・脚長をかけない。
    func process(_ input: CIImage, settings: ProcessingSettings, hipY: CGFloat?, masks: BeautyMasks?) -> CIImage {
        let extent = input.extent
        var image = input
        if settings.smoothing > 0.01 || settings.brightening > 0.01, let masks {
            image = beautify(image, settings: settings, masks: masks)
        }
        image = settings.filter.apply(to: image)
        if settings.legLength > 0.01, let hipY {
            image = stretchLegs(image, hipY: hipY, amount: settings.legLength)
        }
        return image.cropped(to: extent)
    }

    // MARK: - 美肌・美白

    private func beautify(_ image: CIImage, settings: ProcessingSettings, masks: BeautyMasks) -> CIImage {
        let extent = image.extent
        let longSide = max(extent.width, extent.height)
        let mask = beautyMask(image, masks: masks)
        var result = image

        if settings.smoothing > 0.01 {
            // なめらかにした画像は元の画像と同じ明るさ・色なので、混ぜても肌の色は変わらない。
            // 完全には置き換えず、元の質感を少し残す
            let smooth = bilateralSmooth(image, amount: settings.smoothing, longSide: longSide)
            result = blend(smooth, over: result, mask: mask, amount: 0.85 * settings.smoothing)
        }
        if settings.brightening > 0.01 {
            let brightened = result
                .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.6 * settings.brightening])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 1 - 0.15 * settings.brightening,
                    kCIInputBrightnessKey: 0.0,
                    kCIInputContrastKey: 1.0,
                ])
            result = blend(brightened, over: result, mask: mask, amount: settings.brightening)
        }
        return result
    }

    /// 美肌をかける範囲（白）。肌の領域から、目・眉・唇と、メガネのフチなどのはっきりした線を除いたもの。
    /// 確認用のツール（tools/verify）からも使う。
    func beautyMask(_ image: CIImage, masks: BeautyMasks) -> CIImage {
        let extent = image.extent
        let longSide = max(extent.width, extent.height)
        let black = CIImage(color: .black).cropped(to: extent)
        return skinMask(image, masks: masks, blurRadius: longSide * 0.003)
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: black,
                kCIInputMaskImageKey: edgeProtection(image, longSide: longSide),
            ])
    }

    /// 自作のバイラテラルフィルタ（BeautyKernels.ci.metal）。アプリに入っていなければ nil
    static let bilateralKernel: CIKernel? = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? CIKernel(functionName: "bilateral", fromMetalLibraryData: data)
    }()

    /// 色が近い画素どうしだけを平均して、肌をなめらかにする（境目は混ざらない・明るさは変わらない）。
    private func bilateralSmooth(_ image: CIImage, amount: Double, longSide: CGFloat) -> CIImage {
        guard let kernel = Self.bilateralKernel else { return edgePreservingSmooth(image, amount: amount) }
        // 長辺 1920 なら 半径 8〜19 ピクセル
        let radius = longSide * CGFloat(0.004 + 0.006 * amount)
        let sigmaColor = 0.05 + 0.05 * amount
        let output = kernel.apply(
            extent: image.extent,
            roiCallback: { _, rect in rect.insetBy(dx: -radius - 1, dy: -radius - 1) },
            arguments: [image.clampedToExtent(), Float(radius), Float(sigmaColor)])
        return output?.cropped(to: image.extent) ?? edgePreservingSmooth(image, amount: amount)
    }

    /// 輪郭を保ったまま、平らな部分（肌）だけをなめらかにする（カーネルが使えないときの代わり）。
    /// 縮小してぼかした画像を、元の画像の明るさの差を手がかりに拡大し直す（ガイド付きフィルタに近い）。
    /// 明るさの差が大きい所（目・眉・髪の境目）は元のまま残る。
    private func edgePreservingSmooth(_ image: CIImage, amount: Double) -> CIImage {
        let extent = image.extent
        let factor: CGFloat = 1.0 / 6.0
        let small = image
            .transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 1 + 1.5 * amount)
            .cropped(to: CGRect(x: 0, y: 0, width: extent.width * factor, height: extent.height * factor))
        return image.applyingFilter("CIEdgePreserveUpsampleFilter", parameters: [
            "inputSmallImage": small,
            "inputSpatialSigma": 3.0,
            // 小さいほど輪郭を強く残す。大きいとメガネのフチなどまでぼやける
            "inputLumaSigma": 0.03 + 0.05 * amount,
        ])
        .cropped(to: extent)
    }

    /// はっきりした線（メガネのフチ・まつ毛・髪の毛先）が黒、それ以外が白のマスク。
    /// 毛穴のような細かい凹凸は拾わないよう、強い線だけを残してから少し太らせる。
    private func edgeProtection(_ image: CIImage, longSide: CGFloat) -> CIImage {
        let extent = image.extent
        let strongEdges = image
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
            .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 1.0])
            // 線の強さ v を (v - 0.12) × 5 にして、弱い凹凸を 0 にする
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 5, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 5, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 5, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: -0.6, y: -0.6, z: -0.6, w: 0),
            ])
            .applyingFilter("CIColorClamp")
        return strongEdges
            .clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(1, longSide * 0.002)])
            .applyingGaussianBlur(sigma: longSide * 0.0015)
            .applyingFilter("CIColorInvert")
            .cropped(to: extent)
    }

    /// 肌の部分だけが白で、目・眉・唇は黒になるマスク。
    /// 肌を塗り分けるモデルがあればその結果を、なければ「人物の領域 × 肌の色」を使う。
    private func skinMask(_ image: CIImage, masks: BeautyMasks, blurRadius: CGFloat) -> CIImage {
        let black = CIImage(color: .black).cropped(to: image.extent)
        var mask: CIImage
        if let skin = masks.skin {
            mask = skin
        } else {
            let skinColor = image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": Self.cubeSize,
                "inputCubeData": skinCube,
                "inputColorSpace": sRGB,
            ])
            mask = skinColor.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: black,
                kCIInputMaskImageKey: masks.person ?? black,
            ])
        }
        mask = mask.clampedToExtent().applyingGaussianBlur(sigma: blurRadius).cropped(to: image.extent)
        if let features = masks.features {
            mask = mask.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: black,
                kCIInputMaskImageKey: features,
            ])
        }
        return mask
    }

    private func blend(_ foreground: CIImage, over background: CIImage, mask: CIImage, amount: Double) -> CIImage {
        let a = CGFloat(amount)
        let scaledMask = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        return foreground.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: scaledMask,
        ])
    }

    /// YCbCr の肌色範囲（Cb 77〜127, Cr 133〜173）を 1、外側をなだらかに 0 にするカラーキューブ。
    private static func makeSkinCube(size n: Int) -> Data {
        var values = [Float](repeating: 0, count: n * n * n * 4)
        var index = 0
        let step: Float = 255 / Float(n - 1)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let red = Float(r) * step
                    let green = Float(g) * step
                    let blue = Float(b) * step
                    let luma: Float = 0.299 * red + 0.587 * green + 0.114 * blue
                    let cb: Float = 128 - 0.168736 * red - 0.331264 * green + 0.5 * blue
                    let cr: Float = 128 + 0.5 * red - 0.418688 * green - 0.081312 * blue
                    // 灰色（Cb・Cr ≒ 128）が肌と判定されないよう、範囲の外はすぐ 0 にする
                    let v = soft(cb, 80, 125, 4) * soft(cr, 136, 170, 4) * soft(luma, 60, 250, 15)
                    values[index] = v
                    values[index + 1] = v
                    values[index + 2] = v
                    values[index + 3] = 1
                    index += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func soft(_ x: Float, _ low: Float, _ high: Float, _ falloff: Float) -> Float {
        if x < low { return max(0, 1 - (low - x) / falloff) }
        if x > high { return max(0, 1 - (x - high) / falloff) }
        return 1
    }

    // MARK: - 脚長

    /// 腰から下を縦に伸ばし、そのぶん上半身を少し縮めて画像の高さを保つ。
    private func stretchLegs(_ image: CIImage, hipY: CGFloat, amount: Double) -> CIImage {
        let e = image.extent
        // Core Image は左下原点なので、腰の位置を下からの距離に直す
        let hip = (1 - hipY) * e.height
        guard hip > e.height * 0.15, hip < e.height * 0.85 else { return image }

        let newHip = min(hip * (1 + 0.2 * CGFloat(amount)), e.height * 0.9)
        let legScale = newHip / hip
        let bodyScale = (e.height - newHip) / (e.height - hip)

        let toOrigin = CGAffineTransform(translationX: -e.minX, y: -e.minY)
        let base = image.transformed(by: toOrigin)
        let lower = base
            .cropped(to: CGRect(x: 0, y: 0, width: e.width, height: hip))
            .clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: 1, y: legScale))
            .cropped(to: CGRect(x: 0, y: 0, width: e.width, height: newHip))
        let upper = base
            .cropped(to: CGRect(x: 0, y: hip, width: e.width, height: e.height - hip))
            .clampedToExtent()
            .transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: bodyScale, tx: 0, ty: newHip - hip * bodyScale))
            .cropped(to: CGRect(x: 0, y: newHip, width: e.width, height: e.height - newHip))
        return upper.composited(over: lower).transformed(by: toOrigin.inverted())
    }
}
