import CoreImage
import Foundation
import simd

/// 色の仕上げ（ルック）。どれも 3D LUT（色の対応表）を計算で作り、CIColorCubeWithColorSpace で 1 回でかける。
///
/// 作り方の考え方（フィルム・シネマ系のルックに共通する要素）:
/// - トーンカーブ: コントラストの強弱と、黒の持ち上げ（フェード）・白の抑え（ハイライトを白飛びさせない）
/// - スプリットトーン: 暗部と明部に別の色を薄く乗せる（暗部にシアン寄り、明部に暖色寄りが映画・フィルムの定番）
/// - 色相ごとの彩度: 緑は少し抑えて色相をずらす（フィルムらしい落ち着いた緑）、肌のオレンジは残す
/// - 色温度: 全体を暖かく / 涼しく
enum PhotoFilter: String, CaseIterable, Identifiable {
    case none, natural, cineFilm, film, warmFilm, coolFilm, clear, vintage, bleach, mono, noir

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "なし"
        case .natural: return "ナチュラル"
        case .cineFilm: return "シネフィルム"
        case .film: return "フィルム"
        case .warmFilm: return "ウォーム"
        case .coolFilm: return "クール"
        case .clear: return "クリア"
        case .vintage: return "ヴィンテージ"
        case .bleach: return "ブリーチ"
        case .mono: return "モノクロ"
        case .noir: return "ノワール"
        }
    }

    /// それぞれのルックの中身。
    fileprivate var look: Look? {
        switch self {
        case .none:
            return nil
        case .natural:
            // 色は自然なまま、少しだけメリハリと血色を足す
            return Look(contrast: 0.12, saturation: 1.06, warmth: 0.12)
        case .cineFilm:
            // ソニーのクリエイティブルック「FL3」の方向性: コントラストを少し抑え、色はクリアに、全体を軽く。
            // 暗部はわずかにシアン、明部はわずかに暖色。緑は少し抑えてシアン寄りに
            return Look(exposure: 0.08, contrast: -0.18, lift: 0.035, ceiling: 0.975, saturation: 1.04,
                        warmth: 0.08, shadowTint: [-0.020, 0.004, 0.024], highlightTint: [0.014, 0.008, -0.010],
                        greenSaturation: 0.8, greenHueShift: 10, blueSaturation: 1.05)
        case .film:
            // 映画フィルム風: コントラストはやや強め、黒は少し浮かせ、色は落ち着かせる。暗部シアン・明部イエロー、緑はオリーブ寄り
            return Look(contrast: 0.18, lift: 0.045, ceiling: 0.96, saturation: 0.82, warmth: 0.18,
                        shadowTint: [-0.030, 0.010, 0.030], highlightTint: [0.024, 0.016, -0.020],
                        greenSaturation: 0.65, greenHueShift: -8)
        case .warmFilm:
            // 暖色系のネガフィルム風: 柔らかいコントラスト、肌がきれいに見える暖かさ、クリーム色のハイライト
            return Look(exposure: 0.05, contrast: -0.05, lift: 0.04, ceiling: 0.97, saturation: 0.9,
                        warmth: 0.45, tint: 0.08, highlightTint: [0.020, 0.010, -0.015],
                        greenSaturation: 0.8, greenHueShift: -6)
        case .coolFilm:
            // 寒色系のフィルム風: 暗部は緑がかったシアン、青は深く、肌は白っぽく
            return Look(contrast: 0.08, lift: 0.035, saturation: 0.95, warmth: -0.2, tint: -0.05,
                        shadowTint: [-0.020, 0.015, 0.020], highlightTint: [0.010, 0, 0.010],
                        greenSaturation: 0.95, greenHueShift: 8, blueSaturation: 1.1)
        case .clear:
            // 明るく透明感のある韓国風: 明るめ・低コントラスト・やや涼しげ
            return Look(exposure: 0.12, contrast: -0.15, lift: 0.02, saturation: 0.9, warmth: -0.15)
        case .vintage:
            // 色あせた古い写真風: 黒を大きく浮かせ、彩度を落として暖かく
            return Look(contrast: -0.1, lift: 0.08, ceiling: 0.94, saturation: 0.75, warmth: 0.4,
                        highlightTint: [0.020, 0.015, -0.020])
        case .bleach:
            // 銀残し風: 強いコントラストと低い彩度
            return Look(contrast: 0.35, lift: 0.015, saturation: 0.5)
        case .mono:
            // フィルムの白黒風: 赤をやや明るく（肌がきれいに出る）、黒は少し浮かせる
            return Look(contrast: 0.12, lift: 0.03, monoWeights: [0.35, 0.5, 0.15])
        case .noir:
            return Look(contrast: 0.45, monoWeights: [0.4, 0.45, 0.15])
        }
    }

    func apply(to image: CIImage) -> CIImage {
        guard let data = Self.cubes[self] else { return image }
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": Self.cubeSize,
            "inputCubeData": data,
            "inputColorSpace": Self.sRGB,
        ])
    }

    private static let cubeSize = 33
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    /// 最初に使うときに全部のルックの表を作る（全部で数ミリ秒）
    private static let cubes: [PhotoFilter: Data] = {
        var result: [PhotoFilter: Data] = [:]
        for filter in allCases {
            if let look = filter.look { result[filter] = look.makeCube(size: cubeSize) }
        }
        return result
    }()
}

/// ルックの材料。色はすべて sRGB（ガンマのかかった 0...1）で扱う。
private struct Look {
    /// 明るさ（段）
    var exposure: Float = 0
    /// コントラスト（-0.5...0.5）。正で強く、負で柔らかく
    var contrast: Float = 0
    /// いちばん暗い所の明るさ（黒の持ち上げ・フェード）
    var lift: Float = 0
    /// いちばん明るい所の明るさ
    var ceiling: Float = 1
    var saturation: Float = 1
    /// 正で暖かく（黄〜オレンジ寄り）、負で涼しく（青寄り）
    var warmth: Float = 0
    /// 正でマゼンタ寄り、負で緑寄り
    var tint: Float = 0
    /// 暗い所に足す色
    var shadowTint: SIMD3<Float> = .zero
    /// 明るい所に足す色
    var highlightTint: SIMD3<Float> = .zero
    /// 緑の彩度
    var greenSaturation: Float = 1
    /// 緑の色相のずらし（度）。正でシアン寄り、負で黄寄り
    var greenHueShift: Float = 0
    /// 青の彩度
    var blueSaturation: Float = 1
    /// 白黒にするときの R・G・B の重み
    var monoWeights: SIMD3<Float>?

    func makeCube(size n: Int) -> Data {
        var values = [Float](repeating: 0, count: n * n * n * 4)
        var index = 0
        let scale = 1 / Float(n - 1)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let color = transform(SIMD3(Float(r) * scale, Float(g) * scale, Float(b) * scale))
                    values[index] = color.x
                    values[index + 1] = color.y
                    values[index + 2] = color.z
                    values[index + 3] = 1
                    index += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static let lumaWeights = SIMD3<Float>(0.299, 0.587, 0.114)

    private func transform(_ input: SIMD3<Float>) -> SIMD3<Float> {
        var c = input

        // 色温度・色かぶり
        c *= SIMD3(1 + warmth * 0.06, 1 - tint * 0.04, 1 - warmth * 0.06)

        // 明るさ（光の量で変えるので、いったんガンマを外す）
        if exposure != 0 {
            let linear = SIMD3(pow(max(c.x, 0), 2.2), pow(max(c.y, 0), 2.2), pow(max(c.z, 0), 2.2)) * pow(2, exposure)
            c = SIMD3(pow(linear.x, 1 / 2.2), pow(linear.y, 1 / 2.2), pow(linear.z, 1 / 2.2))
        }
        c = simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1))

        // 色相ごとの彩度
        if greenSaturation != 1 || greenHueShift != 0 || blueSaturation != 1 {
            var (h, s, v) = Self.hsv(c)
            let green = Self.bell(h, center: 120, width: 50)
            let blue = Self.bell(h, center: 220, width: 35)
            s *= 1 + (greenSaturation - 1) * green
            s *= 1 + (blueSaturation - 1) * blue
            h += greenHueShift * green
            s = min(max(s, 0), 1)
            c = Self.rgb(h, s, v)
        }

        if let monoWeights {
            let l = simd_dot(c, monoWeights)
            c = SIMD3(repeating: l)
        } else {
            let l = simd_dot(c, Self.lumaWeights)
            c = SIMD3(repeating: l) + (c - SIMD3(repeating: l)) * saturation
        }

        // トーンカーブ（S 字）。x - k·sin(2πx)/2π は k が ±0.5 程度まで単調で、端の 0 と 1 は動かない
        let k = contrast
        func curve(_ x: Float) -> Float {
            let clamped = min(max(x, 0), 1)
            return clamped - k * sin(2 * .pi * clamped) / (2 * .pi)
        }
        c = SIMD3(curve(c.x), curve(c.y), curve(c.z))

        // スプリットトーン
        let l = simd_dot(c, Self.lumaWeights)
        c += shadowTint * (1 - l) * (1 - l) + highlightTint * l * l

        // 黒の持ち上げ・白の抑え
        c = SIMD3(repeating: lift) + c * (ceiling - lift)
        return simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1))
    }

    /// 色相 h（度）が center から width 以内で 1 に近い、なだらかな重み
    private static func bell(_ h: Float, center: Float, width: Float) -> Float {
        var d = abs(h - center)
        d = min(d, 360 - d)
        guard d < width else { return 0 }
        let t = d / width
        return 0.5 + 0.5 * cos(t * .pi)
    }

    private static func hsv(_ c: SIMD3<Float>) -> (Float, Float, Float) {
        let maxValue = max(c.x, c.y, c.z)
        let minValue = min(c.x, c.y, c.z)
        let delta = maxValue - minValue
        var h: Float = 0
        if delta > 1e-5 {
            if maxValue == c.x {
                h = 60 * ((c.y - c.z) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxValue == c.y {
                h = 60 * ((c.z - c.x) / delta + 2)
            } else {
                h = 60 * ((c.x - c.y) / delta + 4)
            }
        }
        if h < 0 { h += 360 }
        let s = maxValue > 1e-5 ? delta / maxValue : 0
        return (h, s, maxValue)
    }

    private static func rgb(_ hue: Float, _ s: Float, _ v: Float) -> SIMD3<Float> {
        var h = hue.truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        let c = v * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let rgb: SIMD3<Float>
        switch h {
        case ..<60: rgb = SIMD3(c, x, 0)
        case ..<120: rgb = SIMD3(x, c, 0)
        case ..<180: rgb = SIMD3(0, c, x)
        case ..<240: rgb = SIMD3(0, x, c)
        case ..<300: rgb = SIMD3(x, 0, c)
        default: rgb = SIMD3(c, 0, x)
        }
        return rgb + SIMD3(repeating: m)
    }
}
