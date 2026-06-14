//
//  BlurButton.swift
//  PhotosKit-Swift
//
//  Created by 钟钰 on 2026/6/13.
//

import Foundation
import UIKit

final class BlurButton: UIButton {
    
    private lazy var blurView: UIVisualEffectView = {
        let effect: UIVisualEffect
        if #available(iOS 26.0, *) {
            effect = UIGlassEffect(style: .clear)
        } else {
            effect = UIBlurEffect(style: .systemMaterialDark)
        }
        return UIVisualEffectView(effect: effect)
    }()
    private let iconImageView = UIImageView()
    private let contentLabel = UILabel()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
        setupEvent()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        addSubview(blurView)
        blurView.isUserInteractionEnabled = false
        blurView.contentView.backgroundColor = .black.withAlphaComponent(0.15)
        blurView.layer.cornerRadius = 20
        blurView.clipsToBounds = true
        
        addSubview(iconImageView)
        iconImageView.contentMode = .scaleAspectFit
        iconImageView.tintColor = .white
        
        addSubview(contentLabel)
        contentLabel.textColor = .white
        contentLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        contentLabel.textAlignment = .center
        contentLabel.isHidden = true
        
        blurView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        contentLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 20),
            iconImageView.heightAnchor.constraint(equalToConstant: 20),

            contentLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
            contentLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6)
        ])
        layer.cornerRadius = 20
        clipsToBounds = true
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        blurView.layer.cornerRadius = bounds.height / 2
        layer.cornerRadius = bounds.height / 2
    }
    
    private func setupEvent() {
        addTarget(self, action: #selector(touchDown), for: .touchDown)
        addTarget(self, action: #selector(touchUp), for: [.touchUpInside, .touchCancel, .touchDragExit])
    }
    
    func setImage(_ image: UIImage?) {
        contentLabel.isHidden = true
        iconImageView.isHidden = false
        iconImageView.image = image
    }
    
    func setText(_ text: String?) {
        iconImageView.isHidden = true
        contentLabel.isHidden = false
        contentLabel.text = text
    }
    
}

extension BlurButton {
    
    @objc private func touchDown() {
        UIView.animate(withDuration: 0.15, delay: 0, options: [.curveEaseOut]) {
            self.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
            self.alpha = 0.7
        }
    }
    
    @objc private func touchUp() {
        UIView.animate(withDuration: 0.2,
                       delay: 0,
                       usingSpringWithDamping: 0.5,
                       initialSpringVelocity: 3,
                       options: [.curveEaseInOut]
        ) {
            self.transform = .identity
            self.alpha = 1.0
        }
    }
    
}

