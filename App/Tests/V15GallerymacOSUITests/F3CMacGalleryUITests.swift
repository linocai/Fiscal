import XCTest

@MainActor final class F3CMacGalleryUITests: XCTestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    func testReimbursementSpineDetailAndBothEditorsAreReachable() {
        let app = launchGalleryMac(["--v15-f3c-route", "reimbursements"])
        XCTAssertTrue(element(app, "v15.f3c.reimbursements.macos").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "v15.f3c.mac.spine").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "v15.f3c.mac.detail").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "v15.f3c.mac.inspector").waitForExistence(timeout: 5))
        element(app, "v15.f3c.mac.claim.new.open").click()
        XCTAssertTrue(element(app, "v15.f3c.mac.claim.inspector").waitForExistence(timeout: 6))
        XCTAssertFalse(app.staticTexts["请填写报销标题。"].exists)
        XCTAssertFalse(app.staticTexts["请填写报销当事人。"].exists)
        XCTAssertFalse(app.staticTexts["请选择一笔垫付。"].exists)
        app.terminate()

        let receipt = launchGalleryMac(["--v15-f3c-route", "reimbursements"])
        XCTAssertTrue(element(receipt, "v15.f3c.reimbursements.macos").waitForExistence(timeout: 10))
        element(receipt, "v15.f3c.mac.receipt.open").click()
        XCTAssertTrue(element(receipt, "v15.f3c.mac.receipt.inspector").waitForExistence(timeout: 6))
        receipt.terminate()
    }

    func testMacConflictAndDisabledReasonsCompileIntoInspector() {
        let app = launchGalleryMac(["--v15-f3c-route", "reimbursements-conflict"])
        XCTAssertTrue(element(app, "v15.f3c.reimbursements.macos").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "v15.f3c.mac.receipt.inspector").waitForExistence(timeout: 6))
        XCTAssertTrue(element(app, "v15.f3c.mac.inspector.conflict").waitForExistence(timeout: 6))
        app.terminate()
    }

    func testReceiptPartialSuccessInspectorExposesRealGetOnlyRetry() {
        let app = launchGalleryMac(["--v15-f3c-route", "reimbursements-receipt-refresh-failure"])
        XCTAssertTrue(element(app, "v15.f3c.reimbursements.macos").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "v15.f3c.mac.receipt.inspector").waitForExistence(timeout: 8))
        XCTAssertTrue(element(app, "v15.f3c.mac.fact-refresh.required").waitForExistence(timeout: 8))
        let retry = element(app, "v15.f3c.mac.fact-refresh.retry")
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertTrue(retry.isEnabled)
        element(app, "v15.f3c.mac.receipt.close").click()
        XCTAssertTrue(element(app, "v15.f3c.mac.fact-refresh.retry").waitForExistence(timeout: 5))
        element(app, "v15.f3c.mac.fact-refresh.retry").click()
        XCTAssertFalse(element(app, "v15.f3c.mac.fact-refresh.required").waitForExistence(timeout: 3))
        app.terminate()
    }

    func testReceiptAndDirectUnknownOutcomesUseRecoveryCopyNotFailureCopy() {
        for (route, identifier) in [
            ("reimbursements-receipt-unknown", "v15.f3c.mac.inspector.unknown"),
            ("reimbursements-direct-readback", "v15.f3c.mac.direct.unknown"),
        ] {
            let app = launchGalleryMac(["--v15-f3c-route", route])
            let state = element(app, identifier)
            XCTAssertTrue(state.waitForExistence(timeout: 12))
            XCTAssertFalse(app.staticTexts["暂时无法取得数据"].exists)
            app.terminate()
        }
    }
}
