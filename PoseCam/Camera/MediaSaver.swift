import Foundation
import Photos

/// 写真アプリへの保存。追加のみの権限（.addOnly）で足りる。
enum MediaSaver {
    /// creationDate: 写真アプリで並ぶ日時（nil なら写真の撮影日時。編集した写真は保存した日時にする）
    static func savePhoto(_ data: Data, creationDate: Date? = nil, completion: @escaping (Bool) -> Void) {
        withAddPermission({ ok, _ in completion(ok) }) {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
            if let creationDate { request.creationDate = creationDate }
        }
    }

    /// 成功時は一時ファイルを写真ライブラリへ移動する。失敗時は一時ファイルを消す。
    static func saveVideo(at url: URL, completion: @escaping (Bool, String?) -> Void) {
        withAddPermission({ ok, reason in
            if !ok { try? FileManager.default.removeItem(at: url) }
            completion(ok, reason)
        }) {
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: options)
        }
    }

    private static func withAddPermission(_ completion: @escaping (Bool, String?) -> Void,
                                          changes: @escaping () -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion(false, "写真への追加が許可されていません")
                return
            }
            PHPhotoLibrary.shared().performChanges(changes) { success, error in
                let nsError = error as NSError?
                completion(success, nsError.map { "\($0.localizedDescription) (\($0.domain) \($0.code))" })
            }
        }
    }
}
