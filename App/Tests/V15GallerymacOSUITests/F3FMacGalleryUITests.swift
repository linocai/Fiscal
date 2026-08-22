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
}
