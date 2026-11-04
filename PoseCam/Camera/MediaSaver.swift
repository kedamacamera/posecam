import Foundation
import Photos

/// 写真アプリへの保存。追加のみの権限（.addOnly）で足りる。
enum MediaSaver {
    static func savePhoto(_ data: Data, completion: @escaping (Bool) -> Void) {
        withAddPermission(completion) {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }

    /// 成功時は一時ファイルを写真ライブラリへ移動する。失敗時は一時ファイルを消す。
    static func saveVideo(at url: URL, completion: @escaping (Bool) -> Void) {
        withAddPermission({ ok in
            if !ok { try? FileManager.default.removeItem(at: url) }
            completion(ok)
        }) {
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: options)
        }
    }

    private static func withAddPermission(_ completion: @escaping (Bool) -> Void, changes: @escaping () -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion(false)
                return
            }
            PHPhotoLibrary.shared().performChanges(changes) { success, _ in
                completion(success)
            }
        }
    }
}
