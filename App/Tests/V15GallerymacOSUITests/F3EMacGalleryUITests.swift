import XCTest

@MainActor final class F3EMacGalleryUITests: XCTestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    func testAccountCycleSpinesDifferenceInspectorAndEditorAreReachable() {
        let app = launchGalleryMac(["--v15-f3e-route", "reconciliation"])
        XCTAssertTrue(element(app, "v15.f3e.reconciliation.macos").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "v15.f3e.mac.target-spine").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "v15.f3e.mac.checkpoint-spine").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "v15.f3e.mac.inspector").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "v15.f3e.mac.diagnosis").waitForExistence(timeout: 8))
        app.terminate()
    }

    func testMacUnknownConflictPartialRefreshAndDisabledReasonCompileIntoInspector() {
        for (route, identifier) in [
            ("reconciliation-unknown", "v15.f3e.mac.unknown"),
            ("reconciliation-conflict", "v15.f3e.mac.conflict"),
            ("reconciliation-partial-refresh", "v15.f3e.mac.fact-refresh"),
            ("reconciliation-mutation-error", "v15.f3e.mac.mutation.error"),
            ("reconciliation-attention-disabled", "v15.f3e.mac.ignore.statement_import_failed:00000000-0000-0000-0000-00000000E342")
        ] {
            let app = launchGalleryMac(["--v15-f3e-route", route])
            XCTAssertTrue(element(app, "v15.f3e.reconciliation.macos").waitForExistence(timeout: 10))
            XCTAssertTrue(element(app, identifier).waitForExistence(timeout: 8))
            if route == "reconciliation-partial-refresh" { XCTAssertTrue(element(app, "v15.f3e.mac.fact-refresh.retry").waitForExistence(timeout: 5)) }
            app.terminate()
        }
    }
}
