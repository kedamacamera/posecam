/// プレビュー・写真・動画に共通でかける加工の設定。値はすべて 0...1。
struct ProcessingSettings: Equatable {
    var filter: PhotoFilter = .none
    var smoothing: Double = 0.4
    var brightening: Double = 0.2
    /// 肌の赤みを抑える
    var redness: Double = 0
    /// シミ・ニキビ跡などの暗い点を消す
    var blemish: Double = 0
    /// シワ・ほうれい線などの暗い線を薄くする
    var wrinkle: Double = 0
    var legLength: Double = 0

    /// 肌のマスクが必要な加工がひとつでも入っているか
    var needsSkinMask: Bool {
        smoothing > 0.01 || brightening > 0.01 || redness > 0.01 || blemish > 0.01 || wrinkle > 0.01
    }
}
