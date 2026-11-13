// 骨格検出・人物の切り抜きが、写真の種類（立ち・座り・上半身・後ろ向き）ごとにどれだけ当たるかを測るための道具。
// アプリと同じ Vision の検出（VNDetectHumanBodyPoseRequest・VNGeneratePersonSegmentationRequest）を写真にかけ、
// 結果を JSON で書き出す。正解との比べ合わせは eval.py が行う。
// 使い方: posebench <出力.json> <画像...>

import CoreImage
import Foundation
import Vision

let args = CommandLine.arguments
guard args.count >= 3 else { fatalError("usage: posebench out.json images...") }
var results: [[String: Any]] = []

for path in args.dropFirst(2) {
    let url = URL(fileURLWithPath: path)
    var entry: [String: Any] = ["file": url.lastPathComponent]
    let handler = VNImageRequestHandler(url: url, options: [:])
    let pose = VNDetectHumanBodyPoseRequest()
    let seg = VNGeneratePersonSegmentationRequest()
    seg.qualityLevel = .accurate
    seg.outputPixelFormat = kCVPixelFormatType_OneComponent8
    do { try handler.perform([pose, seg]) } catch { entry["error"] = "\(error)"; results.append(entry); continue }

    var bodies: [[String: Any]] = []
    for obs in pose.results ?? [] {
        var joints: [String: [Double]] = [:]
        if let pts = try? obs.recognizedPoints(.all) {
            for (name, p) in pts {
                // 左上原点の 0...1 と信頼度
                joints[name.rawValue.rawValue] = [Double(p.location.x), Double(1 - p.location.y), Double(p.confidence)]
            }
        }
        bodies.append(["joints": joints])
    }
    entry["bodies"] = bodies

    if let buf = seg.results?.first?.pixelBuffer {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
        let stride = CVPixelBufferGetBytesPerRow(buf)
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        var top = -1, bottom = -1
        for y in 0..<h {
            var count = 0
            for x in 0..<w where base[y * stride + x] > 127 { count += 1 }
            // ノイズを避けるため、幅の 0.5% 以上が人物の行だけを数える
            if count > max(1, w / 200) { if top < 0 { top = y }; bottom = y }
        }
        CVPixelBufferUnlockBaseAddress(buf, .readOnly)
        if top >= 0 { entry["segTop"] = Double(top) / Double(h); entry["segBottom"] = Double(bottom + 1) / Double(h) }
    }
    results.append(entry)
}

let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
try data.write(to: URL(fileURLWithPath: args[1]))
print("wrote \(results.count) results")
