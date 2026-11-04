import CoreGraphics

/// 組み込みのポーズ。座標を直接書く代わりに、手足の角度から骨格を組み立てる。
/// 新しいポーズは specs に 1 行足すだけで増やせる。
enum BuiltInPoses {
    static let categories = ["立ち", "かわいい", "かっこいい", "アクション", "座り", "上半身"]

    static let all: [PoseTemplate] = specs.enumerated().map { index, spec in
        spec.makeTemplate(id: "builtin_\(index)")
    }

    private static let specs: [PoseSpec] = [
        // 立ち
        PoseSpec(name: "ナチュラル", category: "立ち"),
        PoseSpec(name: "腰に手", category: "立ち", lUpper: 45, lLower: -50, rUpper: -45, rLower: 50, lThigh: 8, rThigh: -8),
        PoseSpec(name: "片手を腰に", category: "立ち", lUpper: 45, lLower: -50, lThigh: 10, lShin: 4, rThigh: -2),
        PoseSpec(name: "腕組み", category: "立ち", lUpper: 20, lLower: -100, rUpper: -20, rLower: 100),
        PoseSpec(name: "足をクロス", category: "立ち", lThigh: -10, lShin: -8, rThigh: 4, rShin: 6),
        PoseSpec(name: "S字ライン", category: "立ち", torso: 6, head: -8, lUpper: 30, lLower: -40, rUpper: -8, rLower: -4,
                 lThigh: -3, lShin: 2, rThigh: -14, rShin: -3),
        PoseSpec(name: "後ろで手を組む", category: "立ち", lUpper: 8, lLower: -25, rUpper: -8, rLower: 25),

        // かわいい
        PoseSpec(name: "ピース", category: "かわいい", rUpper: -25, rLower: 160),
        PoseSpec(name: "両手ピース", category: "かわいい", lUpper: 25, lLower: -160, rUpper: -25, rLower: 160),
        PoseSpec(name: "ほっぺに手", category: "かわいい", lUpper: 15, lLower: -170, rUpper: -15, rLower: 170),
        PoseSpec(name: "頭上でハート", category: "かわいい", lUpper: 160, lLower: -130, rUpper: -160, rLower: 130),
        PoseSpec(name: "うちまた", category: "かわいい", lUpper: 5, lLower: -15, rUpper: -5, rLower: 15,
                 lThigh: -6, lShin: 10, rThigh: 6, rShin: -10),
        PoseSpec(name: "首かしげ", category: "かわいい", head: 15, lUpper: 10, lLower: 5, rUpper: -20, rLower: 165),
        PoseSpec(name: "猫の手", category: "かわいい", lUpper: 20, lLower: -150, rUpper: -20, rLower: 150),

        // かっこいい
        PoseSpec(name: "ガッツポーズ", category: "かっこいい", lUpper: 12, lLower: 5, rUpper: -95, rLower: 180),
        PoseSpec(name: "両手を広げる", category: "かっこいい", lUpper: 100, lLower: 95, rUpper: -100, rLower: -95),
        PoseSpec(name: "考えるポーズ", category: "かっこいい", lUpper: 20, lLower: -95, rUpper: -10, rLower: 175),
        PoseSpec(name: "指さし", category: "かっこいい", lUpper: 95, lLower: 95),
        PoseSpec(name: "仁王立ち", category: "かっこいい", lUpper: 20, lLower: 0, rUpper: -20, rLower: 0,
                 lThigh: 15, lShin: 5, rThigh: -15, rShin: -5),
        PoseSpec(name: "敬礼", category: "かっこいい", rUpper: -80, rLower: 140),

        // アクション
        PoseSpec(name: "バンザイ", category: "アクション", lUpper: 165, lLower: 170, rUpper: -165, rLower: -170),
        PoseSpec(name: "ジャンプ", category: "アクション", lUpper: 150, lLower: 160, rUpper: -150, rLower: -160,
                 lThigh: 35, lShin: -40, rThigh: -35, rShin: 40),
        PoseSpec(name: "フラミンゴ", category: "アクション", lUpper: 95, lLower: 95, rUpper: -95, rLower: -95,
                 lThigh: 50, lShin: -30),
        PoseSpec(name: "ランジ", category: "アクション", lUpper: 150, lLower: 160, lThigh: 40, lShin: 0, rThigh: -30, rShin: -10),
        PoseSpec(name: "ダンス", category: "アクション", lUpper: 130, lLower: 170, rUpper: -45, rLower: 30,
                 lThigh: 20, lShin: -10, rThigh: -5),
        PoseSpec(name: "手を振る", category: "アクション", lUpper: 60, lLower: 170),

        // 座り
        PoseSpec(name: "しゃがむ", category: "座り", lUpper: 20, lLower: -40, rUpper: -20, rLower: 40,
                 lThigh: 60, lShin: -10, rThigh: -60, rShin: 10, thighScale: 0.6),
        PoseSpec(name: "体育座り", category: "座り", lUpper: 15, lLower: -20, rUpper: -15, rLower: 20,
                 lThigh: 160, lShin: 5, rThigh: -160, rShin: -5, thighScale: 0.5),
        PoseSpec(name: "椅子に座る", category: "座り", lUpper: 10, lLower: -30, rUpper: -10, rLower: 30,
                 lThigh: 8, lShin: 2, rThigh: -8, rShin: -2, thighScale: 0.45),
        PoseSpec(name: "あぐら", category: "座り", lUpper: 25, lLower: -10, rUpper: -25, rLower: 10,
                 lThigh: 75, lShin: -100, rThigh: -75, rShin: 100, thighScale: 0.8),

        // 上半身
        PoseSpec(name: "あご手", category: "上半身", lUpper: 20, lLower: -95, rUpper: -10, rLower: 175, upperBody: true),
        PoseSpec(name: "両手ほおづえ", category: "上半身", lUpper: 10, lLower: -170, rUpper: -10, rLower: 170, upperBody: true),
        PoseSpec(name: "髪をかき上げる", category: "上半身", lUpper: 150, lLower: -150, upperBody: true),
        PoseSpec(name: "口元に手", category: "上半身", rUpper: -5, rLower: 170, upperBody: true),
        PoseSpec(name: "小顔ピース", category: "上半身", head: -10, rUpper: -15, rLower: 172, upperBody: true),
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
