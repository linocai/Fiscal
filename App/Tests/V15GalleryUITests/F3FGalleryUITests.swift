import XCTest

@MainActor final class F3FGalleryUITests: XCTestCase {
    private var app = XCUIApplication()
    private func launch(_ route: String = "ai-proposals", extra: [String] = []) {
        app.terminate(); app = XCUIApplication()
        app.launchArguments = ["--v15-f3f-route", route, "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryLarge"] + extra
        app.launch()
        XCTAssertTrue(element("v15.f3f.ai.ios").waitForExistence(timeout: 10))
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func button(_ id: String) -> XCUIElement { app.buttons.matching(identifier: id).firstMatch }
    private func bringIntoView(_ value: XCUIElement, swipes: Int) {
        for _ in 0..<swipes {
            if value.exists, value.frame.intersects(app.frame) { return }
            if value.exists, value.frame.midY < app.frame.midY { app.swipeDown() }
            else { app.swipeUp() }
        }
    }
    @discardableResult private func reveal(_ id: String, swipes: Int = 14) -> XCUIElement {
        let value = element(id)
        bringIntoView(value, swipes: swipes)
        XCTAssertTrue(value.waitForExistence(timeout: 6), "missing \(id)")
        return value
    }
    @discardableResult private func revealButton(_ id: String, enabled: Bool? = nil, swipes: Int = 14) -> XCUIElement {
        let value = button(id)
        bringIntoView(value, swipes: swipes)
        XCTAssertTrue(value.waitForExistence(timeout: 6), "missing \(id)")
        if let enabled { XCTAssertEqual(value.isEnabled, enabled) }
        return value
    }
    private func replace(_ text: String, field id: String) {
        let field = app.textFields[id]
        for _ in 0..<10 where !field.exists || !field.isHittable { app.swipeUp() }
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 60) + text)
        if app.keyboards.buttons["Return"].waitForExistence(timeout: 1) { app.keyboards.buttons["Return"].tap() }
        if app.keyboards.firstMatch.exists, app.staticTexts["AI 记账"].firstMatch.exists {
            app.staticTexts["AI 记账"].firstMatch.tap()
            _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 3)
        }
    }
    private func attach(_ name: String) { let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment) }

    func testQueueShowsD3InvariantLowConfidenceMissingFieldsAndUnknownReadOnly() {
        launch()
        XCTAssertTrue(element("v15.f3f.d3-invariant").waitForExistence(timeout: 6))
        XCTAssertTrue(reveal("v15.f3f.missing-fields").waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "72%")).firstMatch.exists)
        launch()
        reveal("v15.f3f.proposal.00000000-0000-0000-0000-00000000F304").tap()
        XCTAssertTrue(reveal("v15.f3f.unknown-readonly").waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "暂时无法识别")).firstMatch.exists)
        attach("f3f-ios-queue-confidence-unknown")
    }

    func testEditMustBeConfirmedBeforeHumanExecute() {
        launch()
        let execute = revealButton("v15.f3f.execute", enabled: false)
        XCTAssertFalse(execute.isEnabled)
        let executeReason = app.staticTexts["v15.f3f.execute"]
        XCTAssertTrue(executeReason.exists)
        XCTAssertTrue(executeReason.label.contains("内容已经更新，请重新检查并保存后再记账。"))
        revealButton("v15.f3f.review.open", enabled: true).tap()
        XCTAssertTrue(element("v15.f3f.editor.sheet").waitForExistence(timeout: 6))
        replace("  人工确认工作餐  ", field: "v15.f3f.editor.title")
        revealButton("v15.f3f.editor.confirm", enabled: true).tap()
        XCTAssertTrue(element("v15.f3f.success").waitForExistence(timeout: 8))
        let manual = revealButton("v15.f3f.editor.execute", enabled: true)
        attach("f3f-ios-human-confirmed-before-execute")
        manual.tap()
        XCTAssertTrue(element("v15.f3f.editor.sheet").waitForNonExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已按人工确认内容执行")).firstMatch.waitForExistence(timeout: 8))
    }

    func testFailedRetryIgnoreAndUndoActionsAreReachable() {
        launch()
        reveal("v15.f3f.proposal.00000000-0000-0000-0000-00000000F302").tap()
        XCTAssertTrue(revealButton("v15.f3f.retry", enabled: true).waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["AI 服务当时响应超时。"].waitForExistence(timeout: 6))
        XCTAssertFalse(app.staticTexts["ai_provider_timeout"].exists)
        launch()
        XCTAssertTrue(revealButton("v15.f3f.ignore", enabled: true).waitForExistence(timeout: 6))
        launch()
        reveal("v15.f3f.proposal.00000000-0000-0000-0000-00000000F303").tap()
        XCTAssertTrue(revealButton("v15.f3f.undo", enabled: true).waitForExistence(timeout: 6))
        attach("f3f-ios-failed-ignore-undo")
    }

    func testUnpostedProposalDeletionRequiresConfirmationAndRemovesTheItem() {
        launch()
        reveal("v15.f3f.proposal.00000000-0000-0000-0000-00000000F302").tap()
        revealButton("v15.f3f.delete", enabled: true).tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 6))
        XCTAssertTrue(alert.staticTexts["只删除这项尚未记账的内容，不会影响账本。删除后无法恢复。"].exists)
        alert.buttons["取消"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 6))
        XCTAssertTrue(revealButton("v15.f3f.delete", enabled: true).exists)

        revealButton("v15.f3f.delete", enabled: true).tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 6))
        alert.buttons["v15.f3f.delete.confirm"].firstMatch.tap()
        XCTAssertTrue(revealButton("v15.f3f.undo", enabled: true).waitForExistence(timeout: 8))
        XCTAssertTrue(reveal("v15.f3f.success").waitForExistence(timeout: 8))
        attach("f3f-ios-delete-unposted-confirmed")
    }

    func testUnknownDeleteOrdinaryRefreshSafelyConfirmsTheServerResult() {
        launch("ai-delete-unknown")
        revealButton("v15.f3f.delete", enabled: true).tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 6))
        alert.buttons["v15.f3f.delete.confirm"].firstMatch.tap()

        XCTAssertTrue(revealButton("v15.f3f.unknown.readback", enabled: true).waitForExistence(timeout: 8))
        button("v15.f3f.refresh").tap()

        XCTAssertTrue(reveal("v15.f3f.success").waitForExistence(timeout: 8))
        XCTAssertTrue(revealButton("v15.f3f.delete", enabled: true).waitForExistence(timeout: 8))
        XCTAssertFalse(element("v15.f3f.unknown.readback").exists)
        attach("f3f-ios-delete-unknown-refresh-confirmed")
    }

    func testFieldErrorStaysInSheetAndKeylessUnknownRequiresReadback() {
        launch("ai-field-error")
        revealButton("v15.f3f.review.open").tap()
        revealButton("v15.f3f.editor.confirm", enabled: true).tap()
        XCTAssertTrue(element("v15.f3f.remote-issues").waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["请选择支出分类。"].exists)
        XCTAssertTrue(element("v15.f3f.editor.sheet").exists)

        launch("ai-response-unknown")
        revealButton("v15.f3f.review.open").tap()
        revealButton("v15.f3f.editor.confirm", enabled: true).tap()
        XCTAssertTrue(revealButton("v15.f3f.unknown.abandon", enabled: false).waitForExistence(timeout: 8))
        revealButton("v15.f3f.unknown.readback", enabled: true).tap()
        XCTAssertTrue(revealButton("v15.f3f.unknown.abandon", enabled: true).waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "仍无法确认是否由本次操作造成")).firstMatch.exists)
        attach("f3f-ios-keyless-readback-no-attribution")
    }

    func testCashFlowReviewAndFailedReadbackRemainExplicitlyRecoverable() {
        launch("ai-cash-flow")
        XCTAssertTrue(reveal("v15.f3f.cash-flow.target").waitForExistence(timeout: 8))
        revealButton("v15.f3f.review.open").tap()
        XCTAssertTrue(app.staticTexts["未来现金流草案"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["计划金额（元）"].exists)
        revealButton("v15.f3f.editor.confirm", enabled: true).tap()
        XCTAssertTrue(revealButton("v15.f3f.editor.execute", enabled: true).waitForExistence(timeout: 8))

        launch("ai-response-unknown-read-failure")
        revealButton("v15.f3f.review.open").tap()
        revealButton("v15.f3f.editor.confirm", enabled: true).tap()
        revealButton("v15.f3f.unknown.readback", enabled: true).tap()
        XCTAssertTrue(revealButton("v15.f3f.unknown.readback", enabled: true).waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "检查最新状态失败")).firstMatch.exists)
        XCTAssertFalse(revealButton("v15.f3f.unknown.abandon", enabled: false).isEnabled)
        attach("f3f-ios-cash-flow-and-readback-retry")
    }

    func testReadbackButtonIsSingleFlightAndDisabledUntilItsFreshGetCompletes() {
        launch("ai-response-unknown-read-delayed")
        revealButton("v15.f3f.review.open").tap()
        revealButton("v15.f3f.editor.confirm", enabled: true).tap()
        revealButton("v15.f3f.unknown.readback", enabled: true).tap()
        XCTAssertTrue(app.staticTexts["正在读取最新数据；不会重复保存。"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "仍无法确认是否由本次操作造成")).firstMatch.waitForExistence(timeout: 8))
    }

    func testStableCreateUnknownRetriesSameAttemptAndOfflineEmitsNoAction() {
        launch("ai-create-unknown")
        replace("午餐 132 元", field: "v15.f3f.create.text")
        revealButton("v15.f3f.create.submit", enabled: true).tap()
        XCTAssertTrue(revealButton("v15.f3f.unknown.create-retry", enabled: true).waitForExistence(timeout: 8))
        attach("f3f-ios-stable-key-unknown")
        revealButton("v15.f3f.unknown.create-retry", enabled: true).tap()
        XCTAssertTrue(element("v15.f3f.success").waitForExistence(timeout: 8))

        launch("ai-offline")
        XCTAssertTrue(element("v15.f3f.offline").waitForExistence(timeout: 6))
        XCTAssertFalse(revealButton("v15.f3f.create.submit", enabled: false).isEnabled)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "当前无法提交更改")).firstMatch.exists)
    }

    func testEmptyErrorContractViolationConflictAndAX5LongStatesAreReachable() {
        launch("ai-empty"); XCTAssertTrue(element("v15.f3f.queue.empty").waitForExistence(timeout: 6))
        launch("ai-error"); XCTAssertTrue(element("v15.f3f.queue.error").waitForExistence(timeout: 6))
        launch("ai-settings-violation"); XCTAssertTrue(element("v15.f3f.queue.error").waitForExistence(timeout: 6)); XCTAssertFalse(revealButton("v15.f3f.create.submit", enabled: false).isEnabled)
        launch("ai-conflict"); revealButton("v15.f3f.review.open").tap(); revealButton("v15.f3f.editor.confirm", enabled: true).tap(); XCTAssertTrue(element("v15.f3f.conflict").waitForExistence(timeout: 8))
        launch("ai-page-error"); revealButton("v15.f3f.page.more").tap(); XCTAssertTrue(element("v15.f3f.page.error").waitForExistence(timeout: 8))
        launch("ai-long", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(element("v15.f3f.ai.ios").exists); attach("f3f-ios-ax5-long")
    }

    func testLaterD3SettingsViolationShowsStickyBannerAndLocksVisibleMutationControls() {
        launch("ai-settings-violation-after-safe")
        XCTAssertTrue(reveal("v15.f3f.proposal.00000000-0000-0000-0000-00000000F301").waitForExistence(timeout: 6))
        button("v15.f3f.refresh").tap()
        XCTAssertTrue(element("v15.f3f.d3-contract-banner").waitForExistence(timeout: 8))
        XCTAssertFalse(revealButton("v15.f3f.create.submit", enabled: false).isEnabled)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "本页已停止所有保存操作")).firstMatch.exists)
        XCTAssertTrue(reveal("v15.f3f.proposal.00000000-0000-0000-0000-00000000F301").waitForExistence(timeout: 6))
        attach("f3f-ios-sticky-d3-contract-lock")
    }

    func testStableCreateRecoveryRemainsVisibleAcrossSelectionAndSettingsRecovery() {
        launch("ai-create-unknown-settings-transport-after-safe")
        replace("午餐 132 元", field: "v15.f3f.create.text")
        revealButton("v15.f3f.create.submit", enabled: true).tap()
        XCTAssertTrue(element("v15.f3f.unknown.create-recovery").waitForExistence(timeout: 8))
        XCTAssertTrue(revealButton("v15.f3f.unknown.create-retry", enabled: true).exists)

        reveal("v15.f3f.proposal.00000000-0000-0000-0000-00000000F302").tap()
        XCTAssertTrue(reveal("v15.f3f.unknown.create-recovery").exists)
        reveal("v15.f3f.proposal.00000000-0000-0000-0000-00000000F301").tap()
        XCTAssertTrue(reveal("v15.f3f.unknown.create-recovery").exists)

        button("v15.f3f.refresh").tap()
        XCTAssertTrue(revealButton("v15.f3f.unknown.create-retry", enabled: false).waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "AI 安全设置读取失败")).firstMatch.exists)
        button("v15.f3f.refresh").tap()
        XCTAssertTrue(revealButton("v15.f3f.unknown.create-retry", enabled: true).waitForExistence(timeout: 8))
        revealButton("v15.f3f.unknown.create-retry", enabled: true).tap()
        XCTAssertTrue(reveal("v15.f3f.success").waitForExistence(timeout: 8))
        attach("f3f-ios-stable-create-settings-recovery")
    }
}
