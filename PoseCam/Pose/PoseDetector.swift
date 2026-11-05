import CoreImage
import CoreML
import Vision

/// 美肌に使うマスク。どれも元の画像と同じ大きさ。
struct BeautyMasks {
    /// 肌の領域（白）。肌を塗り分ける AI モデル（SkinSegmenter）があるときに使う
    var skin: CIImage?
    /// 人物の領域（白）。モデルがないときは、これと肌の色の判定を組み合わせる
    var person: CIImage?
    /// 目・眉・唇を黒、鼻すじを灰色、それ以外を白にしたマスク（なめらかにする処理を外す所）。顔が見つからなければ nil
    var features: CIImage?
    /// 目・唇だけを黒にしたマスク（赤み消しを外す所）。眉や小鼻の際の赤みは消したいので外さない
    var redFeatures: CIImage?

    /// 大きさの確認に使う
    var extent: CGRect? { (skin ?? person)?.extent }

    func map(_ transform: (CIImage) -> CIImage) -> BeautyMasks {
        BeautyMasks(skin: skin.map(transform), person: person.map(transform),
                    features: features.map(transform), redFeatures: redFeatures.map(transform))
    }
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

    /// プレビュー用。骨格だけを求める。pixelBuffer は切り抜き・縮小済みのコマで、座標もそのコマが基準。
    func pose(pixelBuffer: CVPixelBuffer) -> [Joint: CGPoint]? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        return perform(handler, imageSize: .zero, maskQuality: nil).pose
    }

    /// プレビューの毎コマ用。美肌のマスクだけを、そのコマ自身から求める（骨格は求めない）。
    /// 別のコマのマスクを当てると、カメラを動かしたときに加工の位置が顔から遅れてずれるため。
    /// pixelBuffer は判定用に縮小したコマ。マスクは outputSize（実際に加工する画像の大きさ）に引き伸ばして返す。
    func beautyMasks(pixelBuffer: CVPixelBuffer, outputSize: CGSize) -> BeautyMasks? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        return perform(handler, imageSize: outputSize, maskQuality: .balanced, includePose: false).masks
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

    /// 肌を塗り分けるモデル（Google の MediaPipe のモデルを変換したもの）。アプリに入っていなければ nil
    private static let skinModel: VNCoreMLModel? = {
        guard let url = Bundle.main.url(forResource: "SkinSegmenter", withExtension: "mlmodelc") else { return nil }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        guard let model = try? MLModel(contentsOf: url, configuration: configuration) else { return nil }
        return try? VNCoreMLModel(for: model)
    }()

    static var hasSkinModel: Bool { skinModel != nil }

    private func perform(_ handler: VNImageRequestHandler, imageSize: CGSize,
                         maskQuality: VNGeneratePersonSegmentationRequest.QualityLevel?,
                         includePose: Bool = true) -> Result {
        let poseRequest = VNDetectHumanBodyPoseRequest()
        var requests: [VNRequest] = includePose ? [poseRequest] : []
        var skinRequest: VNCoreMLRequest?
        var segmentation: VNGeneratePersonSegmentationRequest?
        var landmarks: VNDetectFaceLandmarksRequest?
        if let maskQuality {
            if let model = Self.skinModel {
                let request = VNCoreMLRequest(model: model)
                // モデルは縦横比に関係なく 256x256 に引き伸ばした画像を受け取る作り
                request.imageCropAndScaleOption = .scaleFill
                skinRequest = request
                requests.append(request)
            } else {
                let request = VNGeneratePersonSegmentationRequest()
                request.qualityLevel = maskQuality
                request.outputPixelFormat = kCVPixelFormatType_OneComponent8
                segmentation = request
                requests.append(request)
            }
            let faces = VNDetectFaceLandmarksRequest()
            landmarks = faces
            requests.append(faces)
        }
        do {
            try handler.perform(requests)
        } catch {
            return Result()
        }

        var result = Result()
        if includePose, let observations = poseRequest.results {
            // 複数人写っているときは、検出できた関節がいちばん多い人を使う
            let best = observations.map(points(from:)).max { $0.count < $1.count }
            if let best, best.count >= 4 { result.pose = best }
        }

        let skinBuffer = (skinRequest?.results?.first as? VNPixelBufferObservation)?.pixelBuffer
        let personBuffer = segmentation?.results?.first?.pixelBuffer
        if skinBuffer != nil || personBuffer != nil {
            let faces = landmarks?.results ?? []
            result.masks = BeautyMasks(
                skin: skinBuffer.map { Self.scaled(CIImage(cvPixelBuffer: $0), to: imageSize) },
                person: personBuffer.map { Self.scaled(CIImage(cvPixelBuffer: $0), to: imageSize) },
                features: Self.featureMask(faces, imageSize: imageSize, forRedness: false),
                redFeatures: Self.featureMask(faces, imageSize: imageSize, forRedness: true))
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

    /// 加工を外す顔のパーツのマスク（黒が外す部分）。精度は要らないので 1/4 の大きさで描いてから引き伸ばす。
    /// forRedness が false（なめらかにする処理用）: 目・眉・唇を塗りつぶし、鼻すじ・小鼻の線は強さを半分にする。
    /// forRedness が true（赤み消し用）: 目と唇だけを外す。眉の際・小鼻の際の赤みも周りの肌になじませるため。
    /// どちらも境目は大きめにぼかし、加工した所としていない所の境目が見えないようにする。
    private static func featureMask(_ faces: [VNFaceObservation], imageSize: CGSize, forRedness: Bool) -> CIImage? {
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
        context.setLineJoin(.round)
        context.setLineCap(.round)

        var largestFace: CGFloat = 0
        for face in faces {
            guard let marks = face.landmarks else { continue }
            let faceWidth = face.boundingBox.width * size.width
            largestFace = max(largestFace, faceWidth)
            let regions = forRedness
                ? [marks.leftEye, marks.rightEye, marks.outerLips].compactMap { $0 }
                : [marks.leftEye, marks.rightEye, marks.leftEyebrow, marks.rightEyebrow,
                   marks.outerLips, marks.leftPupil, marks.rightPupil].compactMap { $0 }
            context.setStrokeColor(gray: 0, alpha: 1)
            for region in regions {
                // pointsInImage は左下原点で、CGContext と同じ向き
                let points = region.pointsInImage(imageSize: size)
                guard points.count > 1 else { continue }
                context.beginPath()
                context.addLines(between: points)
                context.closePath()
                context.setLineWidth(faceWidth * 0.035)
                context.drawPath(using: .fillStroke)
            }
            guard !forRedness else { continue }
            // 鼻すじと小鼻は、なめらかにする強さを半分にするだけ（全部外すと毛穴や赤みが筋になって残る）
            context.setStrokeColor(gray: 0.5, alpha: 1)
            for region in [marks.noseCrest, marks.nose].compactMap({ $0 }) {
                let points = region.pointsInImage(imageSize: size)
                guard points.count > 1 else { continue }
                context.beginPath()
                context.addLines(between: points)
                context.setLineWidth(faceWidth * 0.025)
                context.strokePath()
            }
        }
        guard let cgImage = context.makeImage() else { return nil }
        let mask = scaled(CIImage(cgImage: cgImage), to: imageSize)
        // 境目がくっきりしないよう、顔の大きさに合わせてぼかす
        let sigma = max(imageSize.width * 0.004, largestFace / scale * 0.02)
        return mask.clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: CGRect(origin: .zero, size: imageSize))
    }

    // MARK: - 写真の人物の輪郭

    /// 写真に写っている人物の輪郭を、画像座標（左上原点・0...1）の閉じた多角形で、大きい順に返す。
    /// 2 人写っていれば 2 つ返す（いちばん大きい人の 2 割に満たない小さな影などは除く）。
    static func personOutlines(ciImage: CIImage) -> [[CGPoint]] {
        let segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .accurate
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do {
            try VNImageRequestHandler(ciImage: ciImage, orientation: .up, options: [:]).perform([segmentation])
        } catch {
            return []
        }
        guard let mask = segmentation.results?.first?.pixelBuffer else { return [] }

        let contours = VNDetectContoursRequest()
        contours.detectsDarkOnLight = false
        contours.contrastAdjustment = 1
        contours.maximumImageDimension = 512
        do {
            try VNImageRequestHandler(cvPixelBuffer: mask, orientation: .up, options: [:]).perform([contours])
        } catch {
            return []
        }
        guard let observation = contours.results?.first else { return [] }

        // 大きい輪郭（＝人物の外形）から順に、点を間引いて返す
        func area(_ contour: VNContour) -> Float {
            let points = contour.normalizedPoints
            guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return 0 }
            return (maxX - minX) * (maxY - minY)
        }
        let sorted = observation.topLevelContours.sorted { area($0) > area($1) }
        guard let largestArea = sorted.first.map(area) else { return [] }
        return sorted.filter { area($0) >= largestArea * 0.2 }.compactMap { contour -> [CGPoint]? in
            let simplified = (try? contour.polygonApproximation(epsilon: 0.002)) ?? contour
            let points = simplified.normalizedPoints.map { CGPoint(x: CGFloat($0.x), y: 1 - CGFloat($0.y)) }
            return points.count >= 8 ? points : nil
        }
    }
}
