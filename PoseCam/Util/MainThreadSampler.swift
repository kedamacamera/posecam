import Darwin
import Foundation

/// 固まったときに、メインスレッドがどの関数の中で止まっているかを調べる（調査用）。
///
/// 見張りのスレッドからメインスレッドを一瞬止め、レジスタ（pc・lr・fp）とフレームポインタの鎖から
/// 戻り先のアドレスを集めて、すぐ再開する。止めている間はメモリを確保しない（メインスレッドが
/// メモリ確保のロックを持ったまま止まっていると、こちらも止まってしまうため）。名前を調べるのは再開した後。
enum MainThreadSampler {
    private static var mainThread: thread_t = 0
    private static let capacity = 48
    private static let buffer = UnsafeMutablePointer<UInt64>.allocate(capacity: capacity)

    /// メインスレッドで一度呼ぶ
    static func recordMainThread() {
        mainThread = mach_thread_self()
    }

    /// 見張りのスレッドから呼ぶ。1 行ずつ「番号 ライブラリ 関数名 + ずれ（ライブラリの先頭からの位置）」
    static func sample() -> [String] {
        #if arch(arm64)
        guard mainThread != 0 else { return ["(メインスレッド不明)"] }
        var count = 0
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return ["(止められなかった)"] }
        var state = arm_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(mainThread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &stateCount)
            }
        }
        if kr == KERN_SUCCESS {
            // 署名つきポインタの上位ビットを落とす
            let mask: UInt64 = 0x0000_000F_FFFF_FFFF
            buffer[0] = state.__pc & mask
            buffer[1] = state.__lr & mask
            count = 2
            var fp = state.__fp & mask
            while count < capacity, fp != 0, fp % 8 == 0 {
                var frame: (UInt64, UInt64) = (0, 0)
                var outSize: vm_size_t = 0
                let read = withUnsafeMutablePointer(to: &frame) {
                    vm_read_overwrite(mach_task_self_, vm_address_t(fp), vm_size_t(16),
                                      vm_address_t(UInt(bitPattern: $0)), &outSize)
                }
                guard read == KERN_SUCCESS else { break }
                let ret = frame.1 & mask
                guard ret != 0 else { break }
                buffer[count] = ret
                count += 1
                let next = frame.0 & mask
                guard next > fp else { break }
                fp = next
            }
        }
        thread_resume(mainThread)
        guard kr == KERN_SUCCESS else { return ["(レジスタを読めなかった \(kr))"] }

        var lines: [String] = []
        for i in 0..<count {
            let address = buffer[i]
            var info = Dl_info()
            if let pointer = UnsafeRawPointer(bitPattern: UInt(address)), dladdr(pointer, &info) != 0 {
                let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
                let base = UInt64(UInt(bitPattern: info.dli_fbase))
                let symbol = info.dli_sname.map { String(cString: $0) } ?? "?"
                let start = UInt64(UInt(bitPattern: info.dli_saddr))
                let offset = start > 0 ? address &- start : 0
                lines.append("\(i) \(image) \(symbol) + \(offset) (0x\(String(address &- base, radix: 16)))")
            } else {
                lines.append("\(i) 0x\(String(address, radix: 16))")
            }
        }
        return lines
        #else
        return ["(arm64 以外では調べない)"]
        #endif
    }
}
