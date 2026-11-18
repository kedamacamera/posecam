// 顔の形の補正（小顔・目・鼻）の確認用。顔の 478 点が顔に合っているかと、補正の結果を書き出す。
// 使い方: reshape-check <出力フォルダ> <写真>...
// 出力: <名前>_points.png（点を描いた顔の周り）、<名前>_reshape_<設定>.png（顔の周り）
import CoreImage
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let outDir = URL(fileURLWithPath: args[0])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let context = CIContext()
let detector = PoseDetector()
let processor = FrameProcessor()
print("face mesh model loaded: \(PoseDetector.hasFaceMeshModel), warp kernel loaded: \(FaceReshape.kernel != nil)")

func save(_ image: CIImage, _ name: String) {
    let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    try? context.writePNGRepresentation(of: normalized, to: outDir.appendingPathComponent(name), format: .RGBA8,
                                        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
}

func reshape(_ slim: Double, _ eye: Double, _ nose: Double) -> ProcessingSettings {
    var settings = ProcessingSettings(filter: .none, smoothing: 0, brightening: 0)
    settings.faceSlim = slim
    settings.eyeSize = eye
    settings.noseSlim = nose
    return settings
}
let presets: [(String, ProcessingSettings)] = [
    ("slim", reshape(1, 0, 0)), ("eyes", reshape(0, 1, 0)), ("nose", reshape(0, 0, 1)), ("all", reshape(0.6, 0.5, 0.5)),
]

for path in args.dropFirst() {
    let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    guard let loaded = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true]) else { continue }
    let image = loaded.transformed(by: CGAffineTransform(translationX: -loaded.extent.minX, y: -loaded.extent.minY))
    guard let masks = detector.analyze(ciImage: image, wantsMasks: true, wantsMesh: true).masks,
          let mesh = masks.faceMeshes.first else {
        print("\(name): no face mesh"); continue
    }
    let xs = mesh.map(\.x), ys = mesh.map(\.y)
    let faceBox = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    let crop = faceBox.insetBy(dx: -faceBox.width * 0.35, dy: -faceBox.height * 0.35).intersection(image.extent).integral
    // 点を描く（輪郭・目・鼻の補正に使う点は赤、それ以外は緑）
    let used: Set<Int> = [234, 454, 132, 58, 172, 136, 361, 288, 397, 365, 468, 473, 33, 133, 362, 263, 129, 358, 4]
    let dot = max(1.5, faceBox.width * 0.006)
    var overlay = image
    for (i, p) in mesh.enumerated() {
        let color = used.contains(i) ? CIColor(red: 1, green: 0.1, blue: 0.1) : CIColor(red: 0.1, green: 1, blue: 0.3)
        let r = used.contains(i) ? dot * 2 : dot
        overlay = CIImage(color: color).cropped(to: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            .composited(over: overlay)
    }
    save(image.cropped(to: crop), "\(name)_original.png")
    save(overlay.cropped(to: crop), "\(name)_points.png")
    for (preset, settings) in presets {
        save(processor.process(image, settings: settings, legs: nil, masks: masks).cropped(to: crop), "\(name)_reshape_\(preset).png")
    }
    print("\(name): \(masks.faceMeshes.count) face(s), face box \(faceBox)")
}
