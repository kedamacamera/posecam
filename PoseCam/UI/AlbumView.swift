import AVKit
import Photos
import PhotosUI
import SwiftUI

/// アプリ内のアルバム。端末の写真・動画を新しい順に並べる（写真ライブラリの読み取りの許可が要る）。
/// 写真をタップすると大きく表示し、「編集」で傾き補正・伸縮・肌の補正ができる。
struct AlbumView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var assets: [PHAsset] = []
    @State private var status: PHAuthorizationStatus = .notDetermined
    @State private var viewing: AlbumPage?
    @State private var editing: EditorInput?
    @State private var pickerItem: PhotosPickerItem?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 2)]

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
                } else if assets.isEmpty {
                    Text(status == .notDetermined ? "読み込み中…" : "写真がありません")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(assets.indices, id: \.self) { index in
                                AssetThumbnail(asset: assets[index])
                                    .onTapGesture { viewing = AlbumPage(index: index) }
                            }
                        }
                    }
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
        .preferredColorScheme(.dark)
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
                editing = EditorInput(data: data)
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
        // 新しい順に、写真と動画を最大 2000 件
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d",
                                        PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        options.fetchLimit = 2000
        let result = PHAsset.fetchAssets(with: options)
        var list: [PHAsset] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in list.append(asset) }
        assets = list
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

/// 一覧の 1 マス。動画には再生のマークを付ける。
struct AssetThumbnail: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        Color.gray.opacity(0.2)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if asset.mediaType == .video {
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(5)
                        .shadow(radius: 2)
                }
            }
            .task(id: asset.localIdentifier) {
                let options = PHImageRequestOptions()
                options.deliveryMode = .opportunistic
                options.isNetworkAccessAllowed = true
                PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 300, height: 300),
                                                      contentMode: .aspectFill, options: options) { result, _ in
                    if let result { image = result }
                }
            }
    }
}

/// 写真・動画を 1 枚ずつ左右にめくって見る。写真は「編集」で編集画面へ。
struct AssetPager: View {
    let assets: [PHAsset]
    let start: Int
    let onEdit: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            TabView(selection: $index) {
                ForEach(assets.indices, id: \.self) { i in
                    AssetPage(asset: assets[i], isCurrent: i == index)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(Color.black)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    if let date = assets[safe: index]?.creationDate {
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
                    if assets[safe: index]?.mediaType == .image {
                        Button(isLoading ? "読み込み中…" : "編集") { edit() }
                            .disabled(isLoading)
                            .bold()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { index = start }
    }

    private func edit() {
        guard let asset = assets[safe: index] else { return }
        isLoading = true
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
            DispatchQueue.main.async {
                isLoading = false
                if let data { onEdit(data) }
            }
        }
    }
}

/// 1 ページ。写真は画面いっぱいに、動画は再生できるように表示する。
struct AssetPage: View {
    let asset: PHAsset
    let isCurrent: Bool
    @State private var image: UIImage?
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black
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
                PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                    DispatchQueue.main.async { player = item.map { AVPlayer(playerItem: $0) } }
                }
            } else {
                let options = PHImageRequestOptions()
                options.deliveryMode = .opportunistic
                options.isNetworkAccessAllowed = true
                let scale = UIScreen.main.scale
                let size = CGSize(width: UIScreen.main.bounds.width * scale, height: UIScreen.main.bounds.height * scale)
                PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFit,
                                                      options: options) { result, _ in
                    if let result { image = result }
                }
            }
        }
        .onChange(of: isCurrent) { if !isCurrent { player?.pause() } }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
