import AVKit
import Photos
import SwiftUI

/// アプリ内のアルバム。端末の写真・動画を新しい順に並べる（写真ライブラリの読み取りの許可が要る）。
/// 写真をタップすると大きく表示し、「編集」で傾き補正・伸縮・肌の補正ができる。
struct AlbumView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Appearance.storageKey) private var appearance: Appearance = .system
    /// 端末の写真・動画（新しい順）。件数が多くても、表示するときに 1 件ずつ取り出す
    @State private var assets: PHFetchResult<PHAsset>?
    @State private var status: PHAuthorizationStatus = .notDetermined
    @State private var viewing: AlbumPage?
    @State private var editing: EditorInput?
    @State private var gridLink = AssetGridLink()
    /// 選択モード（選んだものを共有・削除する）
    @State private var selecting = false
    @State private var selection: Set<Int> = []
    /// 共有の画面に渡すファイル
    /// 選択モードの「共有」ボタンの位置（iPad で共有の画面をそこから吹き出しで出す）
    @State private var shareButtonFrame: CGRect?
    /// 共有用に書き出している・削除している
    @State private var working = false
    /// 写真の画面で削除したら増やして、写真の画面を作り直す（次の写真を表示する）
    @State private var viewerKey = 0
    /// 表示しているもの（すべて・PoseCam・お気に入り・動画・自分で作ったアルバム）
    @State private var source: AlbumSource = .all
    /// 自分で作ったアルバム（中身があるもの）
    @State private var userAlbums: [AlbumSource] = []
    /// 上の「最近の項目 ▼」を押して、アルバムの一覧を開いている
    @State private var showSources = false
    @State private var sourceEntries: [AlbumEntry] = []

    var body: some View {
        ZStack {
            NavigationStack {
                Group {
                    if status == .denied || status == .restricted {
                        VStack(spacing: 12) {
                            Text("写真を表示するには、設定で写真へのアクセスを許可してください。")
                                .multilineTextAlignment(.center)
                            Button("設定を開く") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        }
                        .padding()
                    } else if (assets?.count ?? 0) == 0 {
                        Text(status == .notDetermined ? "読み込み中…" : emptyText)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let assets {
                        // 何十万枚あっても軽いよう、UIKit の一覧で表示する
                        AssetGridView(assets: assets, link: gridLink, selecting: selecting,
                                      onSelectionChange: { selection = $0 }) { index in
                            withAnimation(.easeOut(duration: 0.2)) { viewing = AlbumPage(index: index) }
                        }
                        .ignoresSafeArea(edges: .bottom)
                        .safeAreaInset(edge: .bottom) {
                            if selecting { selectionBar }
                        }
                    }
                }
                // アルバムの一覧（上の「最近の項目 ▼」で開く。BeautyCam と同じく、サムネイルと枚数つき）
                .overlay {
                    if showSources {
                        sourceList
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if !showSources {
                            Button("閉じる") { dismiss() }
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        if selecting {
                            Text(selection.isEmpty ? "選んでください" : "\(selection.count) 件を選択")
                                .font(.headline)
                        } else {
                            Button {
                                if !showSources { sourceEntries = AlbumEntry.all() }
                                withAnimation(.easeOut(duration: 0.2)) { showSources.toggle() }
                            } label: {
                                HStack(spacing: 6) {
                                    Text(source.title).font(.headline).lineLimit(1)
                                    Image(systemName: showSources ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 12, weight: .bold))
                                }
                                .foregroundStyle(Color.primary)
                            }
                            .disabled(working)
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if !showSources {
                            Button(selecting ? "キャンセル" : "選択") {
                                selecting.toggle()
                                selection = []
                            }
                            .disabled((assets?.count ?? 0) == 0)
                        }
                    }
                }
            }
            // 写真の画面は一覧の上に重ねる（下へなぞったとき、下の一覧が透けて見えるように）
            if let page = viewing, let assets {
                AssetViewer(assets: assets, start: page.index, link: gridLink) { data in
                    viewing = nil
                    editing = EditorInput(data: data)
                } onShare: { asset, frame in
                    share([asset], from: frame)
                } onDelete: { asset in
                    deleteInViewer(asset, at: page.index)
                } onClose: {
                    viewing = nil
                }
                .id(viewerKey)
                .transition(.opacity)
            }
            if working {
                ProgressView()
                    .padding(24)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
            }
        }
        .preferredColorScheme(appearance.scheme)
        .task { await load() }
        .fullScreenCover(item: $editing, onDismiss: { Task { await load() } }) { input in
            PhotoEditorView(data: input.data)
        }
    }

    /// アルバムの一覧。押すとそのアルバムに切り替えて閉じる
    private var sourceList: some View {
        List(sourceEntries) { entry in
            Button {
                withAnimation(.easeOut(duration: 0.2)) { showSources = false }
                guard entry.source != source else { return }
                source = entry.source
                selection = []
                Task { await load() }
            } label: {
                HStack(spacing: 16) {
                    AssetThumbnail(asset: entry.cover)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.source.title)
                            .font(.body)
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                        Text("\(entry.photos) 枚の写真と \(entry.videos) 件の動画")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if entry.source == source {
                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
        .listStyle(.plain)
        .background(Color(.systemBackground))
    }

    private var emptyText: String {
        switch source {
        case .poseCam:
            return "PoseCam のアルバムはまだ空です。\nこれから撮った写真・動画がここに入ります（前に撮ったものは「すべて」にあります）。"
        case .favorites: return "お気に入りはありません"
        case .videos: return "動画はありません"
        default: return "写真がありません"
        }
    }

    /// 選択モードの下の帯（共有・削除）
    private var selectionBar: some View {
        HStack {
            Button {
                share(selectedAssets, from: shareButtonFrame)
            } label: {
                Label("共有", systemImage: "square.and.arrow.up")
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { shareButtonFrame = $0 }
            Spacer()
            Text(selection.isEmpty ? "" : "\(selection.count) 件")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) {
                delete(selectedAssets)
            } label: {
                Label("削除", systemImage: "trash")
            }
        }
        .disabled(selection.isEmpty || working)
        .padding(.horizontal, 20)
        .frame(height: 49)
        .background(.bar)
    }

    private var selectedAssets: [PHAsset] {
        guard let assets else { return [] }
        return selection.sorted().filter { $0 < assets.count }.map { assets.object(at: $0) }
    }

    /// 元のファイルを書き出してから、共有の画面を出す
    private func share(_ list: [PHAsset], from frame: CGRect?) {
        guard !list.isEmpty, !working else { return }
        working = true
        Task {
            let items = await AlbumSharing.export(list)
            working = false
            if let items { AlbumSharing.present(items, from: frame) }
        }
    }

    /// 写真ライブラリから消す（iOS が確認する）。消したら一覧を読み直して選択モードを終える
    private func delete(_ list: [PHAsset]) {
        guard !list.isEmpty, !working else { return }
        working = true
        Task {
            let deleted = await AlbumSharing.delete(list)
            working = false
            if deleted {
                selecting = false
                selection = []
                await load()
            }
        }
    }

    /// 写真の画面で 1 枚消す（iOS が確認する）。消したら同じ位置（次の写真）を表示し、最後の 1 枚なら一覧に戻る
    private func deleteInViewer(_ asset: PHAsset, at index: Int) {
        guard !working else { return }
        working = true
        Task {
            let deleted = await AlbumSharing.delete([asset])
            working = false
            guard deleted else { return }
            await load()
            let count = assets?.count ?? 0
            if count == 0 {
                viewing = nil
            } else {
                viewing = AlbumPage(index: min(index, count - 1))
                viewerKey += 1
            }
        }
    }

    @MainActor
    private func load() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        userAlbums = AlbumSource.userAlbums()
        // 選んでいたアルバムが消えていたら「すべて」に戻す
        if case .album(let id, _) = source, !userAlbums.contains(where: { $0.id == id }) { source = .all }
        // 新しい順に、写真と動画をすべて（以前は 2000 件までで、古い写真が出なかった）
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let image = PHAssetMediaType.image.rawValue, video = PHAssetMediaType.video.rawValue
        switch source {
        case .all:
            options.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d", image, video)
            assets = PHAsset.fetchAssets(with: options)
        case .favorites:
            options.predicate = NSPredicate(format: "(mediaType == %d || mediaType == %d) && favorite == YES", image, video)
            assets = PHAsset.fetchAssets(with: options)
        case .videos:
            options.predicate = NSPredicate(format: "mediaType == %d", video)
            assets = PHAsset.fetchAssets(with: options)
        case .poseCam:
            if let album = MediaSaver.existingAlbum() {
                assets = PHAsset.fetchAssets(in: album, options: options)
            } else {
                assets = nil
            }
        case .album(let id, _):
            if let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject {
                assets = PHAsset.fetchAssets(in: album, options: options)
            } else {
                assets = nil
            }
        }
    }
}

/// アルバムで表示するもの
enum AlbumSource: Hashable, Identifiable {
    case all, poseCam, favorites, videos
    /// 自分で作ったアルバム（番号と名前）
    case album(String, String)

    var id: String {
        switch self {
        case .all: return "all"
        case .poseCam: return "posecam"
        case .favorites: return "favorites"
        case .videos: return "videos"
        case .album(let id, _): return id
        }
    }

    var title: String {
        switch self {
        case .all: return "最近の項目"
        case .poseCam: return "PoseCam"
        case .favorites: return "お気に入り"
        case .videos: return "動画"
        case .album(_, let name): return name
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "photo.on.rectangle"
        case .poseCam: return "camera"
        case .favorites: return "heart"
        case .videos: return "video"
        case .album: return "rectangle.stack"
        }
    }

    /// 自分で作ったアルバムのうち、中身があるもの（PoseCam のアルバムは別に出すので除く）
    static func userAlbums() -> [AlbumSource] {
        var list: [AlbumSource] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            .enumerateObjects { collection, _, _ in
                let title = collection.localizedTitle ?? ""
                guard title != MediaSaver.albumTitle, !title.isEmpty,
                      PHAsset.fetchAssets(in: collection, options: nil).count > 0 else { return }
                list.append(.album(collection.localIdentifier, title))
            }
        return list
    }
}

/// アルバムの一覧の 1 行（表紙と、写真・動画の数）
struct AlbumEntry: Identifiable {
    let source: AlbumSource
    let photos: Int
    let videos: Int
    let cover: PHAsset?
    var id: String { source.id }

    /// 最近の項目・お気に入り・動画・PoseCam・自分で作ったアルバム（中身があるもの）
    static func all() -> [AlbumEntry] {
        let image = PHAssetMediaType.image.rawValue, video = PHAssetMediaType.video.rawValue
        func options(_ format: String, _ args: [Any]) -> PHFetchOptions {
            let o = PHFetchOptions()
            o.predicate = NSPredicate(format: format, argumentArray: args)
            o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            return o
        }
        func entry(_ source: AlbumSource, extra: String?, in collection: PHAssetCollection?) -> AlbumEntry {
            let suffix = extra.map { " && " + $0 } ?? ""
            func fetch(_ o: PHFetchOptions) -> PHFetchResult<PHAsset> {
                collection.map { PHAsset.fetchAssets(in: $0, options: o) } ?? PHAsset.fetchAssets(with: o)
            }
            let photos = fetch(options("mediaType == %d" + suffix, [image])).count
            let videos = fetch(options("mediaType == %d" + suffix, [video])).count
            let cover = fetch(options("(mediaType == %d || mediaType == %d)" + suffix, [image, video])).firstObject
            return AlbumEntry(source: source, photos: photos, videos: videos, cover: cover)
        }
        var list = [
            entry(.all, extra: nil, in: nil),
            entry(.favorites, extra: "favorite == YES", in: nil),
        ]
        let videos = entry(.videos, extra: nil, in: nil)
        list.append(AlbumEntry(source: .videos, photos: 0, videos: videos.videos,
                               cover: PHAsset.fetchAssets(with: options("mediaType == %d", [video])).firstObject))
        if let album = MediaSaver.existingAlbum() {
            list.append(entry(.poseCam, extra: nil, in: album))
        }
        for source in AlbumSource.userAlbums() {
            guard case .album(let id, _) = source,
                  let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
            else { continue }
            list.append(entry(source, extra: nil, in: collection))
        }
        return list
    }
}

/// 一覧の 1 枚の小さい写真
struct AssetThumbnail: View {
    let asset: PHAsset?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if asset == nil {
                Image(systemName: "photo.on.rectangle").foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: asset?.localIdentifier) {
            guard let asset else { return }
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            options.resizeMode = .fast
            let side = 72 * UIScreen.main.scale
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                                  contentMode: .aspectFill, options: options) { result, _ in
                if let result { image = result }
            }
        }
    }
}

struct AlbumPage: Identifiable {
    let index: Int
    var id: Int { index }
}

struct EditorInput: Identifiable {
    let id = UUID()
    let data: Data
}

/// 写真・動画を 1 枚ずつ左右にめくって見る画面。一覧の上に重ねて表示する（別の画面として開かない）。
/// 下へなぞると背景が薄くなって下の一覧が見え、離すと写真が一覧のマスへ縮んで戻る（写真アプリと同じ）。
/// 写真は「編集」で編集画面へ。めくる画面は、表示するページだけを作る（何万件あっても重くならない）。
struct AssetViewer: View {
    let assets: PHFetchResult<PHAsset>
    let link: AssetGridLink
    let onEdit: (Data) -> Void
    /// 共有（写真と、共有ボタンの位置）
    let onShare: (PHAsset, CGRect?) -> Void
    let onDelete: (PHAsset) -> Void
    let onClose: () -> Void

    @State private var index: Int
    @State private var isLoading = false
    /// 下へなぞった量（0〜1）。背景の薄さ
    @State private var dragProgress: CGFloat = 0
    /// なぞっている間は上下のボタンを隠す
    @State private var dragging = false
    @State private var shareButtonFrame: CGRect?

    init(assets: PHFetchResult<PHAsset>, start: Int, link: AssetGridLink,
         onEdit: @escaping (Data) -> Void, onShare: @escaping (PHAsset, CGRect?) -> Void, onDelete: @escaping (PHAsset) -> Void,
         onClose: @escaping () -> Void) {
        self.assets = assets
        self.link = link
        self.onEdit = onEdit
        self.onShare = onShare
        self.onDelete = onDelete
        self.onClose = onClose
        _index = State(initialValue: start)
    }

    private var asset: PHAsset? {
        index >= 0 && index < assets.count ? assets.object(at: index) : nil
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .opacity(1 - dragProgress)
                .ignoresSafeArea()
            PhotoPageView(assets: assets, index: $index, dismissal: dismissal)
                .ignoresSafeArea()
            if !dragging {
                bars.transition(.opacity)
            }
        }
    }

    private var dismissal: PagerDismissal {
        PagerDismissal(
            began: { i in
                link.reveal(i)
                withAnimation(.easeOut(duration: 0.15)) { dragging = true }
            },
            progress: { value, duration in
                if let duration {
                    withAnimation(.easeOut(duration: duration)) { dragProgress = value }
                } else {
                    dragProgress = value
                }
            },
            target: { i in link.frame(for: i) },
            cancelled: { _ in
                link.setHidden(nil)
                withAnimation(.easeOut(duration: 0.15)) { dragging = false }
            },
            finished: {
                link.setHidden(nil)
                onClose()
            })
    }

    private var bars: some View {
        VStack(spacing: 0) {
            ZStack {
                if let date = asset?.creationDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened)).font(.footnote)
                }
                HStack {
                    Button("閉じる") { withAnimation(.easeOut(duration: 0.2)) { onClose() } }
                    Spacer()
                    // 編集は右上
                    if asset?.mediaType == .image {
                        Button(isLoading ? "読み込み中…" : "編集") { edit() }
                            .disabled(isLoading)
                            .bold()
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(.bar)
            Spacer()
            // 共有は画面のまん中。左に写真アプリ、右下に削除
            ZStack {
                Button {
                    if let asset { onShare(asset, shareButtonFrame) }
                } label: {
                    Label("共有", systemImage: "square.and.arrow.up")
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { shareButtonFrame = $0 }
                HStack(spacing: 22) {
                    Button {
                        if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
                    } label: {
                        Label("写真アプリ", systemImage: "photo.on.rectangle")
                    }
                    Spacer()
                    Button(role: .destructive) {
                        if let asset { onDelete(asset) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("削除")
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 49)
            .background(.bar)
        }
    }

    private func edit() {
        guard let item = asset else { return }
        isLoading = true
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        PHImageManager.default().requestImageDataAndOrientation(for: item, options: options) { data, _, _, _ in
            DispatchQueue.main.async {
                isLoading = false
                if let data { onEdit(data) }
            }
        }
    }
}

/// 動画の 1 ページ（写真は PhotoPageView の ZoomingPhotoController で表示する）。
struct AssetPage: View {
    let asset: PHAsset
    let isCurrent: Bool
    @State private var image: UIImage?
    @State private var player: AVPlayer?

    init(asset: PHAsset, isCurrent: Bool) {
        self.asset = asset
        self.isCurrent = isCurrent
    }

    var body: some View {
        ZStack {
            // 背景は写真の画面（AssetViewer）の側で描く（下へなぞったときに薄くするため）
            Color.clear
            if asset.mediaType == .video {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    ProgressView()
                }
            } else if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView()
            }
        }
        .task(id: asset.localIdentifier) {
            if asset.mediaType == .video {
                let options = PHVideoRequestOptions()
                options.isNetworkAccessAllowed = true
                options.deliveryMode = .automatic
                PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                    DispatchQueue.main.async {
                        guard let avAsset else {
                            Diagnostics.log("アルバム: 動画を読み込めず \(String(describing: info?[PHImageErrorKey]))")
                            return
                        }
                        let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: avAsset))
                        player = newPlayer
                        if isCurrent { newPlayer.play() }
                    }
                }
            } else {
                let options = PHImageRequestOptions()
                options.deliveryMode = .opportunistic
                options.isNetworkAccessAllowed = true
                let scale = UIScreen.main.scale
                // 拡大しても粗くならないよう、画面の 2 倍の細かさで読み込む
                let size = CGSize(width: UIScreen.main.bounds.width * scale * 2,
                                  height: UIScreen.main.bounds.height * scale * 2)
                PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFit,
                                                      options: options) { result, _ in
                    if let result { image = result }
                }
            }
        }
        .onChange(of: isCurrent) {
            if isCurrent { player?.play() } else { player?.pause() }
        }
        .onDisappear { player?.pause() }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
