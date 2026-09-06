import XCTest

@MainActor
final class F1AGalleryUITests: XCTestCase {
    private var app: XCUIApplication!
    private func launch(_ route: String, extraArguments: [String] = []) {
        app?.terminate(); app = XCUIApplication()
        app.launchArguments = ["--v15-f1a-route", route] + extraArguments
        app.launch()
    }

    func testRecordSheetStartsNeutralWhileSaveRemainsSafelyDisabled() {
        launch("record")
        app.buttons["新建账目"].tap()
        XCTAssertTrue(app.buttons["保存账目"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["保存账目"].isEnabled)
        XCTAssertFalse(app.staticTexts["请填写账目名称。"].exists)
        XCTAssertFalse(app.staticTexts["金额须为大于 0 的元金额，且最多两位小数。"].exists)
        let businessDate = app.datePickers["业务日期（上海）"]
        XCTAssertTrue(businessDate.waitForExistence(timeout: 2))
        XCTAssertEqual(businessDate.value as? String, "2026年8月15日")
        let dateLabel = app.staticTexts["日期"].firstMatch
        XCTAssertTrue(dateLabel.waitForExistence(timeout: 2))
        XCTAssertGreaterThan(dateLabel.frame.width, dateLabel.frame.height, "日期标签必须保持横向可读")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "f1a-ios-record-sheet-disabled"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRecordKeepsAmountNameAndCommitReachableWithKeyboard() {
        launch("record")
        app.buttons["新建账目"].tap()
        let amount = app.textFields["v15.f1a.record.amount"]
        let kind = app.descendants(matching: .any)["v15.f1a.record.kind"].firstMatch
        let account = app.descendants(matching: .any)["v15.f1a.record.account"].firstMatch
        let title = app.textFields["v15.f1a.record.title"]
        let submit = app.buttons["保存账目"]
        for element in [amount, kind, account, title, submit] {
            XCTAssertTrue(element.waitForExistence(timeout: 5))
        }
        XCTAssertLessThan(amount.frame.minY, title.frame.minY)
        XCTAssertLessThan(title.frame.maxY, account.frame.maxY)
        let keyboard = app.keyboards.firstMatch
        if !keyboard.exists { amount.tap() }
        XCTAssertTrue(keyboard.waitForExistence(timeout: 2), "需要显示软件键盘后再验证录入区可达性")
        XCTAssertGreaterThan(keyboard.frame.height, 150, "键盘必须有实际显示高度，不能由硬件键盘焦点冒充")
        XCTAssertLessThan(keyboard.frame.minY, app.frame.maxY - 100, "键盘必须实际出现在屏幕内")
        XCTAssertTrue(submit.isHittable)
        XCTAssertLessThanOrEqual(submit.frame.maxY, keyboard.frame.minY, "确认操作必须位于软件键盘上方")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "f1a-ios-record-software-keyboard"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRecordSheetAcceptsInputAndShowsUserFacingSuccess() {
        launch("record-valid")
        app.buttons["新建账目"].tap()
        XCTAssertTrue(app.buttons["保存账目"].waitForExistence(timeout: 4))
        app.buttons["保存账目"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f1a.record.success"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["账目已保存"].exists)
        XCTAssertTrue(app.staticTexts["已生成 1 条分录"].exists)
    }

    func testNoteCollapsesWithoutLosingTextAndResetsForNextEntry() {
        launch("record-valid")
        app.buttons["新建账目"].tap()
        let toggle = app.buttons["v15.f1a.record.note-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 4))
        let note = app.textFields["备注"]
        XCTAssertFalse(note.exists)
        scrollUntilHittable(toggle)
        toggle.tap()
        XCTAssertTrue(note.waitForExistence(timeout: 2))
        toggle.tap()
        XCTAssertFalse(note.exists)
        toggle.tap()
        scrollUntilHittable(note)
        note.tap()
        note.typeText("Keep this note")
        scrollUntilHittable(toggle)
        toggle.tap()
        XCTAssertFalse(note.exists)
        XCTAssertEqual(toggle.label, "备注 · 已填写")
        toggle.tap()
        XCTAssertEqual(note.value as? String, "Keep this note")
        app.buttons["保存账目"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f1a.record.success"].waitForExistence(timeout: 4))
        XCTAssertFalse(note.exists)
        XCTAssertEqual(toggle.label, "备注")
        let next = app.buttons["录入下一笔"]
        scrollUntilHittable(next)
        next.tap()
        scrollUntilHittable(toggle)
        toggle.tap()
        XCTAssertTrue(note.waitForExistence(timeout: 2))
        XCTAssertTrue(["", "可选"].contains(note.value as? String ?? ""), "下一笔不得保留旧备注")
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
        let amount = app.textFields["v15.f1a.record.amount"]
        let title = app.textFields["v15.f1a.record.title"]
        XCTAssertTrue(amount.waitForExistence(timeout: 2))
        XCTAssertTrue(title.waitForExistence(timeout: 2))
        XCTAssertGreaterThan(amount.frame.height, 52)
        XCTAssertTrue(app.buttons["保存账目"].isHittable)
        XCTAssertFalse(app.staticTexts["请填写账目名称。"].exists)
        let ax5 = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        ax5.name = "f1a-ios-record-sheet-ax5"
        ax5.lifetime = .keepAlways
        add(ax5)
    }

    func testRepaymentUsesHumanCyclePickerPreviewAndUserFacingSuccess() {
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

        let preview = app.buttons["查看还款影响"]
        scrollUntilHittable(preview)
        XCTAssertTrue(preview.isEnabled)
        XCTAssertFalse(app.staticTexts["请选择可用的信用账期。"].exists)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "f1a-ios-record-repayment-valid"
        attachment.lifetime = .keepAlways
        add(attachment)
        preview.tap()
        let confirm = app.buttons["确认还款"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 4))
        scrollUntilHittable(confirm)
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f1a.record.success"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["账目已保存"].exists)
        XCTAssertTrue(app.staticTexts["已生成 2 条分录"].exists)
    }

    func testRepaymentPrefillKeepsCycleAndSaveReachableAtAX5() {
        launch("repayment-valid", extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        app.buttons["新建账目"].tap()
        let cycle = app.descendants(matching: .any)["v15.f1a.record.credit-cycle"]
        XCTAssertTrue(cycle.waitForExistence(timeout: 4))
        scrollUntilHittable(cycle)
        XCTAssertTrue(cycle.isHittable)
        let preview = app.buttons["查看还款影响"]
        scrollUntilHittable(preview)
        XCTAssertTrue(preview.isHittable)
        XCTAssertTrue(preview.isEnabled)
        preview.tap()
        let confirm = app.buttons["确认还款"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 4))
        scrollUntilHittable(confirm)
        XCTAssertTrue(confirm.isHittable)
        XCTAssertTrue(confirm.isEnabled)
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
        // The sheet/root accessibility identifier can replace the identifier
        // of its root ScrollView. Query its native role to target the content,
        // keeping the fixed action bar and keyboard outside the swipe region.
        let recordScroll = app.scrollViews.firstMatch
        XCTAssertTrue(recordScroll.waitForExistence(timeout: 2), "记账编辑器滚动容器不存在", file: file, line: line)
        for _ in 0..<8 where !element.isHittable {
            let bounds = recordScroll.frame.intersection(app.frame)
            var bottom = bounds.maxY
            let keyboard = app.keyboards.firstMatch
            if keyboard.exists { bottom = min(bottom, keyboard.frame.minY) }
            for label in ["保存账目", "查看还款影响", "确认还款"] {
                let action = app.buttons[label]
                if action.exists { bottom = min(bottom, action.frame.minY) }
            }
            let height = bottom - bounds.minY
            XCTAssertGreaterThan(height, 80, "必须保留可滑动的内容区域", file: file, line: line)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let x = bounds.minX + bounds.width * 0.9
            let start = origin.withOffset(CGVector(dx: x, dy: bounds.minY + height * 0.85))
            let end = origin.withOffset(CGVector(dx: x, dy: bounds.minY + height * 0.15))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.isHittable, "element was not reachable", file: file, line: line)
    }
}
