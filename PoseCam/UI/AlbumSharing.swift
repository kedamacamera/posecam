import Photos
import SwiftUI
import UIKit

/// アルバムの写真・動画を共有するときに渡すファイル（一時フォルダに書き出したもの）
struct ShareItems: Identifiable {
    let id = UUID()
    let urls: [URL]
    /// 書き出した一時フォルダ（共有の画面を閉じたら消す）
    let folder: URL

    func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }
}

enum AlbumSharing {
    /// 写真・動画の元のファイルを一時フォルダに書き出す（写真は HEIC・JPEG、動画は MOV など、撮ったときの形のまま）。
    /// iCloud にしかないものは読み込んでから書き出す。書き出せなかったものは飛ばす
    static func export(_ assets: [PHAsset]) async -> ShareItems? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        var urls: [URL] = []
        var usedNames = Set<String>()
        for asset in assets {
            let resources = PHAssetResource.assetResources(for: asset)
            // 編集してあれば編集後のもの、なければ元のもの
            let preferred: [PHAssetResourceType] = asset.mediaType == .video
                ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
            guard let resource = preferred.lazy.compactMap({ type in resources.first { $0.type == type } }).first
            else { continue }
            var name = resource.originalFilename
            if usedNames.contains(name) { name = "\(UUID().uuidString.prefix(4))-\(name)" }
            usedNames.insert(name)
            let url = folder.appendingPathComponent(name)
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            let ok: Bool = await withCheckedContinuation { done in
                PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                    if let error { Diagnostics.log("アルバム: 共有用に書き出せず \(error.localizedDescription)") }
                    done.resume(returning: error == nil)
                }
            }
            if ok { urls.append(url) }
        }
        guard !urls.isEmpty else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        return ShareItems(urls: urls, folder: folder)
    }

    /// 写真ライブラリから消す。iOS が「削除しますか？」を確認し、消したものは「最近削除した項目」に 30 日残る
    static func delete(_ assets: [PHAsset]) async -> Bool {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
            return true
        } catch {
            // 確認で「許可しない」を押したときもここに来る
            Diagnostics.log("アルバム: 削除しなかった \(error.localizedDescription)")
            return false
        }
    }
}

extension AlbumSharing {
    /// iOS の共有の画面を出す。iPhone は下から、iPad は共有ボタン（frame: 画面の座標）から吹き出しで出す
    /// （以前は SwiftUI のシートで出していて、iPad では iPhone の大きさの窓になっていた）。
    /// 閉じたら書き出した一時ファイルを消す
    @MainActor
    static func present(_ items: ShareItems, from frame: CGRect?) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first,
              var top = window.rootViewController else {
            items.cleanUp()
            return
        }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        let controller = UIActivityViewController(activityItems: items.urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in items.cleanUp() }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = window
            popover.sourceRect = frame ?? CGRect(x: window.bounds.midX, y: window.bounds.maxY - 60, width: 1, height: 1)
            popover.permittedArrowDirections = [.down, .up]
        }
        top.present(controller, animated: true)
    }
}
