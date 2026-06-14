//
//  AssetPreviewView.swift
//  PhotosKit-Swift
//
//  Created by 钟钰 on 2026/6/13.
//

import Combine
import Foundation
import Photos
import UIKit

final class AssetPreviewViewModel: ObservableObject {

    @Published var assets: [PHAsset]
    @Published var currentIndex: Int {
        didSet {
            if oldValue != currentIndex {
                isCurrentItemZoomed = false
            }
        }
    }
    @Published var isChromeVisible = true
    private(set) var isCurrentItemZoomed = false

    init(assets: [PHAsset], currentAsset: PHAsset) {
        self.assets = assets
        self.currentIndex = assets.firstIndex { $0.localIdentifier == currentAsset.localIdentifier } ?? 0
    }

    var currentAsset: PHAsset? {
        guard assets.indices.contains(currentIndex) else { return nil }
        return assets[currentIndex]
    }

    func setCurrentIndex(_ index: Int) {
        guard assets.indices.contains(index) else { return }
        currentIndex = index
    }

    func removeCurrentAsset() {
        guard assets.indices.contains(currentIndex) else { return }

        let removingIndex = currentIndex
        if assets.count > 1 && removingIndex == assets.count - 1 {
            currentIndex = removingIndex - 1
        }

        assets.remove(at: removingIndex)

        if assets.isEmpty {
            currentIndex = 0
        }
    }

    func toggleChromeVisibility() {
        isChromeVisible.toggle()
    }

    func setCurrentItemZoomed(_ isZoomed: Bool, for asset: PHAsset) {
        guard currentAsset?.localIdentifier == asset.localIdentifier else { return }
        isCurrentItemZoomed = isZoomed
    }

}

enum PreviewDismissGesturePolicy {

    private static let minimumDismissDistance: CGFloat = 100
    private static let minimumDismissVelocity: CGFloat = 1_000

    static func shouldBeginDismissPan(velocity: CGPoint, isZoomed: Bool) -> Bool {
        guard !isZoomed else { return false }
        return velocity.y > 0 && abs(velocity.y) > abs(velocity.x)
    }

    static func shouldDismiss(translation: CGPoint, velocity: CGPoint) -> Bool {
        let horizontalDistance = abs(translation.x)
        let hasDismissDistance = translation.y >= minimumDismissDistance
            && translation.y > horizontalDistance
        let hasDismissVelocity = velocity.y >= minimumDismissVelocity
            && velocity.y > abs(velocity.x)
        return hasDismissDistance || hasDismissVelocity
    }

}

struct PreviewZoomStateTracker {

    private var isZoomed = false

    mutating func update(scale: CGFloat) -> Bool? {
        let newValue = scale > 1
        guard newValue != isZoomed else { return nil }

        isZoomed = newValue
        return newValue
    }

    mutating func reset() -> Bool? {
        guard isZoomed else { return nil }

        isZoomed = false
        return false
    }

}

final class AssetPreviewViewController: UIViewController {

    private let previewState: AssetPreviewViewModel
    private let onAssetsChanged: (() -> Void)?
    private let sourceViewProvider: ((PHAsset) -> UIView?)?
    private let sourceImageProvider: ((PHAsset) -> UIImage?)?
    private let previewTransitionDelegate: AssetPreviewTransitioningDelegate

    private var isDeleting = false
    private var cancellables = Set<AnyCancellable>()
    private var didScrollToInitialIndex = false
    private var isDraggingToDismiss = false
    private var isCompletingDraggedDismissal = false

    private lazy var previewCollectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0

        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.isPagingEnabled = true
        view.showsHorizontalScrollIndicator = false
        view.showsVerticalScrollIndicator = false
        view.alwaysBounceHorizontal = true
        view.contentInsetAdjustmentBehavior = .never
        view.dataSource = self
        view.delegate = self
        view.register(
            AssetPreviewItemCell.self,
            forCellWithReuseIdentifier: AssetPreviewItemCell.reuseIdentifier
        )
        return view
    }()

    private lazy var dismissPanGesture: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(didPanToDismiss))
        gesture.cancelsTouchesInView = false
        gesture.delegate = self
        return gesture
    }()

    private lazy var topBarView: UIStackView = {
        let view = UIStackView()
        view.axis = .horizontal
        view.alignment = .center
        view.distribution = .fill
        view.spacing = 15
        return view
    }()

    private lazy var closeButton: BlurButton = {
        let button = BlurButton()
        button.setImage(
            UIImage(systemName: "xmark")?.withConfiguration(
                UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
            )
        )
        button.addTarget(self, action: #selector(didTapClose), for: .touchUpInside)
        return button
    }()

    private lazy var deleteButton: BlurButton = {
        let button = BlurButton()
        button.setImage(
            UIImage(systemName: "trash")?.withConfiguration(
                UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
            )
        )
        button.addTarget(self, action: #selector(didTapDelete), for: .touchUpInside)
        return button
    }()

    var currentAsset: PHAsset? {
        previewState.currentAsset
    }

    init(
        assets: [PHAsset],
        currentAsset: PHAsset,
        sourceViewProvider: ((PHAsset) -> UIView?)? = nil,
        sourceImageProvider: ((PHAsset) -> UIImage?)? = nil,
        onAssetsChanged: (() -> Void)? = nil
    ) {
        self.previewState = AssetPreviewViewModel(assets: assets, currentAsset: currentAsset)
        self.onAssetsChanged = onAssetsChanged
        self.sourceViewProvider = sourceViewProvider
        self.sourceImageProvider = sourceImageProvider
        self.previewTransitionDelegate = AssetPreviewTransitioningDelegate(
            sourceViewProvider: sourceViewProvider,
            sourceImageProvider: sourceImageProvider
        )
        super.init(nibName: nil, bundle: nil)

        modalPresentationStyle = .custom
        transitioningDelegate = previewTransitionDelegate
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark

        setupPreview()
        setupDismissGesture()
        setupTopOverlayButtons()
        bindState()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateCollectionLayoutIfNeeded()

        if !didScrollToInitialIndex {
            didScrollToInitialIndex = true
            scrollToCurrentIndex(animated: false)
            updateVisibleCellStates()
        }
    }

    private func setupPreview() {
        view.addSubview(previewCollectionView)
        previewCollectionView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            previewCollectionView.topAnchor.constraint(equalTo: view.topAnchor),
            previewCollectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewCollectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewCollectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupDismissGesture() {
        view.addGestureRecognizer(dismissPanGesture)
    }

    private func setupTopOverlayButtons() {
        topBarView.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBarView)
        NSLayoutConstraint.activate([
            topBarView.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: 15
            ),
            topBarView.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: 15
            ),
            topBarView.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -15
            ),
            topBarView.heightAnchor.constraint(equalToConstant: 45),
            closeButton.widthAnchor.constraint(equalToConstant: 45),
            closeButton.heightAnchor.constraint(equalToConstant: 45),
            deleteButton.widthAnchor.constraint(equalToConstant: 45),
            deleteButton.heightAnchor.constraint(equalToConstant: 45)
        ])
        topBarView.addArrangedSubview(closeButton)
        let spacer = UIView()
        topBarView.addArrangedSubview(spacer)
        topBarView.addArrangedSubview(deleteButton)
    }

    private func bindState() {
        previewState.$isChromeVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in
                self?.setTopBarVisible(visible, animated: true)
                self?.updateVisibleCellStates()
            }
            .store(in: &cancellables)
    }

    private func updateCollectionLayoutIfNeeded() {
        guard let layout = previewCollectionView.collectionViewLayout as? UICollectionViewFlowLayout else { return }

        let targetSize = view.bounds.size
        guard targetSize.width > 0, targetSize.height > 0 else { return }

        if layout.itemSize != targetSize {
            layout.itemSize = targetSize
            layout.invalidateLayout()
            previewCollectionView.layoutIfNeeded()
            scrollToCurrentIndex(animated: false)
        }
    }

    private func reloadPreviewData() {
        previewCollectionView.reloadData()
        previewCollectionView.layoutIfNeeded()
        scrollToCurrentIndex(animated: false)
        updateVisibleCellStates()
    }

    private func scrollToCurrentIndex(animated: Bool) {
        guard previewState.assets.indices.contains(previewState.currentIndex),
              previewCollectionView.bounds.width > 0
        else { return }

        let indexPath = IndexPath(item: previewState.currentIndex, section: 0)
        previewCollectionView.scrollToItem(
            at: indexPath,
            at: .centeredHorizontally,
            animated: animated
        )
    }

    private func updateCurrentIndexFromVisiblePage() {
        guard previewCollectionView.bounds.width > 0 else { return }

        let page = Int(round(previewCollectionView.contentOffset.x / previewCollectionView.bounds.width))
        let clampedPage = min(max(page, 0), max(previewState.assets.count - 1, 0))
        previewState.setCurrentIndex(clampedPage)
        updateVisibleCellStates()
    }

    private func updateVisibleCellStates() {
        for case let cell as AssetPreviewItemCell in previewCollectionView.visibleCells {
            guard let indexPath = previewCollectionView.indexPath(for: cell) else { continue }
            cell.setActive(indexPath.item == previewState.currentIndex)
            cell.setChromeVisible(previewState.isChromeVisible, animated: true)
        }
    }

    private func currentPreviewCell() -> AssetPreviewItemCell? {
        guard previewState.assets.indices.contains(previewState.currentIndex) else { return nil }
        let indexPath = IndexPath(item: previewState.currentIndex, section: 0)
        return previewCollectionView.cellForItem(at: indexPath) as? AssetPreviewItemCell
    }

    private func setTopBarVisible(_ visible: Bool, animated: Bool) {
        guard !isDraggingToDismiss else { return }

        let applyState = {
            self.topBarView.alpha = visible ? 1 : 0
            self.topBarView.isUserInteractionEnabled = visible
        }

        if animated {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseInOut], animations: applyState)
        } else {
            applyState()
        }
    }

    private func setDismissBackgroundProgress(_ progress: CGFloat) {
        let clamped = min(max(progress, 0), 1)
        view.backgroundColor = UIColor.black.withAlphaComponent(1 - clamped * 0.92)
        topBarView.alpha = previewState.isChromeVisible ? 1 - clamped : 0
        topBarView.isUserInteractionEnabled = false
    }

    private func restoreDismissBackground() {
        view.backgroundColor = .black
        setTopBarVisible(previewState.isChromeVisible, animated: true)
    }

    @objc
    private func didTapClose() {
        dismiss(animated: true)
    }

    @objc
    private func didPanToDismiss(_ gesture: UIPanGestureRecognizer) {
        guard !isCompletingDraggedDismissal else { return }

        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)

        switch gesture.state {
        case .began:
            isDraggingToDismiss = true
            previewCollectionView.isScrollEnabled = false

        case .changed:
            let adjustedTranslation = CGPoint(
                x: translation.x,
                y: max(translation.y, 0)
            )
            let progress = min(max(adjustedTranslation.y / max(view.bounds.height * 0.42, 1), 0), 1)
            currentPreviewCell()?.setDismissTransform(
                translation: adjustedTranslation,
                progress: progress
            )
            setDismissBackgroundProgress(progress)

        case .ended:
            previewCollectionView.isScrollEnabled = true
            if PreviewDismissGesturePolicy.shouldDismiss(translation: translation, velocity: velocity) {
                completeDraggedDismissal()
            } else {
                cancelDraggedDismissal()
            }

        case .cancelled, .failed:
            previewCollectionView.isScrollEnabled = true
            cancelDraggedDismissal()

        default:
            break
        }
    }

    private func cancelDraggedDismissal() {
        isDraggingToDismiss = false
        currentPreviewCell()?.resetDismissTransform(animated: true)
        restoreDismissBackground()
    }

    private func completeDraggedDismissal() {
        guard let asset = previewState.currentAsset,
              let cell = currentPreviewCell()
        else {
            dismiss(animated: true)
            return
        }

        isCompletingDraggedDismissal = true

        let sourceView = sourceViewProvider?(asset)
        let sourceFrame: CGRect?
        if let sourceView {
            sourceFrame = sourceView.convert(sourceView.bounds, to: view)
        } else {
            sourceFrame = nil
        }
        let startFrame = cell.heroFrame(in: view)
        let endFrame = sourceFrame?.isEmpty == false
            ? sourceFrame!
            : startFrame.offsetBy(dx: 0, dy: view.bounds.height)

        let transitionImageView = UIImageView()
        transitionImageView.contentMode = .scaleAspectFit
        transitionImageView.clipsToBounds = true
        transitionImageView.frame = startFrame
        transitionImageView.layer.cornerRadius = cell.currentCornerRadius
        transitionImageView.image = sourceImageProvider?(asset)

        sourceView?.isHidden = true
        cell.setMediaHidden(true)
        view.addSubview(transitionImageView)

        let startAnimation = {
            UIView.animate(
                withDuration: 0.28,
                delay: 0,
                options: [.curveEaseInOut],
                animations: {
                    transitionImageView.frame = endFrame
                    transitionImageView.layer.cornerRadius = sourceView?.layer.cornerRadius ?? 12
                    self.previewCollectionView.alpha = 0
                    self.topBarView.alpha = 0
                    self.view.backgroundColor = .clear
                },
                completion: { _ in
                    sourceView?.isHidden = false
                    transitionImageView.removeFromSuperview()
                    self.dismiss(animated: false)
                }
            )
        }

        if transitionImageView.image != nil {
            startAnimation()
        } else {
            let thumbnailSize = CGSize(
                width: startFrame.width * UIScreen.main.scale,
                height: startFrame.height * UIScreen.main.scale
            )
            Task { @MainActor in
                let image = try? await PhotosManager.shared.requestImage(
                    asset: asset,
                    size: thumbnailSize,
                    mode: .aspectFit
                )
                transitionImageView.image = image
                startAnimation()
            }
        }
    }

    @objc
    private func didTapDelete() {
        guard !isDeleting, let asset = previewState.currentAsset else { return }

        let alert = UIAlertController(
            title: "Delete this item?",
            message: "This action cannot be undone.",
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.deleteCurrentAsset(asset)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = deleteButton
            popover.sourceRect = deleteButton.bounds
        }

        present(alert, animated: true)
    }

    private func deleteCurrentAsset(_ asset: PHAsset) {
        isDeleting = true
        deleteButton.isEnabled = false

        Task { @MainActor in
            do {
                let success = try await PhotosManager.shared.delete([asset])
                self.isDeleting = false
                self.deleteButton.isEnabled = true

                guard success else {
                    let alert = UIAlertController(
                        title: "Delete Failed",
                        message: "Please try again.",
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    self.present(alert, animated: true)
                    return
                }

                self.previewState.removeCurrentAsset()
                self.onAssetsChanged?()

                if self.previewState.assets.isEmpty {
                    self.dismiss(animated: true)
                } else {
                    self.reloadPreviewData()
                }
            } catch {
                self.isDeleting = false
                self.deleteButton.isEnabled = true
                print("Error: \(error)")
            }
        }
    }

}

extension AssetPreviewViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        previewState.assets.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: AssetPreviewItemCell.reuseIdentifier,
            for: indexPath
        ) as? AssetPreviewItemCell else {
            return UICollectionViewCell()
        }

        let asset = previewState.assets[indexPath.item]
        cell.configure(
            asset: asset,
            isActive: indexPath.item == previewState.currentIndex,
            isChromeVisible: previewState.isChromeVisible,
            onToggleChrome: { [weak self] in
                self?.previewState.toggleChromeVisibility()
            },
            onZoomChanged: { [weak self] isZoomed in
                self?.previewState.setCurrentItemZoomed(isZoomed, for: asset)
            }
        )
        return cell
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateCurrentIndexFromVisiblePage()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            updateCurrentIndexFromVisiblePage()
        }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        updateCurrentIndexFromVisiblePage()
    }

}

extension AssetPreviewViewController: UIGestureRecognizerDelegate {

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dismissPanGesture else { return true }

        let velocity = dismissPanGesture.velocity(in: view)
        return PreviewDismissGesturePolicy.shouldBeginDismissPan(
            velocity: velocity,
            isZoomed: previewState.isCurrentItemZoomed
        )
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === dismissPanGesture || otherGestureRecognizer === dismissPanGesture
    }

}

fileprivate extension AssetPreviewViewController {

    func prepareForHeroPresentation() {
        loadViewIfNeeded()
        view.layoutIfNeeded()
        previewCollectionView.layoutIfNeeded()
        scrollToCurrentIndex(animated: false)
        previewCollectionView.layoutIfNeeded()
        updateVisibleCellStates()
        setTransitionContentHidden(true)
        topBarView.alpha = 0
    }

    func completeHeroPresentation() {
        setTransitionContentHidden(false)
        setTopBarVisible(previewState.isChromeVisible, animated: true)
    }

    func prepareForHeroDismissal() {
        view.layoutIfNeeded()
        previewCollectionView.layoutIfNeeded()
        updateVisibleCellStates()
    }

    func setTransitionContentHidden(_ hidden: Bool) {
        currentPreviewCell()?.setMediaHidden(hidden)
    }

    func transitionSnapshot() -> UIView? {
        currentPreviewCell()?.snapshotForTransition()
    }

    func transitionHeroFrame(in containerView: UIView) -> CGRect {
        if let cell = currentPreviewCell() {
            let frame = cell.heroFrame(in: containerView)
            if frame.width > 0, frame.height > 0 {
                return frame
            }
        }

        guard let asset = previewState.currentAsset else {
            return view.convert(view.bounds, to: containerView)
        }

        let localFrame = PreviewGeometry.aspectFitRect(
            aspectSize: PreviewGeometry.aspectSize(for: asset),
            in: view.bounds
        )
        return view.convert(localFrame, to: containerView)
    }

}

private final class AssetPreviewItemCell: UICollectionViewCell {

    static let reuseIdentifier = "AssetPreviewItemCell"

    private var assetIdentifier: String?
    private var mediaView: ZoomableAssetView?

    var currentCornerRadius: CGFloat {
        mediaView?.heroView.layer.cornerRadius ?? 0
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        contentView.clipsToBounds = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        mediaView?.resetForReuse()
        mediaView?.removeFromSuperview()
        mediaView = nil
        assetIdentifier = nil
    }

    func configure(
        asset: PHAsset,
        isActive: Bool,
        isChromeVisible: Bool,
        onToggleChrome: @escaping () -> Void,
        onZoomChanged: @escaping (Bool) -> Void
    ) {
        if assetIdentifier != asset.localIdentifier {
            mediaView?.resetForReuse()
            mediaView?.removeFromSuperview()

            let view = makeMediaView(for: asset, controlsVisible: isChromeVisible)
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: contentView.topAnchor),
                view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])

            mediaView = view
            assetIdentifier = asset.localIdentifier
        }

        mediaView?.onToggleChrome = onToggleChrome
        mediaView?.onZoomChanged = onZoomChanged
        setActive(isActive)
        setChromeVisible(isChromeVisible, animated: false)
        resetDismissTransform(animated: false)
    }

    func setActive(_ active: Bool) {
        mediaView?.setActive(active)
    }

    func setChromeVisible(_ visible: Bool, animated: Bool) {
        (mediaView as? AssetVideoView)?.setControlsVisible(visible, animated: animated)
    }

    func setDismissTransform(translation: CGPoint, progress: CGFloat) {
        mediaView?.setDismissTransform(translation: translation, progress: progress)
    }

    func resetDismissTransform(animated: Bool) {
        mediaView?.resetDismissTransform(animated: animated)
    }

    func setMediaHidden(_ hidden: Bool) {
        mediaView?.setMediaHidden(hidden)
    }

    func snapshotForTransition() -> UIView? {
        mediaView?.snapshotForTransition() ?? snapshotView(afterScreenUpdates: false)
    }

    func heroFrame(in containerView: UIView) -> CGRect {
        guard let heroView = mediaView?.heroView else {
            return convert(bounds, to: containerView)
        }
        return heroView.convert(heroView.bounds, to: containerView)
    }

    private func makeMediaView(for asset: PHAsset, controlsVisible: Bool) -> ZoomableAssetView {
        switch asset.mediaType {
        case .image:
            if asset.mediaSubtypes.contains(.photoLive) {
                return AssetLivePhotoView(asset: asset)
            } else {
                return AssetImageView(asset: asset)
            }

        case .video:
            return AssetVideoView(asset: asset, controlsVisible: controlsVisible)

        default:
            return UnsupportedAssetPreviewView(asset: asset)
        }
    }

}

private final class UnsupportedAssetPreviewView: ZoomableAssetView {

    init(asset: PHAsset) {
        super.init(frame: .zero)

        let container = UIView()
        container.backgroundColor = .black

        let label = UILabel()
        label.text = "Unsupported Asset"
        label.textColor = .white.withAlphaComponent(0.7)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textAlignment = .center

        container.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        setMediaView(container, aspectSize: PreviewGeometry.aspectSize(for: asset))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

}

private final class AssetPreviewTransitioningDelegate: NSObject, UIViewControllerTransitioningDelegate {

    private let sourceViewProvider: ((PHAsset) -> UIView?)?
    private let sourceImageProvider: ((PHAsset) -> UIImage?)?

    init(sourceViewProvider: ((PHAsset) -> UIView?)?, sourceImageProvider: ((PHAsset) -> UIImage?)?) {
        self.sourceViewProvider = sourceViewProvider
        self.sourceImageProvider = sourceImageProvider
    }

    func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        AssetPreviewHeroAnimator(
            operation: .present,
            sourceViewProvider: sourceViewProvider,
            sourceImageProvider: sourceImageProvider
        )
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        AssetPreviewHeroAnimator(
            operation: .dismiss,
            sourceViewProvider: sourceViewProvider,
            sourceImageProvider: sourceImageProvider
        )
    }

}

private enum AssetPreviewHeroOperation {
    case present
    case dismiss
}

private final class AssetPreviewHeroAnimator: NSObject, UIViewControllerAnimatedTransitioning {

    private let operation: AssetPreviewHeroOperation
    private let sourceViewProvider: ((PHAsset) -> UIView?)?
    private let sourceImageProvider: ((PHAsset) -> UIImage?)?

    init(
        operation: AssetPreviewHeroOperation,
        sourceViewProvider: ((PHAsset) -> UIView?)?,
        sourceImageProvider: ((PHAsset) -> UIImage?)?
    ) {
        self.operation = operation
        self.sourceViewProvider = sourceViewProvider
        self.sourceImageProvider = sourceImageProvider
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        0.34
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        switch operation {
        case .present:
            animatePresentation(using: transitionContext)
        case .dismiss:
            animateDismissal(using: transitionContext)
        }
    }

    private func animatePresentation(using transitionContext: UIViewControllerContextTransitioning) {
        guard let toViewController = transitionContext.viewController(forKey: .to) as? AssetPreviewViewController,
              let toView = transitionContext.view(forKey: .to)
        else {
            fadePresentation(using: transitionContext)
            return
        }

        let containerView = transitionContext.containerView
        toView.frame = transitionContext.finalFrame(for: toViewController)
        containerView.addSubview(toView)
        toViewController.prepareForHeroPresentation()

        guard let asset = toViewController.currentAsset,
              let sourceView = sourceViewProvider?(asset)
        else {
            toViewController.completeHeroPresentation()
            fadePresentation(using: transitionContext)
            return
        }

        let startFrame = sourceView.convert(sourceView.bounds, to: containerView)
        let endFrame = toViewController.transitionHeroFrame(in: containerView)

        let transitionImageView = UIImageView()
        transitionImageView.contentMode = .scaleAspectFill
        transitionImageView.clipsToBounds = true
        transitionImageView.frame = startFrame
        transitionImageView.layer.cornerRadius = sourceView.layer.cornerRadius
        transitionImageView.image = sourceImageProvider?(asset)

        sourceView.isHidden = true
        toView.alpha = 1
        containerView.addSubview(transitionImageView)

        let startAnimation = {
            UIView.animate(
                withDuration: self.transitionDuration(using: transitionContext),
                delay: 0,
                usingSpringWithDamping: 0.88,
                initialSpringVelocity: 0.5,
                options: [.curveEaseOut],
                animations: {
                    transitionImageView.frame = endFrame
                    transitionImageView.layer.cornerRadius = 0
                },
                completion: { finished in
                    sourceView.isHidden = false
                    transitionImageView.removeFromSuperview()
                    toViewController.completeHeroPresentation()
                    transitionContext.completeTransition(finished && !transitionContext.transitionWasCancelled)
                }
            )
        }

        if transitionImageView.image != nil {
            startAnimation()
        } else {
            let thumbnailSize = CGSize(
                width: startFrame.width * UIScreen.main.scale,
                height: startFrame.height * UIScreen.main.scale
            )
            Task { @MainActor in
                let image = try? await PhotosManager.shared.requestImage(
                    asset: asset,
                    size: thumbnailSize,
                    mode: .aspectFill
                )
                guard !transitionContext.transitionWasCancelled else { return }
                transitionImageView.image = image
                startAnimation()
            }
        }
    }

    private func animateDismissal(using transitionContext: UIViewControllerContextTransitioning) {
        guard let fromViewController = transitionContext.viewController(forKey: .from) as? AssetPreviewViewController,
              let fromView = transitionContext.view(forKey: .from)
        else {
            fadeDismissal(using: transitionContext)
            return
        }

        let containerView = transitionContext.containerView
        if let toViewController = transitionContext.viewController(forKey: .to),
           let toView = transitionContext.view(forKey: .to) {
            toView.frame = transitionContext.finalFrame(for: toViewController)
            containerView.insertSubview(toView, belowSubview: fromView)
        }

        fromViewController.prepareForHeroDismissal()

        guard let asset = fromViewController.currentAsset,
              let sourceView = sourceViewProvider?(asset)
        else {
            fadeDismissal(using: transitionContext)
            return
        }

        let startFrame = fromViewController.transitionHeroFrame(in: containerView)
        let endFrame = sourceView.convert(sourceView.bounds, to: containerView)

        let transitionImageView = UIImageView()
        transitionImageView.contentMode = .scaleAspectFit
        transitionImageView.clipsToBounds = true
        transitionImageView.frame = startFrame
        transitionImageView.layer.cornerRadius = 0
        transitionImageView.image = sourceImageProvider?(asset)

        sourceView.isHidden = true
        fromViewController.setTransitionContentHidden(true)
        containerView.addSubview(transitionImageView)

        let startAnimation = {
            UIView.animate(
                withDuration: self.transitionDuration(using: transitionContext),
                delay: 0,
                options: [.curveEaseInOut],
                animations: {
                    transitionImageView.frame = endFrame
                    transitionImageView.layer.cornerRadius = sourceView.layer.cornerRadius
                    fromView.alpha = 0
                },
                completion: { finished in
                    sourceView.isHidden = false
                    transitionImageView.removeFromSuperview()
                    fromViewController.setTransitionContentHidden(false)
                    transitionContext.completeTransition(finished && !transitionContext.transitionWasCancelled)
                }
            )
        }

        if transitionImageView.image != nil {
            startAnimation()
        } else {
            let thumbnailSize = CGSize(
                width: startFrame.width * UIScreen.main.scale,
                height: startFrame.height * UIScreen.main.scale
            )
            Task { @MainActor in
                let image = try? await PhotosManager.shared.requestImage(
                    asset: asset,
                    size: thumbnailSize,
                    mode: .aspectFit
                )
                guard !transitionContext.transitionWasCancelled else { return }
                transitionImageView.image = image
                startAnimation()
            }
        }
    }

    private func fadePresentation(using transitionContext: UIViewControllerContextTransitioning) {
        guard let toView = transitionContext.view(forKey: .to) else {
            transitionContext.completeTransition(false)
            return
        }

        let containerView = transitionContext.containerView
        toView.alpha = 0
        containerView.addSubview(toView)

        UIView.animate(
            withDuration: transitionDuration(using: transitionContext),
            animations: {
                toView.alpha = 1
            },
            completion: { finished in
                transitionContext.completeTransition(finished && !transitionContext.transitionWasCancelled)
            }
        )
    }

    private func fadeDismissal(using transitionContext: UIViewControllerContextTransitioning) {
        guard let fromView = transitionContext.view(forKey: .from) else {
            transitionContext.completeTransition(false)
            return
        }

        UIView.animate(
            withDuration: transitionDuration(using: transitionContext),
            animations: {
                fromView.alpha = 0
            },
            completion: { finished in
                transitionContext.completeTransition(finished && !transitionContext.transitionWasCancelled)
            }
        )
    }

}
