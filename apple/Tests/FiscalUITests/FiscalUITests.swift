import XCTest

@MainActor
final class FiscalUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let token = try XCTUnwrap(
            ProcessInfo.processInfo.environment["FISCAL_UI_TEST_DEVICE_TOKEN"],
            "Set FISCAL_UI_TEST_DEVICE_TOKEN for authenticated integration UI tests."
        )
        app = XCUIApplication()
        app.launchEnvironment["FISCAL_DEVICE_TOKEN"] = token
        app.launch()
    }

    func testAccountsUseRealAPIAndOnlyOneCustomBottomBar() throws {
        XCTAssertEqual(app.tabBars.count, 0, "The native TabView bar must not exist beneath Fiscal's custom bar.")
        let more = app.buttons["更多"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()

        let accounts = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "账户")).firstMatch
        XCTAssertTrue(accounts.waitForExistence(timeout: 5))
        accounts.tap()

        XCTAssertTrue(app.staticTexts["招行储蓄卡"].waitForExistence(timeout: 8))
        keepScreenshot(named: "ios-p2-accounts")
    }

    func testCategoriesReadTheSharedAPIHierarchy() throws {
        let more = app.buttons["更多"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()

        let categories = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "分类设置")).firstMatch
        XCTAssertTrue(categories.waitForExistence(timeout: 5))
        categories.tap()

        XCTAssertTrue(app.staticTexts["餐饮"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["咖啡"].waitForExistence(timeout: 5))
        keepScreenshot(named: "ios-p2-categories")
    }

    private func keepScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
