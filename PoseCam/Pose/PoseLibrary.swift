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
        let cacheURL = Self.documents.appendingPathComponent("builtin_pose_shapes.json")

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
                   let shape = PoseImporter.extractShape(from: image) {
                    cache[key] = shape
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

/// 写真に写っている人の骨格と輪郭から型を作る。
enum PoseImporter {
    static func makeTemplate(from imageData: Data, name: String) -> PoseTemplate? {
        guard let source = CIImage(data: imageData, options: [.applyOrientationProperty: true]),
              let shape = extractShape(from: source) else { return nil }
        var template = PoseTemplate(name: name, category: PoseLibrary.userCategory, joints: [:],
                                    isUserCreated: true, recommendedZoom: 1, outline: shape.outline)
        template.points = shape.points
        return template
    }

    static func extractShape(from source: CIImage) -> PoseShape? {
        let image = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX,
                                                             y: -source.extent.minY))
        guard let pose = PoseDetector().detect(ciImage: image), pose.count >= 6 else { return nil }
        let aspect = image.extent.width / image.extent.height
        let isotropic = pose.mapValues { PoseSpace.toIsotropic($0, aspect: aspect) }
        let hasLegs = pose[.leftKnee] != nil || pose[.rightKnee] != nil
        // 骨格と輪郭に同じ変換をかけて、画面上で重なるようにする
        let transform = PoseSpace.fitTransform(isotropic, upperBody: !hasLegs)
        let outline = PoseDetector.personOutline(ciImage: image)?.map {
            transform(PoseSpace.toIsotropic($0, aspect: aspect))
        }
        let joints = isotropic.mapValues(transform)
        return PoseShape(points: Dictionary(uniqueKeysWithValues: joints.map { ($0.key.rawValue, $0.value) }),
                         outline: outline)
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
