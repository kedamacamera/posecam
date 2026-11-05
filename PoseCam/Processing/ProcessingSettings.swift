/// プレビュー・写真・動画に共通でかける加工の設定。値はすべて 0...1。
struct ProcessingSettings: Equatable {
    var filter: PhotoFilter = .none
    /// フィルターの濃さ。0.7 がそれぞれのフィルターの標準の濃さで、1 で少しやりすぎなくらい
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

    /// 肌のマスクが必要な加工がひとつでも入っているか
    var needsSkinMask: Bool {
        smoothing > 0.01 || brightening > 0.01 || redness > 0.01 || blemish > 0.01 || wrinkle > 0.01
            || beard > 0.01 || contour > 0.01
    }
}
