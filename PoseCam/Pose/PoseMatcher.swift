import CoreGraphics
import Foundation

/// 型と検出した骨格の一致度（0〜100）。
/// 「手足の向き」と「関節の位置（画面のどこに、どの大きさで立っているか）」の両方がそろって初めて高くなる。
/// 多少のずれ（人の体型の違い・関節の検出のぶれ）は満点のまま扱い、大きくずれると 0 点になる。
enum PoseMatcher {
    private static let bones: [(Joint, Joint)] = [
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
        (.leftShoulder, .leftHip), (.rightShoulder, .rightHip),
        (.neck, .nose),
        (.leftShoulder, .rightShoulder),
    ]

    /// 向きのずれがこの角度までは満点
    private static let angleSlack = 12.0 * Double.pi / 180
    /// 向きのずれがこの角度で 0 点
    private static let angleTolerance = 75.0 * Double.pi / 180
    /// 関節の位置のずれ（型の体の高さに対する割合）がこの値までは満点
    private static let positionSlack = 0.05
    /// 関節の位置のずれがこの値で 0 点
    private static let positionTolerance = 0.38

    /// 関節の位置と向きでの一致度。どちらも等方座標で渡す。
    /// aspect は画面の縦横比（横 / 縦）で、画面内に見えているはずの関節を決めるのに使う。
    /// 比べられる関節が 3 つ未満のとき（顔のアップなどで体の関節が取れないとき）は nil。
    static func score(template: [Joint: CGPoint], detected: [Joint: CGPoint], aspect: CGFloat? = nil) -> Double? {
        guard !template.isEmpty else { return nil }
        // インカメラ（鏡像）や後ろ向きでは左右のラベルが入れ替わるので、両方試して良い方を採る
        let swapped = Dictionary(uniqueKeysWithValues: detected.map { ($0.key.mirrored, $0.value) })
        let scores = [evaluate(template, detected, aspect: aspect), evaluate(template, swapped, aspect: aspect)]
        return scores.compactMap { $0 }.max()
    }

    private static func evaluate(_ template: [Joint: CGPoint], _ detected: [Joint: CGPoint], aspect: CGFloat?) -> Double? {
        // 画面内に見えているはずの型の関節（上半身だけの型なら、画面外の脚は数えない）
        let expected = template.filter { _, p in
            guard let aspect else { return true }
            return abs(p.x) <= aspect / 2 + 0.02 && p.y >= -0.02 && p.y <= 1.02
        }
        let found = expected.keys.filter { detected[$0] != nil }
        guard found.count >= 3, !expected.isEmpty else { return nil }
        // 見えているはずの関節が映っていなければ、そのぶん下げる（顔だけ・上半身だけで満点にならないように）
        let coverage = Double(found.count) / Double(expected.count)
        let coverageFactor = 0.4 + 0.6 * coverage

        let angle = angleScore(template, detected) ?? 0.6
        let position = positionScore(template, detected, joints: found)
        // 掛け算にして、位置か向きのどちらかが大きくずれていれば 0 点になるようにする
        return angle * position * coverageFactor * 100
    }

    /// 骨ごとの向きの差。12 度までは満点、75 度ずれた骨は 0 点。
    private static func angleScore(_ template: [Joint: CGPoint], _ detected: [Joint: CGPoint]) -> Double? {
        var scores: [Double] = []
        for (a, b) in bones {
            guard let ta = template[a], let tb = template[b],
                  let da = detected[a], let db = detected[b] else { continue }
            let tx = Double(tb.x - ta.x), ty = Double(tb.y - ta.y)
            let dx = Double(db.x - da.x), dy = Double(db.y - da.y)
            let tLength = hypot(tx, ty), dLength = hypot(dx, dy)
            guard tLength > 1e-4, dLength > 1e-4 else { continue }
            let cosine = max(-1, min(1, (tx * dx + ty * dy) / (tLength * dLength)))
            let difference = acos(cosine)
            scores.append(max(0, min(1, 1 - (difference - angleSlack) / (angleTolerance - angleSlack))))
        }
        guard scores.count >= 2 else { return nil }
        let mean = scores.reduce(0, +) / Double(scores.count)
        // 平均だけだと腕 1 本の違いが薄まるので、いちばんずれている骨の点数も少し反映する
        return mean * 0.75 + (scores.min() ?? 0) * 0.25
    }

    /// 関節の位置の差。型の体の高さの 5% までは満点、38% ずれると 0 点。
    private static func positionScore(_ template: [Joint: CGPoint], _ detected: [Joint: CGPoint],
                                      joints: [Joint]) -> Double {
        let ys = template.values.map(\.y)
        guard let minY = ys.min(), let maxY = ys.max() else { return 0 }
        let bodyHeight = max(Double(maxY - minY), 0.25)
        let distances = joints.map { joint -> Double in
            let t = template[joint]!, d = detected[joint]!
            return hypot(Double(t.x - d.x), Double(t.y - d.y)) / bodyHeight
        }
        let mean = distances.reduce(0, +) / Double(distances.count)
        let distance = mean * 0.75 + (distances.max() ?? 0) * 0.25
        return max(0, min(1, 1 - (distance - positionSlack) / (positionTolerance - positionSlack)))
    }

    // MARK: - 人の形（シルエット）の重なり

    /// 型の輪郭（等方座標の閉じた多角形）を、width × height のマス目に塗る（上の行から順、true が型の内側）。
    static func rasterize(_ outlines: [[CGPoint]], aspect: CGFloat, width: Int, height: Int) -> [Bool] {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return [Bool](repeating: false, count: width * height)
        }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // 画像座標（上が 0）で描けるよう上下を反転する
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(gray: 1, alpha: 1)
        for outline in outlines where outline.count > 2 {
            let points = outline.map {
                CGPoint(x: ($0.x / aspect + 0.5) * CGFloat(width), y: $0.y * CGFloat(height))
            }
            context.beginPath()
            context.addLines(between: points)
            context.closePath()
            context.fillPath()
        }
        guard let data = context.data else { return [Bool](repeating: false, count: width * height) }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height)
        return (0..<(width * height)).map { bytes[$0] > 127 }
    }

    /// 型の形と、映っている人の形の重なり（IoU: 重なった面積 ÷ どちらかに含まれる面積）から 0〜100 の点数を出す。
    /// 体の関節が取れない顔のアップでも、人の形は取れるので採点できる。
    /// 重なりが 35% 以下で 0 点、80% 以上で満点（人の形の検出のぶれや体型の違いのぶんの余裕）。
    static func silhouetteScore(template: [Bool], detected: [Bool]) -> Double? {
        guard template.count == detected.count, !template.isEmpty else { return nil }
        var both = 0, either = 0
        for i in 0..<template.count {
            let a = template[i], b = detected[i]
            if a && b { both += 1 }
            if a || b { either += 1 }
        }
        guard either > 0 else { return nil }
        let iou = Double(both) / Double(either)
        return max(0, min(1, (iou - 0.35) / (0.8 - 0.35))) * 100
    }

    /// 関節と人の形の点数をまとめる。両方あれば半分ずつ、片方しかなければそれだけで決める。
    static func combine(joints: Double?, silhouette: Double?) -> Double {
        switch (joints, silhouette) {
        case let (j?, s?): return j * 0.5 + s * 0.5
        case let (j?, nil): return j
        case let (nil, s?): return s
        case (nil, nil): return 0
        }
    }
}
