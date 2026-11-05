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

    /// 美肌・スタイルの加工だけを外した設定（比較ボタン用。フィルターは残す）
    var withoutBeauty: ProcessingSettings {
        var copy = ProcessingSettings(filter: filter, filterStrength: filterStrength, smoothing: 0, brightening: 0)
        copy.legRange = legRange
        return copy
    }
}
