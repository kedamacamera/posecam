// アプリと同じ加工・判定のコードを Mac で動かして、結果を画像と数値で確かめる。
// GitHub Actions の verify-processing ワークフローから実行する（iPhone がなくても確認できるように）。
//
// 出力（out/ 以下）:
//   beauty_<名前>.png  … 左から 加工前 / 加工後 / 肌のマスク
//   report.txt         … 肌の平均の明るさ（加工前・後）と、一致度の採点の確認結果

import AppKit
import CoreImage
import Foundation
import ImageIO
import Vision

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

/// 顔に赤い点（ニキビ）と小鼻の横の赤みを描き足した画像を作る（赤み消しの確認用）。
/// 実在の人の写真を使わずに確認できるよう、AI の見本写真に人工的に描く。
func addRedSpots(_ image: CIImage, pose: [Joint: CGPoint]) -> CIImage {
    guard let nose = pose[.nose], let ls = pose[.leftShoulder], let rs = pose[.rightShoulder] else { return image }
    let w = image.extent.width, h = image.extent.height
    let unit = abs(ls.x - rs.x) * w / 4  // だいたい顔の幅の半分
    let center = CGPoint(x: nose.x * w, y: (1 - nose.y) * h)
    // (横, 縦, 半径) を顔の大きさの単位で
    let spots: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (-0.55, -0.15, 0.06, 0.55), (0.6, -0.25, 0.05, 0.55), (0.45, 0.05, 0.04, 0.5),
        (-0.2, 0.75, 0.05, 0.5), (0.1, -0.7, 0.05, 0.55),
        (-0.22, -0.02, 0.10, 0.35), (0.22, -0.02, 0.10, 0.35),  // 小鼻の横の赤み
    ]
    var result = image
    for (dx, dy, r, alpha) in spots {
        let gradient = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: center.x + dx * unit, y: center.y + dy * unit),
            "inputRadius0": r * unit * 0.3,
            "inputRadius1": r * unit,
            "inputColor0": CIColor(red: 0.85, green: 0.15, blue: 0.2, alpha: alpha),
            "inputColor1": CIColor(red: 0.85, green: 0.15, blue: 0.2, alpha: 0),
        ])!.outputImage!.cropped(to: image.extent)
        result = gradient.composited(over: result)
    }
    return result
}

// MARK: - 美肌

let detector = PoseDetector()
let processor = FrameProcessor()
report.append("skin model loaded: \(PoseDetector.hasSkinModel), bilateral kernel loaded: \(FrameProcessor.bilateralKernel != nil), dark spot kernel loaded: \(FrameProcessor.darkSpotKernel != nil), redness kernel loaded: \(FrameProcessor.rednessKernel != nil)")

var inputs: [(String, CIImage)] = CommandLine.arguments.dropFirst().map {
    (URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent, load($0))
}
// 2 枚目以降（上半身の写真）に赤い点を描き足したものも確かめる
for (name, image) in inputs.dropFirst() {
    if let pose = detector.detect(ciImage: image) {
        inputs.append((name + "_redspots", addRedSpots(image, pose: pose)))
    }
}

for (name, image) in inputs {
    let analysis = detector.analyze(ciImage: image, wantsMasks: true)
    guard let masks = analysis.masks else {
        report.append("\(name): masks not found")
        continue
    }
    var settings = ProcessingSettings()
    settings.smoothing = 0.8
    settings.brightening = 0.3
    settings.redness = 0.8
    settings.blemish = 0.8
    settings.wrinkle = 0.8
    let output = processor.process(image, settings: settings, hipY: nil, masks: masks)

    let skin = masks.skin ?? masks.person!
    let before = meanLuma(image, mask: skin)
    let after = meanLuma(output, mask: skin)
    report.append(String(format: "%@: skin luma before %.3f after %.3f (diff %+.3f), features mask: %@",
                         name, before, after, after - before, masks.features == nil ? "none" : "yes"))

    let width = image.extent.width
    // 実際に美肌をかけた範囲（肌 × 顔のパーツの除外）と、赤み消しの範囲
    func opaque(_ mask: CIImage) -> CIImage {
        mask.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
            .cropped(to: image.extent)
    }
    let maskView = opaque(processor.beautyMask(image, masks: masks))
    let redView = opaque(processor.rednessMask(image, masks: masks))
    let sheet = output.transformed(by: CGAffineTransform(translationX: width, y: 0))
        .composited(over: maskView.transformed(by: CGAffineTransform(translationX: width * 2, y: 0)))
        .composited(over: redView.transformed(by: CGAffineTransform(translationX: width * 3, y: 0)))
        .composited(over: image)
    let scale = 2000 / (width * 4)
    savePNG(sheet.transformed(by: CGAffineTransform(scaleX: scale, y: scale)), "beauty_\(name).png")

    // 顔のまわりを拡大して、加工前（左）と加工後（右）を並べる
    if let nose = analysis.pose?[.nose] {
        let side = width * 0.4
        let center = CGPoint(x: nose.x * width, y: (1 - nose.y) * image.extent.height)
        let rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        let toOrigin = CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
        let left = image.cropped(to: rect).transformed(by: toOrigin)
        let right = output.cropped(to: rect).transformed(by: toOrigin.concatenating(CGAffineTransform(translationX: side, y: 0)))
        let face = right.composited(over: left)
        let faceScale = 1600 / (side * 2)
        savePNG(face.transformed(by: CGAffineTransform(scaleX: faceScale, y: faceScale)), "face_\(name).png")

        // 赤い点を描いた画像では、項目を 1 つずつかけた結果も並べる（どの処理が何を変えたか確かめる）
        if name.hasSuffix("_redspots") {
            let steps: [(String, WritableKeyPath<ProcessingSettings, Double>)] = [
                ("smoothing", \.smoothing), ("brightening", \.brightening), ("redness", \.redness),
                ("blemish", \.blemish), ("wrinkle", \.wrinkle),
            ]
            var strip = left
            for (i, step) in steps.enumerated() {
                var single = ProcessingSettings(filter: .none, smoothing: 0, brightening: 0)
                single[keyPath: step.1] = 0.8
                let out = processor.process(image, settings: single, hipY: nil, masks: masks)
                strip = out.cropped(to: rect).transformed(by: toOrigin.concatenating(
                    CGAffineTransform(translationX: side * CGFloat(i + 1), y: 0))).composited(over: strip)
            }
            let stripScale = 2400 / (side * 6)
            savePNG(strip.transformed(by: CGAffineTransform(scaleX: stripScale, y: stripScale)), "steps_\(name).png")
            report.append("steps_\(name): original, " + steps.map(\.0).joined(separator: ", "))
        }
    }
}

// MARK: - 青ひげ・輪郭

/// 鼻の下〜あごに、青みがかった剃り跡（細かい点々＋青黒いくすみ）を描き足す（実在の人の写真を使わずに確かめる）。
func addStubble(_ image: CIImage, pose: [Joint: CGPoint]) -> CIImage {
    guard let nose = pose[.nose], let ls = pose[.leftShoulder], let rs = pose[.rightShoulder] else { return image }
    let w = image.extent.width, h = image.extent.height
    let unit = abs(ls.x - rs.x) * w / 4
    let center = CGPoint(x: nose.x * w, y: (1 - nose.y) * h - unit * 0.75)
    // 口のまわり〜あごを覆う楕円（下ほど濃い）
    let shade = CIFilter(name: "CIRadialGradient", parameters: [
        "inputCenter": CIVector(x: center.x, y: center.y),
        "inputRadius0": unit * 0.25,
        "inputRadius1": unit * 0.75,
        "inputColor0": CIColor(red: 0.30, green: 0.34, blue: 0.44, alpha: 0.32),
        "inputColor1": CIColor(red: 0.30, green: 0.34, blue: 0.44, alpha: 0),
    ])!.outputImage!.transformed(by: CGAffineTransform(translationX: -center.x, y: -center.y)
        .concatenating(CGAffineTransform(scaleX: 1.15, y: 0.8))
        .concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
        .cropped(to: image.extent)
    // 毛穴ほどの細かい点（ランダム）を、楕円の濃さで混ぜる
    let dots = CIFilter(name: "CIRandomGenerator")!.outputImage!
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0.5, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0.25, y: 0.27, z: 0.34, w: -0.32),
        ])
        // 負の値（真っ黒な点）にならないよう 0〜1 に収める。点の濃さは最大 0.18
        .applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 0.18),
        ])
        .cropped(to: image.extent)
        .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: shade])
    return dots.composited(over: shade.composited(over: image))
}

report.append("beard kernel loaded: \(FrameProcessor.beardKernel != nil), direct flash kernel: n/a in verifier")
for (name, original) in inputs.prefix(4) where !name.hasSuffix("_redspots") {
    guard let pose = detector.detect(ciImage: original) else { continue }
    let image = addStubble(original, pose: pose)
    let analysis = detector.analyze(ciImage: image, wantsMasks: true)
    guard let masks = analysis.masks, let nose = analysis.pose?[.nose] else { continue }
    var settings = ProcessingSettings(filter: .none, smoothing: 0, brightening: 0)
    settings.beard = 1
    let concealed = processor.process(image, settings: settings, hipY: nil, masks: masks)
    settings.smoothing = 0.8
    settings.contour = 0.8
    let full = processor.process(image, settings: settings, hipY: nil, masks: masks)
    var smoothOnly = ProcessingSettings(filter: .none, smoothing: 0.8, brightening: 0)
    smoothOnly.contour = 0
    let smoothed = processor.process(image, settings: smoothOnly, hipY: nil, masks: masks)

    let width = image.extent.width
    let side = width * 0.4
    let c = CGPoint(x: nose.x * width, y: (1 - nose.y) * image.extent.height - side * 0.15)
    let rect = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
    let toOrigin = CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
    let beardView = (processor.beardMask(image, masks: masks) ?? CIImage(color: .black))
        .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    var strip = CIImage.empty()
    let debugView = processor.beardDebug(image, masks: masks) ?? CIImage(color: .black)
    for (i, panel) in [original, image, concealed, beardView, debugView, full].enumerated() {
        strip = panel.cropped(to: rect).transformed(by: toOrigin.concatenating(
            CGAffineTransform(translationX: side * CGFloat(i), y: 0))).composited(over: strip)
    }
    let scale = 2400 / (side * 6)
    savePNG(strip.transformed(by: CGAffineTransform(scaleX: scale, y: scale)), "beard_\(name).png")
    if let beard = processor.beardMask(image, masks: masks) {
        func chroma(_ img: CIImage) -> String {
            let v = meanColor(img, mask: beard)
            return String(format: "Y %.3f Cb %+.3f Cr %+.3f", v.y, v.cb, v.cr)
        }
        report.append("beard_\(name): original [\(chroma(original))] stubble [\(chroma(image))] concealed [\(chroma(concealed))]")
    }
    report.append("beard_\(name): original, stubble added, beard 100, beard mask, debug (R=w, G=ref skin x10, B=bluish x10), smoothing 80 + beard + contour 80")
}

// MARK: - ダイレクトフラッシュ
// 実写のフラッシュ写真は用意できないので、見本写真を「周りの光だけのコマ」とみなし、
// 人の所にだけフラッシュの光（元の明るさの 1.5 倍ぶん）を足した画像を「フラッシュ写真」として確かめる。
// 期待: 背景（周りの光だけ）は 1/4 の明るさに、人（ほとんどフラッシュの光）は少しだけ暗くなる。
report.append("direct flash kernel loaded: \(DirectFlash.kernel != nil)")
if let (name, ambient) = inputs.first, let person = personMask(ambient) {
    let flashLight = ambient.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 1.5, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1.5, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 1.5, w: 0),
    ]).applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: person])
    let flashPhoto = flashLight.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: ambient])
        .cropped(to: ambient.extent)
    let result = DirectFlash.apply(photo: flashPhoto, ambient: ambient, exposureRatio: 1)
    let background = person.applyingFilter("CIColorInvert")
    report.append(String(format: "direct flash %@: person luma %.3f -> %.3f, background luma %.3f -> %.3f",
                         name, meanLuma(flashPhoto, mask: person), meanLuma(result, mask: person),
                         meanLuma(flashPhoto, mask: background), meanLuma(result, mask: background)))
    let w = ambient.extent.width
    let sheet = flashPhoto.transformed(by: CGAffineTransform(translationX: w, y: 0))
        .composited(over: result.transformed(by: CGAffineTransform(translationX: w * 2, y: 0)))
        .composited(over: ambient)
    let scale = 1800 / (w * 3)
    savePNG(sheet.transformed(by: CGAffineTransform(scaleX: scale, y: scale)), "directflash.png")
    report.append("directflash.png: ambient frame, flash photo, direct flash result")
}

// MARK: - 無音撮影の Exif
// 映像のコマに付く Exif（実機の例と同じ形）から作った情報が、保存した JPEG に入っているか確かめる。
do {
    let frameExif: [String: Any] = [
        kCGImagePropertyExifExposureTime as String: 1.0 / 60,
        kCGImagePropertyExifFNumber as String: 1.78,
        kCGImagePropertyExifISOSpeedRatings as String: [200],
        kCGImagePropertyExifFocalLength as String: 6.765,
        kCGImagePropertyExifLensModel as String: "iPhone 15 Pro Max back triple camera 6.765mm f/1.78",
    ]
    let metadata = PhotoMetadata.forVideoFrame(exif: frameExif, position: .back)
    if let image = inputs.first?.1, let jpeg = PhotoMetadata.jpeg(image, metadata: metadata, context: context),
       let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
       let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        report.append("silent exif: Make=\(tiff["Make"] ?? "-") Model=\(tiff["Model"] ?? "-") "
            + "LensMake=\(exif["LensMake"] ?? "-") LensModel=\(exif["LensModel"] ?? "-") "
            + "FNumber=\(exif["FNumber"] ?? "-") ISO=\(exif["ISOSpeedRatings"] ?? "-") "
            + "Size=\(exif["PixelXDimension"] ?? "-")x\(exif["PixelYDimension"] ?? "-") Orientation=\(props["Orientation"] ?? "-")")
    } else {
        report.append("silent exif: failed to write")
    }
}

/// 人の領域（白）。美肌のマスクは肌のモデルを優先するので、ここでは人物の判定を直接使う
func personMask(_ image: CIImage) -> CIImage? {
    let request = VNGeneratePersonSegmentationRequest()
    request.qualityLevel = .accurate
    request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    try? VNImageRequestHandler(ciImage: image, options: [:]).perform([request])
    guard let buffer = request.results?.first?.pixelBuffer else { return nil }
    let mask = CIImage(cvPixelBuffer: buffer)
    return mask.transformed(by: CGAffineTransform(scaleX: image.extent.width / mask.extent.width,
                                                  y: image.extent.height / mask.extent.height))
}

/// マスクの範囲の平均の明るさと色み（YCbCr、ガンマのかかった sRGB）
func meanColor(_ image: CIImage, mask: CIImage) -> (y: Double, cb: Double, cr: Double) {
    let masked = image.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: mask])
    func average(_ input: CIImage) -> [Double] {
        let avg = input.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(avg, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return pixel.map(Double.init)
    }
    let m = average(masked), w = max(average(mask)[0], 1e-6)
    let r = m[0] / w, g = m[1] / w, b = m[2] / w
    let y = 0.299 * r + 0.587 * g + 0.114 * b
    return (y, b - y, r - y)
}

// MARK: - フィルター

// 見本写真ごとに、全部のフィルターを横に並べる
/// 色の出方を見るための表（上: 色相 × 彩度、下: 黒から白までの階調）
func colorChart() -> CIImage {
    let width = 300, height = 400
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            var r: Float, g: Float, b: Float
            if y < 320 {
                let h = Float(x) / Float(width) * 6
                let sat = 1 - Float(y / 80) * 0.25
                let v: Float = 0.85
                let f = h - floor(h)
                let pp = v * (1 - sat), q = v * (1 - sat * f), t = v * (1 - sat * (1 - f))
                switch Int(h) % 6 {
                case 0: (r, g, b) = (v, t, pp)
                case 1: (r, g, b) = (q, v, pp)
                case 2: (r, g, b) = (pp, v, t)
                case 3: (r, g, b) = (pp, q, v)
                case 4: (r, g, b) = (t, pp, v)
                default: (r, g, b) = (v, pp, q)
                }
            } else {
                let l = Float(x) / Float(width - 1)
                (r, g, b) = (l, l, l)
            }
            let i = (y * width + x) * 4
            pixels[i] = UInt8(r * 255); pixels[i + 1] = UInt8(g * 255); pixels[i + 2] = UInt8(b * 255)
        }
    }
    let data = Data(pixels)
    return CIImage(bitmapData: data, bytesPerRow: width * 4, size: CGSize(width: width, height: height),
                   format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
}

do {
    var rows: [CIImage] = []
    for image in inputs.prefix(2).map(\.1) + [colorChart()] {
        let cellHeight: CGFloat = 400
        let scale = cellHeight / image.extent.height
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let cellWidth = small.extent.width
        var row = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0,
                                                            width: cellWidth * CGFloat(PhotoFilter.allCases.count),
                                                            height: cellHeight))
        for (i, filter) in PhotoFilter.allCases.enumerated() {
            let cell = filter.apply(to: small).transformed(by: CGAffineTransform(translationX: cellWidth * CGFloat(i), y: 0))
            row = cell.composited(over: row)
        }
        rows.append(row)
    }
    var sheet = CIImage.empty()
    for (i, row) in rows.enumerated() {
        sheet = row.transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(rows.count - 1 - i) * 400))
            .composited(over: sheet)
    }
    savePNG(sheet.cropped(to: sheet.extent), "filters.png")
    report.append("filters: " + PhotoFilter.allCases.map(\.displayName).joined(separator: ", "))
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
        ("upper body only (no legs)", iso.filter { ![.leftKnee, .rightKnee, .leftAnkle, .rightAnkle, .leftHip, .rightHip].contains($0.key) }),
    ]
    report.append("match test (joints: \(pose.count)):")
    for (label, detected) in cases {
        let score = PoseMatcher.score(template: iso, detected: detected, aspect: aspect).map { String(format: "%.1f", $0) } ?? "nil"
        report.append("  \(label): \(score)")
    }
}

// MARK: - 人の形の重なりによる一致度

/// 写真の人物の輪郭を型にして、同じ写真・ずらした型・顔のアップで採点する
func silhouetteTests(_ label: String, _ image: CIImage) {
    let aspect = image.extent.width / image.extent.height
    let outlines = PoseDetector.personOutlines(ciImage: image).map { outline in
        outline.map { PoseSpace.toIsotropic($0, aspect: aspect) }
    }
    let result = detector.poseAndSilhouette(ciImage: image, silhouetteWidth: 48)
    guard !outlines.isEmpty, let silhouette = result.silhouette else {
        report.append("silhouette \(label): no outline or silhouette")
        return
    }
    let jointCount = result.pose?.count ?? 0
    func scoreFor(_ transformed: [[CGPoint]]) -> String {
        let cells = PoseMatcher.rasterize(transformed, aspect: aspect, width: silhouette.width, height: silhouette.height)
        let value = PoseMatcher.silhouetteScore(template: cells, detected: silhouette.cells, width: silhouette.width)
        return value.map { String(format: "%.1f", $0) } ?? "nil"
    }
    func moved(_ dx: CGFloat, _ scale: CGFloat = 1) -> [[CGPoint]] {
        outlines.map { $0.map { CGPoint(x: $0.x * scale + dx, y: ($0.y - 0.5) * scale + 0.5) } }
    }
    report.append("silhouette \(label) (body joints found: \(jointCount), grid \(silhouette.width)x\(silhouette.height)):")
    report.append("  same: \(scoreFor(outlines))")
    report.append("  shifted 10% right: \(scoreFor(moved(0.1)))")
    report.append("  shifted 25% right: \(scoreFor(moved(0.25)))")
    report.append("  80% size: \(scoreFor(moved(0, 0.8)))")
}

if inputs.count > 1 {
    silhouetteTests("full body", inputs[0].1)
    // 顔のアップ（上半身の写真の上 45% を切り抜く）。体の関節は取れにくいが、人の形は取れる
    let upper = inputs[1].1
    let e = upper.extent
    let crop = CGRect(x: 0, y: e.height * 0.55, width: e.width, height: e.height * 0.45)
    let face = upper.cropped(to: crop).transformed(by: CGAffineTransform(translationX: 0, y: -crop.minY))
    silhouetteTests("face close-up", face)
}

let text = report.joined(separator: "\n")
print(text)
try? text.write(to: outDir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
