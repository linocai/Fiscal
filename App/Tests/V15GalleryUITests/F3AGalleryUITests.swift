import XCTest

@MainActor final class F3AGalleryUITests: XCTestCase {
    private var app = XCUIApplication()
    private func launch(_ route: String, extra: [String] = []) { app.terminate(); app = XCUIApplication(); app.launchArguments = ["--v15-f3a-route", route] + extra; app.launch(); XCTAssertTrue(app.otherElements["v15.f3a.timeline.ios"].waitForExistence(timeout: 8)) }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
    private func attach(_ name: String) { let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
    func testWindowPageErrorConflictAndReadonlyInspectorAreReachable() {
        launch("timeline")
        XCTAssertTrue(element("v15.f3a.events").waitForExistence(timeout: 5))
        element("v15.f3a.window").buttons["7天"].tap()
        XCTAssertTrue(element("v15.f3a.event.credit_cycle:00000000-0000-0000-0000-00000000F301").waitForExistence(timeout: 5))
        element("v15.f3a.event.credit_cycle:00000000-0000-0000-0000-00000000F301").tap()
        XCTAssertTrue(element("v15.f3a.inspector").waitForExistence(timeout: 4)); element("v15.f3a.inspector.close").tap(); attach("f3a-ios-timeline")
        launch("timeline-page-error"); XCTAssertTrue(element("v15.f3a.events").waitForExistence(timeout: 5)); element("v15.f3a.next").tap(); XCTAssertTrue(element("v15.f3a.page-error").waitForExistence(timeout: 5)); attach("f3a-ios-page-error")
        launch("timeline-conflict"); XCTAssertTrue(element("v15.f3a.conflict").waitForExistence(timeout: 5)); element("v15.f3a.conflict.reload").tap(); XCTAssertTrue(element("v15.f3a.events").waitForExistence(timeout: 5)); attach("f3a-ios-conflict")
    }
    func testEmptyAndOfflineAreExplicitAtAX5() { launch("timeline-empty", extra: ["--v15-f1a-appearance", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]); XCTAssertTrue(element("v15.f3a.empty").waitForExistence(timeout: 5)); attach("f3a-ios-empty-dark-ax5"); launch("timeline-offline", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]); XCTAssertTrue(element("v15.f3a.offline").waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["提交"].exists); attach("f3a-ios-offline-ax5") }
    func testAuthoritativeAccountFilterCanSelectAccountOutsideFirstPageAndKeepItAtEmpty() {
        launch("timeline")
        let filter = element("v15.f3a.account-filter"); XCTAssertTrue(filter.waitForExistence(timeout: 5)); filter.tap()
        let emptyAccount = element("v15.f3a.account.00000000-0000-0000-0000-00000000F307"); XCTAssertTrue(emptyAccount.waitForExistence(timeout: 5)); emptyAccount.tap()
        XCTAssertTrue(element("v15.f3a.empty").waitForExistence(timeout: 5)); XCTAssertTrue(element("v15.f3a.account.selection").label.contains("旅行现金")); attach("f3a-ios-account-filter-empty")
        launch("timeline-account-error"); XCTAssertTrue(element("v15.f3a.account-error").waitForExistence(timeout: 5)); attach("f3a-ios-account-filter-error")
    }
    func testBoundaryAmountDoesNotSqueezeFutureTitleIntoTallColumn() {
        launch("timeline")
        let event = element("v15.f3a.event.credit_cycle:00000000-0000-0000-0000-00000000F301")
        XCTAssertTrue(event.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(event.frame.width, 300)
        XCTAssertLessThan(event.frame.height, 170)
        XCTAssertTrue(event.label.contains("超长中文信用账期到期事项"))
        XCTAssertTrue(event.label.contains("9,223,372,036,854,775.80"))
    }
}
