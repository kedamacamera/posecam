// 美肌の比較用。写真ごとに、アプリと同じ加工（FrameProcessor）をかけた結果を書き出す。
// 改善前（main）と改善後のコードの両方でこのファイルを組み立てて、同じ写真の結果を並べて比べる。
// 使い方: beauty-compare <出力フォルダ> <写真>...
// 出力: <名前>_<設定>_full.png（全体・長い辺 1600）、<名前>_<設定>_face.png（顔の周り・等倍）、<名前>_mask_face.png（美肌をかける範囲）
import CoreImage
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let outDir = URL(fileURLWithPath: args[0])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let context = CIContext()
let detector = PoseDetector()
let processor = FrameProcessor()

func save(_ image: CIImage, _ name: String) {
    let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    try? context.writePNGRepresentation(of: normalized, to: outDir.appendingPathComponent(name), format: .RGBA8,
                                        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
}

let presets: [(String, ProcessingSettings)] = {
    var standard = ProcessingSettings(filter: .none, smoothing: 0.4, brightening: 0.2)
    standard.legLength = 0
    var strong = ProcessingSettings(filter: .none, smoothing: 0.9, brightening: 0.2)
    strong.blemish = 0.6
    strong.redness = 0.5
    return [("standard", standard), ("strong", strong)]
}()

for path in args.dropFirst() {
    let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    guard let loaded = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true]) else {
        print("\(name): load failed"); continue
    }
    let image = loaded.transformed(by: CGAffineTransform(translationX: -loaded.extent.minX, y: -loaded.extent.minY))
    let analysis = detector.analyze(ciImage: image, wantsMasks: true)
    guard let masks = analysis.masks else { print("\(name): masks not found"); continue }
    let extent = image.extent
    // 顔の周り（顔がなければ中央）を切り出す
    var crop = masks.faceRegion ?? extent.insetBy(dx: extent.width * 0.25, dy: extent.height * 0.25)
    crop = crop.intersection(extent).integral
    let fullScale = min(1, 1600 / max(extent.width, extent.height))
    for (preset, settings) in presets {
        let output = processor.process(image, settings: settings, legs: nil, masks: masks)
        save(output.transformed(by: CGAffineTransform(scaleX: fullScale, y: fullScale)), "\(name)_\(preset)_full.png")
        save(output.cropped(to: crop), "\(name)_\(preset)_face.png")
    }
    save(image.cropped(to: crop), "\(name)_original_face.png")
    save(image.transformed(by: CGAffineTransform(scaleX: fullScale, y: fullScale)), "\(name)_original_full.png")
    let mask = processor.beautyMask(image, masks: masks)
        .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    save(mask.cropped(to: crop), "\(name)_mask_face.png")
    print("\(name): \(Int(extent.width))x\(Int(extent.height)), face region \(crop)")
}
