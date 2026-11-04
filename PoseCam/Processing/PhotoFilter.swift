import CoreImage

enum PhotoFilter: String, CaseIterable, Identifiable {
    case none, natural, warm, cool, pink, film, chrome, fade, instant, sepia, mono, noir

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "なし"
        case .natural: return "ナチュラル"
        case .warm: return "ウォーム"
        case .cool: return "クール"
        case .pink: return "ピンク"
        case .film: return "フィルム"
        case .chrome: return "クローム"
        case .fade: return "フェード"
        case .instant: return "インスタント"
        case .sepia: return "セピア"
        case .mono: return "モノクロ"
        case .noir: return "ノワール"
        }
    }

    func apply(to image: CIImage) -> CIImage {
        switch self {
        case .none:
            return image
        case .natural:
            return image.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.35])
        case .warm:
            return Self.colorMatrix(image, r: 1.08, g: 1.0, b: 0.9)
        case .cool:
            return Self.colorMatrix(image, r: 0.92, g: 1.0, b: 1.08)
        case .pink:
            return Self.colorMatrix(image, r: 1.06, g: 0.96, b: 1.02, bias: 0.02)
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 0.9,
                    kCIInputBrightnessKey: 0.02,
                    kCIInputContrastKey: 0.95,
                ])
        case .film:
            return image.applyingFilter("CIPhotoEffectProcess")
        case .chrome:
            return image.applyingFilter("CIPhotoEffectChrome")
        case .fade:
            return image.applyingFilter("CIPhotoEffectFade")
        case .instant:
            return image.applyingFilter("CIPhotoEffectInstant")
        case .sepia:
            return image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.7])
        case .mono:
            return image.applyingFilter("CIPhotoEffectMono")
        case .noir:
            return image.applyingFilter("CIPhotoEffectNoir")
        }
    }

    private static func colorMatrix(_ image: CIImage, r: CGFloat, g: CGFloat, b: CGFloat,
                                     bias: CGFloat = 0) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
        ])
    }
}
