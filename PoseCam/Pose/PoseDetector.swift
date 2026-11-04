import CoreImage
import Vision

/// Vision で人物の骨格と人物の領域（マスク）を求める。
/// 骨格の座標は画像座標（左上原点・0...1）、マスクは入力画像と同じ大きさの CIImage（人物が白）。
/// リクエストは呼び出しごとに作るので、複数のキューから同時に呼んでよい。
final class PoseDetector {
    struct Result {
        var pose: [Joint: CGPoint]?
        var mask: CIImage?
    }

    private let minimumConfidence: Float = 0.3

    /// プレビュー用。マスクは速度優先の品質で求める。
    func analyze(pixelBuffer: CVPixelBuffer, wantsMask: Bool) -> Result {
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        return perform(handler, imageSize: size, mask: wantsMask ? .balanced : nil)
    }

    /// 写真用。マスクは精度優先で求める。
    func analyze(ciImage: CIImage, wantsMask: Bool) -> Result {
        let handler = VNImageRequestHandler(ciImage: ciImage, orientation: .up, options: [:])
        return perform(handler, imageSize: ciImage.extent.size, mask: wantsMask ? .accurate : nil)
    }

    func detect(ciImage: CIImage) -> [Joint: CGPoint]? {
        analyze(ciImage: ciImage, wantsMask: false).pose
    }

    static func hipY(of pose: [Joint: CGPoint]) -> CGFloat? {
        let ys = [pose[.leftHip], pose[.rightHip]].compactMap { $0?.y }
        guard !ys.isEmpty else { return nil }
        return ys.reduce(0, +) / CGFloat(ys.count)
    }

    private func perform(_ handler: VNImageRequestHandler, imageSize: CGSize,
                         mask quality: VNGeneratePersonSegmentationRequest.QualityLevel?) -> Result {
        let poseRequest = VNDetectHumanBodyPoseRequest()
        var requests: [VNRequest] = [poseRequest]
        var maskRequest: VNGeneratePersonSegmentationRequest?
        if let quality {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = quality
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            requests.append(request)
            maskRequest = request
        }
        do {
            try handler.perform(requests)
        } catch {
            return Result()
        }

        var result = Result()
        if let observations = poseRequest.results {
            // 複数人写っているときは、検出できた関節がいちばん多い人を使う
            let best = observations.map(points(from:)).max { $0.count < $1.count }
            if let best, best.count >= 4 { result.pose = best }
        }
        if let buffer = maskRequest?.results?.first?.pixelBuffer {
            let mask = CIImage(cvPixelBuffer: buffer)
            result.mask = mask.transformed(by: CGAffineTransform(scaleX: imageSize.width / mask.extent.width,
                                                                 y: imageSize.height / mask.extent.height))
        }
        return result
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
