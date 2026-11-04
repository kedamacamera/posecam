import SwiftUI

enum ControlPanel: String, CaseIterable, Identifiable {
    case pose = "ポーズ"
    case filter = "フィルター"
    case beauty = "美肌・スタイル"

    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var library = PoseLibrary()
    @Environment(\.scenePhase) private var scenePhase

    @State private var panel: ControlPanel = .pose
    @State private var selectedPose: PoseTemplate?
    @State private var mirrorPose = false
    @State private var showSkeleton = true
    @State private var showLibrary = false
    @State private var zoom: CGFloat = 1
    @State private var zoomAtGestureStart: CGFloat = 1

    private var isMatched: Bool {
        (camera.matchScore ?? 0) >= CameraManager.matchThreshold
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.cameraAuthorized {
                VStack(spacing: 0) {
                    topBar
                    preview
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    bottomControls
                }
            } else {
                PermissionView()
            }

            if let message = camera.statusMessage {
                VStack {
                    Spacer()
                    Text(message)
                        .font(.subheadline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.75)))
                        .foregroundStyle(.white)
                        .padding(.bottom, 260)
                }
                .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onAppear { camera.start() }
        .onChange(of: selectedPose) { updateTemplate() }
        .onChange(of: mirrorPose) { updateTemplate() }
        .onChange(of: scenePhase) {
            if scenePhase != .active { camera.stopRecordingIfNeeded() }
        }
        .sheet(isPresented: $showLibrary) {
            PoseLibraryView(library: library, selection: $selectedPose)
        }
    }

    // MARK: - 上部

    private var topBar: some View {
        HStack(spacing: 26) {
            iconButton(camera.flashOn ? "bolt.fill" : "bolt.slash.fill", active: camera.flashOn) {
                camera.flashOn.toggle()
            }
            iconButton("arrow.left.and.right", active: mirrorPose) {
                mirrorPose.toggle()
            }
            .disabled(selectedPose == nil)
            iconButton("point.3.connected.trianglepath.dotted", active: showSkeleton) {
                showSkeleton.toggle()
            }
            Button {
                camera.autoShutter.toggle()
            } label: {
                Text("AUTO")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .overlay(Capsule().stroke(camera.autoShutter ? Color.yellow : .white, lineWidth: 1.5))
                    .foregroundStyle(camera.autoShutter ? Color.yellow : .white)
            }
            .disabled(selectedPose == nil || camera.mode != .photo)
        }
        .frame(height: 44)
    }

    private func iconButton(_ systemName: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3)
                .foregroundStyle(active ? Color.yellow : .white)
                .frame(width: 36, height: 36)
        }
    }

    // MARK: - プレビュー

    private var preview: some View {
        ZStack {
            CameraPreview(renderer: camera.renderer)
            PoseOverlayView(template: camera.template,
                            detected: showSkeleton ? camera.detectedPose : nil,
                            matched: isMatched)
            VStack {
                HStack {
                    if camera.template != nil, let score = camera.matchScore {
                        ScoreBadge(score: score, matched: isMatched)
                    }
                    Spacer()
                    if camera.isRecording {
                        RecordingBadge(seconds: camera.recordingSeconds)
                    }
                }
                Spacer()
                if zoom > 1.01 {
                    Text(String(format: "%.1fx", zoom))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .foregroundStyle(.white)
                }
            }
            .padding(10)
        }
        .aspectRatio(camera.frameAspect, contentMode: .fit)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    zoom = min(max(zoomAtGestureStart * value.magnification, 1), 8)
                    camera.setZoom(zoom)
                }
                .onEnded { _ in
                    zoomAtGestureStart = zoom
                }
        )
    }

    // MARK: - 下部

    private var bottomControls: some View {
        VStack(spacing: 10) {
            Picker("パネル", selection: $panel) {
                ForEach(ControlPanel.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            Group {
                switch panel {
                case .pose:
                    PoseStrip(library: library, selection: $selectedPose) { showLibrary = true }
                case .filter:
                    FilterStrip(selection: $camera.settings.filter)
                case .beauty:
                    BeautyPanel(settings: $camera.settings)
                }
            }
            .frame(height: 104)

            ModePicker(mode: camera.mode, isLocked: camera.isRecording) { camera.setMode($0) }

            HStack {
                ThumbnailButton(image: camera.lastThumbnail)
                Spacer()
                ShutterButton(mode: camera.mode, isRecording: camera.isRecording, isBusy: camera.isCapturing) {
                    if camera.mode == .photo {
                        camera.capturePhoto()
                    } else {
                        camera.toggleRecording()
                    }
                }
                Spacer()
                Button {
                    camera.flipCamera()
                    zoom = 1
                    zoomAtGestureStart = 1
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
                .disabled(camera.isRecording)
            }
            .padding(.horizontal, 30)
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(Color.black)
    }

    private func updateTemplate() {
        camera.template = selectedPose.map { mirrorPose ? $0.mirrored() : $0 }
    }
}
