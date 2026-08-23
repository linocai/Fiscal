import XCTest

/// Runtime remains deferred under the shared macOS XCUITest policy. This file
/// is compiled and linked by the mac Gallery BFT; it must not be counted as a
/// runtime pass until the global runner root is repaired.
@MainActor final class F3FMacGalleryUITests: XCTestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    func testProposalSpineDetailInspectorAndReviewSheetAreReachable() {
        let app = launchGalleryMac(["--v15-f3f-route", "ai-review"])
        XCTAssertTrue(element(app, "v15.f3f.ai.macos").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "v15.f3f.spine").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "v15.f3f.detail").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "v15.f3f.inspector").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "v15.f3f.editor.sheet").waitForExistence(timeout: 8))
        app.terminate()
    }

    func testDisplayOnlyOfflineAndRecoveryRoutesAreReachable() {
        for route in ["ai-proposals", "ai-offline", "ai-response-unknown", "ai-response-unknown-read-failure", "ai-response-unknown-read-delayed", "ai-conflict", "ai-conflict-read-failure", "ai-page-error", "ai-cash-flow", "ai-server-changed", "ai-long"] {
            let app = launchGalleryMac(["--v15-f3f-route", route])
            XCTAssertTrue(element(app, "v15.f3f.ai.macos").waitForExistence(timeout: 10))
            app.terminate()
        }
    }

    func testCashFlowTargetAndPageFailureRemainRepresentable() {
        let app = launchGalleryMac(["--v15-f3f-route", "ai-cash-flow"])
        XCTAssertTrue(element(app, "v15.f3f.cash-flow.target").waitForExistence(timeout: 10))
        app.terminate()
    }

    func testStableCreateRecoveryPanelAndAccessibilityActionsAreRepresentable() {
        let app = launchGalleryMac(["--v15-f3f-route", "ai-create-unknown-settings-transport-after-safe"])
        XCTAssertTrue(element(app, "v15.f3f.unknown.create-recovery").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "v15.f3f.unknown.create-retry").exists)
        XCTAssertTrue(element(app, "v15.f3f.unknown.create-abandon").exists)
        app.terminate()
    }

    func testUnpostedProposalDeletionRequiresConfirmationAndRemovesTheItem() {
        let app = launchGalleryMac(["--v15-f3f-route", "ai-proposals"])
        XCTAssertTrue(element(app, "v15.f3f.ai.macos").waitForExistence(timeout: 10))
        let failed = element(app, "v15.f3f.proposal.00000000-0000-0000-0000-00000000F302")
        XCTAssertTrue(failed.waitForExistence(timeout: 8))
        failed.tap()
        let delete = app.buttons["v15.f3f.delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 8))
        delete.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 6))
        XCTAssertTrue(alert.staticTexts["只删除这项尚未记账的内容，不会影响账本。删除后无法恢复。"].exists)
        alert.buttons["删除"].tap()
        XCTAssertTrue(failed.waitForNonExistence(timeout: 8))
        XCTAssertTrue(element(app, "v15.f3f.success").waitForExistence(timeout: 8))
        app.terminate()
    }
}
