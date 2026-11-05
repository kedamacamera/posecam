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
        if settings.needsSkinMask, let masks {
            image = beautify(image, settings: settings, masks: masks)
        }
        image = settings.filter.apply(to: image, strength: settings.filterStrength)
        if settings.legLength > 0.01, let hipY {
            image = stretchLegs(image, hipY: hipY, amount: settings.legLength)
        }
        return image.cropped(to: extent)
    }

    // MARK: - 美肌・美白

    private func beautify(_ image: CIImage, settings: ProcessingSettings, masks: BeautyMasks) -> CIImage {
        let extent = image.extent
        let longSide = max(extent.width, extent.height)
        let base = skinBase(image, masks: masks, longSide: longSide)
        let mask = applyFeatures(base, masks.features)
        var result = image

        // シミ（暗い点）は広めの範囲、シワ（暗い細い線）は狭めの範囲の平均と比べて、暗い所だけ埋める
        if settings.blemish > 0.01 {
            let removed = removeDarkSpots(result, strength: settings.blemish, radius: longSide * 0.008,
                                          low: 0.008, high: 0.05, cap: 0.12)
            result = blend(removed, over: result, mask: mask, amount: 1)
        }
        if settings.wrinkle > 0.01 {
            let removed = removeDarkSpots(result, strength: settings.wrinkle, radius: longSide * 0.004,
                                          low: 0.005, high: 0.035, cap: 0.09)
            result = blend(removed, over: result, mask: mask, amount: 1)
        }
        if settings.redness > 0.01 {
            // 周りの肌より赤い所だけを、周りの肌の色になじませる。眉の際・小鼻の際も対象にする（目と唇だけ外す）
            let redMask = applyFeatures(base, masks.redFeatures)
            let calmed = removeRedness(result, mask: redMask, strength: settings.redness, longSide: longSide)
            result = blend(calmed, over: result, mask: redMask, amount: 1)
        }
        if settings.beard > 0.01, let beard = masks.beard {
            // 青ひげ: ひげの所だけ、周りの肌（頬）の色との差のうち青み・暗さを打ち消す
            // 剃り跡の青黒い所は「肌の色」の判定から外れることがあるので、肌の色ではなく肌の領域（モデル）で絞る
            let skinRegion = Self.gray(masks.skin ?? masks.person ?? base)
                .clampedToExtent().applyingGaussianBlur(sigma: longSide * 0.006).cropped(to: extent)
            // 剃り跡の所は肌のモデルの確からしさが下がるので、2 倍して 1 で止める（顔の輪郭の内側だけなので背景には出ない）
            let beardMask = beard.applyingFilter("CIMultiplyCompositing", parameters: [
                kCIInputBackgroundImageKey: Self.boosted(skinRegion)])
            let concealed = concealBeard(result, beardMask: beardMask, skinMask: mask, strength: settings.beard,
                                         longSide: longSide)
            result = blend(concealed, over: result, mask: beardMask, amount: 1)
        }
        if settings.smoothing > 0.01 {
            // なめらかにした画像は元の画像と同じ明るさ・色なので、混ぜても肌の色は変わらない。
            // 強くしたときはほぼ置き換え、弱いときは元の質感を残す
            let smooth = bilateralSmooth(result, amount: settings.smoothing, longSide: longSide)
            let a = settings.smoothing
            result = blend(smooth, over: result, mask: mask, amount: min(1, 0.15 + 0.85 * a))
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
        if settings.contour > 0.01, let shade = masks.jawShade {
            // 輪郭: あごのすぐ外側（首との境目）に影を入れる。肌（人物）の所だけにかけ、背景は暗くしない
            let region = Self.gray(masks.skin ?? masks.person ?? base)
                .clampedToExtent().applyingGaussianBlur(sigma: longSide * 0.01).cropped(to: extent)
            let shadeMask = shade.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: region])
            let shaded = result.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -0.9 * settings.contour])
            result = blend(shaded, over: result, mask: shadeMask, amount: 1)
        }
        return result
    }

    /// 1 チャンネルのマスク（肌のモデル・人物の判定の結果は赤にしか値がない）を、R・G・B すべて同じ値の灰色にする。
    /// 掛け合わせ（CIMultiplyCompositing）に使うと、緑・青が 0 のままで、混ぜる強さが 3 割ほどに落ちてしまうため。
    static func gray(_ mask: CIImage) -> CIImage {
        mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    /// マスクを 2 倍して 1 で止める（半分以上の確からしさなら全部かける）
    static func boosted(_ mask: CIImage) -> CIImage {
        mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 2, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 2, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 2, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]).applyingFilter("CIColorClamp")
    }

    static let beardKernel: CIKernel? = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? CIKernel(functionName: "beardConceal", fromMetalLibraryData: data)
    }()

    /// 青ひげを、ひげの所を除いた周りの肌（頬など）の色に近づける（BeautyKernels.ci.metal の beardConceal）。
    private func concealBeard(_ image: CIImage, beardMask: CIImage, skinMask: CIImage, strength: Double,
                              longSide: CGFloat, debug: Bool = false) -> CIImage {
        guard let kernel = Self.beardKernel else { return image }
        let extent = image.extent
        let black = CIImage(color: .black).cropped(to: extent)
        // 参照する肌 = 肌のうちひげの所ではない所。ひげの範囲の中央まで届くよう広くぼかす
        let notBeard = beardMask.applyingFilter("CIColorInvert")
        let reference = skinMask.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: notBeard])
        let sigma = longSide * 0.03
        let skinOnly = image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: black,
            kCIInputMaskImageKey: reference,
        ])
        let sum = skinOnly.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        let weight = reference.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        // 剃り跡のむらは毛穴より大きいので、少しぼかした色で判定する
        let local = image.clampedToExtent().applyingGaussianBlur(sigma: longSide * 0.004).cropped(to: extent)
        let output = kernel.apply(extent: extent, roiCallback: { _, rect in rect },
                                  arguments: [image, local, sum, weight, Float(strength), Float(debug ? 1 : 0)])
        return output?.cropped(to: extent) ?? image
    }

    /// 確認用: 青ひげ隠しの中の値を色で表した画像（赤: 効き具合、緑: 参照できる肌の量 ×10、青: 青み ×10）。
    func beardDebug(_ image: CIImage, masks: BeautyMasks) -> CIImage? {
        guard let beard = masks.beard else { return nil }
        let extent = image.extent
        let longSide = max(extent.width, extent.height)
        let base = skinBase(image, masks: masks, longSide: longSide)
        let mask = applyFeatures(base, masks.features)
        let skinRegion = Self.gray(masks.skin ?? masks.person ?? base)
            .clampedToExtent().applyingGaussianBlur(sigma: longSide * 0.006).cropped(to: extent)
        let beardMask = beard.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: Self.boosted(skinRegion)])
        return concealBeard(image, beardMask: beardMask, skinMask: mask, strength: 1, longSide: longSide, debug: true)
    }

    /// 青ひげ隠しの範囲（白）。確認用のツールから使う。
    func beardMask(_ image: CIImage, masks: BeautyMasks) -> CIImage? {
        let longSide = max(image.extent.width, image.extent.height)
        return masks.beard?.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: skinBase(image, masks: masks, longSide: longSide)])
    }

    /// 美肌をかける範囲（白）。肌の領域のうち肌の色の所だけで、目・眉・唇を除いたもの。
    /// メガネのフチ・髪の毛・眉は肌の色ではないので、肌の色の判定で外れる。
    /// 確認用のツール（tools/verify）からも使う。
    func beautyMask(_ image: CIImage, masks: BeautyMasks) -> CIImage {
        let longSide = max(image.extent.width, image.extent.height)
        return applyFeatures(skinBase(image, masks: masks, longSide: longSide), masks.features)
    }

    /// 赤み消しをかける範囲（白）。確認用のツールから使う。
    func rednessMask(_ image: CIImage, masks: BeautyMasks) -> CIImage {
        let longSide = max(image.extent.width, image.extent.height)
        return applyFeatures(skinBase(image, masks: masks, longSide: longSide), masks.redFeatures)
    }

    static let rednessKernel: CIKernel? = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? CIKernel(functionName: "rednessRemoval", fromMetalLibraryData: data)
    }()

    /// 周りの肌より赤い所を、周りの肌だけの平均の色に近づける（BeautyKernels.ci.metal の rednessRemoval）。
    private func removeRedness(_ image: CIImage, mask: CIImage, strength: Double, longSide: CGFloat) -> CIImage {
        guard let kernel = Self.rednessKernel else { return image }
        let extent = image.extent
        let black = CIImage(color: .black).cropped(to: extent)
        // ニキビ数個ぶんより広い範囲の「肌だけ」の平均を取る
        let sigma = longSide * 0.012
        let skinOnly = image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: black,
            kCIInputMaskImageKey: mask,
        ])
        let sum = skinOnly.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        let weight = mask.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        let output = kernel.apply(extent: extent, roiCallback: { _, rect in rect },
                                  arguments: [image, sum, weight, Float(strength)])
        return output?.cropped(to: extent) ?? image
    }

    /// 自作のバイラテラルフィルタ（BeautyKernels.ci.metal）。アプリに入っていなければ nil
    static let bilateralKernel: CIKernel? = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? CIKernel(functionName: "bilateral", fromMetalLibraryData: data)
    }()

    static let darkSpotKernel: CIKernel? = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? CIKernel(functionName: "darkSpotRemoval", fromMetalLibraryData: data)
    }()

    /// 周りの平均より暗い所（シミ・シワ）を、周りの平均の色で埋める。
    private func removeDarkSpots(_ image: CIImage, strength: Double, radius: CGFloat,
                                 low: Double, high: Double, cap: Double) -> CIImage {
        guard let kernel = Self.darkSpotKernel else { return image }
        let clamped = image.clampedToExtent()
        let mean = clamped.applyingGaussianBlur(sigma: radius).cropped(to: image.extent)
        let local = clamped.applyingGaussianBlur(sigma: max(1, radius * 0.2)).cropped(to: image.extent)
        let darkest = clamped.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: max(2, radius * 0.4)])
            .cropped(to: image.extent)
        let output = kernel.apply(
            extent: image.extent,
            roiCallback: { _, rect in rect },
            arguments: [image, local, darkest, mean, Float(strength), Float(low), Float(high), Float(cap)])
        return output?.cropped(to: image.extent) ?? image
    }

    /// 色が近い画素どうしだけを平均して、肌をなめらかにする（境目は混ざらない・明るさは変わらない）。
    private func bilateralSmooth(_ image: CIImage, amount: Double, longSide: CGFloat) -> CIImage {
        guard let kernel = Self.bilateralKernel else { return edgePreservingSmooth(image, amount: amount) }
        // 長辺 1280 なら 半径 4〜13 ピクセル。強くするほど広い範囲・大きい色の差までならす。
        // 鼻などの陰影（もっと大きい明暗）は色の差が大きいので残る
        let radius = longSide * CGFloat(0.003 + 0.007 * amount)
        let sigmaColor = 0.04 + 0.07 * amount
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

    /// 肌の部分だけが白のマスク（顔のパーツはまだ除いていない）。
    /// 肌を塗り分けるモデルがあればその結果を、なければ「人物の領域」を使い、肌の色の所だけに絞る。
    /// 境目は大きめにぼかし、加工した所としていない所の境目が見えないようにする。
    private func skinBase(_ image: CIImage, masks: BeautyMasks, longSide: CGFloat) -> CIImage {
        let black = CIImage(color: .black).cropped(to: image.extent)
        let skinColor = image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": Self.cubeSize,
            "inputCubeData": skinCube,
            "inputColorSpace": sRGB,
        ])
        // 肌のモデル（なければ人物の領域）の外側の境目（顔の輪郭・首・髪の生え際）は大きくぼかしてなじませる
        let region = (masks.skin ?? masks.person ?? black)
            .clampedToExtent().applyingGaussianBlur(sigma: longSide * 0.008).cropped(to: image.extent)
        // そのうえで、肌の色の所だけに絞る。モデルはメガネのフチなども「顔」に含めるが、
        // 黒いフチ・眉・髪は肌の色ではないので外れる
        let mask = skinColor.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: black,
            kCIInputMaskImageKey: region,
        ])
        // 肌の色の判定は画素ごとにばらつくので、ごく軽くだけぼかす。強くぼかすとメガネのフチのような
        // 細くて暗い線まで加工の範囲に入り、フチが薄くなる
        return mask.clampedToExtent().applyingGaussianBlur(sigma: longSide * 0.0012).cropped(to: image.extent)
    }

    /// 顔のパーツのマスク（黒が外す所）を掛ける。
    private func applyFeatures(_ base: CIImage, _ features: CIImage?) -> CIImage {
        guard let features else { return base }
        return base.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: features])
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

    /// YCbCr の肌色範囲（Cb 78〜126, Cr 134〜182）を 1、外側をなだらかに 0 にするカラーキューブ。
    /// 赤いニキビ（Cr が高い）も肌に含め、赤み消し・美肌の範囲から漏れて目立たないようにする。
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
                    // 範囲の外はなだらかに 0 にする（背景などは肌のモデルの範囲で先に除いている）
                    let v = soft(cb, 78, 126, 12) * soft(cr, 134, 182, 16) * soft(luma, 40, 250, 20)
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
