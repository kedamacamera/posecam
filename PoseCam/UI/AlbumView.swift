import AVKit
import Photos
import SwiftUI

/// アプリ内のアルバム。端末の写真・動画を新しい順に並べる（写真ライブラリの読み取りの許可が要る）。
/// 写真をタップすると大きく表示し、「編集」で傾き補正・伸縮・肌の補正ができる。
struct AlbumView: View {
    @Environment(\.dismiss) private var dismiss
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
    /// アルバムを切り替えて、中身を読み込んでいる（前のアルバムを出したままにせず「読み込み中」を出す）
    @State private var switching = false
    /// 読み込みの番号。切り替えを続けて押したとき、古い読み込みの結果で上書きしない
    @State private var loadGeneration = 0
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
                    } else if switching || status == .notDetermined {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("読み込み中…").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if (assets?.count ?? 0) == 0 {
                        Text(emptyText)
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
                        // アルバムごとに作り直す（切り替えたら一番上から表示する）
                        .id(source.id)
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
                            if source != .all && !selecting {
                                // アルバムを開いているときは、閉じずに「最近の項目」へ戻る
                                Button {
                                    switchSource(to: .all)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                                        Text("戻る")
                                    }
                                }
                                .disabled(working)
                            } else {
                                Button("閉じる") { dismiss() }
                            }
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
                            .disabled((assets?.count ?? 0) == 0 || switching)
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
        .task { await load(quick: true) }
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
                switchSource(to: entry.source)
            } label: {
                AlbumEntryRow(entry: entry, selected: entry.source == source)
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

    /// 表示するアルバムを替える。前のアルバムの一覧は消して、すぐ「読み込み中」を出す
    private func switchSource(to newSource: AlbumSource) {
        source = newSource
        selection = []
        selecting = false
        assets = nil
        switching = true
        Task { await load(quick: true) }
    }

    /// 写真ライブラリから読み込む。重い問い合わせは裏のスレッドで行い、画面を止めない。
    /// quick のときは、まず新しいほうの数百件だけを読んですぐ表示し、続けて全部を読んで差し替える
    /// （写真の多い iPhone では、全部を読み終えるまで数秒〜数十秒かかっていた）
    @MainActor
    private func load(quick: Bool = false) async {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        status = current == .notDetermined ? await PHPhotoLibrary.requestAuthorization(for: .readWrite) : current
        guard status == .authorized || status == .limited else { switching = false; return }
        // 初めて開いたときも、読み終わるまでは「写真がありません」ではなく「読み込み中」を出す
        if quick && assets == nil { switching = true }
        loadGeneration += 1
        let generation = loadGeneration
        let target = source
        if quick {
            let first = await Task.detached(priority: .userInitiated) {
                AssetFetch(result: AlbumView.fetch(target, limit: AlbumView.quickCount))
            }.value
            guard generation == loadGeneration else { return }
            if first.missing { source = .all; switching = false; await load(quick: true); return }
            assets = first.result
            switching = false
            // 全部で数百件より少なければ、もう読み終わっている
            if (first.result?.count ?? 0) < AlbumView.quickCount { return }
        }
        let all = await Task.detached(priority: .userInitiated) {
            AssetFetch(result: AlbumView.fetch(target, limit: nil))
        }.value
        guard generation == loadGeneration else { return }
        if all.missing {
            // 選んでいたアルバムが消えていたら「最近の項目」に戻す
            source = .all
            await load(quick: true)
            return
        }
        assets = all.result
        switching = false
    }

    /// 最初に読んで表示する件数（数画面分）
    nonisolated static let quickCount = 300

    /// アルバムの中身（新しい順）。自分で作ったアルバムが消えていたら .missing を返す（裏のスレッドで呼ぶ）
    nonisolated static func fetch(_ source: AlbumSource, limit: Int?) -> AssetFetch.Outcome {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if let limit { options.fetchLimit = limit }
        let image = PHAssetMediaType.image.rawValue, video = PHAssetMediaType.video.rawValue
        switch source {
        case .all:
            options.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d", image, video)
            return .found(PHAsset.fetchAssets(with: options))
        case .favorites:
            options.predicate = NSPredicate(format: "(mediaType == %d || mediaType == %d) && favorite == YES", image, video)
            return .found(PHAsset.fetchAssets(with: options))
        case .videos:
            options.predicate = NSPredicate(format: "mediaType == %d", video)
            return .found(PHAsset.fetchAssets(with: options))
        case .poseCam:
            return .found(MediaSaver.existingAlbum().map { PHAsset.fetchAssets(in: $0, options: options) })
        case .album(let id, _):
            guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
            else { return .missing }
            return .found(PHAsset.fetchAssets(in: album, options: options))
        }
    }
}

/// 裏のスレッドで読んだアルバムの中身を、画面のスレッドへ渡す入れ物
/// （PHFetchResult はどのスレッドから読んでもよい）
struct AssetFetch: @unchecked Sendable {
    enum Outcome { case found(PHFetchResult<PHAsset>?), missing }
    let outcome: Outcome
    init(result: Outcome) { outcome = result }
    var result: PHFetchResult<PHAsset>? { if case .found(let r) = outcome { return r } else { return nil } }
    var missing: Bool { if case .missing = outcome { return true } else { return false } }
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
                // 中身の数は数えずに、写真ライブラリが覚えているおおよその数で空のアルバムを除く
                // （以前は 1 つずつ数えていて、写真の多い iPhone では一覧が出るまで 30 秒以上かかった）
                guard title != MediaSaver.albumTitle, !title.isEmpty,
                      collection.estimatedAssetCount != 0 else { return }
                list.append(.album(collection.localIdentifier, title))
            }
        return list
    }
}

/// アルバムの一覧の 1 行。一覧はすぐに出し、表紙と写真・動画の数は行ごとに裏で数える
/// （写真の多い iPhone で、全部数えてから一覧を出すと 30 秒以上かかっていた）
struct AlbumEntry: Identifiable {
    let source: AlbumSource
    var id: String { source.id }

    /// 最近の項目・お気に入り・動画・PoseCam・自分で作ったアルバム
    static func all() -> [AlbumEntry] {
        var list: [AlbumSource] = [.all, .favorites, .videos]
        if MediaSaver.existingAlbum() != nil { list.append(.poseCam) }
        list += AlbumSource.userAlbums()
        return list.map { AlbumEntry(source: $0) }
    }

    /// 写真・動画の数と表紙（裏のスレッドで呼ぶ）
    static func details(of source: AlbumSource) -> (photos: Int, videos: Int, cover: PHAsset?) {
        let image = PHAssetMediaType.image.rawValue, video = PHAssetMediaType.video.rawValue
        func options(_ format: String, _ args: [Any], newest: Bool = false) -> PHFetchOptions {
            let o = PHFetchOptions()
            o.predicate = NSPredicate(format: format, argumentArray: args)
            if newest {
                o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                o.fetchLimit = 1
            }
            return o
        }
        var collection: PHAssetCollection?
        var extra = ""
        switch source {
        case .all: break
        case .favorites: extra = " && favorite == YES"
        case .videos:
            let videos = PHAsset.fetchAssets(with: options("mediaType == %d", [video])).count
            let cover = PHAsset.fetchAssets(with: options("mediaType == %d", [video], newest: true)).firstObject
            return (0, videos, cover)
        case .poseCam: collection = MediaSaver.existingAlbum()
        case .album(let id, _):
            collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
        }
        func fetch(_ o: PHFetchOptions) -> PHFetchResult<PHAsset> {
            collection.map { PHAsset.fetchAssets(in: $0, options: o) } ?? PHAsset.fetchAssets(with: o)
        }
        let photos = fetch(options("mediaType == %d" + extra, [image])).count
        let videos = fetch(options("mediaType == %d" + extra, [video])).count
        let cover = fetch(options("(mediaType == %d || mediaType == %d)" + extra, [image, video], newest: true)).firstObject
        return (photos, videos, cover)
    }
}

/// アルバムの一覧の 1 行の中身（表紙・名前・数）。数え終わるまでは「…」
struct AlbumEntryRow: View {
    let entry: AlbumEntry
    let selected: Bool
    @State private var details: (photos: Int, videos: Int, cover: PHAsset?)?

    var body: some View {
        HStack(spacing: 16) {
            AssetThumbnail(asset: details?.cover)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.source.title)
                    .font(.body)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(details.map { "\($0.photos) 枚の写真と \($0.videos) 件の動画" } ?? "…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
            }
        }
        .task(id: entry.id) {
            let source = entry.source
            let result = await Task.detached(priority: .userInitiated) { AlbumEntry.details(of: source) }.value
            details = result
        }
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
