import PhotosUI
import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var library = PoseLibrary()
    @Environment(\.scenePhase) private var scenePhase

    @State private var panel: ControlPanel?
    /// 美肌・スタイルで選んでいる項目（パネルを閉じても覚えておく。脚長のときは伸ばす範囲の線を出す）
    @State private var beautyItem: BeautyItem = .smoothing
    /// 選んだポーズの見本写真を左下に出すか
    @AppStorage("showPoseSample") private var showPoseSample = true
    @State private var selectedPose: PoseTemplate?
    @State private var mirrorPose = false
    @State private var poseOpacity = 0.85
    @State private var showLibrary = false
    @State private var showLicenses = false
    @State private var showAlbum = false
    /// 構図のガイドの線
    @AppStorage("gridStyle") private var gridStyle: GridStyle = .off
    /// 水平器
    @AppStorage("showLevel") private var showLevel = true
    @State private var zoomAtGestureStart: CGFloat?
    /// タップしてピント・露出を合わせた所（プレビューの中の位置）。nil なら枠を出さない
    @State private var focusPoint: CGPoint?
    @State private var focusDimmed = false
    @State private var focusDimTask: Task<Void, Never>?
    @State private var biasAtPanStart: Float?
    /// 本体のボタンを押し続けたときの短い動画
    @State private var hardwareHoldTask: Task<Void, Never>?
    @State private var hardwareQuickVideo = false
    /// 倍率ボタンの帯の位置（画面の座標。持ち上げる前）
    @State private var lensBarFrame: CGRect?
    /// パネルを下へなぞっている途中
    @State private var panelFlicking = false
    /// 写真の保存に時間がかかっている（0.7 秒たっても終わらない）ときだけ「保存中」を出す
    @State private var showsSaving = false
    @State private var crashReport: CrashReport? = Diagnostics.previousCrash

    private let topBarHeight: CGFloat = 50

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let screen = CGSize(width: geo.size.width + insets.leading + insets.trailing,
                                height: geo.size.height + insets.top + insets.bottom)

            ZStack(alignment: .top) {
                Color.black

                if camera.cameraAuthorized {
                    preview(screen: screen, topInset: insets.top)

                    VStack(spacing: 0) {
                        topBar
                            .frame(height: topBarHeight)
                            .padding(.top, insets.top)
                        statusRow
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                        Spacer(minLength: 0)
                        bottomControls(previewBottom: previewBottom(screen: screen, topInset: insets.top))
                            .padding(.bottom, max(insets.bottom, 12))
                    }

                    if camera.template != nil {
                        poseSideBar
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                            .padding(.trailing, 10)
                            .offset(y: -40)
                    }

                    if let timeline = camera.burstTimeline {
                        BurstRing(timeline: timeline)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    ShutterBlackout(trigger: camera.shutterCount)

                    if let countdown = camera.countdown {
                        Text("\(countdown)")
                            .font(.system(size: 120, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                    }
                } else {
                    PermissionView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if let message = camera.statusMessage {
                    Badge(text: message, color: .black.opacity(0.8))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }

                if let report = crashReport {
                    CrashReportView(report: report) { disableEffects in
                        if disableEffects {
                            camera.settings.smoothing = 0
                            camera.settings.brightening = 0
                        }
                        crashReport = nil
                        camera.start()
                    }
                }
            }
            .frame(width: screen.width, height: screen.height)
            .ignoresSafeArea()
            .onAppear { camera.setScreenAspect(screen.width / screen.height) }
            .onChange(of: screen) { camera.setScreenAspect(screen.width / screen.height) }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            // 前回カメラ起動中に落ちていたら、記録を見せるまでカメラは起動しない
            if crashReport == nil { camera.start() }
        }
        .onChange(of: selectedPose) { updateTemplate() }
        .onChange(of: camera.focusResetCount) { focusPoint = nil }
        .onChange(of: camera.savingPhotos) {
            if camera.savingPhotos == 0 {
                showsSaving = false
            } else if !showsSaving {
                Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    if camera.savingPhotos > 0 { showsSaving = true }
                }
            }
        }
        .onChange(of: showsLegRange) { camera.showsLegRange = showsLegRange }
        .onChange(of: mirrorPose) { updateTemplate() }
        // 比率を変えても、ポーズの型は同じ大きさのまま（縦長の比率で拡大しない）
        .onChange(of: camera.frameAspect) { updateTemplate() }
        .onChange(of: scenePhase) {
            if scenePhase != .active {
                camera.stopRecordingIfNeeded()
                // 起動直後に閉じられただけのときに「落ちた」と判定しないようにする
                Diagnostics.markHealthy()
            }
        }
        .sheet(isPresented: $showLibrary) {
            PoseLibraryView(library: library, selection: $selectedPose)
        }
        .sheet(isPresented: $showLicenses) {
            LicensesView()
        }
        .fullScreenCover(isPresented: $showAlbum) {
            AlbumView()
        }
        .sheet(item: $camera.snapClip) { clip in
            SnapPickerView(clip: clip) { image in camera.setThumbnail(image) }
        }
    }

    // MARK: - プレビュー

    /// 3:4・9:16 は上のバーのすぐ下から、フルは画面全体に表示する。
    private func preview(screen: CGSize, topInset: CGFloat) -> some View {
        let aspect = camera.aspect.ratio ?? screen.width / screen.height
        let height = min(screen.width / aspect, screen.height)
        let top = camera.aspect == .full ? 0 : topInset + topBarHeight

        return ZStack {
            CameraPreview(renderer: camera.renderer)
            Group {
                if let template = camera.template {
                    TemplateLayer(feed: camera.poseFeed, template: template, opacity: poseOpacity)
                }
                if camera.showSkeleton {
                    SkeletonLayer(feed: camera.poseFeed)
                }
                if gridStyle != .off {
                    GridOverlay(style: gridStyle)
                }
                if showLevel {
                    LevelView()
                }
            }
            .allowsHitTesting(false)
            // タップ（ピント・露出）・長押し（AE/AF ロック）・上下（露出）・つまむ（ズーム）・本体のボタン（シャッター）
            CameraGestureView(hardwareShutterEnabled: hardwareShutterEnabled,
                              onTap: { point, size in handleTap(point, size) },
                              onLongPress: { point, size in handleLongPress(point, size) },
                              onVerticalPan: { dy in handlePan(dy) },
                              onPinch: { scale in
                                  guard let scale else { zoomAtGestureStart = nil; return }
                                  let start = zoomAtGestureStart ?? camera.displayZoom
                                  zoomAtGestureStart = start
                                  camera.setDisplayZoom(start * scale)
                              },
                              onHardwareButton: { pressed in hardwareButton(pressed) })
            if let focusPoint {
                FocusIndicator(point: focusPoint, locked: camera.isFocusLocked, bias: camera.exposureBias,
                               dimmed: focusDimmed)
            }
            if camera.isFocusLocked {
                Text("AE/AF ロック")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.yellow))
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 50)
                    .allowsHitTesting(false)
            }
            if showsLegRange {
                LegRangeOverlay(feed: camera.poseFeed, settings: $camera.settings)
            }
        }
        .frame(width: screen.width, height: height)
        .clipped()
        .offset(y: top)
    }

    /// 美肌・スタイルのパネルで脚長を選んでいる
    private var showsLegRange: Bool { panel == .beauty && beautyItem == .legLength }

    // MARK: - ピント・露出・本体のボタン

    /// アルバム・編集などの画面を開いている間は、音量ボタンをふつうの音量ボタンに戻す
    private var hardwareShutterEnabled: Bool {
        camera.cameraAuthorized && !showAlbum && !showLibrary && !showLicenses
            && camera.snapClip == nil && crashReport == nil
    }

    /// タップ: パネルが開いていれば閉じる。閉じていれば、その所にピントと露出を合わせる
    private func handleTap(_ point: CGPoint, _ size: CGSize) {
        if panel != nil {
            withAnimation(.easeOut(duration: 0.18)) { panel = nil }
            return
        }
        camera.focus(at: point, in: size, lock: false)
        showFocus(at: point)
    }

    /// 長押し: ピントと露出を合わせて固定する（AE/AF ロック）
    private func handleLongPress(_ point: CGPoint, _ size: CGSize) {
        if panel != nil {
            withAnimation(.easeOut(duration: 0.18)) { panel = nil }
            return
        }
        camera.focus(at: point, in: size, lock: true)
        showFocus(at: point)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// 枠が出ている間、上下になぞると露出を補正する（上で明るく。120 ポイントで 1 段）
    private func handlePan(_ dy: CGFloat?) {
        guard focusPoint != nil else { return }
        guard let dy else {
            biasAtPanStart = nil
            scheduleFocusDim()
            return
        }
        let start = biasAtPanStart ?? camera.exposureBias
        biasAtPanStart = start
        focusDimTask?.cancel()
        focusDimmed = false
        camera.setExposureBias(start - Float(dy / 120))
    }

    private func showFocus(at point: CGPoint) {
        focusPoint = point
        focusDimmed = false
        scheduleFocusDim()
    }

    private func scheduleFocusDim() {
        focusDimTask?.cancel()
        focusDimTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            focusDimmed = true
        }
    }

    /// 本体のボタン（音量・イヤホン・リモコン・AirPods）。離したらシャッター。
    /// 写真モードで押し続けると、画面のシャッターの長押しと同じく短い動画を撮り、離すと止める
    private func hardwareButton(_ pressed: Bool) {
        if pressed {
            hardwareHoldTask?.cancel()
            hardwareQuickVideo = false
            guard camera.mode == .photo, !camera.isSequenceRunning, !camera.isRecording else { return }
            hardwareHoldTask = Task {
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                hardwareQuickVideo = true
                camera.startQuickVideo()
            }
            return
        }
        hardwareHoldTask?.cancel()
        hardwareHoldTask = nil
        if hardwareQuickVideo {
            hardwareQuickVideo = false
            camera.stopQuickVideo()
        } else if !(camera.isRecording && camera.isQuickVideo) {
            camera.shutterPressed()
        }
    }

    // MARK: - 上部

    private var topBar: some View {
        HStack {
            AspectMenu(aspect: $camera.aspect)
                .disabled(camera.isRecording)
            Spacer()
            GridMenu(style: $gridStyle)
            Spacer()
            LabeledIconButton(systemImage: "timer",
                              label: camera.timerSeconds == 0 ? "タイマー" : "\(camera.timerSeconds)秒",
                              active: camera.timerSeconds > 0) {
                camera.timerSeconds = next(after: camera.timerSeconds, in: [0, 3, 6, 10])
            }
            Spacer()
            LabeledIconButton(systemImage: "square.stack.3d.down.right",
                              label: camera.burstCount == 1 ? "連続撮影" : "\(camera.burstCount)枚",
                              active: camera.burstCount > 1) {
                // ダイレクトフラッシュのときは 3 枚まで（1 枚の加工が重く、続けて撮ると保存できないことがあった）
                camera.burstCount = next(after: camera.burstCount,
                                         in: camera.flashOn && camera.directFlash ? [1, 3] : [1, 3, 5, 10])
            }
            .disabled(camera.mode != .photo)
            .opacity(camera.mode == .photo ? 1 : 0.4)
            Spacer()
            Menu {
                Toggle(camera.canMuteShutter ? "ミュート" : "ミュート（画質が落ちます）", isOn: $camera.muteShutter)
                Toggle("骨格を表示", isOn: $camera.showSkeleton)
                Toggle("水平器", isOn: $showLevel)
                Button("動作の記録をコピー") {
                    UIPasteboard.general.string = ([
                        "iOS \(UIDevice.current.systemVersion)",
                    ] + Diagnostics.events).joined(separator: "\n")
                }
                Button("ライセンス") { showLicenses = true }
            } label: {
                LabeledIcon(systemImage: camera.muteShutter ? "speaker.slash" : "ellipsis.circle", label: "設定")
            }
        }
        .padding(.horizontal, 10)
    }

    /// 一致度・録画時間・連続撮影の進み具合。
    private var statusRow: some View {
        HStack {
            if let template = camera.template, !template.isObject {
                MatchBadge(feed: camera.poseFeed)
            }
            Spacer()
            if let progress = camera.burstProgress {
                Badge(text: progress)
            }
            if camera.isMovingTooMuch && camera.flashOn && camera.directFlash && camera.mode == .photo {
                // ダイレクトフラッシュは、発光前と撮影の間に動くと合成がずれる。撮る前に知らせる
                Badge(text: "動いています。止まってから撮ってください", color: Color.orange.opacity(0.9))
            }
            if showsSaving {
                Badge(text: camera.savingPhotos > 1 ? "写真を保存中（\(camera.savingPhotos) 枚）・アプリを閉じないでください"
                                                    : "写真を保存中・アプリを閉じないでください")
            }
            if camera.savingVideos > 0 {
                Badge(text: camera.savingVideos > 1 ? "動画を保存中（\(camera.savingVideos) 本）" : "動画を保存中")
            }
            if camera.isRecording {
                let seconds = camera.recordingSeconds
                Badge(text: camera.mode == .snap
                      ? "スナップ \(seconds)/\(CameraManager.snapMaxSeconds)秒"
                      : String(format: "%02d:%02d", seconds / 60, seconds % 60),
                      dot: .red)
            }
        }
        .frame(height: 32)
    }

    private var poseSideBar: some View {
        PoseSideBar(opacity: $poseOpacity,
                    mirrored: $mirrorPose,
                    autoShutter: $camera.autoShutter,
                    recommendedZoom: camera.template?.recommendedZoom,
                    canAutoShutter: camera.mode == .photo && camera.template?.isObject != true,
                    onClear: { selectedPose = nil },
                    onApplyZoom: { camera.setDisplayZoom(CGFloat($0), animated: true) })
    }

    // MARK: - 下部

    /// プレビューの下端（画面の上端からの位置）
    private func previewBottom(screen: CGSize, topInset: CGFloat) -> CGFloat {
        guard camera.aspect != .full, let ratio = camera.aspect.ratio else { return screen.height }
        return topInset + topBarHeight + min(screen.width / ratio, screen.height)
    }

    /// 倍率ボタンがプレビューの下端にまたがるとき、プレビューの上に収まるまで持ち上げる量（負の値）
    private func lensBarShift(previewBottom: CGFloat) -> CGFloat {
        guard let frame = lensBarFrame, frame.minY < previewBottom, frame.maxY > previewBottom else { return 0 }
        return -(frame.maxY - previewBottom) - 6
    }

    private func bottomControls(previewBottom: CGFloat) -> some View {
        VStack(spacing: 10) {
            // 選んだポーズの見本写真（左下）。タップで隠す・出す
            if let name = selectedPose?.imageName {
                PoseSampleCard(imageName: name, mirrored: mirrorPose, shown: $showPoseSample)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 12)
            }
            if camera.lensOptions.count > 1 {
                LensBar(options: camera.lensOptions, zoom: camera.displayZoom,
                        minZoom: camera.minDisplayZoom, maxZoom: camera.maxDisplayZoom,
                        activeLens: camera.activeLensName,
                        onSelect: { camera.setDisplayZoom($0, animated: true) },
                        onZoom: { camera.setDisplayZoom($0) })
                    // 帯がプレビューの下端にまたがって、半分だけ映像の上にはみ出して見えないようにする
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { lensBarFrame = $0 }
                    .offset(y: lensBarShift(previewBottom: previewBottom))
            }

            if panel != nil {
                // パネルを開いている間は、下のパネルの切り替えボタンを隠して画面を広くし、代わりに閉じる印を出す
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { panel = nil }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 22)
                        .background(Capsule().fill(Color.black.opacity(0.45)))
                }
                .transition(.opacity)
            }

            if let panel {
                Group {
                    switch panel {
                    case .pose:
                        PoseStrip(library: library, selection: $selectedPose,
                                  frameAspect: camera.frameAspect) { showLibrary = true }
                    case .filter:
                        FilterStrip(selection: $camera.settings.filter, strength: $camera.settings.filterStrength)
                    case .beauty:
                        BeautyPanel(settings: $camera.settings, showOriginal: $camera.showOriginal,
                                    selected: $beautyItem)
                    }
                }
                // 美肌・スタイルはスライダーが多いので少し高くする（はみ出した分はスクロール）
                .frame(height: panel == .beauty ? 120 : panel == .pose ? 140 : 134)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.6)))
                .padding(.horizontal, 8)
                // パネルは下へフリックしても閉じられる（横のスクロールとは向きで区別する）
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            // 下へなぞり始めたら、指を離したときに下のポーズ・フィルターが選ばれないようにする
                            let down = value.translation.height
                            if down > 12, down > abs(value.translation.width) { panelFlicking = true }
                        }
                        .onEnded { value in
                            let down = value.translation.height
                            if down > 40, down > abs(value.translation.width) * 1.2 {
                                withAnimation(.easeOut(duration: 0.18)) { self.panel = nil }
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { panelFlicking = false }
                        }
                )
                .environment(\.suppressPanelTaps, panelFlicking)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if panel == nil {
                PanelChips(panel: $panel)
                    .transition(.opacity)
            }

            HStack {
                flashButton
                Spacer()
                ShutterButton(mode: camera.mode,
                              isRecording: camera.isRecording,
                              isBusy: camera.isCapturing || camera.isSequenceRunning,
                              progress: Double(camera.recordingSeconds) / Double(CameraManager.snapMaxSeconds),
                              action: { camera.shutterPressed() },
                              onLongPressStart: { camera.startQuickVideo() },
                              onLongPressEnd: { camera.stopQuickVideo() })
                Spacer()
                if camera.isRecording && !camera.isQuickVideo {
                    // 録画中は、カメラの切り替えの代わりに静止画のシャッター（録画中のコマを写真にする）
                    Button {
                        camera.captureStillWhileRecording()
                    } label: {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 38, height: 38)
                            .overlay(Circle().stroke(Color.white, lineWidth: 2).padding(-4))
                            .frame(width: 48, height: 48)
                    }
                } else {
                    Button {
                        camera.flipCamera()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(Color.white.opacity(0.18)))
                    }
                    .disabled(camera.isRecording || camera.isSequenceRunning)
                }
            }
            .padding(.horizontal, 30)

            // 一番下はアルバムと撮影モード。画面を閉じるときの上スワイプでシャッターに触れないよう、
            // シャッターは一段上に置く
            ZStack {
                ModePicker(mode: camera.mode, isLocked: camera.isRecording || camera.isSequenceRunning) {
                    camera.setMode($0)
                }
                HStack {
                    ThumbnailButton(image: camera.lastThumbnail, busy: showsSaving) { showAlbum = true }
                    Spacer()
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 4)
        }
        .padding(.top, 14)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    /// 写真: オフ → オン → ダイレクト（背景を暗く落とす）→ オフ。動画・スナップはライトのオン・オフ
    private var flashButton: some View {
        LabeledIconButton(systemImage: camera.flashOn ? (camera.directFlash && camera.mode == .photo
                                                         ? "bolt.circle.fill" : "bolt.fill") : "bolt.slash",
                          label: camera.mode != .photo ? "ライト"
                              : camera.flashOn && camera.directFlash ? "ダイレクト" : "フラッシュ",
                          active: camera.flashOn) {
            if camera.mode != .photo {
                camera.flashOn.toggle()
            } else if !camera.flashOn {
                camera.directFlash = false
                camera.flashOn = true
            } else if !camera.directFlash {
                camera.directFlash = true
            } else {
                camera.flashOn = false
                camera.directFlash = false
            }
        }
        .frame(width: 48, height: 48)
    }

    private func next(after value: Int, in values: [Int]) -> Int {
        guard let index = values.firstIndex(of: value) else { return values[0] }
        return values[(index + 1) % values.count]
    }

    private func updateTemplate() {
        camera.template = selectedPose.map { (mirrorPose ? $0.mirrored() : $0).fitted(toFrameAspect: camera.frameAspect) }
    }
}
