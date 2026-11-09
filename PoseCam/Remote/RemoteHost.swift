import CoreImage
import Foundation
import MultipeerConnectivity
import Network
import UIKit
import WatchConnectivity

// リモートモニター: もう一台のスマホに撮影画面（映像＋ポーズのガイド）を映し、シャッターなどを押せるようにする。
//
// つなぎ方は 2 通り:
// - A: 両方の iPhone に PoseCam を入れ、Multipeer Connectivity で直接つなぐ（Wi-Fi がなくてもつながる）
// - B: 撮る側の iPhone が小さな Web サーバーになり、もう一台はブラウザで見る（Android でも使える。同じ Wi-Fi かテザリング）
// - C: ペアの Apple Watch の「ポーズカメラ」で見る（WatchConnectivity。時計の画面に合わせて小さくしたコマを送る）
//
// どちらも、撮る側が映像にガイドを重ねた JPEG を作って送る。受け取った側が 1 枚表示し終えてから次を送るので、
// 回線が遅くてもコマがたまって遅れていくことはない（古いコマは捨てて、いつも最新のコマを送る）。

/// モニターから撮る側への操作
enum RemoteCommand: String, Codable {
    case shutter
    case flip
    case timer
    /// 連続撮影の枚数を切り替える（Apple Watch から）
    case burst
}

/// モニターでタップした所（映像の中の位置 0...1、左上原点）。lock なら固定（AE/AF ロック）
struct RemoteFocus: Codable {
    var x: Double
    var y: Double
    var lock: Bool
}

/// 撮る側からモニターへ送る状態（一致度・カウントダウンなど）
struct RemoteState: Codable, Equatable {
    /// 一致度（ポーズの型を選んでいないときは nil）
    var score: Int?
    var matched = false
    var countdown: Int?
    var recording = false
    var recordingSeconds = 0
    var busy = false
    var timerSeconds = 0
    /// 撮影モード（CaptureMode の rawValue）
    var mode = CaptureMode.photo.rawValue
    var canFlip = true
    /// 連続撮影の枚数（1 なら 1 枚ずつ）
    var burstCount = 1
    /// 選んでいるポーズの見本写真（アプリに入っている見本の名前。モニター側も同じ写真を持っている）
    var sample: String?
    /// 見本写真を左右反転して見せているか
    var sampleMirrored = false
}

enum RemoteWire {
    /// Bonjour のサービス名（Info.plist の NSBonjourServices と合わせる）
    static let serviceType = "posecam-mon"
    // Multipeer で送るデータの先頭 1 バイト
    static let frame: UInt8 = 1
    static let state: UInt8 = 2
    static let command: UInt8 = 3
    /// モニターが 1 コマ表示し終えた合図（次のコマを送ってよい）
    static let ack: UInt8 = 4
    /// 撮った写真（先頭 1 バイトが 1 なら、モニターでもすぐ大きく見せる。続きは JPEG）
    static let photo: UInt8 = 5
    /// モニターでタップした所にピント・露出を合わせる（RemoteFocus の JSON）
    static let focus: UInt8 = 6

    static func pack(_ kind: UInt8, _ body: Data) -> Data {
        var data = Data([kind])
        data.append(body)
        return data
    }

    /// 相手の画面に出る名前（iOS 16 からは端末名ではなく「iPhone」になる）
    static let peerID = MCPeerID(displayName: String(UIDevice.current.name.prefix(40)))
}

/// 撮る側。映像を JPEG にしてモニター（アプリ・ブラウザ）へ送り、モニターからの操作を受け取る。
/// @Published はメインスレッドでだけ変える。映像は映像のキューから offer で渡す。
final class RemoteHost: NSObject, ObservableObject {
    /// 近くで「モニターになる」を開いている iPhone
    @Published private(set) var nearbyMonitors: [MCPeerID] = []
    /// つないでいるモニター（アプリ）の名前
    @Published private(set) var connectedMonitor: String?
    /// つなごうとしているモニター
    @Published private(set) var invitingMonitor: MCPeerID?
    /// ブラウザで見るときの URL（サーバーを開いていないときは nil）
    @Published private(set) var webURL: URL?
    /// ブラウザで見ている数
    @Published private(set) var webViewers = 0
    @Published private(set) var webError: String?

    /// モニターからの操作（メインスレッドで呼ぶ）
    var onCommand: ((RemoteCommand) -> Void)?
    /// モニターでタップしてピントを合わせる（メインスレッドで呼ぶ）
    var onFocus: ((RemoteFocus) -> Void)?

    /// Apple Watch で見ているか
    @Published private(set) var watchViewing = false

    /// 送っているか（どれかのモニターが見ている）。メインスレッド用
    var isStreaming: Bool { connectedMonitor != nil || webViewers > 0 || watchViewing }

    /// 映像のキューから読む: 送るか
    private let streamingBox = Locked(false)
    /// ガイド（型・骨格・グリッド）を描いた透明な画像。メインスレッドで作り、JPEG を作るときに重ねる
    private let overlayBox = Locked<CGImage?>(nil)
    /// いま送っているコマの大きさ（ピクセル）。ガイドをこの大きさで描く
    let frameSizeBox = Locked<CGSize>(.zero)
    private let encodeBusy = Locked(false)
    /// 映像のキューから読む: Apple Watch 用の小さいコマも作るか
    private let watchBox = Locked(false)
    /// 映像のキュー専用
    private var lastOffer: CFTimeInterval = 0

    private let queue = DispatchQueue(label: "posecam.remote", qos: .userInitiated)
    private let encodeQueue = DispatchQueue(label: "posecam.remote.encode", qos: .userInitiated)

    // queue 専用
    private var latestFrame: (id: Int, jpeg: Data)?
    private var peerSentID = 0
    private var peerHungry = false
    private var webStreams: [ObjectIdentifier: WebStream] = [:]
    private var latestStateJSON = Data("{}".utf8)
    private var token = ""
    /// ブラウザのモニターで見る、撮った写真（新しいものが先頭。確認用に縮めた JPEG。60 枚まで）
    private var webPhotos: [(id: Int, jpeg: Data)] = []
    private var webPhotoCounter = 0
    /// 撮影後のプレビューで見せる写真（撮る側でプレビューがオンのときに撮ったもの）
    private var webPreviewID: Int?
    /// ブラウザで見ている数（どのスレッドからも読む）
    private let webViewersBox = Locked(0)
    // Apple Watch（queue 専用）
    private var latestWatchFrame: (id: Int, jpeg: Data)?
    private var watchSentID = 0
    private var watchHungry = false
    private var watchLastSeen: CFTimeInterval = 0

    /// モニター（アプリ）とのつながり。つなぐたびに作り直す（以前は 1 つを使い回していて、一度失敗すると
    /// 古い状態が残り、「1 回目は失敗して 2 回目でつながる」ことがあった）。queue からも読むので箱に入れる
    private let sessionBox = Locked(RemoteHost.makeSession())
    private var session: MCSession { sessionBox.value }
    /// いまの相手に何回つなごうとしたか（メインスレッド用）
    private var inviteAttempts = 0

    static func makeSession() -> MCSession {
        MCSession(peer: RemoteWire.peerID, securityIdentity: nil, encryptionPreference: .required)
    }
    private var browser: MCNearbyServiceBrowser?
    private var listener: NWListener?
    private var lastState: RemoteState?

    override init() {
        super.init()
        session.delegate = self
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    // MARK: - 映像

    /// 映像のキューから毎コマ呼ぶ。見ているモニターがあるときだけ、1 秒に 15 コマまで JPEG にする
    func offer(_ image: CIImage, context: CIContext) {
        guard streamingBox.value else { return }
        let now = CACurrentMediaTime()
        guard now - lastOffer >= 1.0 / 15, !encodeBusy.value else { return }
        lastOffer = now
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return }
        let scale = min(1, 720 / max(extent.width, extent.height))
        let size = CGSize(width: (extent.width * scale).rounded(), height: (extent.height * scale).rounded())
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // GPU で小さく描くところまでは映像のキューで行う（元のコマの入れ物を長く持たないように）
        guard let cgImage = context.createCGImage(scaled, from: CGRect(origin: .zero, size: size),
                                                  format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        else { return }
        frameSizeBox.value = size
        encodeBusy.value = true
        let overlay = overlayBox.value
        let forWatch = watchBox.value
        encodeQueue.async { [weak self] in
            guard let self else { return }
            defer { self.encodeBusy.value = false }
            guard let composed = Self.compose(cgImage, overlay: overlay),
                  let jpeg = UIImage(cgImage: composed).jpegData(compressionQuality: 0.55) else { return }
            // 時計へは、時計の画面に合う大きさ（長い辺 320）にして送る（WatchConnectivity は大きいデータが遅い）
            let watchJPEG = forWatch ? Self.small(composed, maxSide: 320).flatMap {
                UIImage(cgImage: $0).jpegData(compressionQuality: 0.45)
            } : nil
            self.queue.async {
                self.publish(jpeg)
                if let watchJPEG { self.publishWatch(watchJPEG) }
            }
        }
    }

    private static func small(_ image: CGImage, maxSide: CGFloat) -> CGImage? {
        let scale = min(1, maxSide / CGFloat(max(image.width, image.height)))
        let width = Int((CGFloat(image.width) * scale).rounded())
        let height = Int((CGFloat(image.height) * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func compose(_ image: CGImage, overlay: CGImage?) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: rect)
        if let overlay { context.draw(overlay, in: rect) }
        return context.makeImage()
    }

    /// メインスレッドで作ったガイドの画像（nil ならガイドなし）
    func setOverlay(_ image: CGImage?) {
        overlayBox.value = image
    }

    /// 状態が変わったときだけ送る（メインスレッド）
    func updateState(_ state: RemoteState) {
        guard state != lastState else { return }
        lastState = state
        guard let json = try? JSONEncoder().encode(state) else { return }
        queue.async {
            self.latestStateJSON = json
            self.sendToPeer(RemoteWire.pack(RemoteWire.state, json), reliable: true)
            self.sendStateToWatch()
        }
    }

    private func publish(_ jpeg: Data) {
        let id = (latestFrame?.id ?? 0) + 1
        latestFrame = (id, jpeg)
        if peerHungry { sendFrameToPeer() }
        for stream in webStreams.values where stream.hungry { stream.send(latestFrame!) }
    }

    private func updateStreaming() {
        DispatchQueue.main.async {
            let on = self.isStreaming
            self.streamingBox.value = on
            self.watchBox.value = self.watchViewing
            if !on { self.overlayBox.value = nil }
            // 送っている間は撮る側の画面を消さない（消えるとアプリが止まり、モニターに映らなくなる）
            UIApplication.shared.isIdleTimerDisabled = on
        }
    }

    // MARK: - A: アプリのモニター（Multipeer Connectivity）

    /// 近くのモニターを探す（リモートモニターの画面を開いている間）
    func startBrowsing() {
        guard browser == nil else { return }
        Diagnostics.log("リモート: 探し始める")
        let browser = MCNearbyServiceBrowser(peer: RemoteWire.peerID, serviceType: RemoteWire.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
        Diagnostics.log("リモート: 探し始めた")
    }

    func stopBrowsing() {
        browser?.stopBrowsingForPeers()
        browser = nil
        nearbyMonitors = []
    }

    func invite(_ peer: MCPeerID) {
        inviteAttempts = 0
        attemptInvite(peer)
    }

    /// 新しいつながりを作って誘う。1 台だけつなぐ（つないでいるモニターは切ってから）
    private func attemptInvite(_ peer: MCPeerID) {
        inviteAttempts += 1
        let old = session
        old.delegate = nil
        old.disconnect()
        let fresh = Self.makeSession()
        fresh.delegate = self
        sessionBox.value = fresh
        connectedMonitor = nil
        invitingMonitor = peer
        Diagnostics.log("リモート: つなぐ（\(inviteAttempts) 回目）")
        browser?.invitePeer(peer, to: fresh, withContext: nil, timeout: 10)
    }

    /// アプリのモニターがつながっているか（どのスレッドから読んでもよい）
    var hasAppMonitor: Bool { !session.connectedPeers.isEmpty }

    /// 撮った写真を見せる相手（アプリのモニターかブラウザのモニター）がいるか（どのスレッドから読んでもよい）
    var wantsPhotos: Bool { hasAppMonitor || webViewersBox.value > 0 }

    /// 撮った写真をモニターへ送る（モニターのアルバムに入る）。どのスレッドから呼んでもよい
    func sendPhoto(_ jpeg: Data, showPreview: Bool) {
        var body = Data([showPreview ? 1 : 0])
        body.append(jpeg)
        queue.async {
            self.sendToPeer(RemoteWire.pack(RemoteWire.photo, body), reliable: true)
            // ブラウザのモニター: 写真を取っておき、状態（/state）で番号を知らせる
            guard !self.token.isEmpty else { return }
            self.webPhotoCounter += 1
            self.webPhotos.insert((self.webPhotoCounter, jpeg), at: 0)
            if self.webPhotos.count > 60 { self.webPhotos.removeLast(self.webPhotos.count - 60) }
            if showPreview { self.webPreviewID = self.webPhotoCounter }
        }
    }

    func disconnectMonitor() {
        session.disconnect()
        connectedMonitor = nil
        invitingMonitor = nil
        updateStreaming()
    }

    /// queue で呼ぶ
    private func sendToPeer(_ data: Data, reliable: Bool) {
        let peers = session.connectedPeers
        guard !peers.isEmpty else { return }
        try? session.send(data, toPeers: peers, with: reliable ? .reliable : .unreliable)
    }

    /// queue で呼ぶ。まだ送っていない新しいコマがあれば送り、モニターの合図を待つ
    private func sendFrameToPeer() {
        guard let frame = latestFrame, frame.id != peerSentID, !session.connectedPeers.isEmpty else {
            peerHungry = true
            return
        }
        peerHungry = false
        peerSentID = frame.id
        sendToPeer(RemoteWire.pack(RemoteWire.frame, frame.jpeg), reliable: true)
        // 合図が届かないまま止まらないよう、1 秒で次を送ってよいことにする
        let sent = frame.id
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.peerSentID == sent, !self.peerHungry else { return }
            self.sendFrameToPeer()
        }
    }

    // MARK: - B: ブラウザのモニター（Web サーバー）

    func startWeb() {
        guard listener == nil else { return }
        webError = nil
        guard let address = Self.localIPv4() else {
            webError = "Wi-Fi かテザリング（インターネット共有）につないでください"
            return
        }
        let newToken = String(UUID().uuidString.prefix(8)).lowercased()
        do {
            let listener = try Self.makeListener()
            listener.newConnectionHandler = { [weak self] connection in
                self?.queue.async { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        let port = listener?.port?.rawValue ?? 0
                        self.webURL = URL(string: "http://\(address):\(port)/?k=\(newToken)")
                    case .failed(let error):
                        self.webError = "開けませんでした（\(error.localizedDescription)）"
                        self.stopWeb()
                    default:
                        break
                    }
                }
            }
            queue.async { self.token = newToken }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            webError = "開けませんでした（\(error.localizedDescription)）"
        }
    }

    func stopWeb() {
        listener?.cancel()
        listener = nil
        webURL = nil
        queue.async {
            for stream in self.webStreams.values { stream.close() }
            self.webStreams = [:]
            self.webPhotos = []
            self.webPreviewID = nil
            self.token = ""
            self.webViewersBox.value = 0
            DispatchQueue.main.async {
                self.webViewers = 0
                self.updateStreaming()
            }
        }
    }

    private static func makeListener() throws -> NWListener {
        // 覚えやすい 8080 を使い、使えなければ空いている番号にする
        if let listener = try? NWListener(using: .tcp, on: 8080) { return listener }
        return try NWListener(using: .tcp)
    }

    /// Wi-Fi（en0）か、この iPhone のテザリング（bridge）の IPv4 アドレス
    static func localIPv4() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var found: [String: String] = [:]
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name == "en0" || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found[name] = String(cString: host)
            }
        }
        return found["en0"] ?? found.first(where: { $0.key.hasPrefix("bridge") })?.value
    }

    /// queue で呼ぶ
    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.handle(head, connection)
            } else if done || error != nil || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.readRequest(connection, buffer: buffer)
            }
        }
    }

    private func handle(_ head: String, _ connection: NWConnection) {
        let requestLine = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, let components = URLComponents(string: String(parts[1])) else {
            respond(connection, status: "400 Bad Request", type: "text/plain", body: Data("bad request".utf8))
            return
        }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        // QR コードの URL に入れた合言葉がないと見られない（同じ Wi-Fi の他人に見られないように）
        guard query["k"] == token, !token.isEmpty else {
            respond(connection, status: "403 Forbidden", type: "text/plain; charset=utf-8",
                    body: Data("撮る側の iPhone に出ている QR コードから開いてください".utf8))
            return
        }
        switch components.path {
        case "/":
            respond(connection, status: "200 OK", type: "text/html; charset=utf-8", body: Data(WebMonitorPage.html.utf8))
        case "/state":
            // アプリのモニターと同じ状態に、撮る側の名前と撮った写真の番号を足す
            var dict = (try? JSONSerialization.jsonObject(with: latestStateJSON)) as? [String: Any] ?? [:]
            dict["camera"] = RemoteWire.peerID.displayName
            dict["photos"] = webPhotos.map(\.id)
            dict["preview"] = webPreviewID.map { $0 as Any } ?? NSNull()
            let body = (try? JSONSerialization.data(withJSONObject: dict)) ?? latestStateJSON
            respond(connection, status: "200 OK", type: "application/json", body: body)
        case "/photo":
            if let id = query["id"].flatMap(Int.init), let photo = webPhotos.first(where: { $0.id == id }) {
                respond(connection, status: "200 OK", type: "image/jpeg", body: photo.jpeg)
            } else {
                respond(connection, status: "404 Not Found", type: "text/plain", body: Data("not found".utf8))
            }
        case "/sample":
            // 見本写真（アプリに入っている見本の名前だけ。英数字と _ - のみ受け付ける）
            let name = query["n"] ?? ""
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
            if !name.isEmpty, name.unicodeScalars.allSatisfy(allowed.contains),
               let jpeg = PoseImageCache.sample(named: name)?.jpegData(compressionQuality: 0.8) {
                respond(connection, status: "200 OK", type: "image/jpeg", body: jpeg)
            } else {
                respond(connection, status: "404 Not Found", type: "text/plain", body: Data("not found".utf8))
            }
        case "/focus":
            // 映像の中の位置（0...1、左上原点）にピント・露出を合わせる。lock=1 なら AE/AF ロック
            if let x = query["x"].flatMap(Double.init), let y = query["y"].flatMap(Double.init),
               (0...1).contains(x), (0...1).contains(y) {
                let focus = RemoteFocus(x: x, y: y, lock: query["lock"] == "1")
                DispatchQueue.main.async { self.onFocus?(focus) }
            }
            respond(connection, status: "200 OK", type: "application/json", body: Data("{}".utf8))
        case "/cmd":
            if let command = query["c"].flatMap(RemoteCommand.init(rawValue:)) {
                DispatchQueue.main.async { self.onCommand?(command) }
            }
            respond(connection, status: "200 OK", type: "application/json", body: Data("{}".utf8))
        case "/stream":
            startStream(connection)
        default:
            respond(connection, status: "404 Not Found", type: "text/plain", body: Data("not found".utf8))
        }
    }

    private func respond(_ connection: NWConnection, status: String, type: String, body: Data) {
        var data = Data(("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n").utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// 映像は MJPEG（multipart/x-mixed-replace）で送り続ける。ブラウザの <img> がそのまま動画のように表示する
    private func startStream(_ connection: NWConnection) {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        let stream = WebStream(connection: connection)
        let key = ObjectIdentifier(stream)
        stream.onClose = { [weak self] in
            guard let self else { return }
            self.webStreams[key] = nil
            let count = self.webStreams.count
            self.webViewersBox.value = count
            DispatchQueue.main.async {
                self.webViewers = count
                self.updateStreaming()
            }
        }
        stream.onHungry = { [weak self, weak stream] in
            guard let self, let stream, let frame = self.latestFrame else { return }
            stream.send(frame)
        }
        webStreams[key] = stream
        let count = webStreams.count
        webViewersBox.value = count
        DispatchQueue.main.async {
            self.webViewers = count
            self.updateStreaming()
        }
        connection.stateUpdateHandler = { [weak stream] state in
            switch state {
            case .failed, .cancelled: stream?.close()
            default: break
            }
        }
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak stream] error in
            if error != nil { stream?.close() } else { stream?.ready() }
        })
    }
}

/// ブラウザ 1 つぶんの映像の送り先（RemoteHost の queue でだけ使う）
private final class WebStream {
    let connection: NWConnection
    var onClose: (() -> Void)?
    var onHungry: (() -> Void)?
    private(set) var hungry = false
    private var sentID = 0
    private var closed = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func ready() {
        hungry = true
        onHungry?()
    }

    func send(_ frame: (id: Int, jpeg: Data)) {
        guard hungry, !closed, frame.id != sentID else { return }
        hungry = false
        sentID = frame.id
        var data = Data("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(frame.jpeg.count)\r\n\r\n".utf8)
        data.append(frame.jpeg)
        data.append(Data("\r\n".utf8))
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { self.close(); return }
            // 送り終わったら次のコマ（新しいコマが来ていれば、すぐ送る）
            self.hungry = true
            self.onHungry?()
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?()
    }
}

// MARK: - Multipeer の通知

extension RemoteHost: MCNearbyServiceBrowserDelegate, MCSessionDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            if !self.nearbyMonitors.contains(peerID) { self.nearbyMonitors.append(peerID) }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { self.nearbyMonitors.removeAll { $0 == peerID } }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Diagnostics.log("リモート: 探せません \(error.localizedDescription)")
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        // 作り直す前の古いつながりからの知らせは無視する
        guard session === self.session else { return }
        queue.async {
            if state == .connected {
                self.peerSentID = 0
                self.peerHungry = true
                self.sendToPeer(RemoteWire.pack(RemoteWire.state, self.latestStateJSON), reliable: true)
                self.sendFrameToPeer()
            } else if session.connectedPeers.isEmpty {
                self.peerHungry = false
            }
        }
        DispatchQueue.main.async {
            switch state {
            case .connected:
                Diagnostics.log("リモート: つながった（\(self.inviteAttempts) 回目）")
                self.connectedMonitor = peerID.displayName
                self.invitingMonitor = nil
            case .notConnected:
                if self.invitingMonitor == peerID {
                    if self.inviteAttempts < 3, self.browser != nil {
                        // 失敗したら、新しいつながりを作って自動でもう一度誘う（3 回まで）
                        Diagnostics.log("リモート: つながらなかったので試し直す（\(self.inviteAttempts) 回目）")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                            guard self.invitingMonitor == peerID, self.browser != nil else { return }
                            self.attemptInvite(peerID)
                        }
                    } else {
                        Diagnostics.log("リモート: つながらなかった（\(self.inviteAttempts) 回）")
                        self.invitingMonitor = nil
                    }
                }
                if session.connectedPeers.isEmpty { self.connectedMonitor = nil }
            default:
                break
            }
            self.updateStreaming()
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let kind = data.first else { return }
        switch kind {
        case RemoteWire.ack:
            queue.async {
                self.peerHungry = true
                self.sendFrameToPeer()
            }
        case RemoteWire.command:
            if let command = try? JSONDecoder().decode(RemoteCommand.self, from: data.dropFirst()) {
                DispatchQueue.main.async { self.onCommand?(command) }
            }
        case RemoteWire.focus:
            if let focus = try? JSONDecoder().decode(RemoteFocus.self, from: data.dropFirst()) {
                DispatchQueue.main.async { self.onFocus?(focus) }
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

// MARK: - C: Apple Watch（WatchConnectivity）

/// 時計とのやり取りの決まり（PoseCamWatch/WatchMonitor.swift と合わせる）
enum WatchWire {
    /// 時計が見ている合図（見ている間 2 秒ごとに届く）。["hello": 1]
    static let hello = "hello"
    /// 時計が 1 コマ表示し終えた合図。["ack": 1]
    static let ack = "ack"
    /// 時計の画面を閉じた合図。["bye": 1]
    static let bye = "bye"
    /// 時計からの操作。["cmd": RemoteCommand の rawValue]
    static let command = "cmd"
    /// 撮る側の状態（RemoteState の JSON）。["state": Data]
    static let state = "state"
}

extension RemoteHost: WCSessionDelegate {
    /// queue で呼ぶ
    fileprivate func publishWatch(_ jpeg: Data) {
        let id = (latestWatchFrame?.id ?? 0) + 1
        latestWatchFrame = (id, jpeg)
        if watchHungry { sendFrameToWatch() }
    }

    /// queue で呼ぶ。まだ送っていない新しいコマがあれば送り、時計の合図を待つ
    private func sendFrameToWatch() {
        let session = WCSession.default
        guard let frame = latestWatchFrame, frame.id != watchSentID,
              session.activationState == .activated, session.isReachable else {
            watchHungry = true
            return
        }
        watchHungry = false
        watchSentID = frame.id
        session.sendMessageData(frame.jpeg, replyHandler: nil) { [weak self] _ in
            // 送れなかったら、次のコマを送れるようにしておく
            self?.queue.async { self?.watchHungry = true }
        }
        // 合図が届かないまま止まらないよう、1.5 秒で次を送ってよいことにする
        let sent = frame.id
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.watchSentID == sent, !self.watchHungry else { return }
            self.sendFrameToWatch()
        }
    }

    /// queue で呼ぶ
    fileprivate func sendStateToWatch() {
        let session = WCSession.default
        guard watchLastSeen > 0, session.activationState == .activated, session.isReachable else { return }
        session.sendMessage([WatchWire.state: latestStateJSON], replyHandler: nil, errorHandler: nil)
    }

    /// queue で呼ぶ。時計からの合図が 5 秒届かなければ、見るのをやめたとみなす（手首を下ろした・圏外など）
    private func checkWatchAlive() {
        guard watchLastSeen > 0 else { return }
        if CACurrentMediaTime() - watchLastSeen > 5 {
            setWatchViewing(false)
        } else {
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.checkWatchAlive() }
        }
    }

    /// queue で呼ぶ
    private func setWatchViewing(_ on: Bool) {
        if on {
            let first = watchLastSeen == 0
            watchLastSeen = CACurrentMediaTime()
            guard first else { return }
            watchSentID = 0
            watchHungry = true
            sendStateToWatch()
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.checkWatchAlive() }
        } else {
            guard watchLastSeen > 0 else { return }
            watchLastSeen = 0
            watchHungry = false
            latestWatchFrame = nil
        }
        DispatchQueue.main.async {
            self.watchViewing = on
            self.updateStreaming()
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error { Diagnostics.log("時計: つなげません \(error.localizedDescription)") }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // 別の時計に切り替えたとき。新しい時計とつなぎ直す
        WCSession.default.activate()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        if !session.isReachable { queue.async { self.setWatchViewing(false) } }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        queue.async {
            if message[WatchWire.hello] != nil {
                self.setWatchViewing(true)
            }
            if message[WatchWire.ack] != nil {
                self.watchLastSeen = CACurrentMediaTime()
                self.watchHungry = true
                self.sendFrameToWatch()
            }
            if message[WatchWire.bye] != nil {
                self.setWatchViewing(false)
            }
            if let raw = message[WatchWire.command] as? String, let command = RemoteCommand(rawValue: raw) {
                DispatchQueue.main.async { self.onCommand?(command) }
            }
        }
    }
}
