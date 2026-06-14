//
//  AssetCollectionView.swift
//  PhotosKit-Swift
//
//  Created by 钟钰 on 2026/6/13.
//

import Foundation
import UIKit
import Photos

fileprivate struct AssetSection {
    let id = UUID()
    let date: Date
    let assets: [PHAsset]
}

final class AssetCollectionView: UIView {
    
    private let gridSpacing: CGFloat = 5
    
    private var assets: [PHAsset] = []
    
    private var sections: [AssetSection] = []
    
    private var isGroupByDate = false
    
    private var onAssetTap: ((PHAsset) -> Void)?

    private var selectionProvider: ((PHAsset) -> Bool)?
    
    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.headerReferenceSize = .zero
        
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.showsVerticalScrollIndicator = false
        view.delegate = self
        view.dataSource = self
        
        view.register(AssetCell.self, forCellWithReuseIdentifier: AssetCell.ReuseId)
        view.register(
            AssetSectionHeader.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: AssetSectionHeader.ReuseId
        )
        
        return view
    }()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupView() {
        backgroundColor = .black
        addSubview(collectionView)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
            collectionView.leftAnchor.constraint(equalTo: leftAnchor),
            collectionView.rightAnchor.constraint(equalTo: rightAnchor)
        ])
    }
    
    func config(
        assets: [PHAsset],
        groupByDate: Bool = false,
        selectionProvider: ((PHAsset) -> Bool)? = nil,
        onAssetTap: ((PHAsset) -> Void)?
    ) {
        self.assets = assets
        self.isGroupByDate = groupByDate
        self.onAssetTap = onAssetTap
        self.selectionProvider = selectionProvider
        if groupByDate {
            self.sections = groupAssetByDate(assets)
        } else {
            self.sections = []
        }
        collectionView.reloadData()
    }

    func reloadSelection() {
        for cell in collectionView.visibleCells {
            guard let cell = cell as? AssetCell,
                  let indexPath = collectionView.indexPath(for: cell),
                  let asset = asset(at: indexPath)
            else { continue }
            cell.setSelected(selectionProvider?(asset) ?? false)
        }
    }
    
    func setContentInset(_ inset: UIEdgeInsets, resetContentOffset: Bool = false) {
        collectionView.contentInset = inset
        collectionView.scrollIndicatorInsets = inset
        if resetContentOffset {
            collectionView.contentOffset = CGPoint(x: -inset.left, y: -inset.top)
        }
    }
    
    func sourceView(for selectedAsset: PHAsset, ensureVisible: Bool = false) -> UIView? {
        if ensureVisible, let indexPath = indexPath(for: selectedAsset) {
            collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
            collectionView.layoutIfNeeded()
        }
        
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard asset(at: indexPath)?.localIdentifier == selectedAsset.localIdentifier else { continue }
            guard let cell = collectionView.cellForItem(at: indexPath) else { return nil }
            return (cell as? AssetCell)?.heroSourceView ?? cell
        }
        return nil
    }
    
    func sourceImage(for selectedAsset: PHAsset) -> UIImage? {
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard asset(at: indexPath)?.localIdentifier == selectedAsset.localIdentifier else { continue }
            guard let cell = collectionView.cellForItem(at: indexPath) as? AssetCell else { return nil }
            return cell.currentImage
        }
        return nil
    }
    
    private func groupAssetByDate(_ assets: [PHAsset]) -> [AssetSection] {
        let calendar = Calendar.current
        let vaildAssets = assets.compactMap { asset in
            return asset.creationDate != nil ? asset : nil
        }
        let sorted = vaildAssets.sorted { $0.creationDate ?? .distantPast > $1.creationDate ?? .distantPast }
        let grouped = Dictionary(grouping: sorted) { asset -> Date in
            let date = asset.creationDate!
            return calendar.startOfDay(for: date)
        }
        let sections = grouped.compactMap { (key, value) in
            AssetSection(date: key, assets: value)
        }.sorted { $0.date > $1.date }
        return sections
    }
    
}

extension AssetCollectionView: UICollectionViewDelegateFlowLayout {
    
    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        referenceSizeForHeaderInSection section: Int
    ) -> CGSize {
        guard isGroupByDate else { return .zero }
        return CGSize(
            width: collectionView.bounds.width,
            height: 36
        )
    }
    
    func collectionView(
        _ collectionView: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        guard let asset = asset(at: indexPath) else { return }
        onAssetTap?(asset)
    }
    
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = (collectionView.bounds.width - gridSpacing * 4) / 3
        return CGSize(width: width, height: width)
    }
    
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, insetForSectionAt section: Int) -> UIEdgeInsets {
        if isGroupByDate {
            return .init(top: gridSpacing, left: gridSpacing, bottom: 20, right: gridSpacing)
        }
        return .init(top: gridSpacing, left: gridSpacing, bottom: gridSpacing, right: gridSpacing)
    }
    
    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        minimumLineSpacingForSectionAt section: Int
    ) -> CGFloat {
        gridSpacing
    }
    
    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        minimumInteritemSpacingForSectionAt section: Int
    ) -> CGFloat {
        gridSpacing
    }
    
}

extension AssetCollectionView: UICollectionViewDataSource {
    
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        isGroupByDate ? sections.count : 1
    }
    
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        isGroupByDate ? sections[section].assets.count : assets.count
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let asset: PHAsset
        
        if isGroupByDate {
            asset = sections[indexPath.section].assets[indexPath.item]
        } else {
            asset = assets[indexPath.item]
        }
        
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: AssetCell.ReuseId, for: indexPath) as? AssetCell
        else { return UICollectionViewCell() }

        cell.configure(with: asset)
        cell.setSelected(selectionProvider?(asset) ?? false)

        return cell
    }
    
    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        guard kind == UICollectionView.elementKindSectionHeader,
              let header = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: AssetSectionHeader.ReuseId,
                for: indexPath
              ) as? AssetSectionHeader
        else { return UICollectionReusableView() }
        
        header.configure(date: sections[indexPath.section].date)
        
        return header
    }
    
}

private extension AssetCollectionView {
    
    func asset(at indexPath: IndexPath) -> PHAsset? {
        if isGroupByDate {
            guard sections.indices.contains(indexPath.section),
                  sections[indexPath.section].assets.indices.contains(indexPath.item)
            else { return nil }
            return sections[indexPath.section].assets[indexPath.item]
        }
        
        guard assets.indices.contains(indexPath.item) else { return nil }
        return assets[indexPath.item]
    }
    
    func indexPath(for asset: PHAsset) -> IndexPath? {
        if isGroupByDate {
            for (sectionIndex, section) in sections.enumerated() {
                guard let itemIndex = section.assets.firstIndex(where: { $0.localIdentifier == asset.localIdentifier }) else {
                    continue
                }
                return IndexPath(item: itemIndex, section: sectionIndex)
            }
            return nil
        }
        
        guard let itemIndex = assets.firstIndex(where: { $0.localIdentifier == asset.localIdentifier }) else {
            return nil
        }
        return IndexPath(item: itemIndex, section: 0)
    }
    
}

final class AssetCell: UICollectionViewCell {
    
    static let ReuseId: String = "AssetCell"
    
    private var representedAssetIdentifier: String?
    
    var heroSourceView: UIView {
        contentView
    }
    
    var currentImage: UIImage? {
        imageView.image
    }
    
    private lazy var imageView: UIImageView = {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.backgroundColor = .gray
        return view
    }()
    
    private lazy var livePhotoIcon: UIImageView = {
        let view = UIImageView()
        view.image = UIImage(systemName: "livephoto")
        view.tintColor = .white
        view.contentMode = .scaleAspectFit
        view.layer.cornerRadius = 6
        view.clipsToBounds = true
        view.isHidden = true
        return view
    }()
    
    private lazy var videoIcon: UIImageView = {
        let view = UIImageView()
        view.image = UIImage(systemName: "video")
        view.tintColor = .white
        view.contentMode = .scaleAspectFit
        view.layer.cornerRadius = 6
        view.clipsToBounds = true
        view.isHidden = true
        return view
    }()

    private lazy var selectionOverlay: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        view.isHidden = true
        return view
    }()

    private lazy var checkmarkView: UIImageView = {
        let config = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let view = UIImageView()
        view.image = UIImage(systemName: "checkmark", withConfiguration: config)
        view.tintColor = .white
        view.contentMode = .scaleAspectFit
        view.backgroundColor = .clear
        view.isHidden = true
        return view
    }()

    private lazy var checkmarkCircle: UIView = {
        let view = UIView()
        view.layer.borderWidth = 1.5
        view.layer.borderColor = UIColor.white.withAlphaComponent(0.8).cgColor
        view.backgroundColor = .clear
        view.isHidden = true
        view.addSubview(checkmarkView)
        return view
    }()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 12
        contentView.clipsToBounds = true
        contentView.addSubview(imageView)
        contentView.addSubview(selectionOverlay)
        contentView.addSubview(checkmarkCircle)
        imageView.addSubview(livePhotoIcon)
        imageView.addSubview(videoIcon)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        livePhotoIcon.translatesAutoresizingMaskIntoConstraints = false
        videoIcon.translatesAutoresizingMaskIntoConstraints = false
        selectionOverlay.translatesAutoresizingMaskIntoConstraints = false
        checkmarkCircle.translatesAutoresizingMaskIntoConstraints = false
        checkmarkView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leftAnchor.constraint(equalTo: leftAnchor),
            imageView.rightAnchor.constraint(equalTo: rightAnchor),
            livePhotoIcon.widthAnchor.constraint(equalToConstant: 20),
            livePhotoIcon.heightAnchor.constraint(equalToConstant: 20),
            livePhotoIcon.rightAnchor.constraint(equalTo: rightAnchor, constant: -8),
            livePhotoIcon.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            videoIcon.widthAnchor.constraint(equalToConstant: 20),
            videoIcon.heightAnchor.constraint(equalToConstant: 20),
            videoIcon.rightAnchor.constraint(equalTo: rightAnchor, constant: -8),
            videoIcon.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            selectionOverlay.topAnchor.constraint(equalTo: topAnchor),
            selectionOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            selectionOverlay.leftAnchor.constraint(equalTo: leftAnchor),
            selectionOverlay.rightAnchor.constraint(equalTo: rightAnchor),
            checkmarkCircle.widthAnchor.constraint(equalToConstant: 24),
            checkmarkCircle.heightAnchor.constraint(equalToConstant: 24),
            checkmarkCircle.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            checkmarkCircle.rightAnchor.constraint(equalTo: rightAnchor, constant: -6),
            checkmarkView.centerXAnchor.constraint(equalTo: checkmarkCircle.centerXAnchor),
            checkmarkView.centerYAnchor.constraint(equalTo: checkmarkCircle.centerYAnchor),
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        checkmarkCircle.layer.cornerRadius = checkmarkCircle.bounds.height / 2
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedAssetIdentifier = nil
        imageView.image = nil
        livePhotoIcon.isHidden = true
        videoIcon.isHidden = true
        setSelected(false)
    }

    func setSelected(_ selected: Bool) {
        selectionOverlay.isHidden = !selected
        checkmarkCircle.isHidden = !selected
        checkmarkView.isHidden = !selected
        if selected {
            checkmarkCircle.backgroundColor = UIColor.systemBlue
            checkmarkCircle.layer.borderColor = UIColor.systemBlue.cgColor
        } else {
            checkmarkCircle.backgroundColor = .clear
            checkmarkCircle.layer.borderColor = UIColor.white.withAlphaComponent(0.8).cgColor
        }
    }
    
    func configure(with asset: PHAsset) {
        representedAssetIdentifier = asset.localIdentifier
        imageView.image = nil
        
        Task { @MainActor in
            do {
                let scale = UIScreen.main.scale
                let targetSize = CGSize(
                    width: max(UIScreen.main.bounds.width * scale, CGFloat(asset.pixelWidth)),
                    height: max(UIScreen.main.bounds.height * scale, CGFloat(asset.pixelHeight))
                )
                let image = try await PhotosManager.shared.requestImage(asset: asset, size: targetSize)
                guard self.representedAssetIdentifier == asset.localIdentifier else { return }
                self.imageView.image = image
                self.livePhotoIcon.isHidden = asset.mediaSubtypes.contains(.photoLive) ? false : true
                self.videoIcon.isHidden = asset.mediaType == .video ? false : true
            } catch {
                print("Error:\(error)")
            }
        }
    }
    
}

final class AssetSectionHeader: UICollectionReusableView {
    
    static let ReuseId: String = "AssetSectionHeader"
    
    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = .white
        return label
    }()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(titleLabel)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleLabel.leftAnchor.constraint(equalTo: leftAnchor, constant: 16),
            titleLabel.rightAnchor.constraint(equalTo: rightAnchor, constant: -16),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func configure(date: Date) {
        titleLabel.text = date.formatted(.dateTime.year().month().day())
    }
    
}
