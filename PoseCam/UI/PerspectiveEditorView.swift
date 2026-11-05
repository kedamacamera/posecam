import CoreImage
import ImageIO
import PhotosUI
import SwiftUI

/// 写真の傾き補正（射影変換）。Snapseed の「射影変換」と同じく、縦・横の傾き（台形のゆがみ）と回転を直し、
/// 直したことで画面の端にできるすき間を自動で埋める。
///
/// すき間の埋め方: 写真の外側に、写真を鏡に映したように折り返した画像をつないでから、写真と一緒に変形する。
/// 端の模様（空・壁・床・芝生など）がそのまま外へ続くので、黒い三角や引き伸ばした筋が出ない。
/// 人や物がすき間の近くにあると、折り返した形が見えることがある（そのときは「補完」を切って切り抜く）。
struct PerspectiveEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var pickerItem: PhotosPickerItem?
    @State private var source: CIImage?
    @State private var properties: [String: Any] = [:]
    @State private var preview: UIImage?
    @State private var vertical = 0.0
    @State private var horizontal = 0.0
    @State private var rotation = 0.0
    @State private var fill = true
    @State private var isSaving = false
    @State private var message: String?
    @State private var renderTask: Task<Void, Never>?

    private static let context = CIContext()

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ZStack {
                    Color.black
                    if let preview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                            .overlay(GridOverlay())
                    } else {
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Label("写真を選ぶ", systemImage: "photo")
                                .font(.headline)
                        }
                    }
                }
                .frame(maxHeight: .infinity)

                if source != nil {
                    VStack(spacing: 6) {
                        slider("縦", value: $vertical, range: -1...1)
                        slider("横", value: $horizontal, range: -1...1)
                        slider("回転", value: $rotation, range: -15...15)
                        Toggle("すき間を自動で埋める", isOn: $fill)
                            .font(.subheadline)
                    }
                    .padding(.horizontal)
                }
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom)
            .navigationTitle("傾き補正")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    if source != nil {
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Text("別の写真")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "保存中…" : "保存") { save() }
                        .disabled(source == nil || isSaving)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: pickerItem) { load() }
        .onChange(of: vertical) { schedulePreview() }
        .onChange(of: horizontal) { schedulePreview() }
        .onChange(of: rotation) { schedulePreview() }
        .onChange(of: fill) { schedulePreview() }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 32, alignment: .leading)
            Slider(value: value, in: range).tint(.yellow)
            Button {
                value.wrappedValue = 0
            } label: {
                Image(systemName: "arrow.counterclockwise").font(.caption)
            }
        }
    }

    private func load() {
        guard let item = pickerItem else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
                message = "写真を読み込めませんでした"
                return
            }
            let props = CGImageSourceCreateWithData(data as CFData, nil)
                .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] } ?? [:]
            source = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            properties = props
            vertical = 0
            horizontal = 0
            rotation = 0
            message = nil
            schedulePreview()
        }
    }

    private func schedulePreview() {
        guard let source else { return }
        renderTask?.cancel()
        let parameters = Perspective(vertical: vertical, horizontal: horizontal, rotationDegrees: rotation)
        let fill = self.fill
        renderTask = Task.detached(priority: .userInitiated) {
            // 画面用は長辺 1200 ピクセルに縮めて計算する
            let scale = min(1, 1200 / max(source.extent.width, source.extent.height))
            let small = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let output = parameters.apply(to: small, fill: fill)
            guard !Task.isCancelled,
                  let cgImage = Self.context.createCGImage(output, from: output.extent) else { return }
            let image = UIImage(cgImage: cgImage)
            await MainActor.run { if !Task.isCancelled { preview = image } }
        }
    }

    private func save() {
        guard let source else { return }
        isSaving = true
        let parameters = Perspective(vertical: vertical, horizontal: horizontal, rotationDegrees: rotation)
        let fill = self.fill
        let properties = self.properties
        Task.detached(priority: .userInitiated) {
            let output = parameters.apply(to: source, fill: fill)
            let jpeg = PhotoMetadata.jpeg(output, metadata: properties, context: Self.context)
            guard let jpeg else {
                await MainActor.run { isSaving = false; message = "保存できませんでした" }
                return
            }
            MediaSaver.savePhoto(jpeg) { ok in
                DispatchQueue.main.async {
                    isSaving = false
                    message = ok ? "写真に保存しました（元の写真はそのまま残っています）" : "保存できませんでした（写真へのアクセス許可を確認してください）"
                }
            }
        }
    }
}

/// 射影変換の設定。vertical / horizontal は -1...1（端の長さを最大 ±30% 変える）、回転は度。
struct Perspective {
    var vertical: Double
    var horizontal: Double
    var rotationDegrees: Double

    /// image は原点が (0, 0)。出力は元と同じ大きさ。
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
        let warped = image.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputBottomLeft": CIVector(cgPoint: corners[0]),
            "inputBottomRight": CIVector(cgPoint: corners[1]),
            "inputTopLeft": CIVector(cgPoint: corners[2]),
            "inputTopRight": CIVector(cgPoint: corners[3]),
        ])
        return warped.composited(over: CIImage(color: .black).cropped(to: target)).cropped(to: target)
    }

    /// 変形後の四隅（左下・右下・左上・右上）。中心はそのままで、台形にしてから回転する。
    private func destinationCorners(width w: CGFloat, height h: CGFloat) -> [CGPoint] {
        let v = CGFloat(vertical) * 0.3, s = CGFloat(horizontal) * 0.3
        // 縦: 上の辺を広げ下の辺を縮める（正の値で、上すぼまりのビルをまっすぐにする向き）
        // 横: 左の辺を伸ばし右の辺を縮める
        let local = [
            CGPoint(x: -w / 2 * (1 - v), y: -h / 2 * (1 + s)),
            CGPoint(x: w / 2 * (1 - v), y: -h / 2 * (1 - s)),
            CGPoint(x: -w / 2 * (1 + v), y: h / 2 * (1 + s)),
            CGPoint(x: w / 2 * (1 + v), y: h / 2 * (1 - s)),
        ]
        let angle = CGFloat(rotationDegrees) * .pi / 180
        return local.map { p in
            CGPoint(x: p.x * cos(angle) - p.y * sin(angle) + w / 2,
                    y: p.x * sin(angle) + p.y * cos(angle) + h / 2)
        }
    }

    /// 写真の周りに、左右・上下に折り返した写真をつないだ画像（範囲は各辺 padding 倍ずつ広い）。
    static func mirrorPadded(_ image: CIImage, padding: CGFloat) -> CIImage {
        let w = image.extent.width, h = image.extent.height
        var result = image
        for ix in -1...1 {
            for iy in -1...1 where !(ix == 0 && iy == 0) {
                // x' = 2w - x（右）, -x（左）。y も同じ
                let sx: CGFloat = ix == 0 ? 1 : -1
                let sy: CGFloat = iy == 0 ? 1 : -1
                let tx: CGFloat = ix == 1 ? 2 * w : 0
                let ty: CGFloat = iy == 1 ? 2 * h : 0
                let tile = image.transformed(by: CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: tx, ty: ty))
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
