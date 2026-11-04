import Foundation

/// 複数のキュー（メイン・映像・検出）から読み書きされる値を守る小さなラッパー。
final class Locked<Value> {
    private var stored: Value
    private let lock = NSLock()

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}
