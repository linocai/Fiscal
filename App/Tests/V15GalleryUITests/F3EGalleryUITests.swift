import XCTest

@MainActor final class F3EGalleryUITests: XCTestCase {
    private var app = XCUIApplication()

    private func launch(_ route: String = "reconciliation", extra: [String] = []) {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--v15-f3e-route", route, "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryLarge"] + extra
        app.launch()
        XCTAssertTrue(element("v15.f3e.reconciliation.ios").waitForExistence(timeout: 10))
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
    private func button(_ id: String) -> XCUIElement { app.buttons[id] }
    private func editorElement(_ id: String) -> XCUIElement { element("v15.f3e.editor").descendants(matching: .any)[id] }
    private func editorButton(_ id: String) -> XCUIElement { element("v15.f3e.editor").descendants(matching: .button)[id] }
    private func labelledElement(containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @discardableResult private func revealLabel(containing text: String, swipes: Int = 6) -> XCUIElement {
        let value = labelledElement(containing: text)
        for _ in 0..<swipes where !value.exists { app.swipeUp() }
        XCTAssertTrue(value.waitForExistence(timeout: 6), "missing label containing \(text)")
        return value
    }

    @discardableResult private func reveal(_ id: String, swipes: Int = 12, down: Bool = false) -> XCUIElement {
        let value = element(id)
        for _ in 0..<swipes {
            if value.exists { break }
            down ? app.swipeDown() : app.swipeUp()
        }
        XCTAssertTrue(value.waitForExistence(timeout: 6), "missing \(id)")
        return value
    }

    @discardableResult private func revealButton(_ id: String, enabled: Bool? = nil, swipes: Int = 12, down: Bool = false) -> XCUIElement {
        let value = button(id)
        for _ in 0..<swipes {
            if value.exists, enabled == false || value.isHittable { break }
            down ? app.swipeDown() : app.swipeUp()
        }
        XCTAssertTrue(value.waitForExistence(timeout: 6), "missing button \(id)")
        if let enabled { XCTAssertEqual(value.isEnabled, enabled, "unexpected enabled state for \(id)") }
        return value
    }

    @discardableResult private func revealEditorButton(_ id: String, enabled: Bool? = nil, swipes: Int = 12, down: Bool = false) -> XCUIElement {
        let value = editorButton(id)
        for _ in 0..<swipes {
            if value.exists, enabled == false || value.isHittable { break }
            down ? app.swipeDown() : app.swipeUp()
        }
        XCTAssertTrue(value.waitForExistence(timeout: 6), "missing editor button \(id)")
        if let enabled { XCTAssertEqual(value.isEnabled, enabled, "unexpected editor enabled state for \(id)") }
        return value
    }

    private func replace(_ text: String, in fieldID: String) {
        let field = app.textFields[fieldID]
        for _ in 0..<8 where !field.exists || !field.isHittable { app.swipeUp() }
        XCTAssertTrue(field.waitForExistence(timeout: 6), "missing field \(fieldID)")
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 32) + text)
        let dismiss = app.keyboards.buttons["Return"]
        if dismiss.waitForExistence(timeout: 1) { dismiss.tap() }
    }

    private func openFilledEditor() {
        revealButton("v15.f3e.editor.open").tap()
        XCTAssertTrue(element("v15.f3e.editor.step1").waitForExistence(timeout: 6))
        revealButton("v15.f3e.editor.next", enabled: true).tap()
        XCTAssertTrue(element("v15.f3e.editor.step2").waitForExistence(timeout: 6))
        replace("1234.56", in: "v15.f3e.editor.amount")
        revealButton("v15.f3e.editor.next", enabled: true).tap()
        XCTAssertTrue(element("v15.f3e.editor.step3").waitForExistence(timeout: 6))
    }

    private func attach(_ name: String) {
        let value = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        value.name = name
        value.lifetime = .keepAlways
        add(value)
    }

    func testFactsTargetsAndBackendOwnedAttentionReasonsAreReachable() {
        launch()
        XCTAssertTrue(reveal("v15.f3e.checkpoint.00000000-0000-0000-0000-00000000E321").waitForExistence(timeout: 6))
        let disabled = revealButton("v15.f3e.attention.ignore.statement_import_failed:00000000-0000-0000-0000-00000000E342", enabled: false)
        XCTAssertFalse(disabled.isEnabled)
        revealLabel(containing: "Statement import attention cannot be ignored")
        let unknown = revealButton("v15.f3e.attention.ignore.future_attention:00000000-0000-0000-0000-00000000E343", enabled: false)
        XCTAssertFalse(unknown.isEnabled)
        revealLabel(containing: "此事项目前不能安全忽略。")
        attach("f3e-ios-facts-and-backend-actions")

        revealButton("v15.f3e.kind.cycle", down: true).tap()
        XCTAssertTrue(reveal("v15.f3e.target.credit_cycle:00000000-0000-0000-0000-00000000E311", down: true).waitForExistence(timeout: 8))
    }

    func testThreeStepEditorShowsEveryReasonThenSavesAndRefreshesFacts() {
        launch()
        revealButton("v15.f3e.editor.open").tap()
        revealButton("v15.f3e.editor.next", enabled: true).tap()
        XCTAssertFalse(revealButton("v15.f3e.editor.next", enabled: false).isEnabled)
        XCTAssertTrue(app.staticTexts["实际余额须为最多两位小数的人民币金额，可为负数或零。"].exists)
        replace("12.345", in: "v15.f3e.editor.amount")
        XCTAssertFalse(revealButton("v15.f3e.editor.next", enabled: false).isEnabled)
        replace("-1234.56", in: "v15.f3e.editor.amount")
        revealButton("v15.f3e.editor.next", enabled: true).tap()
        XCTAssertTrue(element("v15.f3e.editor.step3").waitForExistence(timeout: 6))
        XCTAssertTrue(revealButton("v15.f3e.editor.submit", enabled: true).isEnabled)
        attach("f3e-ios-three-step-valid")
        revealButton("v15.f3e.editor.submit").tap()
        XCTAssertTrue(revealButton("v15.f3e.editor.done", enabled: true).isEnabled)
        revealButton("v15.f3e.editor.done").tap()
        XCTAssertTrue(element("v15.f3e.editor").waitForNonExistence(timeout: 8))
        XCTAssertTrue(reveal("v15.f3e.checkpoint.00000000-0000-0000-0000-00000000E323", down: true).waitForExistence(timeout: 8))
    }

    func testLongDiagnosisKeepsStepTwoInputAndNextActionReachable() {
        launch("reconciliation-long")
        revealButton("v15.f3e.editor.open").tap()
        revealButton("v15.f3e.editor.next", enabled: true).tap()
        XCTAssertTrue(element("v15.f3e.editor.step2").waitForExistence(timeout: 6))
        let amount = app.textFields["v15.f3e.editor.amount"]
        let next = app.buttons["v15.f3e.editor.next"]
        XCTAssertTrue(amount.waitForExistence(timeout: 6))
        XCTAssertTrue(next.waitForExistence(timeout: 6))
        XCTAssertTrue(amount.isHittable, "long diagnosis must not cover the actual-balance field")
        XCTAssertTrue(next.isHittable, "long diagnosis must not push the next action below its evidence list")
    }

    func testFieldErrorsRemainInEditorAndKeylessUnknownOnlyReadsThenAbandons() {
        launch("reconciliation-field-error")
        openFilledEditor()
        revealButton("v15.f3e.editor.submit").tap()
        XCTAssertTrue(reveal("v15.f3e.editor.remote-issues", down: true).waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["实际余额超出服务端允许范围。"].exists)
        XCTAssertTrue(app.staticTexts["备注不符合服务端规则。"].exists)
        XCTAssertTrue(element("v15.f3e.editor").exists)
        attach("f3e-ios-field-errors-in-sheet")

        launch("reconciliation-unknown")
        openFilledEditor()
        revealButton("v15.f3e.editor.submit").tap()
        XCTAssertTrue(editorElement("v15.f3e.unknown").waitForExistence(timeout: 8))
        XCTAssertFalse(revealEditorButton("v15.f3e.unknown.abandon", enabled: false, down: true).isEnabled)
        revealEditorButton("v15.f3e.unknown.readback", down: true).tap()
        XCTAssertTrue(revealEditorButton("v15.f3e.unknown.abandon", enabled: true, down: true).isEnabled)
        attach("f3e-ios-keyless-fresh-readback")
        revealEditorButton("v15.f3e.unknown.abandon", down: true).tap()
        XCTAssertFalse(editorElement("v15.f3e.unknown").exists)
    }

    func testCancelledCheckpointResponseClosesReopensAndUsesFreshGETOnlyRecovery() {
        launch("reconciliation-cancelled-unknown")
        openFilledEditor()
        revealEditorButton("v15.f3e.editor.submit").tap()
        XCTAssertTrue(editorElement("v15.f3e.unknown").waitForExistence(timeout: 8))
        XCTAssertFalse(editorElement("v15.f3e.mutation.retry").exists)
        revealEditorButton("v15.f3e.editor.close", enabled: true).tap()
        XCTAssertTrue(element("v15.f3e.editor").waitForNonExistence(timeout: 8))

        revealButton("v15.f3e.editor.open", enabled: true).tap()
        XCTAssertTrue(editorElement("v15.f3e.unknown").waitForExistence(timeout: 8))
        revealEditorButton("v15.f3e.unknown.readback", enabled: true, down: true).tap()
        XCTAssertTrue(revealEditorButton("v15.f3e.unknown.abandon", enabled: true, down: true).isEnabled)
        attach("f3e-ios-cancelled-unknown-reopened")
        revealEditorButton("v15.f3e.unknown.abandon", down: true).tap()
        XCTAssertFalse(editorElement("v15.f3e.unknown").exists)
    }

    func testDeterministicFailureRetriesTheCapturedTodayIntentAfterTimeAdvances() {
        launch("reconciliation-mutation-error")
        openFilledEditor()
        revealEditorButton("v15.f3e.editor.submit").tap()
        XCTAssertTrue(editorElement("v15.f3e.mutation.error").waitForExistence(timeout: 8))
        let retry = revealEditorButton("v15.f3e.mutation.retry", enabled: true, down: true)

        // The first request used today's visible date. Advancing wall time must
        // not make retry compare a newly synthesized Date with the captured one.
        Thread.sleep(forTimeInterval: 0.35)
        retry.tap()

        XCTAssertTrue(editorElement("v15.f3e.success").waitForExistence(timeout: 10))
        XCTAssertTrue(revealEditorButton("v15.f3e.editor.done", enabled: true, down: true).isEnabled)
        attach("f3e-ios-deterministic-retry-captured-today")
    }

    func testEmptyErrorDiagnosisErrorOfflineConflictAndPartialRefreshAreReachable() {
        launch("reconciliation-empty")
        XCTAssertTrue(reveal("v15.f3e.checkpoints.empty").waitForExistence(timeout: 6))
        launch("reconciliation-error")
        XCTAssertTrue(reveal("v15.f3e.targets.error").waitForExistence(timeout: 6))
        launch("reconciliation-diagnosis-error")
        XCTAssertTrue(reveal("v15.f3e.diagnosis.error").waitForExistence(timeout: 6))
        launch("reconciliation-offline")
        XCTAssertTrue(reveal("v15.f3e.offline").waitForExistence(timeout: 6))
        XCTAssertFalse(revealButton("v15.f3e.editor.open", enabled: false).isEnabled)

        launch("reconciliation-conflict")
        XCTAssertTrue(reveal("v15.f3e.conflict").waitForExistence(timeout: 8))
        launch("reconciliation-partial-refresh")
        openFilledEditor()
        revealButton("v15.f3e.editor.submit").tap()
        XCTAssertTrue(editorElement("v15.f3e.fact-refresh").waitForExistence(timeout: 8))
        let retry = editorButton("v15.f3e.fact-refresh.retry")
        XCTAssertTrue(retry.waitForExistence(timeout: 8))
        XCTAssertTrue(retry.isEnabled)
        attach("f3e-ios-partial-refresh-get-only")
    }
}
