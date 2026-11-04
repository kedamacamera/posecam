import Combine
import CoreImage
import Foundation

/// 組み込みポーズと、ユーザーが写真から登録したポーズを管理する。
final class PoseLibrary: ObservableObject {
    static let userCategory = "マイポーズ"

    @Published private(set) var userPoses: [PoseTemplate] = []
    let builtInPoses = BuiltInPoses.all

    init() {
        load()
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

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("user_poses.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let poses = try? JSONDecoder().decode([PoseTemplate].self, from: data) else { return }
        userPoses = poses
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(userPoses) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// 写真に写っている人の骨格から型を作る。
enum PoseImporter {
    static func makeTemplate(from imageData: Data, name: String) -> PoseTemplate? {
        guard let source = CIImage(data: imageData, options: [.applyOrientationProperty: true]) else { return nil }
        let image = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX,
                                                             y: -source.extent.minY))
        guard let pose = PoseDetector().detect(ciImage: image), pose.count >= 6 else { return nil }
        let aspect = image.extent.width / image.extent.height
        let isotropic = pose.mapValues { PoseSpace.toIsotropic($0, aspect: aspect) }
        let hasLegs = pose[.leftKnee] != nil || pose[.rightKnee] != nil
        return PoseTemplate(name: name, category: PoseLibrary.userCategory,
                            joints: PoseSpace.fit(isotropic, upperBody: !hasLegs), isUserCreated: true)
    }
}
