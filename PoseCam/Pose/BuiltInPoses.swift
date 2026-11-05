import CoreGraphics
import Foundation

/// 組み込みのポーズ。
/// 見本写真（Resources/Poses/pose_NN.jpg、specs と同じ順番）があれば、起動後にその写真から
/// 骨格と輪郭を取り出して置き換える（PoseLibrary）。ここでの角度は写真が使えないときの代わり。
enum BuiltInPoses {
    static let categories = ["立ち", "寄りかかり", "歩き", "座り", "後ろ姿", "上半身", "自撮り", "タバコ", "2人", "食事",
                             "フード", "ドリンク", "アクション"]

    /// 組み込みポーズすべて。サンプル写真から作ったポーズ（sample_poses.json）を先に並べる
    static let all: [PoseTemplate] = samplePoses + specs.enumerated().map { index, spec in
        var template = spec.makeTemplate(id: "builtin_\(index)")
        template.imageName = String(format: "pose_%02d", index)
        return template
    }

    private struct SampleEntry: Decodable {
        let image: String
        let category: String
    }

    /// サンプル写真をもとに AI で作った見本写真のポーズ。骨格と輪郭は builtin_shapes.json から読み込む
    private static let samplePoses: [PoseTemplate] = {
        guard let url = Bundle.main.url(forResource: "sample_poses", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([SampleEntry].self, from: data) else { return [] }
        var counts: [String: Int] = [:]
        return entries.map { entry in
            counts[entry.category, default: 0] += 1
            return PoseTemplate(id: "sample_\(entry.image)", name: "\(entry.category) \(counts[entry.category]!)",
                                category: entry.category, joints: [:], isUserCreated: false, imageName: entry.image)
        }
    }()

    // 男性向けのスナップでよく使うポーズ。角度は見本写真が使えないときの大まかな代わり
    private static let specs: [PoseSpec] = [
        // 立ち
        PoseSpec(name: "ナチュラル", category: "立ち"),
        PoseSpec(name: "両手ポケット", category: "立ち", lUpper: 22, lLower: -35, rUpper: -22, rLower: 35, lThigh: 8, rThigh: -2),
        PoseSpec(name: "片手ポケット", category: "立ち", lUpper: 22, lLower: -35, lThigh: 6),
        PoseSpec(name: "腕組み", category: "立ち", lUpper: 20, lLower: -100, rUpper: -20, rLower: 100),
        PoseSpec(name: "目線外し", category: "立ち", head: 20, lUpper: 22, lLower: -35),
        PoseSpec(name: "足クロス", category: "立ち", lUpper: 22, lLower: -35, lThigh: -10, lShin: -8, rThigh: 4, rShin: 6),
        PoseSpec(name: "襟を直す", category: "立ち", lUpper: 25, lLower: -160, rUpper: -25, rLower: 160),
        PoseSpec(name: "時計を見る", category: "立ち", head: 10, lUpper: 30, lLower: -110),
        PoseSpec(name: "ジャケットを肩に", category: "立ち", lUpper: 160, lLower: -170, rUpper: -22, rLower: 35),
        PoseSpec(name: "髪をかき上げる", category: "立ち", lUpper: 150, lLower: -150, rUpper: -22, rLower: 35),

        // 寄りかかり
        PoseSpec(name: "壁に肩で寄りかかる", category: "寄りかかり", torso: -8, lUpper: 22, lLower: -35, rUpper: -22, rLower: 35,
                 lThigh: -10, lShin: -8, rThigh: 4, rShin: 6),
        PoseSpec(name: "壁に背中・片足上げ", category: "寄りかかり", lUpper: 22, lLower: -35, rUpper: -22, rLower: 35,
                 lThigh: 30, lShin: -20),
        PoseSpec(name: "カウンターに片手", category: "寄りかかり", torso: -6, head: 20, lUpper: 22, lLower: -35, rUpper: -40, rLower: -10,
                 lThigh: -10, lShin: -8, rThigh: 4, rShin: 6),
        PoseSpec(name: "腰掛けて寄りかかる", category: "寄りかかり", lUpper: 15, lLower: 5, rUpper: -15, rLower: -5,
                 lThigh: -15, lShin: -10, rThigh: 15, rShin: 10),

        // 歩き
        PoseSpec(name: "正面に歩く", category: "歩き", lUpper: 5, lLower: -10, rUpper: -15, rLower: 10, lThigh: 10, lShin: -5, rThigh: -6),
        PoseSpec(name: "横向きに歩く", category: "歩き", lUpper: 20, lLower: 30, rUpper: -20, rLower: -10, lThigh: 20, rThigh: -20),
        PoseSpec(name: "振り返る", category: "歩き", head: -20, lUpper: 22, lLower: -35),
        PoseSpec(name: "横向きで振り向く", category: "歩き", head: 15),

        // 座り
        PoseSpec(name: "前かがみに座る", category: "座り", torso: 10, lUpper: 25, lLower: -50, rUpper: -25, rLower: 50,
                 lThigh: 30, lShin: 0, rThigh: -30, rShin: 0, thighScale: 0.45),
        PoseSpec(name: "足を組んで座る", category: "座り", lUpper: 10, lLower: -30, rUpper: -10, rLower: 30,
                 lThigh: -30, lShin: 5, rThigh: -8, rShin: -2, thighScale: 0.45),
        PoseSpec(name: "しゃがむ", category: "座り", lUpper: 20, lLower: -40, rUpper: -20, rLower: 40,
                 lThigh: 60, lShin: -10, rThigh: -60, rShin: 10, thighScale: 0.6),
        PoseSpec(name: "片膝を立てて座る", category: "座り", lUpper: 40, lLower: -60, lThigh: 150, lShin: 10,
                 rThigh: -80, rShin: -10, thighScale: 0.5),
        PoseSpec(name: "高いスツール", category: "座り", lUpper: 15, lLower: -30, rUpper: -15, rLower: 30,
                 lThigh: 30, lShin: 0, rThigh: -10, rShin: -5, thighScale: 0.7),

        // 上半身
        PoseSpec(name: "襟を持つ", category: "上半身", lUpper: 25, lLower: -160, upperBody: true),
        PoseSpec(name: "あご手", category: "上半身", lUpper: 20, lLower: -95, rUpper: -10, rLower: 175, upperBody: true),
        PoseSpec(name: "メガネに手", category: "上半身", rUpper: -15, rLower: 172, upperBody: true),
        PoseSpec(name: "横顔", category: "上半身", head: 25, upperBody: true),
        PoseSpec(name: "髪をかき上げる（上半身）", category: "上半身", lUpper: 150, lLower: -150, upperBody: true),
        PoseSpec(name: "腕組み（上半身）", category: "上半身", lUpper: 20, lLower: -100, rUpper: -20, rLower: 100, upperBody: true),

        // アクション
        PoseSpec(name: "ジャンプ", category: "アクション", lUpper: 40, lLower: 20, rUpper: -40, rLower: -20,
                 lThigh: 35, lShin: -40, rThigh: -35, rShin: 40),
        PoseSpec(name: "手を挙げる", category: "アクション", lUpper: 150, lLower: 170),
        PoseSpec(name: "指さし", category: "アクション", lUpper: 60, lLower: 80),
        PoseSpec(name: "伸びをする", category: "アクション", lUpper: 165, lLower: 170, rUpper: -165, rLower: -170),
        PoseSpec(name: "ジャケットを羽織る", category: "アクション", lUpper: 60, lLower: 120, rUpper: -30, rLower: -60),
        PoseSpec(name: "後ろ姿", category: "アクション", lUpper: 22, lLower: -35, rUpper: -22, rLower: 35),
    ]
}
/// 角度（度）で表したポーズ。0° が真下、正の値が画面右、180° が真上。
/// left は写っている人の左（＝正面を向いたとき画面の右側）。
struct PoseSpec {
    var name: String
    var category: String
    var torso: Double = 0
    var head: Double = 0
    var lUpper: Double = 12
    var lLower: Double = 5
    var rUpper: Double = -12
    var rLower: Double = -5
    var lThigh: Double = 4
    var lShin: Double = 0
    var rThigh: Double = -4
    var rShin: Double = 0
    /// 座りポーズで太ももが手前に向いて短く見えるぶんの縮み
    var thighScale: Double = 1
    var upperBody = false

    func makeTemplate(id: String) -> PoseTemplate {
        PoseTemplate(id: id, name: name, category: category,
                     joints: PoseSpace.fit(joints(), upperBody: upperBody), isUserCreated: false,
                     recommendedZoom: recommendedZoom)
    }

    /// 立ちポーズ・上半身は少し離れて 2 倍で撮ると、歪みが少なく脚も長く見える。
    /// 動きの大きいポーズや座りは、収まりやすい 1 倍。
    private var recommendedZoom: Double {
        switch category {
        case "アクション", "座り": return 1
        default: return 2
        }
    }

    private func joints() -> [Joint: CGPoint] {
        func direction(_ degrees: Double) -> CGPoint {
            let radians = CGFloat(degrees) * .pi / 180
            return CGPoint(x: sin(radians), y: cos(radians))
        }
        func move(_ p: CGPoint, _ d: CGPoint, _ length: CGFloat) -> CGPoint {
            CGPoint(x: p.x + d.x * length, y: p.y + d.y * length)
        }

        let torsoRadians = CGFloat(torso) * .pi / 180
        let side = CGPoint(x: cos(torsoRadians), y: -sin(torsoRadians))
        let thigh = 0.23 * CGFloat(thighScale)

        let neck = CGPoint.zero
        let hipCenter = move(neck, direction(torso), 0.30)
        let leftShoulder = move(neck, side, 0.10)
        let rightShoulder = move(neck, side, -0.10)
        let leftHip = move(hipCenter, side, 0.065)
        let rightHip = move(hipCenter, side, -0.065)
        let leftElbow = move(leftShoulder, direction(lUpper), 0.15)
        let rightElbow = move(rightShoulder, direction(rUpper), 0.15)
        let leftKnee = move(leftHip, direction(lThigh), thigh)
        let rightKnee = move(rightHip, direction(rThigh), thigh)

        return [
            .neck: neck,
            .nose: move(neck, direction(torso + 180 + head), 0.11),
            .leftShoulder: leftShoulder,
            .rightShoulder: rightShoulder,
            .leftElbow: leftElbow,
            .rightElbow: rightElbow,
            .leftWrist: move(leftElbow, direction(lLower), 0.14),
            .rightWrist: move(rightElbow, direction(rLower), 0.14),
            .leftHip: leftHip,
            .rightHip: rightHip,
            .leftKnee: leftKnee,
            .rightKnee: rightKnee,
            .leftAnkle: move(leftKnee, direction(lShin), 0.23),
            .rightAnkle: move(rightKnee, direction(rShin), 0.23),
        ]
    }
}
