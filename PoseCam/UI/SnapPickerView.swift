import AVFoundation
import SwiftUI
import Vision

/// スナップ撮影の後に開く画面。撮った短い動画からコマを並べ、選んだコマを写真として保存する。
/// 顔の写りがよいコマ（Vision の顔の写り具合の評価）を「おすすめ」として最初から選んでおく。
struct SnapPickerView: View {
    let clip: SnapClip
    let onSaved: (UIImage?) -> Void

    @Environment(\.dismiss) private var dismiss

    struct SnapFrame: Identifiable {
        let id: Int
        let time: CMTime
        let image: UIImage
        let score: Float
    }

    @State private var frames: [SnapFrame] = []
    @State private var recommended: Set<Int> = []
    @State private var selected: Set<Int> = []
    @State private var current = 0
    @State private var preview: UIImage?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if isLoading {
                    ProgressView("コマを読み込んでいます…")
                        .frame(maxHeight: .infinity)
                } else if frames.isEmpty {
                    Text(errorMessage ?? "コマを読み込めませんでした")
                        .frame(maxHeight: .infinity)
                } else {
                    previewArea
                    Text("★ はおすすめ（顔がきれいに写っているコマ）。タップで表示、もう一度タップで選択／解除")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    frameStrip
                }
            }
            .padding(.bottom, 8)
            .navigationTitle("スナップから選ぶ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("破棄") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "保存中…" : "保存（\(selected.count)枚）") {
                        Task { await save() }
                    }
                    .disabled(selected.isEmpty || isSaving)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
        .onDisappear { try? FileManager.default.removeItem(at: clip.url) }
    }

    private var previewArea: some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: preview ?? frames[current].image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button {
                toggle(current)
            } label: {
                Image(systemName: selected.contains(current) ? "checkmark.circle.fill" : "circle")
                    .font(.largeTitle)
                    .foregroundStyle(selected.contains(current) ? Color.yellow : .white)
                    .shadow(radius: 3)
                    .padding(12)
            }
        }
    }

    private var frameStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    ForEach(frames) { frame in
                        Button {
                            if current == frame.id {
                                toggle(frame.id)
                            } else {
                                current = frame.id
                            }
                        } label: {
                            thumbnail(frame)
                        }
                        .id(frame.id)
                    }
                }
                .padding(.horizontal)
            }
            .frame(height: 100)
            .onChange(of: current) {
                withAnimation { proxy.scrollTo(current, anchor: .center) }
                Task { await loadPreview() }
            }
        }
    }

    private func thumbnail(_ frame: SnapFrame) -> some View {
        Image(uiImage: frame.image)
            .resizable()
            .scaledToFill()
            .frame(width: 54, height: 96)
            .clipped()
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(current == frame.id ? Color.white : .clear, lineWidth: 2))
            .overlay(alignment: .topLeading) {
                if recommended.contains(frame.id) {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .padding(3)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if selected.contains(frame.id) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .padding(3)
                }
            }
    }

    private func toggle(_ id: Int) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }

    // MARK: - 読み込み・採点

    private func load() async {
        let url = clip.url
        let loaded = await Task.detached(priority: .userInitiated) { () -> [SnapFrame] in
            await Self.extractFrames(url: url)
        }.value
        frames = loaded
        recommended = Self.pickRecommended(loaded, count: 3)
        selected = recommended
        current = recommended.min() ?? 0
        isLoading = false
        await loadPreview()
    }

    /// 1 秒に 8 コマ取り出し、それぞれの顔の写り具合を採点する。
    nonisolated private static func extractFrames(url: URL) async -> [SnapFrame] {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 360)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let seconds = duration.seconds
        let times = stride(from: 0.0, to: seconds, by: 1.0 / 8).map {
            CMTime(seconds: $0, preferredTimescale: 600)
        }
        var result: [SnapFrame] = []
        for await item in generator.images(for: times) {
            guard let cgImage = try? item.image else { continue }
            result.append(SnapFrame(id: result.count, time: item.requestedTime,
                                    image: UIImage(cgImage: cgImage), score: faceQuality(cgImage)))
        }
        return result
    }

    nonisolated private static func faceQuality(_ image: CGImage) -> Float {
        let request = VNDetectFaceCaptureQualityRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return request.results?.compactMap(\.faceCaptureQuality).max() ?? 0
    }

    /// 点数の高い順に、似たコマばかりにならないよう 4 コマ（0.5 秒）以上離して選ぶ。
    nonisolated private static func pickRecommended(_ frames: [SnapFrame], count: Int) -> Set<Int> {
        var picked: [Int] = []
        for frame in frames.sorted(by: { $0.score > $1.score }) where frame.score > 0 {
            if picked.allSatisfy({ abs($0 - frame.id) >= 4 }) {
                picked.append(frame.id)
            }
            if picked.count == count { break }
        }
        return Set(picked)
    }

    private func loadPreview() async {
        guard frames.indices.contains(current) else { return }
        let index = current
        preview = nil
        let image = await fullImage(at: frames[index].time, maxSide: 1200)
        if current == index { preview = image }
    }

    private func fullImage(at time: CMTime, maxSide: CGFloat?) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let maxSide { generator.maximumSize = CGSize(width: maxSide, height: maxSide) }
        guard let (cgImage, _) = try? await generator.image(at: time) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - 保存

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        var savedCount = 0
        var lastImage: UIImage?
        for id in selected.sorted() {
            guard let image = await fullImage(at: frames[id].time, maxSide: nil),
                  let data = image.jpegData(compressionQuality: 0.92) else { continue }
            let ok = await withCheckedContinuation { continuation in
                MediaSaver.savePhoto(data) { continuation.resume(returning: $0) }
            }
            if ok {
                savedCount += 1
                lastImage = image
            }
        }
        if savedCount > 0 {
            onSaved(lastImage)
            dismiss()
        } else {
            errorMessage = "保存できませんでした（写真へのアクセス許可を確認してください）"
        }
    }
}
