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
        if let outline = template.outline {
            drawContour(outline.map(transform), in: context, color: color,
                        lineWidth: lineWidth, fillOpacity: fillOpacity)
        } else {
            drawOutline(template.joints.mapValues(transform), in: context, color: color,
                        lineWidth: lineWidth, fillOpacity: fillOpacity)
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

/// プレビューに重ねる型（人の形の輪郭）。検出結果とは別のビューにして、骨格が動くたびに描き直さないようにする。
struct PoseTemplateOverlay: View {
    let template: PoseTemplate
    let matched: Bool
    /// 0...1
    let opacity: Double

    var body: some View {
        Canvas { context, size in
            var layer = context
            layer.opacity = opacity
            layer.drawLayer { inner in
                PoseDrawing.drawTemplate(template, in: inner,
                                         transform: { PoseSpace.toView($0, size: size) },
                                         color: matched ? .green : .white, lineWidth: 3, fillOpacity: 0.12)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 2)
        .allowsHitTesting(false)
    }
}

/// 検出した骨格（細い線）。
struct SkeletonOverlay: View {
    let detected: [Joint: CGPoint]

    var body: some View {
        Canvas { context, size in
            let points = detected.mapValues { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            PoseDrawing.drawSkeleton(points, in: context, color: .cyan.opacity(0.8))
        }
        .allowsHitTesting(false)
    }
}

struct PoseThumbnail: View {
    let template: PoseTemplate
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            Canvas { context, size in
                let transform = PoseDrawing.fitTransform(template.outline ?? Array(template.joints.values),
                                                         into: size, inset: template.outline == nil ? 10 : 4)
                PoseDrawing.drawTemplate(template, in: context, transform: transform,
                                         color: .white, lineWidth: 1.2, fillOpacity: 0.15)
            }
            .frame(width: 56, height: 64)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Color.yellow : .clear, lineWidth: 2))
            Text(template.name)
                .font(.caption2)
                .lineLimit(1)
                .frame(width: 64)
        }
        .foregroundStyle(.white)
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
                .frame(width: 56, height: 64)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(highlighted ? Color.yellow : .clear, lineWidth: 2))
            Text(title)
                .font(.caption2)
                .lineLimit(1)
                .frame(width: 64)
        }
        .foregroundStyle(.white)
    }
}

/// 画面下部の横スクロールのポーズ選択。写真からの登録もここから行う。
struct PoseStrip: View {
    @ObservedObject var library: PoseLibrary
    @Binding var selection: PoseTemplate?
    let onShowAll: () -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                Button { selection = nil } label: {
                    TileLabel(systemImage: "nosign", title: "なし", highlighted: selection == nil)
                }
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    TileLabel(systemImage: isImporting ? "hourglass" : "photo.badge.plus", title: "写真から")
                }
                .disabled(isImporting)
                Button(action: onShowAll) {
                    TileLabel(systemImage: "square.grid.2x2", title: "一覧")
                }
                ForEach(library.allPoses) { pose in
                    Button { selection = pose } label: {
                        PoseThumbnail(template: pose, isSelected: selection?.id == pose.id)
                    }
                }
            }
            .padding(.horizontal)
        }
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
        let name = "マイポーズ \(library.userPoses.count + 1)"
        let template = await Task.detached(priority: .userInitiated) {
            PoseImporter.makeTemplate(from: data, name: name)
        }.value
        guard let template else {
            importError = "人物の全身または上半身がはっきり写っている写真を選んでください。"
            return
        }
        library.add(template)
        selection = template
    }
}

/// カテゴリ別の一覧（シート）。自分で登録したポーズは長押しで削除できる。
struct PoseLibraryView: View {
    @ObservedObject var library: PoseLibrary
    @Binding var selection: PoseTemplate?
    @Environment(\.dismiss) private var dismiss

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
                                Button {
                                    selection = pose
                                    dismiss()
                                } label: {
                                    PoseThumbnail(template: pose, isSelected: selection?.id == pose.id)
                                }
                                .contextMenu {
                                    if pose.isUserCreated {
                                        Button("削除", role: .destructive) {
                                            if selection?.id == pose.id { selection = nil }
                                            library.delete(pose)
                                        }
                                    }
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
        .preferredColorScheme(.dark)
    }
}
