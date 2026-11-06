import CoreGraphics
import CoreImage
import Foundation

// iPhone 専用の部品（UIKit）を使わないので、Mac の確認・事前計算ツール（tools/）からも使える。

/// 顔の位置・大きさ・向きと、取れたときは顔のパーツ（あご・両目・鼻・口）。
/// 座標系は使う所に合わせる（画像座標か等方座標）。
///
/// 横顔では片目しか見えず、目・口の位置は取れないことがある（iPhone の顔検出は向きだけは横顔でも返す）。
/// そのため、位置と大きさは「顔の枠」（中心と高さ）で、向きは yaw（左右）と roll（傾き）で比べ、
/// パーツは表示と補助にだけ使う。
/// 目は「画像の左側の目」「右側の目」で持つ（本人の左右ではない）。
struct FaceShape: Codable, Equatable {
    /// 顔の枠の中心
    var center: CGPoint
    /// 顔の枠の高さ（y の単位。画像座標でも等方座標でも画面の高さに対する割合）
    var height: CGFloat
    /// 左右の向き（度）。正面が 0。画像の右を向くと正
    var yaw: Double
    /// 傾き（度）。正面で頭がまっすぐなら 0
    var roll: Double
    /// あごのライン（取れたときだけ）
    var contour: [CGPoint] = []
    var leftEye: CGPoint?
    var rightEye: CGPoint?
    var nose: CGPoint?
    /// 唇の外側の輪郭（取れたときだけ）
    var mouth: [CGPoint] = []

    func map(_ transform: (CGPoint) -> CGPoint) -> FaceShape {
        var result = self
        result.center = transform(center)
        result.contour = contour.map(transform)
        result.leftEye = leftEye.map(transform)
        result.rightEye = rightEye.map(transform)
        result.nose = nose.map(transform)
        result.mouth = mouth.map(transform)
        return result
    }

    /// 等方座標で左右反転したもの（左右の目を入れ替え、向きと傾きの符号も逆にする）
    func mirrored() -> FaceShape {
        let flip = { (p: CGPoint) in CGPoint(x: -p.x, y: p.y) }
        var result = map(flip)
        result.leftEye = rightEye.map(flip)
        result.rightEye = leftEye.map(flip)
        result.yaw = -yaw
        result.roll = -roll
        return result
    }

    /// 顔の幅のめやす（顔の枠はほぼ縦長なので高さの 0.8 倍）
    var width: CGFloat { height * 0.8 }
}

/// 2 人以上のポーズの、2 人目以降の人の骨格と顔（座標系は使う所に合わせる）。
struct PersonShape: Codable, Equatable {
    var points: [String: CGPoint]
    var face: FaceShape?

    var joints: [Joint: CGPoint] {
        Dictionary(uniqueKeysWithValues: points.compactMap { key, value in Joint(rawValue: key).map { ($0, value) } })
    }

    init(joints: [Joint: CGPoint], face: FaceShape?) {
        points = Dictionary(uniqueKeysWithValues: joints.map { ($0.key.rawValue, $0.value) })
        self.face = face
    }

    func map(_ transform: (CGPoint) -> CGPoint) -> PersonShape {
        PersonShape(points: points.mapValues(transform), face: face?.map(transform))
    }

    init(points: [String: CGPoint], face: FaceShape?) {
        self.points = points
        self.face = face
    }
}

/// 写真から取り出した型の形（等方座標）。
struct PoseShape: Codable {
    var points: [String: CGPoint]
    /// いちばん大きい人物の輪郭
    var outline: [CGPoint]?
    /// 2 人以上写っているときの、ほかの人の輪郭
    var extraOutlines: [[CGPoint]]?
    /// いちばん大きく写っている顔のパーツ
    var face: FaceShape?
    /// 料理・ドリンクの写真のテーブルの縁（開いた線）
    var lines: [[CGPoint]]?
    /// 2 人以上のポーズの、2 人目以降の骨格と顔
    var extraPeople: [PersonShape]?
}

/// 写真を解析した結果。座標は写真の画像座標（左上原点・0...1）。
struct PhotoAnalysis {
    /// 写真の大きさ（ピクセル）
    let size: CGSize
    /// 関節（写真から取り込む画面では、手で動かせる）
    var joints: [Joint: CGPoint]
    /// 人物の輪郭。大きい順
    let outlines: [[CGPoint]]
    /// いちばん大きく写っている顔のパーツ（画像座標）
    var face: FaceShape?
    /// テーブルの縁（画像座標の [始点, 終点]）
    var lines: [[CGPoint]] = []
    /// 2 人以上写っているときの、2 人目以降の骨格と顔（画像座標）
    var others: [PersonShape] = []

    /// 写っている人物全員の範囲（ピクセル）。輪郭があれば輪郭、なければ関節から求める
    var personBounds: CGRect {
        let source = outlines.isEmpty ? Array(joints.values) : outlines.flatMap { $0 }
        let points = source.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else {
            return CGRect(origin: .zero, size: size)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// 写真に写っている人の骨格と輪郭から型を作る。
///
/// 写真の中の「カメラの画面と同じ比率の枠」（crop、ピクセル）を決め、その枠の中の位置をそのまま型にする。
/// こうすると、枠の中で人が占める大きさ・位置が、撮影画面でもそのまま再現される。
enum PoseImporter {
    static func analyze(_ source: CIImage) -> PhotoAnalysis? {
        let image = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX,
                                                             y: -source.extent.minY))
        let people = PoseDetector().detectPeople(ciImage: image)
        let joints = people.first ?? [:]
        let outlines = PoseDetector.personOutlines(ciImage: image)
        // 輪郭が取れれば、足などの関節が検出できなくても型にできる
        guard !outlines.isEmpty || joints.count >= 6 else { return nil }
        let faces = PoseDetector.faceShapes(ciImage: image)
        var analysis = PhotoAnalysis(size: image.extent.size, joints: joints, outlines: outlines, face: faces.first)
        analysis.others = otherPeople(people, faces: faces)
        return analysis
    }

    /// 2 人目以降の人。後ろに小さく写った人を拾わないよう、関節が 6 つ以上あり、
    /// 1 人目の体の大きさ（関節の上下の幅）の半分以上の人を 3 人まで使う。
    /// （以前は人の輪郭が 2 つ以上あるときだけにしていたが、くっついて写った 2 人は輪郭が 1 つになり、
    /// 2 人の見本写真 11 枚のうち 1 枚しか 2 人目が取れなかった）
    /// 顔は、1 人目の顔（いちばん大きい顔）以外で、その人の頭（鼻・耳・首）にいちばん近いものを付ける
    static func otherPeople(_ people: [[Joint: CGPoint]], faces: [FaceShape]) -> [PersonShape] {
        guard let first = people.first else { return [] }
        func height(_ joints: [Joint: CGPoint]) -> CGFloat {
            let ys = joints.values.map(\.y)
            return (ys.max() ?? 0) - (ys.min() ?? 0)
        }
        let minimum = height(first) * 0.5
        var remaining = Array(faces.dropFirst())
        var result: [PersonShape] = []
        for joints in people.dropFirst() where joints.count >= 6 && height(joints) >= minimum {
            guard result.count < 3 else { break }
            let head = [Joint.nose, .leftEar, .rightEar].compactMap { joints[$0] }
            let anchor = head.isEmpty ? joints[.neck] : CGPoint(x: head.map(\.x).reduce(0, +) / CGFloat(head.count),
                                                                 y: head.map(\.y).reduce(0, +) / CGFloat(head.count))
            var face: FaceShape?
            if let anchor, let index = remaining.indices.min(by: {
                hypot(remaining[$0].center.x - anchor.x, remaining[$0].center.y - anchor.y)
                    < hypot(remaining[$1].center.x - anchor.x, remaining[$1].center.y - anchor.y)
            }), hypot(remaining[index].center.x - anchor.x, remaining[index].center.y - anchor.y) < remaining[index].height * 1.5 {
                face = remaining.remove(at: index)
            }
            result.append(PersonShape(joints: joints, face: face))
        }
        return result
    }

    /// 料理・ドリンクの写真から、主な被写体（お皿・グラス・手）の輪郭を取り出す。
    static func analyzeObject(_ source: CIImage) -> PhotoAnalysis? {
        let image = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX,
                                                             y: -source.extent.minY))
        let outlines = PoseDetector.objectOutlines(ciImage: image)
        guard !outlines.isEmpty else { return nil }
        return PhotoAnalysis(size: image.extent.size, joints: [:], outlines: outlines)
    }

    /// 料理・ドリンクは写真の構図そのものが手本なので、写真の中央を画面の比率でできるだけ大きく切り抜く。
    static func fullFrameCrop(size: CGSize, aspect: CGFloat) -> CGRect {
        var width = size.width
        var height = width / aspect
        if height > size.height {
            height = size.height
            width = height * aspect
        }
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    /// 人物全体が枠に収まる、最初の枠。
    /// 写真の下端まで人が写っている（上半身の写真など）ときは、写真の下端を枠の下端にして元の構図を保つ。
    static func defaultCrop(for analysis: PhotoAnalysis, aspect: CGFloat) -> CGRect {
        let bounds = analysis.personBounds
        let touchesBottom = bounds.maxY > analysis.size.height * 0.985
        let top = bounds.minY - bounds.height * 0.08
        let bottom = touchesBottom ? analysis.size.height : bounds.maxY + bounds.height * 0.06
        var height = bottom - top
        var width = height * aspect
        if width < bounds.width * 1.12 {
            width = bounds.width * 1.12
            height = width / aspect
        }
        let originY = touchesBottom ? analysis.size.height - height : top - (height - (bottom - top)) / 2
        return CGRect(x: bounds.midX - width / 2, y: originY, width: width, height: height)
    }

    /// 枠の中の位置を等方座標にした型の形。
    static func shape(for analysis: PhotoAnalysis, crop: CGRect) -> PoseShape {
        let aspect = crop.width / crop.height
        func convert(_ point: CGPoint) -> CGPoint {
            let x = (point.x * analysis.size.width - crop.minX) / crop.width
            let y = (point.y * analysis.size.height - crop.minY) / crop.height
            return CGPoint(x: (x - 0.5) * aspect, y: y)
        }
        let outlines = analysis.outlines.map { $0.map(convert) }
        func convertFace(_ face: FaceShape) -> FaceShape {
            var converted = face.map(convert)
            converted.height = face.height * analysis.size.height / crop.height
            return converted
        }
        var shape = PoseShape(
            points: Dictionary(uniqueKeysWithValues: analysis.joints.map { ($0.key.rawValue, convert($0.value)) }),
            outline: outlines.first,
            extraOutlines: outlines.count > 1 ? Array(outlines.dropFirst()) : nil,
            // 顔の高さは「枠の高さに対する割合」に直す（以前は写真の高さに対する割合のままで、
            // 枠が写真より小さい・大きいと、顔の大きさの一致度の基準がその分ずれていた）
            face: analysis.face.map { face in
                var converted = face.map(convert)
                converted.height = face.height * analysis.size.height / crop.height
                return converted
            },
            lines: analysis.lines.isEmpty ? nil : analysis.lines.map { $0.map(convert) })
        if !analysis.others.isEmpty {
            shape.extraPeople = analysis.others.map {
                PersonShape(points: $0.points.mapValues(convert), face: $0.face.map(convertFace))
            }
        }
        return shape
    }

    static func makeTemplate(name: String, shape: PoseShape) -> PoseTemplate {
        var template = PoseTemplate(name: name, category: PoseTemplate.userCategory, joints: [:],
                                    isUserCreated: true, recommendedZoom: 1, outline: shape.outline)
        template.points = shape.points
        template.extraOutlines = shape.extraOutlines
        template.face = shape.face
        template.lines = shape.lines
        template.extraPeople = shape.extraPeople
        return template
    }
}
