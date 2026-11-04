import CoreGraphics
import CoreImage
import Foundation

// iPhone 専用の部品（UIKit）を使わないので、Mac の確認・事前計算ツール（tools/）からも使える。

/// 写真から取り出した型の形（等方座標）。
struct PoseShape: Codable {
    var points: [String: CGPoint]
    /// いちばん大きい人物の輪郭
    var outline: [CGPoint]?
    /// 2 人以上写っているときの、ほかの人の輪郭
    var extraOutlines: [[CGPoint]]?
}

/// 写真を解析した結果。座標は写真の画像座標（左上原点・0...1）。
struct PhotoAnalysis {
    /// 写真の大きさ（ピクセル）
    let size: CGSize
    let joints: [Joint: CGPoint]
    /// 人物の輪郭。大きい順
    let outlines: [[CGPoint]]

    /// 写っている人物全員の範囲（ピクセル）。輪郭があれば輪郭、なければ関節から求める
    var personBounds: CGRect {
        let source = outlines.isEmpty ? Array(joints.values) : outlines.flatMap { $0 }
        let points = source.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else {
            return CGRect(origin: .zero, size: size)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// 写真に写っている人の骨格と輪郭から型を作る。
///
/// 写真の中の「カメラの画面と同じ比率の枠」（crop、ピクセル）を決め、その枠の中の位置をそのまま型にする。
/// こうすると、枠の中で人が占める大きさ・位置が、撮影画面でもそのまま再現される。
enum PoseImporter {
    static func analyze(_ source: CIImage) -> PhotoAnalysis? {
        let image = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX,
                                                             y: -source.extent.minY))
        let joints = PoseDetector().detect(ciImage: image) ?? [:]
        let outlines = PoseDetector.personOutlines(ciImage: image)
        // 輪郭が取れれば、足などの関節が検出できなくても型にできる
        guard !outlines.isEmpty || joints.count >= 6 else { return nil }
        return PhotoAnalysis(size: image.extent.size, joints: joints, outlines: outlines)
    }

    /// 人物全体が枠に収まる、最初の枠。
    /// 写真の下端まで人が写っている（上半身の写真など）ときは、写真の下端を枠の下端にして元の構図を保つ。
    static func defaultCrop(for analysis: PhotoAnalysis, aspect: CGFloat) -> CGRect {
        let bounds = analysis.personBounds
        let touchesBottom = bounds.maxY > analysis.size.height * 0.985
        let top = bounds.minY - bounds.height * 0.08
        let bottom = touchesBottom ? analysis.size.height : bounds.maxY + bounds.height * 0.06
        var height = bottom - top
        var width = height * aspect
        if width < bounds.width * 1.12 {
            width = bounds.width * 1.12
            height = width / aspect
        }
        let originY = touchesBottom ? analysis.size.height - height : top - (height - (bottom - top)) / 2
        return CGRect(x: bounds.midX - width / 2, y: originY, width: width, height: height)
    }

    /// 枠の中の位置を等方座標にした型の形。
    static func shape(for analysis: PhotoAnalysis, crop: CGRect) -> PoseShape {
        let aspect = crop.width / crop.height
        func convert(_ point: CGPoint) -> CGPoint {
            let x = (point.x * analysis.size.width - crop.minX) / crop.width
            let y = (point.y * analysis.size.height - crop.minY) / crop.height
            return CGPoint(x: (x - 0.5) * aspect, y: y)
        }
        let outlines = analysis.outlines.map { $0.map(convert) }
        return PoseShape(
            points: Dictionary(uniqueKeysWithValues: analysis.joints.map { ($0.key.rawValue, convert($0.value)) }),
            outline: outlines.first,
            extraOutlines: outlines.count > 1 ? Array(outlines.dropFirst()) : nil)
    }

    static func makeTemplate(name: String, shape: PoseShape) -> PoseTemplate {
        var template = PoseTemplate(name: name, category: PoseTemplate.userCategory, joints: [:],
                                    isUserCreated: true, recommendedZoom: 1, outline: shape.outline)
        template.points = shape.points
        template.extraOutlines = shape.extraOutlines
        return template
    }
}
