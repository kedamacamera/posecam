import CoreImage
import ImageIO
import SwiftUI

/// 写真の編集。傾き補正（射影変換）・縦横の伸縮・肌の補正をかけて、新しい写真として保存する（元の写真は残る）。
///
/// 傾き補正（Snapseed の「射影変換」と同じ）で画面の端にできるすき間は、
/// - 既定では、すき間が入らない範囲まで自動で切り抜き、元の大きさに戻す
/// - 「反転で埋める」を選ぶと、写真の外側を鏡のように折り返した画像で埋める（空・芝生・壁などが続く屋外向け。
///   屋内では折り返しが目立つ）
/// Photoshop の生成拡張のような、AI で絵を描き足す補完は、端末の中だけでは動かせない（大きな画像生成のモデルか、
/// 外部のサービスが必要）ので入れていない。
struct PhotoEditorView: View {
    let data: Data

    @Environment(\.dismiss) private var dismiss

    private enum Tool: String, CaseIterable, Identifiable {
        case tilt = "傾き", stretch = "伸縮", skin = "肌"
        var id: String { rawValue }
    }

    @State private var tool: Tool = .tilt
    @State private var source: CIImage?
    @State private var properties: [String: Any] = [:]
    @State private var preview: UIImage?
    @State private var vertical = 0.0
    @State private var horizontal = 0.0
    @State private var rotation = 0.0
    @State private var stretchX = 0.0
    @State private var stretchY = 0.0
    @State private var fill = false
    @State private var skin = ProcessingSettings(smoothing: 0, brightening: 0)
    /// 画面用の小さな画像と、その肌・顔のマスク（読み込み時に 1 回だけ求める）
    @State private var small: CIImage?
    @State private var smallMasks: BeautyMasks?
    @State private var isSaving = false
    @State private var message: String?
    @State private var renderTask: Task<Void, Never>?
    /// 写真の拡大（2 本指でつまむ）と、拡大中の移動（1 本指でなぞる）。ダブルタップで元に戻す
    @State private var zoom: CGFloat = 1
    @State private var zoomAtStart: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panAtStart: CGSize = .zero

    private static let context = CIContext()
    private static let processor = FrameProcessor()

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                ZStack {
                    Color.black
                    if let preview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                            .overlay(tool == .skin || zoom > 1.01 ? nil : GridOverlay(style: .thirds))
                            .scaleEffect(zoom)
                            .offset(pan)
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxHeight: .infinity)
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in zoom = min(6, max(1, zoomAtStart * value.magnification)) }
                        .onEnded { _ in
                            zoomAtStart = zoom
                            if zoom <= 1.01 { resetZoom() }
                        }
                        .simultaneously(with: DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                guard zoom > 1.01 else { return }
                                pan = CGSize(width: panAtStart.width + value.translation.width,
                                             height: panAtStart.height + value.translation.height)
                            }
                            .onEnded { _ in panAtStart = pan })
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        if zoom > 1.01 { resetZoom() } else { zoom = 2.5; zoomAtStart = 2.5 }
                    }
                }

                Picker("道具", selection: $tool) {
                    ForEach(Tool.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                VStack(spacing: 6) {
                    switch tool {
                    case .tilt:
                        slider("縦", value: $vertical, range: -1...1)
                        slider("横", value: $horizontal, range: -1...1)
                        slider("回転", value: $rotation, range: -15...15)
                        Picker("すき間", selection: $fill) {
                            Text("切り抜く").tag(false)
                            Text("反転で埋める").tag(true)
                        }
                        .pickerStyle(.segmented)
                    case .stretch:
                        slider("横幅", value: $stretchX, range: -1...1)
                        slider("縦幅", value: $stretchY, range: -1...1)
                    case .skin:
                        slider("美肌", value: $skin.smoothing, range: 0...1, zero: 0)
                        slider("美白", value: $skin.brightening, range: 0...1, zero: 0)
                        slider("赤み", value: $skin.redness, range: 0...1, zero: 0)
                        slider("シミ", value: $skin.blemish, range: 0...1, zero: 0)
                        slider("青ひげ", value: $skin.beard, range: 0...1, zero: 0)
                    }
                }
                .frame(height: 150, alignment: .top)
                .padding(.horizontal)

                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "保存中…" : "保存") { save() }
                        .disabled(source == nil || isSaving)
                }
            }
        }
        .preferredColorScheme(.dark)
        // 撮影画面の上に開いたとき、下の画面が透けて重なって見えないようにする
        .presentationBackground(Color.black)
        .task { load() }
        .onChange(of: vertical) { schedulePreview() }
        .onChange(of: horizontal) { schedulePreview() }
        .onChange(of: rotation) { schedulePreview() }
        .onChange(of: stretchX) { schedulePreview() }
        .onChange(of: stretchY) { schedulePreview() }
        .onChange(of: fill) { schedulePreview() }
        .onChange(of: skin) { schedulePreview() }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                        zero: Double = 0) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 40, alignment: .leading)
            Slider(value: value, in: range).tint(.yellow)
            Button {
                value.wrappedValue = zero
            } label: {
                Image(systemName: "arrow.counterclockwise").font(.caption)
            }
        }
    }

    private func resetZoom() {
        zoom = 1
        zoomAtStart = 1
        pan = .zero
        panAtStart = .zero
    }

    private var geometry: Perspective {
        Perspective(vertical: vertical, horizontal: horizontal, rotationDegrees: rotation,
                    stretchX: stretchX, stretchY: stretchY)
    }

    private func load() {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            message = "写真を読み込めませんでした"
            return
        }
        properties = CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] } ?? [:]
        // 向きは画素に反映したので、保存するときの向きの情報は「そのまま」にする
        properties[kCGImagePropertyOrientation as String] = 1
        let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        source = normalized
        // 画面用は長辺 1800 ピクセルに縮めて計算する（拡大して肌の仕上がりを見られるよう、少し大きめ）
        let scale = min(1, 1800 / max(normalized.extent.width, normalized.extent.height))
        let reduced = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        small = reduced
        schedulePreview()
        Task.detached(priority: .userInitiated) {
            let masks = PoseDetector().analyze(ciImage: reduced, wantsMasks: true).masks
            await MainActor.run {
                smallMasks = masks
                if skin.needsSkinMask { schedulePreview() }
            }
        }
    }

    private func schedulePreview() {
        guard let small else { return }
        renderTask?.cancel()
        let geometry = self.geometry, fill = self.fill, skin = self.skin, masks = smallMasks
        renderTask = Task.detached(priority: .userInitiated) {
            var image = small
            if skin.needsSkinMask, let masks {
                image = Self.processor.process(image, settings: skin, legs: nil, masks: masks)
            }
            let output = geometry.apply(to: image, fill: fill)
            guard !Task.isCancelled,
                  let cgImage = Self.context.createCGImage(output, from: output.extent) else { return }
            let result = UIImage(cgImage: cgImage)
            await MainActor.run { if !Task.isCancelled { preview = result } }
        }
    }

    private func save() {
        guard let source else { return }
        isSaving = true
        let geometry = self.geometry, fill = self.fill, skin = self.skin, properties = self.properties
        Task.detached(priority: .userInitiated) {
            var image = source
            if skin.needsSkinMask, let masks = PoseDetector().analyze(ciImage: source, wantsMasks: true).masks {
                image = Self.processor.process(image, settings: skin, legs: nil, masks: masks)
            }
            let output = geometry.apply(to: image, fill: fill)
            guard let jpeg = PhotoMetadata.jpeg(output, metadata: properties, context: Self.context) else {
                await MainActor.run { isSaving = false; message = "保存できませんでした" }
                return
            }
            MediaSaver.savePhoto(jpeg) { ok in
                DispatchQueue.main.async {
                    isSaving = false
                    message = ok ? "保存しました（元の写真はそのまま残っています）" : "保存できませんでした（写真へのアクセス許可を確認してください）"
                }
            }
        }
    }
}

/// 射影変換の設定。vertical / horizontal は -1...1（端の長さを最大 ±30% 変える）、回転は度、
/// stretchX / stretchY は -1...1（横幅・縦幅を最大 ±30% 伸び縮みさせる）。
struct Perspective {
    var vertical: Double
    var horizontal: Double
    var rotationDegrees: Double
    var stretchX: Double = 0
    var stretchY: Double = 0

    /// image は原点が (0, 0)。出力は元と同じ大きさ。
    /// fill が false のときは、すき間が入らない範囲まで切り抜いて元の大きさに引き伸ばす。
    func apply(to image: CIImage, fill: Bool) -> CIImage {
        let w = image.extent.width, h = image.extent.height
        let target = CGRect(x: 0, y: 0, width: w, height: h)
        let corners = destinationCorners(width: w, height: h)
        // 元の四隅（左下・右下・左上・右上。Core Image は左下原点）→ 変形後の四隅
        let sourceCorners = [CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: 0, y: h), CGPoint(x: w, y: h)]
        guard let homography = Homography(from: sourceCorners, to: corners) else { return image }

        if fill {
            // 周りに鏡のように折り返した画像をつなぎ、写真と同じ変形をかける。変形で裏返らない範囲まで広げる
            for padding in [0.5, 0.3, 0.15] as [CGFloat] {
                let padded = Self.mirrorPadded(image, padding: padding)
                let e = padded.extent
                let mapped = [CGPoint(x: e.minX, y: e.minY), CGPoint(x: e.maxX, y: e.minY),
                              CGPoint(x: e.minX, y: e.maxY), CGPoint(x: e.maxX, y: e.maxY)].map(homography.map)
                guard mapped.allSatisfy({ $0 != nil }) else { continue }
                let p = mapped.map { $0! }
                return padded.applyingFilter("CIPerspectiveTransform", parameters: [
                    "inputBottomLeft": CIVector(cgPoint: p[0]),
                    "inputBottomRight": CIVector(cgPoint: p[1]),
                    "inputTopLeft": CIVector(cgPoint: p[2]),
                    "inputTopRight": CIVector(cgPoint: p[3]),
                ]).cropped(to: target)
            }
        }
        // 端の色を少し外へ延ばしてから変形する（切り抜く範囲の縁がわずかに欠けないように）。
        // clampedToExtent のままの無限の大きさの画像を変形すると、大きさが計算できず画像が作れなかった
        let padded = image.clampedToExtent().cropped(to: image.extent.insetBy(dx: -8, dy: -8))
        let warped = padded.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputBottomLeft": CIVector(cgPoint: corners[0]),
            "inputBottomRight": CIVector(cgPoint: corners[1]),
            "inputTopLeft": CIVector(cgPoint: corners[2]),
            "inputTopRight": CIVector(cgPoint: corners[3]),
        ])
        // 変形後の写真（四角形）の内側に収まる、元と同じ縦横比のいちばん大きな四角を、中心から求めて切り抜く
        let quad = [corners[0], corners[1], corners[3], corners[2]]
        let scale = Self.largestInsideScale(quad: quad, width: w, height: h)
        let crop = CGRect(x: w * (1 - scale) / 2, y: h * (1 - scale) / 2, width: w * scale, height: h * scale)
        return warped.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
            .cropped(to: target)
    }

    /// 中心が画像の中心で、縦横比が画像と同じ四角が quad（凸の四角形、順番に並んだ四隅）に収まる最大の倍率（0...1）
    static func largestInsideScale(quad: [CGPoint], width w: CGFloat, height h: CGFloat) -> CGFloat {
        func inside(_ p: CGPoint) -> Bool {
            var sign: CGFloat = 0
            for i in 0..<4 {
                let a = quad[i], b = quad[(i + 1) % 4]
                let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
                if abs(cross) < 1e-6 { continue }
                if sign == 0 { sign = cross > 0 ? 1 : -1 } else if (cross > 0 ? 1 : -1) != sign { return false }
            }
            return true
        }
        var low: CGFloat = 0.05, high: CGFloat = 1
        if [CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w, y: h), CGPoint(x: 0, y: h)].allSatisfy(inside) {
            return 1
        }
        for _ in 0..<24 {
            let mid = (low + high) / 2
            let dx = w * (1 - mid) / 2, dy = h * (1 - mid) / 2
            let rect = [CGPoint(x: dx, y: dy), CGPoint(x: w - dx, y: dy), CGPoint(x: w - dx, y: h - dy), CGPoint(x: dx, y: h - dy)]
            if rect.allSatisfy(inside) { low = mid } else { high = mid }
        }
        return low
    }

    /// 変形後の四隅（左下・右下・左上・右上）。中心はそのままで、伸縮・台形にしてから回転する。
    private func destinationCorners(width w: CGFloat, height h: CGFloat) -> [CGPoint] {
        let v = CGFloat(vertical) * 0.3, s = CGFloat(horizontal) * 0.3
        let sx = 1 + CGFloat(stretchX) * 0.3, sy = 1 + CGFloat(stretchY) * 0.3
        // 縦: 上の辺を広げ下の辺を縮める（正の値で、上すぼまりのビルをまっすぐにする向き）
        // 横: 左の辺を伸ばし右の辺を縮める
        let local = [
            CGPoint(x: -w / 2 * (1 - v), y: -h / 2 * (1 + s)),
            CGPoint(x: w / 2 * (1 - v), y: -h / 2 * (1 - s)),
            CGPoint(x: -w / 2 * (1 + v), y: h / 2 * (1 + s)),
            CGPoint(x: w / 2 * (1 + v), y: h / 2 * (1 - s)),
        ].map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
        let angle = CGFloat(rotationDegrees) * .pi / 180
        return local.map { p in
            CGPoint(x: p.x * cos(angle) - p.y * sin(angle) + w / 2,
                    y: p.x * sin(angle) + p.y * cos(angle) + h / 2)
        }
    }

    /// 写真の周りに、左右・上下に折り返した写真をつないだ画像（範囲は各辺 padding 倍ずつ広い）。
    static func mirrorPadded(_ image: CIImage, padding: CGFloat) -> CIImage {
        let w = image.extent.width, h = image.extent.height
        // 各タイルは、端の色を外へ延ばした画像から自分の範囲だけを切り抜いて並べる。
        // 以前は写真をそのまま並べていたため、境目の 1 画素が「写真の端」と「外の透明」の中間になり、
        // 変形して拡大すると、つなぎ目に線が出ていた
        let source = image.clampedToExtent()
        var result = source.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        for ix in -1...1 {
            for iy in -1...1 where !(ix == 0 && iy == 0) {
                // x' = 2w - x（右）, -x（左）。y も同じ
                let sx: CGFloat = ix == 0 ? 1 : -1
                let sy: CGFloat = iy == 0 ? 1 : -1
                let tx: CGFloat = ix == 1 ? 2 * w : 0
                let ty: CGFloat = iy == 1 ? 2 * h : 0
                let rect = CGRect(x: CGFloat(ix) * w, y: CGFloat(iy) * h, width: w, height: h)
                let tile = source.transformed(by: CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: tx, ty: ty))
                    .cropped(to: rect)
                result = tile.composited(over: result)
            }
        }
        let rect = CGRect(x: -w * padding, y: -h * padding, width: w * (1 + 2 * padding), height: h * (1 + 2 * padding))
        return result.cropped(to: rect)
    }
}

/// 4 点の対応から求める射影変換（ホモグラフィー）。
struct Homography {
    private let m: [Double]  // h11 h12 h13 h21 h22 h23 h31 h32（h33 = 1）

    init?(from source: [CGPoint], to destination: [CGPoint]) {
        var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let x = Double(source[i].x), y = Double(source[i].y)
            let u = Double(destination[i].x), v = Double(destination[i].y)
            a[2 * i] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            a[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }
        // ガウスの消去法
        for col in 0..<8 {
            guard let pivot = (col..<8).max(by: { abs(a[$0][col]) < abs(a[$1][col]) }),
                  abs(a[pivot][col]) > 1e-12 else { return nil }
            a.swapAt(col, pivot)
            for row in 0..<8 where row != col {
                let factor = a[row][col] / a[col][col]
                for k in col..<9 { a[row][k] -= factor * a[col][k] }
            }
        }
        m = (0..<8).map { a[$0][8] / a[$0][$0] }
    }

    /// 点を移す。変形で無限遠の向こう（裏返る所）に行く点は nil
    func map(_ p: CGPoint) -> CGPoint? {
        let x = Double(p.x), y = Double(p.y)
        let w = m[6] * x + m[7] * y + 1
        guard w > 0.05 else { return nil }
        return CGPoint(x: (m[0] * x + m[1] * y + m[2]) / w, y: (m[3] * x + m[4] * y + m[5]) / w)
    }
}
