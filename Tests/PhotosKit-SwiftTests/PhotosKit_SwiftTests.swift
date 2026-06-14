import XCTest
import UIKit
@testable import PhotosKit_Swift

final class PhotosKit_SwiftTests: XCTestCase {

    func testPreviewImplementationDoesNotUseSwiftUI() throws {
        let sourceFiles = [
            "AssetPreviewView.swift",
            "AssetImageView.swift",
            "AssetLiveView.swift",
            "AssetVideoView.swift",
            "ZoomableAssetView.swift"
        ]

        for fileName in sourceFiles {
            let source = try sourceFile(named: fileName)
            XCTAssertFalse(source.contains("import SwiftUI"), fileName)
            XCTAssertFalse(source.contains("UIHostingController"), fileName)
            XCTAssertFalse(source.contains("UIViewRepresentable"), fileName)
            XCTAssertFalse(source.contains(": View"), fileName)
        }
    }

    func testPreviewZoomStateTrackerOnlyReportsZoomBoundaryChanges() {
        var tracker = PreviewZoomStateTracker()

        XCTAssertNil(tracker.update(scale: 1.0))
        XCTAssertEqual(tracker.update(scale: 1.1), true)
        XCTAssertNil(tracker.update(scale: 1.5))
        XCTAssertNil(tracker.update(scale: 2.0))
        XCTAssertEqual(tracker.update(scale: 1.0), false)
        XCTAssertNil(tracker.update(scale: 1.0))
    }

    func testPreviewDismissGestureIgnoresHorizontalPagingPan() {
        let velocity = CGPoint(x: 900, y: 80)

        XCTAssertFalse(
            PreviewDismissGesturePolicy.shouldBeginDismissPan(
                velocity: velocity,
                isZoomed: false
            )
        )
    }

    func testPreviewDismissGestureAllowsDownwardPanOnlyWhenNotZoomed() {
        let downwardVelocity = CGPoint(x: 40, y: 900)
        let downwardTranslation = CGPoint(x: 30, y: 130)

        XCTAssertTrue(
            PreviewDismissGesturePolicy.shouldBeginDismissPan(
                velocity: downwardVelocity,
                isZoomed: false
            )
        )
        XCTAssertTrue(
            PreviewDismissGesturePolicy.shouldDismiss(
                translation: downwardTranslation,
                velocity: downwardVelocity
            )
        )
        XCTAssertFalse(
            PreviewDismissGesturePolicy.shouldBeginDismissPan(
                velocity: downwardVelocity,
                isZoomed: true
            )
        )
    }

}

private func sourceFile(named name: String) throws -> String {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceURL = packageRoot
        .appendingPathComponent("Sources")
        .appendingPathComponent("PhotosKit-Swift")
        .appendingPathComponent(name)
    return try String(contentsOf: sourceURL)
}
