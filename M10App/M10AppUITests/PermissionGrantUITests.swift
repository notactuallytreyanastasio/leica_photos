import XCTest

/// One-time permission bootstrapping: launches the app with a special
/// argument that requests Photos access, then taps the system dialog.
/// After this runs once, the permission persists and the real PhotoKit
/// integration unit tests run instead of skipping.
///
/// (simctl privacy grants wouldn't bind for readWrite on this simulator —
/// this does it the way a user would.)
final class PermissionGrantUITests: XCTestCase {

    func testGrantPhotosAccessOnce() {
        let app = XCUIApplication()
        app.launchArguments.append("-m10-request-photo-access")
        app.launch()

        // system permission alerts live in SpringBoard, not the app
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let fullAccess = springboard.buttons["Allow Full Access"]
        if fullAccess.waitForExistence(timeout: 10) {
            fullAccess.tap()
        } else {
            // older phrasing / already granted — nothing to do
            let allow = springboard.buttons["Allow Access to All Photos"]
                .exists ? springboard.buttons["Allow Access to All Photos"] : nil
            allow?.tap()
        }
        // give TCC a moment to settle
        Thread.sleep(forTimeInterval: 1)
    }
}
