import XCTest

final class F3GMacGalleryUITests: XCTestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    func testStatementImportWorkbenchBuildsForAutomation() {
        let app = launchGalleryMac(["--v15-f3g-route", "statement-import"])
        XCTAssertTrue(element(app, "v15.f3g.statement-import.macos").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "v15.f3g.mac.intake").exists)
        XCTAssertTrue(element(app, "v15.f3g.mac.workbench").exists)
        XCTAssertTrue(element(app, "v15.f3g.mac.inspector").exists)
        let preview = app.buttons["v15.f3g.mac.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5)); preview.click()
        XCTAssertTrue(element(app, "v15.f3g.mac.confirmation").waitForExistence(timeout: 5))
        app.terminate()
    }

    func testEmptySelectionReasonHasOneVisibleOwner() {
        let app = launchGalleryMac(["--v15-f3g-route", "statement-import"])
        XCTAssertTrue(element(app, "v15.f3g.statement-import.macos").waitForExistence(timeout: 10))
        let toggle = element(app, "v15.f3g.mac.select.00000000-0000-0000-0000-000000007305")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()
        let reason = element(app, "v15.f3g.mac.preview-inspector.reason")
        XCTAssertTrue(reason.waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "v15.f3g.mac.preview-inspector.reason").count, 1)
        XCTAssertFalse(app.buttons["v15.f3g.mac.preview"].isEnabled)
        XCTAssertFalse(app.buttons["v15.f3g.mac.preview-inspector"].isEnabled)
        app.terminate()
    }

    func testResolutionReadbackUnknownUsesRecoveryCopyNotFailureCopy() {
        let app = launchGalleryMac(["--v15-f3g-route", "statement-import-resolution-recovery"])
        let state = element(app, "v15.f3g.mac.resolution-readback-unknown")
        XCTAssertTrue(state.waitForExistence(timeout: 14))
        XCTAssertTrue(state.label.contains("行处理结果暂时不明"), state.label)
        XCTAssertFalse(app.staticTexts["暂时无法取得数据"].exists)
        XCTAssertTrue(element(app, "v15.f3g.mac.resolution-readback-retry").isEnabled)
        app.terminate()
    }
}
