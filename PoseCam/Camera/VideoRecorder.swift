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
    /// 届いた音声のかたまりの数（書き込み前に捨てたものも含む）と、録画の開始より前の時刻だったもの
    private var audioReceived = 0
    private var audioBeforeStart = 0
    /// 書き込んだ音声の大きさ（マイクの音が本当に入っているかの確認用。0...1 の振幅）
    private var audioPeak: Float = 0
    private var audioSquareSum: Double = 0
    private var audioSampleCount = 0
    private var audioFormat = ""
    private var startTime = CMTime.invalid
    private var failureReason: String?

    var hasAudioTrack: Bool { audioInput != nil }

    /// codec は HEVC が使えなければ H.264 で作り直す（CameraManager 側）
    /// transform: 横向きで撮ったときの回転（画素は縦向きのまま、再生するときに回す）
    init(url: URL, size: CGSize, audioSettings: [String: Any]?, codec: AVVideoCodecType = .hevc,
         transform: CGAffineTransform = .identity) throws {
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
        videoInput.transform = transform
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
            startTime = time
        }
        guard videoInput.isReadyForMoreMediaData else { return }
        if adaptor.append(buffer, withPresentationTime: time) {
            framesWritten += 1
        } else {
            noteFailure()
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        audioReceived += 1
        guard sessionStarted, writer.status == .writing, let audioInput else { return }
        // 録画の開始（最初のコマ）より前に録れた音は入れない（開始音が入らないように）
        if CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), startTime) < 0 {
            audioBeforeStart += 1
            return
        }
        guard audioInput.isReadyForMoreMediaData, audioInput.append(sampleBuffer) else {
            audioDropped += 1
            return
        }
        audioWritten += 1
        measureLevel(sampleBuffer)
    }

    /// 音声の振幅の最大と平均（RMS）を測る。16 ビット整数と 32 ビット浮動小数の PCM に対応
    private func measureLevel(_ sampleBuffer: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return }
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        if audioFormat.isEmpty {
            audioFormat = "\(Int(asbd.mSampleRate))Hz \(asbd.mChannelsPerFrame)ch \(asbd.mBitsPerChannel)bit\(isFloat ? " float" : "")"
        }
        var blockBuffer: CMBlockBuffer?
        var list = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr, let data = list.mBuffers.mData else { return }
        let bytes = Int(list.mBuffers.mDataByteSize)
        if isFloat && asbd.mBitsPerChannel == 32 {
            let samples = data.bindMemory(to: Float.self, capacity: bytes / 4)
            for i in 0..<(bytes / 4) {
                let v = samples[i]
                audioPeak = max(audioPeak, abs(v))
                audioSquareSum += Double(v * v)
            }
            audioSampleCount += bytes / 4
        } else if asbd.mBitsPerChannel == 16 {
            let samples = data.bindMemory(to: Int16.self, capacity: bytes / 2)
            for i in 0..<(bytes / 2) {
                let v = Float(samples[i]) / 32768
                audioPeak = max(audioPeak, abs(v))
                audioSquareSum += Double(v * v)
            }
            audioSampleCount += bytes / 2
        }
    }

    /// 振幅（0...1）をデシベル（dBFS）に。無音は -120
    private static func decibels(_ amplitude: Double) -> String {
        String(format: "%.0f", amplitude > 0 ? max(-120, 20 * log10(amplitude)) : -120)
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
        if audioInput == nil {
            Diagnostics.log("録画: 音声トラックなし（届いた音声 \(audioReceived) 個）")
        } else {
            let rms = audioSampleCount > 0 ? (audioSquareSum / Double(audioSampleCount)).squareRoot() : 0
            // 話し声ならふつう最大 -20 dBFS 前後、平均 -40 dBFS 前後。-90 より小さければほぼ無音
            Diagnostics.log("録画: 音声 届いた \(audioReceived)・書き込み \(audioWritten)・開始前 \(audioBeforeStart)・取りこぼし \(audioDropped)、"
                + "大きさ 最大 \(Self.decibels(Double(audioPeak))) dB・平均 \(Self.decibels(rms)) dB（\(audioFormat)）")
        }
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
