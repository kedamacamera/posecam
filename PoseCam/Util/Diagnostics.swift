import Foundation

/// 起動直後のクラッシュを調べるための記録。
/// カメラ起動中に通った段階を順に UserDefaults に書き、正常に動き出したら消す。
/// 次の起動時に記録が残っていれば、どこまで進んで落ちたかが分かる。
struct CrashReport: Identifiable {
    let id = UUID()
    let steps: [String]
    let exception: String?
}

enum Diagnostics {
    private static let inProgressKey = "diag.inProgress"
    private static let stepsKey = "diag.steps"
    private static let exceptionKey = "diag.exception"
    private static let eventsKey = "diag.events"
    private static let lock = NSLock()

    /// 前回の起動がカメラ起動中に終わっていれば、その記録を返す。
    static let previousCrash: CrashReport? = {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: inProgressKey) else { return nil }
        return CrashReport(steps: defaults.stringArray(forKey: stepsKey) ?? [],
                           exception: defaults.string(forKey: exceptionKey))
    }()

    static func install() {
        _ = previousCrash
        reset()
        NSSetUncaughtExceptionHandler { exception in
            let text = "\(exception.name.rawValue): \(exception.reason ?? "")"
            UserDefaults.standard.set(text, forKey: "diag.exception")
            UserDefaults.standard.synchronize()
        }
    }

    /// どのスレッドから呼んでもよい。
    static func mark(_ step: String) {
        let thread = Thread.isMainThread ? "main" : String(cString: __dispatch_queue_get_label(nil))
        lock.lock()
        defer { lock.unlock() }
        let defaults = UserDefaults.standard
        var steps = defaults.stringArray(forKey: stepsKey) ?? []
        steps.append("[\(thread)] \(step)")
        defaults.set(Array(steps.suffix(40)), forKey: stepsKey)
        defaults.set(true, forKey: inProgressKey)
    }

    /// 起動後の出来事（録画の失敗など）を記録だけする。「落ちた」とは判定しない。
    static func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let defaults = UserDefaults.standard
        var lines = defaults.stringArray(forKey: eventsKey) ?? []
        let time = ISO8601DateFormatter().string(from: Date())
        lines.append("\(time) \(message)")
        defaults.set(Array(lines.suffix(60)), forKey: eventsKey)
    }

    /// log で記録した出来事（新しいものが後ろ）
    static var events: [String] { UserDefaults.standard.stringArray(forKey: eventsKey) ?? [] }

    // MARK: - 固まった（メインスレッドが止まった）ときの記録

    private static let hungKey = "diag.hung"

    /// 前回、画面が固まったまま終わったか（起動時に一度だけ読む。読んだら消す）
    static let previousHang: Bool = {
        let defaults = UserDefaults.standard
        let hung = defaults.bool(forKey: hungKey)
        defaults.removeObject(forKey: hungKey)
        return hung
    }()

    /// メインスレッドが 4 秒以上止まったら、その直前までの出来事の記録に「固まった」と書き、次の起動で知らせる。
    /// （固まると「動作の記録をコピー」も押せないので、次に開いたときに記録を渡せるようにする）
    /// メインスレッドから呼ぶ（起動時）
    static func startHangWatch() {
        _ = previousHang
        MainThreadSampler.recordMainThread()
        let beat = Locked(CFAbsoluteTimeGetCurrent())
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in beat.value = CFAbsoluteTimeGetCurrent() }
        RunLoop.main.add(timer, forMode: .common)
        let watch = DispatchQueue(label: "posecam.hangwatch", qos: .utility)
        var reported = false
        var lastCheck = CFAbsoluteTimeGetCurrent()
        func check() {
            let now = CFAbsoluteTimeGetCurrent()
            // この見張り自体が 2 秒以上遅れた = アプリが裏に回って止まっていた。戻った直後は固まりと数えない
            if now - lastCheck > 2 { beat.value = now }
            lastCheck = now
            let stalled = now - beat.value
            if stalled > 4, !reported {
                reported = true
                log("固まった: 画面の処理が \(Int(stalled)) 秒止まっている")
                // 止まっている所（メインスレッドの呼び出しの積み重なり）を記録する
                log("固まった所:\n" + MainThreadSampler.sample().joined(separator: "\n"))
                UserDefaults.standard.set(true, forKey: hungKey)
            } else if stalled < 1, reported {
                reported = false
                log("固まりが解けた")
                UserDefaults.standard.removeObject(forKey: hungKey)
            }
            watch.asyncAfter(deadline: .now() + 1, execute: check)
        }
        watch.asyncAfter(deadline: .now() + 1, execute: check)
    }

    static func markHealthy() {
        lock.lock()
        UserDefaults.standard.set(false, forKey: inProgressKey)
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: inProgressKey)
        defaults.removeObject(forKey: stepsKey)
        defaults.removeObject(forKey: exceptionKey)
        lock.unlock()
    }
}
