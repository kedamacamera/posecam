import SwiftUI
import UIKit

/// 画面の明るさ（設定の「外観」）。「端末に合わせる」は iPhone の設定（ダークモード）に従う。
/// 撮影画面は、プレビューの上に重なるボタン・パネルは見やすさのため常に暗い表示のままにし、
/// 上下の帯（プレビューの外）と、アルバム・ポーズ一覧などの画面がこの設定で変わる。
/// 写真の編集画面と、写真からポーズを登録する画面は、写真の色を正しく見られるよう常に暗い表示（写真アプリと同じ）。
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearance"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "端末に合わせる"
        case .light: return "ライト"
        case .dark: return "ダーク"
        }
    }

    /// preferredColorScheme に渡す値（nil は端末に合わせる）
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// アプリのすべてのウィンドウに外観を直接設定する。
    /// 設定を全画面で開くようにしてから、SwiftUI の preferredColorScheme だけでは
    /// 実機で外観が切り替わらなくなっていた（全画面の上からは後ろの画面の指定が届かない）
    @MainActor
    func applyToWindows() {
        let style: UIUserInterfaceStyle
        switch self {
        case .system: style = .unspecified
        case .light: style = .light
        case .dark: style = .dark
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { window.overrideUserInterfaceStyle = style }
        }
    }
}

/// 撮影画面の上下の帯（プレビューの外）の色。ダークでは今までどおり黒地に白、ライトでは明るい灰色の地に黒。
/// SwiftUI の colorScheme（環境）に合わせて決まるので、プレビューの上に重なる所は .dark を指定すれば白のまま。
extension Color {
    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .light ? light : dark })
    }

    /// 帯の地の色
    static let chromeBackground = dynamic(light: UIColor(white: 0.96, alpha: 1), dark: .black)
    /// 帯の上の文字・アイコン
    static let chromeText = dynamic(light: UIColor(white: 0.08, alpha: 1), dark: .white)
    /// 選んでいる項目（ダークでは黄色、ライトでは白地でも読める濃い黄色）
    static let chromeAccent = dynamic(light: UIColor(red: 0.78, green: 0.52, blue: 0, alpha: 1), dark: .systemYellow)
    /// 文字の影（映像の上で読みやすくするため。ライトの帯では付けない）
    static let chromeShadow = dynamic(light: .clear, dark: UIColor(white: 0, alpha: 0.5))
}
