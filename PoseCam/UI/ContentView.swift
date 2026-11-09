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
    /// リモートモニターの画面（撮る側）と、この iPhone をモニターにした画面
    @State private var showRemote = false
    @State private var showSettings = false
    /// 設定のシートを閉じた後に開く画面
    @State private var afterSettings: AfterSettings?
    private enum AfterSettings { case remote, licenses }
    /// リモートモニターのシートを閉じた後に、この端末をモニターにする
    @State private var monitorAfterRemote = false
    @State private var showMonitor = false
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
    /// パネル・シャッター・撮影モードの範囲の上端（画面の座標）
    @State private var controlsTop: CGFloat = .infinity
    /// シャッターの段・撮影モードの段の上端（画面の座標）。プレビューに重なっているかを決めるのに使う
    @State private var shutterRowTop: CGFloat = 0
    @State private var modeRowTop: CGFloat = 0
    /// 実際に表示しているプレビューの下端（画面の座標）。計算した値ではなく、表示された位置を測る
    @State private var measuredPreviewBottom: CGFloat?
    @AppStorage(Appearance.storageKey) private var appearance: Appearance = .system
    @Environment(\.colorScheme) private var colorScheme

    private let topBarHeight: CGFloat = 50

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let screen = CGSize(width: geo.size.width + insets.leading + insets.trailing,
                                height: geo.size.height + insets.top + insets.bottom)

            ZStack(alignment: .top) {
                Color.chromeBackground

                if camera.cameraAuthorized {
                    preview(screen: screen, topInset: insets.top)

                    VStack(spacing: 0) {
                        topBar
                            .frame(height: topBarHeight)
                            .padding(.top, insets.top)
                            // フルの比率では上のバーも映像の上に重なるので、外観の設定によらず白い文字にする
                            .environment(\.colorScheme, camera.aspect == .full ? .dark : colorScheme)
                        statusRow
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                        Spacer(minLength: 0)
                        bottomControls(previewBottom: measuredPreviewBottom
                                           ?? previewBottom(screen: screen, topInset: insets.top),
                                       bottomPadding: max(insets.bottom, 12))
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
        .preferredColorScheme(appearance.scheme)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            // 前回カメラ起動中に落ちていたら、記録を見せるまでカメラは起動しない
            if crashReport == nil { camera.start() }
            camera.remote.onCommand = { handleRemote($0) }
        }
        // モニターに送るガイドの絵と状態（見ているモニターがあるときだけ作る）
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                updateRemote()
            }
        }
        // この iPhone をモニターにしている間は、カメラを止める（撮る側としての送信もやめる）
        .onChange(of: showMonitor) {
            if showMonitor {
                camera.remote.disconnectMonitor()
                camera.remote.stopWeb()
                camera.suspend()
            } else if crashReport == nil {
                camera.resume()
            }
        }
        .onChange(of: selectedPose) { updateTemplate() }
        // アルバム（写真の表示・編集）を開いている間はカメラを止める（裏で動き続けて熱くなり、電池が減っていた）
        .onChange(of: showAlbum) {
            if showAlbum {
                camera.suspend()
            } else if crashReport == nil {
                camera.resume()
            }
        }
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
        .sheet(isPresented: $showSettings, onDismiss: {
            // 設定のシートが閉じ切ってから、次の画面を出す
            switch afterSettings {
            case .remote: showRemote = true
            case .licenses: showLicenses = true
            case nil: break
            }
            afterSettings = nil
        }) {
            settingsSheet
        }
        .sheet(isPresented: $showLicenses) {
            LicensesView()
        }
        .fullScreenCover(isPresented: $showAlbum) {
            AlbumView()
        }
        .sheet(isPresented: $showRemote, onDismiss: {
            // 「モニターにする」を押したときは、シートが閉じ切ってから全画面を出す
            if monitorAfterRemote {
                monitorAfterRemote = false
                showMonitor = true
            }
        }) {
            RemoteSheet(remote: camera.remote) { monitorAfterRemote = true }
        }
        .fullScreenCover(isPresented: $showMonitor) {
            RemoteMonitorView { showMonitor = false }
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
                    SkeletonLayer(feed: camera.poseFeed,
                                  template: camera.template?.isObject == true ? nil : camera.template)
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
                              ignoreBelow: controlsTop - top,
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
        // 倍率ボタンの帯がプレビューの下端にかからないよう、表示されたプレビューの下端を測っておく
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { measuredPreviewBottom = $0 }
        .padding(.top, top)
    }

    /// 美肌・スタイルのパネルで脚長を選んでいる
    private var showsLegRange: Bool { panel == .beauty && beautyItem == .legLength }

    // MARK: - ピント・露出・本体のボタン

    /// アルバム・編集などの画面を開いている間は、音量ボタンをふつうの音量ボタンに戻す
    private var hardwareShutterEnabled: Bool {
        camera.cameraAuthorized && !showAlbum && !showLibrary && !showLicenses && !showRemote && !showMonitor && !showSettings
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
            // 以前はメニュー（Menu）にしていたが、メニューからシートを出すと、iPhone では表示されないまま
            // 画面の操作を一切受け付けなくなった（メニューが閉じるのを 0.35 秒待っても直らなかった）。
            // 設定はシートにし、そこから開く画面は、設定のシートが閉じ切ってから（onDismiss で）出す
            Button {
                showSettings = true
            } label: {
                LabeledIcon(systemImage: camera.muteShutter ? "speaker.slash" : "ellipsis.circle", label: "設定")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
    }

    /// 設定のシートの中身
    private var settingsSheet: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(camera.canMuteShutter ? "ミュート" : "ミュート（画質が落ちます）", isOn: $camera.muteShutter)
                    Toggle("骨格を表示", isOn: $camera.showSkeleton)
                    Toggle("水平器", isOn: $showLevel)
                    Picker(selection: $appearance) {
                        ForEach(Appearance.allCases) { item in
                            Text(item.label).tag(item)
                        }
                    } label: {
                        Label("外観（ダーク・ライト）", systemImage: "circle.lefthalf.filled")
                    }
                    .pickerStyle(.menu)
                }
                Section {
                    Button {
                        Diagnostics.log("リモート: 設定から開く")
                        afterSettings = .remote
                        showSettings = false
                    } label: {
                        Label("リモートモニター", systemImage: "rectangle.on.rectangle")
                    }
                    Button {
                        UIPasteboard.general.string = ([
                            "iOS \(UIDevice.current.systemVersion)",
                        ] + Diagnostics.events).joined(separator: "\n")
                        showSettings = false
                    } label: {
                        Label("動作の記録をコピー", systemImage: "doc.on.doc")
                    }
                    Button {
                        afterSettings = .licenses
                        showSettings = false
                    } label: {
                        Label("ライセンス", systemImage: "doc.text")
                    }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { showSettings = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// 一致度・録画時間・連続撮影の進み具合。
    private var statusRow: some View {
        HStack {
            if let template = camera.template, !template.isObject {
                MatchBadge(feed: camera.poseFeed)
            }
            Spacer()
            RemoteStatusBadge(remote: camera.remote)
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

    /// 倍率ボタンの帯（丸い黒い地を含む）がプレビューの下端にかかる・近すぎるときに動かす量。
    /// 以前は「下端をまたいでいるか」を計算上のプレビューの位置で決めていて、実際の表示と数ポイント食い違うと
    /// 動かさず、帯の黒い地の上側が映像に少しかかって見えていた。
    /// 表示されたプレビューの下端を測り、帯との間を必ず gap 以上空ける。まずプレビューの外（下）へ下げ、
    /// 下のボタンとの間が足りないときだけ映像の上へ上げる
    private func lensBarShift(previewBottom: CGFloat) -> CGFloat {
        guard let frame = lensBarFrame else { return 0 }
        let gap: CGFloat = 6
        guard frame.maxY > previewBottom - gap, frame.minY < previewBottom + gap else { return 0 }
        let down = previewBottom + gap - frame.minY
        if frame.maxY + down <= controlsTop - 2 { return down }
        return previewBottom - gap - frame.maxY
    }

    private func bottomControls(previewBottom: CGFloat, bottomPadding: CGFloat) -> some View {
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

            // パネル・シャッター・撮影モードの範囲。フルの比率ではこの下にもプレビュー（ピント・露出の操作面）があり、
            // ボタンを押したつもりの指を操作面が取ってしまい、撮影モードが切り替わらずにピントの枠が出ていた。
            // この範囲より下の指は、操作面では受け取らない
            VStack(spacing: 10) {
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
                // パネルは映像の上に重なるので、外観の設定によらず暗い表示
                .environment(\.colorScheme, .dark)
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
                                .foregroundStyle(Color.chromeText)
                                .frame(width: 48, height: 48)
                                .background(Circle().fill(Color.chromeText.opacity(0.18)))
                        }
                        .disabled(camera.isRecording || camera.isSequenceRunning)
                    }
                }
                .padding(.horizontal, 30)
                // 映像の上に重なる段は、外観の設定によらず白い文字（9:16 ではシャッターの段が映像に重なる）
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { shutterRowTop = $0 }
                .environment(\.colorScheme, shutterRowTop < previewBottom - 1 ? .dark : colorScheme)

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
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { modeRowTop = $0 }
                .environment(\.colorScheme, modeRowTop < previewBottom - 1 ? .dark : colorScheme)
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { controlsTop = $0 }
        }
        .padding(.top, 14)
        .padding(.bottom, bottomPadding)
        .background(
            // 下端（ホームバーの所）まで暗くする。以前は一番下の帯だけ暗くならず、映像がそのまま見えていた
            // ライトの外観で、下の段が映像に重なっていないときは、明るい帯を暗くしない
            LinearGradient(colors: [.clear, .black.opacity(colorScheme == .dark || shutterRowTop < previewBottom - 1
                                                         || modeRowTop < previewBottom - 1 ? 0.6 : 0)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    /// 写真: オフ → オン → ダイレクト 1 → ダイレクト 2 → オフ。動画・スナップはライトのオン・オフ。
    /// ダイレクト 1 はフラッシュの届いた所（狭い部屋なら壁も）が明るく写る。
    /// ダイレクト 2 は人物の周りの背景を暗く落とし、人だけが浮かび上がる
    private var flashButton: some View {
        let direct = camera.flashOn && camera.directFlash && camera.mode == .photo
        return LabeledIconButton(systemImage: camera.flashOn ? (direct ? "bolt.circle.fill" : "bolt.fill") : "bolt.slash",
                                 label: camera.mode != .photo ? "ライト"
                                     : direct ? (camera.directFlashDark ? "ダイレクト2" : "ダイレクト1") : "フラッシュ",
                                 active: camera.flashOn) {
            if camera.mode != .photo {
                camera.flashOn.toggle()
            } else if !camera.flashOn {
                camera.directFlash = false
                camera.directFlashDark = false
                camera.flashOn = true
            } else if !camera.directFlash {
                camera.directFlash = true
                camera.directFlashDark = false
            } else if !camera.directFlashDark {
                camera.directFlashDark = true
            } else {
                camera.flashOn = false
                camera.directFlash = false
                camera.directFlashDark = false
            }
        }
        .frame(width: 48, height: 48)
    }

    private func next(after value: Int, in values: [Int]) -> Int {
        guard let index = values.firstIndex(of: value) else { return values[0] }
        return values[(index + 1) % values.count]
    }

    // MARK: - リモートモニター

    /// モニター（アプリ・ブラウザ）から届いた操作
    private func handleRemote(_ command: RemoteCommand) {
        switch command {
        case .shutter:
            if !(camera.isRecording && camera.isQuickVideo) { camera.shutterPressed() }
        case .flip:
            if !camera.isRecording && !camera.isSequenceRunning { camera.flipCamera() }
        case .timer:
            camera.timerSeconds = next(after: camera.timerSeconds, in: [0, 3, 6, 10])
        case .burst:
            // 画面の連続撮影ボタンと同じ（写真のときだけ。ダイレクトフラッシュでは 3 枚まで）
            guard camera.mode == .photo, !camera.isSequenceRunning else { return }
            camera.burstCount = next(after: camera.burstCount,
                                     in: camera.flashOn && camera.directFlash ? [1, 3] : [1, 3, 5, 10])
        }
    }

    /// 1 秒に 10 回: モニターへ送る状態と、映像に重ねるガイド（型・骨格・グリッド）の絵を作る
    private func updateRemote() {
        let remote = camera.remote
        guard remote.isStreaming else { return }
        let showsScore = camera.template.map { !$0.isObject } ?? false
        let score = camera.poseFeed.score ?? 0
        remote.updateState(RemoteState(
            score: showsScore ? Int(score) : nil,
            matched: showsScore && score >= CameraManager.matchThreshold,
            countdown: camera.countdown,
            recording: camera.isRecording,
            recordingSeconds: camera.recordingSeconds,
            busy: camera.isCapturing || camera.isSequenceRunning,
            timerSeconds: camera.timerSeconds,
            mode: camera.mode.rawValue,
            canFlip: !camera.isRecording && !camera.isSequenceRunning,
            burstCount: camera.mode == .photo ? camera.burstCount : 1))

        let size = remote.frameSizeBox.value
        let template = camera.template
        guard size.width > 0, template != nil || camera.showSkeleton || gridStyle != .off else {
            remote.setOverlay(nil)
            return
        }
        // この画面と同じ線の太さに見えるよう、画面の幅で描いてからコマの大きさに拡大する
        let width: CGFloat = 390
        let overlay = ZStack {
            if let template {
                PoseTemplateOverlay(template: template,
                                    matched: score >= CameraManager.matchThreshold,
                                    opacity: poseOpacity)
            }
            if camera.showSkeleton {
                SkeletonLayer(feed: camera.poseFeed, template: template?.isObject == true ? nil : template)
            }
            if gridStyle != .off {
                GridOverlay(style: gridStyle)
            }
        }
        .frame(width: width, height: width * size.height / size.width)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: overlay)
        renderer.scale = size.width / width
        renderer.isOpaque = false
        remote.setOverlay(renderer.cgImage)
    }

    private func updateTemplate() {
        camera.template = selectedPose.map { (mirrorPose ? $0.mirrored() : $0).fitted(toFrameAspect: camera.frameAspect) }
    }
}
