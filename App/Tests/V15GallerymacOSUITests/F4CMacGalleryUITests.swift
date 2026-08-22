import XCTest

@MainActor final class F4CMacGalleryUITests: XCTestCase {
    func testArchiveConfirmationNativeSaveAndDisabledRestore() {
        let app = launchGalleryMac(["--v15-f4c-route", "archive"])
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["v15.f4c.security.macos"].waitForExistence(timeout: 10))
        app.secureTextFields["v15.f4c.password"].click(); app.secureTextFields["v15.f4c.password"].typeText("synthetic-password-123")
        app.secureTextFields["v15.f4c.password-confirmation"].click(); app.secureTextFields["v15.f4c.password-confirmation"].typeText("synthetic-password-123")
        app.buttons["v15.f4c.export"].click()
        XCTAssertTrue(app.buttons["v15.f4c.confirm"].waitForExistence(timeout: 5))
        app.buttons["v15.f4c.confirm"].click()
        XCTAssertTrue(any["v15.f4c.handoff"].waitForExistence(timeout: 6))
        app.buttons["v15.f4c.handoff"].click()
        XCTAssertTrue(any["v15.f4c.success"].waitForExistence(timeout: 6))
        XCTAssertFalse(app.buttons["v15.f4c.restore-disabled"].isEnabled)
        app.terminate()
    }
    func testUnknownAndOfflineHaveNoSuccess() {
        let unknown = launchGalleryMac(["--v15-f4c-route", "archive-unknown"])
        XCTAssertTrue(unknown.descendants(matching: .any)["v15.f4c.security.macos"].waitForExistence(timeout: 10))
        unknown.secureTextFields["v15.f4c.password"].click(); unknown.secureTextFields["v15.f4c.password"].typeText("synthetic-password-123")
        unknown.secureTextFields["v15.f4c.password-confirmation"].click(); unknown.secureTextFields["v15.f4c.password-confirmation"].typeText("synthetic-password-123")
        unknown.buttons["v15.f4c.export"].click(); unknown.buttons["v15.f4c.confirm"].click()
        XCTAssertTrue(unknown.descendants(matching: .any)["v15.f4c.unknown"].waitForExistence(timeout: 6))
        unknown.terminate()
        let offline = launchGalleryMac(["--v15-f4c-route", "archive-offline"])
        XCTAssertTrue(offline.descendants(matching: .any)["v15.f4c.security.macos"].waitForExistence(timeout: 10))
        XCTAssertFalse(offline.buttons["v15.f4c.export"].isEnabled); offline.terminate()
    }
    func testFailureAndUnknownExposeExplicitResetActions() {
        let failed = launchGalleryMac(["--v15-f4c-route", "archive-error"])
        XCTAssertTrue(failed.descendants(matching: .any)["v15.f4c.security.macos"].waitForExistence(timeout: 10))
        failed.secureTextFields["v15.f4c.password"].click(); failed.secureTextFields["v15.f4c.password"].typeText("synthetic-password-123")
        failed.secureTextFields["v15.f4c.password-confirmation"].click(); failed.secureTextFields["v15.f4c.password-confirmation"].typeText("synthetic-password-123")
        failed.buttons["v15.f4c.export"].click(); failed.buttons["v15.f4c.confirm"].click()
        XCTAssertTrue(failed.buttons["v15.f4c.retry"].waitForExistence(timeout: 6)); XCTAssertTrue(failed.buttons["v15.f4c.close"].exists)
        failed.terminate()
    }
}
