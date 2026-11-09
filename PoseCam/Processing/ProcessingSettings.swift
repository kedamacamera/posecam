import Foundation

/// プレビュー・写真・動画に共通でかける加工の設定。値はすべて 0...1。
struct ProcessingSettings: Equatable {
    var filter: PhotoFilter = .none
    /// フィルターの濃さ（0...2）。1 がそれぞれのフィルターの標準の濃さで、2 でその 2 倍
    var filterStrength: Double = PhotoFilter.standardStrength
    var smoothing: Double = 0.4
    var brightening: Double = 0.2
    /// 肌の赤みを抑える
    var redness: Double = 0
    /// シミ・ニキビ跡などの暗い点を消す
    var blemish: Double = 0
    /// シワ・ほうれい線などの暗い線を薄くする
    var wrinkle: Double = 0
    /// 青ひげ（ひげの剃り跡の青み）を隠す
    var beard: Double = 0
    /// あごの輪郭に影を入れて、美肌で消えたフェイスラインを出す
    var contour: Double = 0
    var legLength: Double = 0
    /// 脚長で伸ばす範囲を手で決めたとき（画像の上端 0・下端 1）。nil は骨格から自動で決める
    var legRange: ClosedRange<Double>?

    /// 肌のマスクが必要な加工がひとつでも入っているか
    var needsSkinMask: Bool {
        smoothing > 0.01 || brightening > 0.01 || redness > 0.01 || blemish > 0.01 || wrinkle > 0.01
            || beard > 0.01 || contour > 0.01
    }

    /// 人物の領域が要るか（人物以外をモノクロにするフィルター）
    var needsPersonMask: Bool { filter.needsPersonMask }

    var needsMasks: Bool { needsSkinMask || needsPersonMask }

    // MARK: - 覚えておく（アプリを開き直しても同じ加工から始める）

    private static let savedKey = "processingSettings"

    /// 前回の設定（なければ初期値）
    static func loadSaved() -> ProcessingSettings {
        guard let data = UserDefaults.standard.data(forKey: savedKey),
              let saved = try? JSONDecoder().decode(ProcessingSettings.self, from: data) else { return ProcessingSettings() }
        return saved
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.savedKey)
    }

    /// 美肌・スタイルの加工だけを外した設定（比較ボタン用。フィルターは残す）
    var withoutBeauty: ProcessingSettings {
        var copy = ProcessingSettings(filter: filter, filterStrength: filterStrength, smoothing: 0, brightening: 0)
        copy.legRange = legRange
        return copy
    }
}

/// 覚えておく項目。脚長で手で決めた範囲（legRange）は写真ごとに違うので覚えない。
/// 項目を足しても前回の保存が読めるよう、ない項目は初期値にする
extension ProcessingSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case filter, filterStrength, smoothing, brightening, redness, blemish, wrinkle, beard, contour, legLength
    }

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let raw = try c.decodeIfPresent(String.self, forKey: .filter), let value = PhotoFilter(rawValue: raw) {
            filter = value
        }
        filterStrength = try c.decodeIfPresent(Double.self, forKey: .filterStrength) ?? filterStrength
        smoothing = try c.decodeIfPresent(Double.self, forKey: .smoothing) ?? smoothing
        brightening = try c.decodeIfPresent(Double.self, forKey: .brightening) ?? brightening
        redness = try c.decodeIfPresent(Double.self, forKey: .redness) ?? redness
        blemish = try c.decodeIfPresent(Double.self, forKey: .blemish) ?? blemish
        wrinkle = try c.decodeIfPresent(Double.self, forKey: .wrinkle) ?? wrinkle
        beard = try c.decodeIfPresent(Double.self, forKey: .beard) ?? beard
        contour = try c.decodeIfPresent(Double.self, forKey: .contour) ?? contour
        legLength = try c.decodeIfPresent(Double.self, forKey: .legLength) ?? legLength
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(filter.rawValue, forKey: .filter)
        try c.encode(filterStrength, forKey: .filterStrength)
        try c.encode(smoothing, forKey: .smoothing)
        try c.encode(brightening, forKey: .brightening)
        try c.encode(redness, forKey: .redness)
        try c.encode(blemish, forKey: .blemish)
        try c.encode(wrinkle, forKey: .wrinkle)
        try c.encode(beard, forKey: .beard)
        try c.encode(contour, forKey: .contour)
        try c.encode(legLength, forKey: .legLength)
    }
}
