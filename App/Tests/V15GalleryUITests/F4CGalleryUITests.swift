import XCTest

@MainActor final class F4CGalleryUITests: XCTestCase {
    private var app = XCUIApplication()
    private func launch(_ route: String = "archive") {
        app.terminate(); app = XCUIApplication()
        app.launchArguments = ["--v15-f4c-route", route]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f4c.security.ios"].waitForExistence(timeout: 10))
    }
    private func enterPasswordAndConfirm() {
        let password = app.secureTextFields["v15.f4c.password"]
        password.tap(); password.typeText("synthetic-password-123")
        let confirmation = app.secureTextFields["v15.f4c.password-confirmation"]
        confirmation.tap(); confirmation.typeText("synthetic-password-123")
        app.buttons["v15.f4c.export"].tap()
        XCTAssertTrue(app.buttons["v15.f4c.confirm"].waitForExistence(timeout: 5))
        app.buttons["v15.f4c.confirm"].tap()
    }
    func testArchiveConfirmationTransferAndRestoreBoundary() {
        launch()
        enterPasswordAndConfirm()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f4c.handoff"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["v15.f4c.restore-disabled"].exists)
    }
    func testInvalidMetadataUnknownAndOfflineStayHonest() {
        launch("archive-bad-type")
        app.secureTextFields["v15.f4c.password"].tap(); app.secureTextFields["v15.f4c.password"].typeText("synthetic-password-123")
        app.secureTextFields["v15.f4c.password-confirmation"].tap(); app.secureTextFields["v15.f4c.password-confirmation"].typeText("synthetic-password-123")
        app.buttons["v15.f4c.export"].tap(); app.buttons["v15.f4c.confirm"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f4c.error"].waitForExistence(timeout: 6))
        launch("archive-offline")
        XCTAssertFalse(app.buttons["v15.f4c.export"].isEnabled)
    }
    func testFailedTransferRequiresExplicitResetThenNewPOST() {
        launch("archive-error-retry")
        enterPasswordAndConfirm()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f4c.error"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["v15.f4c.retry"].exists)
        XCTAssertTrue(app.buttons["v15.f4c.close"].exists)
        app.buttons["v15.f4c.retry"].tap()
        XCTAssertTrue(app.buttons["v15.f4c.export"].waitForExistence(timeout: 3))
        enterPasswordAndConfirm()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f4c.handoff"].waitForExistence(timeout: 6))
    }
    func testUnknownCanCloseThenExplicitlyRetry() {
        launch("archive-unknown-retry")
        enterPasswordAndConfirm()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f4c.unknown"].waitForExistence(timeout: 6))
        app.buttons["v15.f4c.close"].tap()
        XCTAssertTrue(app.buttons["v15.f4c.export"].waitForExistence(timeout: 3))
        enterPasswordAndConfirm()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f4c.handoff"].waitForExistence(timeout: 6))
    }
}
