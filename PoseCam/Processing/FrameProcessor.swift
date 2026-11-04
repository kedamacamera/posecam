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
        let mask = skinMask(image, masks: masks, blurRadius: longSide * 0.003)
        var result = image

        if settings.smoothing > 0.01 {
            let smooth = frequencySeparatedSmooth(image, amount: settings.smoothing, longSide: longSide)
            result = blend(smooth, over: result, mask: mask, amount: min(1, 1.1 * settings.smoothing))
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

    /// 周波数分離の美肌（プロのレタッチと同じ考え方）。
    /// 画像を「色むら・凹凸などの大きな成分」と「毛穴やきめなどの細かい成分」に分け、
    /// 大きな成分だけをなめらかにしてから、細かい成分を一定量戻す。
    /// こうすると、むらは消えても肌の質感が残り、のっぺりした「塗った肌」にならない。
    private func frequencySeparatedSmooth(_ image: CIImage, amount: Double, longSide: CGFloat) -> CIImage {
        let extent = image.extent
        // 細かい成分 = 元の画像 − 少しだけぼかした画像。負の値を扱えないので 0.5 を足して持つ
        let fine = image.clampedToExtent()
            .applyingGaussianBlur(sigma: longSide * 0.0012)
            .cropped(to: extent)
        let shifted = image.applyingFilter("CIColorMatrix", parameters: [
            "inputBiasVector": CIVector(x: 0.5, y: 0.5, z: 0.5, w: 0),
        ])
        let detail = shifted.applyingFilter("CISubtractBlendMode", parameters: [
            kCIInputBackgroundImageKey: fine,
        ])

        // 大きな成分は、輪郭を残したままなめらかにする
        let base = edgePreservingSmooth(image, amount: amount)

        // 細かい成分を戻す量。強くするほど少なめに戻す（0.6 → 0.3）
        let keep = CGFloat(0.6 - 0.3 * amount)
        // リニアライト合成は「下 + 2 ×（上 − 0.5）」なので、上を 0.5 + keep/2 ×（細かい成分）にしておく
        let scaledDetail = detail.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: keep / 2, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: keep / 2, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: keep / 2, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0.5 - keep / 4, y: 0.5 - keep / 4, z: 0.5 - keep / 4, w: 0),
        ])
        return scaledDetail.applyingFilter("CILinearLightBlendMode", parameters: [
            kCIInputBackgroundImageKey: base,
        ])
        .cropped(to: extent)
    }

    /// 輪郭を保ったまま、平らな部分（肌）だけをなめらかにする。
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
            "inputLumaSigma": 0.06 + 0.1 * amount,
        ])
        .cropped(to: extent)
    }

    /// 人物の領域の中の肌色の部分だけが白で、目・眉・唇は黒になるマスク。
    private func skinMask(_ image: CIImage, masks: BeautyMasks, blurRadius: CGFloat) -> CIImage {
        let skin = image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": Self.cubeSize,
            "inputCubeData": skinCube,
            "inputColorSpace": sRGB,
        ])
        let black = CIImage(color: .black).cropped(to: image.extent)
        var mask = skin.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: black,
            kCIInputMaskImageKey: masks.person,
        ])
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
