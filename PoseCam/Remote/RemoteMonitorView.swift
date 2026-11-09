import CoreImage.CIFilterBuiltins
import MultipeerConnectivity
import SwiftUI

/// モニター側（A: アプリ同士）。近くの撮る側から見つけてもらい、届いた映像を表示して、シャッターなどを送り返す。
final class RemoteMonitorClient: NSObject, ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var state: RemoteState?
    /// つないでいる撮る側の名前
    @Published private(set) var cameraName: String?
    /// このモニターを開いている間に撮った写真（新しいものが先頭。アルバムで見る）
    @Published private(set) var photos: [MonitorPhoto] = []
    /// 撮る側が「撮影後にプレビューを表示」にしているとき、いま撮った写真
    @Published var incomingPreview: MonitorPhoto?

    /// 撮る側とのつながり。誘われるたびに作り直す（失敗した後の古い状態を残さない）。メインスレッドで変える
    private var session = RemoteHost.makeSession()
    private var advertiser: MCNearbyServiceAdvertiser?
    private let decodeQueue = DispatchQueue(label: "posecam.monitor", qos: .userInitiated)

    override init() {
        super.init()
        session.delegate = self
    }

    func start() {
        guard advertiser == nil else { return }
        let advertiser = MCNearbyServiceAdvertiser(peer: RemoteWire.peerID, discoveryInfo: nil,
                                                   serviceType: RemoteWire.serviceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        session.disconnect()
    }

    func send(_ command: RemoteCommand) {
        guard !session.connectedPeers.isEmpty, let json = try? JSONEncoder().encode(command) else { return }
        try? session.send(RemoteWire.pack(RemoteWire.command, json), toPeers: session.connectedPeers, with: .reliable)
    }

    private func sendAck(to peer: MCPeerID) {
        try? session.send(Data([RemoteWire.ack]), toPeers: [peer], with: .reliable)
    }
}

extension RemoteMonitorClient: MCNearbyServiceAdvertiserDelegate, MCSessionDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // 「モニターになる」を開いている間だけ届く。撮る側を 1 台だけ受け入れる。
        // つながっていなければ、新しいつながりを作ってから受け入れる
        DispatchQueue.main.async {
            guard self.advertiser != nil, self.session.connectedPeers.isEmpty else {
                invitationHandler(false, nil)
                return
            }
            let old = self.session
            old.delegate = nil
            old.disconnect()
            let fresh = RemoteHost.makeSession()
            fresh.delegate = self
            self.session = fresh
            Diagnostics.log("モニター: 誘いを受けた")
            invitationHandler(true, fresh)
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Diagnostics.log("モニター: 開始できません \(error.localizedDescription)")
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                self.cameraName = peerID.displayName
            case .notConnected:
                if session.connectedPeers.isEmpty {
                    self.cameraName = nil
                    self.image = nil
                    self.state = nil
                }
            default:
                break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let kind = data.first else { return }
        switch kind {
        case RemoteWire.frame:
            decodeQueue.async {
                // 表示できる形にしてから出す（メインスレッドで JPEG を開くと、ボタンの反応が遅れる）
                let image = UIImage(data: data.dropFirst())?.preparingForDisplay()
                DispatchQueue.main.async {
                    if let image { self.image = image }
                    // 表示したら次のコマを送ってもらう
                    self.sendAck(to: peerID)
                }
            }
        case RemoteWire.state:
            if let state = try? JSONDecoder().decode(RemoteState.self, from: data.dropFirst()) {
                DispatchQueue.main.async { self.state = state }
            }
        case RemoteWire.photo:
            let body = data.dropFirst()
            guard let flag = body.first else { return }
            decodeQueue.async {
                guard let image = UIImage(data: body.dropFirst())?.preparingForDisplay() else { return }
                let photo = MonitorPhoto(image: image)
                DispatchQueue.main.async {
                    // 多くなりすぎないよう、新しい 60 枚まで
                    self.photos = Array(([photo] + self.photos).prefix(60))
                    if flag == 1 { self.incomingPreview = photo }
                }
            }
        default:
            break
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
                 with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
                 at localURL: URL?, withError error: Error?) {}
}

/// モニターで受け取った写真
struct MonitorPhoto: Identifiable, Equatable {
    let id = UUID()
    let image: UIImage

    static func == (a: MonitorPhoto, b: MonitorPhoto) -> Bool { a.id == b.id }
}

/// この iPhone をモニターにする画面（全画面）
struct RemoteMonitorView: View {
    let onClose: () -> Void
    @StateObject private var client = RemoteMonitorClient()
    /// 映像を左右反転して見る（背面カメラで自分を撮るとき、鏡のように見るため）。初めはしない。覚えておく
    @AppStorage("monitorMirror") private var mirror = false
    /// 撮る側が撮影後のプレビューをオンにしているとき、このモニターでも表示する。覚えておく
    @AppStorage("monitorShowsPreview") private var showsPreview = true
    @State private var showSample = true
    @State private var showAlbum = false
    @State private var shownPreview: MonitorPhoto?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = client.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(x: mirror ? -1 : 1, y: 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 14) {
                    ProgressView().tint(.white)
                    Text(client.cameraName == nil ? "撮る側を待っています" : "映像を待っています")
                        .font(.headline)
                    Text("撮る側の iPhone・iPad で「設定」→「リモートモニター」を開き、\n「\(RemoteWire.peerID.displayName)」を選んでください。\n"
                         + "Wi-Fi がなくても、2 台が近く（5 m くらいまで）にあればつながります。")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding(30)
            }

            if let countdown = client.state?.countdown {
                Text("\(countdown)")
                    .font(.system(size: 120, weight: .bold, design: .rounded))
                    .shadow(color: .black.opacity(0.6), radius: 8)
            }

            VStack {
                HStack(spacing: 8) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.black.opacity(0.5)))
                    }
                    if let score = client.state?.score {
                        Badge(text: "一致度 \(score)%",
                              color: client.state?.matched == true ? .green : .black.opacity(0.55))
                    }
                    if client.state?.recording == true, let seconds = client.state?.recordingSeconds {
                        Badge(text: String(format: "%02d:%02d", seconds / 60, seconds % 60), dot: .red)
                    }
                    Spacer()
                    if let name = client.cameraName {
                        Text(name).font(.caption).foregroundStyle(.secondary)
                    }
                    // 左右反転（押すたびに切り替え。覚えておく）
                    Button {
                        mirror.toggle()
                    } label: {
                        Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(mirror ? Color.yellow : Color.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.black.opacity(0.5)))
                    }
                    .accessibilityLabel(mirror ? "左右反転をやめる" : "左右反転する")
                    // 撮った写真をすぐ大きく見せるか（撮る側で撮影後のプレビューをオンにしているとき）
                    Button {
                        showsPreview.toggle()
                    } label: {
                        Image(systemName: showsPreview ? "eye" : "eye.slash")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.black.opacity(0.5)))
                    }
                    .accessibilityLabel(showsPreview ? "撮った写真の表示をやめる" : "撮った写真を表示する")
                }
                .padding(.horizontal, 12)
                // 撮る側で選んでいるポーズの見本写真（左上。タップで隠す・出す）
                if let sample = client.state?.sample {
                    PoseSampleCard(imageName: sample, mirrored: client.state?.sampleMirrored ?? false,
                                   shown: $showSample)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                }
                Spacer()
                if client.cameraName != nil {
                    controls
                }
            }
            .padding(.vertical, 12)
        }
        .overlay {
            if let photo = shownPreview {
                CapturePreviewOverlay(image: photo.image) {
                    withAnimation(.easeIn(duration: 0.15)) { shownPreview = nil }
                }
            }
        }
        // 撮る側が撮影後のプレビューをオンにしていれば、撮れた写真を 2 秒大きく見せる
        .onChange(of: client.incomingPreview) {
            guard let photo = client.incomingPreview else { return }
            client.incomingPreview = nil
            guard showsPreview else { return }
            withAnimation(.easeOut(duration: 0.15)) { shownPreview = photo }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if shownPreview == photo { withAnimation(.easeIn(duration: 0.2)) { shownPreview = nil } }
            }
        }
        .sheet(isPresented: $showAlbum) {
            MonitorAlbumView(photos: client.photos)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .onAppear {
            client.start()
            // 見ている間は画面を消さない
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            client.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private var controls: some View {
        let state = client.state ?? RemoteState()
        let mode = CaptureMode(rawValue: state.mode) ?? .photo
        return HStack {
            // このモニターを開いてから撮った写真
            Button {
                showAlbum = true
            } label: {
                Group {
                    if let last = client.photos.first {
                        Image(uiImage: last.image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo.on.rectangle").font(.system(size: 18))
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.6), lineWidth: 1))
            }
            .accessibilityLabel("撮った写真を見る")
            Spacer()
            LabeledIconButton(systemImage: "timer",
                              label: state.timerSeconds == 0 ? "タイマー" : "\(state.timerSeconds)秒",
                              active: state.timerSeconds > 0) { client.send(.timer) }
                .frame(width: 64)
            Spacer()
            ShutterButton(mode: mode, isRecording: state.recording, isBusy: state.busy, progress: 0,
                          action: {
                              UIImpactFeedbackGenerator(style: .light).impactOccurred()
                              client.send(.shutter)
                          })
            Spacer()
            Button {
                client.send(.flip)
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.title2)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Color.white.opacity(0.18)))
            }
            .disabled(!state.canFlip)
            .frame(width: 64)
            // 左の写真のボタンと同じ幅の空きを置いて、シャッターを真ん中にする
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}

/// 撮る側の「リモートモニター」の画面。設定の画面の中で横に送って開く（NavigationStack の中に置く）。
/// 以前は設定（メニュー・シート）を閉じてから別のシートで出していたが、iPhone（iOS 27.2）では
/// 閉じた直後に出したシートが見えないまま、画面の操作を一切受け付けなくなった
struct RemoteSheet: View {
    @ObservedObject var remote: RemoteHost
    /// 「この iPhone をモニターにする」
    let onBecomeMonitor: () -> Void

    /// 画面の文に使う、この端末の呼び名（iPad では「この iPad を〜」と出す）
    static let deviceWord = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"

    var body: some View {
            List {
                Section {
                    if let name = remote.connectedMonitor {
                        HStack {
                            Label("\(name) につながっています", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Spacer()
                            Button("切る", role: .destructive) { remote.disconnectMonitor() }
                        }
                    }
                    ForEach(remote.nearbyMonitors, id: \.self) { peer in
                        Button {
                            remote.invite(peer)
                        } label: {
                            HStack {
                                Image(systemName: "iphone")
                                Text(peer.displayName)
                                Spacer()
                                if remote.invitingMonitor == peer {
                                    ProgressView()
                                    Text("つないでいます").font(.caption).foregroundStyle(.secondary)
                                } else if remote.connectedMonitor == peer.displayName {
                                    Text("表示中").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("つなぐ").font(.caption.weight(.semibold))
                                }
                            }
                        }
                    }
                    if remote.nearbyMonitors.isEmpty && remote.connectedMonitor == nil {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("近くのモニターを探しています")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("アプリのモニターにつなぐ（iPhone・iPad）")
                        // 見出しは大文字にしない（iPhone が IPHONE になる）
                        .textCase(nil)
                } footer: {
                    Text("もう一台の iPhone・iPad でポーズカメラを開き、「設定」→「リモートモニター」→「この iPhone（iPad）をモニターにする」を押すと、"
                         + "ここに出ます。Wi-Fi がなくても、近く（5 m くらいまで）にあればつながります。"
                         + "シャッターを押すと、この \(Self.deviceWord) のカメラで撮ります。")
                }

                Section {
                    Toggle("ブラウザのモニターを開く", isOn: Binding(
                        get: { remote.webURL != nil },
                        set: { $0 ? remote.startWeb() : remote.stopWeb() }))
                    if let url = remote.webURL {
                        VStack(spacing: 10) {
                            if let qr = Self.qrCode(url.absoluteString) {
                                Image(uiImage: qr)
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: 200, height: 200)
                            }
                            Text(url.absoluteString)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                            Text(remote.webViewers > 0 ? "\(remote.webViewers) 台が見ています" : "まだ誰も見ていません")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    if let error = remote.webError {
                        Text(error).foregroundStyle(.orange)
                    }
                } header: {
                    Text("ブラウザで見る（Android・タブレットなど）")
                        .textCase(nil)
                } footer: {
                    Text("もう一台を同じ Wi-Fi か、この iPhone のテザリング（インターネット共有）につなぎ、カメラで QR コードを読みます。"
                         + "アプリを入れなくても使えます。QR コードの URL を知っている人だけが見られます。")
                }

                Section {
                    Button {
                        // 全画面は、設定の画面の上に重ねて出す（閉じてから出すと iPhone で固まる）
                        onBecomeMonitor()
                    } label: {
                        Label("この \(Self.deviceWord) をモニターにする", systemImage: "rectangle.on.rectangle")
                    }
                } footer: {
                    Text("撮る側の映像を映し、ここからシャッターを押せます。モニターにしている間、この \(Self.deviceWord) のカメラは止まります。")
                }
            }
            .navigationTitle("リモートモニター")
            .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Diagnostics.log("リモート: 画面が開いた")
            remote.startBrowsing()
        }
        .onDisappear { remote.stopBrowsing() }
    }

    private static func qrCode(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// 撮る側の画面に出す「モニター中」の印
struct RemoteStatusBadge: View {
    @ObservedObject var remote: RemoteHost

    var body: some View {
        if remote.isStreaming {
            let count = (remote.connectedMonitor != nil ? 1 : 0) + remote.webViewers
            Badge(text: count > 1 ? "モニター \(count) 台" : "モニター中", color: Color.blue.opacity(0.8))
        }
    }
}
