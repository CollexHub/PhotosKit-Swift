Pod::Spec.new do |s|
  s.name = 'PhotosKit-Swift'
  s.version = '0.1.0'
  s.summary = 'A lightweight Swift wrapper around Photos framework APIs.'
  s.description = <<-DESC
PhotosKit-Swift provides async Swift helpers for requesting photo library
permissions, fetching assets and albums, requesting images, live photos, and
videos, and saving or deleting photo library assets.
  DESC

  s.homepage = 'https://github.com/CollexHub/PhotosKit-Swift'
  s.license = { :type => 'MIT', :file => 'LICENSE' }
  s.author = { 'maojiu' => 'maojiu-bb@outlook.com' }
  s.source = { :git => 'https://github.com/CollexHub/PhotosKit-Swift.git', :tag => s.version.to_s }

  s.ios.deployment_target = '15.0'
  s.swift_version = '5.0'
  s.module_name = 'PhotosKit_Swift'
  s.source_files = 'Sources/PhotosKit-Swift/**/*.swift'
  s.frameworks = 'AVFoundation', 'Photos', 'PhotosUI', 'UIKit'
end
