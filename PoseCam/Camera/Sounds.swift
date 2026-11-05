import AVFoundation

/// 録画の開始・停止音とタイマーの音。
///
/// 以前は iOS のシステム音（AudioServicesPlaySystemSound の 1117・1118・1103）を鳴らしていたが、
/// 録画用に音声の設定（playAndRecord）にしているときにシステム音を鳴らすと、その後の録画で
/// マイクの声が入らず、端末の中の音（開始音）だけが入っていた（無音の設定で音を鳴らさないときは声が入る）。
/// そこで、音はアプリの中で作って、アプリ自身の音声の設定のまま AVAudioPlayer で鳴らす。
enum Sounds {
    enum Kind: CaseIterable {
        case recordStart, recordStop, tick
    }

    private static var players: [Kind: AVAudioPlayer] = [:]

    /// メインスレッドから呼ぶ
    static func play(_ kind: Kind) {
        if players[kind] == nil {
            players[kind] = try? AVAudioPlayer(data: wav(for: kind))
            players[kind]?.prepareToPlay()
        }
        guard let player = players[kind] else { return }
        // 端末の音量で大きさが変わりすぎないよう、音量が低いときは音そのものを大きくする
        // （音量 40% 以上ならほぼ同じ大きさに聞こえる。それより下げると、さすがに小さくなる）
        let output = AVAudioSession.sharedInstance().outputVolume
        player.volume = min(1, 0.4 / max(output, 0.05))
        player.currentTime = 0
        player.play()
    }

    /// 短い電子音（44.1kHz・モノラル・16 ビットの WAV）。開始は上がる 2 音、停止は下がる 2 音、タイマーは 1 音
    private static func wav(for kind: Kind) -> Data {
        let tones: [(frequency: Double, seconds: Double)]
        switch kind {
        case .recordStart: tones = [(1046.5, 0.07), (0, 0.03), (1568, 0.09)]
        case .recordStop: tones = [(1568, 0.07), (0, 0.03), (1046.5, 0.09)]
        case .tick: tones = [(1318.5, 0.05)]
        }
        let rate = 44_100.0
        var samples: [Int16] = []
        for tone in tones {
            let count = Int(rate * tone.seconds)
            for i in 0..<count {
                // 端をなめらかに上げ下げして、プツッという音が出ないようにする
                let t = Double(i) / rate
                let edge = min(1, min(Double(i), Double(count - i)) / (rate * 0.006))
                let value = tone.frequency > 0 ? sin(2 * .pi * tone.frequency * t) * 0.35 * edge : 0
                samples.append(Int16(value * Double(Int16.max)))
            }
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(byteCount))
        for sample in samples { append(sample) }
        return data
    }
}
