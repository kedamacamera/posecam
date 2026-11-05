import SwiftUI
import CoreImage

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
    let systemImage: String
    let label: String
    var active = false

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: systemImage)
                .font(.system(size: 19))
                .frame(height: 24)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .frame(minWidth: 48)
        .foregroundStyle(active ? Color.yellow : .white)
        .shadow(color: .black.opacity(0.5), radius: 2)
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
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white, lineWidth: 1.5))
                    .frame(height: 24)
                Text("比率")
                    .font(.system(size: 10, weight: .medium))
            }
            .frame(minWidth: 48)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 2)
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
            } else if let activeLens {
                Text(activeLens)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .shadow(color: .black.opacity(0.6), radius: 2)
            }
            HStack(spacing: 6) {
                ForEach(options) { option in
                    let active = option.displayFactor == activeFactor
                    Text(active ? ZoomFormat.short(zoom) + "×" : ZoomFormat.short(option.displayFactor))
                        .font(.system(size: active ? 12 : 11, weight: .bold))
                        .foregroundStyle(active ? Color.yellow : .white)
                        .frame(width: active ? 40 : 32, height: active ? 40 : 32)
                        .background(Circle().fill(Color.black.opacity(0.45)))
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
        }
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

    var body: some View {
        VStack(spacing: 8) {
            StrengthSlider(value: $strength, standard: PhotoFilter.standardStrength)
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

/// フィルターの濃さ。標準（70%）の所に点があり、近くまで動かすと磁石のように吸い付く（軽い振動つき）。
/// 100% はわざと少しやりすぎなくらいの濃さ。
struct StrengthSlider: View {
    @Binding var value: Double
    let standard: Double
    /// この範囲まで近づいたら標準に吸い付く
    private let snapRange = 0.04

    var body: some View {
        HStack(spacing: 10) {
            Text("濃さ")
                .font(.caption.weight(.semibold))
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.3)).frame(height: 4)
                    Capsule().fill(Color.yellow).frame(width: width * value, height: 4)
                    // 標準の位置の点
                    Circle()
                        .fill(abs(value - standard) < 0.001 ? Color.yellow : .white)
                        .frame(width: 7, height: 7)
                        .offset(x: width * standard - 3.5)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 20, height: 20)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .offset(x: width * value - 10)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    var next = min(max(drag.location.x / width, 0), 1)
                    if abs(next - standard) < snapRange { next = standard }
                    if next == standard && value != standard {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    value = next
                })
            }
            .frame(height: 24)
            Text("\(Int((value * 100).rounded()))")
                .font(.caption.monospacedDigit())
                .frame(width: 28, alignment: .trailing)
        }
        .foregroundStyle(.white)
    }
}

/// 三分割の線。料理や物の主役を線の交点に置くと、構図が決まりやすい。
struct GridOverlay: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for i in 1...2 {
                let x = size.width * CGFloat(i) / 3
                let y = size.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(.black.opacity(0.3)), lineWidth: 2)
            context.stroke(path, with: .color(.white.opacity(0.7)), lineWidth: 0.8)
        }
        .allowsHitTesting(false)
    }
}

/// フィルターの見本（同梱の見本写真の上半身に、そのフィルターをかけた小さな画像）。メインスレッドから使う。
enum FilterThumbnails {
    private static let context = CIContext()
    private static var cache: [PhotoFilter: UIImage] = [:]

    private static let source: CIImage? = {
        guard let url = Bundle.main.url(forResource: "pose_00", withExtension: "jpg"),
              let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        let e = image.extent
        // 上半身あたりを正方形に切り抜いて、112 ピクセルに縮める
        let side = e.width * 0.8
        let crop = CGRect(x: e.minX + (e.width - side) / 2, y: e.maxY - side - e.height * 0.04,
                          width: side, height: side)
        let scale = 112 / side
        return image.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }()

    static func image(for filter: PhotoFilter) -> UIImage? {
        if let cached = cache[filter] { return cached }
        guard let source else { return nil }
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
        HStack(spacing: 20) {
            ForEach(CaptureMode.allCases) { item in
                Button { onSelect(item) } label: {
                    Text(item.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(item == mode ? Color.yellow : .white.opacity(0.75))
                        .shadow(color: .black.opacity(0.5), radius: 2)
                }
                .disabled(isLocked)
            }
        }
    }
}

struct ShutterButton: View {
    let mode: CaptureMode
    let isRecording: Bool
    let isBusy: Bool
    /// スナップ撮影の進み具合（0...1）
    let progress: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 74, height: 74)
                if mode == .snap && isRecording {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.yellow, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 74, height: 74)
                }
                switch mode {
                case .photo:
                    Circle()
                        .fill(Color.white.opacity(isBusy ? 0.6 : 1))
                        .frame(width: 60, height: 60)
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
        }
        .animation(.easeInOut(duration: 0.2), value: isRecording)
    }
}

/// 最後に撮った写真・動画。タップで写真アプリを開く。
struct ThumbnailButton: View {
    let image: UIImage?

    var body: some View {
        Button {
            if let url = URL(string: "photos-redirect://") {
                UIApplication.shared.open(url)
            }
        } label: {
            HStack(spacing: 6) {
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.white.opacity(0.15)
                    }
                }
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.6), lineWidth: 1))
                Text("アルバム")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
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
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
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
        .foregroundStyle(.white)
        .padding()
    }
}
