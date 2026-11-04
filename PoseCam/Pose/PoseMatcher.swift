import CoreGraphics
import Foundation

/// 型と検出した骨格の一致度（0〜100）。
/// 「手足の向き」と「関節の位置（画面のどこに、どの大きさで立っているか）」の両方がそろって初めて高くなる。
/// どちらかが大きくずれていれば 0 点。
enum PoseMatcher {
    private static let bones: [(Joint, Joint)] = [
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
        (.neck, .nose),
        (.leftShoulder, .rightShoulder),
    ]

    /// 向きのずれがこの角度で 0 点になる
    private static let angleTolerance = Double.pi / 4
    /// 関節の位置のずれ（体の高さに対する割合）がこの値で 0 点になる
    private static let positionTolerance = 0.18

    /// どちらも等方座標で渡す。
    static func score(template: [Joint: CGPoint], detected: [Joint: CGPoint]) -> Double? {
        // インカメラ（鏡像）や後ろ向きでは左右のラベルが入れ替わるので、両方試して良い方を採る
        let swapped = Dictionary(uniqueKeysWithValues: detected.map { ($0.key.mirrored, $0.value) })
        return [evaluate(template, detected), evaluate(template, swapped)].compactMap { $0 }.max()
    }

    private static func evaluate(_ template: [Joint: CGPoint], _ detected: [Joint: CGPoint]) -> Double? {
        guard let angle = angleScore(template, detected),
              let position = positionScore(template, detected) else { return nil }
        // 掛け算にして、位置か向きのどちらかが大きくずれていれば 0 点になるようにする
        return angle * position * 100
    }

    /// 骨ごとの向きの差。45 度ずれた骨は 0 点。
    private static func angleScore(_ template: [Joint: CGPoint], _ detected: [Joint: CGPoint]) -> Double? {
        var total = 0.0
        var count = 0
        for (a, b) in bones {
            guard let ta = template[a], let tb = template[b],
                  let da = detected[a], let db = detected[b] else { continue }
            let tx = Double(tb.x - ta.x), ty = Double(tb.y - ta.y)
            let dx = Double(db.x - da.x), dy = Double(db.y - da.y)
            let tLength = hypot(tx, ty), dLength = hypot(dx, dy)
            guard tLength > 1e-4, dLength > 1e-4 else { continue }
            let cosine = max(-1, min(1, (tx * dx + ty * dy) / (tLength * dLength)))
            total += max(0, 1 - acos(cosine) / angleTolerance)
            count += 1
        }
        // 上半身だけ写っていても判定できるよう、5 本見えていれば採点する
        guard count >= 5 else { return nil }
        return total / Double(count)
    }

    /// 関節の位置の差。型の体の高さの 18% ずれると 0 点。立ち位置や大きさが違えば下がる。
    private static func positionScore(_ template: [Joint: CGPoint], _ detected: [Joint: CGPoint]) -> Double? {
        let common = template.keys.filter { detected[$0] != nil }
        guard common.count >= 5 else { return nil }
        let ys = template.values.map(\.y)
        guard let minY = ys.min(), let maxY = ys.max() else { return nil }
        let bodyHeight = max(Double(maxY - minY), 0.2)
        let meanDistance = common.reduce(0.0) { sum, joint in
            let t = template[joint]!, d = detected[joint]!
            return sum + hypot(Double(t.x - d.x), Double(t.y - d.y))
        } / Double(common.count)
        return max(0, 1 - meanDistance / (bodyHeight * positionTolerance))
    }
}
