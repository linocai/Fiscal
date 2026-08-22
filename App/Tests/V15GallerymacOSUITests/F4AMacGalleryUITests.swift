import XCTest

@MainActor final class F4AMacGalleryUITests: XCTestCase {
    func testReportsThreePaneInteractionAndSafeDrill() {
        let app = launchGalleryMac(["--v15-f4a-route", "reports-page-error"])
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["v15.f4a.reports.macos"].waitForExistence(timeout: 10))
        XCTAssertTrue(any["v15.f4a.mac.sidebar"].exists)
        XCTAssertTrue(any["v15.f4a.mac.inspector"].exists)
        app.buttons["v15.f4a.row.category.0"].click()
        XCTAssertTrue(any["v15.f4a.drill.item.00000000-0000-0000-0000-00000000F404"].waitForExistence(timeout: 6))
        app.buttons["v15.f4a.drill.next"].click()
        XCTAssertTrue(any["v15.f4a.drill.page-error"].waitForExistence(timeout: 6))
        app.buttons["重试"].click()
        XCTAssertTrue(any["v15.f4a.drill.return"].exists)
        app.buttons["v15.f4a.drill.return"].click()
        XCTAssertTrue(any["v15.f4a.mac.inspector"].exists)
        app.buttons["v15.f4a.row.category.0"].click()
        XCTAssertTrue(any["v15.f4a.drill.context"].waitForExistence(timeout: 6))
        app.buttons["v15.f4a.lens.merchants"].click()
        XCTAssertFalse(any["v15.f4a.drill.context"].exists)
        app.terminate()
    }

    func testFirstPageDrillFailureRetriesCurrentOwner() {
        let app = launchGalleryMac(["--v15-f4a-route", "reports-drill-first-error"])
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["v15.f4a.reports.macos"].waitForExistence(timeout: 10))
        app.buttons["v15.f4a.row.category.0"].click()
        XCTAssertTrue(any["v15.f4a.drill.error"].waitForExistence(timeout: 6))
        app.buttons["重试"].click()
        XCTAssertTrue(any["v15.f4a.drill.item.00000000-0000-0000-0000-00000000F404"].waitForExistence(timeout: 6))
        app.terminate()
    }

    func testRevisionBoundPDFExport() {
        let app = launchGalleryMac(["--v15-f4b-route", "reports"])
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["v15.f4a.reports.macos"].waitForExistence(timeout: 10))
        app.buttons["v15.f4b.export.pdf"].click()
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
        cancel.buttons["v15.f4b.export.csv"].click()
        cancel.buttons["v15.f4b.export.confirm"].click()
        XCTAssertTrue(cancelAny["v15.f4b.export.ready"].waitForExistence(timeout: 6))
        cancel.buttons["v15.f4b.export.handoff"].click()
        XCTAssertFalse(cancelAny["v15.f4b.export.inspector"].waitForExistence(timeout: 2))
        cancel.terminate()

        let retry = launchGalleryMac(["--v15-f4b-route", "reports-export-save-retry"])
        let retryAny = retry.descendants(matching: .any)
        XCTAssertTrue(retryAny["v15.f4a.reports.macos"].waitForExistence(timeout: 10))
        retry.buttons["v15.f4b.export.pdf"].click()
        retry.buttons["v15.f4b.export.confirm"].click()
        XCTAssertTrue(retryAny["v15.f4b.export.ready"].waitForExistence(timeout: 6))
        retry.buttons["v15.f4b.export.handoff"].click()
        XCTAssertTrue(retryAny["v15.f4b.export.error"].waitForExistence(timeout: 6))
        retry.buttons["v15.f4b.export.save.retry"].click()
        XCTAssertTrue(retryAny["v15.f4b.export.success"].waitForExistence(timeout: 6))
        retry.terminate()
    }
}
