import SwiftUI

/// 脚長で伸ばす範囲の線（美肌・スタイルで「脚長」を選んでいるときだけ、プレビューに重ねる）。
/// ふだんは骨格から自動で決めた範囲（腰〜足首）を表示する。線の右の丸をドラッグすると、
/// 伸ばし始め・伸ばし終わりを手で決められる（「自動」を押すと骨格からの自動に戻る）。
/// 線は伸ばした後の映像の上での位置に描き、ドラッグした位置は元の映像の位置に直して保存する。
struct LegRangeOverlay: View {
    @ObservedObject var feed: PoseFeed
    @Binding var settings: ProcessingSettings

    /// 骨格も手の範囲もないときに表示・ドラッグの起点にする範囲
    private static let fallback = LegLayout(shoulder: 0.45, start: 0.5, end: 0.95, headTop: 0.45)

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let detected = LegLayout.make(pose: feed.detected, manual: settings.legRange)
            let layout = detected ?? Self.fallback
            let plan = layout.plan(height: height, amount: settings.legLength)
            let startY = plan.outputRow(layout.start * height)
            let endY = plan.outputRow(layout.end * height)

            ZStack(alignment: .topLeading) {
                // 伸ばす範囲をうっすら塗る
                Rectangle()
                    .fill(Color.yellow.opacity(0.08))
                    .frame(width: geo.size.width, height: max(0, endY - startY))
                    .offset(y: startY)
                    .allowsHitTesting(false)
                line(y: startY, width: geo.size.width, title: "伸ばし始め") { y in
                    let source = plan.sourceRow(y) / height
                    let low = layout.shoulder + 0.03
                    let start = min(max(source, low), layout.end - 0.08)
                    settings.legRange = Double(start)...Double(layout.end)
                }
                line(y: endY, width: geo.size.width, title: "伸ばし終わり") { y in
                    let source = plan.sourceRow(y) / height
                    let end = min(max(source, layout.start + 0.08), 1)
                    settings.legRange = Double(layout.start)...Double(end)
                }
                HStack(spacing: 8) {
                    Text(settings.legRange == nil ? (detected == nil ? "人が見つかりません" : "自動（腰〜足首）") : "手動")
                        .font(.caption2.weight(.semibold))
                    if settings.legRange != nil {
                        Button("自動に戻す") { settings.legRange = nil }
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.yellow)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .foregroundStyle(.white)
                .offset(x: 10, y: max(4, startY - 34))
            }
        }
    }

    /// 横の線と、右端のドラッグ用の丸。onDrag には指の位置（ビューの上端からの距離）を渡す
    private func line(y: CGFloat, width: CGFloat, title: String,
                      onDrag: @escaping (CGFloat) -> Void) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: width, y: y))
            }
            .stroke(Color.yellow, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .allowsHitTesting(false)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.yellow)
                .shadow(color: .black.opacity(0.7), radius: 2)
                .offset(x: width - 108, y: y - 16)
                .allowsHitTesting(false)
            Image(systemName: "arrow.up.and.down.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(Color.yellow, Color.black.opacity(0.6))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .offset(x: width - 50, y: y - 22)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("legRange"))
                        .onChanged { onDrag($0.location.y) }
                )
        }
        .coordinateSpace(name: "legRange")
    }
}

/// 選んだポーズの見本写真を、画面の左下に小さく表示する。タップで隠す・もう一度出す。
struct PoseSampleCard: View {
    let imageName: String
    let mirrored: Bool
    @Binding var shown: Bool

    var body: some View {
        if shown, let image = PoseImageCache.sample(named: imageName) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(x: mirrored ? -1 : 1, y: 1)
                .frame(width: 92)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.7), lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                        .padding(3)
                }
                .shadow(color: .black.opacity(0.4), radius: 3)
                .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { shown = false } }
        } else {
            Button { withAnimation(.easeOut(duration: 0.15)) { shown = true } } label: {
                Image(systemName: "photo")
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.45)))
            }
        }
    }
}
