// アプリと同じ加工・判定のコードを Mac で動かして、結果を画像と数値で確かめる。
// GitHub Actions の verify-processing ワークフローから実行する（iPhone がなくても確認できるように）。
//
// 出力（out/ 以下）:
//   beauty_<名前>.png  … 左から 加工前 / 加工後 / 肌のマスク
//   report.txt         … 肌の平均の明るさ（加工前・後）と、一致度の採点の確認結果

import AppKit
import CoreImage
import Foundation

let context = CIContext()
let outDir = URL(fileURLWithPath: "out", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
var report: [String] = []

func load(_ path: String) -> CIImage {
    guard let image = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true]) else {
        fatalError("cannot load \(path)")
    }
    return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
}

/// マスクの白い部分だけの平均の明るさ（0〜1、sRGB）
func meanLuma(_ image: CIImage, mask: CIImage) -> Double {
    let extent = image.extent
    let black = CIImage(color: .black).cropped(to: extent)
    let masked = image.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: black, kCIInputMaskImageKey: mask,
    ])
    func average(_ input: CIImage) -> [Double] {
        let avg = input.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: extent)])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(avg, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return pixel.map(Double.init)
    }
    let sum = average(masked)
    let weight = average(mask)[1]
    guard weight > 1e-4 else { return 0 }
    return (0.299 * sum[0] + 0.587 * sum[1] + 0.114 * sum[2]) / weight
}

func savePNG(_ image: CIImage, _ name: String) {
    let url = outDir.appendingPathComponent(name)
    try? context.writePNGRepresentation(of: image, to: url, format: .RGBA8,
                                        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
}

// MARK: - 美肌

let detector = PoseDetector()
let processor = FrameProcessor()
report.append("skin model loaded: \(PoseDetector.hasSkinModel)")

for path in CommandLine.arguments.dropFirst() {
    let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    let image = load(path)
    let analysis = detector.analyze(ciImage: image, wantsMasks: true)
    guard let masks = analysis.masks else {
        report.append("\(name): masks not found")
        continue
    }
    var settings = ProcessingSettings()
    settings.smoothing = 0.8
    settings.brightening = 0.3
    let output = processor.process(image, settings: settings, hipY: nil, masks: masks)

    let skin = masks.skin ?? masks.person!
    let before = meanLuma(image, mask: skin)
    let after = meanLuma(output, mask: skin)
    report.append(String(format: "%@: skin luma before %.3f after %.3f (diff %+.3f), features mask: %@",
                         name, before, after, after - before, masks.features == nil ? "none" : "yes"))

    let width = image.extent.width
    let maskView = skin.applyingFilter("CIColorMatrix", parameters: [
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
    ]).cropped(to: image.extent)
    let sheet = output.transformed(by: CGAffineTransform(translationX: width, y: 0))
        .composited(over: maskView.transformed(by: CGAffineTransform(translationX: width * 2, y: 0)))
        .composited(over: image)
    let scale = 1600 / (width * 3)
    savePNG(sheet.transformed(by: CGAffineTransform(scaleX: scale, y: scale)), "beauty_\(name).png")
}

// MARK: - 一致度

if let first = CommandLine.arguments.dropFirst().first,
   let pose = detector.detect(ciImage: load(first)) {
    let image = load(first)
    let aspect = image.extent.width / image.extent.height
    let iso = pose.mapValues { PoseSpace.toIsotropic($0, aspect: aspect) }
    func shifted(_ dx: CGFloat, _ dy: CGFloat, scale: CGFloat = 1) -> [Joint: CGPoint] {
        iso.mapValues { CGPoint(x: $0.x * scale + dx, y: ($0.y - 0.5) * scale + 0.5 + dy) }
    }
    var rotatedArm = iso
    if let elbow = iso[.leftElbow], let wrist = iso[.leftWrist] {
        // 前腕を 60 度回す
        let angle = CGFloat.pi / 3
        let v = CGPoint(x: wrist.x - elbow.x, y: wrist.y - elbow.y)
        rotatedArm[.leftWrist] = CGPoint(x: elbow.x + v.x * cos(angle) - v.y * sin(angle),
                                         y: elbow.y + v.x * sin(angle) + v.y * cos(angle))
    }
    let cases: [(String, [Joint: CGPoint])] = [
        ("same pose", iso),
        ("shifted 10% right", shifted(0.1, 0)),
        ("shifted 25% right", shifted(0.25, 0)),
        ("80% size", shifted(0, 0, scale: 0.8)),
        ("left forearm rotated 60deg", rotatedArm),
    ]
    report.append("match test (joints: \(pose.count)):")
    for (label, detected) in cases {
        let score = PoseMatcher.score(template: iso, detected: detected).map { String(format: "%.1f", $0) } ?? "nil"
        report.append("  \(label): \(score)")
    }
}

let text = report.joined(separator: "\n")
print(text)
try? text.write(to: outDir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
