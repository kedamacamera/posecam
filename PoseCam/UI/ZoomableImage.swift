import SwiftUI

/// 拡大・移動できる画像（編集画面とアルバムの写真で使う）。
/// - 2 本指でつまむ: 指の間を中心に拡大・縮小する（1〜6 倍）
/// - 1 本指でなぞる: 拡大しているとき・画像が画面より大きいときに移動する
/// - ダブルタップ: タップした所を中心に 2.5 倍、拡大中なら元に戻す
/// どの操作でも、画像の端が表示する範囲の内側へ入り込まない（画面の外へ流れていかない）ようにする。
/// 以前の編集画面は画面の中央を中心に拡大していたため、端の方でつまむと狙った所が画面の外へ逃げ、
/// 縮小すると画像が画面の外に残っていた。
struct ZoomableImage<Overlay: View>: View {
    let image: UIImage
    /// 表示する大きさを、表示できる範囲から決める（nil なら範囲に収まる大きさ）
    let displaySize: ((CGSize) -> CGSize)?
    /// 画像に重ねるもの（構図の線など。画像と一緒に拡大する）
    let overlay: () -> Overlay
    /// 拡大しているか（アルバムで、拡大中は左右のめくりを止めるのに使う）
    let onZoomChange: ((Bool) -> Void)?

    init(image: UIImage, displaySize: ((CGSize) -> CGSize)? = nil, onZoomChange: ((Bool) -> Void)? = nil,
         @ViewBuilder overlay: @escaping () -> Overlay) {
        self.image = image
        self.displaySize = displaySize
        self.onZoomChange = onZoomChange
        self.overlay = overlay
    }

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var pinchStart: (zoom: CGFloat, pan: CGSize, location: CGPoint)?
    @State private var dragStart: CGSize?

    var body: some View {
        GeometryReader { geo in
            let area = geo.size
            let size = displaySize?(area) ?? Self.fit(image.size, in: area)
            Image(uiImage: image)
                .resizable()
                .frame(width: size.width, height: size.height)
                .overlay(overlay())
                .scaleEffect(zoom)
                .offset(pan)
                .frame(width: area.width, height: area.height)
                .contentShape(Rectangle())
                .gesture(magnify(area: area, size: size))
                .simultaneousGesture(drag(area: area, size: size),
                                     including: canPan(area: area, size: size) ? .all : .subviews)
                .onTapGesture(count: 2, coordinateSpace: .local) { location in
                    withAnimation(.easeOut(duration: 0.2)) {
                        if zoom > 1.01 {
                            zoom = 1
                        } else {
                            let c = contentPoint(location, area: area)
                            zoom = 2.5
                            pan = CGSize(width: location.x - area.width / 2 - c.x * zoom,
                                         height: location.y - area.height / 2 - c.y * zoom)
                        }
                        pan = clamped(pan, area: area, size: size)
                    }
                    onZoomChange?(zoom > 1.01)
                }
                .onChange(of: size) { pan = clamped(pan, area: area, size: size) }
        }
        .clipped()
    }

    static func fit(_ image: CGSize, in area: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return area }
        let scale = min(area.width / image.width, area.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    /// 画面の点（範囲の左上が原点）が、拡大前の画像のどこ（中央が原点）にあたるか
    private func contentPoint(_ location: CGPoint, area: CGSize) -> CGPoint {
        CGPoint(x: (location.x - area.width / 2 - pan.width) / zoom,
                y: (location.y - area.height / 2 - pan.height) / zoom)
    }

    private func canPan(area: CGSize, size: CGSize) -> Bool {
        size.width * zoom > area.width + 1 || size.height * zoom > area.height + 1
    }

    /// 画像の端が範囲の内側に入り込まない移動量（画像が範囲より小さい向きは中央に置く）
    private func clamped(_ pan: CGSize, area: CGSize, size: CGSize) -> CGSize {
        let maxX = max(0, (size.width * zoom - area.width) / 2)
        let maxY = max(0, (size.height * zoom - area.height) / 2)
        return CGSize(width: min(max(pan.width, -maxX), maxX), height: min(max(pan.height, -maxY), maxY))
    }

    private func magnify(area: CGSize, size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? (zoom: zoom, pan: pan, location: value.startLocation)
                pinchStart = start
                // つまみ始めた指の間にあった画像の点が、ずっと指の間に残るように動かす
                let l = CGPoint(x: start.location.x - area.width / 2, y: start.location.y - area.height / 2)
                let c = CGPoint(x: (l.x - start.pan.width) / start.zoom, y: (l.y - start.pan.height) / start.zoom)
                zoom = min(6, max(1, start.zoom * value.magnification))
                pan = clamped(CGSize(width: l.x - c.x * zoom, height: l.y - c.y * zoom), area: area, size: size)
            }
            .onEnded { _ in
                pinchStart = nil
                if zoom < 1.01 { zoom = 1 }
                withAnimation(.easeOut(duration: 0.15)) { pan = clamped(pan, area: area, size: size) }
                onZoomChange?(zoom > 1.01)
            }
    }

    private func drag(area: CGSize, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard pinchStart == nil else { return }
                let start = dragStart ?? pan
                dragStart = start
                pan = clamped(CGSize(width: start.width + value.translation.width,
                                     height: start.height + value.translation.height), area: area, size: size)
            }
            .onEnded { _ in dragStart = nil }
    }
}

extension ZoomableImage where Overlay == EmptyView {
    init(image: UIImage, displaySize: ((CGSize) -> CGSize)? = nil, onZoomChange: ((Bool) -> Void)? = nil) {
        self.init(image: image, displaySize: displaySize, onZoomChange: onZoomChange) { EmptyView() }
    }
}
