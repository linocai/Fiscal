import XCTest

@MainActor final class F3GGalleryUITests: XCTestCase {
    private var app = XCUIApplication()
    private func launch(_ route: String = "statement-import") { app.terminate(); app = XCUIApplication(); app.launchArguments = ["--v15-f3g-route", route, "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryLarge"]; app.launch(); XCTAssertTrue(element("v15.f3g.statement-import.ios").waitForExistence(timeout: 10)) }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
    private func button(_ id: String) -> XCUIElement { app.buttons[id] }
    private func reveal(_ id: String) -> XCUIElement { let value = element(id); for _ in 0..<12 where !value.exists { app.swipeUp() }; XCTAssertTrue(value.waitForExistence(timeout: 8), "missing \(id)"); return value }
    private func prepareReview() {
        XCTAssertTrue(reveal("v15.f3g.provider-consent").exists)
        button("v15.f3g.provider-consent").tap(); XCTAssertTrue(button("v15.f3g.provider-start").isEnabled); button("v15.f3g.provider-start").tap()
        XCTAssertTrue(reveal("v15.f3g.validation-run").exists); button("v15.f3g.validation-run").tap()
        XCTAssertTrue(reveal("v15.f3g.preview").exists)
    }
    func testSyntheticMaskedEvidenceRequestBoundReviewAndExactConfirmation() {
        launch("statement-import-provider"); prepareReview(); button("v15.f3g.page-load").tap(); XCTAssertTrue(reveal("v15.f3g.masked-page").label.contains("•"))
        button("v15.f3g.preview").tap(); XCTAssertTrue(element("v15.f3g.confirmation-sheet").waitForExistence(timeout: 8)); XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "原样提交服务器返回的行与版本")).firstMatch.exists)
        button("v15.f3g.confirm").tap(); XCTAssertTrue(element("v15.f3g.sheet-receipt").waitForExistence(timeout: 8)); button("v15.f3g.preview-dismiss").tap(); XCTAssertTrue(reveal("v15.f3g.receipt").exists)
    }
    func testResponseUnknownReadsReceiptWithoutSecondConfirm() {
        launch("statement-import-unknown"); XCTAssertTrue(reveal("v15.f3g.receipt-readback").exists); button("v15.f3g.receipt-readback").tap(); XCTAssertTrue(reveal("v15.f3g.receipt").exists)
    }
    func testUnresolvedAndOfflineDisableConfirmation() {
        launch("statement-import-unresolved"); button("v15.f3g.select.00000000-0000-0000-0000-000000007306").tap(); XCTAssertFalse(reveal("v15.f3g.preview").isEnabled)
        launch("statement-import-offline"); XCTAssertTrue(element("v15.f3g.offline").waitForExistence(timeout: 6)); XCTAssertFalse(button("v15.f3g.pick-file").isEnabled)
    }
    func testPreviewSheetOwnsLoadingFailureConflictAndRetry() {
        launch("statement-import-preview-delayed"); XCTAssertTrue(reveal("v15.f3g.preview").exists); XCTAssertTrue(button("v15.f3g.preview").isEnabled); button("v15.f3g.preview").tap()
        XCTAssertTrue(element("v15.f3g.confirmation-sheet").waitForExistence(timeout: 3))
        XCTAssertTrue(element("v15.f3g.preview-loading").waitForExistence(timeout: 3))
        XCTAssertTrue(element("v15.f3g.confirm").waitForExistence(timeout: 8))

        launch("statement-import-preview-error")
        XCTAssertTrue(element("v15.f3g.preview-failure").waitForExistence(timeout: 8)); button("v15.f3g.preview-retry").tap()
        XCTAssertTrue(element("v15.f3g.confirm").waitForExistence(timeout: 8))

        launch("statement-import-preview-conflict")
        XCTAssertTrue(element("v15.f3g.preview-failure").waitForExistence(timeout: 8)); button("v15.f3g.preview-retry").tap()
        XCTAssertTrue(element("v15.f3g.confirm").waitForExistence(timeout: 8))
    }
    func testConfirmKeepsSheetOwnedUntilDelayedRequestResolves() {
        launch("statement-import-confirm-delayed"); XCTAssertTrue(reveal("v15.f3g.preview").exists); button("v15.f3g.preview").tap()
        XCTAssertTrue(element("v15.f3g.confirm").waitForExistence(timeout: 8)); button("v15.f3g.confirm").tap()
        XCTAssertTrue(element("v15.f3g.confirming").waitForExistence(timeout: 3))
        XCTAssertFalse(button("v15.f3g.preview-dismiss").isEnabled)
        XCTAssertTrue(element("v15.f3g.sheet-receipt").waitForExistence(timeout: 8))
    }
    func testPageFailureStaysInWorkbenchAndRetriesLocally() {
        launch("statement-import-page-error")
        XCTAssertTrue(reveal("v15.f3g.page-error").exists)
        XCTAssertTrue(reveal("v15.f3g.preview").exists)
        button("v15.f3g.page-retry").tap()
        XCTAssertTrue(reveal("v15.f3g.masked-page").exists)
    }
    func testReadControlsRemainReachableWhileResolutionPUTIsInFlight() {
        launch("statement-import-resolution-delayed")
        XCTAssertTrue(reveal("v15.f3g.resolve-create.00000000-0000-0000-0000-000000007306").exists)
        button("v15.f3g.resolve-create.00000000-0000-0000-0000-000000007306").tap()
        XCTAssertFalse(reveal("v15.f3g.preview").isEnabled)
        XCTAssertTrue(reveal("v15.f3g.page-load").isEnabled)
        button("v15.f3g.page-load").tap()
        XCTAssertTrue(reveal("v15.f3g.reload-workbench").isEnabled)
        button("v15.f3g.reload-workbench").tap()
        XCTAssertTrue(reveal("v15.f3g.masked-page").exists)
        XCTAssertTrue(reveal("v15.f3g.preview").exists)
    }
    func testFilteredSecondPageResolutionRecoveryUsesGetOnlyReadbackUI() {
        launch("statement-import-resolution-recovery")
        XCTAssertTrue(reveal("v15.f3g.error").exists)
        button("v15.f3g.resolution-readback-retry").tap()
        XCTAssertTrue(reveal("v15.f3g.resolution-readback-status").label.contains("已在完整复核行中确认处理结果"))
        XCTAssertFalse(element("v15.f3g.error").exists)
    }
}
