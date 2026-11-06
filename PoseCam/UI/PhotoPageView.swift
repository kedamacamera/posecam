import Photos
import SwiftUI
import UIKit

/// アルバムの写真・動画を左右にめくる画面（UIKit の UIPageViewController）。
/// 写真は 1 枚ずつ拡大できるスクロール面（UIScrollView）に置く。iPhone の写真アプリと同じ仕組みで、
/// 拡大中に指で動かすと、まず写真が動き、写真の端が画面の端に来てからさらに動かしたときだけ前後の写真へめくれる。
/// 以前の SwiftUI の TabView では、拡大中に写真を動かすと同時に次の写真へめくれていた。
struct PhotoPageView: UIViewControllerRepresentable {
    let assets: PHFetchResult<PHAsset>
    @Binding var index: Int

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal,
                                              options: [.interPageSpacing: 16])
        controller.view.backgroundColor = .black
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        if let first = context.coordinator.page(at: index) {
            controller.setViewControllers([first], direction: .forward, animated: false)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.state.current = index
    }

    /// いま表示しているページの番号（動画の再生・停止に使う）
    final class PagerState: ObservableObject {
        @Published var current = 0
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PhotoPageView
        let state = PagerState()

        init(parent: PhotoPageView) {
            self.parent = parent
            state.current = parent.index
        }

        func page(at i: Int) -> UIViewController? {
            guard i >= 0, i < parent.assets.count else { return nil }
            let asset = parent.assets.object(at: i)
            let controller: UIViewController
            if asset.mediaType == .video {
                controller = UIHostingController(rootView: VideoPageContent(asset: asset, index: i, state: state))
                controller.view.backgroundColor = .black
            } else {
                controller = ZoomingPhotoController(asset: asset)
            }
            controller.view.tag = i
            return controller
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            page(at: viewController.view.tag - 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            page(at: viewController.view.tag + 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let current = pageViewController.viewControllers?.first else { return }
            // めくって離れた写真は、拡大を元に戻しておく
            for previous in previousViewControllers {
                (previous as? ZoomingPhotoController)?.resetZoom()
            }
            let i = current.view.tag
            state.current = i
            parent.index = i
        }
    }
}

/// 動画の 1 ページ。いま表示しているページのときだけ再生する
private struct VideoPageContent: View {
    let asset: PHAsset
    let index: Int
    @ObservedObject var state: PhotoPageView.PagerState

    var body: some View {
        AssetPage(asset: asset, isCurrent: state.current == index)
    }
}

/// 写真 1 枚。2 本指で拡大（指の間を中心に）、1 本指で移動、ダブルタップでタップした所を拡大・元に戻す
final class ZoomingPhotoController: UIViewController, UIScrollViewDelegate {
    private let asset: PHAsset
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var request: PHImageRequestID?

    init(asset: PHAsset) {
        self.asset = asset
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        view.addSubview(scrollView)
        imageView.contentMode = .scaleAspectFit
        scrollView.addSubview(imageView)
        spinner.color = .white
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        spinner.startAnimating()
        view.addSubview(spinner)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        load()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if scrollView.zoomScale <= scrollView.minimumZoomScale + 0.001 { layoutImage() }
    }

    deinit {
        if let request { PHImageManager.default().cancelImageRequest(request) }
    }

    private func load() {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        // 拡大しても粗くならないよう、画面の 2 倍の細かさで読み込む
        let scale = UIScreen.main.scale * 2
        let bounds = UIScreen.main.bounds
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        request = PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFit,
                                                        options: options) { [weak self] image, _ in
            guard let self, let image else { return }
            self.spinner.stopAnimating()
            self.imageView.image = image
            self.layoutImage()
        }
    }

    /// 写真を画面に収まる大きさで置く（拡大していないとき）
    private func layoutImage() {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return }
        let bounds = scrollView.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        scrollView.zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: size)
        scrollView.contentSize = size
        centerImage()
    }

    /// 写真が画面より小さい向きは、余白を上下・左右に均等に入れて中央に置く
    private func centerImage() {
        let bounds = scrollView.bounds.size
        let content = imageView.frame.size
        let x = max(0, (bounds.width - content.width) / 2)
        let y = max(0, (bounds.height - content.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func resetZoom() {
        scrollView.setZoomScale(1, animated: false)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1.01 {
            scrollView.setZoomScale(1, animated: true)
        } else {
            let point = recognizer.location(in: imageView)
            let scale: CGFloat = 2.5
            let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
            scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
        }
    }
}
