import PhotosUI
import SwiftUI

/// 骨格の描画。型は人の形の輪郭線、検出結果は細い骨格線。
enum PoseDrawing {
    /// 骨格から人の形（頭・首・胴・手足を 1 つにつなげた図形）を作る。太さは肩幅を基準にする。
    static func bodyShape(_ p: [Joint: CGPoint]) -> Path? {
        guard let ls = p[.leftShoulder], let rs = p[.rightShoulder] else { return nil }
        let s = max(distance(ls, rs), 1)
        var parts: [CGPath] = []

        func limb(_ a: CGPoint, _ b: CGPoint, _ width: CGFloat) {
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            parts.append(path.strokedPath(StrokeStyle(lineWidth: width * s, lineCap: .round)).cgPath)
        }
        func limb(_ a: Joint, _ b: Joint, _ width: CGFloat) {
            guard let pa = p[a], let pb = p[b] else { return }
            limb(pa, pb, width)
        }
        func ellipse(center: CGPoint, rx: CGFloat, ry: CGFloat, angle: CGFloat) {
            let transform = CGAffineTransform(rotationAngle: angle)
                .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
            parts.append(Path(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
                .applying(transform).cgPath)
        }

        // 胴: 肩を少し外へ、ウエストを少し内へ、腰を外へ張り出させる
        let shoulderMid = mid(ls, rs)
        if let lh = p[.leftHip], let rh = p[.rightHip] {
            let hipMid = mid(lh, rh)
            let waistMid = lerp(shoulderMid, hipMid, 0.62)
            var torso = Path()
            torso.addLines([
                push(ls, from: shoulderMid, by: 0.1),
                push(rs, from: shoulderMid, by: 0.1),
                push(lerp(rs, rh, 0.62), from: waistMid, by: -0.08),
                push(rh, from: hipMid, by: 0.45),
                push(lh, from: hipMid, by: 0.45),
                push(lerp(ls, lh, 0.62), from: waistMid, by: -0.08),
            ])
            torso.closeSubpath()
            parts.append(torso.cgPath)
            parts.append(torso.strokedPath(StrokeStyle(lineWidth: 0.16 * s, lineJoin: .round)).cgPath)
        } else {
            limb(ls, rs, 0.3)
        }

        // 首と頭（頭は鼻の少し上を中心にした楕円を、首→鼻の向きに傾ける）
        let neck = p[.neck] ?? shoulderMid
        if let nose = p[.nose] {
            let length = max(distance(neck, nose), 0.001)
            let dir = CGPoint(x: (nose.x - neck.x) / length, y: (nose.y - neck.y) / length)
            let center = CGPoint(x: nose.x + dir.x * 0.06 * s, y: nose.y + dir.y * 0.06 * s)
            limb(neck, lerp(neck, center, 0.6), 0.2)
            ellipse(center: center, rx: 0.21 * s, ry: 0.27 * s, angle: atan2(dir.y, dir.x) + .pi / 2)
        }

        // 腕・脚
        limb(.leftShoulder, .leftElbow, 0.27)
        limb(.leftElbow, .leftWrist, 0.21)
        limb(.rightShoulder, .rightElbow, 0.27)
        limb(.rightElbow, .rightWrist, 0.21)
        limb(.leftHip, .leftKnee, 0.42)
        limb(.leftKnee, .leftAnkle, 0.28)
        limb(.rightHip, .rightKnee, 0.42)
        limb(.rightKnee, .rightAnkle, 0.28)

        // 手と足先
        for (elbow, wrist) in [(Joint.leftElbow, Joint.leftWrist), (.rightElbow, .rightWrist)] {
            guard let e = p[elbow], let w = p[wrist] else { continue }
            let hand = extend(e, w, by: 0.12 * s)
            ellipse(center: hand, rx: 0.1 * s, ry: 0.14 * s, angle: atan2(w.y - e.y, w.x - e.x) - .pi / 2)
        }
        for ankle in [Joint.leftAnkle, .rightAnkle] {
            guard let a = p[ankle] else { continue }
            ellipse(center: CGPoint(x: a.x, y: a.y + 0.06 * s), rx: 0.16 * s, ry: 0.09 * s, angle: 0)
        }

        guard var shape = parts.first else { return nil }
        for part in parts.dropFirst() {
            shape = shape.union(part)
        }
        return Path(shape)
    }

    /// 人の形を輪郭線と薄い塗りで描く。
    static func drawOutline(_ points: [Joint: CGPoint], in context: GraphicsContext,
                            color: Color, lineWidth: CGFloat, fillOpacity: Double) {
        guard let shape = bodyShape(points) else { return }
        draw(shape, in: context, color: color, lineWidth: lineWidth, fillOpacity: fillOpacity)
    }

    /// 写真から取った輪郭（閉じた多角形）を、なめらかな曲線にして描く。
    static func drawContour(_ points: [CGPoint], in context: GraphicsContext,
                            color: Color, lineWidth: CGFloat, fillOpacity: Double) {
        draw(smoothClosedPath(points), in: context, color: color, lineWidth: lineWidth, fillOpacity: fillOpacity)
    }

    /// 型を描く。写真から取った輪郭があればそれを、なければ骨格から作った形を使う。
    /// transform は等方座標から描画先の座標への変換。
    static func drawTemplate(_ template: PoseTemplate, in context: GraphicsContext,
                             transform: (CGPoint) -> CGPoint,
                             color: Color, lineWidth: CGFloat, fillOpacity: Double) {
        let outlines = template.allOutlines
        if !outlines.isEmpty {
            for outline in outlines {
                drawContour(outline.map(transform), in: context, color: color,
                            lineWidth: lineWidth, fillOpacity: fillOpacity)
            }
        } else {
            drawOutline(template.joints.mapValues(transform), in: context, color: color,
                        lineWidth: lineWidth, fillOpacity: fillOpacity)
        }
        // テーブルの縁（料理・ドリンクの型）
        for line in template.lines ?? [] where line.count > 1 {
            var path = Path()
            path.addLines(line.map(transform))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
    }

    private static func draw(_ shape: Path, in context: GraphicsContext,
                             color: Color, lineWidth: CGFloat, fillOpacity: Double) {
        context.fill(shape, with: .color(color.opacity(fillOpacity)))
        context.stroke(shape, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
    }

    /// 点を通るなめらかな閉曲線（Catmull-Rom をベジェ曲線に直したもの）。
    static func smoothClosedPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        let n = points.count
        guard n > 2 else { return path }
        path.move(to: points[0])
        for i in 0..<n {
            let p0 = points[(i - 1 + n) % n]
            let p1 = points[i]
            let p2 = points[(i + 1) % n]
            let p3 = points[(i + 2) % n]
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        path.closeSubpath()
        return path
    }

    /// 点を通るなめらかな開いた曲線（Catmull-Rom。両端は端の点を繰り返す）。
    static func smoothOpenPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        let n = points.count
        guard n > 1 else { return path }
        path.move(to: points[0])
        for i in 0..<(n - 1) {
            let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[min(i + 2, n - 1)]
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        return path
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    private static func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { lerp(a, b, 0.5) }
    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
    /// 中心から見て point を外側（負なら内側）へずらす。
    private static func push(_ point: CGPoint, from center: CGPoint, by factor: CGFloat) -> CGPoint {
        CGPoint(x: point.x + (point.x - center.x) * factor, y: point.y + (point.y - center.y) * factor)
    }
    /// a→b の向きに、b からさらに length だけ先の点。
    private static func extend(_ a: CGPoint, _ b: CGPoint, by length: CGFloat) -> CGPoint {
        let d = max(distance(a, b), 0.001)
        return CGPoint(x: b.x + (b.x - a.x) / d * length, y: b.y + (b.y - a.y) / d * length)
    }

    /// 顔のボーン（あごのライン・両目・鼻・口）。transform は顔の座標から描画先の座標への変換。
    /// 横顔などで目が取れていないときは、顔の枠（楕円）と、向いている側に鼻の形（くの字）を描く。
    static func drawFace(_ face: FaceShape, in context: GraphicsContext, transform: (CGPoint) -> CGPoint,
                         color: Color, lineWidth: CGFloat) {
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        let center = transform(face.center)
        let top = transform(CGPoint(x: face.center.x, y: face.center.y - face.height / 2))
        let bottom = transform(CGPoint(x: face.center.x, y: face.center.y + face.height / 2))
        let h = abs(bottom.y - top.y)
        if face.contour.count > 2 {
            // 点を通るなめらかな線（ボーン入れツールで直したあごは 8 点なので、直線でつなぐと角ばる）
            context.stroke(smoothOpenPath(face.contour.map(transform)), with: .color(color), style: style)
        } else {
            // 顔の枠（横顔では少し細い楕円）
            let w = h * (abs(face.yaw) > 45 ? 0.6 : 0.78)
            let rect = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
            // 顔の傾き（roll、画面で反時計回りが +）に合わせて楕円も回す
            let turn = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: -face.roll * .pi / 180)
                .translatedBy(x: -center.x, y: -center.y)
            context.stroke(Path(ellipseIn: rect).applying(turn), with: .color(color), style: style)
        }
        let drawnMouth = (face.mouthLines ?? []).filter { $0.count > 1 }
        let drawnNose = (face.noseLines ?? []).filter { $0.count > 1 }
        if !drawnMouth.isEmpty {
            // ボーン入れツールでペンで描いた口の線
            for line in drawnMouth {
                context.stroke(smoothOpenPath(line.map(transform)), with: .color(color), style: style)
            }
        } else if face.mouth.count > 2 {
            var mouth = Path()
            mouth.addLines(face.mouth.map(transform))
            mouth.closeSubpath()
            context.stroke(mouth, with: .color(color), style: style)
        }
        let r = lineWidth * 1.6
        if let leftEye = face.leftEye, let rightEye = face.rightEye {
            let left = transform(leftEye), right = transform(rightEye)
            var axis = Path()
            axis.move(to: left)
            axis.addLine(to: right)
            if drawnNose.isEmpty, let nose = face.nose {
                axis.move(to: CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2))
                axis.addLine(to: transform(nose))
            }
            context.stroke(axis, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: lineWidth * 0.7, lineCap: .round))
            for p in [left, right] {
                context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(color))
            }
        }
        if !drawnNose.isEmpty {
            // ボーン入れツールでペンで描いた鼻の線（自動の鼻の形の代わり）
            for line in drawnNose {
                context.stroke(smoothOpenPath(line.map(transform)), with: .color(color), style: style)
            }
        } else if face.leftEye == nil || face.rightEye == nil, let nosePoint = face.nose {
            // 横顔・斜めの顔: 目が取れないので、鼻の形（くの字）を、鼻の点の所に顔の向いている側へ描く。
            // 鼻の点がない（取れなかった・ボーン入れツールで消した）ときは描かない
            let side: CGFloat = face.yaw >= 0 ? 1 : -1
            let tip = transform(nosePoint)
            var nose = Path()
            nose.move(to: CGPoint(x: tip.x - side * h * 0.1, y: tip.y - h * 0.2))
            nose.addLine(to: tip)
            nose.addLine(to: CGPoint(x: tip.x - side * h * 0.08, y: tip.y + h * 0.04))
            context.stroke(nose, with: .color(color), style: style)
        }
    }

    static func drawSkeleton(_ points: [Joint: CGPoint], in context: GraphicsContext, color: Color) {
        let style = StrokeStyle(lineWidth: 3, lineCap: .round)
        for (a, b) in Joint.bones {
            guard let pa = points[a], let pb = points[b] else { continue }
            var path = Path()
            path.move(to: pa)
            path.addLine(to: pb)
            context.stroke(path, with: .color(color), style: style)
        }
        for p in points.values {
            context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(color))
        }
    }

    /// 型の骨格と比べて色分けした骨格。骨ごとの向きの差が 20 度までは緑、50 度以上はオレンジ（間は黄色）。
    /// インカメラ（鏡像）では左右のラベルが入れ替わるので、全体の差が小さい方の対応で比べる（一致度と同じ）
    static func drawSkeleton(_ points: [Joint: CGPoint], guide: [Joint: CGPoint], in context: GraphicsContext) {
        func difference(_ pa: CGPoint, _ pb: CGPoint, _ ga: CGPoint, _ gb: CGPoint) -> Double? {
            let dx = Double(pb.x - pa.x), dy = Double(pb.y - pa.y)
            let gx = Double(gb.x - ga.x), gy = Double(gb.y - ga.y)
            let l1 = hypot(dx, dy), l2 = hypot(gx, gy)
            guard l1 > 1, l2 > 1 else { return nil }
            return acos(max(-1, min(1, (dx * gx + dy * gy) / (l1 * l2)))) * 180 / .pi
        }
        func differences(_ map: (Joint) -> Joint) -> [Int: Double] {
            var result: [Int: Double] = [:]
            for (i, bone) in Joint.bones.enumerated() {
                guard let pa = points[bone.0], let pb = points[bone.1],
                      let ga = guide[map(bone.0)], let gb = guide[map(bone.1)],
                      let d = difference(pa, pb, ga, gb) else { continue }
                result[i] = d
            }
            return result
        }
        let straight = differences { $0 }
        let swapped = differences { $0.mirrored }
        func mean(_ d: [Int: Double]) -> Double { d.isEmpty ? .infinity : d.values.reduce(0, +) / Double(d.count) }
        let chosen = mean(swapped) < mean(straight) ? swapped : straight
        let style = StrokeStyle(lineWidth: 3.5, lineCap: .round)
        for (i, (a, b)) in Joint.bones.enumerated() {
            guard let pa = points[a], let pb = points[b] else { continue }
            var path = Path()
            path.move(to: pa)
            path.addLine(to: pb)
            let color: Color
            if let d = chosen[i] {
                color = d <= 20 ? .green : (d >= 50 ? .orange : .yellow)
            } else {
                color = .cyan
            }
            context.stroke(path, with: .color(color.opacity(0.9)), style: style)
        }
        for p in points.values {
            context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.cyan))
        }
    }

    /// サムネイル用に、点の集まり全体を枠に収める変換を返す。
    static func fitTransform(_ points: [CGPoint], into size: CGSize, inset: CGFloat) -> (CGPoint) -> CGPoint {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
            return { $0 }
        }
        let width = max(maxX - minX, 0.001)
        let height = max(maxY - minY, 0.001)
        let scale = min((size.width - inset * 2) / width, (size.height - inset * 2) / height)
        let offsetX = (size.width - width * scale) / 2
        let offsetY = (size.height - height * scale) / 2
        return { CGPoint(x: offsetX + ($0.x - minX) * scale, y: offsetY + ($0.y - minY) * scale) }
    }
}

/// プレビューに重ねる型（人の形の輪郭）。型・一致したか・濃さが変わったときだけ描き直す（Equatable）。
/// 線の内側は塗らない（肌の加工の効き具合が見えにくくなるため）。
/// 影（shadow）は毎回画面外に描き直すので重い。代わりに暗い太線を下に敷いて見やすくする。
struct PoseTemplateOverlay: View, Equatable {
    let template: PoseTemplate
    let matched: Bool
    /// 0...1
    let opacity: Double

    var body: some View {
        Canvas { context, size in
            var layer = context
            layer.opacity = opacity
            let transform = { PoseSpace.toView($0, size: size) }
            PoseDrawing.drawTemplate(template, in: layer, transform: transform,
                                     color: .black.opacity(0.35), lineWidth: 5, fillOpacity: 0)
            PoseDrawing.drawTemplate(template, in: layer, transform: transform,
                                     color: matched ? .green : .white, lineWidth: 3, fillOpacity: 0)
            // 顔のボーン（目・鼻・口・あご）も重ねて、顔の位置と大きさを合わせやすくする
            // 2 人以上の型は、全員の顔を描く
            for face in template.people.compactMap(\.face) {
                PoseDrawing.drawFace(face, in: layer, transform: transform, color: .black.opacity(0.35), lineWidth: 3.5)
                PoseDrawing.drawFace(face, in: layer, transform: transform,
                                     color: matched ? .green : .white, lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
    }
}

/// 一致度に応じて型の色を変える。一致度が変わっても、色が変わらなければ型は描き直さない。
struct TemplateLayer: View {
    @ObservedObject var feed: PoseFeed
    let template: PoseTemplate
    let opacity: Double

    var body: some View {
        PoseTemplateOverlay(template: template,
                            matched: (feed.score ?? 0) >= CameraManager.matchThreshold,
                            opacity: opacity)
            .equatable()
    }
}

/// 検出した骨格（細い線）。型があるときは、型の骨格を白い点線で重ね、
/// 自分の骨は型と向きが合っていれば緑、ずれていればオレンジにする（どこを直せば一致度が上がるか分かるように）。
struct SkeletonLayer: View {
    @ObservedObject var feed: PoseFeed
    var template: PoseTemplate? = nil

    var body: some View {
        if feed.detected != nil || feed.face != nil || template != nil {
            Canvas { context, size in
                let toView = { (p: CGPoint) in CGPoint(x: p.x * size.width, y: p.y * size.height) }
                let guide = template.map { $0.joints.mapValues { PoseSpace.toView($0, size: size) } } ?? [:]
                // 2 人以上の型は、全員の骨格を点線で描く
                let guides = template?.people.map { $0.joints.mapValues { PoseSpace.toView($0, size: size) } } ?? []
                for person in guides {
                    let dash = StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 6])
                    for (a, b) in Joint.bones {
                        guard let pa = person[a], let pb = person[b] else { continue }
                        var path = Path()
                        path.move(to: pa)
                        path.addLine(to: pb)
                        context.stroke(path, with: .color(.black.opacity(0.35)),
                                       style: StrokeStyle(lineWidth: 4.5, lineCap: .round, dash: [6, 6]))
                        context.stroke(path, with: .color(.white.opacity(0.9)), style: dash)
                    }
                }
                if let detected = feed.detected {
                    let points = detected.mapValues(toView)
                    if guide.isEmpty {
                        PoseDrawing.drawSkeleton(points, in: context, color: .cyan.opacity(0.8))
                    } else {
                        PoseDrawing.drawSkeleton(points, guide: guide, in: context)
                    }
                }
                if let face = feed.face {
                    PoseDrawing.drawFace(face, in: context, transform: toView, color: .cyan.opacity(0.8), lineWidth: 2)
                }
                // 2 人以上の型のとき、2 人目以降に映っている人
                for other in feed.others {
                    PoseDrawing.drawSkeleton(other.mapValues(toView), in: context, color: .cyan.opacity(0.8))
                }
                for face in feed.otherFaces {
                    PoseDrawing.drawFace(face, in: context, transform: toView, color: .cyan.opacity(0.8), lineWidth: 2)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// 一致度の表示。
struct MatchBadge: View {
    @ObservedObject var feed: PoseFeed

    var body: some View {
        let score = feed.score ?? 0
        Badge(text: "一致度 \(Int(score))%",
              color: score >= CameraManager.matchThreshold ? .green : .black.opacity(0.55))
    }
}

struct PoseThumbnail: View {
    let template: PoseTemplate
    let isSelected: Bool
    var isFavorite = false
    /// 見本写真のサムネイル（作り終わるまでは nil。作るのはメインスレッド以外）
    @State private var image: UIImage?

    static let size = CGSize(width: 58, height: 80)

    var body: some View {
        VStack(spacing: 4) {
            Group {
                // 組み込みポーズは見本写真、写真から登録したポーズは輪郭を表示する
                if let name = template.imageName {
                    if let image = image ?? PoseImageCache.cachedThumbnail(named: name) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.clear
                            .task(id: name) { image = await PoseImageCache.loadThumbnail(named: name) }
                    }
                } else {
                    Canvas { context, size in
                        let outlines = template.allOutlines
                        let points = outlines.isEmpty ? Array(template.joints.values) : outlines.flatMap { $0 }
                        let transform = PoseDrawing.fitTransform(points, into: size,
                                                                 inset: outlines.isEmpty ? 10 : 4)
                        PoseDrawing.drawTemplate(template, in: context, transform: transform,
                                                 color: .chromeText, lineWidth: 1.2, fillOpacity: 0.15)
                    }
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .background(Color.chromeText.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Color.yellow : .clear, lineWidth: 2))
            .overlay(alignment: .topTrailing) {
                if isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.pink)
                        .padding(3)
                        .background(Circle().fill(Color.black.opacity(0.5)))
                        .padding(3)
                }
            }
            Text(template.name)
                .font(.caption2)
                .lineLimit(1)
                .frame(width: 66)
        }
        .foregroundStyle(Color.chromeText)
    }
}

struct TileLabel: View {
    let systemImage: String
    let title: String
    var highlighted = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: PoseThumbnail.size.width, height: PoseThumbnail.size.height)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(highlighted ? Color.yellow : .clear, lineWidth: 2))
            Text(title)
                .font(.caption2)
                .lineLimit(1)
                .frame(width: 66)
        }
        .foregroundStyle(.white)
    }
}

/// 画面下部の横スクロールのポーズ選択。写真からの登録もここから行う。
struct PoseStrip: View {
    @ObservedObject var library: PoseLibrary
    @Binding var selection: PoseTemplate?
    /// カメラの画面の縦横比。取り込んだ写真の構図をこの比率の枠で合わせる
    let frameAspect: CGFloat
    let onShowAll: () -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var isImporting = false
    @State private var importError: String?
    @State private var draft: PoseImportDraft?

    /// 一覧の中で、画面の中央にあるポーズ（"カテゴリ|id"）
    @State private var visibleItem: String?
    /// 最後に選んだポーズの一覧の中の位置（パネルを閉じて開き直しても、その位置から表示する）
    private static var lastSelectedItem: String?
    /// 上の見出しで選ばれているカテゴリ
    @State private var activeCategory: String?
    /// 見出しをタップして一覧を動かしている間は、スクロールに合わせて見出しを動かさない
    @State private var isJumping = false
    /// ポーズの一覧を直接動かすためのもの（見出しのタップ用）
    @State private var rowProxy: ScrollViewProxy?
    /// 見出しのタップで一覧を合わせ直す予約の番号
    @State private var jumpGeneration = 0
    /// パネルを下へフリックして閉じている途中（指の下のポーズを選ばない）
    @Environment(\.suppressPanelTaps) private var suppressTaps

    private struct Item: Identifiable {
        let id: String
        let category: String
        let pose: PoseTemplate
    }

    /// カテゴリの順にすべてのポーズを並べたもの（お気に入りのポーズは、元のカテゴリにも並ぶ）
    private var items: [Item] {
        library.categories.flatMap { category in
            library.poses(in: category).map { Item(id: "\(category)|\($0.id)", category: category, pose: $0) }
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            categoryTabs
            poseRow
        }
        .onAppear(perform: restorePosition)
        .onChange(of: pickerItem) {
            guard let item = pickerItem else { return }
            Task { await importPose(from: item) }
        }
        .alert("ポーズを登録できませんでした",
               isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .sheet(item: $draft) { draft in
            PoseImportEditor(draft: draft, aspect: frameAspect) { shape in
                let template = PoseImporter.makeTemplate(name: "マイポーズ \(library.userPoses.count + 1)",
                                                         shape: shape)
                library.add(template)
                selection = template
            }
        }
    }

    /// カテゴリの見出し。タップするとそのカテゴリの先頭へ一覧が動く。一覧をスライドすると、見えている
    /// カテゴリの見出しが選ばれる。
    private var categoryTabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(library.categories, id: \.self) { category in
                        CategoryTab(title: category,
                                    active: category == (activeCategory ?? library.categories.first)) {
                            jump(to: category)
                        }
                        .id(category)
                    }
                }
                .padding(.horizontal)
            }
            .onChange(of: activeCategory) {
                guard let activeCategory else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(activeCategory, anchor: .center) }
            }
        }
        .frame(height: 22)
    }

    private var poseRow: some View {
        ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 10) {
                Button { if !suppressTaps { selection = nil } } label: {
                    TileLabel(systemImage: "nosign", title: "なし", highlighted: selection == nil)
                }
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    TileLabel(systemImage: isImporting ? "hourglass" : "photo.badge.plus", title: "写真から")
                }
                .disabled(isImporting)
                Button(action: onShowAll) {
                    TileLabel(systemImage: "square.grid.2x2", title: "一覧")
                }
                ForEach(items) { item in
                    PoseCell(library: library, pose: item.pose, selection: $selection) {
                        guard !suppressTaps else { return }
                        selection = item.pose
                        Self.lastSelectedItem = item.id
                        // 選んだポーズのカテゴリへ、見出しをすぐ切り替える
                        isJumping = true
                        activeCategory = item.category
                        withAnimation(.easeOut(duration: 0.25)) { visibleItem = item.id }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { isJumping = false }
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal)
        }
        // 画面の中央にあるポーズで見出しを決める（中央を越えた時点で、前後のカテゴリへ切り替わる）
        .scrollPosition(id: $visibleItem, anchor: .center)
        .onChange(of: visibleItem) {
            guard !isJumping, let visibleItem,
                  let category = items.first(where: { $0.id == visibleItem })?.category,
                  category != activeCategory else { return }
            activeCategory = category
        }
        .onAppear { rowProxy = proxy }
        }
    }

    /// 見出しをタップしたとき、そのカテゴリの先頭のポーズを中央へ動かす。
    /// 以前は、スワイプの惰性に負けないよう 1.5 秒のあいだ一覧のスクロールを止めて何度も合わせ直していたため、
    /// タップ後しばらく一覧を触れず、見出しのタップも効かないように見えていた（サムネイルの作成で
    /// メインスレッドが止まっていたのも重なっていた）。
    /// いまは一覧を止めず、すぐに動かして、0.35 秒後に 1 回だけ（惰性で外れていれば）合わせ直す。
    /// その間に別の見出しをタップすれば、そちらが優先される
    private func jump(to category: String) {
        guard let first = items.first(where: { $0.category == category }) else { return }
        jumpGeneration += 1
        let generation = jumpGeneration
        isJumping = true
        activeCategory = category
        withAnimation(.easeOut(duration: 0.25)) {
            rowProxy?.scrollTo(first.id, anchor: .center)
            visibleItem = first.id
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard jumpGeneration == generation else { return }
            if items.first(where: { $0.id == visibleItem })?.category != category {
                rowProxy?.scrollTo(first.id, anchor: .center)
                visibleItem = first.id
            }
            isJumping = false
        }
    }

    /// パネルを開き直したとき、使っているポーズを中央に表示する（使っていなければ先頭のまま）
    private func restorePosition() {
        guard let selection else { return }
        let all = items
        let item = all.first(where: { $0.id == Self.lastSelectedItem && $0.pose.id == selection.id })
            ?? all.first(where: { $0.pose.id == selection.id })
        guard let item else { return }
        isJumping = true
        activeCategory = item.category
        visibleItem = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { isJumping = false }
    }

    @MainActor
    private func importPose(from item: PhotosPickerItem) async {
        isImporting = true
        defer {
            isImporting = false
            pickerItem = nil
        }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            importError = "写真を読み込めませんでした。"
            return
        }
        let made = await Task.detached(priority: .userInitiated) {
            PoseImportDraft.make(from: data)
        }.value
        guard let made else {
            importError = "人物がはっきり写っている写真を選んでください。"
            return
        }
        // 構図を合わせる画面を開く（登録はその画面で行う）
        draft = made
    }
}

/// カテゴリ別の一覧（シート）。自分で登録したポーズは長押しで削除できる。
struct PoseLibraryView: View {
    @ObservedObject var library: PoseLibrary
    @Binding var selection: PoseTemplate?
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Appearance.storageKey) private var appearance: Appearance = .system

    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 8)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(library.categories, id: \.self) { category in
                        Text(category)
                            .font(.headline)
                            .padding(.horizontal)
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(library.poses(in: category)) { pose in
                                PoseCell(library: library, pose: pose, selection: $selection) {
                                    selection = pose
                                    dismiss()
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("ポーズ一覧")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .preferredColorScheme(appearance.scheme)
    }
}

/// ポーズのカテゴリの見出し 1 つ。
struct CategoryTab: View {
    let title: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                HStack(spacing: 3) {
                    if title == PoseLibrary.favoriteCategory {
                        Image(systemName: "heart.fill").font(.system(size: 10))
                    }
                    Text(title)
                }
                .font(.system(size: 13, weight: active ? .bold : .medium))
                .foregroundStyle(active ? Color.yellow : Color.white.opacity(0.75))
                Capsule()
                    .fill(active ? Color.yellow : Color.clear)
                    .frame(height: 2)
            }
            .fixedSize()
        }
    }
}

/// ポーズ 1 つ。タップで選び、長押しでお気に入りに追加・解除（自分で登録したポーズは削除も）。
struct PoseCell: View {
    @ObservedObject var library: PoseLibrary
    let pose: PoseTemplate
    @Binding var selection: PoseTemplate?
    let onSelect: () -> Void

    var body: some View {
        let selected: Bool = selection?.id == pose.id
        let favorite: Bool = library.isFavorite(pose)
        return Button(action: onSelect) {
            PoseThumbnail(template: pose, isSelected: selected, isFavorite: favorite)
        }
        .contextMenu { PoseMenu(library: library, pose: pose, selection: $selection) }
    }
}

/// ポーズを長押ししたときのメニュー。お気に入りの追加・解除と、自分で登録したポーズの削除。
struct PoseMenu: View {
    @ObservedObject var library: PoseLibrary
    let pose: PoseTemplate
    @Binding var selection: PoseTemplate?

    var body: some View {
        if library.isFavorite(pose) {
            Button { library.toggleFavorite(pose) } label: {
                Label("お気に入りから外す", systemImage: "heart.slash")
            }
        } else {
            Button { library.toggleFavorite(pose) } label: {
                Label("お気に入りに追加", systemImage: "heart")
            }
        }
        if pose.isUserCreated {
            Button("削除", role: .destructive) {
                if selection?.id == pose.id { selection = nil }
                library.delete(pose)
            }
        }
    }
}

/// パネルを下へフリックして閉じている途中は、指の下にあるポーズ・フィルターを選ばない
struct SuppressPanelTapsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var suppressPanelTaps: Bool {
        get { self[SuppressPanelTapsKey.self] }
        set { self[SuppressPanelTapsKey.self] = newValue }
    }
}
