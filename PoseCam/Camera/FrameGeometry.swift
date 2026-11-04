import CoreImage

/// カメラのフレームを、選んだ縦横比に中央で切り抜き、必要なら縮小する。
/// 映像・人物マスク・検出した関節の座標に同じ変換をかけるために使う。
struct FrameGeometry {
    let sourceSize: CGSize
    /// 切り抜く範囲（Core Image 座標・左下原点）
    let cropRect: CGRect
    /// 出力サイズ（書き出しに使うので偶数）
    let outputSize: CGSize

    init(sourceSize: CGSize, aspect: CGFloat, maxLongSide: CGFloat?) {
        self.sourceSize = sourceSize
        var width = sourceSize.width
        var height = sourceSize.height
        if width / height > aspect {
            width = height * aspect
        } else {
            height = width / aspect
        }
        width = CGFloat(Int(width) / 2 * 2)
        height = CGFloat(Int(height) / 2 * 2)
        cropRect = CGRect(x: ((sourceSize.width - width) / 2).rounded(.down),
                          y: ((sourceSize.height - height) / 2).rounded(.down),
                          width: width, height: height)

        var scale: CGFloat = 1
        if let maxLongSide, max(width, height) > maxLongSide {
            scale = maxLongSide / max(width, height)
        }
        outputSize = CGSize(width: CGFloat(Int(width * scale) / 2 * 2),
                            height: CGFloat(Int(height * scale) / 2 * 2))
    }

    var aspect: CGFloat { outputSize.width / outputSize.height }

    func apply(_ image: CIImage) -> CIImage {
        let toOrigin = CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY)
        let scale = CGAffineTransform(scaleX: outputSize.width / cropRect.width,
                                      y: outputSize.height / cropRect.height)
        return image.cropped(to: cropRect)
            .transformed(by: toOrigin.concatenating(scale))
            .cropped(to: CGRect(origin: .zero, size: outputSize))
    }

    /// 元フレームの画像座標（左上原点・0...1）を、切り抜き後の画像座標に直す。
    func convert(_ point: CGPoint) -> CGPoint {
        let top = sourceSize.height - cropRect.maxY
        return CGPoint(x: (point.x * sourceSize.width - cropRect.minX) / cropRect.width,
                       y: (point.y * sourceSize.height - top) / cropRect.height)
    }
}
