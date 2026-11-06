import Combine
import CoreImage
import Foundation
import ImageIO
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
        PoseImageCache.warmUp(names: builtInPoses.compactMap(\.imageName))
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
            builtInPoses[index].lines = shape.lines
            builtInPoses[index].extraPeople = shape.extraPeople
        }
    }

    /// 同梱の形がない見本写真だけ、iPhone 上で骨格と輪郭を取り出す。
    /// 1 枚あたり 0.2 秒ほどかかるので、結果は保存して次回から使い回す。
    /// 写真が差し替わったときに古い結果を使わないよう、写真のファイルサイズをキーに含める。
    private func prepareBuiltInShapes() {
        let poses = builtInPoses
        // 型の作り方を変えたら名前を変えて、古い結果を使わないようにする
        let cacheURL = Self.documents.appendingPathComponent("builtin_pose_shapes_v8.json")

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
                    updated[index].lines = shape.lines
                    updated[index].extraPeople = shape.extraPeople
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
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        // 組み込みポーズ全部（約 200 枚）と見本写真を覚えておけるだけの数
        cache.countLimit = 600
        return cache
    }()

    /// 覚えているサムネイル（なければ nil。読み込みはしない）
    static func cachedThumbnail(named name: String) -> UIImage? {
        cache.object(forKey: name as NSString)
    }

    /// サムネイルを作る。元の JPEG を全部は展開せず、縮小した画像だけを作る（ImageIO）。
    /// 以前は画面の表示中（メインスレッド）に元の大きさで展開してから縮めていて、カテゴリの見出しをタップして
    /// 一覧を遠くへ動かすと、間のポーズのサムネイルをまとめて作るあいだ操作が止まっていた。
    /// いまはメインスレッド以外で作る（loadThumbnail・warmUp）
    static func thumbnail(named name: String) -> UIImage? {
        if let cached = cache.object(forKey: name as NSString) { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 240,
              ] as CFDictionary) else { return nil }
        let thumbnail = UIImage(cgImage: cgImage)
        cache.setObject(thumbnail, forKey: name as NSString)
        return thumbnail
    }

    /// メインスレッド以外でサムネイルを作る
    static func loadThumbnail(named name: String) async -> UIImage? {
        if let cached = cachedThumbnail(named: name) { return cached }
        return await Task.detached(priority: .userInitiated) { thumbnail(named: name) }.value
    }

    /// 起動後、組み込みポーズのサムネイルを先に作っておく（一覧を開いたときにすぐ出るように）
    static func warmUp(names: [String]) {
        DispatchQueue.global(qos: .utility).async {
            for name in names { _ = thumbnail(named: name) }
        }
    }

    /// 撮影画面の左下に出す見本写真（縦横比はそのまま、幅 360 ピクセル）
    static func sample(named name: String) -> UIImage? {
        let key = "sample|\(name)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg"),
              let image = UIImage(contentsOfFile: url.path), image.size.width > 0 else { return nil }
        let size = CGSize(width: 360, height: (360 * image.size.height / image.size.width).rounded())
        guard let sample = image.preparingThumbnail(of: size) else { return nil }
        cache.setObject(sample, forKey: key)
        return sample
    }
}
