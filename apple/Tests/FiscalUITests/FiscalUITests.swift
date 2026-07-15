import XCTest

@MainActor
final class FiscalUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launchApp() throws {
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
        try launchApp()
        XCTAssertEqual(app.tabBars.count, 0, "The native TabView bar must not exist beneath Fiscal's custom bar.")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "fiscal.customBottomBar").count, 1)
        let more = app.buttons["更多"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()

        let accounts = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "账户")).firstMatch
        XCTAssertTrue(accounts.waitForExistence(timeout: 5))
        accounts.tap()

        XCTAssertTrue(app.staticTexts["招行储蓄卡"].waitForExistence(timeout: 8))
        keepScreenshot(named: "ios-p2-accounts")
    }

    func testP3TransactionListAndRecordSheetUseRealAPI() throws {
        try launchApp()
        XCTAssertEqual(app.tabBars.count, 0)
        let customBar = app.descendants(matching: .any).matching(identifier: "fiscal.customBottomBar")
        XCTAssertEqual(customBar.count, 1)

        app.buttons["流水"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["transactions.screen"].waitForExistence(timeout: 8))
        let search = app.searchFields["搜索标题或备注"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertLessThan(search.frame.maxY, customBar.element.frame.minY, "iOS 26 must keep search above the custom bottom bar.")
        XCTAssertTrue(app.staticTexts["手冲咖啡与午餐"].waitForExistence(timeout: 8))
        keepScreenshot(named: "ios-p3-transactions")

        let rowMenu = app.buttons
            .matching(identifier: "transaction.rowMenu")
            .matching(NSPredicate(format: "label == %@", "More"))
            .firstMatch
        XCTAssertTrue(rowMenu.waitForExistence(timeout: 5))
        rowMenu.tap()
        let voidMenuItem = app.buttons["作废"]
        XCTAssertTrue(voidMenuItem.waitForExistence(timeout: 3))
        voidMenuItem.tap()
        let confirmVoid = app.alerts.buttons["作废"]
        XCTAssertTrue(confirmVoid.waitForExistence(timeout: 3))
        confirmVoid.tap()
        let undoBar = app.descendants(matching: .any)["transaction.undoBar"]
        XCTAssertTrue(undoBar.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(undoBar.frame.maxY, customBar.element.frame.minY, "Undo must remain fully above the custom bottom bar.")
        app.buttons["撤销"].tap()
        XCTAssertTrue(undoBar.waitForNonExistence(timeout: 5))

        app.buttons["记一笔"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["transaction.editor"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["支出"].exists)
        XCTAssertTrue(app.buttons["收入"].exists)
        XCTAssertTrue(app.buttons["转账"].exists)
        keepScreenshot(named: "ios-p3-record")
    }

    func testCategoriesReadTheSharedAPIHierarchy() throws {
        try launchApp()
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
