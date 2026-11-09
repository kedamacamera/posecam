import SwiftUI

/// 撮影後のプレビュー: 撮れた写真を画面いっぱいに大きく見せる。タップで閉じる。
/// 撮影画面と、リモートモニターの両方で使う
struct CapturePreviewOverlay: View {
    let image: UIImage
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(24)
                .shadow(color: .black.opacity(0.5), radius: 10)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onClose)
        .transition(.opacity)
    }
}
