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
