import AudioToolbox
import AVFoundation
import Combine
import CoreImage
import ImageIO
import os
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
    /// 検出した顔のパーツ（画像座標）。骨格の表示に使う
    @Published fileprivate(set) var face: FaceShape?
    @Published fileprivate(set) var score: Double?
    /// 2 人目以降の、検出した骨格と顔（画像座標）。2 人以上の型のときだけ表示に使う
    @Published fileprivate(set) var others: [[Joint: CGPoint]] = []
    @Published fileprivate(set) var otherFaces: [FaceShape] = []

    /// 写真の編集画面で、写真から求めた骨格を脚長の範囲の線に使う
    func showStill(pose: [Joint: CGPoint]?) {
        detected = pose
    }
}

/// レンズ切り替えボタン 1 つぶん。displayFactor は標準カメラと同じ表示倍率（0.5 / 1 / 2 / 5 など）。
struct LensOption: Identifiable, Equatable {
    let displayFactor: CGFloat
    var id: CGFloat { displayFactor }
}

/// 連続撮影の予定。1 枚目を撮る時刻と間隔から、次のシャッターまでの残りを計算できる。
struct BurstTimeline: Equatable {
    /// シャッターを押した時刻
    let start: Date
    let firstShot: Date
    /// 1 枚目までの待ち時間も円で表すか（セルフタイマーのときは数字のカウントダウンに任せる）
    let showsLeadIn: Bool
    let interval: Double
    let total: Int
}

/// 撮った写真の確認用の画像（撮影後のプレビュー表示に使う）
struct CapturedPhoto: Identifiable, Equatable {
    let id = UUID()
    let image: UIImage

    static func == (a: CapturedPhoto, b: CapturedPhoto) -> Bool { a.id == b.id }
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
    /// 連続撮影の間隔（秒）。1 枚目もシャッターを押してからこの時間で撮る（構える時間）
    static let burstInterval: Double = 2
    static let snapMaxSeconds = 10

    // MARK: 状態（表示用）

    @Published private(set) var mode: CaptureMode = .photo
    @Published private(set) var position: AVCaptureDevice.Position = .back
    @Published private(set) var isRecording = false
    /// 停止した後、書き出し・保存がまだ終わっていない動画の数（裏で保存を続け、その間も次を撮れる）
    @Published private(set) var savingVideos = 0
    /// 写真モードでシャッターを長押しして撮っている短い動画
    @Published private(set) var isQuickVideo = false
    @Published private(set) var recordingSeconds = 0
    @Published private(set) var isCapturing = false
    /// 撮った後、加工・保存がまだ終わっていない写真の数
    @Published private(set) var savingPhotos = 0
    /// ダイレクトフラッシュで、カメラか被写体が大きく動いている（撮る前に「止まってください」と出す）
    @Published private(set) var isMovingTooMuch = false
    @Published private(set) var frameAspect: CGFloat = 3.0 / 4.0
    let poseFeed = PoseFeed()
    /// 撮影した瞬間に 1 増える（画面を一瞬暗くして、シャッターが切れたことを知らせる）
    @Published private(set) var shutterCount = 0
    @Published private(set) var lastThumbnail: UIImage?
    @Published private(set) var cameraAuthorized = true
    @Published private(set) var statusMessage: String?
    /// タップで合わせたピント・露出を固定している（AE/AF ロック）
    @Published private(set) var isFocusLocked = false
    /// 露出の補正（EV）
    @Published private(set) var exposureBias: Float = 0
    /// ピント・露出が画面全体の自動に戻るたびに 1 増える（画面のピントの枠を消す）
    @Published private(set) var focusResetCount = 0

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
        didSet {
            applyTorch()
            updateMotionWatch()
        }
    }
    /// ダイレクトフラッシュ（写ルンです・昔のコンデジ風）。フラッシュの光が届かない背景を暗く落とす
    @Published var directFlash = false {
        // ダイレクトフラッシュは 1 枚の処理が重いので、連続撮影は 3 枚までにする
        // （10 枚続けると、メモリが足りずに保存できないことがあった）
        didSet {
            if directFlash && burstCount > 3 { burstCount = 3 }
            updateMotionWatch()
        }
    }
    /// ダイレクトフラッシュ 2: 人物の周りの背景も暗く落とす（1 はフラッシュの届いた所はそのまま明るい）
    @Published var directFlashDark = false
    /// 自動撮影（型に合ったら撮る）。アプリを終了しても覚えておく
    @Published var autoShutter = UserDefaults.standard.bool(forKey: CameraManager.autoShutterKey) {
        didSet {
            UserDefaults.standard.set(autoShutter, forKey: Self.autoShutterKey)
            updatePoseNeeded()
        }
    }
    static let autoShutterKey = "autoShutter"
    @Published var showSkeleton = false {
        didSet {
            showSkeletonBox.value = showSkeleton
            updatePoseNeeded()
        }
    }
    /// 脚長で伸ばす範囲の線を表示している（脚長が 0 でも、線の位置を決めるために骨格を検出する）
    var showsLegRange = false {
        didSet { updatePoseNeeded() }
    }
    @Published var timerSeconds = 0
    @Published var burstCount = 1
    @Published var muteShutter = false {
        didSet { if mode == .photo { applyPhotoFormat() } }
    }
    @Published var aspect: AspectOption = .threeFour {
        didSet { updateTargetAspect() }
    }
    /// 加工の設定。アプリを開き直しても前回と同じ設定から始める（以前は開き直すたびに初期値に戻っていた）
    @Published var settings = ProcessingSettings.loadSaved() {
        didSet {
            updateSettingsBox()
            updatePoseNeeded()
            if settings != oldValue { settings.save() }
        }
    }
    /// 比較ボタンを押している間だけ、加工をすべて外したプレビューにする（撮影結果には影響しない）
    @Published var showOriginal = false {
        didSet { updateSettingsBox() }
    }
    @Published var template: PoseTemplate? {
        didSet {
            // 料理・ドリンクの構図の型は人の判定をしないので、骨格や一致度の判定には渡さない
            templateBox.value = template?.isObject == true ? nil : template
            if template == nil || template?.isObject == true { poseFeed.score = nil }
            updatePoseNeeded()
        }
    }

    let renderer = PreviewRenderer()
    /// リモートモニター（もう一台のスマホに撮影画面を映す）
    let remote = RemoteHost()

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "posecam.session")
    private let videoQueue = DispatchQueue(label: "posecam.video", qos: .userInitiated)
    private let detectionQueue = DispatchQueue(label: "posecam.detection", qos: .userInitiated)
    /// 撮影後の加工・保存はプレビューより優先度を下げ、撮影中に画面がカクつかないようにする
    private let photoQueue = DispatchQueue(label: "posecam.photo", qos: .utility)
    /// 録画の書き込み（動画ファイルの作成・コマと音声の追加・仕上げ）とマイクの音声。
    /// 映像のキューと分けて、書き出しの開始・仕上げに時間がかかっても、プレビューと音声の受け取りが止まらないようにする
    /// （以前は同じキューで、録画を繰り返すと十数秒止まり、音声も取りこぼしていた）
    private let recordingQueue = DispatchQueue(label: "posecam.recording", qos: .userInitiated)

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let photoOutput = AVCapturePhotoOutput()

    private let processor = FrameProcessor()
    private let detector = PoseDetector()
    // 覚えておいた加工の設定で始める（settings の didSet は最初の値では呼ばれない）
    private let settingsBox = Locked(ProcessingSettings.loadSaved())
    private let templateBox = Locked<PoseTemplate?>(nil)
    private let poseBox = Locked<[Joint: CGPoint]?>(nil)
    private let aspectBox = Locked<CGFloat>(3.0 / 4.0)
    private let modeBox = Locked(CaptureMode.photo)
    private let isDetecting = Locked(false)
    /// 骨格の検出が要るか（型・骨格の表示・自動撮影・脚長のどれかを使っているときだけ検出する）
    private let poseNeeded = Locked(false)
    private let showSkeletonBox = Locked(false)
    /// 無音撮影に使う、加工前の最新のコマ。シャッターの瞬間にすぐ取り出せるよう、映像のキューを待たずに読める箱に入れる
    private let latestSourceBox = Locked<CIImage?>(nil)
    /// 最新のコマの撮影情報（Exif: 絞り・シャッター速度・ISO・レンズ名）。無音撮影の写真とダイレクトフラッシュに使う
    private let latestExifBox = Locked<[String: Any]>([:])
    /// カメラ（前・後）ごとの、通常の写真の大きさ（縦向き）。無音撮影の写真をこの大きさにそろえる
    private let photoSizeBox = Locked<[AVCaptureDevice.Position: CGSize]>([:])
    /// 撮り終わったら連続撮影の終わりの合図をする写真（uniqueID）
    private let endSignalPhotoID = Locked<Int64?>(nil)
    /// ダイレクトフラッシュで撮る写真ごとの、発光直前のコマ（写真の uniqueID ごと）
    private let ambientFrames = Locked<[Int64: (image: CIImage, exif: [String: Any], dark: Bool)]>([:])

    // sessionQueue 専用
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var isConfigured = false
    /// 表示倍率 1x に当たるデバイスの videoZoomFactor（超広角を含むカメラでは 2.0 など）
    private var zoomBase: CGFloat = 1
    private var lensObservation: NSKeyValueObservation?
    /// セルフタイマー中に背面のライトを弱く点けているか
    private var timerLightOn = false
    /// 合図のライトの点滅を止めるための番号（増やすと、それより前に始めた点滅は止まる）
    private var blinkGeneration = 0

    // detectionQueue 専用
    /// 型の輪郭を一致度用のマス目に塗ったもの（型と比率が変わったときだけ作り直す）
    private var templateCells: (key: String, cells: [Bool])?

    // videoQueue 専用
    private var lastDetectionTime: CFTimeInterval = 0
    private var lastSlowFrameLog: CFTimeInterval = 0
    private var smoothedLegs: LegLayout?
    private var lastFrameSize: CGSize = .zero
    /// 録画の書き込み先にするコマの入れ物（加工済みのコマをここに描いてから、書き込みのキューへ渡す）
    private var recordPool: CVPixelBufferPool?
    private var recordPoolSize: CGSize = .zero

    // 映像のキューと録画のキューの両方から読む
    /// いま書き込み中の録画の番号（nil は書き込まない）
    private let recordingTake = Locked<Int?>(nil)
    /// その録画に音声を入れるか
    private let recordingAudio = Locked(false)
    /// 書き込みのキューに渡して、まだ書いていないコマの数（多すぎるときはコマを捨てる）
    private let pendingRecordFrames = Locked(0)
    /// 動きを見張るか（ダイレクトフラッシュの写真のときだけ）
    private let motionWatch = Locked(false)
    /// 動きの判定に使う、前のコマを小さくした明るさ（videoQueue 専用）
    private var motionPrevious: [Float]?
    private var motionLevel: Float = 0
    private var motionMoving = false
    /// 描けずに捨てたコマの数（recordingQueue で使う）
    private var failedRecordFrames = 0

    // recordingQueue 専用
    private var recorder: VideoRecorder?
    private var recorderTake: Int?
    private var lastRecordedBuffer: CVPixelBuffer?
    private var droppedRecordFrames = 0
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
    private var pendingPhotos = 0 {
        didSet { savingPhotos = pendingPhotos }
    }
    private var takeCounter = 0
    /// AE/AF ロックの予約の番号（増やすと、それより前に予約した固定は行わない）
    private var lockGeneration = 0

    // MARK: - セッション

    func start() {
        // 横向きで撮ったら横向きの写真・動画として保存するため、端末の向きを調べておく
        CaptureOrientation.shared.start()
        // 覚えておいた脚長が入っていれば、最初から骨格を検出する
        updatePoseNeeded()
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

    /// アルバム・写真の編集を開いている間、カメラを止める（裏で動かし続けると熱くなり、電池が減る）。
    /// 撮影中（シャッターを押してから写真が届くまで）は、写真が届いてから止める。
    /// 写真の加工・保存はカメラと関係なく続く。start() で動かし直す
    func suspend(attempt: Int = 0) {
        stopRecordingIfNeeded()
        if (isCapturing || isSequenceRunning) && attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.suspend(attempt: attempt + 1) }
            return
        }
        sessionQueue.async {
            guard self.session.isRunning else { return }
            self.setTorch(false)
            self.session.stopRunning()
            Diagnostics.mark("カメラを止めた（アルバム）")
        }
    }

    /// suspend() で止めたカメラを動かし直す（動画・スナップのライトも元に戻す）
    func resume() {
        start()
        // start() はカメラの許可を確かめてから動かし始めるので、動き出してからライトを付け直す
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.applyTorch() }
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
        audioOutput.setSampleBufferDelegate(self, queue: recordingQueue)
        session.commitConfiguration()

        updateConnections(position: .back)
        refreshLenses(keepingDisplayZoom: nil)
        // セッションが止まったら（マイクの切り替え・他のアプリとの取り合いなど）記録して動かし直す
        NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                               object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            Diagnostics.log("セッションのエラー: \(error?.localizedDescription ?? "") (\(error?.code ?? 0))")
            guard let self else { return }
            self.sessionQueue.async {
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
        // タップで合わせた後に被写体が大きく変わったら、画面全体の自動に戻す（ロック中は通知しない）
        NotificationCenter.default.addObserver(forName: AVCaptureDevice.subjectAreaDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.isFocusLocked else { return }
            self.resetFocus()
            self.focusResetCount += 1
        }
        Diagnostics.mark("構成: 完了")
    }

    /// 写真は 4:3 の高画質、動画とスナップは 1080p。動画のときだけマイクをつなぐ。
    func setMode(_ newMode: CaptureMode) {
        guard newMode != mode, !isRecording, !isSequenceRunning else { return }
        mode = newMode
        modeBox.value = newMode
        updateMotionWatch()
        resetFocus()
        focusResetCount += 1
        let position = self.position
        let torch = flashOn && newMode != .photo
        let zoom = displayZoom

        let preset: AVCaptureSession.Preset = newMode == .photo ? .photo : .hd1920x1080
        let silent = newMode == .photo && usesSilentFrames
        let reconfigure = {
            self.changeSession(preset: preset, silent: silent, audio: newMode == .video, position: position,
                               zoom: zoom, torch: torch)
        }

        if newMode == .video && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in reconfigure() }
        } else {
            reconfigure()
        }
    }

    /// iOS が消音を許可していない機種（日本向けの iPhone など）で無音撮影するときは、映像のコマを写真にする。
    private var usesSilentFrames: Bool { muteShutter && !canMuteShutter }

    private func applyPhotoFormat() {
        guard !isRecording, !isSequenceRunning else { return }
        changeSession(preset: .photo, silent: usesSilentFrames, audio: nil, position: position,
                      zoom: displayZoom, torch: nil)
    }

    /// セッションの画質（プリセット）を変える。変えるとデバイスの倍率が 1（超広角）に戻ってしまうので、
    /// 構成の中で倍率も設定し、倍率が戻るまでのコマは画面に出さない（最後のコマを表示したままにする）。
    /// audio: マイクをつなぐか（nil は変えない）、torch: ライト（nil は変えない）
    /// 構成の変更後、コマが届かないまま画面が止まり続けないよう、一定時間で必ず表示を再開する。
    private func unfreezeLater() {
        videoQueue.asyncAfter(deadline: .now() + 1.0) {
            if self.framesToSkip > 0 {
                Diagnostics.log("表示: 1 秒たってもコマが届かないので固定を解除")
                self.framesToSkip = 0
                self.renderer.setFrozen(false)
            }
        }
    }

    private func changeSession(preset: AVCaptureSession.Preset, silent: Bool, audio: Bool?,
                               position: AVCaptureDevice.Position, zoom: CGFloat, torch: Bool?) {
        renderer.setFrozen(true)
        sessionQueue.async {
            guard self.isConfigured else {
                self.renderer.setFrozen(false)
                return
            }
            self.session.beginConfiguration()
            self.configureVideoFormat(preset: preset, silent: silent)
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
            self.unfreezeLater()
        }
    }

    func flipCamera() {
        guard !isRecording, !isSequenceRunning else { return }
        let newPosition: AVCaptureDevice.Position = position == .back ? .front : .back
        position = newPosition
        isFocusLocked = false
        exposureBias = 0
        focusResetCount += 1
        let torch = flashOn && mode != .photo
        let preset: AVCaptureSession.Preset = mode == .photo ? .photo : .hd1920x1080
        let silent = mode == .photo && usesSilentFrames

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
            self.configureVideoFormat(preset: preset, silent: silent)
            self.session.commitConfiguration()
            self.updateConnections(position: newPosition)
            self.refreshLenses(keepingDisplayZoom: nil)
            self.setTorch(torch)
            if self.audioInput != nil { self.selectMicrophone(for: newPosition) }
        }
        videoQueue.async { self.smoothedLegs = nil }
    }

    /// 映像の形式を決める。sessionQueue の構成（beginConfiguration）の中から呼ぶ。
    /// 無音撮影では映像のコマを写真にするので、写真と同じ 4:3 の映像の形式を直接選ぶ。
    /// 以前は 4K（16:9）のプリセットを使っていたが、16:9 はセンサーの上下を切り捨てるので、
    /// 3:4 に切り抜くと通常の写真より画角が狭くなっていた。
    private func configureVideoFormat(preset: AVCaptureSession.Preset, silent: Bool) {
        if silent, let device = videoInput?.device, let format = Self.fullSensorVideoFormat(device) {
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                if format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
                    device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                }
                device.unlockForConfiguration()
                let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                Diagnostics.log("無音撮影の映像形式: \(d.width)x\(d.height)")
                return
            } catch {}
        }
        session.sessionPreset = session.canSetSessionPreset(preset) ? preset : .photo
    }

    /// 4:3 で 30 コマ/秒を出せる映像の形式のうち、いちばん画素数の多いもの（長辺 4032 まで）。
    private static func fullSensorVideoFormat(_ device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        func pixels(_ format: AVCaptureDevice.Format) -> Int {
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return Int(d.width) * Int(d.height)
        }
        return device.formats.filter { format in
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard d.height > 0 else { return false }
            let ratio = Double(d.width) / Double(d.height)
            return abs(ratio - 4.0 / 3.0) < 0.01 && d.width <= 4032
                && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 29 }
        }.max { pixels($0) < pixels($1) }
    }

    /// 背面は超広角・望遠をまとめた仮想カメラを使い、倍率に応じて iOS がレンズを切り替える。
    /// 前面は iPhone では広角、iPad mini（第 6 世代以降）などでは超広角（センターフレーム付き）しかないので、両方探す。
    private static func camera(at position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        // iPad のセンターフレームは、映っている人に合わせて勝手にズーム・移動するので、ポーズのガイドと
        // 見本の位置・大きさがずれる。このアプリの中では切る（iPad 本体の設定や、ほかのアプリには影響しない）
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInWideAngleCamera, .builtInUltraWideCamera]
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
            // 通常の写真の大きさを覚えておく（無音撮影の写真をこの大きさにそろえる）
            if session.sessionPreset == .photo {
                let size = CGSize(width: CGFloat(min(best.width, best.height)),
                                  height: CGFloat(max(best.width, best.height)))
                var sizes = photoSizeBox.value
                sizes[device.position] = size
                photoSizeBox.value = sizes
            }
        }
    }

    private func attachAudio() {
        guard audioInput == nil,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let mic = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: mic),
              session.canAddInput(input) else { return }
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .videoRecording,
                                         options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try audioSession.setActive(true)
        } catch {
            // 録音できる設定にできないと、マイクの音が無音になる
            Diagnostics.log("マイク: 音声の設定に失敗 \(error.localizedDescription)")
        }
        session.addInput(input)
        audioInput = input
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        }
        selectMicrophone(for: videoInput?.device.position ?? .back)
    }

    /// 内蔵マイクのうち、撮っているカメラと同じ側のものを固定で使う。
    /// iOS に任せると録画ごとに使うマイク（前・後ろ・下）が変わることがあり、同じ場所で撮っても
    /// 動画ごとに声の大きさが大きく違っていた。sessionQueue から呼ぶ。
    private func selectMicrophone(for position: AVCaptureDevice.Position) {
        let audio = AVAudioSession.sharedInstance()
        guard let mic = audio.availableInputs?.first(where: { $0.portType == .builtInMic }) else { return }
        let wanted: AVAudioSession.Orientation = position == .front ? .front : .back
        do {
            try audio.setPreferredInput(mic)
            if let source = mic.dataSources?.first(where: { $0.orientation == wanted }) {
                // 指向性があれば前方（カメラの向き）を、なければ全方向を使う
                if let patterns = source.supportedPolarPatterns {
                    let pattern: AVAudioSession.PolarPattern = patterns.contains(.cardioid) ? .cardioid : .omnidirectional
                    if patterns.contains(pattern) { try source.setPreferredPolarPattern(pattern) }
                }
                try mic.setPreferredDataSource(source)
            }
        } catch {
            Diagnostics.log("マイク: 選べず \(error.localizedDescription)")
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
    @discardableResult
    private func setTimerLight(_ on: Bool) -> Bool {
        guard let device = videoInput?.device, device.hasTorch, device.position == .back else { return false }
        // 覚えている状態ではなく、実際のライトの状態で判断する（撮影や構成の変更で、知らないうちに消えていることがある）
        guard on != (device.torchMode == .on) else {
            timerLightOn = on
            return true
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if on {
                try device.setTorchModeOn(level: 0.01)
            } else {
                device.torchMode = .off
            }
            timerLightOn = on
            return true
        } catch {
            Diagnostics.log("ライト: \(on ? "点灯" : "消灯")できず（使える状態 \(device.isTorchAvailable)）\(error.localizedDescription)")
            return false
        }
    }

    /// 合図のライトを、deadline（シャッターの時刻）に近づくほど速く点滅させる。sessionQueue から呼ぶ。
    /// 残り 3 秒より前は 1 秒に 1 回、3〜1.8 秒は 0.5 秒ごと、1.8〜1.1 秒は 0.25 秒ごと、最後は 0.14 秒ごと。
    /// シャッターの 0.6 秒前には消しておく。ライトは点けてから実際に光るまで・消してから暗くなるまで遅れがあり、
    /// 直前まで点けていると写真に写り込んでいた（フラッシュをオフにしていても明るくなっていた）。
    private func blinkLight(until deadline: Date) {
        blinkGeneration += 1
        blinkStep(generation: blinkGeneration, deadline: deadline)
    }

    private func blinkStep(generation: Int, deadline: Date) {
        guard generation == blinkGeneration else { return }
        let remaining = deadline.timeIntervalSinceNow
        let darkBeforeShot = 0.6
        guard remaining > darkBeforeShot + 0.03 else {
            setTimerLight(false)
            return
        }
        let period = remaining > 3 ? 1.0 : remaining > 1.8 ? 0.5 : remaining > 1.1 ? 0.25 : 0.14
        let onTime = min(0.08, period / 2, remaining - darkBeforeShot)
        setTimerLight(true)
        sessionQueue.asyncAfter(deadline: .now() + onTime) {
            guard generation == self.blinkGeneration else { return }
            self.setTimerLight(false)
        }
        sessionQueue.asyncAfter(deadline: .now() + period) {
            self.blinkStep(generation: generation, deadline: deadline)
        }
    }

    private func stopBlinking() {
        blinkGeneration += 1
        setTimerLight(false)
    }

    /// 連続撮影がすべて終わった合図。背面のライトを最低の明るさで 2 回チカチカさせる。sessionQueue から呼ぶ。
    /// 最後の写真の撮影が終わった（didFinishCaptureFor が届いた）後に呼ぶので、写真には写り込まない。
    /// 連続撮影の終わりをライトで知らせる（設定。初めはする）
    static let burstEndLightKey = "burstEndLight"

    private func signalSequenceFinished(after delay: Double) {
        // 設定でオフにしていれば知らせない（値がなければ、以前と同じく知らせる）
        if UserDefaults.standard.object(forKey: Self.burstEndLightKey) as? Bool == false {
            Diagnostics.log("連続撮影: 終わりの合図はオフ")
            return
        }
        blinkGeneration += 1
        let generation = blinkGeneration
        let position = videoInput?.device.position
        Diagnostics.log("連続撮影: 終わりの合図（\(position == .back ? "背面" : "前面のためライトなし")）")
        // 見落とさないよう、0.15 秒ずつ 2 回点ける
        for (time, on) in [(0.0, true), (0.15, false), (0.35, true), (0.5, false)] {
            sessionQueue.asyncAfter(deadline: .now() + delay + time) {
                guard generation == self.blinkGeneration else { return }
                if !self.setTimerLight(on), on {
                    // 撮影の直後でライトが使えないときは、少し待ってもう一度
                    self.sessionQueue.asyncAfter(deadline: .now() + 0.3) {
                        guard generation == self.blinkGeneration else { return }
                        self.setTimerLight(true)
                        self.sessionQueue.asyncAfter(deadline: .now() + 0.15) { self.setTimerLight(false) }
                    }
                }
            }
        }
    }

    // MARK: - 比率

    private func updateSettingsBox() {
        // 比較ボタン（美肌・スタイルのパネル）は美肌・スタイルの加工だけを外す。フィルターは残す
        settingsBox.value = showOriginal ? settings.withoutBeauty : settings
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
        let needed = (template != nil && template?.isObject != true) || showSkeleton || autoShutter
            || settings.legLength > 0.01 || showsLegRange
        poseNeeded.value = needed
        if !needed {
            poseFeed.detected = nil
            poseFeed.face = nil
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

    // MARK: - ピント・露出

    /// 画面をタップした所にピントと露出を合わせる（lock が true なら合わせた後に固定する: AE/AF ロック）。
    /// point はプレビューの中の位置、size はプレビューの大きさ（どちらもポイント）。
    /// プレビューは「選んだ比率に中央で切り抜いたコマ」をそのまま表示しているので、切り抜きを戻して元のコマの位置にし、
    /// さらにカメラの向き（横向きのセンサー）の座標に直す。
    func focus(at point: CGPoint, in size: CGSize, lock: Bool) {
        guard size.width > 0, size.height > 0, let source = latestSourceBox.value?.extent.size,
              source.width > 0, source.height > 0 else { return }
        let crop = FrameGeometry(sourceSize: source, aspect: aspectBox.value, maxLongSide: nil).cropRect
        let cx = min(max(point.x / size.width, 0), 1), cy = min(max(point.y / size.height, 0), 1)
        // 元のコマ（縦向き・左上原点）の中の位置
        let sx = (crop.minX + cx * crop.width) / source.width
        let sy = (source.height - crop.maxY + cy * crop.height) / source.height
        // コマは 90 度回して縦向きにしてあり、インカメラはさらに左右を反転している
        let interest = position == .front ? CGPoint(x: sy, y: sx) : CGPoint(x: sy, y: 1 - sx)
        isFocusLocked = lock
        exposureBias = 0
        if !lock { lockGeneration += 1 }
        sessionQueue.async {
            guard let device = self.videoInput?.device, (try? device.lockForConfiguration()) != nil else { return }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = interest
                // .autoFocus は 1 回合わせたら固定になる
                let mode: AVCaptureDevice.FocusMode = lock ? .autoFocus : .continuousAutoFocus
                if device.isFocusModeSupported(mode) { device.focusMode = mode }
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = interest
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            }
            // 顔に合わせて自動で露出を変える機能は、ロック中は止める（止めないと、顔が映ると明るさが変わる）
            device.automaticallyAdjustsFaceDrivenAutoExposureEnabled = !lock
            if lock { device.isFaceDrivenAutoExposureEnabled = false }
            device.setExposureTargetBias(0, completionHandler: nil)
            // 被写体が大きく変わったら、標準のカメラと同じく中央に戻す
            device.isSubjectAreaChangeMonitoringEnabled = !lock
            device.unlockForConfiguration()
        }
        guard lock else { return }
        // 露出は、タップした所に合わせ終わるのを待ってから固定する。
        // 以前は .autoExpose（1 回合わせたら固定）を使っていたが、機種によっては固定されず、明るさが変わり続けていた
        lockGeneration += 1
        let generation = lockGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            guard self.lockGeneration == generation else { return }
            self.sessionQueue.async {
                guard let device = self.videoInput?.device, (try? device.lockForConfiguration()) != nil else { return }
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                device.unlockForConfiguration()
            }
        }
    }

    /// 露出の補正（EV）。-2...+2 の範囲で、カメラが対応する範囲に収める
    func setExposureBias(_ value: Float) {
        let clamped = min(max(value, -2), 2)
        exposureBias = clamped
        sessionQueue.async {
            guard let device = self.videoInput?.device, (try? device.lockForConfiguration()) != nil else { return }
            let v = min(max(clamped, device.minExposureTargetBias), device.maxExposureTargetBias)
            device.setExposureTargetBias(v, completionHandler: nil)
            device.unlockForConfiguration()
        }
    }

    /// ピント・露出を画面全体の自動に戻す（被写体が変わったとき・カメラを切り替えたとき）
    func resetFocus() {
        isFocusLocked = false
        lockGeneration += 1
        exposureBias = 0
        sessionQueue.async {
            guard let device = self.videoInput?.device, (try? device.lockForConfiguration()) != nil else { return }
            let center = CGPoint(x: 0.5, y: 0.5)
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = center }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = center }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.setExposureTargetBias(0, completionHandler: nil)
            device.isSubjectAreaChangeMonitoringEnabled = false
            device.automaticallyAdjustsFaceDrivenAutoExposureEnabled = true
            device.unlockForConfiguration()
        }
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
        /// ダイレクトフラッシュ
        let direct: Bool
        /// ダイレクトフラッシュ 2（人物の周りの背景も暗く落とす）
        var directDark = false
        let mute: Bool
        /// iOS が消音を許可していない機種で、映像のコマを写真として保存する
        let silent: Bool
        /// 連続撮影では画質より撮影の速さを優先して、間隔を一定に保つ
        let fast: Bool
    }

    /// タイマー → 2 秒ごとに burstCount 枚撮る。
    /// 撮影の時刻は開始時に「待ち時間の後、そこから間隔ごと」と決めておき、画面の処理とは別のキュー
    /// （sessionQueue）の正確なタイマーで撮る。前の撮影の終わりを待たないので、間隔がずれない。
    /// 連続撮影はタイマーなしでも、押してから 2 秒後に 1 枚目を撮る（構える時間）。
    private func startPhotoSequence() {
        guard !isSequenceRunning else { return }
        // 前の写真の加工・保存が詰まっているとき・メモリが少ないときは撮らない
        // （撮り続けると、メモリが足りずに加工に失敗して保存できなくなっていた）
        if isSaveBacklogged {
            report("保存中です。しばらくお待ちください")
            return
        }
        isSequenceRunning = true
        let total = burstCount
        let interval = Self.burstInterval
        let delay = timerSeconds > 0 ? Double(timerSeconds) : (total > 1 ? interval : 0)
        let options = ShotOptions(flash: flashOn, direct: flashOn && directFlash,
                                  directDark: flashOn && directFlash && directFlashDark, mute: muteShutter,
                                  silent: usesSilentFrames, fast: total > 1)
        showCountdown(timerSeconds)
        // 撮影のタイマーと同じ基準の時刻から、円の残りを計算する
        let start = Date()
        let firstShot = start.addingTimeInterval(delay)
        burstTimeline = total > 1
            ? BurstTimeline(start: start, firstShot: firstShot, showsLeadIn: timerSeconds == 0,
                            interval: interval, total: total)
            : nil

        // セルフタイマーのときだけ、1 枚目までの待ち時間に背面のライトを最低の明るさで点滅させ、シャッターが
        // 近づくほど速くする（背面カメラで自分を撮るとき、画面が見えなくてもいつ撮られるか分かる）。
        // 連続撮影の構える時間・撮影の合間は点滅させない。終わったときに 2 回点滅させるだけにする
        let usesLight = timerSeconds > 0
        if usesLight {
            sessionQueue.async { self.blinkLight(until: firstShot) }
        }

        var shot = 0
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: sessionQueue)
        timer.schedule(deadline: .now() + delay, repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self, weak timer] in
            guard let self else { return }
            shot += 1
            // フラッシュを使うときも、ライトを消してから通常どおり発光させる
            if usesLight && shot == 1 { self.stopBlinking() }
            let current = shot
            // 連続撮影の最後の 1 枚は、撮り終わったらライトを 2 回チカチカさせて知らせる
            self.performCapture(options, signalsEnd: total > 1 && current >= total)
            if current >= total {
                timer?.cancel()
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
        Sounds.play(.tick)
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
                Sounds.play(.tick)
            }
        }
        countdownTimer = timer
        timer.resume()
    }

    private func cancelSequence() {
        burstTimeline = nil
        shotTimer?.cancel()
        sessionQueue.async { self.stopBlinking() }
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
    private func performCapture(_ options: ShotOptions, signalsEnd: Bool = false) {
        if options.silent {
            captureSilently()
            // 映像のコマはもう取り出したので、すぐ合図してよい
            if signalsEnd { signalSequenceFinished(after: 0.25) }
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
            if options.direct, let ambient = latestSourceBox.value.flatMap(ownedCopy) {
                // 発光する直前のコマ（フラッシュなしの明るさ）を覚えておき、写真と比べて
                // 「フラッシュの光」と「周りの光」を分ける。
                // カメラのコマの入れ物はすぐ次のコマに使い回されるので、縮小した自前の画像に写しておく
                // （写しておかないと、写真の加工のときには中身が変わっていて書き出しに失敗していた）
                var frames = ambientFrames.value
                frames[photoSettings.uniqueID] = (ambient, latestExifBox.value, options.directDark)
                ambientFrames.value = frames
            }
        }
        if options.mute, #available(iOS 18.0, *), photoOutput.isShutterSoundSuppressionSupported {
            photoSettings.isShutterSoundSuppressionEnabled = true
        }
        if options.fast {
            photoSettings.photoQualityPrioritization = .speed
        }
        photoSettings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        if signalsEnd { endSignalPhotoID.value = photoSettings.uniqueID }
        photoOutput.capturePhoto(with: photoSettings, delegate: self)
    }
    /// カメラのコマを 1/4 に縮めて自前の画像に写す（明るさを比べるだけなので小さくてよい）
    private func ownedCopy(_ frame: CIImage) -> CIImage? {
        let e = frame.extent
        let small = frame.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
        guard let cgImage = renderer.ciContext.createCGImage(small, from: small.extent) else { return nil }
        // 元の大きさの座標に戻しておく（写真の加工では元のコマと同じように切り抜く）
        return CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(scaleX: 4, y: 4))
    }

    /// 加工・保存が詰まっているか。ダイレクトフラッシュは 2 枚、それ以外は 5 枚まで待たせてよい。
    /// アプリが使える残りのメモリが 500MB を切ったら、待っている写真があるうちは撮らない
    var isSaveBacklogged: Bool {
        let limit = flashOn && directFlash ? 2 : 5
        let available = os_proc_available_memory()
        let lowMemory = available > 0 && available < 500 * 1024 * 1024
        return pendingPhotos >= limit || (pendingPhotos > 0 && lowMemory)
    }

    private func photoFinished() {
        pendingPhotos = max(0, pendingPhotos - 1)
        isCapturing = pendingPhotos > 0
    }

    /// 無音撮影。最新の映像のコマ（加工前・フル解像度）を写真と同じ手順で加工して保存する。
    private func captureSilently(upscale: Bool = true) {
        let settings = settingsBox.value
        let aspect = aspectBox.value
        // シャッターの瞬間のコマをすぐに取り出す（映像の処理が終わるのを待たない）
        guard let frame = latestSourceBox.value else {
            DispatchQueue.main.async { self.photoFinished() }
            return
        }
        let exif = latestExifBox.value
        let orientation = CaptureOrientation.shared.current
        let position = videoInput?.device.position ?? .back
        // 通常の写真と同じ画素数になるよう、裏で引き伸ばす
        let targetSize = upscale ? photoSizeBox.value[position] : nil
        photoQueue.async {
            defer { DispatchQueue.main.async { self.photoFinished() } }
            let metadata = PhotoMetadata.forVideoFrame(exif: exif, position: position)
            guard let result = self.processStill(frame, settings: settings, aspect: aspect, metadata: metadata,
                                                 upscaleTo: targetSize, orientation: orientation) else {
                self.report("写真の処理に失敗しました")
                return
            }
            self.save(result)
        }
    }

    /// 撮った写真の確認用の小さい画像（撮影後のプレビュー表示・モニターへの送信に使う）
    @Published private(set) var lastCapture: CapturedPhoto?

    /// 撮影後にプレビューを表示する（設定）
    static let capturePreviewKey = "capturePreview"

    /// 保存できた写真を、撮影後のプレビュー表示とモニター（アプリ）に渡す。どのスレッドから呼んでもよい
    private func shareCapture(_ jpeg: Data) {
        let preview = UserDefaults.standard.bool(forKey: Self.capturePreviewKey)
        let monitor = remote.wantsPhotos
        guard preview || monitor else { return }
        photoQueue.async {
            // モニターへは、横向きで撮った写真は横向きにして送る
            // 大きく見せるかはモニター側の「プレビュー」で決める（撮る側の設定がオフでも、モニターでは見られる）
            if monitor, let small = Self.smallJPEG(jpeg, maxSide: 1600) {
                self.remote.sendPhoto(small.data, showPreview: true)
            }
            // この画面のプレビューは、撮ったときの持ち方のまま（横に持って見ているので回さない）
            if preview, let small = Self.smallJPEG(jpeg, maxSide: 1600, applyOrientation: false) {
                DispatchQueue.main.async { self.lastCapture = CapturedPhoto(image: small.image) }
            }
        }
    }

    /// JPEG を長い辺 maxSide に縮めた JPEG と画像。applyOrientation なら向き（横向きで撮った写真）を画素に反映する
    static func smallJPEG(_ data: Data, maxSide: Int, applyOrientation: Bool = true) -> (data: Data, image: UIImage)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: applyOrientation,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cgImage)
        guard let small = image.jpegData(compressionQuality: 0.75) else { return nil }
        return (small, image)
    }

    private func save(_ result: (jpeg: Data, thumbnail: UIImage?)) {
        MediaSaver.savePhoto(result.jpeg) { ok in
            if ok {
                DispatchQueue.main.async { self.lastThumbnail = result.thumbnail }
                self.shareCapture(result.jpeg)
            } else {
                self.report("写真を保存できませんでした（写真へのアクセス許可を確認してください）")
            }
        }
    }

    private func processPhoto(_ data: Data, metadata: [String: Any], settings: ProcessingSettings, aspect: CGFloat,
                              ambient: (image: CIImage, exif: [String: Any], dark: Bool)?,
                              orientation: CGImagePropertyOrientation) -> (jpeg: Data, thumbnail: UIImage?)? {
        guard let source = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        var flash: (image: CIImage, ratio: Double, dark: Bool)?
        if let ambient {
            // 写真とコマの露出（シャッター速度 × ISO）の比で、コマの明るさを写真の明るさにそろえる
            if let photoExposure = PhotoMetadata.exposure(of: metadata),
               let frameExposure = PhotoMetadata.exposure(ofExif: ambient.exif), frameExposure > 0 {
                flash = (ambient.image, photoExposure / frameExposure, ambient.dark)
            } else {
                Diagnostics.log("ダイレクトフラッシュ: 露出の情報がないので通常のフラッシュで保存")
            }
        }
        if let result = processStill(source, settings: settings, aspect: aspect, metadata: metadata, upscaleTo: nil,
                                     orientation: orientation, ambient: flash) {
            return result
        }
        guard flash != nil else { return nil }
        // 続けて撮ったときに一時的に書き出せないことがあるので、少し待って 1 回やり直す
        Diagnostics.log("ダイレクトフラッシュ: 書き出しに失敗、やり直す")
        Thread.sleep(forTimeInterval: 0.3)
        if let result = processStill(source, settings: settings, aspect: aspect, metadata: metadata, upscaleTo: nil,
                                     orientation: orientation, ambient: flash) {
            return result
        }
        // ダイレクトフラッシュの加工で書き出せなかったときも、写真は残す（通常のフラッシュの写真として保存する）
        Diagnostics.log("ダイレクトフラッシュ: 書き出しに失敗したので通常のフラッシュで保存")
        report("ダイレクトフラッシュの加工に失敗したので、通常のフラッシュで保存しました")
        return processStill(source, settings: settings, aspect: aspect, metadata: metadata, upscaleTo: nil,
                            orientation: orientation)
    }

    /// upscaleTo: 無音撮影で、通常の写真の大きさ（縦向き）。小さければ引き伸ばす。
    /// ambient: ダイレクトフラッシュで、発光直前のコマと露出の比。
    private func processStill(_ source: CIImage, settings: ProcessingSettings, aspect: CGFloat,
                              metadata: [String: Any], upscaleTo: CGSize?,
                              orientation: CGImagePropertyOrientation = .up,
                              ambient: (image: CIImage, ratio: Double, dark: Bool)? = nil) -> (jpeg: Data, thumbnail: UIImage?)? {
        let normalized = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX,
                                                                  y: -source.extent.minY))
        var image = FrameGeometry(sourceSize: normalized.extent.size, aspect: aspect, maxLongSide: nil)
            .apply(normalized)
        if let target = upscaleTo {
            // 通常の写真を同じ比率に切り抜いたときの大きさまで、Lanczos で引き伸ばす
            let full = FrameGeometry(sourceSize: target, aspect: aspect, maxLongSide: nil).outputSize
            let scale = full.height / image.extent.height
            if scale > 1.01 {
                image = image.applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0,
                ]).cropped(to: CGRect(origin: .zero, size: full))
            }
        }
        if let ambient {
            let frame = ambient.image.transformed(by: CGAffineTransform(translationX: -ambient.image.extent.minX,
                                                                        y: -ambient.image.extent.minY))
            let cropped = FrameGeometry(sourceSize: frame.extent.size, aspect: aspect, maxLongSide: nil).apply(frame)
            let fitted = cropped.transformed(by: CGAffineTransform(scaleX: image.extent.width / cropped.extent.width,
                                                                   y: image.extent.height / cropped.extent.height))
            image = DirectFlash.apply(photo: image, ambient: fitted, exposureRatio: ambient.ratio,
                                      darkBackground: ambient.dark)
        }

        let wantsMasks = settings.needsSkinMask
        var analysis = PoseDetector.Result()
        if settings.needsMasks || settings.legLength > 0.01 {
            analysis = detector.analyze(ciImage: image, wantsMasks: wantsMasks, wantsPerson: settings.needsPersonMask)
        }
        let legs = settings.legLength > 0.01 ? LegLayout.make(pose: analysis.pose, manual: settings.legRange) : nil
        let output = processor.process(image, settings: settings, legs: legs, masks: analysis.masks)
        // 撮影情報（Exif・レンズ名など）を付けて JPEG にする
        guard let jpeg = PhotoMetadata.jpeg(output, metadata: metadata, context: renderer.ciContext,
                                            orientation: orientation) else { return nil }
        return (jpeg, makeThumbnail(output, orientation: orientation))
    }

    func makeThumbnail(_ image: CIImage, orientation: CGImagePropertyOrientation = .up) -> UIImage? {
        let scale = 240 / max(image.extent.width, image.extent.height)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = renderer.ciContext.createCGImage(small, from: small.extent) else { return nil }
        // 横向きで撮った写真は、サムネイルも横向きに見せる
        let uiOrientation: UIImage.Orientation
        switch orientation {
        case .right: uiOrientation = .right
        case .left: uiOrientation = .left
        case .down: uiOrientation = .down
        default: uiOrientation = .up
        }
        return UIImage(cgImage: cgImage, scale: 1, orientation: uiOrientation)
    }

    func setThumbnail(_ image: UIImage?) {
        lastThumbnail = image
    }

    // MARK: - 動画・スナップ

    func stopRecordingIfNeeded() {
        if isRecording { stopRecording() }
        if isSequenceRunning { cancelSequence() }
    }

    /// 写真モードでシャッターを 1 秒長押ししたとき。離すまで（最長 10 秒）動画を撮る
    func startQuickVideo() {
        guard mode == .photo, !isRecording, !isSequenceRunning else { return }
        startRecording(quick: true)
    }

    func stopQuickVideo() {
        if isQuickVideo { stopRecording() }
    }

    /// 録画中に静止画を撮る（標準のカメラと同じく、録画中のコマをそのまま写真にする。音は鳴らさない）
    func captureStillWhileRecording() {
        guard isRecording else { return }
        shutterCount += 1
        pendingPhotos += 1
        isCapturing = true
        captureSilently(upscale: false)
    }

    private func startRecording(quick: Bool = false) {
        guard mode != .photo || quick, !isRecording else { return }
        isRecording = true
        isQuickVideo = quick
        recordingSeconds = 0
        takeCounter += 1
        let take = takeCounter
        let withAudio = mode == .video || quick
        recordingAudio.value = withAudio
        if quick {
            // 写真モードはマイクをつないでいないので、長押しの動画のときだけつなぐ
            sessionQueue.async {
                self.session.beginConfiguration()
                self.attachAudio()
                self.session.commitConfiguration()
            }
        }
        // 無音の設定では開始・停止の音を鳴らさない（鳴らすと、その音が動画に入る）
        let mute = muteShutter
        if !mute { Sounds.play(.recordStart) }
        recordTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.recordingSeconds += 1
            if (self.mode == .snap || self.isQuickVideo) && self.recordingSeconds >= Self.snapMaxSeconds {
                self.stopRecording()
            }
        }
        let audio = AVAudioSession.sharedInstance()
        let route = audio.currentRoute.inputs.map { "\($0.portType.rawValue)/\($0.selectedDataSource?.dataSourceName ?? "-")" }
        Diagnostics.log("録画: 開始の操作 #\(take)（マイク \(route.joined(separator: ",")), 音声 \(withAudio ? "あり" : "なし"), "
            + "\(audio.category.rawValue)/\(audio.mode.rawValue), 入力の音量 \(String(format: "%.2f", audio.inputGain)), "
            + "マイクの許可 \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)）")
        // 開始音が録音に入らないよう、少し待ってから書き込みを始める
        DispatchQueue.main.asyncAfter(deadline: .now() + (mute ? 0.05 : 0.45)) {
            guard self.isRecording, self.takeCounter == take else { return }
            self.recordingTake.value = take
        }
    }

    /// 停止したら、すぐに停止音を鳴らし、書き出しと写真への保存は裏で続ける。
    /// その間にほかのアプリへ移ったり、次の録画を始めたりしても、保存が終わるまで続ける
    /// （iOS にバックグラウンドでの実行時間をもらう）。
    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        let quick = isQuickVideo
        isQuickVideo = false
        recordTimer?.invalidate()
        recordTimer = nil
        recordingTake.value = nil
        let take = takeCounter
        let isSnap = mode == .snap && !quick
        if !muteShutter { Sounds.play(.recordStop) }

        savingVideos += 1
        let background = BackgroundTask(name: "動画の保存")
        let finished = {
            DispatchQueue.main.async {
                self.savingVideos = max(0, self.savingVideos - 1)
                background.end()
            }
        }

        // 書き込みのキューで止める。それまでに渡したコマはすべて書いてから止まる（キューは順番どおり）
        recordingQueue.async {
            guard let recorder = self.recorder, self.recorderTake == take else {
                // 録画中に映像のコマが 1 つも届かなかった
                Diagnostics.log("録画: #\(take) コマが届かず録画できず（受信 \(self.frameCount) コマ目）")
                self.report("録画できませんでした（カメラの映像が届いていません）")
                finished()
                return
            }
            // 次の録画は新しい書き出し先で始まる。この録画の書き出しは、そのまま裏で続く
            self.recorder = nil
            self.recorderTake = nil
            let thumbnail = self.lastRecordedBuffer.flatMap { self.makeThumbnail(CIImage(cvPixelBuffer: $0)) }
            self.lastRecordedBuffer = nil
            if self.droppedRecordFrames > 0 {
                Diagnostics.log("録画: #\(take) 書き込みが追いつかず捨てたコマ \(self.droppedRecordFrames)")
                self.droppedRecordFrames = 0
            }
            if self.failedRecordFrames > 0 {
                Diagnostics.log("録画: #\(take) 描けずに捨てたコマ \(self.failedRecordFrames)")
                self.failedRecordFrames = 0
            }

            recorder.finish { outcome in
                guard let url = outcome.url else {
                    Diagnostics.log("録画: #\(take) 書き出し失敗 \(outcome.failure ?? "")")
                    self.report("動画の書き出しに失敗しました: \(outcome.failure ?? "理由不明")")
                    finished()
                    return
                }
                if isSnap {
                    DispatchQueue.main.async { self.snapClip = SnapClip(url: url) }
                    finished()
                    return
                }
                MediaSaver.saveVideo(at: url) { ok, reason in
                    if ok {
                        Diagnostics.log("録画: #\(take) 保存完了\(outcome.partial ? "（途中まで）" : "")")
                        DispatchQueue.main.async { self.lastThumbnail = thumbnail }
                        if outcome.partial {
                            self.report("動画の最後の部分を書き出せなかったので、途中まで保存しました")
                        }
                    } else {
                        Diagnostics.log("録画: #\(take) 保存失敗 \(reason ?? "")")
                        self.report("動画を保存できませんでした: \(reason ?? "写真へのアクセス許可を確認してください")")
                    }
                    finished()
                }
            }
        }

        if quick {
            // 長押しの動画が終わったら、写真モードのマイクを外す（マイク使用中の表示を消す）
            sessionQueue.async {
                guard self.modeBox.value == .photo else { return }
                self.session.beginConfiguration()
                self.detachAudio()
                self.session.commitConfiguration()
            }
        }
    }

    /// videoQueue から呼ぶ。加工済みのコマを書き込み用の入れ物に描いて、書き込みのキューへ渡す。
    /// 描いた入れ物を返す（録画中はプレビューもこれを表示し、同じ加工を 2 回 GPU で描かない）。
    private func handleRecording(_ image: CIImage, at time: CMTime) -> CVPixelBuffer? {
        guard let take = recordingTake.value else { return nil }
        // 書き込みが詰まっているときは、プレビューを止めないようにコマを捨てる
        guard pendingRecordFrames.value < 8 else {
            recordingQueue.async { self.droppedRecordFrames += 1 }
            return nil
        }
        guard let buffer = makeRecordBuffer(image) else {
            // 描けなかったコマは書き込まない（以前は真っ黒なコマが入っていた）
            recordingQueue.async { self.failedRecordFrames += 1 }
            return nil
        }
        pendingRecordFrames.value += 1
        recordingQueue.async {
            self.pendingRecordFrames.value -= 1
            self.appendRecordFrame(buffer, at: time, take: take)
        }
        return buffer
    }

    /// videoQueue から呼ぶ。
    private func makeRecordBuffer(_ image: CIImage) -> CVPixelBuffer? {
        let extent = image.extent
        let size = CGSize(width: CGFloat(Int(extent.width) / 2 * 2), height: CGFloat(Int(extent.height) / 2 * 2))
        if recordPool == nil || recordPoolSize != size {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            recordPool = pool
            recordPoolSize = size
        }
        guard let recordPool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, recordPool, &buffer)
        guard let buffer else { return nil }
        let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        guard renderer.ciContext.renderAndWait(normalized, to: buffer, size: size) else { return nil }
        return buffer
    }

    /// recordingQueue から呼ぶ。最初のコマで書き出し先を作る。
    private func appendRecordFrame(_ buffer: CVPixelBuffer, at time: CMTime, take: Int) {
        if recorderTake != take {
            // すでに止めた録画のコマは捨てる
            guard recordingTake.value == take else { return }
            let started = CACurrentMediaTime()
            let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            var audioSettings: [String: Any]?
            if recordingAudio.value {
                // マイクがつながっていれば、カメラの勧める設定を使う。取れなければ AAC で書く
                audioSettings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov)
                if audioSettings == nil {
                    Diagnostics.log("録画: 音声の推奨設定が取れず、AAC で書き込む")
                    audioSettings = VideoRecorder.fallbackAudioSettings
                }
            }
            // 録画を始めたときの端末の向きで、動画を横向き・縦向きにする（標準のカメラと同じく、途中では変えない）
            let transform = CaptureOrientation.videoTransform(for: CaptureOrientation.shared.current)
            do {
                recorder = try VideoRecorder(url: url, size: size, audioSettings: audioSettings, transform: transform)
            } catch {
                // HEVC で始められない機種・状態では H.264 で作り直す
                Diagnostics.log("録画: HEVC で開始できず \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: url)
                do {
                    recorder = try VideoRecorder(url: url, size: size, audioSettings: audioSettings, codec: .h264,
                                                 transform: transform)
                } catch {
                    Diagnostics.log("録画: 開始できず \(error.localizedDescription)")
                    report("録画を開始できませんでした: \(error.localizedDescription)")
                    recordingTake.value = nil
                    DispatchQueue.main.async { self.stopRecording() }
                    return
                }
            }
            recorderTake = take
            droppedRecordFrames = 0
            failedRecordFrames = 0
            let seconds = CACurrentMediaTime() - started
            Diagnostics.log("録画: #\(take) 開始 \(Int(size.width))x\(Int(size.height))\(seconds > 0.3 ? String(format: "（準備に %.1f 秒）", seconds) : "")")
        }
        recorder?.appendVideo(buffer, at: time)
        lastRecordedBuffer = buffer
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
            let template = self.templateBox.value
            let outlines = template?.allOutlines ?? []
            // 一致度は「関節の位置と向き」と「人の形の重なり」の両方で見る。
            // 顔のアップなど体の関節が取れないときも、人の形は取れるので採点できる
            let gridWidth = 48
            // 顔のパーツは、型に顔があるとき（顔の位置の一致度）と骨格を表示するときだけ求める
            let wantsFace = template?.face != nil || self.showSkeletonBox.value
            let result = self.detector.poseAndSilhouette(pixelBuffer: pixelBuffer,
                                                         silhouetteWidth: outlines.isEmpty ? nil : gridWidth,
                                                         face: wantsFace)
            let face = result.face
            let pose = result.pose
            self.poseBox.value = pose
            var score: Double?
            let isGroup = !(template?.extraPeople ?? []).isEmpty
            if let template, isGroup {
                // 2 人以上の型: 型の人と映っている人を組み合わせて、人ごとの一致度を平均する
                let detected = result.poses.map { $0.mapValues { PoseSpace.toIsotropic($0, aspect: aspect) } }
                let people = template.people
                let jointScore = PoseMatcher.score(people: people.map(\.joints), detected: detected, aspect: aspect)
                var silhouetteScore: Double?
                if let silhouette = result.silhouette {
                    let key = "\(template.id)|\(silhouette.width)x\(silhouette.height)"
                    if self.templateCells?.key != key {
                        self.templateCells = (key, PoseMatcher.rasterize(outlines, aspect: aspect,
                                                                         width: silhouette.width,
                                                                         height: silhouette.height))
                    }
                    silhouetteScore = PoseMatcher.silhouetteScore(template: self.templateCells!.cells,
                                                                  detected: silhouette.cells,
                                                                  width: silhouette.width)
                }
                let templateFaces = people.compactMap(\.face)
                let faceScore = PoseMatcher.faceScore(
                    templates: templateFaces,
                    detected: result.faces.map { $0.map { PoseSpace.toIsotropic($0, aspect: aspect) } },
                    personFound: !result.poses.isEmpty || silhouetteScore != nil)
                score = PoseMatcher.combine(joints: jointScore, silhouette: silhouetteScore, face: faceScore,
                                            faceWidth: templateFaces.map(\.width).max() ?? 0)
            } else if let template {
                let jointScore = pose.flatMap { pose -> Double? in
                    let isotropic = pose.mapValues { PoseSpace.toIsotropic($0, aspect: aspect) }
                    return PoseMatcher.score(template: template.joints, detected: isotropic, aspect: aspect)
                }
                var silhouetteScore: Double?
                if let silhouette = result.silhouette {
                    let key = "\(template.id)|\(silhouette.width)x\(silhouette.height)"
                    if self.templateCells?.key != key {
                        self.templateCells = (key, PoseMatcher.rasterize(outlines, aspect: aspect,
                                                                         width: silhouette.width,
                                                                         height: silhouette.height))
                    }
                    silhouetteScore = PoseMatcher.silhouetteScore(template: self.templateCells!.cells,
                                                                  detected: silhouette.cells,
                                                                  width: silhouette.width)
                }
                // 顔の位置・大きさ・傾き（型と映っている人の両方に顔があるときだけ）
                var faceScore: Double?
                if let templateFace = template.face, let face {
                    faceScore = PoseMatcher.faceScore(template: templateFace,
                                                      detected: face.map { PoseSpace.toIsotropic($0, aspect: aspect) })
                } else if template.face != nil, template.face!.width > 0.15 {
                    // 顔のアップの型なのに顔が映っていなければ 0 点として数える
                    faceScore = 0
                } else if template.face != nil, pose != nil || silhouetteScore != nil {
                    // 人は映っているのに顔が見つからない（手や物で隠れている）ときは、半分の点として数える。
                    // 数えないと、顔の点数が低い人ほど顔を隠した方が一致度が上がっていた
                    faceScore = 50
                }
                // 人が見つからないときも「0%」と表示する（表示が消えると反応していないように見えるため）
                score = PoseMatcher.combine(joints: jointScore, silhouette: silhouetteScore, face: faceScore,
                                            faceWidth: template.face?.width ?? 0)
            }
            self.isDetecting.value = false

            DispatchQueue.main.async {
                guard self.poseNeeded.value else { return }
                if self.poseFeed.detected != pose { self.poseFeed.detected = pose }
                if self.poseFeed.face != face { self.poseFeed.face = face }
                let others = isGroup ? Array(result.poses.dropFirst()) : []
                let otherFaces = isGroup ? Array(result.faces.dropFirst()) : []
                if self.poseFeed.others != others { self.poseFeed.others = others }
                if self.poseFeed.otherFaces != otherFaces { self.poseFeed.otherFaces = otherFaces }
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

    /// 脚長で伸ばす範囲を少しずつ追従させ、境目がちらつかないようにする。videoQueue から呼ぶ。
    private func updatedLegs(manual: ClosedRange<Double>?) -> LegLayout? {
        guard let target = LegLayout.make(pose: poseBox.value, manual: manual) else { return smoothedLegs }
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a * 0.8 + b * 0.2 }
        let smoothed = smoothedLegs.map {
            LegLayout(shoulder: mix($0.shoulder, target.shoulder), start: mix($0.start, target.start),
                      end: mix($0.end, target.end), headTop: mix($0.headTop, target.headTop))
        } ?? target
        smoothedLegs = smoothed
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
            // 失敗の理由は読み切れるよう長めに出す
            DispatchQueue.main.asyncAfter(deadline: .now() + (message.count > 30 ? 8 : 2.5)) {
                if self.statusMessage == message { self.statusMessage = nil }
            }
        }
    }
}

/// iOS にバックグラウンドで実行を続ける時間をもらう。end() は何度呼んでもよい（メインスレッドから使う）。
private final class BackgroundTask {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Diagnostics.log("\(name): バックグラウンドの時間切れ")
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

// MARK: - フレーム受信

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === audioOutput {
            // 音声は録画のキュー（recordingQueue）で届く
            recorder?.appendAudio(sampleBuffer)
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let frameStarted = CACurrentMediaTime()
        defer { noteSlowFrame(since: frameStarted) }

        // 最初の 1 コマだけ記録し、1 秒ほど動いたら正常とみなす
        frameCount += 1
        if frameCount == 1 {
            Diagnostics.mark("フレーム: 初回受信 \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))")
        }
        if frameCount == 30 { Diagnostics.markHealthy() }

        let source = CIImage(cvPixelBuffer: pixelBuffer)
        latestSourceBox.value = source
        if motionWatch.value, frameCount % 3 == 0 { measureMotion(source) }
        if let exif = CMGetAttachment(sampleBuffer, key: kCGImagePropertyExifDictionary, attachmentModeOut: nil)
            as? [String: Any] {
            latestExifBox.value = exif
        }

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
        let wantsMasks = settings.needsMasks
        let wantsPose = poseNeeded.value

        let image = geometry.apply(source)
        publishFrameSizeIfNeeded(image.extent.size)

        // 判定（骨格・肌・顔のパーツ）は、切り抜いて小さくしたコマで行う（大きなコマのままだと重い）
        var visionBuffer: CVPixelBuffer?
        if wantsMasks || wantsPose {
            // 動画・スナップでは毎コマ判定するので小さめにして、コマ落ちを減らす
            visionBuffer = makeVisionBuffer(image, maxLongSide: isPhoto ? 960 : 640)
            // 判定用のコマが描けなかったときは、美肌のかからないコマが混ざらないよう、このコマを捨てる
            if visionBuffer == nil, wantsMasks { return }
        }
        if wantsPose, let visionBuffer {
            analyzeIfIdle(visionBuffer, aspect: geometry.aspect)
        }

        // 美肌のマスクは、このコマ自身から求める。前のコマのマスクを使うと、カメラや顔が動いたときに
        // 加工の位置が遅れてずれる。間に合わないコマは捨てられる（alwaysDiscardsLateVideoFrames）
        var masks: BeautyMasks?
        if wantsMasks, let visionBuffer {
            masks = detector.beautyMasks(pixelBuffer: visionBuffer, outputSize: image.extent.size,
                                         skin: settings.needsSkinMask, person: settings.needsPersonMask)
        }
        let legs = settings.legLength > 0.01 ? updatedLegs(manual: settings.legRange) : nil
        let processed = processor.process(image, settings: settings, legs: legs, masks: masks)
        if let recorded = handleRecording(processed, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) {
            // 録画中は、録画用に描いたコマをそのまま表示する（加工を 2 回描くと GPU が追いつかずコマ落ちしていた）
            let extent = processed.extent
            let shown = CIImage(cvPixelBuffer: recorded)
                .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            renderer.display(shown)
            remote.offer(shown, context: renderer.ciContext)
        } else {
            renderer.display(processed)
            remote.offer(processed, context: renderer.ciContext)
        }
    }

    private func updateMotionWatch() {
        let watch = flashOn && directFlash && mode == .photo
        motionWatch.value = watch
        if !watch { isMovingTooMuch = false }
    }

    /// カメラ・被写体の動きの大きさを、3 コマに 1 回、24×32 に縮めたコマの明るさの差で求める（videoQueue）。
    /// ダイレクトフラッシュは、発光前のコマと写真の間に動くと合成がずれるので、動いている間は撮る前に知らせる。
    /// 骨格の判定は人が写っていないと使えず、カメラの手ぶれも分からないので、画面全体の変化で見る
    private func measureMotion(_ source: CIImage) {
        let w = 24, h = 32
        let e = source.extent
        let scale = CGFloat(h) / e.height
        let tiny = source
            .applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: (CGFloat(w) / e.width) / scale,
            ])
        let t = tiny.extent
        let placed = tiny.transformed(by: CGAffineTransform(translationX: -t.minX, y: -t.minY))
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        renderer.ciContext.render(placed, toBitmap: &bytes, rowBytes: w * 4,
                                  bounds: CGRect(x: 0, y: 0, width: w, height: h),
                                  format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var luma = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            luma[i] = (0.299 * Float(bytes[i * 4]) + 0.587 * Float(bytes[i * 4 + 1]) + 0.114 * Float(bytes[i * 4 + 2])) / 255
        }
        defer { motionPrevious = luma }
        guard let previous = motionPrevious else { return }
        var diff: Float = 0
        for i in 0..<luma.count { diff += abs(luma[i] - previous[i]) }
        diff /= Float(luma.count)
        motionLevel = motionLevel * 0.6 + diff * 0.4
        // 出す・消すの境目を分けて、表示がちらつかないようにする
        let moving = motionMoving ? motionLevel > 0.018 : motionLevel > 0.03
        guard moving != motionMoving else { return }
        motionMoving = moving
        DispatchQueue.main.async {
            if self.motionWatch.value { self.isMovingTooMuch = moving }
        }
    }

    /// 1 コマの処理に 0.5 秒以上かかったら記録する（5 秒に 1 回まで）。videoQueue から呼ぶ。
    private func noteSlowFrame(since start: CFTimeInterval) {
        let now = CACurrentMediaTime()
        let seconds = now - start
        guard seconds > 0.5, now - lastSlowFrameLog > 5 else { return }
        lastSlowFrameLog = now
        Diagnostics.log(String(format: "映像: 1 コマの処理に %.1f 秒かかった", seconds))
    }

    /// 判定用に、長辺 maxLongSide ピクセルまで縮小したコマを作る。videoQueue から呼ぶ。
    private func makeVisionBuffer(_ image: CIImage, maxLongSide: CGFloat) -> CVPixelBuffer? {
        let extent = image.extent
        let scale = min(1, maxLongSide / max(extent.width, extent.height))
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
        // 描き終わる前に判定すると、黒いコマや前のコマから肌の範囲を求めてしまう（全体がぼやけるコマの原因）
        guard renderer.ciContext.renderAndWait(small, to: buffer, size: size) else { return nil }
        return buffer
    }
}

// MARK: - 写真受信

extension CameraManager: AVCapturePhotoCaptureDelegate {
    /// 写真 1 枚の撮影（露光・発光）がすべて終わった
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        guard endSignalPhotoID.value == resolvedSettings.uniqueID else { return }
        endSignalPhotoID.value = nil
        sessionQueue.async { self.signalSequenceFinished(after: resolvedSettings.isFlashEnabled ? 0.4 : 0.15) }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        let settings = settingsBox.value
        let aspect = aspectBox.value
        let data = photo.fileDataRepresentation()
        let metadata = photo.metadata
        // シャッターを押した直後の端末の向き（横向きなら横向きの写真として保存する）
        let orientation = CaptureOrientation.shared.current
        var frames = ambientFrames.value
        let ambient = frames.removeValue(forKey: photo.resolvedSettings.uniqueID)
        ambientFrames.value = frames

        photoQueue.async {
            defer { DispatchQueue.main.async { self.photoFinished() } }
            guard error == nil, let data,
                  let result = self.processPhoto(data, metadata: metadata, settings: settings, aspect: aspect,
                                                 ambient: ambient, orientation: orientation) else {
                self.report("写真の処理に失敗しました")
                return
            }
            self.save(result)
        }
    }
}
