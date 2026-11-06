import CoreGraphics
import Vision

/// 骨格の関節。left / right は「写っている人から見た」左右（Vision と同じ定義）。
enum Joint: String, CaseIterable, Codable {
    case nose, neck
    case leftShoulder, rightShoulder
    case leftElbow, rightElbow
    case leftWrist, rightWrist
    case leftHip, rightHip
    case leftKnee, rightKnee
    case leftAnkle, rightAnkle

    var mirrored: Joint {
        switch self {
        case .nose, .neck: return self
        case .leftShoulder: return .rightShoulder
        case .rightShoulder: return .leftShoulder
        case .leftElbow: return .rightElbow
        case .rightElbow: return .leftElbow
        case .leftWrist: return .rightWrist
        case .rightWrist: return .leftWrist
        case .leftHip: return .rightHip
        case .rightHip: return .leftHip
        case .leftKnee: return .rightKnee
        case .rightKnee: return .leftKnee
        case .leftAnkle: return .rightAnkle
        case .rightAnkle: return .leftAnkle
        }
    }

    /// 画面に出す名前（写っている人から見た左右）
    var label: String {
        switch self {
        case .nose: return "鼻"
        case .neck: return "首"
        case .leftShoulder: return "左肩"
        case .rightShoulder: return "右肩"
        case .leftElbow: return "左ひじ"
        case .rightElbow: return "右ひじ"
        case .leftWrist: return "左手首"
        case .rightWrist: return "右手首"
        case .leftHip: return "左腰"
        case .rightHip: return "右腰"
        case .leftKnee: return "左ひざ"
        case .rightKnee: return "右ひざ"
        case .leftAnkle: return "左足首"
        case .rightAnkle: return "右足首"
        }
    }

    /// 写っている人から見た左側の関節か（鼻・首は nil）
    var isLeft: Bool? {
        switch self {
        case .nose, .neck: return nil
        case .leftShoulder, .leftElbow, .leftWrist, .leftHip, .leftKnee, .leftAnkle: return true
        default: return false
        }
    }

    var visionName: VNHumanBodyPoseObservation.JointName {
        switch self {
        case .nose: return .nose
        case .neck: return .neck
        case .leftShoulder: return .leftShoulder
        case .rightShoulder: return .rightShoulder
        case .leftElbow: return .leftElbow
        case .rightElbow: return .rightElbow
        case .leftWrist: return .leftWrist
        case .rightWrist: return .rightWrist
        case .leftHip: return .leftHip
        case .rightHip: return .rightHip
        case .leftKnee: return .leftKnee
        case .rightKnee: return .rightKnee
        case .leftAnkle: return .leftAnkle
        case .rightAnkle: return .rightAnkle
        }
    }

    /// 描画に使う骨（関節の組）。
    /// 首と鼻はつながない。鼻は顔を横に向けるだけで首の真上から大きく外れ、首から鼻への線が
    /// 実際の頭の傾きと関係なく傾いて見えていた。頭の向き・傾きは顔（FaceShape の yaw・roll）で表す
    static let bones: [(Joint, Joint)] = [
        (.leftShoulder, .rightShoulder),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.leftShoulder, .leftHip), (.rightShoulder, .rightHip),
        (.leftHip, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
    ]
}

/// 座標系の変換。
///
/// - 画像座標: 左上原点、x・y とも 0...1 に正規化（縦横で単位が違う）
/// - 等方座標: y は 0...1（画面の上→下）、x は画面中央からのずれを「画面の高さ」単位で表す。
///   縦横比の違う画面（写真 3:4 / 動画 9:16）でも型の形が崩れないよう、型はこの座標で持つ。
enum PoseSpace {
    static func toIsotropic(_ p: CGPoint, aspect: CGFloat) -> CGPoint {
        CGPoint(x: (p.x - 0.5) * aspect, y: p.y)
    }

    static func toView(_ p: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + p.x * size.height, y: p.y * size.height)
    }

    private static let upperJoints: Set<Joint> = [
        .nose, .neck, .leftShoulder, .rightShoulder, .leftElbow, .rightElbow,
        .leftWrist, .rightWrist, .leftHip, .rightHip,
    ]

    /// 等方座標の骨格を、画面内に収まる大きさ・位置に整える。
    /// upperBody のときは上半身だけを基準に大きく配置する（脚は画面外にはみ出してよい）。
    static func fit(_ points: [Joint: CGPoint], upperBody: Bool) -> [Joint: CGPoint] {
        let transform = fitTransform(points, upperBody: upperBody)
        return points.mapValues(transform)
    }

    /// fit と同じ変換を返す。骨格と輪郭に同じ変換をかけるときに使う。
    static func fitTransform(_ points: [Joint: CGPoint], upperBody: Bool) -> (CGPoint) -> CGPoint {
        let considered = points.filter { !upperBody || upperJoints.contains($0.key) }.map(\.value)
        guard let minX = considered.map(\.x).min(), let maxX = considered.map(\.x).max(),
              let minY = considered.map(\.y).min(), let maxY = considered.map(\.y).max() else {
            return { $0 }
        }
        // 鼻より上にある頭頂部のぶん余白を足す
        let top = minY - (maxY - minY) * (upperBody ? 0.2 : 0.1)
        let height = max(maxY - top, 0.01)
        let width = max(maxX - minX, 0.01)
        let targetHeight: CGFloat = upperBody ? 0.62 : 0.80
        let scale = min(targetHeight / height, 0.5 / width)
        let centerX = (minX + maxX) / 2
        let centerY = (top + maxY) / 2
        let targetCenterY: CGFloat = upperBody ? 0.58 : 0.52
        return { CGPoint(x: ($0.x - centerX) * scale, y: ($0.y - centerY) * scale + targetCenterY) }
    }
}
