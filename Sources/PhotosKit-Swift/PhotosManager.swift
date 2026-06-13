import AVFoundation
import Foundation
import Photos
import UIKit
import ImageIO

private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

public typealias PhotoManager = PhotosManager

public final class PhotosManager {
    
    public static let shared = PhotosManager()
    
    private let imageManager: PHImageManager = .default()
    
    private init() { }
    
    public func checkPermission() async throws -> Bool {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .authorized || status == .limited {
            return true
        }
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }
    
    public func fetchAssets(in album: PHAssetCollection? = nil) async throws -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: false)
        ]
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false
        
        if let album = album {
            return PHAsset.fetchAssets(in: album, options: options)
        } else {
            return PHAsset.fetchAssets(with: options)
        }
    }
    
    public func fetchAlbums() async throws -> [PHAssetCollection] {
        var albums: [PHAssetCollection] = []
        
        let smartAlbums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)
        smartAlbums.enumerateObjects { collection, _, _ in
            albums.append(collection)
        }
        
        let userAlbums = PHAssetCollection.fetchTopLevelUserCollections(with: nil)
        userAlbums.enumerateObjects { collection, _, _ in
            if let collection = collection as? PHAssetCollection {
                albums.append(collection)
            }
        }
        
        return albums
    }
    
    public func fetchImages() async throws -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: false)
        ]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false
        
        return PHAsset.fetchAssets(with: options)
    }
    
    public func fetchLives() async throws -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: false)
        ]
        options.predicate = NSPredicate(format: "mediaSubtype & %d != 0", PHAssetMediaSubtype.photoLive.rawValue)
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false
        
        return PHAsset.fetchAssets(with: options)
    }
    
    public func fetchVideos() async throws -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: false)
        ]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false
        
        return PHAsset.fetchAssets(with: options)
    }
    
    public func requestImage(
        asset: PHAsset,
        size: CGSize = CGSize(width: 200, height: 200),
        mode: PHImageContentMode = .aspectFit,
        deliveryMode: PHImageRequestOptionsDeliveryMode = .highQualityFormat,
        isNetworkAccessAllowed: Bool = true
    ) async throws -> UIImage {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = isNetworkAccessAllowed
        options.deliveryMode = deliveryMode
        
        return try await withCheckedThrowingContinuation { continuation in
            imageManager.requestImage(
                for: asset,
                targetSize: size,
                contentMode: mode,
                options: options
            ) { image, _ in
                guard let image = image else {
                    continuation.resume(throwing: NSError(domain: "Image Not Found", code: -1))
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }
    
    public func requestLive(
        asset: PHAsset,
        size: CGSize = CGSize(width: 200, height: 200),
        mode: PHImageContentMode = .aspectFit,
        deliveryMode: PHImageRequestOptionsDeliveryMode = .highQualityFormat,
        isNetworkAccessAllowed: Bool = true
    ) async throws -> PHLivePhoto {
        let options = PHLivePhotoRequestOptions()
        options.isNetworkAccessAllowed = isNetworkAccessAllowed
        options.deliveryMode = deliveryMode
        
        return try await withCheckedThrowingContinuation { continuation in
            imageManager.requestLivePhoto(
                for: asset,
                targetSize: size,
                contentMode: mode,
                options: options
            ) { live, _ in
                guard let live = live else {
                    continuation.resume(throwing: NSError(domain: "Request live error", code: -1))
                    return
                }
                continuation.resume(returning: live)
            }
        }
    }
    
    public func requestVideo(
        asset: PHAsset,
        deliveryMode: PHVideoRequestOptionsDeliveryMode = .highQualityFormat,
        isNetworkAccessAllowed: Bool = true
    ) async throws -> AVAsset {
        let options = PHVideoRequestOptions()
        options.deliveryMode = deliveryMode
        options.isNetworkAccessAllowed = isNetworkAccessAllowed
        
        let videoAsset: UncheckedSendable<AVAsset> = try await withCheckedThrowingContinuation { continuation in
            imageManager.requestAVAsset(
                forVideo: asset,
                options: options
            ) { av, _, _ in
                guard let av = av else {
                    continuation.resume(throwing: NSError(domain: "Request video error", code: -1))
                    return
                }
                continuation.resume(returning: UncheckedSendable(value: av))
            }
        }
        
        return videoAsset.value
    }
    
    public func requestVideoUrl(
        asset: PHAsset,
        deliveryMode: PHVideoRequestOptionsDeliveryMode = .highQualityFormat,
        isNetworkAccessAllowed: Bool = true
    ) async throws -> URL {
        let options = PHVideoRequestOptions()
        options.deliveryMode = deliveryMode
        options.isNetworkAccessAllowed = isNetworkAccessAllowed
        
        let exportSessionBox: UncheckedSendable<AVAssetExportSession> = try await withCheckedThrowingContinuation { continuation in
            imageManager.requestExportSession(
                forVideo: asset,
                options: options,
                exportPreset: AVAssetExportPresetHighestQuality
            ) { session, info in
                if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let session else {
                    continuation.resume(throwing: NSError(domain: "Request video url session error", code: -1))
                    return
                }
                continuation.resume(returning: UncheckedSendable(value: session))
            }
        }
        let exportSession = exportSessionBox.value
        
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportSession.outputURL = url
            exportSession.outputFileType = .mov
            let sendableExportSession = UncheckedSendable(value: exportSession)
            exportSession.exportAsynchronously {
                let exportSession = sendableExportSession.value
                switch exportSession.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                case .failed:
                    continuation.resume(throwing: exportSession.error ?? NSError(domain: "Export video error", code: -1))
                default:
                    continuation.resume(throwing: NSError(domain: "Export video error", code: -1))
                }
            }
        }
        
        return url
    }
    
    public func saveImage(
        _ image: UIImage,
        in album: PHAssetCollection?
    ) async throws -> Bool {
        return try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest.creationRequestForAsset(from: image)
                if let album = album,
                   let placeholder = request.placeholderForCreatedAsset,
                   let albumRequest = PHAssetCollectionChangeRequest(for: album) {
                    albumRequest.addAssets([placeholder] as NSArray)
                }
            } completionHandler: { success, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: success)
            }
        }
    }
    
    public func saveLive(
        photoData: Data,
        videoUrl: URL,
        in album: PHAssetCollection?
    ) async throws -> Bool {
        return try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let photoOption = PHAssetResourceCreationOptions()
                let videoOption = PHAssetResourceCreationOptions()
                request.addResource(with: .photo, data: photoData, options: photoOption)
                request.addResource(with: .pairedVideo, fileURL: videoUrl, options: videoOption)
                if let album = album,
                   let placeholder = request.placeholderForCreatedAsset,
                   let albumRequest = PHAssetCollectionChangeRequest(for: album) {
                    albumRequest.addAssets([placeholder] as NSArray)
                }
            } completionHandler: { success, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: success)
            }
        }
    }
    
    public func saveVideo(
        _ url: URL,
        in album: PHAssetCollection?
    ) async throws -> Bool {
        return try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                if let album = album,
                   let placeholder = request?.placeholderForCreatedAsset,
                   let albumRequest = PHAssetCollectionChangeRequest(for: album) {
                    albumRequest.addAssets([placeholder] as NSArray)
                }
            } completionHandler: { success, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: success)
            }
        }
    }
    
    public func delete(_ assets: [PHAsset]) async throws -> Bool {
        return try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            } completionHandler: { success, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: success)
            }
        }
    }
    
    public func requestExif(from asset: PHAsset) async throws -> [String: Any] {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .original
        return try await withCheckedThrowingContinuation { continuation in
            imageManager.requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, _, _, _ in
                guard let data = data,
                      let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                      let metadata = CGImageSourceCopyMetadataAtIndex(imageSource, 0, nil) as? [String: Any]
                else {
                    continuation.resume(throwing: NSError(domain: "Request Exif Error", code: -1))
                    return;
                }
                continuation.resume(returning: metadata)
            }
        }
    }
    
}
