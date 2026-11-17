import CoreGraphics
import Foundation

/// 撮ってもらう人ガイド。撮る人の画面に「撮影目標」のチェックリストを出す。
///
/// アプリが確実に判断できる項目だけを出す（2026-11-14 に COCO の正解付き写真で、Vision の検出を種類別に測った結果から）:
/// - 傾き: 端末のセンサーなので姿勢によらない
/// - 頭の上の余白: 人物の切り抜きの上端。立ち・座り・上半身・後ろ向きのどれでも、ずれは画面の高さの 0.4%（中央値）
/// - 足先まで入っている: 骨格の足首。立ち姿の全身なら 96% 当たるが、座りでは 33% しか当たらないので、
///   立ち姿の全身と分かるときだけ出す
/// - 顔の向き: ポーズの型に顔の向きがあるときだけ（型がなければ、どちらを向くのが正解か決まらない）
/// 見栄え（脚が長く見えるか・背景が良いか）は判断できないので出さない。
struct ShootingGuide {
    struct Item: Identifiable, Equatable {
        let id: String
        /// 目標（例: 「まっすぐ構える」）
        let title: String
        let isDone: Bool
        /// できていないときの指示（撮る人向け）
        let hint: String?
    }

    /// 頭の上の余白の目安（画面の高さに対する割合）。これより狭いと頭が切れそう、広いと上が空きすぎ
    static let minHeadroom: CGFloat = 0.02
    static let maxHeadroom: CGFloat = 0.15
    /// 傾きをまっすぐとみなす範囲（度）
    static let levelTolerance: Double = 2
    /// 顔の向きを型と同じとみなす範囲（度）
    static let yawTolerance: Double = 15
    /// 足首が画面の下端にかかっているとみなす位置（画面の高さに対する割合）
    static let bottomEdge: CGFloat = 0.97

    /// 座っている型（足首が写っていても、座りでは足首の検出が当てにならない）
    private static let seatedCategories: Set<String> = ["座り", "食事"]

    /// - Parameters:
    ///   - tilt: 画面の傾き（度。近い方の縦・横からのずれ）。nil なら端末を寝かせている（真上から撮る）
    ///   - pose: 検出した骨格（画像座標・左上原点）
    ///   - personTop: 人物の切り抜きの上端（画面の高さに対する割合）。人がいなければ nil
    ///   - face: 検出した顔
    ///   - template: 選んでいるポーズの型
    static func items(tilt: Double?, pose: [Joint: CGPoint]?, personTop: CGFloat?, face: FaceShape?,
                      template: PoseTemplate?) -> [Item] {
        var items: [Item] = []

        if let tilt {
            let done = abs(tilt) < levelTolerance
            items.append(Item(id: "level", title: "まっすぐ構える", isDone: done,
                              hint: done ? nil : (tilt > 0 ? "スマホを左へ \(Int(abs(tilt).rounded()))° 戻す"
                                                           : "スマホを右へ \(Int(abs(tilt).rounded()))° 戻す")))
        }

        if let top = personTop {
            let hint: String?
            if top < minHeadroom {
                hint = "頭が切れそう。少し引くか、スマホを上へ向ける"
            } else if top > maxHeadroom {
                hint = "上が空きすぎ。少し寄るか、スマホを下へ向ける"
            } else {
                hint = nil
            }
            items.append(Item(id: "headroom", title: "頭の上に少し余白", isDone: hint == nil, hint: hint))
        } else {
            items.append(Item(id: "headroom", title: "人を画面に入れる", isDone: false, hint: "人が見つかりません"))
        }

        if expectsFullBody(template: template, pose: pose) {
            let ankles = [pose?[.leftAnkle], pose?[.rightAnkle]].compactMap { $0 }
            let done = ankles.count == 2 && ankles.allSatisfy { $0.y < bottomEdge }
            items.append(Item(id: "feet", title: "足先まで入れる", isDone: done,
                              hint: done ? nil : "足先が切れています。少し引くか、スマホを下へ向ける"))
        }

        if let target = template?.face, let face {
            // yaw は画像の右を向くと正
            let diff = face.yaw - target.yaw
            let done = abs(diff) < yawTolerance
            items.append(Item(id: "face", title: "顔の向きを型に合わせる", isDone: done,
                              hint: done ? nil : (diff > 0 ? "顔をもう少し画面の左へ向けてもらう"
                                                           : "顔をもう少し画面の右へ向けてもらう")))
        }
        return items
    }

    /// 立ち姿の全身を撮っていると分かるか。
    /// 型があれば型で決める（足首が画面内にあり、座りでない）。
    /// 型がなければ、両膝が両腰より下にあり、太ももが縦に近い（立っている）ときだけ全身とみなす。
    /// 座ると太ももが横になり、膝が腰とほぼ同じ高さに来るので外れる。
    static func expectsFullBody(template: PoseTemplate?, pose: [Joint: CGPoint]?) -> Bool {
        if let template {
            guard !seatedCategories.contains(template.category) else { return false }
            let joints = template.joints
            return [joints[.leftAnkle], joints[.rightAnkle]].contains { ($0?.y ?? 2) <= 1 }
        }
        guard let pose, let lh = pose[.leftHip], let rh = pose[.rightHip],
              let lk = pose[.leftKnee], let rk = pose[.rightKnee] else { return false }
        let thigh = ((lk.y - lh.y) + (rk.y - rh.y)) / 2
        return thigh > 0.08
    }

    /// 人物の形のマス目（上の行から）から、人がいる一番上の行の位置（0...1）。
    /// 細いノイズで反応しないよう、2 マス以上が人の行だけを数える
    static func top(of silhouette: PoseDetector.Silhouette) -> CGFloat? {
        for y in 0..<silhouette.height {
            var count = 0
            for x in 0..<silhouette.width where silhouette.cells[y * silhouette.width + x] {
                count += 1
                if count >= 2 { return CGFloat(y) / CGFloat(silhouette.height) }
            }
        }
        return nil
    }
}
