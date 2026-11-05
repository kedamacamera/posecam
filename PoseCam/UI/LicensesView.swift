import SwiftUI

/// アプリが使っている他社のソフトウェアとそのライセンス。
/// Apache License 2.0 は「ライセンスの写しを渡すこと」が条件なので全文を同梱し、名前をタップすると表示する。
struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss

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
        NavigationStack {
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
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
        ScrollView {
            Text(text)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
