//
//  PhotosPreview.swift
//  PhotosKit-Swift
//
//  Created by 钟钰 on 2026/6/13.
//

import AVFoundation
import Foundation
import Photos
import PhotosUI
import UIKit

public final class PhotosPreview: UIView {

    private let imageView = UIImageView()
    private let livePhotoView = PHLivePhotoView()
    private let videoContainerView = UIView()
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    private let errorLabel = UILabel()

    private var loadTask: Task<Void, Never>?
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var currentAssetIdentifier: String?

    public private(set) var asset: PHAsset?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    public convenience init(asset: PHAsset) {
        self.init(frame: .zero)
        configure(with: asset)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        loadTask?.cancel()
        player?.pause()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = videoContainerView.bounds
    }

    public func configure(with asset: PHAsset) {
        self.asset = asset
        currentAssetIdentifier = asset.localIdentifier
        resetContent()
        loadingIndicator.startAnimating()
        let targetSize = requestTargetSize()

        loadTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                if asset.mediaType == .video {
                    let videoAsset = try await PhotosManager.shared.requestVideo(asset: asset)
                    await MainActor.run {
                        self.showVideo(videoAsset, for: asset)
                    }
                } else if asset.mediaSubtypes.contains(.photoLive) {
                    let livePhoto = try await PhotosManager.shared.requestLive(
                        asset: asset,
                        size: targetSize,
                        mode: .aspectFit
                    )
                    await MainActor.run {
                        self.showLivePhoto(livePhoto, for: asset)
                    }
                } else {
                    let image = try await PhotosManager.shared.requestImage(
                        asset: asset,
                        size: targetSize,
                        mode: .aspectFit
                    )
                    await MainActor.run {
                        self.showImage(image, for: asset)
                    }
                }
            } catch {
                await MainActor.run {
                    self.showError(error.localizedDescription, for: asset)
                }
            }
        }
    }

    public func prepareForReuse() {
        asset = nil
        currentAssetIdentifier = nil
        resetContent()
    }

    public func pausePlayback() {
        player?.pause()
        livePhotoView.stopPlayback()
    }

    public func resumePlayback() {
        if asset?.mediaType == .video {
            player?.play()
        } else if asset?.mediaSubtypes.contains(.photoLive) == true {
            livePhotoView.startPlayback(with: .hint)
        }
    }

    private func setupView() {
        backgroundColor = .black
        clipsToBounds = true

        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.translatesAutoresizingMaskIntoConstraints = false

        livePhotoView.contentMode = .scaleAspectFit
        livePhotoView.backgroundColor = .black
        livePhotoView.translatesAutoresizingMaskIntoConstraints = false

        videoContainerView.backgroundColor = .black
        videoContainerView.translatesAutoresizingMaskIntoConstraints = false

        loadingIndicator.color = .white
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false

        errorLabel.textColor = .secondaryLabel
        errorLabel.font = .preferredFont(forTextStyle: .callout)
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(imageView)
        addSubview(livePhotoView)
        addSubview(videoContainerView)
        addSubview(loadingIndicator)
        addSubview(errorLabel)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),

            livePhotoView.topAnchor.constraint(equalTo: topAnchor),
            livePhotoView.leadingAnchor.constraint(equalTo: leadingAnchor),
            livePhotoView.trailingAnchor.constraint(equalTo: trailingAnchor),
            livePhotoView.bottomAnchor.constraint(equalTo: bottomAnchor),

            videoContainerView.topAnchor.constraint(equalTo: topAnchor),
            videoContainerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoContainerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoContainerView.bottomAnchor.constraint(equalTo: bottomAnchor),

            loadingIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),

            errorLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            errorLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            errorLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private func resetContent() {
        NotificationCenter.default.removeObserver(self)
        loadTask?.cancel()
        player?.pause()
        player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil

        imageView.image = nil
        livePhotoView.livePhoto = nil
        livePhotoView.stopPlayback()
        errorLabel.text = nil
        errorLabel.isHidden = true

        imageView.isHidden = true
        livePhotoView.isHidden = true
        videoContainerView.isHidden = true
    }

    private func showImage(_ image: UIImage, for asset: PHAsset) {
        guard currentAssetIdentifier == asset.localIdentifier else { return }
        loadingIndicator.stopAnimating()
        imageView.image = image
        imageView.isHidden = false
        livePhotoView.isHidden = true
        videoContainerView.isHidden = true
    }

    private func showLivePhoto(_ livePhoto: PHLivePhoto, for asset: PHAsset) {
        guard currentAssetIdentifier == asset.localIdentifier else { return }
        loadingIndicator.stopAnimating()
        livePhotoView.livePhoto = livePhoto
        livePhotoView.isHidden = false
        imageView.isHidden = true
        videoContainerView.isHidden = true
        livePhotoView.startPlayback(with: .hint)
    }

    private func showVideo(_ videoAsset: AVAsset, for asset: PHAsset) {
        guard currentAssetIdentifier == asset.localIdentifier else { return }
        loadingIndicator.stopAnimating()

        let item = AVPlayerItem(asset: videoAsset)
        let player = AVPlayer(playerItem: item)
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.frame = videoContainerView.bounds
        videoContainerView.layer.addSublayer(layer)

        self.player = player
        playerLayer = layer
        imageView.isHidden = true
        livePhotoView.isHidden = true
        videoContainerView.isHidden = false

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(videoDidFinishPlaying(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )
        player.play()
    }

    private func showError(_ message: String, for asset: PHAsset) {
        guard currentAssetIdentifier == asset.localIdentifier else { return }
        loadingIndicator.stopAnimating()
        errorLabel.text = message.isEmpty ? "Unable to load asset." : message
        errorLabel.isHidden = false
        imageView.isHidden = true
        livePhotoView.isHidden = true
        videoContainerView.isHidden = true
    }

    private func requestTargetSize() -> CGSize {
        let baseSize = bounds.size == .zero ? UIScreen.main.bounds.size : bounds.size
        let scale = UIScreen.main.scale
        return CGSize(
            width: max(baseSize.width * scale, 1),
            height: max(baseSize.height * scale, 1)
        )
    }

    @objc private func videoDidFinishPlaying(_ notification: Notification) {
        guard let item = notification.object as? AVPlayerItem else { return }
        item.seek(to: .zero, completionHandler: nil)
        player?.play()
    }
}
