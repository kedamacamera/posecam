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
/// 結果は「フラッシュの光はそのまま、周りの光だけを ambientGain 倍（既定 1/4 = 2 段分シャッター速度を
/// 上げたのと同じ）」になる。比べるのはぼかした明るさなので、多少の手ぶれでは崩れない。
enum DirectFlash {
    static let kernel: CIKernel? = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? CIKernel(functionName: "directFlash", fromMetalLibraryData: data)
    }()

    /// photo と ambient は同じ大きさ・同じ切り抜き。exposureRatio は（写真の露出）/（コマの露出）。
    static func apply(photo: CIImage, ambient: CIImage, exposureRatio: Double, ambientGain: Double = 0.25) -> CIImage {
        guard let kernel else { return photo }
        let extent = photo.extent
        let sigma = max(extent.width, extent.height) * 0.006
        let photoLow = photo.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        let ambientLow = ambient.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        guard let relit = kernel.apply(extent: extent, roiCallback: { _, rect in rect },
                                       arguments: [photo, photoLow, ambientLow, Float(exposureRatio),
                                                   Float(ambientGain)]) else { return photo }
        // フラッシュらしい周辺の落ち込みを少しだけ足す
        return relit.cropped(to: extent)
            .applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 0.35, kCIInputRadiusKey: 1.6])
            .cropped(to: extent)
    }
}
