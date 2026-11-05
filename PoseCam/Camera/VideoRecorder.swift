import AVFoundation
import CoreImage

/// 加工済みフレームと音声を .mov に書き出す。呼び出しはすべて同じキュー（録画のキュー）から行う。
final class VideoRecorder {
    enum RecorderError: Error {
        case cannotAddInput
        case cannotStart
    }

    /// 書き出しの結果。partial は、書き出しの仕上げに失敗したが、途中まで（最後の区切りまで）は再生できるファイル
    struct Outcome {
        let url: URL?
        let failure: String?
        var partial: Bool { url != nil && failure != nil }
    }

    /// 音声の設定がカメラから取れないときに使う AAC（モノラル）
    static let fallbackAudioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 128_000,
    ]

    private let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var sessionStarted = false
    /// 書き込めたコマの数（失敗の理由を知らせるのに使う）
    private(set) var framesWritten = 0
    /// 書き込めた音声・書き込めなかった音声のかたまりの数（マイクが録れているかの確認用）
    private var audioWritten = 0
    private var audioDropped = 0
    private var failureReason: String?

    var hasAudioTrack: Bool { audioInput != nil }

    /// codec は HEVC が使えなければ H.264 で作り直す（CameraManager 側）
    init(url: URL, size: CGSize, audioSettings: [String: Any]?, codec: AVVideoCodecType = .hevc) throws {
        let width = Int(size.width) / 2 * 2
        let height = Int(size.height) / 2 * 2
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // 1 秒ごとに区切って書く。アプリを閉じられる・仕上げに失敗するなどで最後まで書けなくても、
        // 最後の区切りまでは再生できるファイルとして残る
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)

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
            } else {
                Diagnostics.log("録画: 音声のトラックを追加できず")
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
    }

    /// buffer は加工済みのコマを描いた入れ物（大きさは書き出しと同じ）
    func appendVideo(_ buffer: CVPixelBuffer, at time: CMTime) {
        guard writer.status == .writing else {
            noteFailure()
            return
        }
        if !sessionStarted {
            writer.startSession(atSourceTime: time)
            sessionStarted = true
        }
        guard videoInput.isReadyForMoreMediaData else { return }
        if adaptor.append(buffer, withPresentationTime: time) {
            framesWritten += 1
        } else {
            noteFailure()
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard sessionStarted, writer.status == .writing, let audioInput else { return }
        guard audioInput.isReadyForMoreMediaData, audioInput.append(sampleBuffer) else {
            audioDropped += 1
            return
        }
        audioWritten += 1
    }

    private func noteFailure() {
        guard failureReason == nil else { return }
        let error = writer.error as NSError?
        failureReason = error.map { "\($0.localizedDescription) (\($0.domain) \($0.code))" } ?? "status \(writer.status.rawValue)"
        Diagnostics.log("録画: 書き込み失敗 \(failureReason ?? "")")
    }

    /// 書き出しが終わったら結果を返す。仕上げに失敗しても、コマを書けていればファイルは残して返す
    /// （1 秒ごとに区切って書いているので、途中までは再生できる）。
    func finish(_ completion: @escaping (Outcome) -> Void) {
        Diagnostics.log("録画: 音声 \(audioInput == nil ? "トラックなし" : "\(audioWritten) 個 書き込み・\(audioDropped) 個 取りこぼし")")
        guard sessionStarted, framesWritten > 0 else {
            noteFailure()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            completion(Outcome(url: nil, failure: "映像を 1 コマも書き込めませんでした（\(failureReason ?? "不明")）"))
            return
        }
        guard writer.status == .writing else {
            noteFailure()
            completion(Outcome(url: url, failure: failureReason))
            return
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        let frames = framesWritten
        writer.finishWriting { [writer, url] in
            if writer.status == .completed {
                Diagnostics.log("録画: 書き出し完了 \(frames) コマ")
                completion(Outcome(url: url, failure: nil))
            } else {
                let error = writer.error as NSError?
                let reason = error.map { "\($0.localizedDescription) (\($0.domain) \($0.code))" } ?? "不明"
                Diagnostics.log("録画: 仕上げに失敗 \(reason)")
                completion(Outcome(url: url, failure: reason))
            }
        }
    }
}
