import XCTest

@MainActor final class F4AGalleryUITests: XCTestCase {
    private var app = XCUIApplication()
    private func launch(_ route: String = "reports") {
        app.terminate(); app = XCUIApplication()
        app.launchArguments = ["--v15-f4a-route", route, "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryLarge"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f4a.reports.ios"].waitForExistence(timeout: 10))
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
    private func button(_ id: String) -> XCUIElement { app.buttons[id] }
    private func reveal(_ id: String) -> XCUIElement {
        let value = element(id)
        XCTAssertTrue(value.waitForExistence(timeout: 6), "missing \(id)")
        for _ in 0..<12 where !value.isHittable { app.swipeUp() }
        XCTAssertTrue(value.isHittable, "not hittable \(id)")
        return value
    }
    private func revealButton(_ id: String) -> XCUIElement {
        let value = button(id)
        XCTAssertTrue(value.waitForExistence(timeout: 6), "missing button \(id)")
        for _ in 0..<12 where !value.isHittable { app.swipeUp() }
        XCTAssertTrue(value.isHittable, "button not hittable \(id)")
        return value
    }

    func testPeriodFourLensSafeDrillPagingRetryAndReturn() {
        launch("reports-page-error")
        app.buttons["v15.f4a.period.toggle"].tap()
        XCTAssertTrue(element("v15.f4a.meta").waitForExistence(timeout: 6))
        app.buttons["v15.f4a.period.toggle"].tap()
        app.buttons["v15.f4a.lens.spending"].tap()
        XCTAssertTrue(element("v15.f4a.surface.spending").waitForExistence(timeout: 6))
        revealButton("v15.f4a.measure.netConsumption").tap()
        revealButton("v15.f4a.row.category.0").tap()
        XCTAssertTrue(element("v15.f4a.drill").waitForExistence(timeout: 6))
        XCTAssertTrue(element("v15.f4a.drill.item.00000000-0000-0000-0000-00000000F404").waitForExistence(timeout: 6))
        revealButton("v15.f4a.drill.next").tap()
        XCTAssertTrue(reveal("v15.f4a.drill.page-error").exists)
        app.buttons["重试"].tap()
        XCTAssertTrue(element("v15.f4a.drill.item.00000000-0000-0000-0000-00000000F404").waitForExistence(timeout: 6))
        app.buttons["v15.f4a.drill.return"].tap()
        XCTAssertFalse(element("v15.f4a.drill").exists)
    }

    func testDisabledRowsDoNotOpenDrillAndConflictReloads() {
        launch()
        app.buttons["v15.f4a.lens.spending"].tap()
        let disabledCategory = reveal("v15.f4a.row.category.1")
        XCTAssertFalse(disabledCategory.isEnabled)
        XCTAssertFalse(element("v15.f4a.drill").exists)
        launch("reports-conflict")
        app.buttons["v15.f4a.lens.spending"].tap()
        revealButton("v15.f4a.row.category.0").tap()
        XCTAssertTrue(element("v15.f4a.conflict").waitForExistence(timeout: 6))
        app.buttons["v15.f4a.conflict.reload"].tap()
        XCTAssertTrue(reveal("v15.f4a.row.category.0").exists)
    }

    func testCompletenessOnlyAndFirstPageDrillRetry() {
        launch("reports-completeness-only")
        XCTAssertTrue(element("v15.f4a.surface.overview").waitForExistence(timeout: 6))
        XCTAssertFalse(element("v15.f4a.empty").exists)

        launch("reports-unknown-account")
        let disabledAccount = reveal("v15.f4a.row.overview.account.0")
        XCTAssertFalse(disabledAccount.isEnabled)
        XCTAssertFalse(element("v15.f4a.drill").exists)

        launch("reports-drill-first-error")
        app.buttons["v15.f4a.lens.spending"].tap()
        revealButton("v15.f4a.row.category.0").tap()
        XCTAssertTrue(element("v15.f4a.drill.error").waitForExistence(timeout: 6))
        app.buttons["重试"].tap()
        XCTAssertTrue(element("v15.f4a.drill.item.00000000-0000-0000-0000-00000000F404").waitForExistence(timeout: 6))

        launch("reports-drill-empty")
        app.buttons["v15.f4a.lens.spending"].tap()
        revealButton("v15.f4a.row.category.0").tap()
        XCTAssertTrue(element("v15.f4a.drill.empty").waitForExistence(timeout: 6))
    }

    func testOverviewAndCashFlowMetricsStayInsidePhoneWidth() {
        launch()
        let overview = element("v15.f4a.metric.0")
        XCTAssertTrue(overview.waitForExistence(timeout: 6))
        XCTAssertGreaterThanOrEqual(overview.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(overview.frame.maxX, app.frame.maxX)

        app.buttons["v15.f4a.lens.cashFlow"].tap()
        XCTAssertTrue(element("v15.f4a.surface.cashFlow").waitForExistence(timeout: 6))
        let cashFlow = element("v15.f4a.metric.0")
        XCTAssertGreaterThanOrEqual(cashFlow.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(cashFlow.frame.maxX, app.frame.maxX)
    }

    func testRevisionBoundExportReadyHandoffAndStaleResponse() {
        launch()
        revealButton("v15.f4b.export").tap()
        app.buttons["导出 CSV"].tap()
        XCTAssertTrue(element("v15.f4b.export.sheet").waitForExistence(timeout: 6))
        app.buttons["v15.f4b.export.confirm"].tap()
        XCTAssertTrue(element("v15.f4b.export.ready").waitForExistence(timeout: 6))
        XCTAssertTrue(button("v15.f4b.export.handoff").exists)
        XCTAssertFalse(element("v15.f4b.export.success").exists)
        button("v15.f4b.export.done").tap()
        XCTAssertTrue(element("v15.f4b.export.sheet").waitForNonExistence(timeout: 6))
        XCTAssertFalse(element("v15.f4b.export.success").exists)

        launch("reports-export-stale")
        revealButton("v15.f4b.export").tap()
        app.buttons["导出 PDF"].tap()
        app.buttons["v15.f4b.export.confirm"].tap()
        XCTAssertTrue(element("v15.f4b.export.error").waitForExistence(timeout: 6))
    }
}
