import XCTest

@MainActor final class F3CGalleryUITests: XCTestCase {
    private var app = XCUIApplication()
    // F3-C gallery fixture's party.expected_date; keep UI input aligned with
    // the fixed fixture fact rather than the host clock.
    private let fixtureExpectedDate = "2026-08-20"

    private func launch(_ route: String = "reimbursements", extra: [String] = []) {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--v15-f3c-route", route] + extra
        app.launch()
        XCTAssertTrue(element("v15.f3c.reimbursements.ios").waitForExistence(timeout: 10))
        XCTAssertTrue(element("v15.f3c.claim.detail").waitForExistence(timeout: 10))
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
    private func button(_ id: String) -> XCUIElement { app.buttons[id] }
    private func textField(_ id: String) -> XCUIElement { app.textFields[id] }

    @discardableResult private func reveal(_ id: String, swipes: Int = 10) -> XCUIElement {
        let value = element(id)
        for _ in 0..<swipes where !value.exists || !value.isHittable { app.swipeUp() }
        XCTAssertTrue(value.waitForExistence(timeout: 6), "missing \(id)")
        return value
    }

    @discardableResult private func revealButton(_ id: String, requireHittable: Bool = true, swipes: Int = 10) -> XCUIElement {
        let value = button(id)
        for _ in 0..<swipes where !value.exists || (requireHittable && !value.isHittable) { app.swipeUp() }
        XCTAssertTrue(value.waitForExistence(timeout: 6), "missing button \(id)")
        return value
    }

    @discardableResult private func revealTextField(_ id: String, upward: Bool = true) -> XCUIElement {
        let value = textField(id)
        for _ in 0..<10 where !value.exists || !value.isHittable { upward ? app.swipeUp() : app.swipeDown() }
        XCTAssertTrue(value.waitForExistence(timeout: 6), "missing field \(id)")
        return value
    }

    @discardableResult private func revealAtTop(_ id: String, swipes: Int = 10) -> XCUIElement {
        let value = element(id)
        for _ in 0..<swipes where !value.exists || !value.isHittable { app.swipeDown() }
        XCTAssertTrue(value.waitForExistence(timeout: 6), "missing top element \(id)")
        return value
    }

    private func hasKeyboardFocus(_ field: XCUIElement) -> Bool {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasKeyboardFocus == true"))[field.identifier]
            .exists
    }

    private func waitForKeyboardFocus(_ field: XCUIElement, timeout: TimeInterval = 0.8) -> Bool {
        if hasKeyboardFocus(field) { return true }
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"),
            object: field
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func focus(_ field: XCUIElement) -> XCUIElement {
        let identifier = field.identifier
        for _ in 0..<3 {
            let current = textField(identifier)
            if hasKeyboardFocus(current) { return current }
            if app.keyboards.firstMatch.exists, current.frame.maxY > 500 {
                app.swipeUp()
            }
            let tappable = textField(identifier)
            tappable.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if waitForKeyboardFocus(tappable) { return tappable }
        }
        XCTFail("failed to focus field \(identifier)")
        return textField(identifier)
    }

    private func replace(_ value: String, in field: XCUIElement) {
        let active = focus(field)
        if let current = active.value as? String, !current.isEmpty {
            active.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        active.typeText(value.isEmpty ? XCUIKeyboardKey.delete.rawValue : value)
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testNewClaimGreyButtonReasonsThenEligibleUncategorizedCandidateCompletes() {
        launch()
        button("v15.f3c.claim.new.open").tap()
        XCTAssertTrue(element("v15.f3c.sheet.claim").waitForExistence(timeout: 6))
        XCTAssertFalse(revealButton("v15.f3c.claim.create", requireHittable: false).isEnabled)
        XCTAssertTrue(app.staticTexts["请填写报销标题。"].exists)
        XCTAssertTrue(app.staticTexts["请填写报销当事人。"].exists)
        replace("八月差旅报销", in: revealTextField("v15.f3c.claim.title", upward: false))
        replace("示例公司", in: revealTextField("v15.f3c.claim.party", upward: false))
        revealButton("v15.f3c.candidate.00000000-0000-0000-0000-00000000C304", swipes: 5).tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "未分类（允许）")).firstMatch.exists)
        replace("2026/08/20", in: revealTextField("v15.f3c.claim.date", upward: false))
        XCTAssertFalse(revealButton("v15.f3c.claim.create", requireHittable: false).isEnabled)
        XCTAssertTrue(app.staticTexts["预计日期必须为 YYYY-MM-DD。"].exists)
        replace(fixtureExpectedDate, in: revealTextField("v15.f3c.claim.date", upward: false))
        XCTAssertTrue(revealButton("v15.f3c.claim.create").isEnabled)
        attach("f3c-ios-claim-invalid-valid")
        revealButton("v15.f3c.claim.create").tap()
        XCTAssertTrue(revealAtTop("v15.f3c.sheet.success").waitForExistence(timeout: 8))
        attach("f3c-ios-claim-success")
    }

    func testReceiptAccountLoadingEmptyErrorRetryAreVisible() {
        launch("reimbursements-receipt-loading")
        revealButton("v15.f3c.receipt.open").tap()
        XCTAssertTrue(element("v15.f3c.sheet.receipt").waitForExistence(timeout: 5))
        XCTAssertTrue(reveal("v15.f3c.receipt.accounts.loading").exists)
        XCTAssertFalse(revealButton("v15.f3c.receipt.preview", requireHittable: false).isEnabled)
        attach("f3c-ios-receipt-loading")

        launch("reimbursements-receipt-empty")
        revealButton("v15.f3c.receipt.open").tap()
        XCTAssertTrue(reveal("v15.f3c.receipt.accounts.empty").waitForExistence(timeout: 7))
        XCTAssertFalse(revealButton("v15.f3c.receipt.preview", requireHittable: false).isEnabled)
        attach("f3c-ios-receipt-empty")

        launch("reimbursements-receipt-retry")
        revealButton("v15.f3c.receipt.open").tap()
        let error = reveal("v15.f3c.receipt.accounts.error")
        XCTAssertTrue(error.waitForExistence(timeout: 7))
        XCTAssertFalse(revealButton("v15.f3c.receipt.preview", requireHittable: false).isEnabled)
        error.buttons["重试"].tap()
        XCTAssertTrue(reveal("v15.f3c.receipt.account.00000000-0000-0000-0000-00000000C306").waitForExistence(timeout: 7))
        XCTAssertTrue(revealButton("v15.f3c.receipt.preview").isEnabled)
        attach("f3c-ios-receipt-retry")
    }

    func testReceiptInvalidValidPreviewInvalidationAndCommitCompletes() {
        launch()
        revealButton("v15.f3c.receipt.open").tap()
        XCTAssertTrue(element("v15.f3c.sheet.receipt").waitForExistence(timeout: 5))
        XCTAssertTrue(reveal("v15.f3c.receipt.account.00000000-0000-0000-0000-00000000C306").waitForExistence(timeout: 6))
        replace(" ", in: revealTextField("v15.f3c.receipt.title", upward: false))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "请填写到账标题。")).firstMatch.waitForExistence(timeout: 3))
        replace("公司回款", in: revealTextField("v15.f3c.receipt.title", upward: false))
        replace("180.001", in: revealTextField("v15.f3c.receipt.amount", upward: false))
        replace("2026-08-16", in: revealTextField("v15.f3c.receipt.date", upward: false))
        XCTAssertFalse(revealButton("v15.f3c.receipt.preview", requireHittable: false).isEnabled)
        XCTAssertTrue(app.staticTexts["到账金额须为正数，且最多两位小数。"].exists)
        replace("180.00", in: revealTextField("v15.f3c.receipt.amount", upward: false))
        replace("2026-08-15", in: revealTextField("v15.f3c.receipt.date", upward: false))
        XCTAssertTrue(revealButton("v15.f3c.receipt.preview").isEnabled)
        revealButton("v15.f3c.receipt.preview").tap()
        XCTAssertTrue(reveal("v15.f3c.receipt.preview.result").waitForExistence(timeout: 7))
        XCTAssertTrue(revealButton("v15.f3c.receipt.commit").isEnabled)
        replace("invalid", in: revealTextField("v15.f3c.receipt.amount", upward: false))
        XCTAssertFalse(element("v15.f3c.receipt.preview.result").exists)
        XCTAssertFalse(revealButton("v15.f3c.receipt.commit", requireHittable: false).isEnabled)
        attach("f3c-ios-receipt-preview-invalidated")
        replace("180.00", in: revealTextField("v15.f3c.receipt.amount", upward: false))
        revealButton("v15.f3c.receipt.preview").tap()
        XCTAssertTrue(reveal("v15.f3c.receipt.preview.result").waitForExistence(timeout: 7))
        revealButton("v15.f3c.receipt.commit").tap()
        XCTAssertTrue(revealAtTop("v15.f3c.sheet.success").waitForExistence(timeout: 8))
        attach("f3c-ios-receipt-success")
    }

    func testReceiptRemoteReasonsAndConflictReloadRepreviewSuccessStayInsideSheet() {
        launch("reimbursements-remote-reasons")
        revealButton("v15.f3c.receipt.open").tap(); revealButton("v15.f3c.receipt.preview").tap()
        XCTAssertTrue(revealAtTop("v15.f3c.sheet.remote-reasons").waitForExistence(timeout: 7))
        XCTAssertTrue(app.staticTexts["该收款账户已停用，请重新选择。"].exists)
        XCTAssertTrue(app.staticTexts["到账标题与服务端规则不符。"].exists)
        XCTAssertTrue(element("v15.f3c.sheet.receipt").exists)
        attach("f3c-ios-receipt-remote-reasons")

        launch("reimbursements-conflict")
        revealButton("v15.f3c.receipt.open").tap(); revealButton("v15.f3c.receipt.preview").tap()
        let conflict = revealAtTop("v15.f3c.sheet.conflict")
        XCTAssertTrue(conflict.waitForExistence(timeout: 7))
        XCTAssertTrue(element("v15.f3c.sheet.receipt").exists)
        attach("f3c-ios-receipt-conflict")
        conflict.buttons["取最新数据重新决定"].tap()
        XCTAssertFalse(element("v15.f3c.sheet.receipt").waitForExistence(timeout: 2))
        revealButton("v15.f3c.receipt.open").tap(); revealButton("v15.f3c.receipt.preview").tap()
        XCTAssertTrue(reveal("v15.f3c.receipt.preview.result").waitForExistence(timeout: 7))
        revealButton("v15.f3c.receipt.commit").tap()
        XCTAssertTrue(revealAtTop("v15.f3c.sheet.success").waitForExistence(timeout: 8))
        attach("f3c-ios-conflict-repreview-success")
    }

    func testCandidateEmptyErrorRetryUnknownStateOfflineAndAX5AreReachable() {
        launch("reimbursements-candidates-empty")
        button("v15.f3c.claim.new.open").tap()
        XCTAssertTrue(reveal("v15.f3c.candidates.empty").waitForExistence(timeout: 7))
        attach("f3c-ios-candidates-empty")

        launch("reimbursements-candidates-retry")
        button("v15.f3c.claim.new.open").tap()
        let error = reveal("v15.f3c.candidates.error")
        XCTAssertTrue(error.waitForExistence(timeout: 7)); error.buttons["重试"].tap()
        XCTAssertTrue(reveal("v15.f3c.candidate.00000000-0000-0000-0000-00000000C304").waitForExistence(timeout: 7))
        attach("f3c-ios-candidates-retry")

        launch()
        revealButton("v15.f3c.claim.00000000-0000-0000-0000-00000000C313").tap()
        XCTAssertTrue(reveal("v15.f3c.claim.unknown-state").waitForExistence(timeout: 7))

        launch("reimbursements-offline", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(element("v15.f3c.offline").waitForExistence(timeout: 6))
        XCTAssertFalse(button("v15.f3c.claim.new.open").isEnabled)
        attach("f3c-ios-offline-ax5")
    }

    func testReceiptUnknownCloseSwitchOwnerReturnAndSameKeyRecovery() {
        launch("reimbursements-receipt-unknown")
        revealButton("v15.f3c.receipt.open").tap()
        XCTAssertTrue(element("v15.f3c.sheet.receipt").waitForExistence(timeout: 6))
        revealButton("v15.f3c.receipt.preview").tap()
        XCTAssertTrue(reveal("v15.f3c.receipt.preview.result").waitForExistence(timeout: 7))
        revealButton("v15.f3c.receipt.commit").tap()
        XCTAssertTrue(revealAtTop("v15.f3c.sheet.unknown").waitForExistence(timeout: 8))
        XCTAssertTrue(revealButton("v15.f3c.receipt.retry-same-key").exists)
        XCTAssertTrue(revealButton("v15.f3c.receipt.abandon").exists)
        XCTAssertFalse(revealButton("v15.f3c.receipt.preview", requireHittable: false).isEnabled)
        XCTAssertTrue(element("v15.f3c.receipt.preview.reasons").exists)
        attach("f3c-ios-receipt-unknown-before-close")
        app.buttons["关闭"].tap()
        XCTAssertFalse(element("v15.f3c.sheet.receipt").waitForExistence(timeout: 2))

        revealButton("v15.f3c.claim.00000000-0000-0000-0000-00000000C313").tap()
        XCTAssertTrue(reveal("v15.f3c.claim.unknown-state").waitForExistence(timeout: 7))
        revealButton("v15.f3c.claim.00000000-0000-0000-0000-00000000C301").tap()
        XCTAssertTrue(revealButton("v15.f3c.receipt.open").waitForExistence(timeout: 7))
        revealButton("v15.f3c.receipt.open").tap()
        XCTAssertTrue(element("v15.f3c.sheet.unknown").waitForExistence(timeout: 7))
        revealButton("v15.f3c.receipt.retry-same-key").tap()
        XCTAssertTrue(revealAtTop("v15.f3c.sheet.success").waitForExistence(timeout: 8))
        attach("f3c-ios-receipt-unknown-reopened-success")
    }

    func testNewClaimUnknownCloseReopenKeepsRecoveryAndSameKeyCompletes() {
        launch("reimbursements-claim-unknown")
        button("v15.f3c.claim.new.open").tap()
        XCTAssertTrue(element("v15.f3c.sheet.claim").waitForExistence(timeout: 6))
        replace("未知恢复报销", in: revealTextField("v15.f3c.claim.title", upward: false))
        replace("示例公司", in: revealTextField("v15.f3c.claim.party", upward: false))
        revealButton("v15.f3c.candidate.00000000-0000-0000-0000-00000000C304", swipes: 5).tap()
        XCTAssertTrue(revealButton("v15.f3c.claim.create").isEnabled)
        revealButton("v15.f3c.claim.create").tap()
        XCTAssertTrue(revealAtTop("v15.f3c.sheet.unknown").waitForExistence(timeout: 8))
        XCTAssertTrue(revealButton("v15.f3c.claim.retry-same-key").exists)
        XCTAssertTrue(revealButton("v15.f3c.claim.abandon").exists)
        XCTAssertFalse(revealButton("v15.f3c.claim.create", requireHittable: false).isEnabled)
        XCTAssertTrue(element("v15.f3c.claim.create.reasons").exists)
        app.buttons["关闭"].tap()
        XCTAssertFalse(element("v15.f3c.sheet.claim").waitForExistence(timeout: 2))
        revealButton("v15.f3c.claim.new.open").tap()
        XCTAssertTrue(element("v15.f3c.sheet.unknown").waitForExistence(timeout: 7))
        revealButton("v15.f3c.claim.retry-same-key").tap()
        XCTAssertTrue(revealAtTop("v15.f3c.sheet.success").waitForExistence(timeout: 8))
        attach("f3c-ios-claim-unknown-reopened-success")
    }

    func testCancelOutstandingUsesSharedDraftAndValidStatusReasons() {
        launch()
        revealButton("v15.f3c.cancel.open").tap()
        XCTAssertTrue(revealButton("v15.f3c.cancel.preview").isEnabled)
        app.buttons["关闭"].tap()

        launch("reimbursements-direct-readback")
        XCTAssertFalse(element("v15.f3c.cancel.open").exists)
        XCTAssertTrue(revealButton("v15.f3c.direct.open").isEnabled)
        attach("f3c-ios-cancel-status-reasons")
    }

    func testEveryBackendApplicableClaimActionEntryIsReachable() {
        let cases: [(String, [String], Bool, Bool)] = [
            ("reimbursements-actions-draft", ["v15.f3c.direct.submit", "v15.f3c.direct.void"], true, false),
            ("reimbursements-actions-pending", ["v15.f3c.direct.retractSubmission"], true, true),
            ("reimbursements-actions-cancelled", ["v15.f3c.direct.reopen", "v15.f3c.direct.archive"], true, false),
            ("reimbursements-actions-voided", ["v15.f3c.direct.restore"], false, false),
            ("reimbursements-actions-received", ["v15.f3c.direct.archive"], true, false),
            ("reimbursements-actions-archived", ["v15.f3c.direct.unarchive"], false, false)
        ]
        for (route, actionIDs, replaceVisible, cancelVisible) in cases {
            launch(route)
            XCTAssertEqual(element("v15.f3c.replace.open").exists, replaceVisible, route)
            XCTAssertEqual(element("v15.f3c.cancel.open").exists, cancelVisible, route)
            if route == "reimbursements-actions-draft" {
                revealButton("v15.f3c.replace.open").tap()
                XCTAssertTrue(element("v15.f3c.sheet.operation").waitForExistence(timeout: 5))
                XCTAssertTrue(revealTextField("v15.f3c.replace.title", upward: false).isEnabled)
                app.buttons["关闭"].tap()
            }
            revealButton("v15.f3c.direct.open").tap()
            XCTAssertTrue(element("v15.f3c.sheet.operation").waitForExistence(timeout: 5))
            for id in actionIDs { XCTAssertTrue(revealButton(id).isEnabled, "missing enabled \(id) for \(route)") }
            attach("f3c-ios-\(route)-actions")
        }
    }

    func testClaimDirectUnknownReadbackStaysLockedUntilExplicitAbandon() {
        launch("reimbursements-direct-readback")
        revealButton("v15.f3c.direct.open").tap()
        revealButton("v15.f3c.direct.void").tap()
        let unknown = reveal("v15.f3c.direct.unknown")
        XCTAssertTrue(unknown.waitForExistence(timeout: 7))
        XCTAssertFalse(revealButton("v15.f3c.direct.abandon", requireHittable: false).isEnabled)
        revealButton("v15.f3c.unknown.readback").tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "仍无法确认")).firstMatch.waitForExistence(timeout: 7))
        XCTAssertTrue(revealButton("v15.f3c.direct.abandon").isEnabled)
        revealButton("v15.f3c.direct.abandon").tap()
        XCTAssertFalse(element("v15.f3c.direct.unknown").waitForExistence(timeout: 2))
        attach("f3c-ios-direct-unknown-readback-abandon")
    }

    func testReceiptReplaceThenVoidRestoreRefreshesClaimFacts() {
        launch()
        revealButton("v15.f3c.receipt.actions.00000000-0000-0000-0000-00000000C307").tap()
        XCTAssertTrue(element("v15.f3c.sheet.operation").waitForExistence(timeout: 5))
        revealButton("v15.f3c.receipt.replace.open").tap()
        XCTAssertTrue(revealTextField("v15.f3c.receipt.replace.amount", upward: false).waitForExistence(timeout: 5))
        replace("100.00", in: revealTextField("v15.f3c.receipt.replace.amount", upward: false))
        revealButton("v15.f3c.receipt.replace.preview").tap()
        XCTAssertTrue(reveal("v15.f3c.receipt.replace.preview.result").waitForExistence(timeout: 7))
        revealButton("v15.f3c.receipt.replace.commit").tap()
        XCTAssertTrue(reveal("v15.f3c.secondary.success").waitForExistence(timeout: 8))
        XCTAssertFalse(element("v15.f3c.fact-refresh.required").exists)
        app.buttons["关闭"].tap()

        revealButton("v15.f3c.receipt.actions.00000000-0000-0000-0000-00000000C307").tap()
        revealButton("v15.f3c.receipt.direct.void").tap()
        XCTAssertTrue(revealButton("v15.f3c.receipt.direct.restore").waitForExistence(timeout: 8))
        XCTAssertFalse(element("v15.f3c.fact-refresh.required").exists)
        revealButton("v15.f3c.receipt.direct.restore").tap()
        XCTAssertTrue(revealButton("v15.f3c.receipt.direct.void").waitForExistence(timeout: 8))
        XCTAssertFalse(element("v15.f3c.fact-refresh.required").exists)
        attach("f3c-ios-receipt-replace-void-restore")
    }

    func testReceiptRefreshFailureShowsPartialSuccessAndGetOnlyRetry() {
        launch("reimbursements-receipt-refresh-failure")
        revealButton("v15.f3c.receipt.actions.00000000-0000-0000-0000-00000000C307").tap()
        revealButton("v15.f3c.receipt.replace.open").tap()
        replace("100.00", in: revealTextField("v15.f3c.receipt.replace.amount", upward: false))
        revealButton("v15.f3c.receipt.replace.preview").tap()
        revealButton("v15.f3c.receipt.replace.commit").tap()
        let gate = reveal("v15.f3c.fact-refresh.required")
        XCTAssertTrue(gate.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "到账已经保存")).firstMatch.exists)
        XCTAssertTrue(revealButton("v15.f3c.fact-refresh.retry").isEnabled)
        app.buttons["关闭"].tap()
        XCTAssertTrue(reveal("v15.f3c.fact-refresh.required").waitForExistence(timeout: 5))
        revealButton("v15.f3c.fact-refresh.retry").tap()
        XCTAssertFalse(element("v15.f3c.fact-refresh.required").waitForExistence(timeout: 3))
        XCTAssertTrue(element("v15.f3c.secondary.success").waitForExistence(timeout: 5))
        attach("f3c-ios-receipt-refresh-recovered")
    }
}
