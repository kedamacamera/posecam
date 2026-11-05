// 組み込みポーズの見本写真から、骨格と輪郭（型の形）を事前に計算する。
// iPhone の初回起動で 100 枚以上を解析して待たせないよう、結果を JSON にしてアプリに同梱する。
// GitHub Actions の build-shapes ワークフローから実行する。
//
// 使い方: shapes <見本写真のフォルダ>
// 出力（out/ 以下）:
//   builtin_shapes.json … 画像名 → PoseShape
//   preview_<n>.png     … 見本写真に、取り出した輪郭（白）と骨格（水色）、枠（黄）を重ねた一覧

import CoreGraphics
import CoreImage
import Foundation

let context = CIContext()
let outDir = URL(fileURLWithPath: "out", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

guard CommandLine.arguments.count > 1 else { fatalError("usage: shapes <dir>") }
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let files = (try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))
    .filter { $0.pathExtension == "jpg" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

// 見本写真のカテゴリ（料理・ドリンクは人ではなく物の輪郭を取る）
struct SampleEntry: Decodable { let image: String; let category: String }
let entries = (try? JSONDecoder().decode([SampleEntry].self,
    from: Data(contentsOf: folder.appendingPathComponent("sample_poses.json")))) ?? []
let categories = Dictionary(entries.map { ($0.image, $0.category) }, uniquingKeysWith: { a, _ in a })

var shapes: [String: PoseShape] = [:]
var failed: [String] = []
var previews: [(name: String, image: CGImage, analysis: PhotoAnalysis, crop: CGRect)] = []

for url in files {
    let name = url.deletingPathExtension().lastPathComponent
    let isObject = PoseTemplate.objectCategories.contains(categories[name] ?? "")
    guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
          let analysis = isObject ? PoseImporter.analyzeObject(image) : PoseImporter.analyze(image) else {
        failed.append(name)
        continue
    }
    // 組み込みポーズは、写真モードの標準の比率（3:4）で枠を決める（アプリの PoseLibrary と同じ）
    let crop = isObject
        ? PoseImporter.fullFrameCrop(size: analysis.size, aspect: 3.0 / 4.0)
        : PoseImporter.defaultCrop(for: analysis, aspect: 3.0 / 4.0)
    shapes[name] = PoseImporter.shape(for: analysis, crop: crop)

    let scale = 200 / image.extent.width
    let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    if let cgImage = context.createCGImage(small, from: small.extent) {
        previews.append((name, cgImage, analysis, crop))
    }
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
try encoder.encode(shapes).write(to: outDir.appendingPathComponent("builtin_shapes.json"))
print("shapes: \(shapes.count), failed: \(failed.count) \(failed)")

// MARK: - 確認用の一覧画像

let cellWidth = 200, cellHeight = 300, columns = 10, perSheet = 40
for sheetIndex in stride(from: 0, to: previews.count, by: perSheet) {
    let chunk = Array(previews[sheetIndex..<min(sheetIndex + perSheet, previews.count)])
    let rows = (chunk.count + columns - 1) / columns
    let width = columns * cellWidth, height = rows * cellHeight
    guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
    canvas.setFillColor(CGColor(gray: 1, alpha: 1))
    canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))

    for (i, item) in chunk.enumerated() {
        let originX = CGFloat((i % columns) * cellWidth)
        // CGContext は左下原点なので、上の行から順に並べるよう y を反転する
        let originY = CGFloat(height - (i / columns + 1) * cellHeight)
        let photoHeight = CGFloat(item.image.height) * CGFloat(cellWidth) / CGFloat(item.image.width)
        let photoRect = CGRect(x: originX, y: originY + CGFloat(cellHeight) - photoHeight,
                               width: CGFloat(cellWidth), height: photoHeight)
        canvas.draw(item.image, in: photoRect)

        // 画像座標（左上原点・0...1）を、セルの中の座標に直す
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: photoRect.minX + p.x * photoRect.width, y: photoRect.maxY - p.y * photoRect.height)
        }
        canvas.setLineWidth(2)
        canvas.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        for outline in item.analysis.outlines where outline.count > 2 {
            canvas.beginPath()
            canvas.addLines(between: outline.map(point))
            canvas.closePath()
            canvas.strokePath()
        }
        canvas.setStrokeColor(CGColor(red: 0, green: 0.8, blue: 1, alpha: 1))
        for (a, b) in Joint.bones {
            guard let pa = item.analysis.joints[a], let pb = item.analysis.joints[b] else { continue }
            canvas.beginPath()
            canvas.move(to: point(pa))
            canvas.addLine(to: point(pb))
            canvas.strokePath()
        }
        // 顔のボーン（緑）
        if let face = item.analysis.face {
            canvas.setStrokeColor(CGColor(red: 0.2, green: 1, blue: 0.3, alpha: 1))
            canvas.beginPath()
            canvas.addLines(between: face.contour.map(point))
            canvas.strokePath()
            canvas.beginPath()
            canvas.addLines(between: face.mouth.map(point))
            canvas.closePath()
            canvas.strokePath()
            for eye in [face.leftEye, face.rightEye].compactMap({ $0 }) {
                let c = point(eye)
                canvas.fillEllipse(in: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4))
            }
            // 顔の枠と向き（yaw）
            let c = point(face.center)
            let h = face.height * photoRect.height
            canvas.stroke(CGRect(x: c.x - h * 0.4, y: c.y - h / 2, width: h * 0.8, height: h))
            canvas.beginPath()
            canvas.move(to: c)
            canvas.addLine(to: CGPoint(x: c.x + CGFloat(sin(face.yaw * .pi / 180)) * h * 0.6, y: c.y))
            canvas.strokePath()
        }
        // 撮影画面に重なる枠（3:4）
        let size = item.analysis.size
        let crop = item.crop
        let cropRect = CGRect(x: photoRect.minX + crop.minX / size.width * photoRect.width,
                              y: photoRect.maxY - crop.maxY / size.height * photoRect.height,
                              width: crop.width / size.width * photoRect.width,
                              height: crop.height / size.height * photoRect.height)
        canvas.setStrokeColor(CGColor(red: 1, green: 0.85, blue: 0, alpha: 1))
        canvas.stroke(cropRect)
    }
    if let sheet = canvas.makeImage() {
        let url = outDir.appendingPathComponent("preview_\(sheetIndex / perSheet).png")
        try? context.writePNGRepresentation(of: CIImage(cgImage: sheet), to: url, format: .RGBA8,
                                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}

// MARK: - 顔の向きの確認（顔だけを大きく切り出し、向きの矢印を描く。画像の右向き＝赤、左向き＝青）

var faceCells: [(CGImage, FaceShape)] = []
for url in files {
    guard faceCells.count < 48,
          let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { continue }
    let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    guard let face = PoseDetector.faceShape(ciImage: normalized), abs(face.yaw) > 20 else { continue }
    let size = normalized.extent.size
    let side = face.height * size.height * 1.8
    // 顔の中心（画像座標・左上原点）を Core Image の座標（左下原点）に直して切り出す
    let rect = CGRect(x: face.center.x * size.width - side / 2, y: (1 - face.center.y) * size.height - side / 2,
                      width: side, height: side)
    let crop = normalized.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        .transformed(by: CGAffineTransform(scaleX: 160 / side, y: 160 / side))
    if let cg = context.createCGImage(crop, from: CGRect(x: 0, y: 0, width: 160, height: 160)) {
        faceCells.append((cg, face))
    }
}
if !faceCells.isEmpty, let canvas = CGContext(data: nil, width: 8 * 160, height: ((faceCells.count + 7) / 8) * 160,
                                              bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
    let rows = (faceCells.count + 7) / 8
    for (i, cell) in faceCells.enumerated() {
        let x = CGFloat((i % 8) * 160), y = CGFloat((rows - 1 - i / 8) * 160)
        canvas.draw(cell.0, in: CGRect(x: x, y: y, width: 160, height: 160))
        let length = CGFloat(sin(cell.1.yaw * .pi / 180)) * 70
        canvas.setLineWidth(5)
        canvas.setStrokeColor(cell.1.yaw > 0 ? CGColor(red: 1, green: 0.1, blue: 0.1, alpha: 1)
                                             : CGColor(red: 0.1, green: 0.4, blue: 1, alpha: 1))
        canvas.beginPath()
        canvas.move(to: CGPoint(x: x + 80, y: y + 80))
        canvas.addLine(to: CGPoint(x: x + 80 + length, y: y + 80))
        canvas.strokePath()
    }
    if let sheet = canvas.makeImage() {
        try? context.writePNGRepresentation(of: CIImage(cgImage: sheet), to: outDir.appendingPathComponent("faces_yaw.png"),
                                            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
    print("faces_yaw.png: \(faceCells.count) faces turned more than 20 degrees")
}
