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

    /// どちらも等方座標で渡す。aspect は画面の縦横比（横 / 縦）で、画面内に見えているはずの関節を決めるのに使う。
    /// 比べられる関節が少なすぎるときは 0 点（体が映っていない）。
    static func score(template: [Joint: CGPoint], detected: [Joint: CGPoint], aspect: CGFloat? = nil) -> Double? {
        guard !template.isEmpty else { return nil }
        // インカメラ（鏡像）や後ろ向きでは左右のラベルが入れ替わるので、両方試して良い方を採る
        let swapped = Dictionary(uniqueKeysWithValues: detected.map { ($0.key.mirrored, $0.value) })
        return max(evaluate(template, detected, aspect: aspect), evaluate(template, swapped, aspect: aspect))
    }

    private static func evaluate(_ template: [Joint: CGPoint], _ detected: [Joint: CGPoint], aspect: CGFloat?) -> Double {
        // 画面内に見えているはずの型の関節（上半身だけの型なら、画面外の脚は数えない）
        let expected = template.filter { _, p in
            guard let aspect else { return true }
            return abs(p.x) <= aspect / 2 + 0.02 && p.y >= -0.02 && p.y <= 1.02
        }
        let found = expected.keys.filter { detected[$0] != nil }
        guard found.count >= 3, !expected.isEmpty else { return 0 }
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
}
