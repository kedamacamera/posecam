import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var library = PoseLibrary()
    @Environment(\.scenePhase) private var scenePhase

    @State private var panel: ControlPanel?
    @State private var selectedPose: PoseTemplate?
    @State private var mirrorPose = false
    @State private var poseOpacity = 0.85
    @State private var showLibrary = false
    @State private var showLicenses = false
    @State private var zoomAtGestureStart: CGFloat?
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
                        bottomControls
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
        .onChange(of: mirrorPose) { updateTemplate() }
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
            if let template = camera.template {
                TemplateLayer(feed: camera.poseFeed, template: template, opacity: poseOpacity)
            }
            if camera.showSkeleton {
                SkeletonLayer(feed: camera.poseFeed)
            }
        }
        .frame(width: screen.width, height: height)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    let start = zoomAtGestureStart ?? camera.displayZoom
                    zoomAtGestureStart = start
                    camera.setDisplayZoom(start * value.magnification)
                }
                .onEnded { _ in zoomAtGestureStart = nil }
        )
        .offset(y: top)
    }

    // MARK: - 上部

    private var topBar: some View {
        HStack {
            LabeledIconButton(systemImage: camera.flashOn ? "bolt.fill" : "bolt.slash",
                              label: camera.mode == .photo ? "フラッシュ" : "ライト",
                              active: camera.flashOn) {
                camera.flashOn.toggle()
            }
            Spacer()
            AspectMenu(aspect: $camera.aspect)
                .disabled(camera.isRecording)
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
                camera.burstCount = next(after: camera.burstCount, in: [1, 3, 10])
            }
            .disabled(camera.mode != .photo)
            .opacity(camera.mode == .photo ? 1 : 0.4)
            Spacer()
            Menu {
                Toggle("無音で撮影", isOn: $camera.muteShutter)
                if !camera.canMuteShutter {
                    Text("映像のコマを写真として保存します（約 600〜830 万画素）")
                }
                Picker("連続撮影の間隔", selection: $camera.burstInterval) {
                    Text("1秒ごと").tag(1.0)
                    Text("2秒ごと").tag(2.0)
                }
                Toggle("骨格を表示", isOn: $camera.showSkeleton)
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
            if camera.template != nil {
                MatchBadge(feed: camera.poseFeed)
            }
            Spacer()
            if let progress = camera.burstProgress {
                Badge(text: progress)
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
                    canAutoShutter: camera.mode == .photo,
                    onClear: { selectedPose = nil },
                    onApplyZoom: { camera.setDisplayZoom(CGFloat($0), animated: true) })
    }

    // MARK: - 下部

    private var bottomControls: some View {
        VStack(spacing: 10) {
            if camera.lensOptions.count > 1 {
                LensBar(options: camera.lensOptions, zoom: camera.displayZoom,
                        minZoom: camera.minDisplayZoom, maxZoom: camera.maxDisplayZoom,
                        activeLens: camera.activeLensName,
                        onSelect: { camera.setDisplayZoom($0, animated: true) },
                        onZoom: { camera.setDisplayZoom($0) })
            }

            if let panel {
                Group {
                    switch panel {
                    case .pose:
                        PoseStrip(library: library, selection: $selectedPose,
                                  frameAspect: camera.frameAspect) { showLibrary = true }
                    case .filter:
                        FilterStrip(selection: $camera.settings.filter)
                    case .beauty:
                        BeautyPanel(settings: $camera.settings, showOriginal: $camera.showOriginal)
                    }
                }
                // 美肌・スタイルはスライダーが多いので少し高くする（はみ出した分はスクロール）
                .frame(height: panel == .beauty ? 120 : 104)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.6)))
                .padding(.horizontal, 8)
                // パネルは下へフリックしても閉じられる（横のスクロールとは向きで区別する）
                .simultaneousGesture(
                    DragGesture(minimumDistance: 20)
                        .onEnded { value in
                            let down = value.translation.height
                            if down > 40, down > abs(value.translation.width) * 1.2 {
                                withAnimation(.easeOut(duration: 0.18)) { self.panel = nil }
                            }
                        }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            PanelChips(panel: $panel)

            HStack {
                Color.clear.frame(width: 48, height: 48)
                Spacer()
                ShutterButton(mode: camera.mode,
                              isRecording: camera.isRecording,
                              isBusy: camera.isCapturing || camera.isSequenceRunning,
                              progress: Double(camera.recordingSeconds) / Double(CameraManager.snapMaxSeconds)) {
                    camera.shutterPressed()
                }
                Spacer()
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
            .padding(.horizontal, 30)

            // 一番下はアルバムと撮影モード。画面を閉じるときの上スワイプでシャッターに触れないよう、
            // シャッターは一段上に置く
            ZStack {
                ModePicker(mode: camera.mode, isLocked: camera.isRecording || camera.isSequenceRunning) {
                    camera.setMode($0)
                }
                HStack {
                    ThumbnailButton(image: camera.lastThumbnail)
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

    private func next(after value: Int, in values: [Int]) -> Int {
        guard let index = values.firstIndex(of: value) else { return values[0] }
        return values[(index + 1) % values.count]
    }

    private func updateTemplate() {
        camera.template = selectedPose.map { mirrorPose ? $0.mirrored() : $0 }
    }
}
