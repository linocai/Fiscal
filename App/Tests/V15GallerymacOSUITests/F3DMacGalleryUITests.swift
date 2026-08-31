import XCTest

@MainActor final class F3DMacGalleryUITests: XCTestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    func testCashFlowSpineInspectorEditorsAndRecoverySurfacesAreReachable() {
        let app = launchGalleryMac(["--v15-f3d-route", "cash-flow-create"])
        XCTAssertTrue(element(app, "v15.f3d.cash-flow.macos").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "v15.f3d.mac.spine").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "v15.f3d.mac.inspector").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "v15.f3d.mac.editor").waitForExistence(timeout: 5))
        app.terminate()
    }

    func testMacCreateEntryOpensBeforeBlankDraftValidation() {
        let app = launchGalleryMac(["--v15-f3d-route", "cash-flow"])
        let open = element(app, "v15.f3d.mac.create.open")
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        XCTAssertTrue(open.isEnabled)
        open.tap()
        XCTAssertTrue(element(app, "v15.f3d.mac.editor").waitForExistence(timeout: 5))
        let submit = element(app, "v15.f3d.mac.create.submit")
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertFalse(submit.isEnabled)
        XCTAssertFalse(app.staticTexts["请填写标题。"].exists)
        XCTAssertFalse(app.staticTexts["计划金额须为正数，最多两位小数。"].exists)
        app.terminate()
    }

    func testMacUnknownConflictAndPartialRefreshCompileIntoInspector() {
        for (route, identifier) in [("cash-flow-unknown", "v15.f3d.mac.unknown"), ("cash-flow-conflict", "v15.f3d.mac.conflict"), ("cash-flow-partial-refresh", "v15.f3d.mac.fact-refresh")] {
            let app = launchGalleryMac(["--v15-f3d-route", route])
            XCTAssertTrue(element(app, "v15.f3d.cash-flow.macos").waitForExistence(timeout: 10))
            XCTAssertTrue(element(app, identifier).waitForExistence(timeout: 8))
            app.terminate()
        }
    }
}
