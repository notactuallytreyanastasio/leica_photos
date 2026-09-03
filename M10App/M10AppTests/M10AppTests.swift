import XCTest
@testable import M10App

final class M10AppTests: XCTestCase {
    @MainActor
    func testAppStateStartsDisconnected() {
        let state = AppState()
        XCTAssertEqual(state.phase, .disconnected)
        XCTAssertTrue(state.photos.isEmpty)
        XCTAssertTrue(state.visiblePhotos.isEmpty)
    }
}
