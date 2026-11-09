import SwiftUI

/// モニターで見る「撮った写真」。このモニターを開いてから撮る側で撮った写真（新しいものが先頭）。
/// 写真は撮る側の写真ライブラリに保存されている。ここにあるのは確認用の縮小した写真（長い辺 1600）
struct MonitorAlbumView: View {
    let photos: [MonitorPhoto]
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

    var body: some View {
        NavigationStack {
            Group {
                if photos.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle").font(.largeTitle)
                        Text("まだ写真がありません")
                            .font(.headline)
                        Text("このモニターを開いている間に撮った写真が、ここに入ります。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(30)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(photos) { photo in
                                NavigationLink {
                                    MonitorPhotoPage(photos: photos, selection: photo.id)
                                } label: {
                                    Image(uiImage: photo.image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(minWidth: 0, maxWidth: .infinity)
                                        .aspectRatio(3 / 4, contentMode: .fill)
                                        .clipped()
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("撮った写真")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down").font(.system(size: 17, weight: .semibold))
                    }
                    .accessibilityLabel("モニターに戻る")
                }
            }
        }
    }
}

/// 1 枚ずつ大きく見る（左右にめくる。つまむ・ダブルタップで拡大。拡大していなければ下へなぞると一覧に戻る）
private struct MonitorPhotoPage: View {
    let photos: [MonitorPhoto]
    @State var selection: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TabView(selection: $selection) {
            ForEach(photos) { photo in
                MonitorZoomImage(image: photo.image) { dismiss() }
                    .tag(photo.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea(edges: .bottom)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// つまんで拡大・ダブルタップで拡大／元に戻す写真（UIScrollView）。
/// 拡大していないときは、横になぞると外側のページめくりになる
private struct MonitorZoomImage: UIViewRepresentable {
    let image: UIImage
    /// 下へなぞって離した（一覧に戻る）
    let onSwipeDown: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSwipeDown: onSwipeDown) }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = ZoomScrollView()
        scroll.backgroundColor = .clear
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delegate = context.coordinator
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        scroll.addSubview(imageView)
        scroll.imageView = imageView
        context.coordinator.imageView = imageView
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        // 拡大していないとき、下へなぞると写真が指について動き、離すと一覧に戻る（写真アプリと同じ）
        let down = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swipeDown(_:)))
        down.delegate = context.coordinator
        scroll.addGestureRecognizer(down)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.onSwipeDown = onSwipeDown
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
            scroll.setZoomScale(1, animated: false)
            scroll.setNeedsLayout()
        }
    }

    /// 拡大していないときの写真の枠を、画面の大きさに合わせる
    final class ZoomScrollView: UIScrollView {
        weak var imageView: UIImageView?
        private var laidOutSize: CGSize = .zero

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let imageView, bounds.size != laidOutSize, bounds.width > 0 else { return }
            laidOutSize = bounds.size
            setZoomScale(1, animated: false)
            imageView.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        weak var imageView: UIImageView?
        var onSwipeDown: () -> Void

        init(onSwipeDown: @escaping () -> Void) {
            self.onSwipeDown = onSwipeDown
        }

        /// 拡大していないときに、下向きになぞり始めたときだけ受け取る（横はページめくり）
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer,
                  let scroll = recognizer.view as? UIScrollView else { return true }
            guard scroll.zoomScale <= 1.01 else { return false }
            let v = pan.velocity(in: scroll)
            return v.y > 0 && v.y > abs(v.x) * 1.2
        }

        @objc func swipeDown(_ pan: UIPanGestureRecognizer) {
            guard let view = imageView else { return }
            let t = pan.translation(in: pan.view)
            switch pan.state {
            case .changed:
                let dy = max(0, t.y)
                let scale = max(0.6, 1 - dy / 1200)
                view.transform = CGAffineTransform(translationX: t.x, y: dy).scaledBy(x: scale, y: scale)
            case .ended:
                if t.y > 110 || pan.velocity(in: pan.view).y > 900 {
                    onSwipeDown()
                } else {
                    UIView.animate(withDuration: 0.2) { view.transform = .identity }
                }
            default:
                UIView.animate(withDuration: 0.2) { view.transform = .identity }
            }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func doubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scroll = recognizer.view as? UIScrollView, let imageView else { return }
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: true)
            } else {
                // タップした所を中心に 2.5 倍
                let point = recognizer.location(in: imageView)
                let scale: CGFloat = 2.5
                let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
            }
        }
    }
}
