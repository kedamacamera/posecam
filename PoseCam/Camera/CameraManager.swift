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

enum AspectOption: String, CaseIterable, Identifiable {
    case square = "1:1"
    case threeFour = "3:4"
    case nineSixteen = "9:16"
    case full = "フル"

    var id: String { rawValue }

    /// 横 / 縦。フルは画面の比率なので nil
    var ratio: CGFloat? {
        switch self {
        case .square: return 1
        case .threeFour: return 3.0 / 4.0
        case .nineSixteen: return 9.0 / 16.0
        case .full: return nil
        }
    }
}

/// 骨格の検出結果と一致度。1 秒に十数回変わるので、カメラ全体（CameraManager）とは分けて、
/// これを使う小さなビューだけが描き直されるようにする（画面全体を描き直すと重くなる）。
final class PoseFeed: ObservableObject {
    @Published fileprivate(set) var detected: [Joint: CGPoint]?
    @Published fileprivate(set) var score: Double?
}

/// レンズ切り替えボタン 1 つぶん。displayFactor は標準カメラと同じ表示倍率（0.5 / 1 / 2 / 5 など）。
struct LensOption: Identifiable, Equatable {
    let displayFactor: CGFloat
    var id: CGFloat { displayFactor }
}

/// 連続撮影の予定。1 枚目を撮る時刻と間隔から、次のシャッターまでの残りを計算できる。
struct BurstTimeline: Equatable {
    let firstShot: Date
    let interval: Double
    let total: Int
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
    let poseFeed = PoseFeed()
    /// 撮影した瞬間に 1 増える（画面を一瞬暗くして、シャッターが切れたことを知らせる）
    @Published private(set) var shutterCount = 0
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
    /// 連続撮影の予定（画面の「減っていく円」の表示に使う）
    @Published private(set) var burstTimeline: BurstTimeline?
    @Published private(set) var isSequenceRunning = false
    @Published private(set) var canMuteShutter = false
    @Published var snapClip: SnapClip?

    // MARK: 設定（UI から変える）

    @Published var flashOn = false {
        didSet { applyTorch() }
    }
    @Published var autoShutter = false {
        didSet { updatePoseNeeded() }
    }
    @Published var showSkeleton = false {
        didSet { updatePoseNeeded() }
    }
    @Published var timerSeconds = 0
    @Published var burstCount = 1
    /// 連続撮影の間隔（秒）
    @Published var burstInterval: Double = 1
    @Published var muteShutter = false {
        didSet { if mode == .photo { applyPreset(photoModePreset) } }
    }
    @Published var aspect: AspectOption = .threeFour {
        didSet { updateTargetAspect() }
    }
    @Published var settings = ProcessingSettings() {
        didSet {
            updateSettingsBox()
            updatePoseNeeded()
        }
    }
    /// 比較ボタンを押している間だけ、加工をすべて外したプレビューにする（撮影結果には影響しない）
    @Published var showOriginal = false {
        didSet { updateSettingsBox() }
    }
    @Published var template: PoseTemplate? {
        didSet {
            templateBox.value = template
            if template == nil { poseFeed.score = nil }
            updatePoseNeeded()
        }
    }

    let renderer = PreviewRenderer()

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "posecam.session")
    private let videoQueue = DispatchQueue(label: "posecam.video", qos: .userInitiated)
    private let detectionQueue = DispatchQueue(label: "posecam.detection", qos: .userInitiated)
    /// 撮影後の加工・保存はプレビューより優先度を下げ、撮影中に画面がカクつかないようにする
    private let photoQueue = DispatchQueue(label: "posecam.photo", qos: .utility)

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let photoOutput = AVCapturePhotoOutput()

    private let processor = FrameProcessor()
    private let detector = PoseDetector()
    private let settingsBox = Locked(ProcessingSettings())
    private let templateBox = Locked<PoseTemplate?>(nil)
    private let poseBox = Locked<[Joint: CGPoint]?>(nil)
    private let aspectBox = Locked<CGFloat>(3.0 / 4.0)
    private let modeBox = Locked(CaptureMode.photo)
    private let isDetecting = Locked(false)
    /// 骨格の検出が要るか（型・骨格の表示・自動撮影・脚長のどれかを使っているときだけ検出する）
    private let poseNeeded = Locked(false)
    /// 無音撮影に使う、加工前の最新のコマ。シャッターの瞬間にすぐ取り出せるよう、映像のキューを待たずに読める箱に入れる
    private let latestSourceBox = Locked<CIImage?>(nil)

    // sessionQueue 専用
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var isConfigured = false
    /// 表示倍率 1x に当たるデバイスの videoZoomFactor（超広角を含むカメラでは 2.0 など）
    private var zoomBase: CGFloat = 1
    private var lensObservation: NSKeyValueObservation?
    /// セルフタイマー中に背面のライトを弱く点けているか
    private var timerLightOn = false

    // videoQueue 専用
    private var lastDetectionTime: CFTimeInterval = 0
    private var smoothedHipY: CGFloat?
    private var lastFrameSize: CGSize = .zero
    private var wantsRecording = false
    private var recorder: VideoRecorder?
    private var lastRecordedFrame: CIImage?
    private var frameCount = 0
    /// 撮影モードの切り替え直後に捨てるコマの数（倍率が戻る前のコマを見せない）
    private var framesToSkip = 0
    /// 判定（Vision）用に縮小したコマを入れる入れ物
    private var visionPool: CVPixelBufferPool?
    private var visionPoolSize: CGSize = .zero

    // メインスレッド専用
    private var screenAspect: CGFloat = 9.0 / 19.5
    private var recordTimer: Timer?
    private var shotTimer: DispatchSourceTimer?
    private var countdownTimer: DispatchSourceTimer?
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
            self.changeSession(preset: preset, audio: newMode == .video, position: position,
                               zoom: zoom, torch: torch)
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
        changeSession(preset: preset, audio: nil, position: position, zoom: displayZoom, torch: nil)
    }

    /// セッションの画質（プリセット）を変える。変えるとデバイスの倍率が 1（超広角）に戻ってしまうので、
    /// 構成の中で倍率も設定し、倍率が戻るまでのコマは画面に出さない（最後のコマを表示したままにする）。
    /// audio: マイクをつなぐか（nil は変えない）、torch: ライト（nil は変えない）
    private func changeSession(preset: AVCaptureSession.Preset, audio: Bool?, position: AVCaptureDevice.Position,
                               zoom: CGFloat, torch: Bool?) {
        renderer.setFrozen(true)
        sessionQueue.async {
            guard self.isConfigured else {
                self.renderer.setFrozen(false)
                return
            }
            self.session.beginConfiguration()
            self.session.sessionPreset = self.session.canSetSessionPreset(preset) ? preset : .photo
            if let audio {
                if audio { self.attachAudio() } else { self.detachAudio() }
            }
            if let device = self.videoInput?.device {
                self.setDeviceZoom(zoom * self.zoomBase, device: device, animated: false)
            }
            self.session.commitConfiguration()
            self.updateConnections(position: position)
            self.refreshLenses(keepingDisplayZoom: zoom)
            if let torch { self.setTorch(torch) }
            // 倍率を設定した後のコマが届くまで、数コマ待ってから表示を再開する
            self.videoQueue.async { self.framesToSkip = 3 }
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

        // シャッターを押した瞬間のコマを使う（ゼロシャッターラグ）。押してから写るまでの遅れをなくし、
        // セルフタイマーが 0 になった瞬間・連続撮影の各タイミングの姿がそのまま写るようにする
        if photoOutput.isZeroShutterLagSupported {
            photoOutput.isZeroShutterLagEnabled = true
        }
        if photoOutput.isResponsiveCaptureSupported {
            photoOutput.isResponsiveCaptureEnabled = true
            if photoOutput.isFastCapturePrioritizationSupported {
                photoOutput.isFastCapturePrioritizationEnabled = true
            }
        }

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

    /// セルフタイマー中の合図のライト。背面のライトをいちばん弱い明るさで点け、シャッターの瞬間に消す。
    /// 画面が見えない背面側からでも、いつシャッターが切れたか分かるようにする。sessionQueue から呼ぶ。
    private func setTimerLight(_ on: Bool) {
        guard let device = videoInput?.device, device.hasTorch, device.position == .back else { return }
        guard on != timerLightOn else { return }
        do {
            try device.lockForConfiguration()
            if on {
                try device.setTorchModeOn(level: 0.01)
            } else {
                device.torchMode = .off
            }
            device.unlockForConfiguration()
            timerLightOn = on
        } catch {}
    }

    // MARK: - 比率

    private func updateSettingsBox() {
        settingsBox.value = showOriginal ? ProcessingSettings(filter: .none, smoothing: 0, brightening: 0) : settings
    }

    func setScreenAspect(_ value: CGFloat) {
        guard value > 0 else { return }
        screenAspect = value
        updateTargetAspect()
    }

    private func updateTargetAspect() {
        aspectBox.value = aspect.ratio ?? screenAspect
    }

    private func updatePoseNeeded() {
        let needed = template != nil || showSkeleton || autoShutter || settings.legLength > 0.01
        poseNeeded.value = needed
        if !needed {
            poseFeed.detected = nil
            poseFeed.score = nil
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

        // レンズは倍率に応じて iOS が自動で切り替える（標準の .auto）。被写体が近すぎる・暗いときは
        // 望遠の代わりに広角を拡大して使うので、いま実際に使っているレンズを表示する。
        lensObservation = nil
        if device.isVirtualDevice {
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

    /// 撮影 1 回ぶんの設定。シャッターを押した時点の値で固定する。
    private struct ShotOptions {
        let flash: Bool
        let mute: Bool
        /// iOS が消音を許可していない機種で、映像のコマを写真として保存する
        let silent: Bool
        /// 連続撮影では画質より撮影の速さを優先して、間隔を一定に保つ
        let fast: Bool
    }

    /// タイマー → burstInterval 秒ごとに burstCount 枚撮る。
    /// 撮影の時刻は開始時に「タイマー秒後、そこから間隔ごと」と決めておき、画面の処理とは別のキュー
    /// （sessionQueue）の正確なタイマーで撮る。前の撮影の終わりを待たないので、間隔がずれない。
    private func startPhotoSequence() {
        guard !isSequenceRunning else { return }
        isSequenceRunning = true
        let total = burstCount
        let delay = timerSeconds
        let options = ShotOptions(flash: flashOn, mute: muteShutter,
                                  silent: muteShutter && !canMuteShutter, fast: total > 1)
        showCountdown(delay)
        // 撮影のタイマーと同じ基準の時刻から、円の残りを計算する
        burstTimeline = total > 1
            ? BurstTimeline(firstShot: Date().addingTimeInterval(Double(delay)), interval: burstInterval, total: total)
            : nil

        // セルフタイマーのときは、待っている間だけ背面のライトを弱く点ける（シャッターの瞬間に消す）
        let usesTimerLight = delay > 0
        let interval = burstInterval
        if usesTimerLight {
            sessionQueue.async { self.setTimerLight(true) }
        }

        var shot = 0
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: sessionQueue)
        timer.schedule(deadline: .now() + .seconds(delay), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self, weak timer] in
            guard let self else { return }
            shot += 1
            // フラッシュを使うときも、ライトを消してから通常どおり発光させる
            if usesTimerLight { self.setTimerLight(false) }
            self.performCapture(options)
            let current = shot
            if current >= total {
                timer?.cancel()
            } else if usesTimerLight {
                // 連続撮影では、次のシャッターまでの間また点ける（消えた瞬間が 1 枚ごとの合図になる）
                self.sessionQueue.asyncAfter(deadline: .now() + min(0.4, interval / 2)) { [weak timer] in
                    if let timer, !timer.isCancelled { self.setTimerLight(true) }
                }
            }
            DispatchQueue.main.async {
                self.shutterCount += 1
                self.pendingPhotos += 1
                self.isCapturing = true
                if total > 1 { self.burstProgress = "\(current)/\(total)" }
                if current >= total { self.finishSequence() }
            }
        }
        shotTimer = timer
        timer.resume()
    }

    /// 動画・スナップ用。タイマーが終わったら action を呼ぶ。
    private func countdownThen(_ seconds: Int, action: @escaping () -> Void) {
        guard seconds > 0 else {
            action()
            return
        }
        isSequenceRunning = true
        showCountdown(seconds)
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now() + .seconds(seconds), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.isSequenceRunning = false
            action()
        }
        shotTimer = timer
        timer.resume()
    }

    /// 画面のカウントダウン表示と音。撮影そのものは別のタイマーで行う。
    private func showCountdown(_ seconds: Int) {
        guard seconds > 0 else { return }
        countdown = seconds
        AudioServicesPlaySystemSound(1103)
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self, weak timer] in
            guard let self else { return }
            let next = (self.countdown ?? 1) - 1
            if next <= 0 {
                self.countdown = nil
                timer?.cancel()
            } else {
                self.countdown = next
                AudioServicesPlaySystemSound(1103)
            }
        }
        countdownTimer = timer
        timer.resume()
    }

    private func cancelSequence() {
        burstTimeline = nil
        shotTimer?.cancel()
        sessionQueue.async { self.setTimerLight(false) }
        shotTimer = nil
        countdownTimer?.cancel()
        countdownTimer = nil
        countdown = nil
        burstProgress = nil
        isSequenceRunning = false
    }

    private func finishSequence() {
        burstTimeline = nil
        shotTimer = nil
        isSequenceRunning = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if !self.isSequenceRunning { self.burstProgress = nil }
        }
    }

    // MARK: - 写真

    /// sessionQueue から呼ぶ。
    private func performCapture(_ options: ShotOptions) {
        if options.silent {
            captureSilently()
            return
        }
        guard photoOutput.connection(with: .video)?.isActive == true else {
            DispatchQueue.main.async { self.photoFinished() }
            return
        }
        let photoSettings = photoOutput.availablePhotoCodecTypes.contains(.hevc)
            ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            : AVCapturePhotoSettings()
        if options.flash, photoOutput.supportedFlashModes.contains(.on) {
            photoSettings.flashMode = .on
        }
        if options.mute, #available(iOS 18.0, *), photoOutput.isShutterSoundSuppressionSupported {
            photoSettings.isShutterSoundSuppressionEnabled = true
        }
        if options.fast {
            photoSettings.photoQualityPrioritization = .speed
        }
        photoSettings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        photoOutput.capturePhoto(with: photoSettings, delegate: self)
    }
    private func photoFinished() {
        pendingPhotos = max(0, pendingPhotos - 1)
        isCapturing = pendingPhotos > 0
    }

    /// 無音撮影。最新の映像のコマ（加工前・フル解像度）を写真と同じ手順で加工して保存する。
    private func captureSilently() {
        let settings = settingsBox.value
        let aspect = aspectBox.value
        // シャッターの瞬間のコマをすぐに取り出す（映像の処理が終わるのを待たない）
        guard let frame = latestSourceBox.value else {
            DispatchQueue.main.async { self.photoFinished() }
            return
        }
        photoQueue.async {
            defer { DispatchQueue.main.async { self.photoFinished() } }
            guard let result = self.processStill(frame, settings: settings, aspect: aspect) else {
                self.report("写真の処理に失敗しました")
                return
            }
            self.save(result)
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

        let wantsMasks = settings.needsSkinMask
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
    /// pixelBuffer は切り抜き・縮小済みのコマ（aspect はその縦横比）。
    private func analyzeIfIdle(_ pixelBuffer: CVPixelBuffer, aspect: CGFloat) {
        let now = CACurrentMediaTime()
        guard now - lastDetectionTime > 0.08, !isDetecting.value else { return }
        lastDetectionTime = now
        isDetecting.value = true

        detectionQueue.async {
            // 骨格（ポーズの一致度・脚長用）だけ。美肌のマスクは毎コマ映像の処理の中で求める
            let pose = self.detector.pose(pixelBuffer: pixelBuffer)
            self.poseBox.value = pose
            var score: Double?
            if let template = self.templateBox.value {
                // 人が見つからないときも「0%」と表示する（表示が消えると反応していないように見えるため）
                score = pose.map { pose in
                    let isotropic = pose.mapValues { PoseSpace.toIsotropic($0, aspect: aspect) }
                    return PoseMatcher.score(template: template.joints, detected: isotropic, aspect: aspect) ?? 0
                } ?? 0
            }
            self.isDetecting.value = false

            DispatchQueue.main.async {
                guard self.poseNeeded.value else { return }
                if self.poseFeed.detected != pose { self.poseFeed.detected = pose }
                let rounded = self.template == nil ? nil : score.map { $0.rounded() }
                if self.poseFeed.score != rounded { self.poseFeed.score = rounded }
                self.evaluateAutoShutter()
            }
        }
    }

    /// 一致度がしきい値を 0.8 秒保ったら自動で撮影する。連写しないよう 3 秒あける。
    private func evaluateAutoShutter() {
        guard autoShutter, mode == .photo, !isSequenceRunning,
              let score = poseFeed.score, score >= Self.matchThreshold else {
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
        latestSourceBox.value = source

        // 撮影モードの切り替え直後は、倍率が戻るまで数コマ捨てる（最後のコマを表示したまま）
        if framesToSkip > 0 {
            framesToSkip -= 1
            if framesToSkip == 0 { renderer.setFrozen(false) }
            return
        }

        // 写真モードのプレビューは画質を落として軽くする（撮った写真は別に高画質で処理する）。
        // 動画・スナップはこのコマがそのまま保存されるので 1080p のまま
        let isPhoto = modeBox.value == .photo
        let geometry = FrameGeometry(sourceSize: source.extent.size, aspect: aspectBox.value,
                                     maxLongSide: isPhoto ? 1280 : 1920)
        let settings = settingsBox.value
        let wantsMasks = settings.needsSkinMask
        let wantsPose = poseNeeded.value

        let image = geometry.apply(source)
        publishFrameSizeIfNeeded(image.extent.size)

        // 判定（骨格・肌・顔のパーツ）は、切り抜いて小さくしたコマで行う（大きなコマのままだと重い）
        var visionBuffer: CVPixelBuffer?
        if wantsMasks || wantsPose {
            visionBuffer = makeVisionBuffer(image)
        }
        if wantsPose, let visionBuffer {
            analyzeIfIdle(visionBuffer, aspect: geometry.aspect)
        }

        // 美肌のマスクは、このコマ自身から求める。前のコマのマスクを使うと、カメラや顔が動いたときに
        // 加工の位置が遅れてずれる。間に合わないコマは捨てられる（alwaysDiscardsLateVideoFrames）
        var masks: BeautyMasks?
        if wantsMasks, let visionBuffer {
            masks = detector.beautyMasks(pixelBuffer: visionBuffer, outputSize: image.extent.size)
        }
        let hipY = settings.legLength > 0.01 ? updatedHipY() : nil
        let processed = processor.process(image, settings: settings, hipY: hipY, masks: masks)
        renderer.display(processed)
        handleRecording(processed, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    /// 判定用に、長辺 960 ピクセルまで縮小したコマを作る。videoQueue から呼ぶ。
    private func makeVisionBuffer(_ image: CIImage) -> CVPixelBuffer? {
        let extent = image.extent
        let scale = min(1, 960 / max(extent.width, extent.height))
        let size = CGSize(width: (extent.width * scale).rounded(), height: (extent.height * scale).rounded())
        if visionPool == nil || visionPoolSize != size {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            visionPool = pool
            visionPoolSize = size
        }
        guard let visionPool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, visionPool, &buffer)
        guard let buffer else { return nil }
        let small = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: size.width / extent.width, y: size.height / extent.height))
        renderer.ciContext.render(small, to: buffer, bounds: CGRect(origin: .zero, size: size),
                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return buffer
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
