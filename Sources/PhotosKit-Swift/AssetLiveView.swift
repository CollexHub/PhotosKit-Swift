//
//  AssetLiveView.swift
//  PhotosKit-Swift
//
//  Created by 钟钰 on 2026/6/13.
//

import Foundation
import Photos
import PhotosUI
import UIKit

final class AssetLivePhotoView: ZoomableAssetView {

    private let asset: PHAsset
    private let livePhotoView = PHLivePhotoView()
    private let loadingView = UIActivityIndicatorView(style: .large)
    private var representedAssetIdentifier: String?
    private var loadTask: Task<Void, Never>?
    private var isPlaybackActive = false

    init(asset: PHAsset) {
        self.asset = asset
        super.init(frame: .zero)
        setupLivePhotoView()
        loadLivePhoto()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        loadTask?.cancel()
        livePhotoView.stopPlayback()
    }

    override func setActive(_ active: Bool) {
        super.setActive(active)
        isPlaybackActive = active
        updatePlayback()
    }

    override func resetForReuse() {
        loadTask?.cancel()
        loadTask = nil
        representedAssetIdentifier = nil
        livePhotoView.stopPlayback()
        livePhotoView.livePhoto = nil
        loadingView.stopAnimating()
        isPlaybackActive = false
        super.resetForReuse()
    }

    private func setupLivePhotoView() {
        livePhotoView.contentMode = .scaleAspectFit
        livePhotoView.clipsToBounds = true
        livePhotoView.backgroundColor = .clear
        setMediaView(livePhotoView, aspectSize: PreviewGeometry.aspectSize(for: asset))

        loadingView.color = .white
        loadingView.hidesWhenStopped = true
        addSubview(loadingView)
        loadingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            loadingView.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private func loadLivePhoto() {
        representedAssetIdentifier = asset.localIdentifier
        loadingView.startAnimating()

        loadTask = Task { @MainActor in
            do {
                let scale = UIScreen.main.scale
                let targetSize = CGSize(
                    width: max(UIScreen.main.bounds.width * scale, CGFloat(asset.pixelWidth)),
                    height: max(UIScreen.main.bounds.height * scale, CGFloat(asset.pixelHeight))
                )
                let livePhoto = try await PhotosManager.shared.requestLive(
                    asset: asset,
                    size: targetSize,
                    mode: .aspectFit
                )

                guard !Task.isCancelled,
                      representedAssetIdentifier == asset.localIdentifier
                else { return }

                livePhotoView.livePhoto = livePhoto
                loadingView.stopAnimating()
                updatePlayback()
            } catch {
                guard !Task.isCancelled else { return }
                loadingView.stopAnimating()
                print("Error: \(error)")
            }
        }
    }

    private func updatePlayback() {
        guard livePhotoView.livePhoto != nil else { return }

        if isPlaybackActive {
            livePhotoView.startPlayback(with: .hint)
        } else {
            livePhotoView.stopPlayback()
        }
    }

}
