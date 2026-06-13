//
//  PhotosPicker.swift
//  PhotosKit-Swift
//
//  Created by 钟钰 on 2026/6/13.
//

import Foundation
import Photos
import UIKit

public enum PhotosKitPresentationError: LocalizedError {
    case permissionDenied
    case missingPresentationContext

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Photo library permission was denied."
        case .missingPresentationContext:
            return "No visible view controller is available to present PhotosKit UI."
        }
    }
}

enum PhotosSelectionChange: Equatable {
    case selected(index: Int)
    case deselected
    case rejectedMaximumCount
}

struct PhotosSelectionState {
    let maxCount: Int
    private(set) var selectedIdentifiers: [String]

    init(maxCount: Int, selectedIdentifiers: [String] = []) {
        self.maxCount = max(0, maxCount)
        self.selectedIdentifiers = Array(selectedIdentifiers.prefix(max(0, maxCount)))
    }

    mutating func toggle(_ identifier: String) -> PhotosSelectionChange {
        if let index = selectedIdentifiers.firstIndex(of: identifier) {
            selectedIdentifiers.remove(at: index)
            return .deselected
        }

        guard selectedIdentifiers.count < maxCount else {
            return .rejectedMaximumCount
        }

        selectedIdentifiers.append(identifier)
        return .selected(index: selectedIdentifiers.count)
    }

    func selectedIndex(for identifier: String) -> Int? {
        guard let index = selectedIdentifiers.firstIndex(of: identifier) else {
            return nil
        }
        return index + 1
    }
}

@MainActor
enum PhotosPickerPresenter {
    static func presentPreview(groupByDate: Bool, columnCount: Int) async throws {
        guard try await PhotosManager.shared.checkPermission() else {
            throw PhotosKitPresentationError.permissionDenied
        }
        guard let presenter = UIViewController.photosTopViewController() else {
            throw PhotosKitPresentationError.missingPresentationContext
        }

        let picker = PhotosPickerViewController(
            configuration: .init(
                mode: .previewOnly,
                groupByDate: groupByDate,
                columnCount: max(1, columnCount)
            )
        )
        let navigationController = UINavigationController(rootViewController: picker)
        navigationController.modalPresentationStyle = .fullScreen
        presenter.present(navigationController, animated: true)
    }

    static func presentPicker(maxCount: Int, groupByDate: Bool) async throws -> [PHAsset] {
        guard try await PhotosManager.shared.checkPermission() else {
            throw PhotosKitPresentationError.permissionDenied
        }
        guard let presenter = UIViewController.photosTopViewController() else {
            throw PhotosKitPresentationError.missingPresentationContext
        }

        return try await withCheckedThrowingContinuation { continuation in
            let completion = PhotosPickerContinuation(continuation)
            let picker = PhotosPickerViewController(
                configuration: .init(
                    mode: .picker(maxCount: max(1, maxCount)),
                    groupByDate: groupByDate,
                    columnCount: 3
                )
            )
            picker.onFinish = { assets in
                completion.resume(returning: assets)
            }
            picker.onCancel = {
                completion.resume(throwing: CancellationError())
            }

            let navigationController = UINavigationController(rootViewController: picker)
            navigationController.modalPresentationStyle = .fullScreen
            presenter.present(navigationController, animated: true)
        }
    }
}

private final class PhotosPickerContinuation {
    private var continuation: CheckedContinuation<[PHAsset], Error>?

    init(_ continuation: CheckedContinuation<[PHAsset], Error>) {
        self.continuation = continuation
    }

    func resume(returning assets: [PHAsset]) {
        guard let continuation = continuation else { return }
        self.continuation = nil
        continuation.resume(returning: assets)
    }

    func resume(throwing error: Error) {
        guard let continuation = continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: error)
    }
}

final class PhotosPickerViewController: UIViewController {

    enum Mode {
        case picker(maxCount: Int)
        case previewOnly
    }

    struct Configuration {
        let mode: Mode
        let groupByDate: Bool
        let columnCount: Int
    }

    var onFinish: (([PHAsset]) -> Void)?
    var onCancel: (() -> Void)?

    private let configuration: Configuration
    private let imageManager = PHCachingImageManager()
    private var collectionView: UICollectionView!
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    private let messageLabel = UILabel()
    private var doneButton: UIBarButtonItem?

    private var sections: [PhotosAssetSection] = []
    private var assets: [PHAsset] = []
    private var assetsByIdentifier: [String: PHAsset] = [:]
    private var selectionState: PhotosSelectionState
    private var loadTask: Task<Void, Never>?
    private var activePreviewTransition: PhotosHeroTransitionController?

    private var isSelectionEnabled: Bool {
        if case .picker = configuration.mode {
            return true
        }
        return false
    }

    init(configuration: Configuration) {
        self.configuration = configuration
        switch configuration.mode {
        case .picker(let maxCount):
            selectionState = PhotosSelectionState(maxCount: maxCount)
        case .previewOnly:
            selectionState = PhotosSelectionState(maxCount: 0)
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        configuration = .init(mode: .previewOnly, groupByDate: false, columnCount: 3)
        selectionState = PhotosSelectionState(maxCount: 0)
        super.init(coder: coder)
    }

    deinit {
        loadTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupNavigation()
        setupCollectionView()
        setupStateViews()
        loadAssets()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateThumbnailCaching()
    }

    private func setupNavigation() {
        title = isSelectionEnabled ? "Pick Assets" : "Album"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )

        guard isSelectionEnabled else { return }

        let doneButton = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(doneTapped)
        )
        doneButton.isEnabled = false
        navigationItem.rightBarButtonItem = doneButton
        self.doneButton = doneButton
    }

    private func setupCollectionView() {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 1
        layout.minimumInteritemSpacing = 1
        layout.sectionInset = UIEdgeInsets(top: 1, left: 1, bottom: 1, right: 1)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .systemBackground
        collectionView.alwaysBounceVertical = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(PhotosPickerAssetCell.self, forCellWithReuseIdentifier: PhotosPickerAssetCell.reuseIdentifier)
        collectionView.register(
            PhotosPickerSectionHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: PhotosPickerSectionHeaderView.reuseIdentifier
        )
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupStateViews() {
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.textColor = .secondaryLabel
        messageLabel.font = .preferredFont(forTextStyle: .callout)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.isHidden = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(loadingIndicator)
        view.addSubview(messageLabel)

        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            messageLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func loadAssets() {
        loadingIndicator.startAnimating()
        messageLabel.isHidden = true

        loadTask = Task { [weak self] in
            do {
                let result = try await PhotosManager.shared.fetchAssets()
                let fetchedAssets = Self.assets(from: result)

                await MainActor.run {
                    guard let self = self else { return }
                    self.loadingIndicator.stopAnimating()
                    self.assets = fetchedAssets
                    self.assetsByIdentifier = Dictionary(
                        uniqueKeysWithValues: fetchedAssets.map { ($0.localIdentifier, $0) }
                    )
                    self.sections = Self.makeSections(
                        from: fetchedAssets,
                        groupByDate: self.configuration.groupByDate
                    )
                    self.collectionView.reloadData()
                    self.messageLabel.text = fetchedAssets.isEmpty ? "No photos or videos found." : nil
                    self.messageLabel.isHidden = !fetchedAssets.isEmpty
                    self.updateDoneButton()
                }
            } catch {
                await MainActor.run {
                    guard let self = self else { return }
                    self.loadingIndicator.stopAnimating()
                    self.messageLabel.text = error.localizedDescription
                    self.messageLabel.isHidden = false
                }
            }
        }
    }

    private func updateThumbnailCaching() {
        let side = itemSideLength()
        let scale = UIScreen.main.scale
        let targetSize = CGSize(width: side * scale, height: side * scale)
        imageManager.stopCachingImagesForAllAssets()
        imageManager.startCachingImages(
            for: assets,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: nil
        )
    }

    private func selectedAssets() -> [PHAsset] {
        selectionState.selectedIdentifiers.compactMap { assetsByIdentifier[$0] }
    }

    private func updateDoneButton() {
        doneButton?.isEnabled = !selectionState.selectedIdentifiers.isEmpty
    }

    private func toggleSelection(for asset: PHAsset) -> PhotosSelectionChange {
        let change = selectionState.toggle(asset.localIdentifier)
        switch change {
        case .selected, .deselected:
            collectionView.reloadItems(at: collectionView.indexPathsForVisibleItems)
            updateDoneButton()
        case .rejectedMaximumCount:
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.warning)
        }
        return change
    }

    private func presentPreview(at indexPath: IndexPath) {
        guard let globalIndex = globalIndex(for: indexPath) else { return }

        let previewController = PhotosPreviewViewController(
            assets: assets,
            initialIndex: globalIndex,
            selectionEnabled: isSelectionEnabled,
            selectedIndexProvider: { [weak self] asset in
                self?.selectionState.selectedIndex(for: asset.localIdentifier)
            },
            selectionToggle: { [weak self] asset in
                self?.toggleSelection(for: asset) ?? .rejectedMaximumCount
            }
        )

        let transitionController = PhotosHeroTransitionController(
            assetProvider: { [weak self] index in
                self?.asset(atGlobalIndex: index)
            },
            currentIndexProvider: { [weak previewController] in
                previewController?.currentIndex ?? globalIndex
            },
            sourceFrameProvider: { [weak self] index in
                self?.heroFrameForAsset(atGlobalIndex: index)
            },
            sourceImageProvider: { [weak self] index in
                self?.heroImageForAsset(atGlobalIndex: index)
            }
        )
        previewController.heroTransitionController = transitionController
        previewController.onDismissed = { [weak self] in
            self?.activePreviewTransition = nil
            self?.collectionView.reloadItems(at: self?.collectionView.indexPathsForVisibleItems ?? [])
            self?.updateDoneButton()
        }

        activePreviewTransition = transitionController
        previewController.modalPresentationStyle = .custom
        previewController.transitioningDelegate = transitionController
        present(previewController, animated: true)
    }

    private func itemSideLength() -> CGFloat {
        let columns = CGFloat(max(1, configuration.columnCount))
        let spacing = CGFloat(max(0, Int(columns) - 1))
        let horizontalInset: CGFloat = 2
        return floor((collectionView.bounds.width - horizontalInset - spacing) / columns)
    }

    private func globalIndex(for indexPath: IndexPath) -> Int? {
        guard sections.indices.contains(indexPath.section),
              sections[indexPath.section].assets.indices.contains(indexPath.item)
        else {
            return nil
        }
        let asset = sections[indexPath.section].assets[indexPath.item]
        return assets.firstIndex { $0.localIdentifier == asset.localIdentifier }
    }

    private func indexPath(forGlobalIndex index: Int) -> IndexPath? {
        guard assets.indices.contains(index) else { return nil }
        let identifier = assets[index].localIdentifier
        for (sectionIndex, section) in sections.enumerated() {
            if let itemIndex = section.assets.firstIndex(where: { $0.localIdentifier == identifier }) {
                return IndexPath(item: itemIndex, section: sectionIndex)
            }
        }
        return nil
    }

    private func asset(atGlobalIndex index: Int) -> PHAsset? {
        guard assets.indices.contains(index) else { return nil }
        return assets[index]
    }

    private func heroFrameForAsset(atGlobalIndex index: Int) -> CGRect? {
        guard let indexPath = indexPath(forGlobalIndex: index) else { return nil }
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        collectionView.layoutIfNeeded()
        guard let cell = collectionView.cellForItem(at: indexPath) as? PhotosPickerAssetCell else {
            return nil
        }
        return cell.heroFrameInWindow()
    }

    private func heroImageForAsset(atGlobalIndex index: Int) -> UIImage? {
        guard let indexPath = indexPath(forGlobalIndex: index),
              let cell = collectionView.cellForItem(at: indexPath) as? PhotosPickerAssetCell
        else {
            return nil
        }
        return cell.thumbnailImage
    }

    @objc private func cancelTapped() {
        dismiss(animated: true) { [onCancel] in
            onCancel?()
        }
    }

    @objc private func doneTapped() {
        let assets = selectedAssets()
        dismiss(animated: true) { [onFinish] in
            onFinish?(assets)
        }
    }

    private static func assets(from result: PHFetchResult<PHAsset>) -> [PHAsset] {
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }

    private static func makeSections(from assets: [PHAsset], groupByDate: Bool) -> [PhotosAssetSection] {
        guard groupByDate else {
            return [PhotosAssetSection(title: nil, assets: assets)]
        }

        let calendar = Calendar.current
        let grouped = Dictionary(grouping: assets) { asset -> Date in
            guard let date = asset.creationDate else { return Date.distantPast }
            return calendar.startOfDay(for: date)
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        return grouped.keys.sorted(by: >).map { date in
            let title = date == Date.distantPast ? "Unknown Date" : formatter.string(from: date)
            return PhotosAssetSection(title: title, assets: grouped[date] ?? [])
        }
    }
}

extension PhotosPickerViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        sections.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].assets.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: PhotosPickerAssetCell.reuseIdentifier,
            for: indexPath
        ) as? PhotosPickerAssetCell else {
            return UICollectionViewCell()
        }

        let asset = sections[indexPath.section].assets[indexPath.item]
        let side = itemSideLength()
        let scale = UIScreen.main.scale
        cell.configure(
            with: asset,
            imageManager: imageManager,
            targetSize: CGSize(width: side * scale, height: side * scale),
            selectedIndex: selectionState.selectedIndex(for: asset.localIdentifier),
            selectionEnabled: isSelectionEnabled
        )
        cell.selectionHandler = { [weak self, weak asset] in
            guard let asset = asset else { return }
            _ = self?.toggleSelection(for: asset)
        }
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        guard kind == UICollectionView.elementKindSectionHeader,
              let header = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: PhotosPickerSectionHeaderView.reuseIdentifier,
                for: indexPath
              ) as? PhotosPickerSectionHeaderView
        else {
            return UICollectionReusableView()
        }
        header.configure(title: sections[indexPath.section].title)
        return header
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        presentPreview(at: indexPath)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let side = itemSideLength()
        return CGSize(width: side, height: side)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        referenceSizeForHeaderInSection section: Int
    ) -> CGSize {
        guard configuration.groupByDate else { return .zero }
        return CGSize(width: collectionView.bounds.width, height: 44)
    }
}

private struct PhotosAssetSection {
    let title: String?
    let assets: [PHAsset]
}

private final class PhotosPickerAssetCell: UICollectionViewCell {
    static let reuseIdentifier = "PhotosPickerAssetCell"

    private let imageView = UIImageView()
    private let selectionButton = UIButton(type: .custom)
    private let badgeLabel = PaddingLabel()

    private var representedIdentifier: String?
    var selectionHandler: (() -> Void)?

    var thumbnailImage: UIImage? {
        imageView.image
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedIdentifier = nil
        imageView.image = nil
        selectionHandler = nil
        badgeLabel.isHidden = true
    }

    func configure(
        with asset: PHAsset,
        imageManager: PHImageManager,
        targetSize: CGSize,
        selectedIndex: Int?,
        selectionEnabled: Bool
    ) {
        representedIdentifier = asset.localIdentifier
        configureSelectionButton(selectedIndex: selectedIndex, isEnabled: selectionEnabled)
        configureBadge(for: asset)

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { [weak self] image, _ in
            DispatchQueue.main.async {
                guard self?.representedIdentifier == asset.localIdentifier else { return }
                self?.imageView.image = image
            }
        }
    }

    func heroFrameInWindow() -> CGRect {
        imageView.convert(imageView.bounds, to: nil)
    }

    private func setupView() {
        backgroundColor = .secondarySystemBackground
        clipsToBounds = true

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false

        selectionButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        selectionButton.setTitleColor(.white, for: .normal)
        selectionButton.layer.cornerRadius = 14
        selectionButton.layer.borderColor = UIColor.white.cgColor
        selectionButton.layer.borderWidth = 1.5
        selectionButton.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        selectionButton.addTarget(self, action: #selector(selectionButtonTapped), for: .touchUpInside)
        selectionButton.translatesAutoresizingMaskIntoConstraints = false

        badgeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        badgeLabel.textColor = .white
        badgeLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        badgeLabel.layer.cornerRadius = 4
        badgeLabel.clipsToBounds = true
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(imageView)
        contentView.addSubview(badgeLabel)
        contentView.addSubview(selectionButton)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            selectionButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            selectionButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            selectionButton.widthAnchor.constraint(equalToConstant: 28),
            selectionButton.heightAnchor.constraint(equalToConstant: 28),

            badgeLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            badgeLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            badgeLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 20)
        ])
    }

    private func configureSelectionButton(selectedIndex: Int?, isEnabled: Bool) {
        selectionButton.isHidden = !isEnabled
        guard isEnabled else { return }

        if let selectedIndex = selectedIndex {
            selectionButton.setTitle("\(selectedIndex)", for: .normal)
            selectionButton.backgroundColor = tintColor
            selectionButton.layer.borderWidth = 0
        } else {
            selectionButton.setTitle(nil, for: .normal)
            selectionButton.backgroundColor = UIColor.black.withAlphaComponent(0.25)
            selectionButton.layer.borderWidth = 1.5
        }
    }

    private func configureBadge(for asset: PHAsset) {
        if asset.mediaType == .video {
            badgeLabel.text = "▶ \(Self.formattedDuration(asset.duration))"
            badgeLabel.isHidden = false
        } else if asset.mediaSubtypes.contains(.photoLive) {
            badgeLabel.text = "LIVE"
            badgeLabel.isHidden = false
        } else {
            badgeLabel.isHidden = true
        }
    }

    @objc private func selectionButtonTapped() {
        selectionHandler?()
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        guard duration.isFinite else { return "0:00" }
        let totalSeconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

private final class PhotosPickerSectionHeaderView: UICollectionReusableView {
    static let reuseIdentifier = "PhotosPickerSectionHeaderView"

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func configure(title: String?) {
        label.text = title
    }
}

private final class PhotosPreviewViewController: UIViewController {

    private let assets: [PHAsset]
    private let initialIndex: Int
    private let selectionEnabled: Bool
    private let selectedIndexProvider: (PHAsset) -> Int?
    private let selectionToggle: (PHAsset) -> PhotosSelectionChange

    private var collectionView: UICollectionView!
    private let chromeView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterialDark))
    private let closeButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let selectionButton = UIButton(type: .custom)
    private var didScrollToInitialIndex = false
    private var interactiveDismissal: UIPercentDrivenInteractiveTransition?

    var heroTransitionController: PhotosHeroTransitionController?
    var onDismissed: (() -> Void)?
    private(set) var currentIndex: Int

    init(
        assets: [PHAsset],
        initialIndex: Int,
        selectionEnabled: Bool,
        selectedIndexProvider: @escaping (PHAsset) -> Int?,
        selectionToggle: @escaping (PHAsset) -> PhotosSelectionChange
    ) {
        self.assets = assets
        self.initialIndex = initialIndex
        self.currentIndex = initialIndex
        self.selectionEnabled = selectionEnabled
        self.selectedIndexProvider = selectedIndexProvider
        self.selectionToggle = selectionToggle
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        assets = []
        initialIndex = 0
        currentIndex = 0
        selectionEnabled = false
        selectedIndexProvider = { _ in nil }
        selectionToggle = { _ in .rejectedMaximumCount }
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCollectionView()
        setupChrome()
        setupDismissGesture()
        updateChrome()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !didScrollToInitialIndex, assets.indices.contains(initialIndex) else { return }
        didScrollToInitialIndex = true
        collectionView.scrollToItem(
            at: IndexPath(item: initialIndex, section: 0),
            at: .centeredHorizontally,
            animated: false
        )
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            onDismissed?()
        }
    }

    private func setupCollectionView() {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .black
        collectionView.isPagingEnabled = true
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(PhotosPreviewPageCell.self, forCellWithReuseIdentifier: PhotosPreviewPageCell.reuseIdentifier)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupChrome() {
        chromeView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(chromeView)

        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .white
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        selectionButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        selectionButton.setTitleColor(.white, for: .normal)
        selectionButton.layer.cornerRadius = 15
        selectionButton.layer.borderColor = UIColor.white.cgColor
        selectionButton.layer.borderWidth = 1.5
        selectionButton.addTarget(self, action: #selector(selectionTapped), for: .touchUpInside)
        selectionButton.translatesAutoresizingMaskIntoConstraints = false

        chromeView.contentView.addSubview(closeButton)
        chromeView.contentView.addSubview(titleLabel)
        chromeView.contentView.addSubview(selectionButton)

        NSLayoutConstraint.activate([
            chromeView.topAnchor.constraint(equalTo: view.topAnchor),
            chromeView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chromeView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chromeView.heightAnchor.constraint(equalToConstant: 88),

            closeButton.leadingAnchor.constraint(equalTo: chromeView.contentView.leadingAnchor, constant: 12),
            closeButton.bottomAnchor.constraint(equalTo: chromeView.contentView.bottomAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            titleLabel.centerXAnchor.constraint(equalTo: chromeView.contentView.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),

            selectionButton.trailingAnchor.constraint(equalTo: chromeView.contentView.trailingAnchor, constant: -20),
            selectionButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            selectionButton.widthAnchor.constraint(equalToConstant: 30),
            selectionButton.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    private func setupDismissGesture() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    private func updateChrome() {
        titleLabel.text = assets.isEmpty ? "" : "\(currentIndex + 1) / \(assets.count)"
        selectionButton.isHidden = !selectionEnabled || !assets.indices.contains(currentIndex)
        guard selectionEnabled, assets.indices.contains(currentIndex) else { return }

        let asset = assets[currentIndex]
        if let selectedIndex = selectedIndexProvider(asset) {
            selectionButton.setTitle("\(selectedIndex)", for: .normal)
            selectionButton.backgroundColor = view.tintColor
            selectionButton.layer.borderWidth = 0
        } else {
            selectionButton.setTitle(nil, for: .normal)
            selectionButton.backgroundColor = UIColor.black.withAlphaComponent(0.25)
            selectionButton.layer.borderWidth = 1.5
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func selectionTapped() {
        guard assets.indices.contains(currentIndex) else { return }
        _ = selectionToggle(assets[currentIndex])
        updateChrome()
    }

    @objc private func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)
        let progress = min(max(translation.y / max(view.bounds.height, 1), 0), 1)

        switch gesture.state {
        case .began:
            interactiveDismissal = heroTransitionController?.beginInteractiveDismissal()
            dismiss(animated: true)
        case .changed:
            interactiveDismissal?.update(progress)
        case .ended, .cancelled, .failed:
            if progress > 0.22 || velocity.y > 900 {
                interactiveDismissal?.finish()
            } else {
                interactiveDismissal?.cancel()
            }
            heroTransitionController?.clearInteractiveDismissal()
            interactiveDismissal = nil
        default:
            break
        }
    }
}

extension PhotosPreviewViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        assets.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: PhotosPreviewPageCell.reuseIdentifier,
            for: indexPath
        ) as? PhotosPreviewPageCell else {
            return UICollectionViewCell()
        }
        cell.configure(with: assets[indexPath.item])
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        collectionView.bounds.size
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateCurrentIndex(from: scrollView)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        updateCurrentIndex(from: scrollView)
    }

    private func updateCurrentIndex(from scrollView: UIScrollView) {
        guard scrollView.bounds.width > 0 else { return }
        let index = Int(round(scrollView.contentOffset.x / scrollView.bounds.width))
        currentIndex = min(max(index, 0), max(assets.count - 1, 0))
        updateChrome()
    }
}

extension PhotosPreviewViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        return velocity.y > abs(velocity.x) && velocity.y > 0
    }
}

private final class PhotosPreviewPageCell: UICollectionViewCell {
    static let reuseIdentifier = "PhotosPreviewPageCell"

    private let previewView = PhotosPreview()

    override init(frame: CGRect) {
        super.init(frame: frame)
        previewView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(previewView)
        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: contentView.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        previewView.prepareForReuse()
    }

    func configure(with asset: PHAsset) {
        previewView.configure(with: asset)
    }
}

private final class PhotosHeroTransitionController: NSObject, UIViewControllerTransitioningDelegate {
    private let assetProvider: (Int) -> PHAsset?
    private let currentIndexProvider: () -> Int
    private let sourceFrameProvider: (Int) -> CGRect?
    private let sourceImageProvider: (Int) -> UIImage?
    private var interactiveDismissal: UIPercentDrivenInteractiveTransition?

    init(
        assetProvider: @escaping (Int) -> PHAsset?,
        currentIndexProvider: @escaping () -> Int,
        sourceFrameProvider: @escaping (Int) -> CGRect?,
        sourceImageProvider: @escaping (Int) -> UIImage?
    ) {
        self.assetProvider = assetProvider
        self.currentIndexProvider = currentIndexProvider
        self.sourceFrameProvider = sourceFrameProvider
        self.sourceImageProvider = sourceImageProvider
        super.init()
    }

    func beginInteractiveDismissal() -> UIPercentDrivenInteractiveTransition {
        let transition = UIPercentDrivenInteractiveTransition()
        transition.completionCurve = .easeOut
        interactiveDismissal = transition
        return transition
    }

    func clearInteractiveDismissal() {
        interactiveDismissal = nil
    }

    func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        PhotosHeroAnimator(
            isPresenting: true,
            assetProvider: assetProvider,
            currentIndexProvider: currentIndexProvider,
            sourceFrameProvider: sourceFrameProvider,
            sourceImageProvider: sourceImageProvider
        )
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        PhotosHeroAnimator(
            isPresenting: false,
            assetProvider: assetProvider,
            currentIndexProvider: currentIndexProvider,
            sourceFrameProvider: sourceFrameProvider,
            sourceImageProvider: sourceImageProvider
        )
    }

    func interactionControllerForDismissal(
        using animator: UIViewControllerAnimatedTransitioning
    ) -> UIViewControllerInteractiveTransitioning? {
        interactiveDismissal
    }
}

private final class PhotosHeroAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let isPresenting: Bool
    private let assetProvider: (Int) -> PHAsset?
    private let currentIndexProvider: () -> Int
    private let sourceFrameProvider: (Int) -> CGRect?
    private let sourceImageProvider: (Int) -> UIImage?

    init(
        isPresenting: Bool,
        assetProvider: @escaping (Int) -> PHAsset?,
        currentIndexProvider: @escaping () -> Int,
        sourceFrameProvider: @escaping (Int) -> CGRect?,
        sourceImageProvider: @escaping (Int) -> UIImage?
    ) {
        self.isPresenting = isPresenting
        self.assetProvider = assetProvider
        self.currentIndexProvider = currentIndexProvider
        self.sourceFrameProvider = sourceFrameProvider
        self.sourceImageProvider = sourceImageProvider
        super.init()
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        0.32
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        isPresenting ? animatePresentation(using: transitionContext) : animateDismissal(using: transitionContext)
    }

    private func animatePresentation(using transitionContext: UIViewControllerContextTransitioning) {
        guard let toView = transitionContext.view(forKey: .to) else {
            transitionContext.completeTransition(false)
            return
        }

        let container = transitionContext.containerView
        let index = currentIndexProvider()
        let sourceFrame = convertedSourceFrame(for: index, in: container)
        let destinationFrame = mediaFrame(for: index, in: container.bounds)
        let imageView = transitionImageView(for: index, frame: sourceFrame)

        toView.frame = transitionContext.finalFrame(for: transitionContext.viewController(forKey: .to) ?? UIViewController())
        toView.alpha = 0
        container.addSubview(toView)
        container.addSubview(imageView)

        UIView.animate(
            withDuration: transitionDuration(using: transitionContext),
            delay: 0,
            usingSpringWithDamping: 0.92,
            initialSpringVelocity: 0,
            options: [.curveEaseOut, .allowUserInteraction],
            animations: {
                imageView.frame = destinationFrame
                imageView.contentMode = .scaleAspectFit
                toView.alpha = 1
            },
            completion: { finished in
                imageView.removeFromSuperview()
                transitionContext.completeTransition(finished && !transitionContext.transitionWasCancelled)
            }
        )
    }

    private func animateDismissal(using transitionContext: UIViewControllerContextTransitioning) {
        guard let fromView = transitionContext.view(forKey: .from) else {
            transitionContext.completeTransition(false)
            return
        }

        let container = transitionContext.containerView
        let index = currentIndexProvider()
        let sourceFrame = mediaFrame(for: index, in: container.bounds)
        let destinationFrame = convertedSourceFrame(for: index, in: container)
        let imageView = transitionImageView(for: index, frame: sourceFrame)

        if let toView = transitionContext.view(forKey: .to) {
            toView.frame = transitionContext.finalFrame(for: transitionContext.viewController(forKey: .to) ?? UIViewController())
            container.insertSubview(toView, belowSubview: fromView)
        }
        container.addSubview(imageView)

        UIView.animate(
            withDuration: transitionDuration(using: transitionContext),
            delay: 0,
            options: [.curveEaseInOut, .allowUserInteraction],
            animations: {
                imageView.frame = destinationFrame
                imageView.contentMode = .scaleAspectFill
                fromView.alpha = 0
            },
            completion: { _ in
                let completed = !transitionContext.transitionWasCancelled
                imageView.removeFromSuperview()
                fromView.alpha = 1
                if completed {
                    fromView.removeFromSuperview()
                }
                transitionContext.completeTransition(completed)
            }
        )
    }

    private func convertedSourceFrame(for index: Int, in container: UIView) -> CGRect {
        guard let sourceFrame = sourceFrameProvider(index) else {
            return CGRect(x: container.bounds.midX, y: container.bounds.midY, width: 1, height: 1)
        }
        return container.convert(sourceFrame, from: nil)
    }

    private func mediaFrame(for index: Int, in bounds: CGRect) -> CGRect {
        guard let asset = assetProvider(index) else { return bounds }
        let pixelWidth = CGFloat(max(asset.pixelWidth, 1))
        let pixelHeight = CGFloat(max(asset.pixelHeight, 1))
        let scale = min(bounds.width / pixelWidth, bounds.height / pixelHeight)
        let size = CGSize(width: pixelWidth * scale, height: pixelHeight * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func transitionImageView(for index: Int, frame: CGRect) -> UIImageView {
        let imageView = UIImageView(image: sourceImageProvider(index))
        imageView.backgroundColor = .black
        imageView.contentMode = isPresenting ? .scaleAspectFill : .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.frame = frame
        return imageView
    }
}

private final class PaddingLabel: UILabel {
    var textInsets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + textInsets.left + textInsets.right,
            height: size.height + textInsets.top + textInsets.bottom
        )
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: textInsets))
    }
}

private extension UIViewController {
    static func photosTopViewController(base: UIViewController? = UIApplication.shared.photosKeyWindow?.rootViewController) -> UIViewController? {
        if let navigationController = base as? UINavigationController {
            return photosTopViewController(base: navigationController.visibleViewController)
        }
        if let tabBarController = base as? UITabBarController {
            return photosTopViewController(base: tabBarController.selectedViewController)
        }
        if let presentedController = base?.presentedViewController {
            return photosTopViewController(base: presentedController)
        }
        return base
    }
}

private extension UIApplication {
    var photosKeyWindow: UIWindow? {
        for scene in connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return keyWindow
            }
        }
        return nil
    }
}
