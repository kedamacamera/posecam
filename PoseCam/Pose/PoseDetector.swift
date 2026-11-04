import CoreImage
import Vision

/// Vision で人物の骨格を検出する。返す座標は画像座標（左上原点・0...1）。
/// リクエストは呼び出しごとに作るので、複数のキューから同時に呼んでよい。
final class PoseDetector {
    private let minimumConfidence: Float = 0.3

    func detect(pixelBuffer: CVPixelBuffer) -> [Joint: CGPoint]? {
        perform(VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:]))
    }

    func detect(ciImage: CIImage) -> [Joint: CGPoint]? {
        perform(VNImageRequestHandler(ciImage: ciImage, orientation: .up, options: [:]))
    }

    static func hipY(of pose: [Joint: CGPoint]) -> CGFloat? {
        let ys = [pose[.leftHip], pose[.rightHip]].compactMap { $0?.y }
        guard !ys.isEmpty else { return nil }
        return ys.reduce(0, +) / CGFloat(ys.count)
    }

    private func perform(_ handler: VNImageRequestHandler) -> [Joint: CGPoint]? {
        let request = VNDetectHumanBodyPoseRequest()
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observations = request.results else { return nil }
        // 複数人写っているときは、検出できた関節がいちばん多い人を使う
        let best = observations.map(points(from:)).max { $0.count < $1.count }
        guard let best, best.count >= 4 else { return nil }
        return best
    }

    private func points(from observation: VNHumanBodyPoseObservation) -> [Joint: CGPoint] {
        var result: [Joint: CGPoint] = [:]
        for joint in Joint.allCases {
            guard let point = try? observation.recognizedPoint(joint.visionName),
                  point.confidence > minimumConfidence else { continue }
            result[joint] = CGPoint(x: point.location.x, y: 1 - point.location.y)
        }
        return result
    }
}
