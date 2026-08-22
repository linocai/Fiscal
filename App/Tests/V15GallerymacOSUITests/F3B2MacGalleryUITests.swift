import XCTest

@MainActor final class F3B2MacGalleryUITests: XCTestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    func testInstallmentSpineScheduleInspectorAndCreationSheetAreReachable() {
        let app = launchGalleryMac(["--v15-f3b2-route", "installments"])
        XCTAssertTrue(element(app, "v15.f3b2.installments.macos").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "v15.f3b2.mac.spine").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "v15.f3b2.mac.schedule").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "v15.f3b2.mac.inspector").waitForExistence(timeout: 5))
        element(app, "v15.f3b2.mac.create").click(); XCTAssertTrue(element(app, "v15.f3b2.mac.create.sheet").waitForExistence(timeout: 5)); app.terminate()
    }

    func testNoKeyUpdateAndCommandRecoveryControlsCompileIntoInspector() {
        let app = launchGalleryMac(["--v15-f3b2-route", "installments-update-unknown-confirmed"])
        XCTAssertTrue(element(app, "v15.f3b2.installments.macos").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "v15.f3b2.mac.edit.preview").waitForExistence(timeout: 5)); app.terminate()
    }
}
