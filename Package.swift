// swift-tools-version:5.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PhotosKit-Swift",
    platforms: [
        .iOS("15.0"),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "PhotosKit-Swift",
            targets: ["PhotosKit-Swift"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "PhotosKit-Swift",
        ),
        .testTarget(
            name: "PhotosKit-SwiftTests",
            dependencies: ["PhotosKit-Swift"]
        )
    ],
    swiftLanguageVersions: [.v5]
)
