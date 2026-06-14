//
//  AssetVideoView.swift
//  PhotosKit-Swift
//
//  Created by 钟钰 on 2026/6/13.
//

import AVFoundation
import Foundation
import Photos
import UIKit

final class AssetVideoView: ZoomableAssetView {

    private let asset: PHAsset
    private let renderView = VideoRenderUIView()
    private let loadingView = UIActivityIndicatorView(style: .large)
    private let controlsView = VideoControlsView()

    private var player: AVPlayer?
    private var representedAssetIdentifier: String?
    private var loadTask: Task<Void, Never>?
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?

    private var shouldPlay = false
    private var isPlaying = false
    private var isMuted = false
    private var playbackRate: Float = 1.0
    private var duration: Double = 0
    private var currentTime: Double = 0
    private var isSeeking = false
    private var wasPlayingBeforeSeeking = false
    private var controlsVisible = true

    init(asset: PHAsset, controlsVisible: Bool) {
        self.asset = asset
        self.controlsVisible = controlsVisible
        super.init(frame: .zero)
        setupVideoView()
        setupControls()
        loadVideo()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        loadTask?.cancel()
        removePlayerObservers()
        player?.pause()
        renderView.playerLayer.player = nil
    }

    override func setActive(_ active: Bool) {
        super.setActive(active)
        shouldPlay = active
        updatePlaybackState()
    }

    override func resetForReuse() {
        loadTask?.cancel()
        loadTask = nil
        representedAssetIdentifier = nil
        removePlayerObservers()
        player?.pause()
        player = nil
        renderView.playerLayer.player = nil
        loadingView.stopAnimating()
        duration = 0
        currentTime = 0
        isPlaying = false
        shouldPlay = false
        super.resetForReuse()
    }

    func setControlsVisible(_ visible: Bool, animated: Bool) {
        controlsVisible = visible
        let targetAlpha: CGFloat = visible && player != nil ? 1 : 0
        let changes = {
            self.controlsView.alpha = targetAlpha
            self.controlsView.isUserInteractionEnabled = visible && self.player != nil
        }

        if animated {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseInOut], animations: changes)
        } else {
            changes()
        }
    }

    private func setupVideoView() {
        renderView.backgroundColor = .clear
        renderView.playerLayer.videoGravity = .resizeAspect
        setMediaView(renderView, aspectSize: PreviewGeometry.aspectSize(for: asset))

        loadingView.color = .white
        loadingView.hidesWhenStopped = true
        addSubview(loadingView)
        loadingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            loadingView.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private func setupControls() {
        controlsView.alpha = 0
        controlsView.isUserInteractionEnabled = false
        controlsView.onTogglePlayPause = { [weak self] in
            self?.togglePlayPause()
        }
        controlsView.onToggleMute = { [weak self] in
            self?.toggleMute()
        }
        controlsView.onRateSelected = { [weak self] rate in
            self?.setPlaybackRate(rate)
        }
        controlsView.onSeekBegan = { [weak self] in
            self?.beginSeeking()
        }
        controlsView.onSeekChanged = { [weak self] value in
            self?.updateSeekProgress(value)
        }
        controlsView.onSeekEnded = { [weak self] value in
            self?.finishSeeking(value)
        }

        addSubview(controlsView)
        controlsView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controlsView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            controlsView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            controlsView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -24)
        ])
    }

    private func loadVideo() {
        representedAssetIdentifier = asset.localIdentifier
        loadingView.startAnimating()

        loadTask = Task { @MainActor in
            do {
                let avAsset = try await PhotosManager.shared.requestVideo(asset: asset)
                let resolvedDuration = await loadAssetDurationSeconds(avAsset)
                let playerItem = AVPlayerItem(asset: avAsset)
                let player = AVPlayer(playerItem: playerItem)
                player.automaticallyWaitsToMinimizeStalling = true
                player.isMuted = isMuted

                guard !Task.isCancelled,
                      representedAssetIdentifier == asset.localIdentifier
                else { return }

                removePlayerObservers()
                self.player?.pause()
                self.player = player
                self.renderView.playerLayer.player = player
                self.duration = resolvedDuration
                self.currentTime = 0
                self.isPlaying = false
                self.loadingView.stopAnimating()
                self.configurePlayerObservers()
                self.updateControlState()
                self.setControlsVisible(controlsVisible, animated: false)
                self.updatePlaybackState()
            } catch {
                guard !Task.isCancelled else { return }
                loadingView.stopAnimating()
                print("Error: \(error)")
            }
        }
    }

    private func loadAssetDurationSeconds(_ asset: AVAsset) async -> Double {
        do {
            let duration = try await asset.load(.duration)
            let seconds = duration.seconds
            guard seconds.isFinite && seconds > 0 else { return 0 }
            return seconds
        } catch {
            return 0
        }
    }

    private func configurePlayerObservers() {
        guard let player else { return }

        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self = self, !self.isSeeking else { return }
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            self.currentTime = max(0, seconds)
            self.updateControlState()
        }

        if let item = player.currentItem {
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                guard let self = self else { return }
                self.currentTime = 0
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                if self.shouldPlay {
                    self.play()
                } else {
                    self.isPlaying = false
                    self.updateControlState()
                }
            }
        }
    }

    private func removePlayerObservers() {
        if let token = timeObserverToken, let player {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func updatePlaybackState() {
        guard player != nil else { return }

        if shouldPlay {
            play()
        } else {
            pause(resetToBeginning: true)
        }
    }

    private func play() {
        guard let player else { return }

        player.isMuted = isMuted
        player.play()
        player.rate = playbackRate
        isPlaying = true
        updateControlState()
    }

    private func pause(resetToBeginning: Bool) {
        guard let player else { return }

        player.pause()
        isPlaying = false

        if resetToBeginning {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = 0
        }

        updateControlState()
    }

    private func togglePlayPause() {
        if isPlaying {
            pause(resetToBeginning: false)
        } else {
            shouldPlay = true
            play()
        }
    }

    private func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
        updateControlState()
    }

    private func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            player?.rate = rate
        }
        updateControlState()
    }

    private func beginSeeking() {
        guard player != nil else { return }

        isSeeking = true
        wasPlayingBeforeSeeking = isPlaying
        player?.pause()
        isPlaying = false
        updateControlState()
    }

    private func updateSeekProgress(_ value: Double) {
        currentTime = min(max(value, 0), max(duration, 0))
        updateControlState()
    }

    private func finishSeeking(_ value: Double) {
        guard let player else { return }

        currentTime = min(max(value, 0), max(duration, 0))
        let seekTime = CMTime(seconds: currentTime, preferredTimescale: 600)
        player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
        isSeeking = false

        if shouldPlay && wasPlayingBeforeSeeking {
            play()
        } else {
            updateControlState()
        }

        wasPlayingBeforeSeeking = false
    }

    private func updateControlState() {
        controlsView.configure(
            isPlaying: isPlaying,
            isMuted: isMuted,
            rate: playbackRate,
            currentTime: currentTime,
            duration: duration,
            isSeeking: isSeeking
        )
    }

}

private final class VideoControlsView: UIView {

    var onTogglePlayPause: (() -> Void)?
    var onToggleMute: (() -> Void)?
    var onRateSelected: ((Float) -> Void)?
    var onSeekBegan: (() -> Void)?
    var onSeekChanged: ((Double) -> Void)?
    var onSeekEnded: ((Double) -> Void)?

    private let supportedRates: [Float] = [0.5, 1.0, 1.5, 2.0]
    private var duration: Double = 0
    private var isDraggingSlider = false
    private var selectedRate: Float = 1.0

    private let materialView: UIVisualEffectView = {
        let effect: UIVisualEffect
        if #available(iOS 26.0, *) {
            effect = UIGlassEffect(style: .clear)
        } else {
            effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        }

        let view = UIVisualEffectView(effect: effect)
        view.contentView.backgroundColor = .black.withAlphaComponent(0.18)
        view.clipsToBounds = true
        return view
    }()

    private let timeLabel: UILabel = {
        let label = UILabel()
        label.textColor = .white.withAlphaComponent(0.96)
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textAlignment = .center
        label.alpha = 0
        return label
    }()

    private let playButton = VideoControlButton(systemName: "play.fill")
    private let muteButton = VideoControlButton(systemName: "speaker.wave.2.fill")
    private let rateButton = VideoControlButton(systemName: "speedometer")

    private let progressSlider: UISlider = {
        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.value = 0
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = .white.withAlphaComponent(0.28)

        let thumbSize = CGSize(width: 12, height: 12)
        let thumbRenderer = UIGraphicsImageRenderer(size: thumbSize)
        let thumbImage = thumbRenderer.image { ctx in
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: thumbSize))
        }
        slider.setThumbImage(thumbImage, for: .normal)
        slider.setThumbImage(thumbImage, for: .highlighted)

        let trackHeight: CGFloat = 3
        let trackSize = CGSize(width: 1, height: trackHeight)
        let trackRenderer = UIGraphicsImageRenderer(size: trackSize)
        let minTrack = trackRenderer.image { ctx in
            UIColor.white.setFill()
            ctx.cgContext.fill(CGRect(origin: .zero, size: trackSize))
        }
        let maxTrack = trackRenderer.image { ctx in
            UIColor.white.withAlphaComponent(0.28).setFill()
            ctx.cgContext.fill(CGRect(origin: .zero, size: trackSize))
        }
        slider.setMinimumTrackImage(minTrack, for: .normal)
        slider.setMaximumTrackImage(maxTrack, for: .normal)

        return slider
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
        setupActions()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        materialView.layer.cornerRadius = materialView.bounds.height / 2
    }

    func configure(
        isPlaying: Bool,
        isMuted: Bool,
        rate: Float,
        currentTime: Double,
        duration: Double,
        isSeeking: Bool
    ) {
        self.duration = max(duration, 0)
        let shouldRefreshRateMenu = abs(rate - selectedRate) >= 0.001
        selectedRate = rate

        playButton.setImage(
            UIImage(systemName: isPlaying ? "pause.fill" : "play.fill")?.withConfiguration(
                UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            ),
            for: .normal
        )
        muteButton.setImage(
            UIImage(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")?.withConfiguration(
                UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            ),
            for: .normal
        )

        if !isDraggingSlider {
            progressSlider.maximumValue = Float(max(duration, 0.1))
            progressSlider.value = Float(min(max(currentTime, 0), max(duration, 0.1)))
        }

        timeLabel.text = "\(formatTime(currentTime)) / \(formatTime(duration))"
        UIView.animate(withDuration: 0.18) {
            self.timeLabel.alpha = isSeeking ? 1 : 0
        }

        if shouldRefreshRateMenu {
            configureRateMenu()
        }
    }

    private func setupView() {
        addSubview(materialView)
        addSubview(timeLabel)

        let stack = UIStackView(arrangedSubviews: [
            playButton,
            progressSlider,
            muteButton,
            rateButton
        ])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 10

        materialView.contentView.addSubview(stack)

        materialView.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            timeLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            timeLabel.bottomAnchor.constraint(equalTo: materialView.topAnchor, constant: -8),

            materialView.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            materialView.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: trailingAnchor),
            materialView.bottomAnchor.constraint(equalTo: bottomAnchor),
            materialView.heightAnchor.constraint(equalToConstant: 48),

            stack.topAnchor.constraint(equalTo: materialView.contentView.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: materialView.contentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: materialView.contentView.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: materialView.contentView.bottomAnchor, constant: -8),

            playButton.widthAnchor.constraint(equalToConstant: 36),
            playButton.heightAnchor.constraint(equalToConstant: 36),
            muteButton.widthAnchor.constraint(equalToConstant: 36),
            muteButton.heightAnchor.constraint(equalToConstant: 36),
            rateButton.widthAnchor.constraint(equalToConstant: 36),
            rateButton.heightAnchor.constraint(equalToConstant: 36),
            progressSlider.heightAnchor.constraint(equalToConstant: 28)
        ])

        configureRateMenu()
    }

    private func setupActions() {
        playButton.addTarget(self, action: #selector(didTapPlay), for: .touchUpInside)
        muteButton.addTarget(self, action: #selector(didTapMute), for: .touchUpInside)
        progressSlider.addTarget(self, action: #selector(didBeginSeeking), for: .touchDown)
        progressSlider.addTarget(self, action: #selector(didChangeSlider), for: .valueChanged)
        progressSlider.addTarget(
            self,
            action: #selector(didEndSeeking),
            for: [.touchUpInside, .touchUpOutside, .touchCancel]
        )
    }

    private func configureRateMenu() {
        let actions = supportedRates.map { rate in
            UIAction(
                title: String(format: "%.1fx", rate),
                state: abs(rate - selectedRate) < 0.001 ? .on : .off
            ) { [weak self] _ in
                self?.onRateSelected?(rate)
            }
        }

        rateButton.menu = UIMenu(children: actions)
        rateButton.showsMenuAsPrimaryAction = true
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        let minute = total / 60
        let second = total % 60
        return String(format: "%02d:%02d", minute, second)
    }

    @objc
    private func didTapPlay() {
        onTogglePlayPause?()
    }

    @objc
    private func didTapMute() {
        onToggleMute?()
    }

    @objc
    private func didBeginSeeking() {
        isDraggingSlider = true
        onSeekBegan?()
    }

    @objc
    private func didChangeSlider() {
        onSeekChanged?(Double(progressSlider.value))
    }

    @objc
    private func didEndSeeking() {
        onSeekEnded?(Double(progressSlider.value))
        isDraggingSlider = false
    }

}

private final class VideoControlButton: UIButton {

    init(systemName: String) {
        super.init(frame: .zero)

        tintColor = .white
        setImage(
            UIImage(systemName: systemName)?.withConfiguration(
                UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            ),
            for: .normal
        )
        imageView?.contentMode = .scaleAspectFit
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

}

final class VideoRenderUIView: UIView {

    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

}
