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
    let onSelect: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing = 2
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .systemBackground
        view.register(Cell.self, forCellWithReuseIdentifier: Cell.id)
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        view.prefetchDataSource = context.coordinator
        context.coordinator.assets = assets
        context.coordinator.link = link
        link?.collectionView = view
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        context.coordinator.onSelect = onSelect
        if context.coordinator.assets !== assets {
            context.coordinator.assets = assets
            view.reloadData()
        }
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout,
                             UICollectionViewDataSourcePrefetching {
        var assets: PHFetchResult<PHAsset>?
        var onSelect: (Int) -> Void
        weak var link: AssetGridLink?
        private let manager = PHCachingImageManager()
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
            onSelect(indexPath.item)
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
