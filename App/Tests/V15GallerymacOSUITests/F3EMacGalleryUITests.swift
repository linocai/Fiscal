import XCTest

@MainActor final class F3EMacGalleryUITests: XCTestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    func testLongDiagnosisKeepsTargetAmountAndPrimaryActionReachable() {
        let app = launchGalleryMac(["--v15-f3e-route", "reconciliation-long"])
        XCTAssertTrue(element(app, "v15.f3e.reconciliation.macos").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "v15.f3e.mac.checkpoint-workspace").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "v15.f3e.mac.diagnosis-workspace").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "v15.f3e.mac.diagnosis").waitForExistence(timeout: 8))
        let amount = app.textFields["实际余额（元）"]
        let next = app.buttons["v15.f3e.mac.editor.next"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertTrue(amount.isHittable, "long diagnosis must not push the amount field out of the checkpoint workspace")
        XCTAssertTrue(next.isHittable, "long diagnosis must not push the primary action out of the checkpoint workspace")
        app.terminate()
    }

    func testMacUnknownConflictPartialRefreshAndDisabledReasonCompileIntoInspector() {
        for (route, identifier) in [
            ("reconciliation-unknown", "v15.f3e.mac.unknown"),
            ("reconciliation-conflict", "v15.f3e.mac.conflict"),
            ("reconciliation-partial-refresh", "v15.f3e.mac.fact-refresh"),
            ("reconciliation-mutation-error", "v15.f3e.mac.mutation.error"),
            ("reconciliation-attention-disabled", "v15.f3e.mac.attention.empty")
        ] {
            let app = launchGalleryMac(["--v15-f3e-route", route])
            XCTAssertTrue(element(app, "v15.f3e.reconciliation.macos").waitForExistence(timeout: 10))
            XCTAssertTrue(element(app, identifier).waitForExistence(timeout: 8))
            if route == "reconciliation-partial-refresh" { XCTAssertTrue(element(app, "v15.f3e.mac.fact-refresh.retry").waitForExistence(timeout: 5)) }
            app.terminate()
        }
    }
}
