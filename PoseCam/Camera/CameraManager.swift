import AVFoundation
import Combine
import CoreImage
import ImageIO
import UIKit

enum CaptureMode: String, CaseIterable, Identifiable {
    case photo = "写真"
    case video = "動画"

    var id: String { rawValue }
}

/// カメラセッション、フレームごとの加工・骨格検出、写真撮影、録画をまとめて扱う。
///
/// キューの役割:
/// - sessionQueue: セッション構成・デバイス操作
/// - videoQueue: フレーム処理と録画（音声も同じキューで受ける）
/// - detectionQueue: 骨格検出（重いので映像キューを止めないよう分ける）
/// - photoQueue: 撮影した写真の加工と保存
/// @Published なプロパティはメインスレッドでのみ更新する。
final class CameraManager: NSObject, ObservableObject {
    static let matchThreshold: Double = 80

    @Published private(set) var mode: CaptureMode = .photo
    @Published private(set) var position: AVCaptureDevice.Position = .back
    @Published private(set) var isRecording = false
    @Published private(set) var recordingSeconds = 0
    @Published private(set) var isCapturing = false
    @Published private(set) var frameAspect: CGFloat = 3.0 / 4.0
    @Published private(set) var detectedPose: [Joint: CGPoint]?
    @Published private(set) var matchScore: Double?
    @Published private(set) var lastThumbnail: UIImage?
    @Published private(set) var cameraAuthorized = true
    @Published private(set) var statusMessage: String?

    @Published var flashOn = false {
        didSet { applyTorch() }
    }
    @Published var autoShutter = false
    @Published var settings = ProcessingSettings() {
        didSet { settingsBox.value = settings }
    }
    @Published var template: PoseTemplate? {
        didSet {
            templateBox.value = template
            if template == nil { matchScore = nil }
        }
    }

    let renderer = PreviewRenderer()

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "posecam.session")
    private let videoQueue = DispatchQueue(label: "posecam.video", qos: .userInitiated)
    private let detectionQueue = DispatchQueue(label: "posecam.detection", qos: .userInitiated)
    private let photoQueue = DispatchQueue(label: "posecam.photo", qos: .userInitiated)

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let photoOutput = AVCapturePhotoOutput()

    private let processor = FrameProcessor()
    private let detector = PoseDetector()
    private let settingsBox = Locked(ProcessingSettings())
    private let templateBox = Locked<PoseTemplate?>(nil)
    private let poseBox = Locked<[Joint: CGPoint]?>(nil)
    private let isDetecting = Locked(false)

    // sessionQueue 専用
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var isConfigured = false

    // videoQueue 専用
    private var lastDetectionTime: CFTimeInterval = 0
    private var smoothedHipY: CGFloat?
    private var lastFrameSize: CGSize = .zero
    private var wantsRecording = false
    private var recorder: VideoRecorder?
    private var lastRecordedFrame: CIImage?
    private var frameCount = 0

    // detectionQueue 専用
    private var hasDetectedOnce = false

    // メインスレッド専用
    private var recordTimer: Timer?
    private var matchStartedAt: Date?
    private var lastAutoShotAt = Date.distantPast

    // MARK: - セッション

    func start() {
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            await MainActor.run { self.cameraAuthorized = granted }
            Diagnostics.mark("カメラ許可: \(granted)")
            guard granted else { return }
            sessionQueue.async {
                self.configureIfNeeded()
                if !self.session.isRunning {
                    Diagnostics.mark("startRunning 開始")
                    self.session.startRunning()
                    Diagnostics.mark("startRunning 完了")
                }
            }
        }
    }

    private func configureIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true

        Diagnostics.mark("構成: 開始")
        session.beginConfiguration()
        session.sessionPreset = .photo
        Diagnostics.mark("構成: 入力を追加")
        if let device = Self.camera(at: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
        }
        Diagnostics.mark("構成: 映像出力の設定")
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.deliversPreviewSizedOutputBuffers = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        Diagnostics.mark("構成: 出力を追加")
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        audioOutput.setSampleBufferDelegate(self, queue: videoQueue)
        Diagnostics.mark("構成: commit")
        session.commitConfiguration()

        updateConnections(position: .back)
        Diagnostics.mark("構成: 完了")
    }

    /// 写真は 4:3 の高画質、動画は 9:16 の 1080p。動画モードのときだけマイクをつなぐ。
    func setMode(_ newMode: CaptureMode) {
        guard newMode != mode, !isRecording else { return }
        mode = newMode
        let position = self.position
        let torch = flashOn && newMode == .video

        let reconfigure = {
            self.sessionQueue.async {
                self.session.beginConfiguration()
                self.session.sessionPreset = newMode == .photo ? .photo : .hd1920x1080
                // 写真モードはプレビュー用の小さいフレームで十分。動画は書き出すのでフルサイズで受ける
                self.videoOutput.deliversPreviewSizedOutputBuffers = newMode == .photo
                if newMode == .video {
                    self.attachAudio()
                } else {
                    self.detachAudio()
                }
                self.session.commitConfiguration()
                self.updateConnections(position: position)
                self.setTorch(torch)
            }
        }

        if newMode == .video && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in reconfigure() }
        } else {
            reconfigure()
        }
    }

    func flipCamera() {
        guard !isRecording else { return }
        let newPosition: AVCaptureDevice.Position = position == .back ? .front : .back
        position = newPosition
        let torch = flashOn && mode == .video

        sessionQueue.async {
            guard let device = Self.camera(at: newPosition),
                  let newInput = try? AVCaptureDeviceInput(device: device) else { return }
            self.session.beginConfiguration()
            if let old = self.videoInput { self.session.removeInput(old) }
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.videoInput = newInput
            } else if let old = self.videoInput {
                self.session.addInput(old)
            }
            self.session.commitConfiguration()
            self.updateConnections(position: newPosition)
            self.setTorch(torch)
        }
        videoQueue.async { self.smoothedHipY = nil }
    }

    func setZoom(_ factor: CGFloat) {
        sessionQueue.async {
            guard let device = self.videoInput?.device else { return }
            let upper = min(device.maxAvailableVideoZoomFactor, 8)
            let clamped = min(max(factor, device.minAvailableVideoZoomFactor), upper)
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
            } catch {}
        }
    }

    private static func camera(at position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    /// フレームを縦向きにし、インカメラは鏡像にする（プレビュー・写真・動画で揃える）。
    private func updateConnections(position: AVCaptureDevice.Position) {
        let connections = [videoOutput.connection(with: .video), photoOutput.connection(with: .video)]
        Diagnostics.mark("接続: 向きと鏡像の設定（\(connections.compactMap { $0 }.count) 本）")
        for connection in connections.compactMap({ $0 }) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = position == .front
            }
        }
        Diagnostics.mark("接続: 写真サイズの設定")
        updatePhotoDimensions()
    }

    /// 48MP などの巨大サイズは加工が重いので、12MP 程度までで最大のサイズを選ぶ。
    private func updatePhotoDimensions() {
        guard let device = videoInput?.device else { return }
        func pixels(_ d: CMVideoDimensions) -> Int { Int(d.width) * Int(d.height) }
        let candidates = device.activeFormat.supportedMaxPhotoDimensions
        let best = candidates.filter { pixels($0) <= 12_600_000 }.max { pixels($0) < pixels($1) } ?? candidates.first
        if let best {
            Diagnostics.mark("写真サイズ: \(best.width)x\(best.height)（候補 \(candidates.count) 個）")
            photoOutput.maxPhotoDimensions = best
        }
    }

    private func attachAudio() {
        guard audioInput == nil,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let mic = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: mic),
              session.canAddInput(input) else { return }
        session.addInput(input)
        audioInput = input
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        }
    }

    private func detachAudio() {
        if let audioInput {
            session.removeInput(audioInput)
            self.audioInput = nil
        }
        if session.outputs.contains(where: { $0 === audioOutput }) {
            session.removeOutput(audioOutput)
        }
    }

    private func applyTorch() {
        let on = flashOn && mode == .video
        sessionQueue.async { self.setTorch(on) }
    }

    private func setTorch(_ on: Bool) {
        guard let device = videoInput?.device, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        } catch {}
    }

    // MARK: - 写真

    func capturePhoto() {
        guard mode == .photo, !isCapturing else { return }
        isCapturing = true
        let flash = flashOn

        sessionQueue.async {
            guard self.photoOutput.connection(with: .video)?.isActive == true else {
                DispatchQueue.main.async { self.isCapturing = false }
                return
            }
            let photoSettings = self.photoOutput.availablePhotoCodecTypes.contains(.hevc)
                ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                : AVCapturePhotoSettings()
            if flash, self.photoOutput.supportedFlashModes.contains(.on) {
                photoSettings.flashMode = .on
            }
            photoSettings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            self.photoOutput.capturePhoto(with: photoSettings, delegate: self)
        }
    }

    private func processPhoto(_ data: Data, settings: ProcessingSettings) -> (jpeg: Data, thumbnail: UIImage?)? {
        guard let source = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        let image = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX,
                                                             y: -source.extent.minY))
        var hipY: CGFloat?
        if settings.legLength > 0.01, let pose = detector.detect(ciImage: image) {
            hipY = PoseDetector.hipY(of: pose)
        }
        let output = processor.process(image, settings: settings, hipY: hipY)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = renderer.ciContext.jpegRepresentation(
                  of: output, colorSpace: colorSpace,
                  options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92])
        else { return nil }
        return (jpeg, makeThumbnail(output))
    }

    private func makeThumbnail(_ image: CIImage) -> UIImage? {
        let scale = 240 / max(image.extent.width, image.extent.height)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = renderer.ciContext.createCGImage(small, from: small.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - 動画

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func stopRecordingIfNeeded() {
        if isRecording { stopRecording() }
    }

    private func startRecording() {
        guard mode == .video, !isRecording else { return }
        isRecording = true
        recordingSeconds = 0
        recordTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.recordingSeconds += 1
        }
        videoQueue.async { self.wantsRecording = true }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recordTimer?.invalidate()
        recordTimer = nil

        videoQueue.async {
            self.wantsRecording = false
            guard let recorder = self.recorder else { return }
            self.recorder = nil
            let thumbnail = self.lastRecordedFrame.flatMap { self.makeThumbnail($0) }
            self.lastRecordedFrame = nil

            recorder.finish { url in
                guard let url else {
                    self.report("動画の書き出しに失敗しました")
                    return
                }
                MediaSaver.saveVideo(at: url) { ok in
                    if ok {
                        DispatchQueue.main.async { self.lastThumbnail = thumbnail }
                    } else {
                        self.report("動画を保存できませんでした（写真へのアクセス許可を確認してください）")
                    }
                }
            }
        }
    }

    /// videoQueue から呼ぶ。
    private func handleRecording(_ image: CIImage, at time: CMTime) {
        guard wantsRecording else { return }
        if recorder == nil {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            let audioSettings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov)
            do {
                recorder = try VideoRecorder(url: url, size: image.extent.size,
                                             audioSettings: audioSettings, context: renderer.ciContext)
            } catch {
                wantsRecording = false
                report("録画を開始できませんでした")
                DispatchQueue.main.async { self.stopRecording() }
                return
            }
        }
        recorder?.appendVideo(image, at: time)
        lastRecordedFrame = image
    }

    // MARK: - 骨格検出・自動シャッター

    /// videoQueue から呼ぶ。前回の検出が終わっていて、前回から一定時間たっていれば検出する。
    private func detectPoseIfIdle(_ pixelBuffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        guard now - lastDetectionTime > 0.07, !isDetecting.value else { return }
        lastDetectionTime = now
        isDetecting.value = true
        let aspect = CGFloat(CVPixelBufferGetWidth(pixelBuffer)) / CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        detectionQueue.async {
            let first = !self.hasDetectedOnce
            self.hasDetectedOnce = true
            if first { Diagnostics.mark("骨格検出: 初回開始") }
            let pose = self.detector.detect(pixelBuffer: pixelBuffer)
            if first { Diagnostics.mark("骨格検出: 初回完了（関節 \(pose?.count ?? 0) 個）") }
            self.poseBox.value = pose
            var score: Double?
            if let pose, let template = self.templateBox.value {
                let isotropic = pose.mapValues { PoseSpace.toIsotropic($0, aspect: aspect) }
                score = PoseMatcher.score(template: template.joints, detected: isotropic)
            }
            self.isDetecting.value = false

            DispatchQueue.main.async {
                self.detectedPose = pose
                self.matchScore = self.template == nil ? nil : score
                self.evaluateAutoShutter()
            }
        }
    }

    /// 一致度がしきい値を 0.8 秒保ったら自動で撮影する。連写しないよう 3 秒あける。
    private func evaluateAutoShutter() {
        guard autoShutter, mode == .photo, !isCapturing,
              let score = matchScore, score >= Self.matchThreshold else {
            matchStartedAt = nil
            return
        }
        let now = Date()
        let startedAt = matchStartedAt ?? now
        matchStartedAt = startedAt
        if now.timeIntervalSince(startedAt) >= 0.8, now.timeIntervalSince(lastAutoShotAt) > 3 {
            lastAutoShotAt = now
            matchStartedAt = nil
            capturePhoto()
        }
    }

    /// 腰の高さを少しずつ追従させ、脚長加工の境目がちらつかないようにする。videoQueue から呼ぶ。
    private func updatedHipY() -> CGFloat? {
        guard let pose = poseBox.value, let y = PoseDetector.hipY(of: pose) else { return smoothedHipY }
        let smoothed = smoothedHipY.map { $0 * 0.8 + y * 0.2 } ?? y
        smoothedHipY = smoothed
        return smoothed
    }

    private func publishFrameSizeIfNeeded(_ size: CGSize) {
        guard size != lastFrameSize, size.height > 0 else { return }
        lastFrameSize = size
        DispatchQueue.main.async { self.frameAspect = size.width / size.height }
    }

    private func report(_ message: String) {
        DispatchQueue.main.async {
            self.statusMessage = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if self.statusMessage == message { self.statusMessage = nil }
            }
        }
    }
}

// MARK: - フレーム受信

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === audioOutput {
            recorder?.appendAudio(sampleBuffer)
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // 最初の 1 コマだけ各段階を記録し、3 秒ほど動いたら正常とみなす
        frameCount += 1
        let first = frameCount == 1
        if first {
            Diagnostics.mark("フレーム: 初回受信 \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))")
        }
        if frameCount == 90 { Diagnostics.markHealthy() }

        detectPoseIfIdle(pixelBuffer)
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        publishFrameSizeIfNeeded(image.extent.size)

        let settings = settingsBox.value
        let hipY = settings.legLength > 0.01 ? updatedHipY() : nil
        if first { Diagnostics.mark("フレーム: 加工") }
        let processed = processor.process(image, settings: settings, hipY: hipY)
        if first { Diagnostics.mark("フレーム: 表示へ渡す") }
        renderer.display(processed)
        handleRecording(processed, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}

// MARK: - 写真受信

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        let settings = settingsBox.value
        let data = photo.fileDataRepresentation()

        photoQueue.async {
            defer { DispatchQueue.main.async { self.isCapturing = false } }
            guard error == nil, let data, let result = self.processPhoto(data, settings: settings) else {
                self.report("写真の処理に失敗しました")
                return
            }
            MediaSaver.savePhoto(result.jpeg) { ok in
                if ok {
                    DispatchQueue.main.async { self.lastThumbnail = result.thumbnail }
                } else {
                    self.report("写真を保存できませんでした（写真へのアクセス許可を確認してください）")
                }
            }
        }
    }
}
