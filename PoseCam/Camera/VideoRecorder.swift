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

    init(url: URL, size: CGSize, audioSettings: [String: Any]?, context: CIContext) throws {
        let width = Int(size.width) / 2 * 2
        let height = Int(size.height) / 2 * 2
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
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
        guard writer.status == .writing else { return }
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
        adaptor.append(buffer, withPresentationTime: time)
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard sessionStarted, writer.status == .writing,
              let audioInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }

    /// 書き出しが終わったら URL を返す。1 フレームも書けていなければ nil。
    func finish(_ completion: @escaping (URL?) -> Void) {
        guard writer.status == .writing, sessionStarted else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            completion(nil)
            return
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting { [writer, url] in
            if writer.status == .completed {
                completion(url)
            } else {
                try? FileManager.default.removeItem(at: url)
                completion(nil)
            }
        }
    }
}
