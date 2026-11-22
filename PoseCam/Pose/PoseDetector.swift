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
    /// 頬（目の下〜鼻の下、鼻を除く）を白にしたマスク。ひげの生えない肌の色を知るのに使う
    var upperFace: CIImage?
    /// 顔のある範囲（顔の枠を広げたもの・画像の座標）。重い処理をこの中だけで行う。顔がなければ nil
    var faceRegion: CGRect?
    /// いちばん大きい顔の幅（画像のピクセル）。美肌の強さ（ならす範囲など）を顔の大きさに合わせるのに使う。顔がなければ nil
    var faceWidth: CGFloat?
    /// 顔の 478 点（MediaPipe の顔のメッシュの番号順・左下原点の画像の座標）。大きい顔から 2 つまで。
    /// 小顔・目・鼻の形の補正に使う。モデルがない・顔が見つからなければ空
    var faceMeshes: [[CGPoint]] = []

    /// 大きさの確認に使う
    var extent: CGRect? { (skin ?? person)?.extent }

    func map(_ transform: (CIImage) -> CIImage) -> BeautyMasks {
        BeautyMasks(skin: skin.map(transform), person: person.map(transform),
                    features: features.map(transform), redFeatures: redFeatures.map(transform),
                    beard: beard.map(transform), jawShade: jawShade.map(transform),
                    upperFace: upperFace.map(transform), faceRegion: nil, faceWidth: nil, faceMeshes: [])
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
    /// 骨格・人の形・顔のパーツ（画像座標）。
    struct Live {
        var pose: [Joint: CGPoint]?
        var silhouette: Silhouette?
        var face: FaceShape?
        /// 映っている人全員の骨格（関節の多い順。2 人以上の型の一致度に使う）
        var poses: [[Joint: CGPoint]] = []
        /// 映っている顔全部（大きい順）
        var faces: [FaceShape] = []
    }

    func poseAndSilhouette(pixelBuffer: CVPixelBuffer, silhouetteWidth: Int?, face: Bool = false) -> Live {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        let aspect = CGFloat(CVPixelBufferGetWidth(pixelBuffer)) / CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        return poseAndSilhouette(handler, aspect: aspect, silhouetteWidth: silhouetteWidth, face: face)
    }

    /// 確認用のツールから使う（写真から）。
    func poseAndSilhouette(ciImage: CIImage, silhouetteWidth: Int?, face: Bool = false) -> Live {
        let handler = VNImageRequestHandler(ciImage: ciImage, orientation: .up, options: [:])
        return poseAndSilhouette(handler, aspect: ciImage.extent.width / ciImage.extent.height,
                                 silhouetteWidth: silhouetteWidth, face: face)
    }

    private func poseAndSilhouette(_ handler: VNImageRequestHandler, aspect: CGFloat,
                                   silhouetteWidth: Int?, face wantsFace: Bool) -> Live {
        let poseRequest = VNDetectHumanBodyPoseRequest()
        let segmentation = VNGeneratePersonSegmentationRequest()
        // 人の形は大まかでよいので、いちばん速い品質で求める
        segmentation.qualityLevel = .fast
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let faceRequest = VNDetectFaceLandmarksRequest()
        // 顔の向き（yaw・roll）は、顔の枠の検出（リビジョン 3）が連続した角度で返す。
        // ランドマーク検出の向きは 0・±45・±90 度の 3 段階なので使わない
        let angleRequest = Self.angleRequest()
        var requests: [VNRequest] = [poseRequest]
        if silhouetteWidth != nil { requests.append(segmentation) }
        if wantsFace { requests += [faceRequest, angleRequest] }
        do {
            try handler.perform(requests)
        } catch {
            return Live()
        }
        let poses = (poseRequest.results ?? []).map(points(from:)).filter { $0.count >= 3 }
            .sorted { $0.count > $1.count }
        var silhouette: Silhouette?
        if let width = silhouetteWidth, let mask = segmentation.results?.first?.pixelBuffer {
            silhouette = Self.cells(of: mask, width: width, height: max(1, Int((CGFloat(width) / aspect).rounded())))
        }
        let faces = wantsFace ? Self.faceShapes(from: faceRequest.results ?? [], angles: angleRequest.results ?? []) : []
        return Live(pose: poses.first, silhouette: silhouette, face: faces.first, poses: poses, faces: faces)
    }

    /// 写真のいちばん大きい顔のパーツ（画像座標）。型を作るときに使う。
    static func faceShape(ciImage: CIImage) -> FaceShape? {
        let request = VNDetectFaceLandmarksRequest()
        let angles = angleRequest()
        try? VNImageRequestHandler(ciImage: ciImage, orientation: .up, options: [:]).perform([request, angles])
        return faceShape(from: request.results ?? [], angles: angles.results ?? [])
    }

    /// 写真の顔すべて（大きい順・画像座標）。2 人以上の型を作るときに使う。
    static func faceShapes(ciImage: CIImage) -> [FaceShape] {
        let request = VNDetectFaceLandmarksRequest()
        let angles = angleRequest()
        try? VNImageRequestHandler(ciImage: ciImage, orientation: .up, options: [:]).perform([request, angles])
        return faceShapes(from: request.results ?? [], angles: angles.results ?? [])
    }

    /// 写真に写っている人全員の骨格（関節が 4 つ以上の人・関節の多い順・画像座標）。
    func detectPeople(ciImage: CIImage) -> [[Joint: CGPoint]] {
        let request = VNDetectHumanBodyPoseRequest()
        try? VNImageRequestHandler(ciImage: ciImage, orientation: .up, options: [:]).perform([request])
        return (request.results ?? []).map(points(from:)).filter { $0.count >= 4 }.sorted { $0.count > $1.count }
    }

    /// 顔の向きを連続した角度で返す、顔の枠の検出（iOS 15 以降のリビジョン 3）
    private static func angleRequest() -> VNDetectFaceRectanglesRequest {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        return request
    }

    /// いちばん大きい顔を、画像座標（左上原点・0...1）で返す。
    /// 横顔などでパーツが取れなくても、枠と向き（iOS 15 以降の顔検出は向きを連続した値で返す）があれば返す。
    /// faces: ランドマーク検出の結果、angles: 顔の枠の検出の結果（向きはこちらから取る）
    static func faceShape(from faces: [VNFaceObservation], angles: [VNFaceObservation] = []) -> FaceShape? {
        faceShapes(from: faces, angles: angles).first
    }

    /// 顔すべてを大きい順に返す（先頭は faceShape と同じ顔）。
    static func faceShapes(from faces: [VNFaceObservation], angles: [VNFaceObservation] = []) -> [FaceShape] {
        // パーツの取れた顔を優先し、なければ枠だけの顔でもよい
        (faces.isEmpty ? angles : faces).sorted { $0.boundingBox.height > $1.boundingBox.height }
            .map { shape(of: $0, angles: angles) }
    }

    private static func shape(of face: VNFaceObservation, angles: [VNFaceObservation]) -> FaceShape {
        let box = face.boundingBox  // 左下原点
        // 同じ顔（枠の中心がいちばん近いもの）の、連続した角度を使う
        let angleSource = angles.min {
            hypot($0.boundingBox.midX - box.midX, $0.boundingBox.midY - box.midY)
                < hypot($1.boundingBox.midX - box.midX, $1.boundingBox.midY - box.midY)
        } ?? face
        // Vision の yaw は、画像の右を向くと正（確認画像 faces_yaw.png で、横顔 48 枚の向きと照らし合わせて確認）
        let yaw = (angleSource.yaw?.doubleValue ?? 0) * 180 / .pi
        let roll = (angleSource.roll?.doubleValue ?? 0) * 180 / .pi
        var shape = FaceShape(center: CGPoint(x: box.midX, y: 1 - box.midY), height: box.height, yaw: yaw, roll: roll)
        guard let marks = face.landmarks else { return shape }
        let unit = CGSize(width: 1, height: 1)
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            // imageSize を 1x1 にすると、画像全体に対する 0...1 の座標（左下原点）になる
            region?.pointsInImage(imageSize: unit).map { CGPoint(x: $0.x, y: 1 - $0.y) } ?? []
        }
        func center(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            let p = points(region)
            guard !p.isEmpty else { return nil }
            return CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(p.count), y: p.map(\.y).reduce(0, +) / CGFloat(p.count))
        }
        shape.contour = points(marks.faceContour)
        shape.mouth = points(marks.outerLips)
        // 正面に近いときは鼻の中心。横顔では、鼻の点のうち顔の向いている側にいちばん出ている点（鼻先）
        // （中心のままだと頬の上に鼻が描かれていた）
        let nosePoints = points(marks.nose) + points(marks.noseCrest)
        if abs(yaw) >= 35, let noseCenter = center(marks.nose) {
            // 横顔の輪郭の点のうち、鼻の高さにあるものも候補にする（鼻の点は鼻先より内側に出やすい）
            let band = box.height * 0.12
            let candidates = nosePoints + shape.contour.filter { abs($0.y - noseCenter.y) < band }
            let tip = yaw > 0 ? candidates.max { $0.x < $1.x } : candidates.min { $0.x < $1.x }
            shape.nose = tip.map { CGPoint(x: $0.x, y: noseCenter.y) }
        } else {
            shape.nose = center(marks.nose)
        }
        // 横を向くと奥の目は見えないので、正面に近いとき（左右 35 度以内）だけ両目を使う
        if abs(yaw) < 35, let a = center(marks.leftEye), let b = center(marks.rightEye) {
            shape.leftEye = a.x <= b.x ? a : b
            shape.rightEye = a.x <= b.x ? b : a
        }
        return shape
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
    /// skin: 肌・顔のパーツのマスクが要るか、person: 人物の領域が要るか（人物以外をモノクロにするフィルター）
    func beautyMasks(pixelBuffer: CVPixelBuffer, outputSize: CGSize, skin: Bool = true,
                     person: Bool = false, mesh: Bool = false) -> BeautyMasks? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        // 顔の周りで肌の範囲を求め直すのは写真だけ（モデルを顔ごとにもう一度動かすので、プレビューでは加工が遅れてついてくる）
        return perform(handler, source: mesh ? CIImage(cvPixelBuffer: pixelBuffer) : nil, imageSize: outputSize,
                       maskQuality: skin ? .balanced : nil, includePose: false,
                       person: person ? .balanced : nil, refineSkin: false).masks
    }

    /// プレビュー用。肌のモデルだけを動かして肌の範囲を求める（軽いので毎コマ求め、顔が動いても加工が遅れてつかないようにする）。
    /// pixelBuffer はモデルの入力と同じ 256x256 に縮めたコマ。モデルがなければ nil
    func skinMask(pixelBuffer: CVPixelBuffer, outputSize: CGSize) -> CIImage? {
        guard let model = Self.skinModel else { return nil }
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil,
              let buffer = (request.results?.first as? VNPixelBufferObservation)?.pixelBuffer else { return nil }
        return Self.scaled(CIImage(cvPixelBuffer: buffer), to: outputSize)
    }

    /// 写真用。マスクは精度優先で求める。
    func analyze(ciImage: CIImage, wantsMasks: Bool, wantsPerson: Bool = false, wantsMesh: Bool = false) -> Result {
        let handler = VNImageRequestHandler(ciImage: ciImage, orientation: .up, options: [:])
        return perform(handler, source: wantsMesh ? ciImage : nil, imageSize: ciImage.extent.size, maskQuality: wantsMasks ? .accurate : nil,
                       person: wantsPerson ? .accurate : nil)
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

    /// source: handler に渡した画像そのもの。渡したときだけ顔の 478 点を求める（顔を回して切り抜くのに使う）
    private func perform(_ handler: VNImageRequestHandler, source: CIImage? = nil, imageSize: CGSize,
                         maskQuality: VNGeneratePersonSegmentationRequest.QualityLevel?,
                         includePose: Bool = true,
                         person: VNGeneratePersonSegmentationRequest.QualityLevel? = nil,
                         refineSkin: Bool = true) -> Result {
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
        // 人物以外をモノクロにするフィルターでは、肌のモデルがあっても人物の領域を求める
        if let person, segmentation == nil {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = person
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            segmentation = request
            requests.append(request)
        }
        do {
            try handler.perform(requests)
        } catch {
            return Result()
        }

        var result = Result()
        if includePose, let observations = poseRequest.results {
            // 複数人写っているときは、いちばん大きく写っている人を使う（背景の人は小さく写るため）
            let people = observations.map(points(from:)).filter { $0.count >= 4 }
            if let index = PoseMatcher.chooseSubject(from: people, template: nil) { result.pose = people[index] }
        }

        let skinBuffer = (skinRequest?.results?.first as? VNPixelBufferObservation)?.pixelBuffer
        let personBuffer = segmentation?.results?.first?.pixelBuffer
        if skinBuffer != nil || personBuffer != nil {
            let faces = landmarks?.results ?? []
            var skin = skinBuffer.map { Self.scaled(CIImage(cvPixelBuffer: $0), to: imageSize) }
            if refineSkin, let whole = skin, let model = Self.skinModel {
                skin = Self.refineSkinAroundFaces(whole, faces: faces, handler: handler, model: model, imageSize: imageSize)
            }
            result.masks = BeautyMasks(
                skin: skin,
                person: personBuffer.map { Self.scaled(CIImage(cvPixelBuffer: $0), to: imageSize) },
                features: Self.featureMask(faces, imageSize: imageSize, forRedness: false),
                redFeatures: Self.featureMask(faces, imageSize: imageSize, forRedness: true),
                beard: Self.beardMask(faces, imageSize: imageSize),
                jawShade: Self.jawShadeMask(faces, imageSize: imageSize),
                upperFace: Self.upperFaceMask(faces, imageSize: imageSize),
                faceRegion: Self.faceRegion(faces, imageSize: imageSize),
                faceWidth: faces.map { $0.boundingBox.width * imageSize.width }.max(),
                faceMeshes: source.map { Self.faceMeshes(faces, source: $0, imageSize: imageSize) } ?? [])
        }
        return result
    }

    private func points(from observation: VNHumanBodyPoseObservation) -> [Joint: CGPoint] {
        var result: [Joint: CGPoint] = [:]
        for joint in Joint.allCases {
            guard let name = joint.visionName, let point = try? observation.recognizedPoint(name),
                  point.confidence > minimumConfidence else { continue }
            result[joint] = CGPoint(x: point.location.x, y: 1 - point.location.y)
        }
        return result
    }

    /// 顔のまわりだけを切り出して、肌のモデルにもう一度かける。
    /// モデルは 256x256 の画像しか受け取らないので、写真全体を入れると全身の写真では顔が数十マスにしかならず、
    /// 髪の生え際・顔の輪郭・眉の周りの肌の範囲がにじんでいた。顔の周りの正方形だけを入れれば、顔が 256 マスいっぱいになる。
    /// 結果は写真全体の結果の上に、切り出した範囲の縁をなだらかにして重ねる（大きい顔から 2 つまで）。
    private static func refineSkinAroundFaces(_ whole: CIImage, faces: [VNFaceObservation], handler: VNImageRequestHandler,
                                              model: VNCoreMLModel, imageSize: CGSize) -> CIImage {
        let bounds = CGRect(origin: .zero, size: imageSize)
        var result = whole
        var refined = false
        let largest = faces.sorted { $0.boundingBox.width > $1.boundingBox.width }.prefix(2)
        for face in largest {
            let box = face.boundingBox
            let faceRect = CGRect(x: box.minX * imageSize.width, y: box.minY * imageSize.height,
                                  width: box.width * imageSize.width, height: box.height * imageSize.height)
            // 髪の生え際・首まで入るよう、顔の幅の 2.2 倍の正方形（画像からはみ出す分は内側へずらす）
            let side = min(max(faceRect.width, faceRect.height) * 2.2, imageSize.width, imageSize.height)
            // 写真全体の 6 割以上を占めるなら、全体の結果と変わらないので切り出さない
            guard side < max(imageSize.width, imageSize.height) * 0.6, side >= 8 else { continue }
            var square = CGRect(x: faceRect.midX - side / 2, y: faceRect.midY - side / 2, width: side, height: side)
            square.origin.x = min(max(square.minX, 0), imageSize.width - side)
            square.origin.y = min(max(square.minY, 0), imageSize.height - side)

            let request = VNCoreMLRequest(model: model)
            request.imageCropAndScaleOption = .scaleFill
            // Vision の範囲は左下原点の 0...1。CIImage の座標と同じ向き
            request.regionOfInterest = CGRect(x: square.minX / imageSize.width, y: square.minY / imageSize.height,
                                              width: side / imageSize.width, height: side / imageSize.height)
            guard (try? handler.perform([request])) != nil,
                  let buffer = (request.results?.first as? VNPixelBufferObservation)?.pixelBuffer else { continue }
            let crop = CIImage(cvPixelBuffer: buffer)
            let placed = crop
                .transformed(by: CGAffineTransform(scaleX: side / crop.extent.width, y: side / crop.extent.height))
                .transformed(by: CGAffineTransform(translationX: square.minX, y: square.minY))
            // 切り出した範囲の縁（外側 15%）は全体の結果となだらかにつなぐ
            let feather = side * 0.15
            let weight = CIImage(color: .white).cropped(to: square.insetBy(dx: feather, dy: feather))
                .composited(over: CIImage(color: .black))
                .applyingGaussianBlur(sigma: feather * 0.4)
                .cropped(to: bounds)
            result = placed.composited(over: result)
                .applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: result,
                    kCIInputMaskImageKey: weight,
                ])
                .cropped(to: bounds)
            refined = true
        }
        return refined ? bake(result, bounds: bounds) : result
    }

    /// マスクを作るときに使う CIContext（色の変換はしない）
    private static let maskContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    /// 重ねたマスクを、長い辺 512 ピクセルの画像に一度だけ描いておく。
    /// 描かずに渡すと、重ね合わせと縁のぼかしがプレビューの毎コマ描き直されて重くなる（マスクはもともと粗いので画質は変わらない）
    private static func bake(_ mask: CIImage, bounds: CGRect) -> CIImage {
        let scale = min(1, 512 / max(bounds.width, bounds.height))
        let size = CGRect(x: 0, y: 0, width: (bounds.width * scale).rounded(.up), height: (bounds.height * scale).rounded(.up))
        let small = mask.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).cropped(to: size)
        guard let cg = maskContext.createCGImage(small, from: size, format: .RGBA8, colorSpace: nil) else { return mask }
        return CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(scaleX: bounds.width / size.width, y: bounds.height / size.height))
            .cropped(to: bounds)
    }

    /// 顔の 478 点を求めるモデル（Google の MediaPipe Face Mesh V2 を変換したもの）。アプリに入っていなければ nil
    private static let faceMeshModel: VNCoreMLModel? = {
        guard let url = Bundle.main.url(forResource: "FaceLandmarks", withExtension: "mlmodelc") else { return nil }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        guard let model = try? MLModel(contentsOf: url, configuration: configuration) else { return nil }
        return try? VNCoreMLModel(for: model)
    }()

    static var hasFaceMeshModel: Bool { faceMeshModel != nil }

    private static func render256(_ image: CIImage) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        CVPixelBufferCreate(nil, 256, 256, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        guard let buffer else { return nil }
        // 描き終わるまで待ってから判定する（描きかけのコマで点を求めないように）
        let destination = CIRenderDestination(pixelBuffer: buffer)
        guard let task = try? maskContext.startTask(toRender: image, to: destination),
              (try? task.waitUntilCompleted()) != nil else { return nil }
        return buffer
    }

    /// 大きい顔から 2 つまで、顔の 478 点を求める（左下原点・imageSize の座標）。
    /// Vision の顔の枠を 1.5 倍の正方形に広げ、両目が水平になるよう回して 256x256 に切り抜いてモデルに入れる
    /// （MediaPipe と同じ切り抜き方。傾いた顔のままだと点がずれる）。
    private static func faceMeshes(_ faces: [VNFaceObservation], source: CIImage, imageSize: CGSize) -> [[CGPoint]] {
        guard let model = faceMeshModel else { return [] }
        let size = CGFloat(256)
        let origin = source.extent.origin
        let sourceSize = source.extent.size
        let toOutput = CGAffineTransform(scaleX: imageSize.width / sourceSize.width, y: imageSize.height / sourceSize.height)
        var meshes: [[CGPoint]] = []
        for face in faces.sorted(by: { $0.boundingBox.width > $1.boundingBox.width }).prefix(2) {
            let box = face.boundingBox
            let rect = CGRect(x: origin.x + box.minX * sourceSize.width, y: origin.y + box.minY * sourceSize.height,
                              width: box.width * sourceSize.width, height: box.height * sourceSize.height)
            guard rect.width >= 24 else { continue }
            // 両目を結ぶ線の傾き（画像の左にある目 → 右にある目）
            var angle: CGFloat = 0
            if let marks = face.landmarks, let a = marks.leftEye, let b = marks.rightEye {
                func center(_ region: VNFaceLandmarkRegion2D) -> CGPoint {
                    let points = region.pointsInImage(imageSize: sourceSize)
                    let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
                    return CGPoint(x: origin.x + sum.x / CGFloat(max(points.count, 1)),
                                   y: origin.y + sum.y / CGFloat(max(points.count, 1)))
                }
                let p = center(a), q = center(b)
                let (left, right) = p.x < q.x ? (p, q) : (q, p)
                angle = atan2(right.y - left.y, right.x - left.x)
            }
            let side = max(rect.width, rect.height) * 1.5
            // 画像 → 切り抜き（顔の中心を原点へ・傾きを戻す・256 に縮める・切り抜きの中心へ）
            let toCrop = CGAffineTransform(translationX: -rect.midX, y: -rect.midY)
                .concatenating(CGAffineTransform(rotationAngle: -angle))
                .concatenating(CGAffineTransform(scaleX: size / side, y: size / side))
                .concatenating(CGAffineTransform(translationX: size / 2, y: size / 2))
            let crop = source.clampedToExtent().transformed(by: toCrop)
                .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
            let request = VNCoreMLRequest(model: model)
            request.imageCropAndScaleOption = .scaleFill
            // 切り抜きは自分で 256x256 の画像に描いてから渡す（CIImage のまま渡すと Vision が毎回描き直しの準備をして遅い）
            guard let cropBuffer = render256(crop) else { continue }
            let handler = VNImageRequestHandler(cvPixelBuffer: cropBuffer, orientation: .up, options: [:])
            guard (try? handler.perform([request])) != nil,
                  let results = request.results as? [VNCoreMLFeatureValueObservation],
                  let points = results.first(where: { $0.featureName == "landmarks" })?.featureValue.multiArrayValue,
                  let score = results.first(where: { $0.featureName == "face" })?.featureValue.multiArrayValue,
                  score.count > 0, score[0].doubleValue > 0.5, points.count >= 478 * 3 else { continue }
            let toImage = toCrop.inverted().concatenating(
                CGAffineTransform(translationX: -origin.x, y: -origin.y)).concatenating(toOutput)
            var mesh: [CGPoint] = []
            mesh.reserveCapacity(478)
            for i in 0..<478 {
                // モデルの座標は左上原点（下向きが正）なので、左下原点に直す
                let x = CGFloat(points[i * 3].doubleValue)
                let y = size - CGFloat(points[i * 3 + 1].doubleValue)
                mesh.append(CGPoint(x: x, y: y).applying(toImage))
            }
            meshes.append(mesh)
        }
        return meshes
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

    /// 頬（目の下〜鼻の下端、顔の輪郭の内側。鼻は外す）。ひげの生えない肌の色を知るのに使う。
    /// 額は頬より赤みが少なく、混ぜると青ひげ隠しの目標の色が剃り跡の色に近づいて効かなくなるので含めない。
    private static func upperFaceMask(_ faces: [VNFaceObservation], imageSize: CGSize) -> CIImage? {
        drawMask(imageSize: imageSize, blurOfFace: 0.02, faces: faces) { context, size in
            for face in faces {
                guard let marks = face.landmarks, let contour = marks.faceContour,
                      let nose = marks.nose else { continue }
                let points = contour.pointsInImage(imageSize: size)
                let nosePoints = nose.pointsInImage(imageSize: size)
                let eyes = [marks.leftEye, marks.rightEye].compactMap { $0?.pointsInImage(imageSize: size) }.flatMap { $0 }
                guard points.count > 2, let noseBottom = nosePoints.map(\.y).min(),
                      let eyeBottom = eyes.map(\.y).min() else { continue }
                let faceWidth = face.boundingBox.width * size.width
                let box = face.boundingBox
                context.saveGState()
                // 左下原点なので、鼻の下端より上・目の下端より少し下まで
                let top = eyeBottom - faceWidth * 0.04
                guard top > noseBottom else { context.restoreGState(); continue }
                context.clip(to: CGRect(x: 0, y: noseBottom, width: size.width, height: top - noseBottom))
                context.setFillColor(gray: 1, alpha: 1)
                context.beginPath()
                context.addLines(between: points)
                if let last = points.last, let first = points.first {
                    context.addLine(to: CGPoint(x: last.x, y: box.maxY * size.height))
                    context.addLine(to: CGPoint(x: first.x, y: box.maxY * size.height))
                }
                context.closePath()
                context.fillPath()
                // 鼻（小鼻の影・鼻すじのテカリ）は頬の色ではないので外す
                if nosePoints.count > 2 {
                    context.setFillColor(gray: 0, alpha: 1)
                    context.setStrokeColor(gray: 0, alpha: 1)
                    context.setLineWidth(faceWidth * 0.08)
                    context.setLineJoin(.round)
                    context.beginPath()
                    context.addLines(between: nosePoints)
                    context.closePath()
                    context.drawPath(using: .fillStroke)
                }
                context.restoreGState()
            }
        }
    }

    /// 顔の枠を上下左右に顔の幅の半分ずつ広げた範囲（左下原点の画像の座標）。
    /// ひげのマスクはあごの縁の外まで広げてぼかしているので、それより十分広くとる
    private static func faceRegion(_ faces: [VNFaceObservation], imageSize: CGSize) -> CGRect? {
        let boxes = faces.map { face -> CGRect in
            let box = face.boundingBox
            let rect = CGRect(x: box.minX * imageSize.width, y: box.minY * imageSize.height,
                              width: box.width * imageSize.width, height: box.height * imageSize.height)
            return rect.insetBy(dx: -rect.width * 0.5, dy: -rect.width * 0.5)
        }
        guard let first = boxes.first else { return nil }
        return boxes.dropFirst().reduce(first) { $0.union($1) }
            .intersection(CGRect(origin: .zero, size: imageSize)).integral
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
                // 口ひげは鼻のすぐ下から生えるので、鼻の下端のすぐ下まで含める
                context.clip(to: CGRect(x: 0, y: 0, width: size.width, height: noseBottom - faceWidth * 0.005))
                context.setFillColor(gray: 1, alpha: 1)
                context.beginPath()
                context.addLines(between: points)
                context.closePath()
                context.fillPath()
                // 顔の輪郭の点は実際のあごの縁より少し内側にあり、あごの縁・あごの下の剃り跡が範囲から外れて
                // 一部しか消えなかった。輪郭の線を太くなぞって、縁の外側まで広げる
                context.setStrokeColor(gray: 1, alpha: 1)
                // あご下の剃り跡まで届くよう、縁の外側へ顔の幅の 1 割ほど広げる
                context.setLineWidth(faceWidth * 0.17)
                context.setLineJoin(.round)
                context.setLineCap(.round)
                context.beginPath()
                context.addLines(between: points)
                context.strokePath()
                context.restoreGState()
                if let lips = marks.outerLips?.pointsInImage(imageSize: size), lips.count > 2 {
                    context.setFillColor(gray: 0, alpha: 1)
                    context.setStrokeColor(gray: 0, alpha: 1)
                    // 唇の外側を広く外すと、下唇の真下・口ひげの際の剃り跡が残っていた。唇の縁だけ外す
                    context.setLineWidth(faceWidth * 0.012)
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
