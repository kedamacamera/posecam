import PhotosUI
import SwiftUI

/// 骨格の描画。型（太い半透明のシルエット）と検出結果（細い線）で共用する。
enum PoseDrawing {
    static func drawFigure(_ points: [Joint: CGPoint], in context: GraphicsContext,
                           lineWidth: CGFloat, color: Color) {
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        if let ls = points[.leftShoulder], let rs = points[.rightShoulder],
           let rh = points[.rightHip], let lh = points[.leftHip] {
            var torso = Path()
            torso.addLines([ls, rs, rh, lh])
            torso.closeSubpath()
            context.fill(torso, with: .color(color))
            context.stroke(torso, with: .color(color), style: style)
        }
        for (a, b) in Joint.bones {
            guard let pa = points[a], let pb = points[b] else { continue }
            var path = Path()
            path.move(to: pa)
            path.addLine(to: pb)
            context.stroke(path, with: .color(color), style: style)
        }
        if let nose = points[.nose] {
            let r = lineWidth * 1.3
            context.fill(Path(ellipseIn: CGRect(x: nose.x - r, y: nose.y - r, width: r * 2, height: r * 2)),
                         with: .color(color))
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

    /// 肩幅に合わせて線の太さを決める（上半身ポーズは大きく、全身ポーズは細く）。
    static func lineWidth(for points: [Joint: CGPoint], fallback: CGFloat) -> CGFloat {
        guard let ls = points[.leftShoulder], let rs = points[.rightShoulder] else { return fallback }
        return max(hypot(ls.x - rs.x, ls.y - rs.y) * 0.35, 1.5)
    }

    /// サムネイル用に、骨格全体を枠に収める。
    static func fit(_ points: [Joint: CGPoint], into size: CGSize, inset: CGFloat) -> [Joint: CGPoint] {
        let xs = points.values.map(\.x)
        let ys = points.values.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return [:] }
        let width = max(maxX - minX, 0.001)
        let height = max(maxY - minY, 0.001)
        let scale = min((size.width - inset * 2) / width, (size.height - inset * 2) / height)
        let offsetX = (size.width - width * scale) / 2
        let offsetY = (size.height - height * scale) / 2
        return points.mapValues {
            CGPoint(x: offsetX + ($0.x - minX) * scale, y: offsetY + ($0.y - minY) * scale)
        }
    }
}

/// プレビューに重ねる型と検出した骨格。
struct PoseOverlayView: View {
    let template: PoseTemplate?
    let detected: [Joint: CGPoint]?
    let matched: Bool

    var body: some View {
        Canvas { context, size in
            if let template {
                let points = template.joints.mapValues { PoseSpace.toView($0, size: size) }
                let width = PoseDrawing.lineWidth(for: points, fallback: size.height * 0.04)
                // レイヤーごと半透明にして、線の重なりが濃くならないようにする
                var layer = context
                layer.opacity = 0.45
                layer.drawLayer { inner in
                    PoseDrawing.drawFigure(points, in: inner, lineWidth: width, color: matched ? .green : .white)
                }
            }
            if let detected {
                let points = detected.mapValues { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                PoseDrawing.drawSkeleton(points, in: context, color: .cyan.opacity(0.8))
            }
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
                let points = PoseDrawing.fit(template.joints, into: size, inset: 9)
                PoseDrawing.drawFigure(points, in: context,
                                       lineWidth: PoseDrawing.lineWidth(for: points, fallback: 4), color: .white)
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
