import XCTest

@MainActor final class F3AMacGalleryUITests: XCTestCase {
    func testTimelineMacSurfaceBuildsAndKeepsFutureTruthExplicit() {
        let app = launchGalleryMac(["--v15-f3a-route", "timeline"])
        XCTAssertTrue(app.descendants(matching: .any)["v15.f3a.timeline.macos"].waitForExistence(timeout: 8))
        let expected = app.descendants(matching: .any)["v15.f3a.event.cash_flow_item:00000000-0000-0000-0000-00000000F303"]
        XCTAssertTrue(expected.waitForExistence(timeout: 5))
        XCTAssertTrue(expected.label.contains("预计（尚未确认）"))
        XCTAssertTrue(expected.label.contains("流出"))
        XCTAssertTrue(expected.label.contains("现金流事项"))
        XCTAssertTrue(app.descendants(matching: .any)["v15.f3a.truth-notice"].exists)
        app.terminate()
    }
}
