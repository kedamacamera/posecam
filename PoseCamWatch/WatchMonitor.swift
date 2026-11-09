import SwiftUI
import WatchConnectivity
import WatchKit

/// 撮る側（iPhone）の状態。iPhone の RemoteState と同じ JSON（使う項目だけ）
struct WatchCameraState: Decodable {
    var score: Int?
    var matched = false
    var countdown: Int?
    var recording = false
    var recordingSeconds = 0
    var busy = false
    var timerSeconds = 0
    var mode = "写真"
    var burstCount = 1
}

/// iPhone とのやり取り（PoseCam/Remote/RemoteHost.swift の WatchWire と合わせる）。
/// 見ている間は 2 秒ごとに「見ている」合図を送り、届いたコマを 1 枚表示するたびに「次をください」を返す
final class WatchMonitorLink: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var image: UIImage?
    @Published private(set) var state: WatchCameraState?
    @Published private(set) var reachable = false

    private var timer: Timer?
    private var lastFrame = Date.distantPast

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        if session.activationState != .activated { session.activate() }
        sayHello()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.sayHello()
            // 3 秒コマが来なければ、映像が止まったとみなして待ち表示にする
            if Date().timeIntervalSince(self.lastFrame) > 3 { self.image = nil }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        send(["bye": 1])
    }

    func command(_ name: String) {
        WKInterfaceDevice.current().play(.click)
        send(["cmd": name])
    }

    private func sayHello() {
        reachable = WCSession.default.activationState == .activated && WCSession.default.isReachable
        send(["hello": 1])
    }

    private func send(_ message: [String: Any]) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(message, replyHandler: nil, errorHandler: nil)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { self.sayHello() }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.reachable = session.isReachable
            if session.isReachable { self.sayHello() } else { self.image = nil }
        }
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        let image = UIImage(data: messageData)
        DispatchQueue.main.async {
            if let image {
                self.image = image
                self.lastFrame = Date()
            }
            // 表示したら次のコマを送ってもらう
            self.send(["ack": 1])
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let json = message["state"] as? Data,
              let state = try? JSONDecoder().decode(WatchCameraState.self, from: json) else { return }
        DispatchQueue.main.async { self.state = state }
    }
}

struct WatchMonitorView: View {
    @StateObject private var link = WatchMonitorLink()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = link.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 6) {
                    ProgressView()
                    Text(link.reachable ? "映像を待っています" : "iPhone でポーズカメラを開いてください")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }

            if let countdown = link.state?.countdown {
                Text("\(countdown)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .shadow(color: .black.opacity(0.7), radius: 6)
            }

            VStack {
                HStack(spacing: 4) {
                    if let score = link.state?.score {
                        badge("\(score)%", color: link.state?.matched == true ? .green : .black.opacity(0.6))
                    }
                    if link.state?.recording == true, let seconds = link.state?.recordingSeconds {
                        badge(String(format: "● %02d:%02d", seconds / 60, seconds % 60), color: .red)
                    }
                    Spacer()
                }
                Spacer()
                controls
            }
            .padding(.horizontal, 4)
        }
        .onAppear { link.start() }
        .onDisappear { link.stop() }
        .onChange(of: scenePhase) { _, phase in
            // 手首を下ろしたら止め、上げたらまた見る
            if phase == .active { link.start() } else { link.stop() }
        }
    }

    private var controls: some View {
        let state = link.state
        let isVideo = state?.mode == "動画"
        return HStack {
            smallButton(state.map { $0.timerSeconds == 0 ? "タイマー" : "\($0.timerSeconds)秒" } ?? "タイマー",
                        systemImage: "timer", active: (state?.timerSeconds ?? 0) > 0) { link.command("timer") }
            Spacer(minLength: 2)
            Button { link.command("shutter") } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 3).frame(width: 46, height: 46)
                    if isVideo && state?.recording == true {
                        RoundedRectangle(cornerRadius: 4).fill(.red).frame(width: 18, height: 18)
                    } else {
                        Circle().fill(isVideo ? .red : .white).frame(width: 36, height: 36)
                    }
                }
                .opacity(state?.busy == true ? 0.5 : 1)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 2)
            smallButton(state.map { $0.burstCount <= 1 ? "1枚" : "\($0.burstCount)枚" } ?? "1枚",
                        systemImage: "square.stack.3d.down.right", active: (state?.burstCount ?? 1) > 1) {
                link.command("burst")
            }
            .disabled(isVideo)
            .opacity(isVideo ? 0.4 : 1)
        }
    }

    private func smallButton(_ label: String, systemImage: String, active: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: systemImage).font(.system(size: 15, weight: .semibold))
                Text(label).font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(active ? .yellow : .white)
            .frame(width: 44, height: 40)
            .background(Circle().fill(Color.black.opacity(0.55)).frame(width: 40, height: 40))
        }
        .buttonStyle(.plain)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color))
    }
}
