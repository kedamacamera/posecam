import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// 保存する写真の撮影情報（Exif / TIFF）。
///
/// - 通常の撮影: iOS が付けた情報（AVCapturePhoto.metadata）をそのまま引き継ぐ。
///   加工の途中で縦向きに直しているので、向き（Orientation）は 1 にし、画素数は保存する大きさに直す。
/// - 無音撮影（映像のコマを写真にする）: 映像のコマに付いている Exif（絞り・シャッター速度・ISO・焦点距離・
///   レンズ名）を使い、写真アプリで表示される機種名・レンズ名（Make / Model / LensMake / LensModel）を補う。
enum PhotoMetadata {
    private static let exifKey = kCGImagePropertyExifDictionary as String
    private static let tiffKey = kCGImagePropertyTIFFDictionary as String

    /// 撮影日時（Exif の撮影・デジタル化の日時と、TIFF の日時）を date に書き換えた情報。
    /// 編集して保存した写真を、保存した日時の写真にするのに使う。
    static func stamped(_ metadata: [String: Any], date: Date) -> [String: Any] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let dateText = formatter.string(from: date)
        formatter.dateFormat = "xxx"
        let offset = formatter.string(from: date)
        var result = metadata
        var exif = metadata[exifKey] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifDateTimeOriginal as String] = dateText
        exif[kCGImagePropertyExifDateTimeDigitized as String] = dateText
        exif[kCGImagePropertyExifOffsetTimeOriginal as String] = offset
        exif[kCGImagePropertyExifOffsetTimeDigitized as String] = offset
        exif[kCGImagePropertyExifOffsetTime as String] = offset
        exif.removeValue(forKey: kCGImagePropertyExifSubsecTimeOriginal as String)
        exif.removeValue(forKey: kCGImagePropertyExifSubsecTimeDigitized as String)
        result[exifKey] = exif
        var tiff = metadata[tiffKey] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFDateTime as String] = dateText
        result[tiffKey] = tiff
        return result
    }

    /// 無音撮影の写真に付ける情報。exif は映像のコマの Exif。
    static func forVideoFrame(exif frameExif: [String: Any], position: AVCaptureDevice.Position) -> [String: Any] {
        var exif = frameExif
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let dateText = formatter.string(from: now)
        formatter.dateFormat = "xxx"
        let offset = formatter.string(from: now)

        // レンズ名は「iPhone 15 Pro back triple camera 6.765mm f/1.78」の形。先頭が機種名
        var lensModel = exif[kCGImagePropertyExifLensModel as String] as? String
        var model = lensModel.flatMap { name -> String? in
            for marker in [" back ", " front "] {
                if let range = name.range(of: marker) { return String(name[..<range.lowerBound]) }
            }
            return nil
        } ?? machineName
        if lensModel == nil {
            // コマにレンズ名がなければ、焦点距離と絞りから同じ形で作る
            let side = position == .front ? "front" : "back"
            var parts = ["\(model) \(side) camera"]
            if let focal = exif[kCGImagePropertyExifFocalLength as String] as? Double {
                parts.append(String(format: "%.3gmm", focal))
            }
            if let fNumber = exif[kCGImagePropertyExifFNumber as String] as? Double {
                parts.append(String(format: "f/%.3g", fNumber))
            }
            lensModel = parts.joined(separator: " ")
            exif[kCGImagePropertyExifLensModel as String] = lensModel
        }
        if model.isEmpty { model = "iPhone" }
        exif[kCGImagePropertyExifLensMake as String] = "Apple"
        exif[kCGImagePropertyExifDateTimeOriginal as String] = dateText
        exif[kCGImagePropertyExifDateTimeDigitized as String] = dateText
        exif[kCGImagePropertyExifOffsetTimeOriginal as String] = offset
        exif[kCGImagePropertyExifOffsetTimeDigitized as String] = offset

        let tiff: [String: Any] = [
            kCGImagePropertyTIFFMake as String: "Apple",
            kCGImagePropertyTIFFModel as String: model,
            kCGImagePropertyTIFFDateTime as String: dateText,
            kCGImagePropertyTIFFSoftware as String: "PoseCam",
        ]
        return [exifKey: exif, tiffKey: tiff]
    }

    /// 端末の型番（iPhone16,2 など）。レンズ名から機種名が取れないときだけ使う
    private static var machineName: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// 露出（シャッター速度 × ISO）。ダイレクトフラッシュで、写真とコマの明るさをそろえるのに使う
    static func exposure(of metadata: [String: Any]) -> Double? {
        (metadata[exifKey] as? [String: Any]).flatMap(exposure(ofExif:))
    }

    static func exposure(ofExif exif: [String: Any]) -> Double? {
        guard let time = exif[kCGImagePropertyExifExposureTime as String] as? Double else { return nil }
        let isoList = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Double]
        let iso = isoList?.first ?? 100
        return time * iso
    }

    /// 加工した画像を、撮影情報付きの JPEG にする。
    static func jpeg(_ image: CIImage, metadata: [String: Any], context: CIContext) -> Data? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let cgImage = context.createCGImage(image, from: image.extent, format: .RGBA8,
                                                  colorSpace: colorSpace) else { return nil }
        var properties = metadata
        // 縦向きに直してあるので向きは 1。画素数は保存する大きさ。元の写真の大きさ・サムネイルの情報は消す
        properties[kCGImagePropertyOrientation as String] = 1
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth,
                    kCGImagePropertyHasAlpha] {
            properties.removeValue(forKey: key as String)
        }
        if var tiff = properties[tiffKey] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[tiffKey] = tiff
        }
        if var exif = properties[exifKey] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = cgImage.width
            exif[kCGImagePropertyExifPixelYDimension as String] = cgImage.height
            properties[exifKey] = exif
        }
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.92

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
