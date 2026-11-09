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

/// 1 枚ずつ大きく見る（左右にめくる。つまむ・ダブルタップで拡大）
private struct MonitorPhotoPage: View {
    let photos: [MonitorPhoto]
    @State var selection: UUID

    var body: some View {
        TabView(selection: $selection) {
            ForEach(photos) { photo in
                MonitorZoomImage(image: photo.image)
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

    func makeCoordinator() -> Coordinator { Coordinator() }

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
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
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

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

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
