//
//  AssetImageView.swift
//  PhotosKit-Swift
//
//  Created by 钟钰 on 2026/6/13.
//

import Foundation
import Photos
import UIKit

final class AssetImageView: ZoomableAssetView {

    private let asset: PHAsset
    private let imageView = UIImageView()
    private let loadingView = UIActivityIndicatorView(style: .large)
    private var representedAssetIdentifier: String?
    private var loadTask: Task<Void, Never>?

    init(asset: PHAsset) {
        self.asset = asset
        super.init(frame: .zero)
        setupImageView()
        loadImage()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        loadTask?.cancel()
    }

    override func resetForReuse() {
        loadTask?.cancel()
        loadTask = nil
        representedAssetIdentifier = nil
        imageView.image = nil
        loadingView.stopAnimating()
        super.resetForReuse()
    }

    private func setupImageView() {
        backgroundColor = .clear

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.backgroundColor = .clear

        setMediaView(imageView, aspectSize: PreviewGeometry.aspectSize(for: asset))

        loadingView.color = .white
        loadingView.hidesWhenStopped = true
        addSubview(loadingView)
        loadingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            loadingView.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private func loadImage() {
        representedAssetIdentifier = asset.localIdentifier
        loadingView.startAnimating()

        loadTask = Task { @MainActor in
            do {
                let scale = UIScreen.main.scale
                let targetSize = CGSize(
                    width: max(UIScreen.main.bounds.width * scale, CGFloat(asset.pixelWidth)),
                    height: max(UIScreen.main.bounds.height * scale, CGFloat(asset.pixelHeight))
                )
                let image = try await PhotosManager.shared.requestImage(
                    asset: asset,
                    size: targetSize,
                    mode: .aspectFit
                )

                guard !Task.isCancelled,
                      representedAssetIdentifier == asset.localIdentifier
                else { return }

                imageView.image = image
                loadingView.stopAnimating()
            } catch {
                guard !Task.isCancelled else { return }
                loadingView.stopAnimating()
                print("Error: \(error)")
            }
        }
    }

}
