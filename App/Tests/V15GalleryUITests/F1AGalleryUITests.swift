import XCTest

@MainActor
final class F1AGalleryUITests: XCTestCase {
    private var app: XCUIApplication!
    private func launch(_ route: String, extraArguments: [String] = []) {
        app?.terminate(); app = XCUIApplication()
        app.launchArguments = ["--v15-f1a-route", route] + extraArguments
        app.launch()
    }

    func testRecordSheetShowsVisibleDisabledReasonsAtPointOfEntry() {
        launch("record")
        app.buttons["新建账目"].tap()
        XCTAssertTrue(app.buttons["保存账目"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["保存账目"].isEnabled)
        XCTAssertTrue(app.staticTexts["请填写账目名称。"].exists)
        XCTAssertTrue(app.staticTexts["金额须为大于 0 的元金额，且最多两位小数。"].exists)
        let businessDate = app.datePickers["业务日期（上海）"]
        XCTAssertTrue(businessDate.waitForExistence(timeout: 2))
        XCTAssertEqual(businessDate.value as? String, "2026年8月15日")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "f1a-ios-record-sheet-disabled"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRecordSheetAcceptsInputAndShowsActualSuccessCredential() {
        launch("record-valid")
        app.buttons["新建账目"].tap()
        XCTAssertTrue(app.buttons["保存账目"].waitForExistence(timeout: 4))
        app.buttons["保存账目"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f1a.record.success"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["已保存事实"].exists)
        XCTAssertTrue(app.staticTexts["交易 00000000-0000-0000-0000-000000000105 · v1 · 1 条分录"].exists)
    }

    func testTypePickerReachesAllFiveKindsWithCompatibleFields() {
        launch("record")
        app.buttons["新建账目"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f1a.record.kind"].waitForExistence(timeout: 4))

        chooseKind("收入")
        XCTAssertTrue(app.descendants(matching: .any)["v15.f1a.record.category"].waitForExistence(timeout: 2))
        chooseKind("转账")
        XCTAssertTrue(app.descendants(matching: .any)["v15.f1a.record.destination"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.descendants(matching: .any)["v15.f1a.record.category"].exists)
        chooseKind("信用卡消费")
        XCTAssertTrue(app.descendants(matching: .any)["v15.f1a.record.category"].waitForExistence(timeout: 2))
        chooseKind("还款")
        XCTAssertTrue(app.descendants(matching: .any)["v15.f1a.record.destination"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["v15.f1a.record.credit-cycle"].waitForExistence(timeout: 2))
        chooseKind("支出")
        XCTAssertTrue(app.descendants(matching: .any)["v15.f1a.record.category"].waitForExistence(timeout: 2))
    }

    func testExpandedSheetDarkAndAX5RemainReadable() {
        launch("record", extraArguments: ["--v15-f1a-appearance", "dark"])
        app.buttons["新建账目"].tap()
        XCTAssertTrue(app.buttons["保存账目"].waitForExistence(timeout: 4))
        let dark = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        dark.name = "f1a-ios-record-sheet-dark"
        dark.lifetime = .keepAlways
        add(dark)

        launch("record", extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        app.buttons["新建账目"].tap()
        XCTAssertTrue(app.buttons["保存账目"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["请填写账目名称。"].exists)
        let ax5 = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        ax5.name = "f1a-ios-record-sheet-ax5"
        ax5.lifetime = .keepAlways
        add(ax5)
    }

    func testRepaymentUsesHumanCyclePickerAndReturnsServerCredential() {
        launch("record")
        app.buttons["新建账目"].tap()
        XCTAssertTrue(app.buttons["保存账目"].waitForExistence(timeout: 4))
        chooseKind("还款")
        fill("12.80", field: "金额（元）")
        fill("信用卡还款", field: "名称")
        let returnKey = app.keyboards.buttons["Return"]
        if returnKey.exists { returnKey.tap() }
        choosePicker("v15.f1a.record.account", option: "日常现金")
        choosePicker("v15.f1a.record.destination", option: "信用账户")

        let cycle = app.descendants(matching: .any)["v15.f1a.record.credit-cycle"]
        XCTAssertTrue(cycle.waitForExistence(timeout: 4))
        scrollUntilHittable(cycle)
        choosePicker("v15.f1a.record.credit-cycle", option: "2026-07-21 至 2026-08-20 · 还款日 2026-09-05")
        XCTAssertEqual(cycle.value as? String, "2026-07-21 至 2026-08-20 · 还款日 2026-09-05")

        let save = app.buttons["保存账目"]
        scrollUntilHittable(save)
        XCTAssertTrue(save.isEnabled)
        XCTAssertFalse(app.staticTexts["请选择可用的信用账期。"].exists)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "f1a-ios-record-repayment-valid"
        attachment.lifetime = .keepAlways
        add(attachment)
        save.tap()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f1a.record.success"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["交易 00000000-0000-0000-0000-000000000109 · v1 · 2 条分录"].exists)
    }

    func testRepaymentPrefillKeepsCycleAndSaveReachableAtAX5() {
        launch("repayment-valid", extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        app.buttons["新建账目"].tap()
        let cycle = app.descendants(matching: .any)["v15.f1a.record.credit-cycle"]
        XCTAssertTrue(cycle.waitForExistence(timeout: 4))
        scrollUntilHittable(cycle)
        XCTAssertTrue(cycle.isHittable)
        let save = app.buttons["保存账目"]
        scrollUntilHittable(save)
        XCTAssertTrue(save.isHittable)
        XCTAssertTrue(save.isEnabled)
    }

    private func chooseKind(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let picker = app.descendants(matching: .any)["v15.f1a.record.kind"]
        picker.tap()
        let option = app.buttons[label]
        XCTAssertTrue(option.waitForExistence(timeout: 2), "missing type option \(label)", file: file, line: line)
        option.tap()
    }

    private func choosePicker(_ identifier: String, option: String, file: StaticString = #filePath, line: UInt = #line) {
        let picker = app.descendants(matching: .any)[identifier]
        scrollUntilHittable(picker)
        picker.tap()
        let choice = app.buttons[option]
        XCTAssertTrue(choice.waitForExistence(timeout: 3), "missing picker option \(option)", file: file, line: line)
        choice.tap()
    }

    private func fill(_ text: String, field: String, file: StaticString = #filePath, line: UInt = #line) {
        let target = app.textFields[field]
        XCTAssertTrue(target.waitForExistence(timeout: 2), "missing field \(field)", file: file, line: line)
        target.tap()
        target.typeText(text)
    }

    private func scrollUntilHittable(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<5 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable, "element was not reachable", file: file, line: line)
    }
}
