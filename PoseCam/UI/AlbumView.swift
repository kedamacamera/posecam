import AVKit
import Photos
import PhotosUI
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
    @State private var pickerItem: PhotosPickerItem?
    @State private var gridLink = AssetGridLink()
    /// 選択モード（選んだものを共有・削除する）
    @State private var selecting = false
    @State private var selection: Set<Int> = []
    /// 共有の画面に渡すファイル
    @State private var sharing: ShareItems?
    /// 共有用に書き出している・削除している
    @State private var working = false

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
                        Text(status == .notDetermined ? "読み込み中…" : "写真がありません")
                            .foregroundStyle(.secondary)
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
                .navigationTitle(selecting ? (selection.isEmpty ? "選んでください" : "\(selection.count) 件を選択") : "アルバム")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        // このアプリで撮っていない写真も編集できる
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Label("ほかの写真を編集", systemImage: "photo.badge.plus")
                        }
                        .disabled(selecting)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button(selecting ? "キャンセル" : "選択") {
                            selecting.toggle()
                            selection = []
                        }
                        .disabled((assets?.count ?? 0) == 0)
                    }
                }
            }
            // 写真の画面は一覧の上に重ねる（下へなぞったとき、下の一覧が透けて見えるように）
            if let page = viewing, let assets {
                AssetViewer(assets: assets, start: page.index, link: gridLink) { data in
                    viewing = nil
                    editing = EditorInput(data: data)
                } onShare: { asset in
                    share([asset])
                } onClose: {
                    viewing = nil
                }
                .transition(.opacity)
            }
            if working {
                ProgressView()
                    .padding(24)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
            }
        }
        .sheet(item: $sharing, onDismiss: { sharing?.cleanUp() }) { items in
            ActivityView(items: items) {
                items.cleanUp()
                sharing = nil
            }
            .presentationDetents([.medium, .large])
        }
        .preferredColorScheme(appearance.scheme)
        .task { await load() }
        .onChange(of: pickerItem) {
            guard let item = pickerItem else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { editing = EditorInput(data: data) }
                pickerItem = nil
            }
        }
        .fullScreenCover(item: $editing, onDismiss: { Task { await load() } }) { input in
            PhotoEditorView(data: input.data)
        }
    }

    /// 選択モードの下の帯（共有・削除）
    private var selectionBar: some View {
        HStack {
            Button {
                share(selectedAssets)
            } label: {
                Label("共有", systemImage: "square.and.arrow.up")
            }
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
    private func share(_ list: [PHAsset]) {
        guard !list.isEmpty, !working else { return }
        working = true
        Task {
            let items = await AlbumSharing.export(list)
            working = false
            if let items { sharing = items }
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

    @MainActor
    private func load() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        // 新しい順に、写真と動画をすべて（以前は 2000 件までで、古い写真が出なかった）
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d",
                                        PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        assets = PHAsset.fetchAssets(with: options)
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
    let onShare: (PHAsset) -> Void
    let onClose: () -> Void

    @State private var index: Int
    @State private var isLoading = false
    /// 下へなぞった量（0〜1）。背景の薄さ
    @State private var dragProgress: CGFloat = 0
    /// なぞっている間は上下のボタンを隠す
    @State private var dragging = false

    init(assets: PHFetchResult<PHAsset>, start: Int, link: AssetGridLink,
         onEdit: @escaping (Data) -> Void, onShare: @escaping (PHAsset) -> Void, onClose: @escaping () -> Void) {
        self.assets = assets
        self.link = link
        self.onEdit = onEdit
        self.onShare = onShare
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
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(.bar)
            Spacer()
            HStack {
                Button {
                    if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
                } label: {
                    Label("写真アプリ", systemImage: "photo.on.rectangle")
                }
                Spacer()
                Button {
                    if let asset { onShare(asset) }
                } label: {
                    Label("共有", systemImage: "square.and.arrow.up")
                }
                Spacer()
                if asset?.mediaType == .image {
                    Button(isLoading ? "読み込み中…" : "編集") { edit() }
                        .disabled(isLoading)
                        .bold()
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
