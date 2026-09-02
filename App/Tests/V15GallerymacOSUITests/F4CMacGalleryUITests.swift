import XCTest

@MainActor final class F4CMacGalleryUITests: XCTestCase {
    private func assertSeededCredentials(_ app: XCUIApplication) {
        XCTAssertTrue(app.secureTextFields["v15.f4c.password"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["v15.f4c.password-confirmation"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["v15.f4c.export"].isEnabled)
    }

    private func press(
        _ buttonID: String,
        in app: XCUIApplication,
        revealing expected: XCUIElement,
        timeout: TimeInterval = 6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let button = app.buttons[buttonID]
        XCTAssertTrue(button.waitForExistence(timeout: 5), file: file, line: line)
        app.activate()
        button.click()
        if !expected.waitForExistence(timeout: 1) {
            // A background macOS window may consume the first click only to
            // become key or to move focus out of a secure field. Retry only
            // after proving that the expected next state did not appear.
            button.click()
        }
        XCTAssertTrue(expected.waitForExistence(timeout: timeout), file: file, line: line)
    }

    func testArchiveConfirmationNativeSaveAndDisabledRestore() {
        let app = launchGalleryMac(["--v15-f4c-route", "archive", "--v15-f4c-seed-credentials"])
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["v15.f4c.security.macos"].waitForExistence(timeout: 10))
        assertSeededCredentials(app)
        press("v15.f4c.export", in: app, revealing: app.buttons["v15.f4c.confirm"])
        press("v15.f4c.confirm", in: app, revealing: any["v15.f4c.handoff"])
        press("v15.f4c.handoff", in: app, revealing: any["v15.f4c.success"])
        XCTAssertTrue(any["v15.f4c.restore-disabled"].exists, "恢复限制应以明确的只读边界呈现，而非占据界面的禁用大按钮")
        app.terminate()
    }
    func testUntouchedArchiveFormIsQuietAndDisabled() {
        let app = launchGalleryMac(["--v15-f4c-route", "archive"])
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["v15.f4c.security.macos"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["v15.f4c.export"].isEnabled)
        XCTAssertFalse(app.staticTexts["密码须为 12 到 128 个字符。"].exists)
        XCTAssertFalse(app.staticTexts["不可用原因：当前口令须为 8 到 128 个字符。"].exists)
        app.terminate()
    }
    func testUnknownAndOfflineHaveNoSuccess() {
        let unknown = launchGalleryMac(["--v15-f4c-route", "archive-unknown-retry", "--v15-f4c-seed-credentials"])
        let unknownAny = unknown.descendants(matching: .any)
        XCTAssertTrue(unknownAny["v15.f4c.security.macos"].waitForExistence(timeout: 10))
        assertSeededCredentials(unknown)
        press("v15.f4c.export", in: unknown, revealing: unknown.buttons["v15.f4c.confirm"])
        press("v15.f4c.confirm", in: unknown, revealing: unknownAny["v15.f4c.unknown"])
        unknown.terminate()
        let offline = launchGalleryMac(["--v15-f4c-route", "archive-offline"])
        XCTAssertTrue(offline.descendants(matching: .any)["v15.f4c.security.macos"].waitForExistence(timeout: 10))
        XCTAssertFalse(offline.buttons["v15.f4c.export"].isEnabled); offline.terminate()
    }
    func testFailureAndUnknownExposeExplicitResetActions() {
        // Snapshot-only routes start their transfer on appear. Use the
        // interactive route here so the test owns the confirmation flow.
        let failed = launchGalleryMac(["--v15-f4c-route", "archive-error-retry", "--v15-f4c-seed-credentials"])
        let failedAny = failed.descendants(matching: .any)
        XCTAssertTrue(failedAny["v15.f4c.security.macos"].waitForExistence(timeout: 10))
        assertSeededCredentials(failed)
        press("v15.f4c.export", in: failed, revealing: failed.buttons["v15.f4c.confirm"])
        press("v15.f4c.confirm", in: failed, revealing: failedAny["v15.f4c.error"])
        XCTAssertTrue(failed.buttons["v15.f4c.retry"].exists); XCTAssertTrue(failed.buttons["v15.f4c.close"].exists)
        failed.terminate()
    }
}
