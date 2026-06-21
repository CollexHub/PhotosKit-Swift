//
//  PhotosPicker.swift
//  PhotosKit-Swift
//
//  Created by 钟钰 on 2026/6/13.
//

import Combine
import Foundation
import Photos
import UIKit

final class PhotosPicker {

    static func show(maxCount: Int, groupByDate: Bool) async throws -> [PHAsset] {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                guard let topVC = UIApplication.shared.topViewController() else {
                    continuation.resume(returning: [])
                    return
                }
                let vc = PhotosPickerViewController(
                    maxCount: maxCount,
                    groupByDate: groupByDate,
                    onComplete: { assets in
                        continuation.resume(returning: assets)
                    }
                )
                vc.modalPresentationStyle = .fullScreen
                topVC.present(vc, animated: true)
            }
        }
    }

}

// MARK: - ViewModel

final class PhotosPickerViewModel: ObservableObject {

    private var albums: [PHAssetCollection] = []

    @Published private(set) var albumsPreviewInfo: [AlbumsPreviewInfo] = []
    @Published private(set) var selectedAlbum: PHAssetCollection? = nil
    @Published private(set) var assets: [PHAsset] = []
    @Published private(set) var selectedAssetIdentifiers: Set<String> = []

    let maxCount: Int

    init(maxCount: Int) {
        self.maxCount = max(1, maxCount)
        fetchAlbums()
        fetchAssets()
        fetchAlbumsPreviewInfo()
    }

    var selectedCount: Int {
        selectedAssetIdentifiers.count
    }

    var isAtMax: Bool {
        selectedAssetIdentifiers.count >= maxCount
    }

    func isAssetSelected(_ asset: PHAsset) -> Bool {
        selectedAssetIdentifiers.contains(asset.localIdentifier)
    }

    func toggleSelection(_ asset: PHAsset) {
        if selectedAssetIdentifiers.contains(asset.localIdentifier) {
            selectedAssetIdentifiers.remove(asset.localIdentifier)
        } else if !isAtMax {
            selectedAssetIdentifiers.insert(asset.localIdentifier)
        }
    }

    func selectedAssets() -> [PHAsset] {
        assets.filter { selectedAssetIdentifiers.contains($0.localIdentifier) }
    }

    func changeSelectedAlbum(_ album: PHAssetCollection) {
        self.selectedAlbum = album
        fetchAssets()
    }

    private func fetchAlbums() {
        Task {
            guard try await PhotosManager.shared.checkPermission() else { return }
            let albums = try await PhotosManager.shared.fetchAlbums()
            self.albums = albums
        }
    }

    private func fetchAssets() {
        Task {
            guard try await PhotosManager.shared.checkPermission() else { return }
            let result = try await PhotosManager.shared.fetchAssets(in: selectedAlbum)
            var newAssets: [PHAsset] = []
            result.enumerateObjects { asset, _, _ in
                newAssets.append(asset)
            }
            self.assets = newAssets
        }
    }

    private func fetchAlbumsPreviewInfo() {
        Task {
            guard try await PhotosManager.shared.checkPermission() else { return }
            let albums = try await PhotosManager.shared.fetchAlbums()
            var infos: [AlbumsPreviewInfo] = []
            for album in albums {
                let assets = try await PhotosManager.shared.fetchAssets(in: album)
                if assets.count <= 0 { continue }
                let item = AlbumsPreviewInfo(
                    title: album.localizedTitle,
                    lastAsset: assets.lastObject,
                    count: assets.count,
                    album: album
                )
                infos.append(item)
            }
            self.albumsPreviewInfo = infos
        }
    }

}

// MARK: - ViewController

final class PhotosPickerViewController: UIViewController {

    private let vm: PhotosPickerViewModel
    private let groupByDate: Bool
    private let onComplete: ([PHAsset]) -> Void

    private var cancellables = Set<AnyCancellable>()
    private var isAlbumSheetShown = false
    private var albumSheetHeightConstraint: NSLayoutConstraint!

    init(maxCount: Int, groupByDate: Bool, onComplete: @escaping ([PHAsset]) -> Void) {
        self.vm = PhotosPickerViewModel(maxCount: maxCount)
        self.groupByDate = groupByDate
        self.onComplete = onComplete
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Top Bar

    private lazy var closeButton: BlurButton = {
        let button = BlurButton()
        button.setImage(
            UIImage(systemName: "xmark")?.withConfiguration(
                UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
            )
        )
        return button
    }()

    private lazy var albumButton: BlurButton = {
        let button = BlurButton()
        button.setText(vm.selectedAlbum?.localizedTitle ?? "All Photos")
        return button
    }()

    private lazy var doneButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle(doneButtonText, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        button.backgroundColor = .systemBlue
        button.layer.cornerRadius = 22.5
        button.layer.masksToBounds = true
        return button
    }()

    private var doneButtonText: String {
        if vm.selectedCount > 0 {
            return "Done (\(vm.selectedCount))"
        }
        return "Done"
    }

    private lazy var topBarView: UIView = {
        let view = UIView()
        view.addSubview(closeButton)
        view.addSubview(albumButton)
        view.addSubview(doneButton)
        return view
    }()

    private lazy var overlayStackView: UIStackView = {
        let stackView = UIStackView(arrangedSubviews: [topBarView])
        stackView.axis = .vertical
        stackView.alignment = .fill
        return stackView
    }()

    // MARK: Collection View

    private lazy var assetCollectionView: AssetCollectionView = {
        let collectionView = AssetCollectionView()
        collectionView.setContentInset(
            UIEdgeInsets(top: 88, left: 0, bottom: 24, right: 0),
            resetContentOffset: true
        )
        collectionView.config(
            assets: vm.assets,
            groupByDate: groupByDate,
            selectionProvider: { [weak self] asset in
                self?.vm.isAssetSelected(asset) ?? false
            },
            onAssetTap: { [weak self] asset in
                self?.didTapAsset(asset)
            }
        )
        return collectionView
    }()

    // MARK: Album Sheet

    private lazy var albumDismissButton: UIButton = {
        let button = UIButton(type: .custom)
        button.backgroundColor = .clear
        button.alpha = 0
        button.isHidden = true
        return button
    }()

    private lazy var albumSheetView: UITableView = {
        let tableView = UITableView()
        tableView.backgroundColor = UIColor.black.withAlphaComponent(0.95)
        tableView.layer.cornerRadius = 16
        tableView.clipsToBounds = true
        tableView.alpha = 0
        tableView.isHidden = true
        tableView.separatorStyle = .none
        tableView.rowHeight = 76
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(PickerAlbumSheetCell.self, forCellReuseIdentifier: PickerAlbumSheetCell.reuseId)
        return tableView
    }()

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        setupView()
        setupLayout()
        bindVM()
    }

    private func setupView() {
        view.addSubview(assetCollectionView)
        view.addSubview(albumDismissButton)
        view.addSubview(albumSheetView)
        view.addSubview(overlayStackView)

        albumDismissButton.addTarget(self, action: #selector(didTapAlbumDismissArea), for: .touchUpInside)
        closeButton.addTarget(self, action: #selector(didTapClose), for: .touchUpInside)
        albumButton.addTarget(self, action: #selector(didTapAlbumSelector), for: .touchUpInside)
        doneButton.addTarget(self, action: #selector(didTapDone), for: .touchUpInside)
    }

    private func setupLayout() {
        assetCollectionView.translatesAutoresizingMaskIntoConstraints = false
        albumDismissButton.translatesAutoresizingMaskIntoConstraints = false
        overlayStackView.translatesAutoresizingMaskIntoConstraints = false
        topBarView.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        albumButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        albumSheetView.translatesAutoresizingMaskIntoConstraints = false

        albumSheetHeightConstraint = albumSheetView.heightAnchor.constraint(equalToConstant: 0)
        let albumButtonMinimumWidthConstraint = albumButton.widthAnchor.constraint(
            greaterThanOrEqualToConstant: 120
        )
        albumButtonMinimumWidthConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            assetCollectionView.topAnchor.constraint(equalTo: view.topAnchor),
            assetCollectionView.leftAnchor.constraint(equalTo: view.leftAnchor),
            assetCollectionView.rightAnchor.constraint(equalTo: view.rightAnchor),
            assetCollectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            albumDismissButton.topAnchor.constraint(equalTo: view.topAnchor),
            albumDismissButton.leftAnchor.constraint(equalTo: view.leftAnchor),
            albumDismissButton.rightAnchor.constraint(equalTo: view.rightAnchor),
            albumDismissButton.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            overlayStackView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 15),
            overlayStackView.leftAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leftAnchor, constant: 15),
            overlayStackView.rightAnchor.constraint(equalTo: view.safeAreaLayoutGuide.rightAnchor, constant: -15),

            topBarView.heightAnchor.constraint(equalToConstant: 45),

            albumSheetView.topAnchor.constraint(equalTo: overlayStackView.bottomAnchor, constant: 12),
            albumSheetView.leftAnchor.constraint(equalTo: view.leftAnchor),
            albumSheetView.rightAnchor.constraint(equalTo: view.rightAnchor),

            closeButton.widthAnchor.constraint(equalToConstant: 45),
            closeButton.heightAnchor.constraint(equalToConstant: 45),
            closeButton.leadingAnchor.constraint(equalTo: topBarView.leadingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),

            doneButton.heightAnchor.constraint(equalToConstant: 45),
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 70),
            doneButton.trailingAnchor.constraint(equalTo: topBarView.trailingAnchor),
            doneButton.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),

            albumButton.heightAnchor.constraint(equalToConstant: 45),
            albumButtonMinimumWidthConstraint,
            albumButton.centerXAnchor.constraint(equalTo: topBarView.centerXAnchor),
            albumButton.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            albumButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: closeButton.trailingAnchor,
                constant: 8
            ),
            albumButton.trailingAnchor.constraint(
                lessThanOrEqualTo: doneButton.leadingAnchor,
                constant: -8
            ),

            albumSheetHeightConstraint
        ])
    }

    private func bindVM() {
        vm.$selectedAlbum
            .receive(on: RunLoop.main)
            .sink { [weak self] album in
                guard let self = self else { return }
                self.albumButton.setText(album?.localizedTitle ?? "All Photos")
            }
            .store(in: &cancellables)

        vm.$assets
            .receive(on: RunLoop.main)
            .sink { [weak self] assets in
                guard let self = self else { return }
                self.assetCollectionView.config(
                    assets: assets,
                    groupByDate: self.groupByDate,
                    selectionProvider: { [weak self] asset in
                        self?.vm.isAssetSelected(asset) ?? false
                    },
                    onAssetTap: { [weak self] asset in
                        self?.didTapAsset(asset)
                    }
                )
            }
            .store(in: &cancellables)

        vm.$albumsPreviewInfo
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.albumSheetView.reloadData()
            }
            .store(in: &cancellables)

        vm.$selectedAssetIdentifiers
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.assetCollectionView.reloadSelection()
                self.doneButton.setTitle(self.doneButtonText, for: .normal)
            }
            .store(in: &cancellables)
    }

}

// MARK: - Actions

extension PhotosPickerViewController {

    @objc
    private func didTapClose() {
        dismiss(animated: true) { [weak self] in
            self?.onComplete([])
        }
    }

    @objc
    private func didTapDone() {
        let selected = vm.selectedAssets()
        dismiss(animated: true) { [weak self] in
            self?.onComplete(selected)
        }
    }

    @objc
    private func didTapAlbumSelector() {
        isAlbumSheetShown ? hideAlbumSheet() : showAlbumSheet()
    }

    @objc
    private func didTapAlbumDismissArea() {
        hideAlbumSheet()
    }

    private func didTapAsset(_ asset: PHAsset) {
        if isAlbumSheetShown {
            hideAlbumSheet()
        }

        if vm.maxCount == 1 {
            // Single selection: select and dismiss immediately
            vm.toggleSelection(asset)
            let selected = vm.selectedAssets()
            dismiss(animated: true) { [weak self] in
                self?.onComplete(selected)
            }
        } else {
            vm.toggleSelection(asset)
        }
    }

    private func showAlbumSheet() {
        isAlbumSheetShown = true
        albumDismissButton.isHidden = false
        albumSheetView.isHidden = false
        albumDismissButton.alpha = 0
        albumSheetView.alpha = 0
        albumSheetHeightConstraint.constant = 360
        view.bringSubviewToFront(albumDismissButton)
        view.bringSubviewToFront(albumSheetView)
        view.bringSubviewToFront(overlayStackView)
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseOut) {
            self.albumDismissButton.alpha = 1
            self.albumSheetView.alpha = 1
            self.view.layoutIfNeeded()
        }
    }

    private func hideAlbumSheet() {
        isAlbumSheetShown = false
        albumSheetHeightConstraint.constant = 0
        UIView.animate(
            withDuration: 0.25,
            delay: 0,
            options: .curveEaseInOut,
            animations: {
                self.albumDismissButton.alpha = 0
                self.albumSheetView.alpha = 0
                self.view.layoutIfNeeded()
            },
            completion: { _ in
                if !self.isAlbumSheetShown {
                    self.albumDismissButton.isHidden = true
                    self.albumSheetView.isHidden = true
                }
            }
        )
    }

}

// MARK: - Album Sheet DataSource & Delegate

extension PhotosPickerViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        vm.albumsPreviewInfo.count
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: PickerAlbumSheetCell.reuseId,
            for: indexPath
        ) as! PickerAlbumSheetCell

        let item = vm.albumsPreviewInfo[indexPath.row]
        cell.config(item)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = vm.albumsPreviewInfo[indexPath.row]
        vm.changeSelectedAlbum(item.album)
        hideAlbumSheet()
    }
}

// MARK: - Album Sheet Cell

private final class PickerAlbumSheetCell: UITableViewCell {

    static let reuseId = "PickerAlbumSheetCell"

    private let coverImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.backgroundColor = .darkGray
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 8
        return imageView
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.textColor = .white
        label.font = .systemFont(ofSize: 16, weight: .medium)
        return label
    }()

    private let countLabel: UILabel = {
        let label = UILabel()
        label.textColor = .lightGray
        label.font = .systemFont(ofSize: 13)
        return label
    }()

    private var representedAssetIdentifier: String?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        backgroundColor = .clear
        selectionStyle = .none

        contentView.addSubview(coverImageView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(countLabel)

        coverImageView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            coverImageView.leftAnchor.constraint(equalTo: contentView.leftAnchor, constant: 12),
            coverImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            coverImageView.widthAnchor.constraint(equalToConstant: 52),
            coverImageView.heightAnchor.constraint(equalToConstant: 52),

            titleLabel.leftAnchor.constraint(equalTo: coverImageView.rightAnchor, constant: 12),
            titleLabel.rightAnchor.constraint(equalTo: contentView.rightAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: coverImageView.topAnchor, constant: 6),

            countLabel.leftAnchor.constraint(equalTo: titleLabel.leftAnchor),
            countLabel.rightAnchor.constraint(equalTo: titleLabel.rightAnchor),
            countLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        coverImageView.image = nil
        representedAssetIdentifier = nil
    }

    func config(_ item: AlbumsPreviewInfo) {
        titleLabel.text = item.title ?? "Unknown Album"
        countLabel.text = "\(item.count)"

        guard let asset = item.lastAsset else {
            coverImageView.image = nil
            return
        }

        representedAssetIdentifier = asset.localIdentifier

        Task {
            let image = try await PhotosManager.shared.requestImage(
                asset: asset,
                size: CGSize(width: 120, height: 120),
                mode: .aspectFill
            )
            if self.representedAssetIdentifier == asset.localIdentifier {
                self.coverImageView.image = image
            }
        }
    }
}
