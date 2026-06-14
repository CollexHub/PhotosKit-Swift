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
import Combine

final class PhotosPreview {

    static func show(_ groupByDate: Bool = false) {
        guard let topVC = UIApplication.shared.topViewController() else {
            return
        }
        let vc = PhotosPreviewViewController(groupByDate)
        vc.modalPresentationStyle = .fullScreen
        topVC.present(vc, animated: true)
    }

}

struct AlbumsPreviewInfo {
    let id = UUID()
    let title: String?
    let lastAsset: PHAsset?
    let count: Int
    let album: PHAssetCollection
}

final class PhotosPreviewViewModel: ObservableObject {

    private var albums: [PHAssetCollection] = []

    @Published private(set) var albumsPreviewInfo: [AlbumsPreviewInfo] = []
    @Published private(set) var selectedAlbum: PHAssetCollection? = nil
    @Published private(set) var assets: [PHAsset] = []

    init() {
        fetchAlbums()
        fetchAssets()
        fetchAlbumsPreviewInfo()
    }

    func fetchAlbums() {
        Task {
            guard try await PhotosManager.shared.checkPermission() else { return }
            let albums = try await PhotosManager.shared.fetchAlbums()
            self.albums = albums
        }
    }

    func fetchAssets() {
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

    func fetchAlbumsPreviewInfo() {
        Task {
            guard try await PhotosManager.shared.checkPermission() else { return }
            let albums = try await PhotosManager.shared.fetchAlbums()
            var infos: [AlbumsPreviewInfo] = []
            for album in albums {
                let assets = try await PhotosManager.shared.fetchAssets(in: album)
                if assets.count <= 0 {
                    continue
                }
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

    func changeSelectedAlbum(_ album: PHAssetCollection) {
        self.selectedAlbum = album
        fetchAssets()
    }

}

final class PhotosPreviewViewController: UIViewController {

    private let vm = PhotosPreviewViewModel()

    private var cancellables = Set<AnyCancellable>()

    private var groupByDate: Bool = false

    private var isAlbumSheetShown = false

    private var albumSheetHeightConstraint: NSLayoutConstraint!

    private let topBarLeadingSpacer = UIView()

    private let topBarTrailingSpacer = UIView()

    private let topBarBalanceSpacer = UIView()

    init(_ groupByDate: Bool) {
        self.groupByDate = groupByDate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

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

    private lazy var topBarView: UIStackView = {
        let stackView = UIStackView(arrangedSubviews: [
            closeButton,
            topBarLeadingSpacer,
            albumButton,
            topBarTrailingSpacer,
            topBarBalanceSpacer
        ])
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 0
        return stackView
    }()

    private lazy var overlayStackView: UIStackView = {
        let stackView = UIStackView(arrangedSubviews: [
            topBarView
        ])
        stackView.axis = .vertical
        stackView.alignment = .fill
        return stackView
    }()

    private lazy var assetCollectionView: AssetCollectionView = {
        let collectionView = AssetCollectionView()
        collectionView.setContentInset(
            UIEdgeInsets(top: 88, left: 0, bottom: 24, right: 0),
            resetContentOffset: true
        )
        collectionView.config(assets: vm.assets, groupByDate: groupByDate) { [weak self] asset in
            self?.presentAssetPreview(asset)
        }
        return collectionView
    }()

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
        tableView.register(AlbumSheetCell.self, forCellReuseIdentifier: AlbumSheetCell.reuseId)
        return tableView
    }()

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
        closeButton.addTarget(self, action: #selector(didTapClosePreview), for: .touchUpInside)
        albumButton.addTarget(self, action: #selector(didTapAlbumSelector), for: .touchUpInside)
    }

    private func setupLayout() {
        assetCollectionView.translatesAutoresizingMaskIntoConstraints = false
        albumDismissButton.translatesAutoresizingMaskIntoConstraints = false
        overlayStackView.translatesAutoresizingMaskIntoConstraints = false
        topBarView.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        albumButton.translatesAutoresizingMaskIntoConstraints = false
        topBarLeadingSpacer.translatesAutoresizingMaskIntoConstraints = false
        topBarTrailingSpacer.translatesAutoresizingMaskIntoConstraints = false
        topBarBalanceSpacer.translatesAutoresizingMaskIntoConstraints = false
        albumSheetView.translatesAutoresizingMaskIntoConstraints = false

        albumSheetHeightConstraint = albumSheetView.heightAnchor.constraint(equalToConstant: 0)

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

            albumButton.heightAnchor.constraint(equalToConstant: 45),
            albumButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            albumButton.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -140),

            topBarLeadingSpacer.widthAnchor.constraint(equalTo: topBarTrailingSpacer.widthAnchor),
            topBarBalanceSpacer.widthAnchor.constraint(equalToConstant: 45),

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
                self.assetCollectionView.config(assets: assets, groupByDate: self.groupByDate) { [weak self] asset in
                    self?.presentAssetPreview(asset)
                }
            }
            .store(in: &cancellables)

        vm.$albumsPreviewInfo
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.albumSheetView.reloadData()
            }
            .store(in: &cancellables)
    }

}

extension PhotosPreviewViewController {

    @objc
    private func didTapClosePreview() {
        self.dismiss(animated: true)
    }

    @objc
    private func didTapAlbumSelector() {
        isAlbumSheetShown ? hideAlbumSheet() : showAlbumSheet()
    }

    @objc
    private func didTapAlbumDismissArea() {
        hideAlbumSheet()
    }

    private func presentAssetPreview(_ asset: PHAsset) {
        if isAlbumSheetShown {
            hideAlbumSheet()
        }

        let previewController = AssetPreviewViewController(
            assets: vm.assets,
            currentAsset: asset,
            sourceViewProvider: { [weak self] asset in
                self?.assetCollectionView.sourceView(for: asset, ensureVisible: true)
            },
            sourceImageProvider: { [weak self] asset in
                self?.assetCollectionView.sourceImage(for: asset)
            },
            onAssetsChanged: { [weak self] in
                self?.vm.fetchAssets()
            }
        )
        present(previewController, animated: true)
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

extension PhotosPreviewViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        vm.albumsPreviewInfo.count
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {

        let cell = tableView.dequeueReusableCell(
            withIdentifier: AlbumSheetCell.reuseId,
            for: indexPath
        ) as! AlbumSheetCell

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

private final class AlbumSheetCell: UITableViewCell {

    static let reuseId = "AlbumSheetCell"

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
        titleLabel.text = item.title ?? "Unknow Album"
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
