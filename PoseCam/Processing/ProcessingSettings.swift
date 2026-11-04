/// プレビュー・写真・動画に共通でかける加工の設定。値はすべて 0...1。
struct ProcessingSettings: Equatable {
    var filter: PhotoFilter = .none
    var smoothing: Double = 0.4
    var brightening: Double = 0.2
    var legLength: Double = 0
}
