import CoreImage
import Vision

/// 美肌に使うマスク。どちらも元の画像と同じ大きさ。
struct BeautyMasks {
    /// 人物の領域（白）
    var person: CIImage
    /// 目・眉・唇を黒、それ以外を白にしたマスク。顔が見つからなければ nil
    var features: CIImage?
}

/// Vision で人物の骨格・領域・顔のパーツを求める。
/// 骨格の座標は画像座標（左上原点・0...1）。
/// リクエストは呼び出しごとに作るので、複数のキューから同時に呼んでよい。
final class PoseDetector {
    struct Result {
        var pose: [Joint: CGPoint]?
        var masks: BeautyMasks?
    }

    private let minimumConfidence: Float = 0.3

    /// プレビュー用。マスクは速度優先の品質で求める。
    func analyze(pixelBuffer: CVPixelBuffer, wantsMasks: Bool) -> Result {
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        return perform(handler, imageSize: size, maskQuality: wantsMasks ? .balanced : nil)
    }

    /// 写真用。マスクは精度優先で求める。
    func analyze(ciImage: CIImage, wantsMasks: Bool) -> Result {
        let handler = VNImageRequestHandler(ciImage: ciImage, orientation: .up, options: [:])
        return perform(handler, imageSize: ciImage.extent.size, maskQuality: wantsMasks ? .accurate : nil)
    }

    func detect(ciImage: CIImage) -> [Joint: CGPoint]? {
        analyze(ciImage: ciImage, wantsMasks: false).pose
    }

    static func hipY(of pose: [Joint: CGPoint]) -> CGFloat? {
        let ys = [pose[.leftHip], pose[.rightHip]].compactMap { $0?.y }
        guard !ys.isEmpty else { return nil }
        return ys.reduce(0, +) / CGFloat(ys.count)
    }

    private func perform(_ handler: VNImageRequestHandler, imageSize: CGSize,
                         maskQuality: VNGeneratePersonSegmentationRequest.QualityLevel?) -> Result {
        let poseRequest = VNDetectHumanBodyPoseRequest()
        var requests: [VNRequest] = [poseRequest]
        var segmentation: VNGeneratePersonSegmentationRequest?
        var landmarks: VNDetectFaceLandmarksRequest?
        if let maskQuality {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = maskQuality
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            segmentation = request
            landmarks = VNDetectFaceLandmarksRequest()
            requests += [request, landmarks!]
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
        if let buffer = segmentation?.results?.first?.pixelBuffer {
            let person = Self.scaled(CIImage(cvPixelBuffer: buffer), to: imageSize)
            let faces = landmarks?.results ?? []
            result.masks = BeautyMasks(person: person, features: Self.featureMask(faces, imageSize: imageSize))
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

    private static func scaled(_ image: CIImage, to size: CGSize) -> CIImage {
        image.transformed(by: CGAffineTransform(scaleX: size.width / image.extent.width,
                                                y: size.height / image.extent.height))
    }

    /// 目・眉・唇を太めに塗りつぶしたマスク（黒が美肌をかけない部分）。
    /// 精度は要らないので 1/4 の大きさで描いてから引き伸ばす。
    private static func featureMask(_ faces: [VNFaceObservation], imageSize: CGSize) -> CIImage? {
        let scale: CGFloat = 0.25
        let width = max(Int(imageSize.width * scale), 1)
        let height = max(Int(imageSize.height * scale), 1)
        guard !faces.isEmpty,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        let size = CGSize(width: width, height: height)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(gray: 0, alpha: 1)
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineJoin(.round)
        context.setLineCap(.round)

        for face in faces {
            guard let marks = face.landmarks else { continue }
            let faceWidth = face.boundingBox.width * size.width
            let regions = [marks.leftEye, marks.rightEye, marks.leftEyebrow, marks.rightEyebrow,
                           marks.outerLips, marks.leftPupil, marks.rightPupil].compactMap { $0 }
            for region in regions {
                // pointsInImage は左下原点で、CGContext と同じ向き
                let points = region.pointsInImage(imageSize: size)
                guard points.count > 1 else { continue }
                context.beginPath()
                context.addLines(between: points)
                context.closePath()
                context.setLineWidth(faceWidth * 0.08)
                context.drawPath(using: .fillStroke)
            }
        }
        guard let cgImage = context.makeImage() else { return nil }
        let mask = scaled(CIImage(cgImage: cgImage), to: imageSize)
        // 境目がくっきりしすぎないようにぼかす
        return mask.clampedToExtent()
            .applyingGaussianBlur(sigma: imageSize.width * 0.004)
            .cropped(to: CGRect(origin: .zero, size: imageSize))
    }

    // MARK: - 写真の人物の輪郭

    /// 写真に写っている人物の輪郭を、画像座標（左上原点・0...1）の閉じた多角形で返す。
    static func personOutline(ciImage: CIImage) -> [CGPoint]? {
        let segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .accurate
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do {
            try VNImageRequestHandler(ciImage: ciImage, orientation: .up, options: [:]).perform([segmentation])
        } catch {
            return nil
        }
        guard let mask = segmentation.results?.first?.pixelBuffer else { return nil }

        let contours = VNDetectContoursRequest()
        contours.detectsDarkOnLight = false
        contours.contrastAdjustment = 1
        contours.maximumImageDimension = 512
        do {
            try VNImageRequestHandler(cvPixelBuffer: mask, orientation: .up, options: [:]).perform([contours])
        } catch {
            return nil
        }
        guard let observation = contours.results?.first else { return nil }

        // いちばん大きい輪郭（＝人物の外形）を選び、点を間引く
        func area(_ contour: VNContour) -> Float {
            let points = contour.normalizedPoints
            guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return 0 }
            return (maxX - minX) * (maxY - minY)
        }
        guard let largest = observation.topLevelContours.max(by: { area($0) < area($1) }) else { return nil }
        let simplified = (try? largest.polygonApproximation(epsilon: 0.002)) ?? largest
        let points = simplified.normalizedPoints.map { CGPoint(x: CGFloat($0.x), y: 1 - CGFloat($0.y)) }
        return points.count >= 8 ? points : nil
    }
}
