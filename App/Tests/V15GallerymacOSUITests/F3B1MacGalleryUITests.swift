import XCTest

final class F3B1MacGalleryUITests: XCTestCase {
    func testCreditSpineInspectorAndScheduleEntryAreReachable() {
        let app = launchGalleryMac(["--v15-f3b1-route", "credit"])
        XCTAssertTrue(app.descendants(matching: .any)["v15.f3b1.credit.macos"].waitForExistence(timeout: 8))
        let cycle = app.descendants(matching: .any)["v15.f3b1.cycle.00000000-0000-0000-0000-00000000B321"]
        XCTAssertTrue(cycle.waitForExistence(timeout: 5)); cycle.click()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f3b1.cycle.inspector"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["v15.f3b1.schedule.open"].click()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f3b1.schedule.sheet"].waitForExistence(timeout: 5))
        app.terminate()
    }
    func testUnknownReadbackControlsCompileIntoTheMacScheduleSheet() {
        let app = launchGalleryMac(["--v15-f3b1-route", "credit-unknown-readback-old"])
        XCTAssertTrue(app.descendants(matching: .any)["v15.f3b1.credit.macos"].waitForExistence(timeout: 8))
        app.descendants(matching: .any)["v15.f3b1.schedule.open"].click()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f3b1.schedule.sheet"].waitForExistence(timeout: 5))
        app.terminate()
    }
}
