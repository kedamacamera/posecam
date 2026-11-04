import SwiftUI

/// アプリが使っている他社のモデル・素材とそのライセンス。
struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss

    private var apacheText: String {
        guard let url = Bundle.main.url(forResource: "Apache-2.0", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("MediaPipe Selfie Multiclass Segmentation")
                            .font(.headline)
                        Text("美肌の肌の判定に、Google LLC の MediaPipe のモデル（selfie_multiclass_256x256）を Core ML 形式に変換して使用しています。")
                        Text("Copyright Google LLC. Licensed under the Apache License, Version 2.0.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ポーズの見本写真")
                            .font(.headline)
                        Text("組み込みポーズの見本写真は AI で生成した画像です。実在の人物ではありません。")
                    }
                    Divider()
                    Text(apacheText)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding()
            }
            .navigationTitle("ライセンス")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
