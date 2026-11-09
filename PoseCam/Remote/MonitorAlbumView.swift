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

/// 1 枚ずつ大きく見る（左右にめくる）
private struct MonitorPhotoPage: View {
    let photos: [MonitorPhoto]
    @State var selection: UUID

    var body: some View {
        TabView(selection: $selection) {
            ForEach(photos) { photo in
                Image(uiImage: photo.image)
                    .resizable()
                    .scaledToFit()
                    .tag(photo.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color.black)
        .navigationBarTitleDisplayMode(.inline)
    }
}
