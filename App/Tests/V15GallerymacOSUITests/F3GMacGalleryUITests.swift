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
}
