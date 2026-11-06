import CoreImage

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
/// 上げたのと同じ）」になる。比べるのはぼかした明るさなので、多少の手ぶれでは崩れない。
/// さらに、フラッシュらしい硬さ（パキッとした感じ）を出すため、輪郭のコントラスト（明瞭度）と全体のコントラストを上げる。
enum DirectFlash {
    static let kernel: CIKernel? = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? CIKernel(functionName: "directFlash", fromMetalLibraryData: data)
    }()

    /// photo と ambient は同じ大きさ・同じ切り抜き。exposureRatio は（写真の露出）/（コマの露出）。
    static func apply(photo: CIImage, ambient: CIImage, exposureRatio: Double, ambientGain: Double = 0.125) -> CIImage {
        guard let kernel else { return photo }
        let extent = photo.extent
        let sigma = max(extent.width, extent.height) * 0.006
        // ぼかした明るさは 1/8 に縮めた画像で求めてから元の大きさに戻す（結果はほぼ同じで、ずっと軽い）。
        // 写真の大きさのままぼかすと処理が重く、続けて撮ると書き出しに失敗することがあった
        let photoLow = Self.lowPass(photo, sigma: sigma)
        let ambientLow = Self.lowPass(ambient, sigma: sigma)
        guard let relit = kernel.apply(extent: extent, roiCallback: { _, rect in rect },
                                       arguments: [photo, photoLow, ambientLow, Float(exposureRatio),
                                                   Float(ambientGain)]) else { return photo }
        // 明瞭度（大きめの半径のアンシャープマスク）とコントラストで硬い光にし、周辺の落ち込みを少し足す
        return relit.cropped(to: extent)
            .clampedToExtent()
            .applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: max(extent.width, extent.height) * 0.008,
                                                          kCIInputIntensityKey: 0.45])
            .cropped(to: extent)
            .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.12, kCIInputSaturationKey: 1.05,
                                                            kCIInputBrightnessKey: 0])
            .applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 0.45, kCIInputRadiusKey: 1.6])
            .cropped(to: extent)
    }

    /// 1/8 に縮めてぼかし、元の大きさ・位置に戻す
    static func lowPass(_ image: CIImage, sigma: CGFloat) -> CIImage {
        let extent = image.extent
        let factor: CGFloat = 0.125
        let toOrigin = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        let small = image.transformed(by: toOrigin.concatenating(CGAffineTransform(scaleX: factor, y: factor)))
        let blurred = small.clampedToExtent()
            .applyingGaussianBlur(sigma: max(0.5, sigma * factor))
        return blurred
            .transformed(by: CGAffineTransform(scaleX: 1 / factor, y: 1 / factor)
                .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY)))
            .cropped(to: extent)
    }
}
