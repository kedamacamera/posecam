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
struct PoseImportEditor: View {
    let draft: PoseImportDraft
    /// カメラの画面の縦横比（幅 / 高さ）
    let aspect: CGFloat
    let onSave: (PoseShape) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var crop: CGRect = .zero
    @State private var dragStart: CGRect?
    @State private var pinchStart: CGRect?

    private var photoSize: CGSize { draft.analysis.size }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("ドラッグで位置、ピンチで大きさを合わせてください。黄色い枠の中がそのまま撮影画面になります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                GeometryReader { geo in
                    let frame = fittedFrame(in: geo.size)
                    editor(frame: frame)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
            .padding(.vertical, 8)
            .navigationTitle("構図を合わせる")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Button("自動") { resetCrop() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("登録") {
                        onSave(PoseImporter.shape(for: draft.analysis, crop: crop))
                        dismiss()
                    }
                    .disabled(crop.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { resetCrop() }
    }

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
                    let points = outline.map {
                        CGPoint(x: ($0.x * photoSize.width - crop.minX) * scale,
                                y: ($0.y * photoSize.height - crop.minY) * scale)
                    }
                    PoseDrawing.drawContour(points, in: context, color: .white, lineWidth: 2.5, fillOpacity: 0.12)
                }
            }
            .allowsHitTesting(false)
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .clipped()
        .overlay(Rectangle().stroke(Color.yellow, lineWidth: 2))
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    let start = dragStart ?? crop
                    dragStart = start
                    // 写真を右へ動かす = 枠を写真の左へ動かす
                    crop.origin = CGPoint(x: start.minX - value.translation.width / scale,
                                          y: start.minY - value.translation.height / scale)
                }
                .onEnded { _ in dragStart = nil }
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
                .onEnded { _ in pinchStart = nil }
        )
    }

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
}
