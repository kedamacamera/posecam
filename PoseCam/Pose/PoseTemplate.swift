import CoreGraphics
import Foundation

/// 画面に重ねる「ポーズの型」。座標は PoseSpace の等方座標。
struct PoseTemplate: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var category: String
    var points: [String: CGPoint]
    var isUserCreated: Bool

    init(id: String = UUID().uuidString, name: String, category: String,
         joints: [Joint: CGPoint], isUserCreated: Bool) {
        self.id = id
        self.name = name
        self.category = category
        self.points = Dictionary(uniqueKeysWithValues: joints.map { ($0.key.rawValue, $0.value) })
        self.isUserCreated = isUserCreated
    }

    var joints: [Joint: CGPoint] {
        Dictionary(uniqueKeysWithValues: points.compactMap { key, value in
            Joint(rawValue: key).map { ($0, value) }
        })
    }

    /// 左右反転した型。
    func mirrored() -> PoseTemplate {
        let flipped = Dictionary(uniqueKeysWithValues: joints.map {
            ($0.key.mirrored, CGPoint(x: -$0.value.x, y: $0.value.y))
        })
        return PoseTemplate(id: id + "#mirror", name: name, category: category,
                            joints: flipped, isUserCreated: isUserCreated)
    }

    static func == (lhs: PoseTemplate, rhs: PoseTemplate) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
