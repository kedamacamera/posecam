import CryptoKit
import Foundation
import Network

/// アプリ同士（撮る側とモニター）の 1 本のつながり。
///
/// 以前は Multipeer Connectivity を使っていたが、Wi-Fi のない屋外では「相手は見つかるのに、つなぐと毎回
/// 10 秒ほどで切れる」ことが続いた（20 秒待つようにしても 10 秒で切れ、3 回試しても同じ）。
/// いまは Network（Apple が今すすめている方）で、端末同士の Wi-Fi（Wi-Fi のアクセスポイントがなくても
/// 2 台の間で直接つながる）を使い、TCP でつなぐ。
///
/// 送るデータは暗号化する: つながったら、お互いにその場かぎりの鍵（Curve25519）を送り合い、
/// そこから作った鍵で 1 つずつ ChaChaPoly で封をする。近くで電波を拾われても中身は読めない。
///
/// 送るときは「長さ（4 バイト）＋中身」で区切る。コールバックはこのつながり専用のキューで呼ぶ。
final class PeerLink {
    enum Role { case camera, monitor }

    /// 鍵の交換が終わり、送り合えるようになった
    var onReady: (() -> Void)?
    /// 相手から 1 つ届いた（RemoteWire.pack した形）
    var onMessage: ((Data) -> Void)?
    /// 切れた・つながらなかった（1 回だけ呼ぶ）
    var onClose: (() -> Void)?

    /// 送り合えるか（どのスレッドから読んでもよい）
    var isReady: Bool { readyBox.value }

    private let connection: NWConnection
    private let role: Role
    private let queue = DispatchQueue(label: "posecam.peerlink", qos: .userInitiated)
    private let readyBox = Locked(false)

    // queue 専用
    private let myKey = Curve25519.KeyAgreement.PrivateKey()
    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    private var pending: [Data] = []
    private var closed = false

    /// 1 つの大きさの上限（撮った写真も入るので大きめ）
    private static let maxMessage = 40 * 1024 * 1024

    /// つなぐ・待ち受けるときの設定。端末同士の Wi-Fi も使う。切れたら数秒で気づくようにする
    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 15
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 4
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    init(connection: NWConnection, role: Role) {
        self.connection = connection
        self.role = role
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // まずお互いの公開鍵を送る（これだけは封をしない）
                self.writeFrame(self.myKey.publicKey.rawRepresentation)
                self.receiveFrame()
            case .failed(let error):
                Diagnostics.log("つながり: 失敗 \(error)")
                self.close()
            case .cancelled:
                self.close()
            case .waiting(let error):
                // 経路がまだない（端末同士の Wi-Fi を立ち上げている途中など）。Network が自分で試し続けるので待つ。
                // 15 秒たっても鍵の交換まで行かなければ、下であきらめる
                Diagnostics.log("つながり: 待ち \(error)")
            default:
                break
            }
        }
        connection.start(queue: queue)
        // 鍵の交換まで 15 秒で終わらなければあきらめる
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !self.readyBox.value else { return }
            self.close()
        }
    }

    /// どのスレッドから呼んでもよい
    func send(_ data: Data) {
        queue.async {
            guard !self.closed else { return }
            if self.sendKey == nil {
                self.pending.append(data)
            } else {
                self.sealAndWrite(data)
            }
        }
    }

    /// どのスレッドから呼んでもよい。onClose は呼ばない
    func cancel() {
        queue.async {
            self.onClose = nil
            self.close()
        }
    }

    // MARK: - queue で呼ぶ

    private func close() {
        guard !closed else { return }
        closed = true
        readyBox.value = false
        connection.cancel()
        let onClose = self.onClose
        self.onClose = nil
        onClose?()
    }

    private func writeFrame(_ body: Data) {
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
    }

    private func receiveFrame() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] head, _, isComplete, error in
            guard let self, !self.closed else { return }
            guard error == nil, let head, head.count == 4 else {
                self.close()
                return
            }
            let length = Int(head.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard length > 0, length <= Self.maxMessage else {
                self.close()
                return
            }
            self.receiveBody(length)
            _ = isComplete
        }
    }

    private func receiveBody(_ length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] body, _, _, error in
            guard let self, !self.closed else { return }
            guard error == nil, let body, body.count == length else {
                self.close()
                return
            }
            self.handle(body)
            if !self.closed { self.receiveFrame() }
        }
    }

    private func handle(_ body: Data) {
        guard let receiveKey else {
            // 最初に届くのは相手の公開鍵
            guard let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: body),
                  let shared = try? myKey.sharedSecretFromKeyAgreement(with: theirs) else {
                close()
                return
            }
            // 向きごとに別の鍵にする（撮る側→モニター と モニター→撮る側）
            let salt = Data("hamera-remote-v1".utf8)
            let toMonitor = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                                           sharedInfo: Data("to-monitor".utf8), outputByteCount: 32)
            let toCamera = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                                          sharedInfo: Data("to-camera".utf8), outputByteCount: 32)
            sendKey = role == .camera ? toMonitor : toCamera
            self.receiveKey = role == .camera ? toCamera : toMonitor
            readyBox.value = true
            let waiting = pending
            pending = []
            for data in waiting { sealAndWrite(data) }
            onReady?()
            return
        }
        // 封を開ける（順番の番号が合わないもの・書き換えられたものは開かないので、切る）
        guard body.count >= 16,
              let nonce = Self.nonce(receiveCounter),
              let box = try? ChaChaPoly.SealedBox(nonce: nonce, ciphertext: body.dropLast(16), tag: body.suffix(16)),
              let plain = try? ChaChaPoly.open(box, using: receiveKey) else {
            close()
            return
        }
        receiveCounter += 1
        onMessage?(plain)
    }

    private func sealAndWrite(_ data: Data) {
        guard let sendKey, let nonce = Self.nonce(sendCounter),
              let box = try? ChaChaPoly.seal(data, using: sendKey, nonce: nonce) else {
            close()
            return
        }
        sendCounter += 1
        var body = box.ciphertext
        body.append(box.tag)
        writeFrame(body)
    }

    /// 送った順の番号から、毎回違う nonce を作る
    private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce? {
        var bytes = Data(count: 4)
        var big = counter.bigEndian
        bytes.append(Data(bytes: &big, count: 8))
        return try? ChaChaPoly.Nonce(data: bytes)
    }
}

/// 撮る側から見つけた、近くのモニター
struct NearbyMonitor: Identifiable, Equatable {
    /// モニターの端末の印（入れ直すまで変わらない）
    let id: String
    /// 画面に出す名前
    let name: String
    let endpoint: NWEndpoint
}
