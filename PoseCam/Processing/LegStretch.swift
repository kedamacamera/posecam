import CoreImage

/// 脚長で伸ばす範囲。座標はすべて画像座標（上端 0・下端 1）。
///
/// 伸ばすのは start〜end（自動では腰〜足首）だけ。伸ばして増えた長さは、
/// 1. 肩より上（頭・首）を形を変えずにそのまま上へずらす（頭の上の余白の分まで）
/// 2. 足りない分だけ、肩〜伸ばし始め（胴）を少し縮める
/// で吸収し、画像の高さは変えない。肩より上は伸び縮みさせない（首や顔が短くならない）。
struct LegLayout: Equatable {
    /// 肩の高さ。これより上は形を変えない
    var shoulder: CGFloat
    var start: CGFloat
    var end: CGFloat
    /// 頭のてっぺん（少し余裕を見た位置）。これより上の余白の分だけ、上へずらしてよい
    var headTop: CGFloat

    /// 骨格（画像座標）と、手で決めた範囲から求める。骨格がなく、範囲も決めていなければ nil
    static func make(pose: [Joint: CGPoint]?, manual: ClosedRange<Double>?) -> LegLayout? {
        func average(_ joints: [Joint]) -> CGFloat? {
            let ys = joints.compactMap { pose?[$0]?.y }
            return ys.isEmpty ? nil : ys.reduce(0, +) / CGFloat(ys.count)
        }
        let hip = average([.leftHip, .rightHip])
        let shoulder = average([.leftShoulder, .rightShoulder]) ?? pose?[.neck]?.y
        let ankle = average([.leftAnkle, .rightAnkle])
        let nose = pose?[.nose]?.y

        let start: CGFloat
        let end: CGFloat
        if let manual {
            start = CGFloat(manual.lowerBound)
            end = CGFloat(manual.upperBound)
        } else {
            guard let hip else { return nil }
            start = hip
            // 足首が写っていなければ（足が切れている）、画像の下端まで伸ばす
            end = ankle.map { min(1, $0 + 0.01) } ?? 1
        }
        guard end - start > 0.05 else { return nil }

        // 肩より上の高さ。骨格がなければ、伸ばし始めより上をそのまま上へずらす
        let protected = min(shoulder ?? start, start)
        var headTop = protected
        if let shoulder {
            // 頭のてっぺんは、鼻から肩までと同じくらい鼻より上にある。少し余裕を見る
            let noseY = nose ?? shoulder - 0.08
            headTop = max(0, noseY - (shoulder - noseY) * 1.1 - 0.015)
        }
        return LegLayout(shoulder: protected, start: start, end: end, headTop: headTop)
    }

    /// 画素の単位にした、伸ばし方の数値。amount は 0...1（脚の長さを最大 25% 伸ばす）
    struct Plan {
        let height: CGFloat
        let shoulder: CGFloat
        let start: CGFloat
        let end: CGFloat
        /// 肩より上を上へずらす量
        let shift: CGFloat
        /// 伸ばして増える長さ
        let added: CGFloat

        /// 出力の行（上端 0・画素）が、元の画像のどの行から来るか（カーネルと同じ計算）
        func sourceRow(_ y: CGFloat) -> CGFloat {
            let torso = start - shoulder
            let squeezed = max(torso - (added - shift), 1)
            if y < shoulder - shift { return y + shift }
            if y < start - added { return shoulder + (y - (shoulder - shift)) * torso / squeezed }
            if y < end { return start + (y - (start - added)) * (end - start) / (end - start + added) }
            return y
        }

        /// 元の画像の行が、出力のどの行に来るか（画面に伸ばす範囲の線を描くのに使う）
        func outputRow(_ y: CGFloat) -> CGFloat {
            let torso = start - shoulder
            let squeezed = max(torso - (added - shift), 1)
            if y < shoulder { return y - shift }
            if y < start { return shoulder - shift + (y - shoulder) * squeezed / max(torso, 1) }
            if y < end { return start - added + (y - start) * (end - start + added) / (end - start) }
            return y
        }
    }

    func plan(height h: CGFloat, amount: Double) -> Plan {
        let s = shoulder * h, a = start * h, b = end * h
        var added = (b - a) * 0.25 * CGFloat(min(max(amount, 0), 1))
        let shift = min(added, max(0, headTop * h))
        // 胴は 2 割までしか縮めない。それでも足りなければ、伸ばす量のほうを減らす
        let maxSqueeze = max(0, a - s) * 0.2
        if added - shift > maxSqueeze { added = shift + maxSqueeze }
        return Plan(height: h, shoulder: s, start: a, end: b, shift: shift, added: added)
    }
}

enum LegStretch {
    private static let kernel: CIKernel? = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? CIKernel(functionName: "legStretch", fromMetalLibraryData: data)
    }()

    static func apply(_ image: CIImage, layout: LegLayout, amount: Double) -> CIImage {
        let e = image.extent
        guard let kernel, e.height > 0 else { return image }
        let plan = layout.plan(height: e.height, amount: amount)
        guard plan.added > 0.5 else { return image }
        let toOrigin = CGAffineTransform(translationX: -e.minX, y: -e.minY)
        let base = image.transformed(by: toOrigin)
        let bounds = CGRect(origin: .zero, size: e.size)
        let h = e.height
        let output = kernel.apply(extent: bounds, roiCallback: { _, rect in
            // 行の対応は単調なので、出力の上下の端の行の元の行を求めれば、必要な範囲が分かる
            let top = plan.sourceRow(h - rect.maxY)
            let bottom = plan.sourceRow(h - rect.minY)
            return CGRect(x: rect.minX - 2, y: h - bottom - 2, width: rect.width + 4, height: bottom - top + 4)
        }, arguments: [base.clampedToExtent(), h, plan.shoulder, plan.start, plan.end, plan.shift, plan.added])
        return (output ?? base).cropped(to: bounds).transformed(by: toOrigin.inverted())
    }
}
