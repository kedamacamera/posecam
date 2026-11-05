import Combine
import CoreImage
import Foundation
import UIKit

/// 組み込みポーズと、ユーザーが写真から登録したポーズを管理する。
final class PoseLibrary: ObservableObject {
    static let userCategory = PoseTemplate.userCategory
    static let favoriteCategory = "お気に入り"

    @Published private(set) var userPoses: [PoseTemplate] = []
    /// お気に入りにしたポーズの id（追加した順）
    @Published private(set) var favoriteIDs: [String] = UserDefaults.standard.stringArray(forKey: "favoritePoses") ?? []
    /// 起動直後は角度から作った形。見本写真の解析が終わると、写真の骨格と輪郭に置き換わる
    @Published private(set) var builtInPoses = BuiltInPoses.all

    init() {
        load()
        applyBundledShapes()
        prepareBuiltInShapes()
    }

    /// 形（骨格か輪郭）がまだないポーズは、選んでも何も表示されないので一覧に出さない
    private var readyBuiltInPoses: [PoseTemplate] {
        builtInPoses.filter { !$0.points.isEmpty || !$0.allOutlines.isEmpty }
    }

    var allPoses: [PoseTemplate] { userPoses + readyBuiltInPoses }

    /// お気に入り（あれば）→ マイポーズ（あれば）→ 組み込みのカテゴリ の順
    var categories: [String] {
        let used = Set(readyBuiltInPoses.map(\.category))
        return (favorites.isEmpty ? [] : [Self.favoriteCategory])
            + (userPoses.isEmpty ? [] : [Self.userCategory])
            + BuiltInPoses.categories.filter { used.contains($0) }
    }

    func poses(in category: String) -> [PoseTemplate] {
        switch category {
        case Self.favoriteCategory: return favorites
        case Self.userCategory: return userPoses
        default: return readyBuiltInPoses.filter { $0.category == category }
        }
    }

    var favorites: [PoseTemplate] {
        let all = Dictionary(allPoses.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return favoriteIDs.compactMap { all[$0] }
    }

    func isFavorite(_ pose: PoseTemplate) -> Bool { favoriteIDs.contains(pose.id) }

    func toggleFavorite(_ pose: PoseTemplate) {
        if let index = favoriteIDs.firstIndex(of: pose.id) {
            favoriteIDs.remove(at: index)
        } else {
            favoriteIDs.append(pose.id)
        }
        UserDefaults.standard.set(favoriteIDs, forKey: "favoritePoses")
    }

    func add(_ pose: PoseTemplate) {
        userPoses.insert(pose, at: 0)
        save()
    }

    func delete(_ pose: PoseTemplate) {
        userPoses.removeAll { $0.id == pose.id }
        if isFavorite(pose) { toggleFavorite(pose) }
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

    /// Mac で事前に計算してアプリに同梱した型の形（tools/shapes）を当てはめる。
    private func applyBundledShapes() {
        guard let url = Bundle.main.url(forResource: "builtin_shapes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let shapes = try? JSONDecoder().decode([String: PoseShape].self, from: data) else { return }
        for index in builtInPoses.indices {
            guard let name = builtInPoses[index].imageName, let shape = shapes[name] else { continue }
            builtInPoses[index].points = shape.points
            builtInPoses[index].outline = shape.outline
            builtInPoses[index].extraOutlines = shape.extraOutlines
            builtInPoses[index].face = shape.face
        }
    }

    /// 同梱の形がない見本写真だけ、iPhone 上で骨格と輪郭を取り出す。
    /// 1 枚あたり 0.2 秒ほどかかるので、結果は保存して次回から使い回す。
    /// 写真が差し替わったときに古い結果を使わないよう、写真のファイルサイズをキーに含める。
    private func prepareBuiltInShapes() {
        let poses = builtInPoses
        // 型の作り方を変えたら名前を変えて、古い結果を使わないようにする
        let cacheURL = Self.documents.appendingPathComponent("builtin_pose_shapes_v3.json")

        DispatchQueue.global(qos: .utility).async {
            var cache = (try? JSONDecoder().decode([String: PoseShape].self,
                                                   from: Data(contentsOf: cacheURL))) ?? [:]
            var updated = poses
            var changed = false

            for index in updated.indices {
                // 同梱の形がすでに当たっているものは飛ばす
                guard updated[index].allOutlines.isEmpty,
                      let name = updated[index].imageName,
                      let url = Bundle.main.url(forResource: name, withExtension: "jpg"),
                      let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
                else { continue }
                let key = "\(name)-\(size)"
                let isObject = updated[index].isObject
                if cache[key] == nil,
                   let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
                   let analysis = isObject ? PoseImporter.analyzeObject(image) : PoseImporter.analyze(image) {
                    // 組み込みポーズは、写真モードの標準の比率（3:4）で枠を決める
                    let crop = isObject
                        ? PoseImporter.fullFrameCrop(size: analysis.size, aspect: 3.0 / 4.0)
                        : PoseImporter.defaultCrop(for: analysis, aspect: 3.0 / 4.0)
                    cache[key] = PoseImporter.shape(for: analysis, crop: crop)
                    changed = true
                }
                if let shape = cache[key] {
                    updated[index].points = shape.points
                    updated[index].outline = shape.outline
                    updated[index].extraOutlines = shape.extraOutlines
                    updated[index].face = shape.face
                }
            }

            if changed, let data = try? JSONEncoder().encode(cache) {
                try? data.write(to: cacheURL, options: .atomic)
            }
            DispatchQueue.main.async { self.builtInPoses = updated }
        }
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
