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

    /// 型の形と、映っている人の形の重なりから 0〜100 の点数を出す。
    /// 体の関節が取れない顔のアップでも、人の形は取れるので採点できる。
    /// 細い全身の形はわずかにずれただけで重なりが大きく減るので、相手の形から少し
    /// はみ出した所までは「重なっている」とみなす（横幅の約 4.5%）。
    /// - 型のうち、人の形の近くにある割合（型を埋められているか）
    /// - 人の形のうち、型の近くにある割合（型からはみ出していないか）
    /// の両方をまとめた値（F 値）が 62% 以下で 0 点、95% 以上で満点。
    /// さらに「頭のてっぺんの高さ」と「左右の位置（重心）」のずれを見る。大きな型に体の一部が収まっているだけ
    /// （頭の位置が全然違う）でも重なりは大きく出るので、ずれが画面の 3% までは満点、25% で 0 点にする。
    static func silhouetteScore(template: [Bool], detected: [Bool], width: Int) -> Double? {
        guard template.count == detected.count, !template.isEmpty, width > 0 else { return nil }
        let height = template.count / width
        let radius = max(1, Int((Double(width) * 0.045).rounded()))
        let nearTemplate = dilate(template, width: width, height: height, radius: radius)
        let nearDetected = dilate(detected, width: width, height: height, radius: radius)
        var templateCount = 0, templateCovered = 0, detectedCount = 0, detectedInside = 0
        for i in 0..<template.count {
            if template[i] {
                templateCount += 1
                if nearDetected[i] { templateCovered += 1 }
            }
            if detected[i] {
                detectedCount += 1
                if nearTemplate[i] { detectedInside += 1 }
            }
        }
        guard templateCount > 0 else { return nil }
        guard detectedCount > 0 else { return 0 }
        let recall = Double(templateCovered) / Double(templateCount)
        let precision = Double(detectedInside) / Double(detectedCount)
        guard recall + precision > 0 else { return 0 }
        let f = 2 * recall * precision / (recall + precision)
        let overlap = max(0, min(1, (f - 0.62) / (0.95 - 0.62)))
        return overlap * alignment(template, detected, width: width, height: height) * 100
    }

    /// 頭のてっぺん（いちばん上の行）と左右の重心のずれから、0〜1 の係数を出す。
    private static func alignment(_ template: [Bool], _ detected: [Bool], width: Int, height: Int) -> Double {
        func top(_ cells: [Bool]) -> Double? {
            // ノイズで 1 マスだけ出ている行は無視し、横幅の 2% 以上が人の最初の行を頭のてっぺんとする
            let minimum = max(1, width / 50)
            for y in 0..<height {
                var count = 0
                for x in 0..<width where cells[y * width + x] { count += 1 }
                if count >= minimum { return Double(y) / Double(height) }
            }
            return nil
        }
        func centerX(_ cells: [Bool]) -> Double? {
            var sum = 0.0, count = 0.0
            for i in cells.indices where cells[i] {
                sum += Double(i % width)
                count += 1
            }
            return count > 0 ? sum / count / Double(width) : nil
        }
        guard let tTop = top(template), let dTop = top(detected),
              let tX = centerX(template), let dX = centerX(detected) else { return 0 }
        func factor(_ difference: Double) -> Double {
            max(0, min(1, 1 - (difference - 0.03) / (0.25 - 0.03)))
        }
        return factor(abs(tTop - dTop)) * factor(abs(tX - dX))
    }

    /// true のマスを radius マス分（正方形）広げる。
    private static func dilate(_ cells: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        var horizontal = [Bool](repeating: false, count: cells.count)
        for y in 0..<height {
            for x in 0..<width where cells[y * width + x] {
                for nx in max(0, x - radius)...min(width - 1, x + radius) { horizontal[y * width + nx] = true }
            }
        }
        var result = [Bool](repeating: false, count: cells.count)
        for y in 0..<height {
            for x in 0..<width where horizontal[y * width + x] {
                for ny in max(0, y - radius)...min(height - 1, y + radius) { result[ny * width + x] = true }
            }
        }
        return result
    }

    // MARK: - 顔

    /// 顔の位置・大きさ・傾きの一致度（0〜100）。どちらも等方座標。
    /// - 位置: 両目の真ん中のずれ。顔の幅の 15% までは満点、80% ずれると 0 点
    ///   （全身の写真で顔が小さいときは、画面の高さの 8% を顔の幅とみなして厳しくなりすぎないようにする）
    /// - 大きさ: 両目の間の長さの比。1.1 倍までは満点、1.65 倍（または 0.6 倍）で 0 点
    /// - 傾き: 両目を結ぶ線の角度の差。5 度までは満点、30 度で 0 点
    static func faceScore(template t: FaceShape, detected d: FaceShape) -> Double {
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        func ramp(_ value: Double, _ slack: Double, _ zero: Double) -> Double {
            max(0, min(1, 1 - (value - slack) / (zero - slack)))
        }
        let tEyes = hypot(Double(t.rightEye.x - t.leftEye.x), Double(t.rightEye.y - t.leftEye.y))
        let dEyes = hypot(Double(d.rightEye.x - d.leftEye.x), Double(d.rightEye.y - d.leftEye.y))
        guard tEyes > 1e-4, dEyes > 1e-4 else { return 0 }
        let tMid = mid(t.leftEye, t.rightEye), dMid = mid(d.leftEye, d.rightEye)
        let faceWidth = max(Double(t.width), 0.08)
        let position = ramp(hypot(Double(tMid.x - dMid.x), Double(tMid.y - dMid.y)) / faceWidth, 0.15, 0.8)
        let size = ramp(abs(log(dEyes / tEyes)), log(1.1), log(1.65))
        let tAngle = atan2(Double(t.rightEye.y - t.leftEye.y), Double(t.rightEye.x - t.leftEye.x))
        let dAngle = atan2(Double(d.rightEye.y - d.leftEye.y), Double(d.rightEye.x - d.leftEye.x))
        let angle = ramp(abs(tAngle - dAngle) * 180 / .pi, 5, 30)
        return position * size * angle * 100
    }

    /// 関節・人の形・顔の点数をまとめる。あるものだけで平均する。
    /// 顔は、型の顔が大きいほど（顔のアップほど）重く見る（顔の幅が画面の高さの 25% 以上で、ほかの 2 倍）。
    static func combine(joints: Double?, silhouette: Double?, face: Double? = nil, faceWidth: CGFloat = 0) -> Double {
        var total = 0.0, weight = 0.0
        if let joints { total += joints; weight += 1 }
        if let silhouette { total += silhouette; weight += 1 }
        if let face {
            let w = 0.5 + 1.5 * min(1, Double(faceWidth) / 0.25)
            total += face * w
            weight += w
        }
        return weight > 0 ? total / weight : 0
    }
}
