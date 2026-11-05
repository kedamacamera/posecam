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
    /// ひげの生える所（鼻の下〜あご、唇は除く）を白にしたマスク（青ひげ隠し用）
    var beard: CIImage?
    /// あごの輪郭のすぐ外側（首との境目）を白にしたマスク（輪郭の影入れ用）
    var jawShade: CIImage?
    /// 鼻より上の顔（頬・額）を白にしたマスク。ひげの生えない肌の色を知るのに使う
    var upperFace: CIImage?

    /// 大きさの確認に使う
    var extent: CGRect? { (skin ?? person)?.extent }

    func map(_ transform: (CIImage) -> CIImage) -> BeautyMasks {
        BeautyMasks(skin: skin.map(transform), person: person.map(transform),
                    features: features.map(transform), redFeatures: redFeatures.map(transform),
                    beard: beard.map(transform), jawShade: jawShade.map(transform),
                    upperFace: upperFace.map(transform))
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

    /// 一致度の判定に使う、人の形のマス目（上の行から順、true が人）。
    struct Silhouette {
        let width: Int
        let height: Int
        let cells: [Bool]
    }

    /// プレビュー用。骨格と、人の形（silhouetteWidth 列のマス目）を求める。
    /// pixelBuffer は切り抜き・縮小済みのコマで、座標もそのコマが基準。
    func poseAndSilhouette(pixelBuffer: CVPixelBuffer, silhouetteWidth: Int?) -> (pose: [Joint: CGPoint]?, silhouette: Silhouette?) {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        let aspect = CGFloat(CVPixelBufferGetWidth(pixelBuffer)) / CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        return poseAndSilhouette(handler, aspect: aspect, silhouetteWidth: silhouetteWidth)
    }

    /// 確認用のツールから使う（写真から）。
    func poseAndSilhouette(ciImage: CIImage, silhouetteWidth: Int?) -> (pose: [Joint: CGPoint]?, silhouette: Silhouette?) {
        let handler = VNImageRequestHandler(ciImage: ciImage, orientation: .up, options: [:])
        return poseAndSilhouette(handler, aspect: ciImage.extent.width / ciImage.extent.height,
                                 silhouetteWidth: silhouetteWidth)
    }

    private func poseAndSilhouette(_ handler: VNImageRequestHandler, aspect: CGFloat,
                                   silhouetteWidth: Int?) -> (pose: [Joint: CGPoint]?, silhouette: Silhouette?) {
        let poseRequest = VNDetectHumanBodyPoseRequest()
        let segmentation = VNGeneratePersonSegmentationRequest()
        // 人の形は大まかでよいので、いちばん速い品質で求める
        segmentation.qualityLevel = .fast
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        var requests: [VNRequest] = [poseRequest]
        if silhouetteWidth != nil { requests.append(segmentation) }
        do {
            try handler.perform(requests)
        } catch {
            return (nil, nil)
        }
        var pose: [Joint: CGPoint]?
        if let observations = poseRequest.results {
            let best = observations.map(points(from:)).max { $0.count < $1.count }
            if let best, best.count >= 3 { pose = best }
        }
        var silhouette: Silhouette?
        if let width = silhouetteWidth, let mask = segmentation.results?.first?.pixelBuffer {
            silhouette = Self.cells(of: mask, width: width, height: max(1, Int((CGFloat(width) / aspect).rounded())))
        }
        return (pose, silhouette)
    }

    /// 人の領域のマスクを、width × height のマス目に縮める（各マスの中心の値で判定）。
    private static func cells(of mask: CVPixelBuffer, width: Int, height: Int) -> Silhouette {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        let maskWidth = CVPixelBufferGetWidth(mask)
        let maskHeight = CVPixelBufferGetHeight(mask)
        let rowBytes = CVPixelBufferGetBytesPerRow(mask)
        guard let base = CVPixelBufferGetBaseAddress(mask)?.assumingMemoryBound(to: UInt8.self) else {
            return Silhouette(width: width, height: height, cells: [Bool](repeating: false, count: width * height))
        }
        var cells = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            let my = min(maskHeight - 1, Int((Double(y) + 0.5) / Double(height) * Double(maskHeight)))
            for x in 0..<width {
                let mx = min(maskWidth - 1, Int((Double(x) + 0.5) / Double(width) * Double(maskWidth)))
                cells[y * width + x] = base[my * rowBytes + mx] > 127
            }
        }
        return Silhouette(width: width, height: height, cells: cells)
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
                redFeatures: Self.featureMask(faces, imageSize: imageSize, forRedness: true),
                beard: Self.beardMask(faces, imageSize: imageSize),
                jawShade: Self.jawShadeMask(faces, imageSize: imageSize),
                upperFace: Self.upperFaceMask(faces, imageSize: imageSize))
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

    /// 1/4 の大きさのグレーの画用紙（黒で塗りつぶし済み）に draw で描き、元の大きさに引き伸ばしてぼかす。
    private static func drawMask(imageSize: CGSize, blurOfFace: CGFloat, faces: [VNFaceObservation],
                                 draw: (CGContext, CGSize) -> Void) -> CIImage? {
        let scale: CGFloat = 0.25
        let width = max(Int(imageSize.width * scale), 1)
        let height = max(Int(imageSize.height * scale), 1)
        guard !faces.isEmpty,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        let size = CGSize(width: width, height: height)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        draw(context, size)
        guard let cgImage = context.makeImage() else { return nil }
        let largestFace = faces.map(\.boundingBox.width).max() ?? 0
        let sigma = max(imageSize.width * 0.004, largestFace * imageSize.width * blurOfFace)
        return scaled(CIImage(cgImage: cgImage), to: imageSize)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: CGRect(origin: .zero, size: imageSize))
    }

    /// 鼻より上の顔（頬・額）。顔の輪郭の内側を、鼻の下端より上だけ塗る（目・眉は後で肌の判定で外れる）。
    private static func upperFaceMask(_ faces: [VNFaceObservation], imageSize: CGSize) -> CIImage? {
        drawMask(imageSize: imageSize, blurOfFace: 0.02, faces: faces) { context, size in
            for face in faces {
                guard let marks = face.landmarks, let contour = marks.faceContour,
                      let nose = marks.nose else { continue }
                let points = contour.pointsInImage(imageSize: size)
                guard points.count > 2, let noseBottom = nose.pointsInImage(imageSize: size).map(\.y).min()
                else { continue }
                let box = face.boundingBox
                context.saveGState()
                context.clip(to: CGRect(x: 0, y: noseBottom, width: size.width, height: size.height - noseBottom))
                context.setFillColor(gray: 1, alpha: 1)
                // 輪郭の線は耳の高さまでなので、その上（額）は顔の枠の上端まで延ばす
                context.beginPath()
                context.addLines(between: points)
                if let last = points.last, let first = points.first {
                    context.addLine(to: CGPoint(x: last.x, y: box.maxY * size.height))
                    context.addLine(to: CGPoint(x: first.x, y: box.maxY * size.height))
                }
                context.closePath()
                context.fillPath()
                context.restoreGState()
            }
        }
    }

    /// ひげの生える範囲。顔の輪郭（あごのライン）の内側のうち鼻より下を塗り、唇を外す。
    private static func beardMask(_ faces: [VNFaceObservation], imageSize: CGSize) -> CIImage? {
        drawMask(imageSize: imageSize, blurOfFace: 0.035, faces: faces) { context, size in
            for face in faces {
                guard let marks = face.landmarks, let contour = marks.faceContour,
                      let nose = marks.nose else { continue }
                let faceWidth = face.boundingBox.width * size.width
                let points = contour.pointsInImage(imageSize: size)
                // pointsInImage は左下原点なので、y が小さいほど下
                guard points.count > 2, let noseBottom = nose.pointsInImage(imageSize: size).map(\.y).min()
                else { continue }
                context.saveGState()
                context.clip(to: CGRect(x: 0, y: 0, width: size.width, height: noseBottom - faceWidth * 0.02))
                context.setFillColor(gray: 1, alpha: 1)
                context.beginPath()
                context.addLines(between: points)
                context.closePath()
                context.fillPath()
                context.restoreGState()
                if let lips = marks.outerLips?.pointsInImage(imageSize: size), lips.count > 2 {
                    context.setFillColor(gray: 0, alpha: 1)
                    context.setStrokeColor(gray: 0, alpha: 1)
                    context.setLineWidth(faceWidth * 0.04)
                    context.setLineJoin(.round)
                    context.beginPath()
                    context.addLines(between: lips)
                    context.closePath()
                    context.drawPath(using: .fillStroke)
                }
            }
        }
    }

    /// あごの輪郭のすぐ外側の帯。鼻より下の輪郭を、顔の中心から外へ少しずらしてなぞる。
    /// 首との境目に影ができ、美肌でぼやけたフェイスラインがはっきりする（メイクのシェーディングと同じ）。
    private static func jawShadeMask(_ faces: [VNFaceObservation], imageSize: CGSize) -> CIImage? {
        drawMask(imageSize: imageSize, blurOfFace: 0.03, faces: faces) { context, size in
            for face in faces {
                guard let marks = face.landmarks, let contour = marks.faceContour,
                      let nose = marks.nose else { continue }
                let faceWidth = face.boundingBox.width * size.width
                let box = face.boundingBox
                let center = CGPoint(x: box.midX * size.width, y: box.midY * size.height)
                guard let noseBottom = nose.pointsInImage(imageSize: size).map(\.y).min() else { continue }
                let lower = contour.pointsInImage(imageSize: size).filter { $0.y < noseBottom }
                guard lower.count > 2 else { continue }
                let shifted = lower.map { p -> CGPoint in
                    let dx = p.x - center.x, dy = p.y - center.y
                    let length = max(hypot(dx, dy), 0.001)
                    let offset = faceWidth * 0.035
                    return CGPoint(x: p.x + dx / length * offset, y: p.y + dy / length * offset)
                }
                context.setStrokeColor(gray: 1, alpha: 1)
                context.setLineWidth(faceWidth * 0.06)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.beginPath()
                context.addLines(between: shifted)
                context.strokePath()
            }
        }
    }

    // MARK: - 写真の人物の輪郭

    /// 写真に写っている人物の輪郭を、画像座標（左上原点・0...1）の閉じた多角形で、大きい順に返す。
    /// 2 人写っていれば 2 つ返す（いちばん大きい人の 2 割に満たない小さな影などは除く）。
    /// 料理・ドリンクの写真の、主な被写体（お皿・グラス・それを持つ手）の輪郭。画像座標（左上原点・0...1）。
    /// 人物用の判定は使えないので、写真の手前にある物を切り抜く判定（iOS 17 / macOS 14 以降）を使う。
    /// 使えない環境では、目立つ所（顕著性）の判定で代わりにする。
    static func objectOutlines(ciImage: CIImage) -> [[CGPoint]] {
        var mask: CVPixelBuffer?
        let handler = VNImageRequestHandler(ciImage: ciImage, orientation: .up, options: [:])
        let foreground = VNGenerateForegroundInstanceMaskRequest()
        if (try? handler.perform([foreground])) != nil, let result = foreground.results?.first {
            mask = try? result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        }
        if mask == nil {
            let saliency = VNGenerateObjectnessBasedSaliencyImageRequest()
            if (try? handler.perform([saliency])) != nil {
                mask = saliency.results?.first?.pixelBuffer
            }
        }
        guard let mask else { return [] }
        return outlines(of: mask, minimumShare: 0.08, limit: 4)
    }

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
        return outlines(of: mask, minimumShare: 0.2, limit: 8)
    }

    /// マスク（白が対象）の外形を、大きい順に閉じた多角形で返す。
    /// minimumShare: いちばん大きい形に対して、これより小さい形は除く。
    private static func outlines(of mask: CVPixelBuffer, minimumShare: Float, limit: Int) -> [[CGPoint]] {
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
        return sorted.filter { area($0) >= largestArea * minimumShare }.prefix(limit).compactMap { contour -> [CGPoint]? in
            let simplified = (try? contour.polygonApproximation(epsilon: 0.002)) ?? contour
            let points = simplified.normalizedPoints.map { CGPoint(x: CGFloat($0.x), y: 1 - CGFloat($0.y)) }
            return points.count >= 8 ? points : nil
        }
    }
}
