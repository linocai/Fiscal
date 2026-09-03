import XCTest

@MainActor
final class F1BGalleryUITests: XCTestCase {
    private var app: XCUIApplication!
    private func launch(route: String = "ledger", _ arguments: [String] = []) {
        app?.terminate(); app = XCUIApplication()
        app.launchArguments = ["--v15-f1b-route", route] + arguments
        app.launch()
    }
    private func attach(_ name: String) { let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image) }
    private func reveal(_ identifier: String) -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier]
        for _ in 0..<10 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable, "missing or unreachable \(identifier)")
        return element
    }

    func testSearchListOpensServerDetailWithHistoryAndProvenance() {
        launch()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f1b.ledger.ios"].waitForExistence(timeout: 5))
        attach("f1b-ios-list-light")
        let search = app.textFields["搜索账目"]
        XCTAssertTrue(search.waitForExistence(timeout: 3)); search.tap(); search.typeText("午餐")
        app.buttons["刷新"].tap()
        let row = app.descendants(matching: .any)["v15.f1b.row.00000000-0000-0000-0000-00000000B101"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f1b.detail.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(reveal("v15.f1b.revision.2").label.contains("已修改"))
        XCTAssertTrue(reveal("v15.f1b.provenance.links").label.contains("已关联 2 条相关记录"))
        attach("f1b-ios-detail-light-history-provenance")
    }

    func testServerEnabledVoidIsReachableAndUnknownEditRestoreAreNotInvented() {
        launch(["--v15-f1a-appearance", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let row = app.descendants(matching: .any)["v15.f1b.row.00000000-0000-0000-0000-00000000B101"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        let void = app.buttons["作废账目"]
        XCTAssertTrue(void.waitForExistence(timeout: 5)); XCTAssertTrue(void.isHittable)
        XCTAssertFalse(app.buttons["编辑账目"].exists)
        XCTAssertFalse(app.buttons["恢复账目"].exists)
        attach("f1b-ios-detail-dark-ax5-history-provenance")
        void.tap()
        XCTAssertTrue(reveal("v15.f1b.archive-read-only").label.contains("归档，只读"))
    }

    func testFiltersAutoLoadAndOfflineMutationExplainsReadOnlyReason() {
        launch()
        XCTAssertTrue(app.buttons["v15.f1b.filters"].waitForExistence(timeout: 5))
        app.buttons["v15.f1b.filters"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f1b.filters.content"].waitForExistence(timeout: 3))
        app.buttons["v15.f1b.filter.kind"].tap()
        XCTAssertTrue(app.buttons["v15.f1b.filter.kind.installment_fee"].waitForExistence(timeout: 3)); app.buttons["v15.f1b.filter.kind.installment_fee"].tap()
        XCTAssertTrue(app.staticTexts["分期手续费"].exists)
        app.buttons["v15.f1b.filter.source"].tap()
        XCTAssertTrue(app.buttons["v15.f1b.filter.source.system"].waitForExistence(timeout: 3)); app.buttons["v15.f1b.filter.source.system"].tap()
        XCTAssertTrue(app.staticTexts["系统生成"].exists)
        let minimum = app.textFields["最低金额"]
        XCTAssertTrue(minimum.waitForExistence(timeout: 3)); minimum.tap(); minimum.typeText("12.80")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f1b.row.00000000-0000-0000-0000-00000000B101"].waitForExistence(timeout: 5))

        launch(route: "ledger-offline")
        let row = app.descendants(matching: .any)["v15.f1b.row.00000000-0000-0000-0000-00000000B101"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f1b.offline"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["v15.f1b.void.disabled"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["作废账目"].exists)
        attach("f1b-ios-offline-snapshot")
    }

    func testPaginationFailureKeepsFirstPageAndShowsLocalRetry() {
        launch(route: "ledger-page-error")
        let first = app.descendants(matching: .any)["v15.f1b.row.00000000-0000-0000-0000-00000000B101"]
        XCTAssertTrue(first.waitForExistence(timeout: 5)); app.buttons["v15.f1b.next-page"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f1b.next-page.error"].waitForExistence(timeout: 5))
        XCTAssertTrue(first.exists)
        attach("f1b-ios-pagination-partial-error")
    }
}
