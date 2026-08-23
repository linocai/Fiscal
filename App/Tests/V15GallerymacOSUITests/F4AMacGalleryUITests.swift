import XCTest

@MainActor final class F4AMacGalleryUITests: XCTestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    private func reveal(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let value = element(app, id)
        XCTAssertTrue(value.waitForExistence(timeout: 6), "missing \(id)")
        let scroll = app.scrollViews["v15.f4a.content.scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 3), "missing report scroll surface")
        for _ in 0..<4 where !element(app, id).isHittable {
            scroll.swipeUp()
        }
        let revealed = element(app, id)
        XCTAssertTrue(revealed.isHittable, "not hittable \(id)")
        return revealed
    }

    func testReportTakeoverLensesAndSafeDrill() {
        let app = launchGalleryMac(["--v15-f4a-route", "reports-page-error"])
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["v15.f4a.reports.macos"].waitForExistence(timeout: 10))
        app.buttons["v15.f4a.lens.spending"].click()
        XCTAssertTrue(any["v15.f4a.surface.spending"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["v15.f4a.measure.personalRealized"].exists)
        reveal(app, "v15.f4a.row.category.0").click()
        XCTAssertTrue(any["v15.f4a.drill"].waitForExistence(timeout: 6))
        XCTAssertTrue(any["v15.f4a.drill.item.00000000-0000-0000-0000-00000000F404"].waitForExistence(timeout: 6))
        app.buttons["v15.f4a.drill.next"].click()
        XCTAssertTrue(any["v15.f4a.drill.page-error"].waitForExistence(timeout: 6))
        app.buttons["重试"].click()
        XCTAssertFalse(any["v15.f4a.drill.page-error"].waitForExistence(timeout: 2))
        let returnButton = app.buttons["返回报表"]
        XCTAssertTrue(returnButton.waitForExistence(timeout: 6))
        returnButton.click()
        XCTAssertTrue(any["v15.f4a.surface.spending"].waitForExistence(timeout: 6))
        app.buttons["v15.f4a.lens.cashFlow"].click()
        XCTAssertTrue(any["v15.f4a.surface.cashFlow"].waitForExistence(timeout: 6))
        XCTAssertFalse(any["v15.f4a.drill"].exists)
        app.terminate()
    }

    func testFirstPageDrillFailureRetriesCurrentOwner() {
        let app = launchGalleryMac(["--v15-f4a-route", "reports-drill-first-error"])
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["v15.f4a.reports.macos"].waitForExistence(timeout: 10))
        app.buttons["v15.f4a.lens.spending"].click()
        reveal(app, "v15.f4a.row.category.0").click()
        XCTAssertTrue(any["v15.f4a.drill.error"].waitForExistence(timeout: 6))
        app.buttons["重试"].click()
        XCTAssertTrue(any["v15.f4a.drill.item.00000000-0000-0000-0000-00000000F404"].waitForExistence(timeout: 6))
        app.terminate()
    }

    func testRevisionBoundPDFExport() {
        let app = launchGalleryMac(["--v15-f4b-route", "reports"])
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["v15.f4a.reports.macos"].waitForExistence(timeout: 10))
        element(app, "v15.f4b.export").click()
        element(app, "v15.f4b.export.pdf").click()
        XCTAssertTrue(any["v15.f4b.export.inspector"].waitForExistence(timeout: 6))
        app.buttons["v15.f4b.export.confirm"].click()
        XCTAssertTrue(any["v15.f4b.export.ready"].waitForExistence(timeout: 6))
        app.buttons["v15.f4b.export.handoff"].click()
        XCTAssertTrue(any["v15.f4b.export.success"].waitForExistence(timeout: 6))
        app.terminate()
    }

    func testLocalSaveCancelAndRetryKeepSingleWindowExportDeterministic() {
        let cancel = launchGalleryMac(["--v15-f4b-route", "reports-export-save-cancel"])
        let cancelAny = cancel.descendants(matching: .any)
        XCTAssertTrue(cancelAny["v15.f4a.reports.macos"].waitForExistence(timeout: 10))
        element(cancel, "v15.f4b.export").click()
        element(cancel, "v15.f4b.export.csv").click()
        cancel.buttons["v15.f4b.export.confirm"].click()
        XCTAssertTrue(cancelAny["v15.f4b.export.ready"].waitForExistence(timeout: 6))
        cancel.buttons["v15.f4b.export.handoff"].click()
        XCTAssertFalse(cancelAny["v15.f4b.export.inspector"].waitForExistence(timeout: 2))
        cancel.terminate()

        let retry = launchGalleryMac(["--v15-f4b-route", "reports-export-save-retry"])
        let retryAny = retry.descendants(matching: .any)
        XCTAssertTrue(retryAny["v15.f4a.reports.macos"].waitForExistence(timeout: 10))
        element(retry, "v15.f4b.export").click()
        element(retry, "v15.f4b.export.pdf").click()
        retry.buttons["v15.f4b.export.confirm"].click()
        XCTAssertTrue(retryAny["v15.f4b.export.ready"].waitForExistence(timeout: 6))
        retry.buttons["v15.f4b.export.handoff"].click()
        XCTAssertTrue(retryAny["v15.f4b.export.error"].waitForExistence(timeout: 6))
        retry.buttons["v15.f4b.export.save.retry"].click()
        XCTAssertTrue(retryAny["v15.f4b.export.success"].waitForExistence(timeout: 6))
        retry.terminate()
    }
}
