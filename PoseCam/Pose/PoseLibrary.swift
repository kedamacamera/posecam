import Combine
import CoreImage
import Foundation
import UIKit

/// 組み込みポーズと、ユーザーが写真から登録したポーズを管理する。
final class PoseLibrary: ObservableObject {
    static let userCategory = "マイポーズ"

    @Published private(set) var userPoses: [PoseTemplate] = []
    /// 起動直後は角度から作った形。見本写真の解析が終わると、写真の骨格と輪郭に置き換わる
    @Published private(set) var builtInPoses = BuiltInPoses.all

    init() {
        load()
        prepareBuiltInShapes()
    }

    var allPoses: [PoseTemplate] { userPoses + builtInPoses }

    var categories: [String] {
        (userPoses.isEmpty ? [] : [Self.userCategory]) + BuiltInPoses.categories
    }

    func poses(in category: String) -> [PoseTemplate] {
        category == Self.userCategory ? userPoses : builtInPoses.filter { $0.category == category }
    }

    func add(_ pose: PoseTemplate) {
        userPoses.insert(pose, at: 0)
        save()
    }

    func delete(_ pose: PoseTemplate) {
        userPoses.removeAll { $0.id == pose.id }
        save()
    }

    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var fileURL: URL { Self.documents.appendingPathComponent("user_poses.json") }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let poses = try? JSONDecoder().decode([PoseTemplate].self, from: data) else { return }
        userPoses = poses
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(userPoses) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - 組み込みポーズの見本写真

    /// 見本写真から骨格と輪郭を取り出す。1 枚あたり 0.2 秒ほどかかるので、結果は保存して次回から使い回す。
    /// 写真が差し替わったときに古い結果を使わないよう、写真のファイルサイズをキーに含める。
    private func prepareBuiltInShapes() {
        let poses = builtInPoses
        // 型の作り方を変えたら名前を変えて、古い結果を使わないようにする
        let cacheURL = Self.documents.appendingPathComponent("builtin_pose_shapes_v2.json")

        DispatchQueue.global(qos: .utility).async {
            var cache = (try? JSONDecoder().decode([String: PoseShape].self,
                                                   from: Data(contentsOf: cacheURL))) ?? [:]
            var updated = poses
            var changed = false

            for index in updated.indices {
                guard let name = updated[index].imageName,
                      let url = Bundle.main.url(forResource: name, withExtension: "jpg"),
                      let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
                else { continue }
                let key = "\(name)-\(size)"
                if cache[key] == nil,
                   let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
                   let analysis = PoseImporter.analyze(image) {
                    // 組み込みポーズは、写真モードの標準の比率（3:4）で枠を決める
                    let crop = PoseImporter.defaultCrop(for: analysis, aspect: 3.0 / 4.0)
                    cache[key] = PoseImporter.shape(for: analysis, crop: crop)
                    changed = true
                }
                if let shape = cache[key] {
                    updated[index].points = shape.points
                    updated[index].outline = shape.outline
                }
            }

            if changed, let data = try? JSONEncoder().encode(cache) {
                try? data.write(to: cacheURL, options: .atomic)
            }
            DispatchQueue.main.async { self.builtInPoses = updated }
        }
    }
}

/// 写真から取り出した型の形（等方座標）。
struct PoseShape: Codable {
    var points: [String: CGPoint]
    var outline: [CGPoint]?
}

/// 写真を解析した結果。座標は写真の画像座標（左上原点・0...1）。
struct PhotoAnalysis {
    /// 写真の大きさ（ピクセル）
    let size: CGSize
    let joints: [Joint: CGPoint]
    let outline: [CGPoint]?

    /// 人物全体の範囲（ピクセル）。輪郭があれば輪郭、なければ関節から求める
    var personBounds: CGRect {
        let points = (outline ?? Array(joints.values)).map {
            CGPoint(x: $0.x * size.width, y: $0.y * size.height)
        }
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
        let outline = PoseDetector.personOutline(ciImage: image)
        // 輪郭が取れれば、足などの関節が検出できなくても型にできる
        guard outline != nil || joints.count >= 6 else { return nil }
        return PhotoAnalysis(size: image.extent.size, joints: joints, outline: outline)
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
        return PoseShape(
            points: Dictionary(uniqueKeysWithValues: analysis.joints.map { ($0.key.rawValue, convert($0.value)) }),
            outline: analysis.outline?.map(convert))
    }

    static func makeTemplate(name: String, shape: PoseShape) -> PoseTemplate {
        var template = PoseTemplate(name: name, category: PoseLibrary.userCategory, joints: [:],
                                    isUserCreated: true, recommendedZoom: 1, outline: shape.outline)
        template.points = shape.points
        return template
    }
}
/// 見本写真のサムネイル。毎回 JPEG を読み直さないよう、縮小したものを覚えておく。
enum PoseImageCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func thumbnail(named name: String) -> UIImage? {
        if let cached = cache.object(forKey: name as NSString) { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg"),
              let image = UIImage(contentsOfFile: url.path),
              let thumbnail = image.preparingThumbnail(of: CGSize(width: 160, height: 240)) else { return nil }
        cache.setObject(thumbnail, forKey: name as NSString)
        return thumbnail
    }
}
