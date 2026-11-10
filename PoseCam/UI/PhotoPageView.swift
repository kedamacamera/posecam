import Photos
import SwiftUI
import UIKit

/// 写真の画面を下へなぞって一覧へ戻るときの、画面との受け渡し。
/// i は、なぞっているページの番号
struct PagerDismissal {
    /// なぞり始めた（一覧のそのマスを見える位置へ動かし、マスを隠しておく）
    var began: (Int) -> Void = { _ in }
    /// なぞった量（0〜1）。背景をこの割合で薄くして、下の一覧を透かす。
    /// duration があるときは、その時間をかけてその値へ動かす（閉じる・元に戻すとき）
    var progress: (CGFloat, Double?) -> Void = { _, _ in }
    /// 戻る先（一覧のマスの位置、画面の座標）。nil ならその場で薄くして閉じる
    var target: (Int) -> CGRect? = { _ in nil }
    /// 途中でやめて元に戻した
    var cancelled: (Int) -> Void = { _ in }
    /// 一覧へ戻り終わった
    var finished: () -> Void = {}
}

/// アルバムの写真・動画を左右にめくる画面（UIKit の UIPageViewController）。
/// 写真は 1 枚ずつ拡大できるスクロール面（UIScrollView）に置く。iPhone の写真アプリと同じ仕組みで、
/// 拡大中に指で動かすと、まず写真が動き、写真の端が画面の端に来てからさらに動かしたときだけ前後の写真へめくれる。
/// 以前の SwiftUI の TabView では、拡大中に写真を動かすと同時に次の写真へめくれていた。
/// 拡大していないときに下へなぞると、写真が指について動き、背景が薄くなって下の一覧が見え、
/// 離すと写真が一覧のマスへ縮んで戻る（写真アプリと同じ）。背景は SwiftUI の側（AssetViewer）で描くので、ここは透明
struct PhotoPageView: UIViewControllerRepresentable {
    let assets: PHFetchResult<PHAsset>
    @Binding var index: Int
    var dismissal = PagerDismissal()

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal,
                                              options: [.interPageSpacing: 16])
        controller.view.backgroundColor = .clear
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

        /// ページ i の、下へなぞって閉じる操作の受け渡し（いつも最新の parent に渡す）
        private func dismissal(for i: Int) -> SwipeDownToDismiss.Handlers {
            SwipeDownToDismiss.Handlers(
                began: { [weak self] in self?.parent.dismissal.began(i) },
                progress: { [weak self] p, d in self?.parent.dismissal.progress(p, d) },
                target: { [weak self] in self?.parent.dismissal.target(i) },
                cancelled: { [weak self] in self?.parent.dismissal.cancelled(i) },
                finished: { [weak self] in self?.parent.dismissal.finished() })
        }

        func page(at i: Int) -> UIViewController? {
            guard i >= 0, i < parent.assets.count else { return nil }
            let asset = parent.assets.object(at: i)
            let controller: UIViewController
            if asset.mediaType == .video {
                let hosting = UIHostingController(rootView: VideoPageContent(asset: asset, index: i, state: state))
                hosting.view.backgroundColor = .clear
                // 動画は一覧のマスへ縮めず、その場で薄くして閉じる
                var handlers = dismissal(for: i)
                handlers.target = { nil }
                hosting.view.addGestureRecognizer(SwipeDownToDismiss(moving: { [weak hosting] in hosting?.view },
                                                                     canBegin: { true }, handlers: handlers))
                controller = hosting
            } else {
                let photo = ZoomingPhotoController(asset: asset)
                photo.dismissal = dismissal(for: i)
                controller = photo
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
    var dismissal = SwipeDownToDismiss.Handlers()

    init(asset: PHAsset) {
        self.asset = asset
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
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
        spinner.color = .secondaryLabel
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        spinner.startAnimating()
        view.addSubview(spinner)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        // 拡大していないときだけ、下へなぞって一覧へ戻る
        scrollView.addGestureRecognizer(SwipeDownToDismiss(
            moving: { [weak self] in self?.imageView },
            canBegin: { [weak self] in
                guard let self else { return false }
                return self.scrollView.zoomScale <= self.scrollView.minimumZoomScale + 0.01
            },
            handlers: SwipeDownToDismiss.Handlers(
                began: { [weak self] in self?.dismissal.began() },
                progress: { [weak self] p, d in self?.dismissal.progress(p, d) },
                target: { [weak self] in self?.dismissal.target() },
                cancelled: { [weak self] in self?.dismissal.cancelled() },
                finished: { [weak self] in self?.dismissal.finished() })))
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

/// 下へなぞって一覧へ戻る（写真アプリと同じ動き）。
/// なぞっている間は写真が指について動き（少し小さくなる）、背景が薄くなって下の一覧が見えてくる。
/// 画面の高さの 8% 以上下げるか、下へ払って離すと、写真が一覧のマスの位置へ縮みながら戻って閉じる
/// （以前は 15% で、1 回目のなぞりでは戻ってしまうことが多かった）。
/// それ以外は元の位置へ戻る
final class SwipeDownToDismiss: UIPanGestureRecognizer, UIGestureRecognizerDelegate {
    struct Handlers {
        var began: () -> Void = {}
        var progress: (CGFloat, Double?) -> Void = { _, _ in }
        var target: () -> CGRect? = { nil }
        var cancelled: () -> Void = {}
        var finished: () -> Void = {}
    }

    private let moving: () -> UIView?
    private let canBegin: () -> Bool
    private let handlers: Handlers

    init(moving: @escaping () -> UIView?, canBegin: @escaping () -> Bool, handlers: Handlers) {
        self.moving = moving
        self.canBegin = canBegin
        self.handlers = handlers
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(handle(_:)))
        delegate = self
        maximumNumberOfTouches = 1
    }

    /// スクロール面・動画の操作と同時に受け取る（拡大していない写真ではスクロール面は動かない）
    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    /// 下向きに、横よりはっきり縦に動かし始めたときだけ（左右のめくりと取り合わない）
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer, canBegin() else { return false }
        // もう左右のめくりが動き出していたら、閉じる操作は始めない
        if let pager = pagerScrollView, pager.isDragging {
            let width = max(pager.bounds.width, 1)
            let offset = pager.contentOffset.x
            let nearest = (offset / width).rounded() * width
            if abs(offset - nearest) > 8 { return false }
        }
        let v = pan.velocity(in: pan.view)
        return v.y > 0 && v.y > abs(v.x) * 1.3
    }

    /// 左右にめくる面（UIPageViewController の中のスクロール面）
    private var pagerScrollView: UIScrollView? {
        var current = view?.superview
        while let v = current {
            if let scroll = v as? UIScrollView, scroll.isPagingEnabled { return scroll }
            current = v.superview
        }
        return nil
    }

    /// 閉じる操作の間は左右のめくりを止める。
    /// 斜め下になぞったとき、めくりと閉じるが同時に動いて、隣の写真に替わりながら閉じていた
    private func lockPager(_ locked: Bool) {
        guard let pager = pagerScrollView else { return }
        if locked {
            // 動き始めていためくりを取り消す（めくり面は今のページへ戻る）
            pager.panGestureRecognizer.isEnabled = false
            pager.panGestureRecognizer.isEnabled = true
            let width = max(pager.bounds.width, 1)
            let page = (pager.contentOffset.x / width).rounded() * width
            pager.setContentOffset(CGPoint(x: page, y: pager.contentOffset.y), animated: false)
            pager.isScrollEnabled = false
        } else {
            pager.isScrollEnabled = true
        }
    }

    @objc private func handle(_ recognizer: UIPanGestureRecognizer) {
        guard let target = moving(), let container = recognizer.view else { return }
        let height = max(container.bounds.height, 1)
        let t = recognizer.translation(in: container)
        switch recognizer.state {
        case .began:
            lockPager(true)
            handlers.began()
        case .changed:
            // 写真の大きさは下げた量に合わせて最大 35% 小さく、背景は画面の高さの 40% 下げたところで透明
            let down = max(0, t.y)
            let scale = 1 - 0.35 * min(1, down / height)
            target.transform = CGAffineTransform(translationX: t.x, y: down).scaledBy(x: scale, y: scale)
            handlers.progress(min(1, down / (height * 0.4)), nil)
        case .ended, .cancelled, .failed:
            lockPager(false)
            let v = recognizer.velocity(in: container)
            // 途中で取り消された（ページめくりと取り合った）ときも、十分に下げていれば閉じる
            if recognizer.state != .failed, v.y > -200, t.y > height * 0.08 || v.y > 500 {
                finish(target)
            } else {
                handlers.progress(0, 0.25)
                UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                    target.transform = .identity
                } completion: { _ in
                    self.handlers.cancelled()
                }
            }
        default:
            break
        }
    }

    /// 写真を一覧のマスの位置へ縮めて閉じる。マスの位置が分からない（動画など）ときは、その場で薄くして閉じる
    private func finish(_ target: UIView) {
        let duration = 0.32
        guard let window = target.window else {
            handlers.finished()
            return
        }
        let image = (target as? UIImageView)?.image
        // 縮め始めは、画面に見えている写真の範囲（上下・左右の黒い余白を除く）から。
        // 以前は画面全体から始めていたので、写真が一瞬大きく切り抜かれて見え、縮み方がきれいでなかった
        var shown = target.bounds
        if let size = image?.size, size.width > 0, size.height > 0 {
            let s = min(shown.width / size.width, shown.height / size.height)
            let w = size.width * s, h = size.height * s
            shown = CGRect(x: shown.midX - w / 2, y: shown.midY - h / 2, width: w, height: h)
        }
        let start = target.convert(shown, to: nil)
        guard let image, let end = handlers.target() else {
            handlers.progress(1, 0.2)
            UIView.animate(withDuration: 0.2) {
                target.alpha = 0
            } completion: { _ in
                self.handlers.finished()
            }
            return
        }
        // 写真の今の位置に同じ写真を重ね、マスの位置・大きさへ動かす。
        // マスは正方形で写真を中央で切り抜いて見せているので、枠を縮めながら中の写真は枠いっぱいに広げる
        let flying = UIView(frame: start)
        flying.clipsToBounds = true
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFill
        imageView.frame = flying.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        flying.addSubview(imageView)
        window.addSubview(flying)
        target.isHidden = true
        handlers.progress(1, duration)
        UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                       options: [.curveEaseOut]) {
            flying.frame = end
        } completion: { _ in
            self.handlers.finished()
            // 一覧のマスが表示し直されるまで一瞬残してから消す（ちらつかないように）
            UIView.animate(withDuration: 0.12, delay: 0.05) {
                flying.alpha = 0
            } completion: { _ in
                flying.removeFromSuperview()
            }
        }
    }
}
