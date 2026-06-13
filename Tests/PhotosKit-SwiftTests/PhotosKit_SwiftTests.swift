import XCTest
@testable import PhotosKit_Swift

final class PhotosKit_SwiftTests: XCTestCase {
    func testSelectionStateTogglesAndRespectsMaximumCount() {
        var state = PhotosSelectionState(maxCount: 2)

        XCTAssertEqual(state.toggle("asset-1"), .selected(index: 1))
        XCTAssertEqual(state.toggle("asset-2"), .selected(index: 2))
        XCTAssertEqual(state.toggle("asset-3"), .rejectedMaximumCount)
        XCTAssertEqual(state.selectedIdentifiers, ["asset-1", "asset-2"])

        XCTAssertEqual(state.toggle("asset-1"), .deselected)
        XCTAssertEqual(state.selectedIdentifiers, ["asset-2"])
        XCTAssertEqual(state.toggle("asset-3"), .selected(index: 2))
        XCTAssertEqual(state.selectedIdentifiers, ["asset-2", "asset-3"])
    }
}
