import CoreImage
import SwiftUI

/// 写真から取り込んだ直後の下書き。
struct PoseImportDraft: Identifiable {
    let id = UUID()
    /// 表示用に縮小した写真
    let image: UIImage
    let analysis: PhotoAnalysis

    /// 写真のデータを読み込み、解析する（重いのでメインスレッド以外から呼ぶ）。
    static func make(from data: Data) -> PoseImportDraft? {
        guard let source = CIImage(data: data, options: [.applyOrientationProperty: true]),
              let analysis = PoseImporter.analyze(source) else { return nil }
        let normalized = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX,
                                                                  y: -source.extent.minY))
        let scale = min(1, 1600 / max(normalized.extent.width, normalized.extent.height))
        let small = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = CIContext().createCGImage(small, from: small.extent) else { return nil }
        return PoseImportDraft(image: UIImage(cgImage: cgImage), analysis: analysis)
    }
}

/// 取り込んだ写真の上に「カメラの画面と同じ比率の枠」を出し、構図を合わせる画面。
/// 枠の中に見えているとおりに、撮影画面へ型が重なる。
/// 「骨格」に切り替えると、自動で見つけた関節と顔を指で動かして直せる（一致度はこの骨格で判定する）。
/// 自動の骨格は、写真によって顔の傾き・腕の位置などを読み違えることがあるため
struct PoseImportEditor: View {
    let draft: PoseImportDraft
    /// カメラの画面の縦横比（幅 / 高さ）
    let aspect: CGFloat
    let onSave: (PoseShape) -> Void

    private enum Mode: String, CaseIterable, Identifiable {
        case crop = "構図"
        case bones = "骨格"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .crop
    @State private var crop: CGRect = .zero
    @State private var dragStart: CGRect?
    @State private var pinchStart: CGRect?
    /// 手で直した関節と顔（写真の上の座標・左上原点・0...1）
    @State private var joints: [Joint: CGPoint] = [:]
    @State private var face: FaceShape?
    @State private var selected: Joint?
    /// 動かし始めたときの、指と関節・顔の中心のずれ（指の下に隠れないよう、つまんだ位置を保つ）
    @State private var grabOffset: CGSize?
    /// 顔の大きさ・傾きを変え始めたときの顔
    @State private var faceAtStart: FaceShape?

    private var photoSize: CGSize { draft.analysis.size }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                Text(mode == .crop
                     ? "ドラッグで位置、ピンチで大きさを合わせてください。黄色い枠の中がそのまま撮影画面になります。"
                     : "丸をドラッグして関節を合わせます。顔は中央の丸で位置、上の丸で大きさと傾きを直します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                GeometryReader { geo in
                    let frame = fittedFrame(in: geo.size)
                    editor(frame: frame)
                        .position(x: frame.midX, y: frame.midY)
                }
                if mode == .bones { boneTools }
            }
            .padding(.vertical, 8)
            .navigationTitle("構図を合わせる")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Button("自動") {
                        if mode == .crop { resetCrop() } else { resetBones() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("登録") {
                        var analysis = draft.analysis
                        analysis.joints = joints
                        analysis.face = face
                        onSave(PoseImporter.shape(for: analysis, crop: crop))
                        dismiss()
                    }
                    .disabled(crop.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            resetCrop()
            resetBones()
        }
    }

    // MARK: - 写真と枠

    private func editor(frame: CGRect) -> some View {
        let scale = crop.width > 0 ? frame.width / crop.width : 1
        return ZStack(alignment: .topLeading) {
            Color.black
            Image(uiImage: draft.image)
                .resizable()
                .frame(width: photoSize.width * scale, height: photoSize.height * scale)
                .offset(x: -crop.minX * scale, y: -crop.minY * scale)
            Canvas { context, _ in
                for outline in draft.analysis.outlines {
                    let points = outline.map { view($0, scale: scale) }
                    PoseDrawing.drawContour(points, in: context, color: .white,
                                            lineWidth: mode == .crop ? 2.5 : 1.2,
                                            fillOpacity: mode == .crop ? 0.12 : 0.05)
                }
                if mode == .bones {
                    drawBones(in: context, scale: scale)
                }
            }
            .allowsHitTesting(false)
            if mode == .bones {
                handles(scale: scale)
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .clipped()
        .overlay(Rectangle().stroke(Color.yellow, lineWidth: 2).allowsHitTesting(false))
        .contentShape(Rectangle())
        .coordinateSpace(name: "editor")
        // 構図のときだけ、写真全体のドラッグ・ピンチで枠を動かす（骨格のときは丸だけを動かす）
        .gesture(
            DragGesture()
                .onChanged { value in
                    let start = dragStart ?? crop
                    dragStart = start
                    // 写真を右へ動かす = 枠を写真の左へ動かす
                    crop.origin = CGPoint(x: start.minX - value.translation.width / scale,
                                          y: start.minY - value.translation.height / scale)
                }
                .onEnded { _ in dragStart = nil },
            including: mode == .crop ? .all : .subviews
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let start = pinchStart ?? crop
                    pinchStart = start
                    // 広げる（拡大）= 枠を小さくする
                    let width = min(max(start.width / value.magnification, photoSize.width * 0.1),
                                    photoSize.width * 4)
                    let height = width / aspect
                    crop = CGRect(x: start.midX - width / 2, y: start.midY - height / 2,
                                  width: width, height: height)
                }
                .onEnded { _ in pinchStart = nil },
            including: mode == .crop ? .all : .subviews
        )
    }

    /// 写真の上の座標（0...1）→ 枠の中の表示位置
    private func view(_ p: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: (p.x * photoSize.width - crop.minX) * scale, y: (p.y * photoSize.height - crop.minY) * scale)
    }

    /// 枠の中の表示位置 → 写真の上の座標（0...1）
    private func photo(_ v: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: (v.x / scale + crop.minX) / photoSize.width, y: (v.y / scale + crop.minY) / photoSize.height)
    }

    // MARK: - 骨格

    private func drawBones(in context: GraphicsContext, scale: CGFloat) {
        let style = StrokeStyle(lineWidth: 2.5, lineCap: .round)
        for (a, b) in Joint.bones {
            guard let pa = joints[a], let pb = joints[b] else { continue }
            var path = Path()
            path.move(to: view(pa, scale: scale))
            path.addLine(to: view(pb, scale: scale))
            context.stroke(path, with: .color(Color.cyan.opacity(0.9)), style: style)
        }
        if let face {
            PoseDrawing.drawFace(face, in: context, transform: { view($0, scale: scale) },
                                 color: .green, lineWidth: 2)
        }
    }

    private func color(of joint: Joint) -> Color {
        if joint == selected { return .yellow }
        switch joint.isLeft {
        case true?: return Color(red: 0.3, green: 0.75, blue: 1)
        case false?: return .orange
        case nil: return .white
        }
    }

    @ViewBuilder private func handles(scale: CGFloat) -> some View {
        ForEach(Joint.allCases.filter { joints[$0] != nil }, id: \.self) { joint in
            let p = view(joints[joint]!, scale: scale)
            Circle()
                .fill(color(of: joint).opacity(0.35))
                .overlay(Circle().stroke(color(of: joint), lineWidth: 2))
                .frame(width: 22, height: 22)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
                .position(p)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("editor"))
                        .onChanged { value in
                            selected = joint
                            let offset = grabOffset ?? CGSize(width: p.x - value.startLocation.x,
                                                              height: p.y - value.startLocation.y)
                            grabOffset = offset
                            joints[joint] = photo(CGPoint(x: value.location.x + offset.width,
                                                          y: value.location.y + offset.height), scale: scale)
                        }
                        .onEnded { _ in grabOffset = nil }
                )
        }
        if let face {
            let center = view(face.center, scale: scale)
            let ring = faceRingPoint(face, scale: scale)
            // 中央の丸: 顔の位置
            Circle()
                .stroke(Color.green, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                .frame(width: 30, height: 30)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .position(center)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("editor"))
                        .onChanged { value in
                            let start = faceAtStart ?? face
                            faceAtStart = start
                            let startCenter = view(start.center, scale: scale)
                            let target = photo(CGPoint(x: startCenter.x + value.translation.width,
                                                       y: startCenter.y + value.translation.height), scale: scale)
                            self.face = transformFace(start, moveTo: target, scale: 1, rotation: 0)
                        }
                        .onEnded { _ in faceAtStart = nil }
                )
            // 上の丸: 大きさと傾き（中心からの距離で大きさ、回した角度で傾き）
            Circle()
                .fill(Color.green)
                .frame(width: 14, height: 14)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
                .position(ring)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("editor"))
                        .onChanged { value in
                            let start = faceAtStart ?? face
                            faceAtStart = start
                            let c = view(start.center, scale: scale)
                            let r0 = faceRingPoint(start, scale: scale)
                            let v0 = CGPoint(x: r0.x - c.x, y: r0.y - c.y)
                            let v1 = CGPoint(x: v0.x + value.translation.width, y: v0.y + value.translation.height)
                            let s = max(0.3, min(3, hypot(v1.x, v1.y) / max(hypot(v0.x, v0.y), 1)))
                            let angle = atan2(v1.y, v1.x) - atan2(v0.y, v0.x)
                            self.face = transformFace(start, moveTo: start.center, scale: s, rotation: angle)
                        }
                        .onEnded { _ in faceAtStart = nil }
                )
        }
    }

    /// 顔の上の丸の位置（顔の中心から、傾きの向きに顔の高さの 0.65 倍）
    private func faceRingPoint(_ face: FaceShape, scale: CGFloat) -> CGPoint {
        let c = view(face.center, scale: scale)
        let length = face.height * photoSize.height * scale * 0.65
        // roll は画面で反時計回りが正（y 下向きの座標では角度の向きが逆）
        let angle = -face.roll * .pi / 180 - .pi / 2
        return CGPoint(x: c.x + CGFloat(cos(angle)) * length, y: c.y + CGFloat(sin(angle)) * length)
    }

    /// 顔を中心ごと動かし、中心のまわりに拡大・回転する（ピクセルの座標で計算する。写真の上の座標は縦横で単位が違う）。
    /// rotation は画面で時計回りが正（ラジアン）
    private func transformFace(_ face: FaceShape, moveTo center: CGPoint, scale s: CGFloat,
                               rotation: CGFloat) -> FaceShape {
        let w = photoSize.width, h = photoSize.height
        let c0 = CGPoint(x: face.center.x * w, y: face.center.y * h)
        let c1 = CGPoint(x: center.x * w, y: center.y * h)
        let cosA = cos(rotation), sinA = sin(rotation)
        var result = face.map { p in
            let dx = p.x * w - c0.x, dy = p.y * h - c0.y
            return CGPoint(x: (c1.x + s * (dx * cosA - dy * sinA)) / w,
                           y: (c1.y + s * (dx * sinA + dy * cosA)) / h)
        }
        result.center = center
        result.height = face.height * s
        result.roll = face.roll - Double(rotation) * 180 / .pi
        return result
    }

    private var boneTools: some View {
        VStack(spacing: 8) {
            if let face {
                HStack {
                    Text("顔の向き").font(.caption)
                    Slider(value: Binding(get: { face.yaw }, set: { self.face?.yaw = $0 }), in: -90...90)
                    Text("\(Int(face.yaw.rounded()))°").font(.caption.monospacedDigit()).frame(width: 40)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let selected {
                        Button("\(selected.label)を消す", role: .destructive) {
                            joints[selected] = nil
                            self.selected = nil
                        }
                        .buttonStyle(.bordered)
                    }
                    if face == nil {
                        Button("＋顔") { addFace() }.buttonStyle(.bordered)
                    } else {
                        Button("顔を消す", role: .destructive) { face = nil }.buttonStyle(.bordered)
                    }
                    // 見つからなかった関節は、枠の中央に置いてから動かせる
                    ForEach(Joint.allCases.filter { joints[$0] == nil }, id: \.self) { joint in
                        Button("＋\(joint.label)") {
                            joints[joint] = photo(CGPoint(x: crop.width / 2, y: crop.height / 2), scale: 1)
                            selected = joint
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    /// 顔が見つからなかったときに、鼻（なければ枠の上の方）に顔を置く
    private func addFace() {
        let center = joints[.nose] ?? photo(CGPoint(x: crop.width / 2, y: crop.height * 0.25), scale: 1)
        face = FaceShape(center: center, height: crop.height * 0.12 / photoSize.height, yaw: 0, roll: 0)
    }

    // MARK: - 枠の大きさ

    /// 画面に収まる、カメラと同じ比率の枠。
    private func fittedFrame(in size: CGSize) -> CGRect {
        let available = CGSize(width: size.width - 32, height: size.height - 16)
        var width = available.width
        var height = width / aspect
        if height > available.height {
            height = available.height
            width = height * aspect
        }
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    private func resetCrop() {
        crop = PoseImporter.defaultCrop(for: draft.analysis, aspect: aspect)
    }

    private func resetBones() {
        joints = draft.analysis.joints
        face = draft.analysis.face
        selected = nil
    }
}
