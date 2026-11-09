import Photos
import SwiftUI
import UIKit

/// アルバムの一覧（写真・動画のマス目）。
/// SwiftUI の LazyVGrid では、写真が何十万枚もあると並べる計算だけで重くなっていたので、
/// 写真アプリと同じ UICollectionView で表示し、見えているマスの縮小画像だけを読み込む。
struct AssetGridView: UIViewRepresentable {
    let assets: PHFetchResult<PHAsset>
    /// 写真の画面から一覧へ戻るときに、マスの位置を調べる・マスを隠すためのもの
    var link: AssetGridLink?
    /// 選択モード（タップで選ぶ・外す。選んだマスにチェックが付く）
    var selecting = false
    /// 選択モードで選んでいるもの（一覧の番号）が変わった
    var onSelectionChange: (Set<Int>) -> Void = { _ in }
    let onSelect: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing = 2
        let view = SlideCollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .systemBackground
        view.register(Cell.self, forCellWithReuseIdentifier: Cell.id)
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        view.prefetchDataSource = context.coordinator
        // 選択モードで横になぞり始めると、なぞった範囲をまとめて選ぶ（写真アプリと同じ）
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.slideSelect(_:)))
        // なぞって選んでいる間に、もう 1 本の指で一覧を動かせる（2 本目の指は SlideCollectionView が受け取る）
        pan.maximumNumberOfTouches = 2
        pan.cancelsTouchesInView = false
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        // なぞって選んでいる間は一覧をスクロールしない（横に動き始めなければ、すぐスクロールになる）
        view.panGestureRecognizer.require(toFail: pan)
        context.coordinator.collectionView = view
        view.onSecondFingerScroll = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.slideMoved(view)
        }
        context.coordinator.assets = assets
        context.coordinator.link = link
        link?.collectionView = view
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        coordinator.onSelectionChange = onSelectionChange
        if coordinator.assets !== assets {
            coordinator.assets = assets
            view.reloadData()
        }
        if coordinator.selecting != selecting {
            coordinator.selecting = selecting
            view.allowsMultipleSelection = selecting
            // 選択モードを終えたら、選んでいたものを外す
            if !selecting {
                for path in view.indexPathsForSelectedItems ?? [] { view.deselectItem(at: path, animated: false) }
            }
        }
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout,
                             UICollectionViewDataSourcePrefetching, UIGestureRecognizerDelegate {
        var assets: PHFetchResult<PHAsset>?
        var onSelect: (Int) -> Void
        var onSelectionChange: (Set<Int>) -> Void = { _ in }
        var selecting = false
        weak var link: AssetGridLink?
        weak var collectionView: UICollectionView?
        private let manager = PHCachingImageManager()
        /// なぞって選ぶ: なぞり始めたマス、選ぶのか外すのか、なぞり始める前に選んでいたもの、いま塗っている範囲
        private var slideStart: Int?
        private var slideSelects = true
        private var slideBaseline: Set<Int> = []
        private var slideRange: ClosedRange<Int>?
        private weak var slidePan: UIPanGestureRecognizer?
        /// なぞる指が一覧の上端・下端の近くにあるとき、一覧を自動で送る
        private var autoScroll: CADisplayLink?
        private var autoScrollSpeed: CGFloat = 0
        private var thumbnailSize = CGSize(width: 200, height: 200)

        init(onSelect: @escaping (Int) -> Void) {
            self.onSelect = onSelect
        }

        func collectionView(_ view: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            assets?.count ?? 0
        }

        func collectionView(_ view: UICollectionView, layout: UICollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> CGSize {
            // 幅 96 ポイント以上で、画面の幅にぴったり並ぶマスの大きさ
            let width = view.bounds.width
            let columns = max(3, floor((width + 2) / 98))
            let side = floor((width - 2 * (columns - 1)) / columns)
            let scale = view.traitCollection.displayScale
            thumbnailSize = CGSize(width: side * scale, height: side * scale)
            return CGSize(width: side, height: side)
        }

        func collectionView(_ view: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = view.dequeueReusableCell(withReuseIdentifier: Cell.id, for: indexPath) as! Cell
            guard let assets, indexPath.item < assets.count else { return cell }
            let asset = assets.object(at: indexPath.item)
            cell.show(asset: asset, manager: manager, size: thumbnailSize)
            // 写真の画面から戻ってくる途中のマスは隠しておく（戻ってきた写真がそこに収まって見えるように）
            cell.alpha = link?.hiddenIndex == indexPath.item ? 0 : 1
            return cell
        }

        func collectionView(_ view: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            if selecting {
                reportSelection(view)
            } else {
                view.deselectItem(at: indexPath, animated: false)
                onSelect(indexPath.item)
            }
        }

        func collectionView(_ view: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
            if selecting { reportSelection(view) }
        }

        // MARK: なぞって選ぶ

        /// 選択モードで、横向きに動き始めたときだけなぞって選ぶ（縦はふつうのスクロール）
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, pan.view === collectionView else { return true }
            guard selecting else { return false }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y)
        }

        @objc func slideSelect(_ pan: UIPanGestureRecognizer) {
            guard let view = pan.view as? UICollectionView else { return }
            let slideView = view as? SlideCollectionView
            switch pan.state {
            case .began:
                slideView?.sliding = true
                guard let start = view.indexPathForItem(at: slideLocation(view, pan))?.item else { return }
                slidePan = pan
                slideStart = start
                slideBaseline = Set((view.indexPathsForSelectedItems ?? []).map(\.item))
                // なぞり始めたマスが選ばれていなければ選んでいき、選ばれていれば外していく
                slideSelects = !slideBaseline.contains(start)
                slideRange = nil
                updateSlide(view, location: slideLocation(view, pan))
            case .changed:
                updateSlide(view, location: slideLocation(view, pan))
                updateAutoScroll(view, location: slideLocation(view, pan))
            default:
                slideView?.sliding = false
                stopAutoScroll()
                slideStart = nil
                slideRange = nil
            }
        }

        /// なぞっている指の位置（2 本目の指が触れていても、1 本目の指の位置）
        private func slideLocation(_ view: UICollectionView, _ pan: UIPanGestureRecognizer) -> CGPoint {
            (view as? SlideCollectionView)?.slideLocation() ?? pan.location(in: view)
        }

        /// 2 本目の指で一覧が動いた: なぞっている指の下のマスまで選ぶ
        func slideMoved(_ view: UICollectionView) {
            guard slideStart != nil, let pan = slidePan else { return }
            updateSlide(view, location: slideLocation(view, pan))
        }

        /// なぞり始めのマスから指のマスまで（一覧の並び順で）を、選ぶ・外す。範囲から外れたマスは元に戻す
        private func updateSlide(_ view: UICollectionView, location: CGPoint) {
            guard let start = slideStart,
                  let current = view.indexPathForItem(at: location)?.item else { return }
            let range = min(start, current)...max(start, current)
            guard range != slideRange else { return }
            let old = slideRange
            slideRange = range
            if let old {
                for i in old where !range.contains(i) {
                    set(view, i, selected: slideBaseline.contains(i))
                }
            }
            for i in range { set(view, i, selected: slideSelects) }
            reportSelection(view)
            UISelectionFeedbackGenerator().selectionChanged()
        }

        private func set(_ view: UICollectionView, _ i: Int, selected: Bool) {
            let path = IndexPath(item: i, section: 0)
            if selected {
                view.selectItem(at: path, animated: false, scrollPosition: [])
            } else {
                view.deselectItem(at: path, animated: false)
            }
        }

        private func updateAutoScroll(_ view: UICollectionView, location: CGPoint) {
            let visible = view.bounds.inset(by: view.adjustedContentInset)
            let edge: CGFloat = 70
            if location.y < visible.minY + edge {
                autoScrollSpeed = -min(18, (visible.minY + edge - location.y) / 4 + 2)
            } else if location.y > visible.maxY - edge {
                autoScrollSpeed = min(18, (location.y - (visible.maxY - edge)) / 4 + 2)
            } else {
                stopAutoScroll()
                return
            }
            if autoScroll == nil {
                let link = CADisplayLink(target: self, selector: #selector(autoScrollTick))
                link.add(to: .main, forMode: .common)
                autoScroll = link
            }
        }

        @objc private func autoScrollTick() {
            guard let view = collectionView, let pan = slidePan else { stopAutoScroll(); return }
            let minY = -view.adjustedContentInset.top
            let maxY = max(minY, view.contentSize.height + view.adjustedContentInset.bottom - view.bounds.height)
            let y = min(max(view.contentOffset.y + autoScrollSpeed, minY), maxY)
            guard y != view.contentOffset.y else { return }
            view.contentOffset.y = y
            // 一覧が動いた分、指の下のマスも変わる
            updateSlide(view, location: slideLocation(view, pan))
        }

        private func stopAutoScroll() {
            autoScroll?.invalidate()
            autoScroll = nil
        }

        private func reportSelection(_ view: UICollectionView) {
            onSelectionChange(Set((view.indexPathsForSelectedItems ?? []).map(\.item)))
        }

        func collectionView(_ view: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            guard let assets else { return }
            let list = indexPaths.filter { $0.item < assets.count }.map { assets.object(at: $0.item) }
            manager.startCachingImages(for: list, targetSize: thumbnailSize, contentMode: .aspectFill, options: nil)
        }

        func collectionView(_ view: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
            guard let assets else { return }
            let list = indexPaths.filter { $0.item < assets.count }.map { assets.object(at: $0.item) }
            manager.stopCachingImages(for: list, targetSize: thumbnailSize, contentMode: .aspectFill, options: nil)
        }
    }

    final class Cell: UICollectionViewCell {
        static let id = "asset"
        private let imageView = UIImageView()
        private let videoMark = UIImageView(image: UIImage(systemName: "play.fill"))
        /// 選んだマスのチェック（選択モードのとき）
        private let checkMark = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
        private let dim = UIView()
        private var assetID: String?
        private var request: PHImageRequestID?
        private weak var manager: PHImageManager?

        override init(frame: CGRect) {
            super.init(frame: frame)
            contentView.backgroundColor = .secondarySystemBackground
            contentView.clipsToBounds = true
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.frame = contentView.bounds
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            contentView.addSubview(imageView)
            videoMark.tintColor = .white
            videoMark.layer.shadowOpacity = 0.6
            videoMark.layer.shadowRadius = 2
            videoMark.layer.shadowOffset = .zero
            videoMark.frame = CGRect(x: 5, y: frame.height - 19, width: 14, height: 14)
            videoMark.autoresizingMask = [.flexibleTopMargin]
            contentView.addSubview(videoMark)
            dim.backgroundColor = UIColor.white.withAlphaComponent(0.25)
            dim.frame = contentView.bounds
            dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            contentView.addSubview(dim)
            checkMark.preferredSymbolConfiguration = .init(paletteColors: [.white, .systemBlue])
            checkMark.frame = CGRect(x: frame.width - 27, y: frame.height - 27, width: 22, height: 22)
            checkMark.autoresizingMask = [.flexibleLeftMargin, .flexibleTopMargin]
            contentView.addSubview(checkMark)
            updateCheck()
        }

        override var isSelected: Bool {
            didSet { updateCheck() }
        }

        private func updateCheck() {
            checkMark.isHidden = !isSelected
            dim.isHidden = !isSelected
        }

        required init?(coder: NSCoder) { fatalError() }

        override func prepareForReuse() {
            super.prepareForReuse()
            if let request { manager?.cancelImageRequest(request) }
            request = nil
            imageView.image = nil
            assetID = nil
        }

        func show(asset: PHAsset, manager: PHCachingImageManager, size: CGSize) {
            assetID = asset.localIdentifier
            self.manager = manager
            videoMark.isHidden = asset.mediaType != .video
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            options.resizeMode = .fast
            let id = asset.localIdentifier
            request = manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFill,
                                           options: options) { [weak self] image, _ in
                guard let self, self.assetID == id, let image else { return }
                self.imageView.image = image
            }
        }
    }
}

/// なぞって選んでいる間、2 本目の指で一覧を上下に動かせる UICollectionView。
/// なぞって選ぶ操作は、指を離したときにマスのタップ（選ぶ・外す）にならないよう、指の終わりを取り消しとして渡す
final class SlideCollectionView: UICollectionView {
    /// なぞって選んでいる最中
    var sliding = false {
        didSet {
            guard sliding != oldValue else { return }
            if sliding {
                slideTouch = activeTouches.count == 1 ? activeTouches.first : nil
                suppressEnd = true
            } else {
                scrollTouch = nil
            }
        }
    }
    /// 2 本目の指で一覧が動いた
    var onSecondFingerScroll: (() -> Void)?
    private var slideTouch: UITouch?
    private var scrollTouch: UITouch?
    private var activeTouches = Set<UITouch>()
    private var suppressEnd = false

    /// なぞっている指（1 本目）の位置
    func slideLocation() -> CGPoint? { slideTouch?.location(in: self) }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.formUnion(touches)
        if sliding, scrollTouch == nil {
            scrollTouch = touches.first { $0 !== slideTouch }
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if sliding, let touch = scrollTouch, touches.contains(touch), let window {
            // 指が上へ動けば一覧も上へ（標準のスクロールと同じ向き）
            let dy = touch.location(in: window).y - touch.previousLocation(in: window).y
            let minY = -adjustedContentInset.top
            let maxY = max(minY, contentSize.height + adjustedContentInset.bottom - bounds.height)
            contentOffset.y = min(max(contentOffset.y - dy, minY), maxY)
            onSecondFingerScroll?()
        }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches)
        if suppressEnd {
            super.touchesCancelled(touches, with: event)
        } else {
            super.touchesEnded(touches, with: event)
        }
        if activeTouches.isEmpty { suppressEnd = false }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches)
        super.touchesCancelled(touches, with: event)
        if activeTouches.isEmpty { suppressEnd = false }
    }

    private func finish(_ touches: Set<UITouch>) {
        activeTouches.subtract(touches)
        if let t = scrollTouch, touches.contains(t) { scrollTouch = nil }
        if let t = slideTouch, touches.contains(t) { slideTouch = nil }
    }
}

/// 一覧（AssetGridView）と写真の画面のつなぎ。
/// 写真の画面を下へなぞって戻るとき、そのマスを見える位置まで動かし、マスの位置（画面の座標）を返す
final class AssetGridLink {
    weak var collectionView: UICollectionView?
    /// 隠しているマス
    private(set) var hiddenIndex: Int?

    /// index のマスが一覧の見えている範囲に入るよう動かし、マスを隠す
    func reveal(_ index: Int) {
        guard let view = collectionView, index >= 0, index < view.numberOfItems(inSection: 0) else { return }
        let path = IndexPath(item: index, section: 0)
        view.layoutIfNeeded()
        if let attributes = view.layoutAttributesForItem(at: path) {
            let visible = view.bounds.inset(by: view.adjustedContentInset)
            if !visible.contains(attributes.frame) {
                view.scrollToItem(at: path, at: .centeredVertically, animated: false)
                view.layoutIfNeeded()
            }
        }
        setHidden(index)
    }

    /// index のマスの位置（画面の座標）
    func frame(for index: Int) -> CGRect? {
        guard let view = collectionView, view.window != nil,
              index >= 0, index < view.numberOfItems(inSection: 0),
              let attributes = view.layoutAttributesForItem(at: IndexPath(item: index, section: 0)) else { return nil }
        return view.convert(attributes.frame, to: nil)
    }

    /// マスを隠す（nil で元に戻す）
    func setHidden(_ index: Int?) {
        guard let view = collectionView else { return }
        if let old = hiddenIndex { view.cellForItem(at: IndexPath(item: old, section: 0))?.alpha = 1 }
        hiddenIndex = index
        if let index { view.cellForItem(at: IndexPath(item: index, section: 0))?.alpha = 0 }
    }
}
