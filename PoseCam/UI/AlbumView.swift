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

    var body: some View {
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
                    AssetGridView(assets: assets) { index in viewing = AlbumPage(index: index) }
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationTitle("アルバム")
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
                }
            }
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
        .fullScreenCover(item: $viewing) { page in
            AssetPager(assets: assets, start: page.index) { data in
                viewing = nil
                // 写真の画面が閉じきってから編集の画面を開く
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    editing = EditorInput(data: data)
                }
            }
        }
        .fullScreenCover(item: $editing, onDismiss: { Task { await load() } }) { input in
            PhotoEditorView(data: input.data)
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

/// 写真・動画を 1 枚ずつ左右にめくって見る。写真は「編集」で編集画面へ。
/// めくる画面は、表示するページだけを作る（何万件あっても重くならない）。
struct AssetPager: View {
    let assets: PHFetchResult<PHAsset>?
    let start: Int
    let onEdit: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(Appearance.storageKey) private var appearance: Appearance = .system
    @State private var index: Int
    @State private var isLoading = false

    private func asset(_ i: Int) -> PHAsset? {
        guard let assets, i >= 0, i < assets.count else { return nil }
        return assets.object(at: i)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let assets {
                    // 写真アプリと同じく、拡大中は写真の端まで動かしてから、さらに動かすと前後へめくれる
                    PhotoPageView(assets: assets, index: $index) { dismiss() }
                }
            }
            .background(Color(.systemBackground))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    if let date = asset(index)?.creationDate {
                        Text(date.formatted(date: .abbreviated, time: .shortened)).font(.footnote)
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
                    } label: {
                        Label("写真アプリ", systemImage: "photo.on.rectangle")
                    }
                    Spacer()
                    if asset(index)?.mediaType == .image {
                        Button(isLoading ? "読み込み中…" : "編集") { edit() }
                            .disabled(isLoading)
                            .bold()
                    }
                }
            }
        }
        .preferredColorScheme(appearance.scheme)
    }

    init(assets: PHFetchResult<PHAsset>?, start: Int, onEdit: @escaping (Data) -> Void) {
        self.assets = assets
        self.start = start
        self.onEdit = onEdit
        _index = State(initialValue: start)
    }

    private func edit() {
        guard let item = asset(index) else { return }
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
            Color(.systemBackground)
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
