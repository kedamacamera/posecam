import SwiftUI
import UIKit

/// アプリが使っている他社のソフトウェアとそのライセンス。設定の画面の中で横に送って開く（NavigationStack の中に置く）。
/// Apache License 2.0 は「ライセンスの写しを渡すこと」が条件なので全文を同梱し、名前をタップすると表示する。
struct LicensesView: View {

    private struct Entry: Identifiable {
        let name: String
        let copyright: String
        let licenseName: String
        let licenseFile: String
        var id: String { name }
    }

    private let entries = [
        Entry(name: "MediaPipe", copyright: "Copyright Google LLC",
              licenseName: "Apache License 2.0", licenseFile: "Apache-2.0"),
    ]

    var body: some View {
            List(entries) { entry in
                NavigationLink {
                    LicenseTextView(title: entry.licenseName, file: entry.licenseFile)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name)
                        Text("\(entry.copyright) / \(entry.licenseName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("ライセンス")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { Diagnostics.log("ライセンス: 画面が開いた") }
        // 外観（ダーク・ライト）は撮影画面で指定したものがそのまま引き継がれるので、ここでは指定しない
        // （開くと操作を受け付けなくなる不具合が出た版で、ここにも指定を足していた。原因の候補として外した）
    }
}

private struct LicenseTextView: View {
    let title: String
    let file: String

    private var text: String {
        guard let url = Bundle.main.url(forResource: file, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    var body: some View {
        // 全文（約 1 万字）を SwiftUI の Text（文字を選べる設定）1 つで出すと、iPhone（iOS 27.2）で
        // 開いた数秒後に画面が固まったまま戻らなかった。UIKit の UITextView で出す
        LicenseTextBox(text: text)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { Diagnostics.log("ライセンス: 全文を開いた") }
    }
}

/// 読むだけの長い文（選んでコピーはできる）
private struct LicenseTextBox: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 32, right: 12)
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.textColor = .label
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {}
}
