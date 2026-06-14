//
//  ZoomableAssetView.swift
//  PhotosKit-Swift
//
//  Created by 钟钰 on 2026/6/14.
//

import Foundation
import Photos
import UIKit

enum PreviewGeometry {
    
    static func aspectFitRect(aspectSize: CGSize, in bounds: CGRect) -> CGRect {
        guard bounds.width > 0,
              bounds.height > 0,
              aspectSize.width > 0,
              aspectSize.height > 0
        else { return bounds }
        
        let scale = min(bounds.width / aspectSize.width, bounds.height / aspectSize.height)
        
        let size = CGSize(width: aspectSize.width * scale, height: aspectSize.height * scale)
        
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
    
    static func aspectSize(for asset: PHAsset) -> CGSize {
        CGSize(
            width: max(CGFloat(asset.pixelWidth), 1),
            height: max(CGFloat(asset.pixelHeight), 1)
        )
    }
    
}

class ZoomableAssetView: UIView {
    
    var onToggleChrome: (() -> Void)?
    var onZoomChanged: ((Bool) -> Void)?
    
    private lazy var scrollView: UIScrollView = {
        let view = UIScrollView()
        view.backgroundColor = .clear
        view.delegate = self
        view.minimumZoomScale = 1
        view.maximumZoomScale = 5
        view.bouncesZoom = true
        view.alwaysBounceHorizontal = false
        view.alwaysBounceVertical = false
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .never
        view.delaysContentTouches = false
        view.canCancelContentTouches = true
        return view
    }()
    
    private lazy var mediaContainerView: UIView = {
        let view = UIView()
        view.backgroundColor = .clear
        view.clipsToBounds = true
        return view
    }()
    
    private var mediaView: UIView?
    
    private var mediaAspectSize: CGSize = CGSize(width: 1, height: 1)
    
    private var lastReportedZoomed: Bool?
    
    private var isActive: Bool = false
    
    var isZoomed: Bool {
        scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
    }
    
    var heroView: UIView {
        mediaContainerView
    }
    
    var heroFrameInBounds: CGRect {
        PreviewGeometry.aspectFitRect(aspectSize: mediaAspectSize, in: bounds)
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        
        setupView()
        setupLayout()
        setupGestures()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        if scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 {
            layoutMediaForCurrentBounds()
        } else {
            centerMediaContainerIfNeeded()
        }
    }
    
    private func setupView() {
        backgroundColor = .clear
        clipsToBounds = true
        
        addSubview(scrollView)
        scrollView.addSubview(mediaContainerView)
    }
    
    private func setupLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    
    private func setupGestures() {
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(didTapContent))
        singleTap.numberOfTapsRequired = 1
        singleTap.delegate = self
        
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(didDoubleTapContent(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        
        singleTap.require(toFail: doubleTap)
        
        addGestureRecognizer(singleTap)
        addGestureRecognizer(doubleTap)
    }
    
    private func layoutMediaForCurrentBounds() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
        
        let frame = heroFrameInBounds
        mediaContainerView.bounds = CGRect(origin: .zero, size: frame.size)
        mediaContainerView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        mediaView?.frame = mediaContainerView.bounds
        
        scrollView.contentSize = frame.size
        centerMediaContainerIfNeeded()
    }
    
    private func centerMediaContainerIfNeeded() {
        let boundSize = scrollView.bounds.size
        var frame = mediaContainerView.frame
        frame.origin.x = frame.width < boundSize.width ? (boundSize.width - frame.width) / 2 : 0
        frame.origin.y = frame.height < boundSize.height ? (boundSize.height - frame.height) / 2 : 0
        mediaContainerView.frame = frame
    }
    
}

extension ZoomableAssetView {
    
    func setMediaView(_ view: UIView, aspectSize: CGSize) {
        mediaView?.removeFromSuperview()
        
        mediaAspectSize = aspectSize.width > 0 && aspectSize.height > 0 ? aspectSize : CGSize(width: 1, height: 1)
        
        mediaContainerView.addSubview(view)
        view.frame = mediaContainerView.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mediaView = view
        
        resetZoom(animated: true)
        
        setNeedsLayout()
    }
    
    @objc
    func setActive(_ active: Bool) {
        isActive = active
        if active {
            reportZoomStateIfNeeded()
        } else {
            resetZoom(animated: true)
            resetReportedZoomState()
        }
    }
    
    @objc
    func resetForReuse() {
        resetZoom(animated: true)
        mediaView?.removeFromSuperview()
        mediaView = nil
        onToggleChrome = nil
        onZoomChanged = nil
        
    }
    
    func resetZoom(animated: Bool) {
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: animated)
        layoutMediaForCurrentBounds()
        reportZoomStateIfNeeded()
    }
    
    func setDismissTransform(translation: CGPoint, progress: CGFloat) {
        let clamped = min(max(progress, 0), 1)
        let scale = 1 - clamped * 0.18
        transform = CGAffineTransform.identity
            .translatedBy(x: translation.x, y: translation.y)
            .scaledBy(x: scale, y: scale)
    }
    
    func resetDismissTransform(animated: Bool) {
        let animations = {
            self.transform = .identity
        }
        if animated {
            UIView.animate(
                withDuration: 0.32,
                delay: 0,
                usingSpringWithDamping: 0.82,
                initialSpringVelocity: 0.6,
                options: [.curveEaseOut],
                animations: animations
            )
        } else {
            animations()
        }
    }
    
    func setMediaHidden(_ hidden: Bool) {
        mediaContainerView.isHidden = hidden
    }
    
    func snapshotForTransition() -> UIView? {
        mediaContainerView.snapshotView(afterScreenUpdates: false)
    }
    
    private func reportZoomStateIfNeeded() {
        guard isActive else { return }
        let currentZoomed = isZoomed
        guard lastReportedZoomed != currentZoomed else { return }
        lastReportedZoomed = currentZoomed
        onZoomChanged?(currentZoomed)
    }

    private func resetReportedZoomState() {
        lastReportedZoomed = nil
    }
    
}

extension ZoomableAssetView: UIGestureRecognizerDelegate {
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view: UIView? = touch.view
        while let currentView = view {
            if currentView is UIControl {
                return false
            }
            view = currentView.superview
        }
        return true
    }
    
    @objc
    private func didTapContent() {
        onToggleChrome?()
    }
    
    @objc
    private func didDoubleTapContent(_ gesture: UIGestureRecognizer) {
        if isZoomed {
            resetZoom(animated: true)
            return
        }
        let point = gesture.location(in: mediaContainerView)
        let targetZoomScale = min(scrollView.maximumZoomScale, 2.6)
        let zoomSize = CGSize(
            width: scrollView.bounds.width / targetZoomScale,
            height: scrollView.bounds.height / targetZoomScale
        )
        let zoomRect = CGRect(
            x: point.x - zoomSize.width / 2,
            y: point.y - zoomSize.height / 2,
            width: zoomSize.width,
            height: zoomSize.height
        )
        scrollView.zoom(to: zoomRect, animated: true)
    }
    
}

extension ZoomableAssetView: UIScrollViewDelegate {
    
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        mediaContainerView
    }
    
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerMediaContainerIfNeeded()
        reportZoomStateIfNeeded()
    }
    
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        if scale <= scrollView.minimumZoomScale {
            resetZoom(animated: true)
        } else {
            reportZoomStateIfNeeded()
        }
    }
    
}
