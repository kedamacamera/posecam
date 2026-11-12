import SwiftUI
import CoreImage

// MARK: - 撮影画面のボタンの見た目

/// 撮影画面のボタンの見た目。iOS 標準の見た目（.automatic）だと、端末の
/// 「ボタンの形」がオンのときにすべてのボタンへ灰色の枠が付き、撮影画面が崩れていた。
/// 自前の見た目にして枠を付けない（押している間は少し薄くする）。
/// 撮影画面のボタンは中で色を決めているので、色はボタンの側では変えない
struct CameraButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.6 : 1)
    }
}

extension View {
    /// 撮影画面の文字・ボタンを、端末の表示の設定（ボタンの形・文字を太くする・文字の大きさ）で崩さない。
    /// 撮影画面はボタンを詰めて並べているので、どれかが大きくなると折り返したり重なったりしていた
    func cameraChromeLayout() -> some View {
        self
            .buttonStyle(CameraButtonStyle())
            .environment(\.legibilityWeight, .regular)
            .dynamicTypeSize(.large)
    }
}

// MARK: - 上部のバー

/// アイコンの下に短い説明を付けたボタン（意味が分かるように必ず文字を添える）。
struct LabeledIconButton: View {
    let systemImage: String
    let label: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LabeledIcon(systemImage: systemImage, label: label, active: active)
        }
    }
}

struct LabeledIcon: View {
    /// iPad は画面が大きく押しにくかったので、ボタンを大きくする
    static let scale: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 1.25 : 1
    let systemImage: String
    let label: String
    var active = false

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: systemImage)
                .font(.system(size: 19 * Self.scale))
                .frame(height: 24 * Self.scale)
            Text(label)
                .font(.system(size: 10 * Self.scale, weight: .medium))
                .lineLimit(1)
                .fixedSize()
        }
        // 押せる所を、絵と文字だけでなくボタンの枠全体にする（iPad は大きく）
        .frame(minWidth: 48 * Self.scale, minHeight: 44 * Self.scale)
        .contentShape(Rectangle())
        .foregroundStyle(active ? Color.chromeAccent : .chromeText)
        .shadow(color: .chromeShadow, radius: 2)
    }
}

/// 比率ボタン。タップすると比率を選ぶメニューを出す。アイコンの代わりに「3:4」などの文字を枠で囲んで表示する。
struct AspectMenu: View {
    @Binding var aspect: AspectOption

    var body: some View {
        Menu {
            Picker("比率", selection: $aspect) {
                ForEach(AspectOption.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
        } label: {
            VStack(spacing: 2) {
                Text(aspect.rawValue)
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 4)
                    .frame(height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.chromeText, lineWidth: 1.5))
                    .frame(height: 24)
                Text("比率")
                    .font(.system(size: 10, weight: .medium))
            }
            .frame(minWidth: 48)
            .foregroundStyle(Color.chromeText)
            .shadow(color: .chromeShadow, radius: 2)
        }
    }
}

/// シャッターが切れた瞬間に画面を一瞬暗くして、すぐ戻す（無音でも撮れたことが分かるように）。
struct ShutterBlackout: View {
    let trigger: Int
    @State private var opacity = 0.0

    var body: some View {
        Color.black
            .opacity(opacity)
            .allowsHitTesting(false)
            .onChange(of: trigger) {
                opacity = 0.85
                withAnimation(.easeOut(duration: 0.3)) { opacity = 0 }
            }
    }
}

// MARK: - ポーズの操作（右側の縦並び）

struct PoseSideBar: View {
    @Binding var opacity: Double
    @Binding var mirrored: Bool
    @Binding var autoShutter: Bool
    let recommendedZoom: Double?
    let canAutoShutter: Bool
    let onClear: () -> Void
    let onApplyZoom: (Double) -> Void

    @State private var showOpacity = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if showOpacity {
                VerticalSlider(value: $opacity, range: 0.15...1)
                    .frame(width: 36, height: 180)
                    .background(Capsule().fill(Color.black.opacity(0.45)))
                    .transition(.opacity)
            }
            VStack(spacing: 12) {
                sideButton("xmark", "解除", active: false, action: onClear)
                sideButton("arrow.left.and.right.righttriangle.left.righttriangle.right", "左右反転",
                           active: mirrored) { mirrored.toggle() }
                sideButton("circle.lefthalf.filled", "濃さ", active: showOpacity) {
                    withAnimation(.easeOut(duration: 0.15)) { showOpacity.toggle() }
                }
                if let zoom = recommendedZoom {
                    Button { onApplyZoom(zoom) } label: {
                        VStack(spacing: 2) {
                            Text(ZoomFormat.short(CGFloat(zoom)) + "×")
                                .font(.system(size: 13, weight: .bold))
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(Color.black.opacity(0.5)))
                            Text("推奨倍率")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(.white)
                    }
                }
                sideButton("camera.viewfinder", "自動撮影", active: autoShutter) {
                    autoShutter.toggle()
                }
                .disabled(!canAutoShutter)
                .opacity(canAutoShutter ? 1 : 0.4)
            }
        }
    }

    private func sideButton(_ systemImage: String, _ label: String, active: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 18))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.black.opacity(0.5)))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(active ? Color.yellow : .white)
            .shadow(color: .black.opacity(0.5), radius: 2)
        }
    }
}

/// 縦向きのスライダー（上が 1）。
struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height - 24
            let ratio = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.white.opacity(0.3)).frame(width: 4)
                Capsule().fill(Color.yellow).frame(width: 4, height: height * ratio)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 12)
            .overlay(alignment: .top) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 18, height: 18)
                    .offset(y: 12 + height * (1 - ratio) - 9)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let t = 1 - min(max((drag.location.y - 12) / height, 0), 1)
                value = range.lowerBound + t * (range.upperBound - range.lowerBound)
            })
        }
    }
}

// MARK: - レンズ・ズーム

enum ZoomFormat {
    /// 0.5 → ".5"、1 → "1"、2.3 → "2.3"（標準カメラと同じ書き方）
    static func short(_ value: CGFloat) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded < 1 { return String(format: ".%d", Int((rounded * 10).rounded())) }
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }
}

/// 倍率ボタン（0.5 / 1 / 2 / 5 など）。
/// 標準カメラと同じく、タップでその倍率に切り替え、長押ししたまま左右に動かすと細かくズームする。
/// 指を離した後もしばらく目盛りが残り、目盛りを左右に動かして続けて調整できる。
struct LensBar: View {
    let options: [LensOption]
    let zoom: CGFloat
    let minZoom: CGFloat
    let maxZoom: CGFloat
    let activeLens: String?
    let onSelect: (CGFloat) -> Void
    let onZoom: (CGFloat) -> Void

    @State private var showRuler = false
    @State private var dragStartZoom: CGFloat?
    @State private var hideTask: Task<Void, Never>?

    /// 指を何ポイント動かすと倍率が e 倍になるか
    static let pointsPerE: CGFloat = 140
    /// 倍率ボタンの大きさの倍率（iPad は大きく）
    static let scale: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 1.35 : 1

    /// いま使っているボタン（現在の倍率以下でいちばん大きいもの）
    private var activeFactor: CGFloat? {
        options.map(\.displayFactor).filter { $0 <= zoom + 0.01 }.max()
    }

    var body: some View {
        VStack(spacing: 6) {
            if showRuler {
                ZoomRuler(zoom: zoom, minZoom: minZoom, maxZoom: maxZoom,
                          lensFactors: options.map(\.displayFactor))
                    .frame(height: 64)
                    .contentShape(Rectangle())
                    .gesture(dragGesture)
                    .transition(.opacity)
            }
            // 倍率ボタンは同じ大きさの丸を 1 本の帯にまとめる（選んだ丸だけ大きくすると、帯の外へはみ出していた）。
            // いま使っているレンズの名前は、帯の左に楕円で囲んで並べる。帯が画面の中央に来るよう、
            // 右にも同じ幅の透明な名前を置く（以前は重ねて置いていて、倍率ボタンと重なっていた）
            HStack(spacing: 8) {
                lensLabel
                buttons
                lensLabel.hidden()
            }
        }
    }

    @ViewBuilder private var lensLabel: some View {
        if let activeLens {
            Text(activeLens)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.45)))
                .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 0.8))
                .allowsHitTesting(false)
        }
    }

    private var buttons: some View {
        HStack(spacing: 4) {
            ForEach(options) { option in
                let active = option.displayFactor == activeFactor
                Text(active ? ZoomFormat.short(zoom) + "×" : ZoomFormat.short(option.displayFactor))
                    .font(.system(size: (active ? 12 : 11) * Self.scale, weight: .bold))
                    .foregroundStyle(active ? Color.yellow : .white)
                    // iPad は画面が大きく押しにくかったので、丸を大きくする
                    .frame(width: 34 * Self.scale, height: 34 * Self.scale)
                    .background(Circle().fill(Color.white.opacity(active ? 0.18 : 0)))
                    .contentShape(Circle())
                    .onTapGesture { onSelect(option.displayFactor) }
                    .gesture(
                        LongPressGesture(minimumDuration: 0.3)
                            .onEnded { _ in
                                withAnimation(.easeOut(duration: 0.15)) { showRuler = true }
                                hideTask?.cancel()
                            }
                            .sequenced(before: dragGesture)
                    )
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.black.opacity(0.45)))
    }

    /// 左へ動かすと拡大、右へ動かすと縮小（標準カメラと同じ向き）。
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                withAnimation(.easeOut(duration: 0.15)) { showRuler = true }
                hideTask?.cancel()
                let start = dragStartZoom ?? zoom
                dragStartZoom = start
                let next = start * exp(-value.translation.width / Self.pointsPerE)
                onZoom(min(max(next, minZoom), maxZoom))
            }
            .onEnded { _ in
                dragStartZoom = nil
                scheduleHide()
            }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { showRuler = false }
        }
    }
}

/// 標準カメラのような目盛り。中央の黄色い線が現在の倍率で、目盛りは対数で並ぶ。
struct ZoomRuler: View {
    let zoom: CGFloat
    let minZoom: CGFloat
    let maxZoom: CGFloat
    let lensFactors: [CGFloat]

    var body: some View {
        Canvas { context, size in
            let center = size.width / 2
            let baseline = size.height - 8
            func x(_ value: CGFloat) -> CGFloat {
                center + (log(value) - log(zoom)) * LensBar.pointsPerE
            }

            // 細かい目盛り
            var value = minZoom
            while value <= maxZoom + 0.001 {
                let px = x(value)
                if px > -10 && px < size.width + 10 {
                    var tick = Path()
                    tick.move(to: CGPoint(x: px, y: baseline - 8))
                    tick.addLine(to: CGPoint(x: px, y: baseline))
                    context.stroke(tick, with: .color(.white.opacity(0.6)), lineWidth: 1)
                }
                value *= 1.04
            }

            // レンズの倍率と大きな倍率には数字を付ける
            let labels = Array(Set(lensFactors + [10, 15].filter { $0 <= maxZoom }))
            for factor in labels {
                let px = x(factor)
                guard px > -20 && px < size.width + 20 else { continue }
                var tick = Path()
                tick.move(to: CGPoint(x: px, y: baseline - 14))
                tick.addLine(to: CGPoint(x: px, y: baseline))
                context.stroke(tick, with: .color(.white), lineWidth: 2)
                context.draw(Text(ZoomFormat.short(factor)).font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white),
                             at: CGPoint(x: px, y: baseline - 24))
            }

            // 現在の倍率
            var needle = Path()
            needle.move(to: CGPoint(x: center, y: baseline - 20))
            needle.addLine(to: CGPoint(x: center, y: baseline + 4))
            context.stroke(needle, with: .color(.yellow), lineWidth: 2)
            context.draw(Text(ZoomFormat.short(zoom) + "×").font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.yellow),
                         at: CGPoint(x: center, y: 8))
        }
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.5), .black.opacity(0.5), .clear],
                           startPoint: .leading, endPoint: .trailing)
        )
    }
}
// MARK: - パネル（ポーズ・フィルター・美肌）

enum ControlPanel: String, CaseIterable, Identifiable {
    case pose = "ポーズ"
    case filter = "フィルター"
    case beauty = "美肌・スタイル"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .pose: return "figure.stand"
        case .filter: return "camera.filters"
        case .beauty: return "sparkles"
        }
    }
}

/// パネルの開閉ボタン。押したパネルだけ開き、もう一度押すと閉じる。
struct PanelChips: View {
    @Binding var panel: ControlPanel?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ControlPanel.allCases) { item in
                let active = panel == item
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { panel = active ? nil : item }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: item.systemImage)
                        Text(item.rawValue)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Image(systemName: active ? "chevron.down" : "chevron.up")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(active ? Color.white : Color.black.opacity(0.45)))
                    .foregroundStyle(active ? Color.black : .white)
                }
            }
        }
    }
}

struct FilterStrip: View {
    @Binding var selection: PhotoFilter
    @Binding var strength: Double
    @Environment(\.suppressPanelTaps) private var suppressTaps

    var body: some View {
        VStack(spacing: 8) {
            StrengthSlider(value: $strength, standard: PhotoFilter.standardStrength, maximum: PhotoFilter.maxStrength)
                .padding(.horizontal)
                .opacity(selection == .none ? 0.35 : 1)
                .disabled(selection == .none)
            thumbnails
        }
    }

    private var thumbnails: some View {
        ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(PhotoFilter.allCases) { filter in
                    Button {
                        guard !suppressTaps else { return }
                        selection = filter
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(filter, anchor: .center) }
                    } label: {
                        VStack(spacing: 6) {
                            Group {
                                if let image = FilterThumbnails.image(for: filter) {
                                    Image(uiImage: image).resizable().scaledToFill()
                                } else {
                                    Color.gray
                                }
                            }
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(selection == filter ? Color.yellow : .clear, lineWidth: 3))
                            Text(filter.displayName)
                                .font(.caption2)
                                .lineLimit(1)
                                .fixedSize()
                                .foregroundStyle(selection == filter ? Color.yellow : .white)
                        }
                    }
                    .id(filter)
                }
            }
            .padding(.horizontal)
        }
        // パネルを閉じて開き直しても、使っているフィルターが中央に来るようにする
        .onAppear { proxy.scrollTo(selection, anchor: .center) }
        }
    }
}

/// フィルターの濃さ。標準（100%）の所に点があり、近くまで動かすと磁石のように吸い付く（軽い振動つき）。
/// 最大（200%）は標準の 2 倍の濃さ。
struct StrengthSlider: View {
    @Binding var value: Double
    let standard: Double
    let maximum: Double
    /// この範囲（全体に対する割合）まで近づいたら標準に吸い付く
    private let snapRange = 0.04

    var body: some View {
        HStack(spacing: 10) {
            Text("濃さ")
                .font(.caption.weight(.semibold))
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.3)).frame(height: 4)
                    Capsule().fill(Color.yellow).frame(width: width * value / maximum, height: 4)
                    // 標準の位置の点
                    Circle()
                        .fill(abs(value - standard) < 0.001 ? Color.yellow : .white)
                        .frame(width: 7, height: 7)
                        .offset(x: width * standard / maximum - 3.5)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 20, height: 20)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .offset(x: width * value / maximum - 10)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    var next = min(max(drag.location.x / width, 0), 1) * maximum
                    if abs(next - standard) < snapRange * maximum { next = standard }
                    if next == standard && value != standard {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    value = next
                })
            }
            .frame(height: 24)
            Text("\(Int((value * 100).rounded()))")
                .font(.caption.monospacedDigit())
                .frame(width: 34, alignment: .trailing)
        }
        .foregroundStyle(.white)
    }
}

/// 構図のガイドの線の種類。
enum GridStyle: String, CaseIterable, Identifiable {
    case off, thirds, thirdsDiagonal, halves, halvesDiagonal, center, radial, golden, phiGrid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "なし"
        case .thirds: return "3分割"
        case .thirdsDiagonal: return "3分割＋斜線"
        case .halves: return "2分割"
        case .halvesDiagonal: return "2分割＋斜線"
        case .center: return "日の丸"
        case .radial: return "放射線"
        case .golden: return "黄金比（螺旋）"
        case .phiGrid: return "黄金分割"
        }
    }

    /// 線の形（size の中の座標）
    func path(in size: CGSize) -> Path {
        let w = size.width, h = size.height
        var path = Path()
        func line(_ a: CGPoint, _ b: CGPoint) { path.move(to: a); path.addLine(to: b) }
        func vertical(_ x: CGFloat) { line(CGPoint(x: x, y: 0), CGPoint(x: x, y: h)) }
        func horizontal(_ y: CGFloat) { line(CGPoint(x: 0, y: y), CGPoint(x: w, y: y)) }
        func diagonals() {
            line(.zero, CGPoint(x: w, y: h))
            line(CGPoint(x: w, y: 0), CGPoint(x: 0, y: h))
        }
        switch self {
        case .off:
            break
        case .thirds, .thirdsDiagonal:
            for i in 1...2 {
                vertical(w * CGFloat(i) / 3)
                horizontal(h * CGFloat(i) / 3)
            }
            if self == .thirdsDiagonal { diagonals() }
        case .halves, .halvesDiagonal:
            vertical(w / 2)
            horizontal(h / 2)
            if self == .halvesDiagonal { diagonals() }
        case .center:
            let r = min(w, h) * 0.16
            path.addEllipse(in: CGRect(x: w / 2 - r, y: h / 2 - r, width: r * 2, height: r * 2))
            line(CGPoint(x: w / 2 - r * 0.35, y: h / 2), CGPoint(x: w / 2 + r * 0.35, y: h / 2))
            line(CGPoint(x: w / 2, y: h / 2 - r * 0.35), CGPoint(x: w / 2, y: h / 2 + r * 0.35))
        case .radial:
            // 中心から四隅と各辺の 1/4・1/2・3/4 へ広がる線（奥行き・動きを出す放射線構図）
            let c = CGPoint(x: w / 2, y: h / 2)
            for t in [0, 0.25, 0.5, 0.75, 1] as [CGFloat] {
                line(c, CGPoint(x: w * t, y: 0))
                line(c, CGPoint(x: w * t, y: h))
                if t > 0 && t < 1 {
                    line(c, CGPoint(x: 0, y: h * t))
                    line(c, CGPoint(x: w, y: h * t))
                }
            }
        case .golden:
            Self.addGoldenSpiral(to: &path, size: size)
        case .phiGrid:
            let phi: CGFloat = 0.382
            vertical(w * phi); vertical(w * (1 - phi))
            horizontal(h * phi); horizontal(h * (1 - phi))
        }
        return path
    }

    /// 黄金螺旋（フィボナッチの正方形と、それをつなぐ 4 分の 1 円）。縦長の画面では縦向きにして、画面いっぱいに広げる。
    private static func addGoldenSpiral(to path: inout Path, size: CGSize) {
        let phi: CGFloat = (1 + sqrt(5)) / 2
        // 横 φ・縦 1 の黄金長方形の中で作る
        var rect = CGRect(x: 0, y: 0, width: phi, height: 1)
        let landscape = size.width >= size.height
        func map(_ p: CGPoint) -> CGPoint {
            landscape ? CGPoint(x: p.x / phi * size.width, y: p.y * size.height)
                      : CGPoint(x: p.y * size.width, y: p.x / phi * size.height)
        }
        func square(_ r: CGRect) {
            let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                           CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map(map)
            path.move(to: corners[0])
            for c in corners.dropFirst() { path.addLine(to: c) }
            path.closeSubpath()
        }
        func arc(center: CGPoint, radius: CGFloat, from a0: CGFloat, to a1: CGFloat) {
            for i in 0...24 {
                let a = (a0 + (a1 - a0) * CGFloat(i) / 24) * .pi / 180
                let p = map(CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a)))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
        }
        for step in 0..<10 {
            switch step % 4 {
            case 0:  // 左に正方形
                let s = rect.height
                square(CGRect(x: rect.minX, y: rect.minY, width: s, height: s))
                arc(center: CGPoint(x: rect.minX + s, y: rect.minY + s), radius: s, from: 180, to: 270)
                rect = CGRect(x: rect.minX + s, y: rect.minY, width: rect.width - s, height: rect.height)
            case 1:  // 上に正方形
                let s = rect.width
                square(CGRect(x: rect.minX, y: rect.minY, width: s, height: s))
                arc(center: CGPoint(x: rect.minX, y: rect.minY + s), radius: s, from: 270, to: 360)
                rect = CGRect(x: rect.minX, y: rect.minY + s, width: rect.width, height: rect.height - s)
            case 2:  // 右に正方形
                let s = rect.height
                square(CGRect(x: rect.maxX - s, y: rect.minY, width: s, height: s))
                arc(center: CGPoint(x: rect.maxX - s, y: rect.minY), radius: s, from: 0, to: 90)
                rect = CGRect(x: rect.minX, y: rect.minY, width: rect.width - s, height: rect.height)
            default:  // 下に正方形
                let s = rect.width
                square(CGRect(x: rect.minX, y: rect.maxY - s, width: s, height: s))
                arc(center: CGPoint(x: rect.maxX, y: rect.maxY - s), radius: s, from: 90, to: 180)
                rect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - s)
            }
        }
    }

    /// メニューに並べる小さな図（縦長の枠と線）
    @MainActor
    var icon: UIImage {
        let size = CGSize(width: 21, height: 28)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let cg = context.cgContext
            cg.setStrokeColor(UIColor.black.cgColor)
            cg.setLineWidth(1.4)
            cg.stroke(CGRect(origin: .zero, size: size).insetBy(dx: 0.7, dy: 0.7))
            cg.setLineWidth(0.9)
            cg.addPath(path(in: size).cgPath)
            cg.strokePath()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }
}

/// 構図のガイドの線。
struct GridOverlay: View {
    var style: GridStyle = .thirds

    var body: some View {
        Canvas { context, size in
            let path = style.path(in: size)
            context.stroke(path, with: .color(.black.opacity(0.3)), lineWidth: 2)
            context.stroke(path, with: .color(.white.opacity(0.7)), lineWidth: 0.8)
        }
        .allowsHitTesting(false)
    }
}

/// 上のバーのグリッドのボタン。押すと線の種類を、名前の横の図と一緒に選べる。
struct GridMenu: View {
    @Binding var style: GridStyle

    var body: some View {
        Menu {
            ForEach(GridStyle.allCases) { item in
                Button {
                    style = item
                } label: {
                    Label {
                        Text(item == style ? "\(item.title) ✓" : item.title)
                    } icon: {
                        Image(uiImage: item.icon)
                    }
                }
            }
        } label: {
            LabeledIcon(systemImage: "squareshape.split.3x3",
                        label: style == .off ? "グリッド" : style.title, active: style != .off)
        }
    }
}

/// フィルターの見本（同梱の見本写真に、そのフィルターをかけた小さな画像）。メインスレッドから使う。
/// 人向けのフィルターは人物の上半身、料理向け（フード）・カフェ向け（カフェ）は料理・ドリンクの見本写真で見せる。
enum FilterThumbnails {
    private static let context = CIContext()
    private static var cache: [PhotoFilter: UIImage] = [:]
    private static var sources: [String: CIImage] = [:]

    /// そのフィルターで撮るものの見本写真
    private static func source(for filter: PhotoFilter) -> CIImage? {
        switch filter {
        case .food: return square(named: "s_145", top: 0.3)      // フレンチトースト
        case .cafe: return square(named: "s_135", top: 0.25)     // 抹茶ラテ
        default: return square(named: "pose_00", top: 0.04, width: 0.8)
        }
    }

    /// 見本写真を正方形に切り抜いて 112 ピクセルに縮める。top: 上から切り抜き始める位置（高さに対する割合）、
    /// width: 切り抜く幅（横幅に対する割合）
    private static func square(named name: String, top: CGFloat, width: CGFloat = 1) -> CIImage? {
        if let cached = sources[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg"),
              let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        let e = image.extent
        let side = min(e.width * width, e.height)
        let y = max(e.minY, e.maxY - side - e.height * top)
        let crop = CGRect(x: e.minX + (e.width - side) / 2, y: y, width: side, height: side)
        let scale = 112 / side
        let result = image.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        sources[name] = result
        return result
    }

    static func image(for filter: PhotoFilter) -> UIImage? {
        if let cached = cache[filter] { return cached }
        guard let source = source(for: filter) else { return nil }
        var output = filter.apply(to: source)
        if filter.needsPersonMask,
           let person = PoseDetector().analyze(ciImage: source, wantsMasks: false, wantsPerson: true).masks?.person {
            output = PhotoFilter.colorKeep(source, person: FrameProcessor.gray(person),
                                           strength: PhotoFilter.standardStrength)
        }
        guard let cgImage = context.createCGImage(output, from: source.extent) else { return nil }
        let image = UIImage(cgImage: cgImage)
        cache[filter] = image
        return image
    }
}

/// 美肌・スタイルの項目。BeautyCam と同じく、項目を選んでから 1 本のスライダーで強さを決める。
/// 項目を増やすときは、ここに 1 行足して ProcessingSettings に値を追加する。
enum BeautyItem: String, CaseIterable, Identifiable {
    case smoothing = "美肌"
    case brightening = "美白"
    case redness = "赤み"
    case blemish = "シミ"
    case wrinkle = "シワ"
    case beard = "青ひげ"
    case contour = "輪郭"
    case legLength = "脚長"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .smoothing: return "sparkles"
        case .brightening: return "sun.max"
        case .redness: return "drop"
        case .blemish: return "circle.dotted"
        case .wrinkle: return "water.waves"
        case .beard: return "mustache"
        case .contour: return "face.smiling"
        case .legLength: return "arrow.up.and.down"
        }
    }

    var keyPath: WritableKeyPath<ProcessingSettings, Double> {
        switch self {
        case .smoothing: return \.smoothing
        case .brightening: return \.brightening
        case .redness: return \.redness
        case .blemish: return \.blemish
        case .wrinkle: return \.wrinkle
        case .beard: return \.beard
        case .contour: return \.contour
        case .legLength: return \.legLength
        }
    }
}

struct BeautyPanel: View {
    @Binding var settings: ProcessingSettings
    /// 押している間だけ、美肌・スタイルの加工を外した映像にする（比べるため。フィルターは残す）
    @Binding var showOriginal: Bool
    @Binding var selected: BeautyItem

    var body: some View {
        VStack(spacing: 10) {
            // 選んでいる項目のスライダーと、押している間だけ加工前に戻すボタン
            HStack(spacing: 12) {
                Text(selected.rawValue)
                    .font(.caption.weight(.semibold))
                    .frame(width: 36, alignment: .leading)
                Slider(value: $settings[dynamicMember: selected.keyPath], in: 0...1)
                    .tint(.yellow)
                Text("\(Int(settings[keyPath: selected.keyPath] * 100))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 28, alignment: .trailing)
                Image(systemName: "square.split.2x1")
                    .font(.system(size: 18))
                    .foregroundStyle(showOriginal ? Color.yellow : .white)
                    .frame(width: 36, height: 30)
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 0, pressing: { pressing in
                        showOriginal = pressing
                    }, perform: {})
            }
            .foregroundStyle(.white)
            .padding(.horizontal)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        Button {
                            settings = ProcessingSettings(filter: settings.filter, filterStrength: settings.filterStrength)
                        } label: {
                            itemLabel(systemImage: "arrow.counterclockwise", title: "リセット", active: false, value: nil)
                        }
                        ForEach(BeautyItem.allCases) { item in
                            Button { selected = item } label: {
                                itemLabel(systemImage: item.systemImage, title: item.rawValue,
                                          active: selected == item, value: settings[keyPath: item.keyPath])
                            }
                            .id(item)
                        }
                    }
                    .padding(.horizontal)
                }
                // 開き直したとき、選んでいた項目が見えるようにする
                .onAppear { proxy.scrollTo(selected, anchor: .center) }
            }
        }
    }

    /// 丸いアイコンと名前。値が 0 でなければアイコンの右上に小さな点を付けて、かかっている項目が分かるようにする
    private func itemLabel(systemImage: String, title: String, active: Bool, value: Double?) -> some View {
        VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 19))
                .frame(width: 50, height: 50)
                .background(Circle().fill(Color.white.opacity(active ? 0.25 : 0.12)))
                .overlay(Circle().stroke(active ? Color.yellow : .clear, lineWidth: 2))
                .overlay(alignment: .topTrailing) {
                    if let value, value > 0.01 {
                        Circle().fill(Color.yellow).frame(width: 7, height: 7).offset(x: -3, y: 3)
                    }
                }
            Text(title)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(active ? Color.yellow : .white)
    }
}
struct SliderRow: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        HStack {
            Text(title)
                .font(.caption)
                .frame(width: 36, alignment: .leading)
            Slider(value: $value, in: 0...1)
                .tint(.yellow)
            Text("\(Int(value * 100))")
                .font(.caption.monospacedDigit())
                .frame(width: 30, alignment: .trailing)
        }
        .foregroundStyle(.white)
    }
}

// MARK: - 下部

struct ModePicker: View {
    let mode: CaptureMode
    let isLocked: Bool
    let onSelect: (CaptureMode) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(CaptureMode.allCases) { item in
                Button { onSelect(item) } label: {
                    Text(item.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(item == mode ? Color.chromeAccent : Color.chromeText.opacity(0.75))
                        .shadow(color: .chromeShadow, radius: 2)
                        // 文字だけだと押せる所が狭く、少し外れた指は後ろの映像（ピント）が取っていた。
                        // ボタンそのものを大きくする
                        .frame(minWidth: 60, minHeight: 40)
                        .contentShape(Rectangle())
                }
                .disabled(isLocked)
            }
        }
    }
}

/// シャッター。写真モードでは 1 秒長押しすると動画を撮り始め、離すと止まる（最長 10 秒）。
struct ShutterButton: View {
    let mode: CaptureMode
    let isRecording: Bool
    let isBusy: Bool
    /// スナップ・長押しの動画の進み具合（0...1）
    let progress: Double
    let action: () -> Void
    var onLongPressStart: (() -> Void)? = nil
    var onLongPressEnd: (() -> Void)? = nil

    @State private var isPressing = false
    @State private var longPressFired = false
    @State private var pendingLongPress: DispatchWorkItem?

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.chromeText, lineWidth: 4)
                .frame(width: 74, height: 74)
            if (mode == .snap || mode == .photo) && isRecording {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(mode == .photo ? Color.red : Color.yellow,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 74, height: 74)
            }
            switch mode {
            case .photo:
                if isRecording {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red)
                        .frame(width: 30, height: 30)
                } else {
                    Circle()
                        .fill(Color.white.opacity(isBusy || isPressing ? 0.6 : 1))
                        .frame(width: 60, height: 60)
                }
            case .video:
                RoundedRectangle(cornerRadius: isRecording ? 6 : 30)
                    .fill(Color.red)
                    .frame(width: isRecording ? 30 : 60, height: isRecording ? 30 : 60)
            case .snap:
                RoundedRectangle(cornerRadius: isRecording ? 6 : 30)
                    .fill(Color.yellow)
                    .frame(width: isRecording ? 30 : 60, height: isRecording ? 30 : 60)
                    .overlay {
                        if !isRecording {
                            Image(systemName: "sparkles").foregroundStyle(.black)
                        }
                    }
            }
        }
        .frame(width: 80, height: 80)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressBegan() }
                .onEnded { _ in pressEnded() }
        )
        .animation(.easeInOut(duration: 0.2), value: isRecording)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }

    private func pressBegan() {
        guard !isPressing else { return }
        isPressing = true
        longPressFired = false
        guard mode == .photo, !isBusy, !isRecording, let onLongPressStart else { return }
        let item = DispatchWorkItem {
            longPressFired = true
            onLongPressStart()
        }
        pendingLongPress = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }

    private func pressEnded() {
        isPressing = false
        pendingLongPress?.cancel()
        pendingLongPress = nil
        if longPressFired {
            longPressFired = false
            onLongPressEnd?()
        } else {
            action()
        }
    }
}

/// 最後に撮った写真・動画。タップでアプリ内のアルバムを開く。
struct ThumbnailButton: View {
    let image: UIImage?
    /// 撮った写真をまだ保存している（くるくるを重ねる）
    var busy = false
    /// アプリ内のアルバムを開く
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.chromeText.opacity(0.15)
                    }
                }
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.chromeText.opacity(0.6), lineWidth: 1))
                .overlay {
                    if busy {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.45))
                            ProgressView().tint(.white).scaleEffect(0.7)
                        }
                    }
                }
                Text(busy ? "保存中" : "アルバム")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(Color.chromeText)
            }
        }
    }
}

struct Badge: View {
    let text: String
    var color: Color = .black.opacity(0.55)
    var dot: Color?

    var body: some View {
        HStack(spacing: 6) {
            if let dot {
                Circle().fill(dot).frame(width: 8, height: 8)
            }
            Text(text)
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(color))
        .foregroundStyle(.white)
    }
}

// MARK: - 連続撮影

/// 次のシャッターまでの残り時間を、減っていく円で表す。円がなくなった瞬間にシャッターが切れる。
/// 円は 12 時の位置から時計回りに減っていく。真ん中は「次に撮るのが何枚目か / 全部で何枚か」。
/// 1 枚ごとに「満タンから 0 まで一定の速さで減る」アニメーションを 1 回だけ指示し、
/// 毎コマの計算は画面側（Core Animation）に任せて、カクつかないようにする。
struct BurstRing: View {
    let timeline: BurstTimeline

    @State private var remaining = 1.0
    @State private var next = 2
    @State private var visible = false

    var body: some View {
        ZStack {
            if visible {
                Circle()
                    .fill(Color.black.opacity(0.35))
                Circle()
                    .stroke(Color.white.opacity(0.25), lineWidth: 8)
                // 時計回りに減らすため、終わり側（12 時）を固定して始まり側を動かす
                Circle()
                    .trim(from: 1 - remaining, to: 1)
                    .stroke(Color.yellow, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text("\(min(next, timeline.total))")
                        .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                    Text("/ \(timeline.total)枚")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
            }
        }
        .frame(width: 120, height: 120)
        .allowsHitTesting(false)
        .task(id: timeline) { await run() }
    }

    private func run() async {
        if timeline.showsLeadIn {
            // タイマーなしの連続撮影: 押してから 1 枚目（2 秒後）までも円で表す
            await deplete(next: 1, until: timeline.firstShot)
        } else {
            // タイマーのカウントダウン中（1 枚目より前）は数字の表示に任せる
            await sleep(until: timeline.firstShot)
        }
        for shot in 1..<timeline.total {
            guard !Task.isCancelled else { return }
            let nextShot = timeline.firstShot.addingTimeInterval(Double(shot) * timeline.interval)
            await deplete(next: shot + 1, until: nextShot)
        }
        visible = false
    }

    /// 円を満タンに戻し、date に 0 になるよう一定の速さで減らす。
    private func deplete(next shotNumber: Int, until date: Date) async {
        guard !Task.isCancelled else { return }
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            visible = true
            next = shotNumber
            remaining = 1
        }
        // 満タンに戻した状態を一度画面に出してから、減らすアニメーションを始める
        try? await Task.sleep(nanoseconds: 16_000_000)
        withAnimation(.linear(duration: max(0.05, date.timeIntervalSinceNow))) { remaining = 0 }
        await sleep(until: date)
    }

    private func sleep(until date: Date) async {
        let seconds = date.timeIntervalSinceNow
        if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    }
}

// MARK: - 特別な画面

/// 前回の起動で落ちたときの記録。テキストをコピーして共有できる。
struct CrashReportView: View {
    let report: CrashReport
    /// 引数は「美肌・美白をオフにして起動するか」
    let onStart: (Bool) -> Void

    @State private var copied = false

    private var text: String {
        var lines = ["iOS \(UIDevice.current.systemVersion) / \(UIDevice.current.model)"]
        lines += report.steps
        if let exception = report.exception {
            lines.append("例外: \(exception)")
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("前回の起動で問題が起きました")
                .font(.headline)
            Text("最後の行の処理の途中で止まっています。下の「記録をコピー」を押して、内容を開発者に送ってください。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))

            Button(copied ? "コピーしました" : "記録をコピー") {
                UIPasteboard.general.string = text
                copied = true
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)

            HStack {
                Button("そのまま起動") { onStart(false) }
                Spacer()
                Button("美肌・美白オフで起動") { onStart(true) }
            }
            .font(.subheadline)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.chromeBackground.ignoresSafeArea())
        .foregroundStyle(Color.chromeText)
    }
}

struct PermissionView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.largeTitle)
            Text("カメラへのアクセスが許可されていません")
                .font(.headline)
            Text("設定アプリでカメラへのアクセスを許可してください。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("設定を開く") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(Color.chromeText)
        .padding()
    }
}
