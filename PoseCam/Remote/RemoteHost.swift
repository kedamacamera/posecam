import CoreImage
import Foundation
import MultipeerConnectivity
import Network
import UIKit

// リモートモニター: もう一台のスマホに撮影画面（映像＋ポーズのガイド）を映し、シャッターなどを押せるようにする。
//
// つなぎ方は 2 通り:
// - A: 両方の iPhone に PoseCam を入れ、Multipeer Connectivity で直接つなぐ（Wi-Fi がなくてもつながる）
// - B: 撮る側の iPhone が小さな Web サーバーになり、もう一台はブラウザで見る（Android でも使える。同じ Wi-Fi かテザリング）
//
// どちらも、撮る側が映像にガイドを重ねた JPEG を作って送る。受け取った側が 1 枚表示し終えてから次を送るので、
// 回線が遅くてもコマがたまって遅れていくことはない（古いコマは捨てて、いつも最新のコマを送る）。

/// モニターから撮る側への操作
enum RemoteCommand: String, Codable {
    case shutter
    case flip
    case timer
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

    /// 送っているか（どちらかのモニターが見ている）。メインスレッド用
    var isStreaming: Bool { connectedMonitor != nil || webViewers > 0 }

    /// 映像のキューから読む: 送るか
    private let streamingBox = Locked(false)
    /// ガイド（型・骨格・グリッド）を描いた透明な画像。メインスレッドで作り、JPEG を作るときに重ねる
    private let overlayBox = Locked<CGImage?>(nil)
    /// いま送っているコマの大きさ（ピクセル）。ガイドをこの大きさで描く
    let frameSizeBox = Locked<CGSize>(.zero)
    private let encodeBusy = Locked(false)
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

    private let session = MCSession(peer: RemoteWire.peerID, securityIdentity: nil, encryptionPreference: .required)
    private var browser: MCNearbyServiceBrowser?
    private var listener: NWListener?
    private var lastState: RemoteState?

    override init() {
        super.init()
        session.delegate = self
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
        encodeQueue.async { [weak self] in
            guard let self else { return }
            defer { self.encodeBusy.value = false }
            guard let jpeg = Self.jpeg(cgImage, overlay: overlay) else { return }
            self.queue.async { self.publish(jpeg) }
        }
    }

    private static func jpeg(_ image: CGImage, overlay: CGImage?) -> Data? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: rect)
        if let overlay { context.draw(overlay, in: rect) }
        guard let composed = context.makeImage() else { return nil }
        return UIImage(cgImage: composed).jpegData(compressionQuality: 0.55)
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
            if !on { self.overlayBox.value = nil }
            // 送っている間は撮る側の画面を消さない（消えるとアプリが止まり、モニターに映らなくなる）
            UIApplication.shared.isIdleTimerDisabled = on
        }
    }

    // MARK: - A: アプリのモニター（Multipeer Connectivity）

    /// 近くのモニターを探す（リモートモニターの画面を開いている間）
    func startBrowsing() {
        guard browser == nil else { return }
        let browser = MCNearbyServiceBrowser(peer: RemoteWire.peerID, serviceType: RemoteWire.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.stopBrowsingForPeers()
        browser = nil
        nearbyMonitors = []
    }

    func invite(_ peer: MCPeerID) {
        // 1 台だけつなぐ（つないでいるモニターは切ってから）
        if !session.connectedPeers.isEmpty { session.disconnect() }
        invitingMonitor = peer
        browser?.invitePeer(peer, to: session, withContext: nil, timeout: 20)
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
            respond(connection, status: "200 OK", type: "text/html; charset=utf-8", body: Data(Self.page.utf8))
        case "/state":
            respond(connection, status: "200 OK", type: "application/json", body: latestStateJSON)
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

    /// ブラウザのモニターのページ
    private static let page = """
    <!doctype html><html lang="ja"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
    <title>ポーズカメラ モニター</title>
    <style>
    html,body{margin:0;height:100%;background:#000;color:#fff;font-family:-apple-system,system-ui,sans-serif;overflow:hidden;
      -webkit-user-select:none;user-select:none;-webkit-touch-callout:none;touch-action:manipulation}
    #v{position:absolute;inset:0;width:100%;height:100%;object-fit:contain}
    #top{position:absolute;left:0;right:0;top:0;display:flex;gap:8px;padding:12px;align-items:center}
    .badge{background:#0008;border-radius:14px;padding:5px 11px;font-weight:600;font-size:15px}
    .ok{background:#1db954}
    #rec{background:#d22}
    #count{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;font-size:120px;font-weight:700;
      text-shadow:0 2px 10px #000;pointer-events:none}
    #bottom{position:absolute;left:0;right:0;bottom:0;display:flex;justify-content:space-around;align-items:center;
      padding:16px 16px calc(16px + env(safe-area-inset-bottom));background:linear-gradient(transparent,#0009)}
    button{background:#fff3;color:#fff;border:0;border-radius:28px;min-width:64px;height:56px;font-size:15px;font-weight:600}
    #shutter{width:80px;height:80px;border-radius:50%;background:#fff;border:5px solid #fff8;background-clip:padding-box}
    #shutter.video{background:#e22}
    #shutter.busy{opacity:.5}
    #msg{position:absolute;left:0;right:0;top:45%;text-align:center;color:#aaa;font-size:15px}
    </style></head><body>
    <img id="v" alt="">
    <div id="msg">つないでいます…</div>
    <div id="top"><span id="score" class="badge" hidden></span><span id="rec" class="badge" hidden></span></div>
    <div id="count" hidden></div>
    <div id="bottom">
      <button id="timer">タイマー</button>
      <button id="shutter" aria-label="シャッター"></button>
      <button id="flip">切替</button>
    </div>
    <script>
    const k=new URLSearchParams(location.search).get('k');
    const v=document.getElementById('v'),msg=document.getElementById('msg');
    function connect(){v.src='/stream?k='+k+'&t='+Date.now();}
    v.onload=()=>{msg.hidden=true;};
    v.onerror=()=>{msg.hidden=false;msg.textContent='つなぎ直しています…';setTimeout(connect,1000);};
    connect();
    function cmd(c){fetch('/cmd?k='+k+'&c='+c).catch(()=>{});if(navigator.vibrate)navigator.vibrate(20);}
    document.getElementById('shutter').onclick=()=>cmd('shutter');
    document.getElementById('flip').onclick=()=>cmd('flip');
    document.getElementById('timer').onclick=()=>cmd('timer');
    async function poll(){
      try{
        const s=await (await fetch('/state?k='+k,{cache:'no-store'})).json();
        const sc=document.getElementById('score');
        sc.hidden=s.score==null;sc.textContent='一致度 '+s.score+'%';sc.className='badge'+(s.matched?' ok':'');
        const r=document.getElementById('rec');r.hidden=!s.recording;
        r.textContent='● '+String(Math.floor(s.recordingSeconds/60)).padStart(2,'0')+':'+String(s.recordingSeconds%60).padStart(2,'0');
        const c=document.getElementById('count');c.hidden=s.countdown==null;c.textContent=s.countdown??'';
        document.getElementById('timer').textContent=s.timerSeconds?s.timerSeconds+'秒':'タイマー';
        const b=document.getElementById('shutter');
        b.className=(s.mode==='動画'?'video':'')+(s.busy?' busy':'');
        document.getElementById('flip').disabled=!s.canFlip;
      }catch(e){}
      setTimeout(poll,300);
    }
    poll();
    </script></body></html>
    """
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
        Diagnostics.mark("リモート: 探せません \(error.localizedDescription)")
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
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
                self.connectedMonitor = peerID.displayName
                self.invitingMonitor = nil
            case .notConnected:
                if self.invitingMonitor == peerID { self.invitingMonitor = nil }
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
