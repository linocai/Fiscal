import XCTest

final class F3AMacGalleryUITests: XCTestCase {
    func testTimelineMacSurfaceBuildsForAutomation() {
        let app = launchGalleryMac(["--v15-f3a-route", "timeline"])
        XCTAssertTrue(app.descendants(matching: .any)["v15.f3a.timeline.macos"].waitForExistence(timeout: 8))
        app.terminate()
    }
}
