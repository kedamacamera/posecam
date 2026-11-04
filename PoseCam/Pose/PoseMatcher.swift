import CoreGraphics
import Foundation

/// 型と検出した骨格の一致度（0〜100）を、骨ごとの向きの差から求める。
/// 位置や大きさは見ないので、画面のどこに立っていても判定できる。
enum PoseMatcher {
    private static let bones: [(Joint, Joint)] = [
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
        (.neck, .nose),
        (.leftShoulder, .rightShoulder),
    ]

    /// どちらも等方座標で渡す。
    static func score(template: [Joint: CGPoint], detected: [Joint: CGPoint]) -> Double? {
        // インカメラ（鏡像）や後ろ向きでは左右のラベルが入れ替わるので、両方試して良い方を採る
        let swapped = Dictionary(uniqueKeysWithValues: detected.map { ($0.key.mirrored, $0.value) })
        let candidates = [compare(template, detected), compare(template, swapped)].compactMap { $0 }
        return candidates.max()
    }

    private static func compare(_ template: [Joint: CGPoint], _ detected: [Joint: CGPoint]) -> Double? {
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
            let angle = acos(cosine)
            total += max(0, 1 - angle / (.pi / 2))
            count += 1
        }
        // 上半身だけ写っていても判定できるよう、5 本見えていれば採点する
        guard count >= 5 else { return nil }
        return total / Double(count) * 100
    }
}
