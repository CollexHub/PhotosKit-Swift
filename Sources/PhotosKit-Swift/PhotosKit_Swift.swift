import AVFoundation
import Foundation
import Photos
import UIKit

public enum PhotosKit {
    
    public static func checkPermission() async throws -> Bool {
        return try await PhotosManager.shared.checkPermission()
    }
    
    public static func fetchAssets(in album: PHAssetCollection? = nil) async throws -> PHFetchResult<PHAsset> {
        return try await PhotosManager.shared.fetchAssets(in: album)
    }
    
    public static func fetchAlbums() async throws -> [PHAssetCollection] {
        return try await PhotosManager.shared.fetchAlbums()
    }
    
    public static func fetchImages() async throws -> PHFetchResult<PHAsset> {
        return try await PhotosManager.shared.fetchImages()
    }
    
    public static func fetchLives() async throws -> PHFetchResult<PHAsset> {
        return try await PhotosManager.shared.fetchLives()
    }
    
    public static func fetchVideos() async throws -> PHFetchResult<PHAsset> {
        return try await PhotosManager.shared.fetchVideos()
    }
    
    public static func requestImage(
        asset: PHAsset,
        size: CGSize = CGSize(width: 200, height: 200),
        mode: PHImageContentMode = .aspectFit,
        deliveryMode: PHImageRequestOptionsDeliveryMode = .highQualityFormat,
        isNetworkAccessAllowed: Bool = true
    ) async throws -> UIImage {
        return try await PhotosManager.shared.requestImage(
            asset: asset,
            size: size,
            mode: mode,
            deliveryMode: deliveryMode,
            isNetworkAccessAllowed: isNetworkAccessAllowed
        )
    }
    
    public static func requestLive(
        asset: PHAsset,
        size: CGSize = CGSize(width: 200, height: 200),
        mode: PHImageContentMode = .aspectFit,
        deliveryMode: PHImageRequestOptionsDeliveryMode = .highQualityFormat,
        isNetworkAccessAllowed: Bool = true
    ) async throws -> PHLivePhoto {
        return try await PhotosManager.shared.requestLive(
            asset: asset,
            size: size,
            mode: mode,
            deliveryMode: deliveryMode,
            isNetworkAccessAllowed: isNetworkAccessAllowed
        )
    }
    
    public static func requestVideo(
        asset: PHAsset,
        deliveryMode: PHVideoRequestOptionsDeliveryMode = .highQualityFormat,
        isNetworkAccessAllowed: Bool = true
    ) async throws -> AVAsset {
        return try await PhotosManager.shared.requestVideo(
            asset: asset,
            deliveryMode: deliveryMode,
            isNetworkAccessAllowed: isNetworkAccessAllowed
        )
    }
    
    public static func requestVideoUrl(
        asset: PHAsset,
        deliveryMode: PHVideoRequestOptionsDeliveryMode = .highQualityFormat,
        isNetworkAccessAllowed: Bool = true
    ) async throws -> URL {
        return try await PhotosManager.shared.requestVideoUrl(
            asset: asset,
            deliveryMode: deliveryMode,
            isNetworkAccessAllowed: isNetworkAccessAllowed
        )
    }
    
    public static func saveImage(
        _ image: UIImage,
        in album: PHAssetCollection?
    ) async throws -> Bool {
        return try await PhotosManager.shared.saveImage(image, in: album)
    }
    
    public static func saveLive(
        photoData: Data,
        videoUrl: URL,
        in album: PHAssetCollection?
    ) async throws -> Bool {
        return try await PhotosManager.shared.saveLive(
            photoData: photoData,
            videoUrl: videoUrl,
            in: album
        )
    }
    
    public static func saveVideo(
        _ url: URL,
        in album: PHAssetCollection?
    ) async throws -> Bool {
        return try await PhotosManager.shared.saveVideo(url, in: album)
    }
    
    public static func delete(_ assets: [PHAsset]) async throws -> Bool {
        return try await PhotosManager.shared.delete(assets)
    }
    
    public static func requestExif(from asset: PHAsset) async throws -> [String: Any] {
        return try await PhotosManager.shared.requestExif(from: asset)
    }
    
}
