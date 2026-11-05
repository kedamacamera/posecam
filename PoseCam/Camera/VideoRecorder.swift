import AVFoundation
import CoreImage

/// 加工済みフレームと音声を .mov に書き出す。呼び出しはすべて同じキュー（映像キュー）から行う。
final class VideoRecorder {
    enum RecorderError: Error {
        case cannotAddInput
        case cannotStart
    }

    private let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var sessionStarted = false
    /// 書き込めたコマの数（失敗の理由を知らせるのに使う）
    private(set) var framesWritten = 0
    private var failureReason: String?

    /// codec は HEVC が使えなければ H.264 で作り直す（CameraManager 側）
    init(url: URL, size: CGSize, audioSettings: [String: Any]?, context: CIContext,
         codec: AVVideoCodecType = .hevc) throws {
        let width = Int(size.width) / 2 * 2
        let height = Int(size.height) / 2 * 2
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecorderError.cannotAddInput }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if let audioSettings {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])

        guard writer.startWriting() else { throw writer.error ?? RecorderError.cannotStart }

        self.url = url
        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.adaptor = adaptor
        self.context = context
    }

    func appendVideo(_ image: CIImage, at time: CMTime) {
        guard writer.status == .writing else {
            noteFailure()
            return
        }
        if !sessionStarted {
            writer.startSession(atSourceTime: time)
            sessionStarted = true
        }
        guard videoInput.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        let bounds = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        context.render(image, to: buffer, bounds: bounds, colorSpace: colorSpace)
        if adaptor.append(buffer, withPresentationTime: time) {
            framesWritten += 1
        } else {
            noteFailure()
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard sessionStarted, writer.status == .writing,
              let audioInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }

    private func noteFailure() {
        guard failureReason == nil else { return }
        let error = writer.error as NSError?
        failureReason = error.map { "\($0.localizedDescription) (\($0.domain) \($0.code))" } ?? "status \(writer.status.rawValue)"
        Diagnostics.log("録画: 書き込み失敗 \(failureReason ?? "")")
    }

    /// 書き出しが終わったら URL を返す。失敗したときは nil と理由を返す。
    func finish(_ completion: @escaping (URL?, String?) -> Void) {
        guard writer.status == .writing, sessionStarted, framesWritten > 0 else {
            noteFailure()
            let reason = framesWritten == 0 ? "映像を 1 コマも書き込めませんでした（\(failureReason ?? "不明")）"
                                            : failureReason
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            completion(nil, reason)
            return
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        let frames = framesWritten
        writer.finishWriting { [writer, url] in
            if writer.status == .completed {
                Diagnostics.log("録画: 書き出し完了 \(frames) コマ")
                completion(url, nil)
            } else {
                let error = writer.error as NSError?
                try? FileManager.default.removeItem(at: url)
                completion(nil, error.map { "\($0.localizedDescription) (\($0.domain) \($0.code))" } ?? "不明")
            }
        }
    }
}
