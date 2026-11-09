import SwiftUI

/// 撮影後のプレビュー: 撮れた写真を画面の幅いっぱいに大きく見せる。タップで閉じる。
/// 撮影画面と、リモートモニターの両方で使う
struct CapturePreviewOverlay: View {
    let image: UIImage
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            // 画面の幅いっぱいに出す（以前は周りに余白を付けていて、撮影中の映像より小さく見えていた）
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onClose)
        .transition(.opacity)
    }
}
