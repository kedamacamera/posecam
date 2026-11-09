import Foundation
import Photos

/// 写真アプリへの保存。追加のみの権限（.addOnly）で足りる。
/// 写真ライブラリの読み書きも許可されていれば（アプリ内のアルバムを開いたことがあれば）、
/// 「PoseCam」というアルバムにも入れる（アルバムの「PoseCam」で、このアプリで撮ったものだけを見られる）。
enum MediaSaver {
    /// このアプリで撮ったものを入れるアルバムの名前
    static let albumTitle = "PoseCam"
    /// 作った・見つけたアルバムの番号（保存は写真ライブラリの順番待ちの列で 1 つずつ行われるので、続けて撮っても 2 つ作らない）
    private static var albumID: String?

    /// creationDate: 写真アプリで並ぶ日時（nil なら写真の撮影日時。編集した写真は保存した日時にする）
    static func savePhoto(_ data: Data, creationDate: Date? = nil, completion: @escaping (Bool) -> Void) {
        withAddPermission({ ok, _ in completion(ok) }) {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
            if let creationDate { request.creationDate = creationDate }
            return request.placeholderForCreatedAsset
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
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: options)
            return request.placeholderForCreatedAsset
        }
    }

    /// 「PoseCam」のアルバム（なければ nil）
    static func existingAlbum() -> PHAssetCollection? {
        if let albumID,
           let found = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject {
            return found
        }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", albumTitle)
        let found = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject
        if let found { albumID = found.localIdentifier }
        return found
    }

    /// 保存できた写真・動画を「PoseCam」のアルバムに入れる（なければ作る）。
    /// 保存とは別に行うので、ここで失敗しても写真・動画は保存されたまま
    private static func addToAlbum(assetID: String) {
        let readWrite = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard readWrite == .authorized || readWrite == .limited else { return }
        PHPhotoLibrary.shared().performChanges({
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else { return }
            if let album = existingAlbum() {
                PHAssetCollectionChangeRequest(for: album)?.addAssets([asset] as NSArray)
            } else {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
                request.addAssets([asset] as NSArray)
                albumID = request.placeholderForCreatedAssetCollection.localIdentifier
            }
        }) { _, error in
            if let error { Diagnostics.log("保存: PoseCam のアルバムに入れられず \(error.localizedDescription)") }
        }
    }

    private static func withAddPermission(_ completion: @escaping (Bool, String?) -> Void,
                                          changes: @escaping () -> PHObjectPlaceholder?) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion(false, "写真への追加が許可されていません")
                return
            }
            var assetID: String?
            PHPhotoLibrary.shared().performChanges({
                assetID = changes()?.localIdentifier
            }) { success, error in
                if success, let assetID { addToAlbum(assetID: assetID) }
                let nsError = error as NSError?
                completion(success, nsError.map { "\($0.localizedDescription) (\($0.domain) \($0.code))" })
            }
        }
    }
}
