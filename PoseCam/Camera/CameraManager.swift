import AudioToolbox
import AVFoundation
import Combine
import CoreImage
import ImageIO
import UIKit

enum CaptureMode: String, CaseIterable, Identifiable {
    case photo = "写真"
    case video = "動画"
    case snap = "スナップ"

    var id: String { rawValue }
}

enum AspectOption: String, CaseIterable {
    case threeFour = "3:4"
    case nineSixteen = "9:16"
    case full = "フル"

    var next: AspectOption {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// レンズ切り替えボタン 1 つぶん。displayFactor は標準カメラと同じ表示倍率（0.5 / 1 / 2 / 5 など）。
struct LensOption: Identifiable, Equatable {
    let displayFactor: CGFloat
    var id: CGFloat { displayFactor }
}

/// スナップ撮影で撮った短い動画。コマを選ぶ画面に渡す。
struct SnapClip: Identifiable {
    let id = UUID()
    let url: URL
}

/// カメラセッション、フレームごとの加工・検出、写真撮影、録画をまとめて扱う。
///
/// キューの役割:
/// - sessionQueue: セッション構成・デバイス操作
/// - videoQueue: フレーム処理と録画（音声も同じキューで受ける）
/// - detectionQueue: 骨格と人物領域の検出（重いので映像キューを止めないよう分ける）
/// - photoQueue: 撮影した写真の加工と保存
/// @Published なプロパティはメインスレッドでのみ更新する。
final class CameraManager: NSObject, ObservableObject {
    static let matchThreshold: Double = 80
    static let snapMaxSeconds = 10

    // MARK: 状態（表示用）

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

    @Published private(set) var lensOptions: [LensOption] = [LensOption(displayFactor: 1)]
    /// いま実際に使われているレンズ（超広角・広角・望遠）
    @Published private(set) var activeLensName: String?
    @Published private(set) var displayZoom: CGFloat = 1
    @Published private(set) var minDisplayZoom: CGFloat = 1
    @Published private(set) var maxDisplayZoom: CGFloat = 10

    @Published private(set) var countdown: Int?
    @Published private(set) var burstProgress: String?
    @Published private(set) var isSequenceRunning = false
    @Published private(set) var canMuteShutter = false
    @Published var snapClip: SnapClip?

    // MARK: 設定（UI から変える）

    @Published var flashOn = false {
        didSet { applyTorch() }
    }
    @Published var autoShutter = false
    @Published var timerSeconds = 0
    @Published var burstCount = 1
    @Published var muteShutter = false {
        didSet { if mode == .photo { applyPreset(photoModePreset) } }
    }
    @Published var aspect: AspectOption = .threeFour {
        didSet { updateTargetAspect() }
    }
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
    private let maskBox = Locked<BeautyMasks?>(nil)
    private let aspectBox = Locked<CGFloat>(3.0 / 4.0)
    private let modeBox = Locked(CaptureMode.photo)
    private let isDetecting = Locked(false)

    // sessionQueue 専用
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var isConfigured = false
    /// 表示倍率 1x に当たるデバイスの videoZoomFactor（超広角を含むカメラでは 2.0 など）
    private var zoomBase: CGFloat = 1
    private var lensObservation: NSKeyValueObservation?

    // videoQueue 専用
    private var lastDetectionTime: CFTimeInterval = 0
    private var smoothedHipY: CGFloat?
    private var lastFrameSize: CGSize = .zero
    private var wantsRecording = false
    private var recorder: VideoRecorder?
    private var lastRecordedFrame: CIImage?
    /// 無音撮影に使う、加工前の最新のコマ
    private var latestSourceFrame: CIImage?
    private var frameCount = 0

    // メインスレッド専用
    private var screenAspect: CGFloat = 9.0 / 19.5
    private var recordTimer: Timer?
    private var sequenceTimer: Timer?
    private var matchStartedAt: Date?
    private var lastAutoShotAt = Date.distantPast
    private var pendingPhotos = 0

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
        // 録画中の効果音をスピーカーから鳴らすため、音声の設定は自分で行う
        session.automaticallyConfiguresApplicationAudioSession = false
        session.sessionPreset = .photo
        if let device = Self.camera(at: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
        }
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        audioOutput.setSampleBufferDelegate(self, queue: videoQueue)
        session.commitConfiguration()

        updateConnections(position: .back)
        refreshLenses(keepingDisplayZoom: nil)
        Diagnostics.mark("構成: 完了")
    }

    /// 写真は 4:3 の高画質、動画とスナップは 1080p。動画のときだけマイクをつなぐ。
    func setMode(_ newMode: CaptureMode) {
        guard newMode != mode, !isRecording, !isSequenceRunning else { return }
        mode = newMode
        modeBox.value = newMode
        let position = self.position
        let torch = flashOn && newMode != .photo
        let zoom = displayZoom

        let preset = newMode == .photo ? photoModePreset : .hd1920x1080
        let reconfigure = {
            self.sessionQueue.async {
                self.session.beginConfiguration()
                self.session.sessionPreset = self.session.canSetSessionPreset(preset) ? preset : .photo
                if newMode == .video {
                    self.attachAudio()
                } else {
                    self.detachAudio()
                }
                self.session.commitConfiguration()
                self.updateConnections(position: position)
                self.refreshLenses(keepingDisplayZoom: zoom)
                self.setTorch(torch)
            }
        }

        if newMode == .video && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in reconfigure() }
        } else {
            reconfigure()
        }
    }

    /// 無音撮影では映像のコマを写真にするので、写真モードでも 4K の映像を受け取って画素数を稼ぐ。
    private var photoModePreset: AVCaptureSession.Preset {
        muteShutter && !canMuteShutter ? .hd4K3840x2160 : .photo
    }

    private func applyPreset(_ preset: AVCaptureSession.Preset) {
        guard !isRecording, !isSequenceRunning else { return }
        let position = self.position
        let zoom = displayZoom
        sessionQueue.async {
            guard self.isConfigured else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = self.session.canSetSessionPreset(preset) ? preset : .photo
            self.session.commitConfiguration()
            self.updateConnections(position: position)
            self.refreshLenses(keepingDisplayZoom: zoom)
        }
    }

    func flipCamera() {
        guard !isRecording, !isSequenceRunning else { return }
        let newPosition: AVCaptureDevice.Position = position == .back ? .front : .back
        position = newPosition
        let torch = flashOn && mode != .photo

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
            self.refreshLenses(keepingDisplayZoom: nil)
            self.setTorch(torch)
        }
        videoQueue.async { self.smoothedHipY = nil }
    }

    /// 背面は超広角・望遠をまとめた仮想カメラを使い、倍率に応じて iOS がレンズを切り替える。
    private static func camera(at position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInWideAngleCamera]
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video,
                                                       position: position).devices
        for type in types {
            if let device = devices.first(where: { $0.deviceType == type }) { return device }
        }
        return nil
    }

    /// フレームを縦向きにし、インカメラは鏡像にする（プレビュー・写真・動画で揃える）。
    private func updateConnections(position: AVCaptureDevice.Position) {
        let connections = [videoOutput.connection(with: .video), photoOutput.connection(with: .video)]
        for connection in connections.compactMap({ $0 }) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = position == .front
            }
        }
        updatePhotoDimensions()

        var canMute = false
        if #available(iOS 18.0, *) {
            canMute = photoOutput.isShutterSoundSuppressionSupported
        }
        DispatchQueue.main.async { self.canMuteShutter = canMute }
    }

    /// 48MP などの巨大サイズは加工が重いので、12MP 程度までで最大のサイズを選ぶ。
    private func updatePhotoDimensions() {
        guard let device = videoInput?.device else { return }
        func pixels(_ d: CMVideoDimensions) -> Int { Int(d.width) * Int(d.height) }
        let candidates = device.activeFormat.supportedMaxPhotoDimensions
        let best = candidates.filter { pixels($0) <= 12_600_000 }.max { pixels($0) < pixels($1) } ?? candidates.first
        if let best {
            photoOutput.maxPhotoDimensions = best
        }
    }

    private func attachAudio() {
        guard audioInput == nil,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let mic = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: mic),
              session.canAddInput(input) else { return }
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playAndRecord, mode: .videoRecording,
                                      options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try? audioSession.setActive(true)
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
        let on = flashOn && mode != .photo
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

    // MARK: - 比率

    func setScreenAspect(_ value: CGFloat) {
        guard value > 0 else { return }
        screenAspect = value
        updateTargetAspect()
    }

    private func updateTargetAspect() {
        switch aspect {
        case .threeFour: aspectBox.value = 3.0 / 4.0
        case .nineSixteen: aspectBox.value = 9.0 / 16.0
        case .full: aspectBox.value = screenAspect
        }
    }

    // MARK: - レンズ・ズーム

    /// 搭載レンズから倍率ボタン（0.5 / 1 / 2 / 望遠）を作る。sessionQueue から呼ぶ。
    private func refreshLenses(keepingDisplayZoom keep: CGFloat?) {
        guard let device = videoInput?.device else { return }
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        let base: CGFloat = hasUltraWide ? (switchOvers.first ?? 1) : 1
        zoomBase = base

        let minDisplay = device.minAvailableVideoZoomFactor / base
        let maxDisplay = min(device.maxAvailableVideoZoomFactor / base, 15)
        let telephotos = switchOvers.dropFirst(hasUltraWide ? 1 : 0).map { $0 / base }

        var factors: [CGFloat] = [1]
        if hasUltraWide { factors.append(1 / base) }
        if maxDisplay >= 2 { factors.append(2) }
        factors += telephotos
        var unique: [CGFloat] = []
        for factor in factors.sorted() where !unique.contains(where: { abs($0 - factor) < 0.05 }) {
            unique.append(factor)
        }

        let target = min(max(keep ?? 1, minDisplay), maxDisplay)
        setDeviceZoom(target * base, device: device, animated: false)

        // 標準の設定（auto）は条件によってレンズの切り替えを控えるので、倍率に応じて自由に切り替えさせる。
        // ただし被写体が近すぎる・暗いときは、iOS が望遠の代わりに広角を拡大して使う（標準カメラと同じ）。
        lensObservation = nil
        if device.isVirtualDevice {
            do {
                try device.lockForConfiguration()
                device.setPrimaryConstituentDeviceSwitchingBehavior(.unrestricted,
                                                                    restrictedSwitchingBehaviorConditions: [])
                device.unlockForConfiguration()
            } catch {}
            lensObservation = device.observe(\.activePrimaryConstituent, options: [.initial, .new]) { device, _ in
                let name = Self.lensName(device.activePrimaryConstituent?.deviceType)
                DispatchQueue.main.async { self.activeLensName = name }
            }
        } else {
            let name = Self.lensName(device.deviceType)
            DispatchQueue.main.async { self.activeLensName = name }
        }

        DispatchQueue.main.async {
            self.lensOptions = unique.map { LensOption(displayFactor: $0) }
            self.minDisplayZoom = minDisplay
            self.maxDisplayZoom = maxDisplay
            self.displayZoom = target
        }
    }

    private static func lensName(_ type: AVCaptureDevice.DeviceType?) -> String? {
        switch type {
        case .builtInUltraWideCamera: return "超広角レンズ"
        case .builtInWideAngleCamera: return "広角レンズ"
        case .builtInTelephotoCamera: return "望遠レンズ"
        default: return nil
        }
    }

    /// 表示倍率でズームする。レンズボタンは animated で滑らかに切り替える。
    func setDisplayZoom(_ value: CGFloat, animated: Bool = false) {
        let clamped = min(max(value, minDisplayZoom), maxDisplayZoom)
        displayZoom = clamped
        sessionQueue.async {
            guard let device = self.videoInput?.device else { return }
            self.setDeviceZoom(clamped * self.zoomBase, device: device, animated: animated)
        }
    }

    private func setDeviceZoom(_ factor: CGFloat, device: AVCaptureDevice, animated: Bool) {
        let clamped = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
        do {
            try device.lockForConfiguration()
            if animated {
                device.ramp(toVideoZoomFactor: clamped, withRate: 12)
            } else {
                device.videoZoomFactor = clamped
            }
            device.unlockForConfiguration()
        } catch {}
    }

    // MARK: - シャッター

    func shutterPressed() {
        switch mode {
        case .photo:
            if isSequenceRunning {
                cancelSequence()
            } else {
                startPhotoSequence()
            }
        case .video, .snap:
            if countdown != nil {
                cancelSequence()
            } else if isRecording {
                stopRecording()
            } else {
                countdownThen(timerSeconds) { self.startRecording() }
            }
        }
    }

    /// タイマー → 1 秒間隔で burstCount 枚撮る。
    private func startPhotoSequence() {
        guard !isSequenceRunning else { return }
        isSequenceRunning = true
        let total = burstCount
        countdownThen(timerSeconds) { self.takeShots(remaining: total, total: total) }
    }

    private func countdownThen(_ seconds: Int, action: @escaping () -> Void) {
        guard seconds > 0 else {
            action()
            return
        }
        isSequenceRunning = true
        countdown = seconds
        AudioServicesPlaySystemSound(1103)
        sequenceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let next = (self.countdown ?? 1) - 1
            if next <= 0 {
                timer.invalidate()
                self.countdown = nil
                if self.mode != .photo { self.isSequenceRunning = false }
                action()
            } else {
                self.countdown = next
                AudioServicesPlaySystemSound(1103)
            }
        }
    }

    private func takeShots(remaining: Int, total: Int) {
        guard isSequenceRunning, remaining > 0 else {
            finishSequence()
            return
        }
        if total > 1 { burstProgress = "\(total - remaining + 1)/\(total)" }
        capturePhoto()
        guard remaining > 1 else {
            finishSequence()
            return
        }
        sequenceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            self?.takeShots(remaining: remaining - 1, total: total)
        }
    }

    private func cancelSequence() {
        sequenceTimer?.invalidate()
        sequenceTimer = nil
        countdown = nil
        burstProgress = nil
        isSequenceRunning = false
    }

    private func finishSequence() {
        sequenceTimer?.invalidate()
        sequenceTimer = nil
        isSequenceRunning = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if !self.isSequenceRunning { self.burstProgress = nil }
        }
    }

    // MARK: - 写真

    private func capturePhoto() {
        pendingPhotos += 1
        isCapturing = true
        let flash = flashOn
        let mute = muteShutter

        // iOS が消音を許可していない機種（日本向けなど）では、映像のコマを写真として保存する
        if mute && !canMuteShutter {
            captureSilently()
            return
        }

        sessionQueue.async {
            guard self.photoOutput.connection(with: .video)?.isActive == true else {
                DispatchQueue.main.async { self.photoFinished() }
                return
            }
            let photoSettings = self.photoOutput.availablePhotoCodecTypes.contains(.hevc)
                ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                : AVCapturePhotoSettings()
            if flash, self.photoOutput.supportedFlashModes.contains(.on) {
                photoSettings.flashMode = .on
            }
            if mute, #available(iOS 18.0, *), self.photoOutput.isShutterSoundSuppressionSupported {
                photoSettings.isShutterSoundSuppressionEnabled = true
            }
            photoSettings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            self.photoOutput.capturePhoto(with: photoSettings, delegate: self)
        }
    }

    private func photoFinished() {
        pendingPhotos = max(0, pendingPhotos - 1)
        isCapturing = pendingPhotos > 0
    }

    /// 無音撮影。最新の映像のコマ（加工前・フル解像度）を写真と同じ手順で加工して保存する。
    private func captureSilently() {
        let settings = settingsBox.value
        let aspect = aspectBox.value
        videoQueue.async {
            guard let frame = self.latestSourceFrame else {
                DispatchQueue.main.async { self.photoFinished() }
                return
            }
            self.photoQueue.async {
                defer { DispatchQueue.main.async { self.photoFinished() } }
                guard let result = self.processStill(frame, settings: settings, aspect: aspect) else {
                    self.report("写真の処理に失敗しました")
                    return
                }
                self.save(result)
            }
        }
    }

    private func save(_ result: (jpeg: Data, thumbnail: UIImage?)) {
        MediaSaver.savePhoto(result.jpeg) { ok in
            if ok {
                DispatchQueue.main.async { self.lastThumbnail = result.thumbnail }
            } else {
                self.report("写真を保存できませんでした（写真へのアクセス許可を確認してください）")
            }
        }
    }

    private func processPhoto(_ data: Data, settings: ProcessingSettings,
                              aspect: CGFloat) -> (jpeg: Data, thumbnail: UIImage?)? {
        guard let source = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        return processStill(source, settings: settings, aspect: aspect)
    }

    private func processStill(_ source: CIImage, settings: ProcessingSettings,
                              aspect: CGFloat) -> (jpeg: Data, thumbnail: UIImage?)? {
        let normalized = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX,
                                                                  y: -source.extent.minY))
        let image = FrameGeometry(sourceSize: normalized.extent.size, aspect: aspect, maxLongSide: nil)
            .apply(normalized)

        let wantsMasks = settings.smoothing > 0.01 || settings.brightening > 0.01
        var analysis = PoseDetector.Result()
        if wantsMasks || settings.legLength > 0.01 {
            analysis = detector.analyze(ciImage: image, wantsMasks: wantsMasks)
        }
        let hipY = analysis.pose.flatMap(PoseDetector.hipY(of:))
        let output = processor.process(image, settings: settings, hipY: hipY, masks: analysis.masks)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = renderer.ciContext.jpegRepresentation(
                  of: output, colorSpace: colorSpace,
                  options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92])
        else { return nil }
        return (jpeg, makeThumbnail(output))
    }

    func makeThumbnail(_ image: CIImage) -> UIImage? {
        let scale = 240 / max(image.extent.width, image.extent.height)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = renderer.ciContext.createCGImage(small, from: small.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    func setThumbnail(_ image: UIImage?) {
        lastThumbnail = image
    }

    // MARK: - 動画・スナップ

    func stopRecordingIfNeeded() {
        if isRecording { stopRecording() }
        if isSequenceRunning { cancelSequence() }
    }

    private func startRecording() {
        guard mode != .photo, !isRecording else { return }
        isRecording = true
        recordingSeconds = 0
        AudioServicesPlaySystemSound(1117)
        recordTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.recordingSeconds += 1
            if self.mode == .snap && self.recordingSeconds >= Self.snapMaxSeconds {
                self.stopRecording()
            }
        }
        // 開始音が録音に入らないよう、少し待ってから書き込みを始める
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard self.isRecording else { return }
            self.videoQueue.async { self.wantsRecording = true }
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recordTimer?.invalidate()
        recordTimer = nil
        let isSnap = mode == .snap

        videoQueue.async {
            self.wantsRecording = false
            guard let recorder = self.recorder else { return }
            self.recorder = nil
            let thumbnail = self.lastRecordedFrame.flatMap { self.makeThumbnail($0) }
            self.lastRecordedFrame = nil

            recorder.finish { url in
                DispatchQueue.main.async { AudioServicesPlaySystemSound(1118) }
                guard let url else {
                    self.report("動画の書き出しに失敗しました")
                    return
                }
                if isSnap {
                    DispatchQueue.main.async { self.snapClip = SnapClip(url: url) }
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
            let audioSettings = modeBox.value == .video
                ? audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov)
                : nil
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

    // MARK: - 検出・自動シャッター

    /// videoQueue から呼ぶ。前回の検出が終わっていて、前回から一定時間たっていれば検出する。
    private func analyzeIfIdle(_ pixelBuffer: CVPixelBuffer, geometry: FrameGeometry, wantsMasks: Bool) {
        let now = CACurrentMediaTime()
        guard now - lastDetectionTime > 0.07, !isDetecting.value else { return }
        lastDetectionTime = now
        isDetecting.value = true

        detectionQueue.async {
            let result = self.detector.analyze(pixelBuffer: pixelBuffer, wantsMasks: wantsMasks)
            let pose = result.pose?.mapValues { geometry.convert($0) }
            self.poseBox.value = pose
            self.maskBox.value = result.masks
            var score: Double?
            if let pose, let template = self.templateBox.value {
                let isotropic = pose.mapValues { PoseSpace.toIsotropic($0, aspect: geometry.aspect) }
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
        guard autoShutter, mode == .photo, !isSequenceRunning,
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
            startPhotoSequence()
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

    func report(_ message: String) {
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

        // 最初の 1 コマだけ記録し、1 秒ほど動いたら正常とみなす
        frameCount += 1
        if frameCount == 1 {
            Diagnostics.mark("フレーム: 初回受信 \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))")
        }
        if frameCount == 30 { Diagnostics.markHealthy() }

        let source = CIImage(cvPixelBuffer: pixelBuffer)
        latestSourceFrame = source
        // 録画中は途中で大きさが変わらないよう比率を固定する（UI 側でも比率ボタンを無効にしている）
        let geometry = FrameGeometry(sourceSize: source.extent.size, aspect: aspectBox.value, maxLongSide: 1920)
        let settings = settingsBox.value
        let wantsMasks = settings.smoothing > 0.01 || settings.brightening > 0.01
        analyzeIfIdle(pixelBuffer, geometry: geometry, wantsMasks: wantsMasks)

        let image = geometry.apply(source)
        publishFrameSizeIfNeeded(image.extent.size)

        var masks: BeautyMasks?
        // 前後カメラの切り替え直後などで大きさの違う古いマスクは使わない
        if wantsMasks, let stored = maskBox.value,
           abs(stored.person.extent.width - source.extent.width) < 1,
           abs(stored.person.extent.height - source.extent.height) < 1 {
            masks = BeautyMasks(person: geometry.apply(stored.person),
                                features: stored.features.map { geometry.apply($0) })
        }
        let hipY = settings.legLength > 0.01 ? updatedHipY() : nil
        let processed = processor.process(image, settings: settings, hipY: hipY, masks: masks)
        renderer.display(processed)
        handleRecording(processed, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}

// MARK: - 写真受信

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        let settings = settingsBox.value
        let aspect = aspectBox.value
        let data = photo.fileDataRepresentation()

        photoQueue.async {
            defer { DispatchQueue.main.async { self.photoFinished() } }
            guard error == nil, let data,
                  let result = self.processPhoto(data, settings: settings, aspect: aspect) else {
                self.report("写真の処理に失敗しました")
                return
            }
            self.save(result)
        }
    }
}
