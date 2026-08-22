import XCTest

@MainActor final class F3B1GalleryUITests: XCTestCase {
    private var app = XCUIApplication()
    private func launch(_ route: String, extra: [String] = []) {
        app.terminate(); app = XCUIApplication(); app.launchArguments = ["--v15-f3b1-route", route] + extra; app.launch()
        XCTAssertTrue(app.otherElements["v15.f3b1.credit.ios"].waitForExistence(timeout: 8))
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
    private func replace(_ value: String, in element: XCUIElement) { element.tap(); element.press(forDuration: 0.8); app.menuItems["Select All"].tap(); element.typeText(value) }
    private func attach(_ name: String) { let value = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); value.name = name; value.lifetime = .keepAlways; add(value) }

    func testSchedulePreviewInvalidationConflictSuccessAndReceiptAreReachable() {
        launch("credit")
        let open = element("v15.f3b1.schedule.open"); XCTAssertTrue(open.waitForExistence(timeout: 5)); open.tap()
        XCTAssertTrue(element("v15.f3b1.schedule.sheet").waitForExistence(timeout: 5))
        let statement = element("v15.f3b1.schedule.statement-day"); XCTAssertTrue(statement.waitForExistence(timeout: 3)); replace("29", in: statement)
        element("v15.f3b1.schedule.preview").tap(); XCTAssertTrue(element("v15.f3b1.schedule.local-reasons").waitForExistence(timeout: 4)); attach("f3b1-ios-invalid")
        replace("25", in: statement); element("v15.f3b1.schedule.preview").tap()
        XCTAssertTrue(element("v15.f3b1.schedule.preview").waitForExistence(timeout: 5)); XCTAssertTrue(element("v15.f3b1.schedule.commit").isEnabled)
        element("v15.f3b1.schedule.commit").tap(); XCTAssertTrue(element("v15.f3b1.schedule.receipt").waitForExistence(timeout: 6)); attach("f3b1-ios-receipt")
        launch("credit-conflict"); element("v15.f3b1.schedule.open").tap(); element("v15.f3b1.schedule.preview").tap(); XCTAssertTrue(element("v15.f3b1.schedule.preview").waitForExistence(timeout: 5)); element("v15.f3b1.schedule.commit").tap(); XCTAssertTrue(element("v15.f3b1.schedule.conflict").waitForExistence(timeout: 5)); attach("f3b1-ios-conflict")
    }
    func testOfflineAndAX5ShowReadonlyReasonWithoutWriteEntry() {
        launch("credit-offline", extra: ["--v15-f1a-appearance", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(element("v15.f3b1.offline").waitForExistence(timeout: 5)); XCTAssertFalse(element("v15.f3b1.schedule.open").isEnabled); attach("f3b1-ios-offline-ax5")
    }
    func testConflictReloadFailureStaysInSheetUntilRetryThenRequiresNewPreview() {
        launch("credit-reload-fails"); element("v15.f3b1.schedule.open").tap(); element("v15.f3b1.schedule.preview").tap()
        XCTAssertTrue(element("v15.f3b1.schedule.preview").waitForExistence(timeout: 5)); element("v15.f3b1.schedule.commit").tap()
        XCTAssertTrue(element("v15.f3b1.schedule.conflict").waitForExistence(timeout: 5)); element("v15.f3b1.schedule.conflict.reload").tap()
        XCTAssertTrue(element("v15.f3b1.schedule.conflict.reload-error").waitForExistence(timeout: 5)); XCTAssertFalse(element("v15.f3b1.schedule.commit").exists)
        element("v15.f3b1.schedule.conflict.reload").tap(); element("v15.f3b1.schedule.preview").tap(); XCTAssertTrue(element("v15.f3b1.schedule.commit").waitForExistence(timeout: 5)); attach("f3b1-ios-conflict-reloaded")
    }
    func testRapidAtoBAccountSwitchKeepsBVersionCyclesDraftAndPreview() {
        launch("credit-account-race")
        let picker = element("v15.f3b1.account-picker")
        XCTAssertTrue(picker.waitForExistence(timeout: 5)); picker.tap()
        let secondAccount = element("v15.f3b1.account.00000000-0000-0000-0000-00000000B312")
        XCTAssertTrue(secondAccount.waitForExistence(timeout: 3)); secondAccount.tap()
        let secondCycle = element("v15.f3b1.cycle.00000000-0000-0000-0000-00000000B323")
        XCTAssertTrue(secondCycle.waitForExistence(timeout: 6))
        XCTAssertTrue(picker.label.contains("旅行信用账户"))
        element("v15.f3b1.schedule.open").tap()
        let statement = element("v15.f3b1.schedule.statement-day")
        let due = element("v15.f3b1.schedule.due-day")
        XCTAssertTrue(statement.waitForExistence(timeout: 3) && due.waitForExistence(timeout: 3))
        XCTAssertEqual(statement.value as? String, "18")
        XCTAssertEqual(due.value as? String, "3")
        element("v15.f3b1.schedule.preview").tap()
        XCTAssertTrue(element("v15.f3b1.schedule.preview").waitForExistence(timeout: 5))
        let version = element("v15.f3b1.schedule.preview.account-version")
        XCTAssertTrue(version.waitForExistence(timeout: 3)); XCTAssertTrue(version.label.contains("7")); attach("f3b1-ios-account-race-b-preview")
    }
    func testUnknownAIsInvisibleOnBAndReturnsOnlyToAWithSameKeyRecovery() {
        launch("credit-account-unknown")
        element("v15.f3b1.schedule.open").tap()
        replace("25", in: element("v15.f3b1.schedule.statement-day")); replace("10", in: element("v15.f3b1.schedule.due-day"))
        element("v15.f3b1.schedule.preview").tap(); XCTAssertTrue(element("v15.f3b1.schedule.commit").waitForExistence(timeout: 5))
        element("v15.f3b1.schedule.commit").tap(); XCTAssertTrue(element("v15.f3b1.schedule.unknown").waitForExistence(timeout: 5))
        app.buttons["v15.f3b1.schedule.dismiss"].tap()
        let picker = element("v15.f3b1.account-picker"); picker.tap()
        let second = element("v15.f3b1.account.00000000-0000-0000-0000-00000000B312")
        XCTAssertTrue(second.waitForExistence(timeout: 3)); second.tap()
        XCTAssertTrue(element("v15.f3b1.cycle.00000000-0000-0000-0000-00000000B323").waitForExistence(timeout: 6))
        element("v15.f3b1.schedule.open").tap()
        XCTAssertFalse(element("v15.f3b1.schedule.unknown").exists)
        element("v15.f3b1.schedule.preview").tap(); XCTAssertTrue(element("v15.f3b1.schedule.commit").waitForExistence(timeout: 5))
        element("v15.f3b1.schedule.commit").tap(); XCTAssertTrue(element("v15.f3b1.schedule.receipt").waitForExistence(timeout: 6))
        app.buttons["v15.f3b1.schedule.dismiss"].tap(); picker.tap()
        let first = element("v15.f3b1.account.00000000-0000-0000-0000-00000000B311")
        XCTAssertTrue(first.waitForExistence(timeout: 3)); first.tap()
        element("v15.f3b1.schedule.open").tap()
        XCTAssertTrue(element("v15.f3b1.schedule.unknown").waitForExistence(timeout: 5))
        element("v15.f3b1.schedule.unknown.retry").tap()
        XCTAssertTrue(element("v15.f3b1.schedule.receipt").waitForExistence(timeout: 6)); attach("f3b1-ios-account-scoped-unknown")
    }
    func testUnknownCommandDisablesPreviewAndCommitWithRecoveryReasonUntilSameKeyReplay() {
        launch("credit-unknown")
        element("v15.f3b1.schedule.open").tap()
        replace("25", in: element("v15.f3b1.schedule.statement-day")); replace("10", in: element("v15.f3b1.schedule.due-day"))
        element("v15.f3b1.schedule.preview").tap()
        XCTAssertTrue(element("v15.f3b1.schedule.commit").waitForExistence(timeout: 5))
        element("v15.f3b1.schedule.commit").tap()
        XCTAssertTrue(element("v15.f3b1.schedule.unknown").waitForExistence(timeout: 5))
        let preview = app.buttons["v15.f3b1.schedule.preview"]
        let commit = app.buttons["v15.f3b1.schedule.commit"]
        XCTAssertFalse(preview.isEnabled)
        XCTAssertFalse(commit.isEnabled)
        XCTAssertTrue(element("v15.f3b1.schedule.preview-reason").waitForExistence(timeout: 5))
        XCTAssertTrue(element("v15.f3b1.schedule.commit-reason").waitForExistence(timeout: 5))
        XCTAssertTrue(element("v15.f3b1.schedule.unknown.retry").exists && element("v15.f3b1.schedule.unknown.readback").exists && element("v15.f3b1.schedule.unknown.abandon").exists)
        element("v15.f3b1.schedule.unknown.retry").tap()
        XCTAssertTrue(element("v15.f3b1.schedule.receipt").waitForExistence(timeout: 12))
        XCTAssertTrue(preview.isEnabled)
        preview.tap()
        XCTAssertTrue(element("v15.f3b1.schedule.commit").waitForExistence(timeout: 5)); attach("f3b1-ios-unknown-command-hard-gate")
    }
    func testPostSuccessRefreshKeepsPreviewAndCommitHardGatedUntilReceipt() {
        launch("credit-post-success-reload")
        element("v15.f3b1.schedule.open").tap()
        element("v15.f3b1.schedule.preview").tap()
        XCTAssertTrue(element("v15.f3b1.schedule.commit").waitForExistence(timeout: 5))
        element("v15.f3b1.schedule.commit").tap()
        XCTAssertTrue(element("v15.f3b1.schedule.committing").waitForExistence(timeout: 5))
        let preview = app.buttons["v15.f3b1.schedule.preview"]
        let commit = app.buttons["v15.f3b1.schedule.commit"]
        XCTAssertFalse(preview.isEnabled)
        XCTAssertFalse(commit.isEnabled)
        XCTAssertTrue(element("v15.f3b1.schedule.preview-reason").waitForExistence(timeout: 5))
        XCTAssertTrue(element("v15.f3b1.schedule.commit-reason").waitForExistence(timeout: 5))
        XCTAssertTrue(element("v15.f3b1.schedule.receipt").waitForExistence(timeout: 12))
        XCTAssertTrue(preview.isEnabled)
        preview.tap()
        XCTAssertTrue(element("v15.f3b1.schedule.commit").waitForExistence(timeout: 5)); attach("f3b1-ios-post-success-refresh-gate")
    }
    func testUnknownReadbackKeepsSameKeyRecoveryUntilFactsConfirmIt() {
        launch("credit-unknown-readback-fails"); element("v15.f3b1.schedule.open").tap()
        replace("25", in: element("v15.f3b1.schedule.statement-day")); replace("10", in: element("v15.f3b1.schedule.due-day")); element("v15.f3b1.schedule.preview").tap()
        XCTAssertTrue(element("v15.f3b1.schedule.preview").waitForExistence(timeout: 5)); element("v15.f3b1.schedule.commit").tap()
        XCTAssertTrue(element("v15.f3b1.schedule.unknown").waitForExistence(timeout: 5)); element("v15.f3b1.schedule.unknown.readback").tap()
        XCTAssertTrue(element("v15.f3b1.schedule.unknown.readback.error").waitForExistence(timeout: 5))
        XCTAssertTrue(element("v15.f3b1.schedule.unknown.retry").exists && element("v15.f3b1.schedule.unknown.readback").exists)
        element("v15.f3b1.schedule.unknown.retry").tap(); XCTAssertTrue(element("v15.f3b1.schedule.receipt").waitForExistence(timeout: 6)); attach("f3b1-ios-unknown-readback-replay")
        launch("credit-unknown-readback-match"); element("v15.f3b1.schedule.open").tap()
        replace("25", in: element("v15.f3b1.schedule.statement-day")); replace("10", in: element("v15.f3b1.schedule.due-day")); element("v15.f3b1.schedule.preview").tap(); XCTAssertTrue(element("v15.f3b1.schedule.preview").waitForExistence(timeout: 5)); element("v15.f3b1.schedule.commit").tap()
        XCTAssertTrue(element("v15.f3b1.schedule.unknown").waitForExistence(timeout: 5)); element("v15.f3b1.schedule.unknown.readback").tap()
        XCTAssertTrue(element("v15.f3b1.schedule.readback-confirmed").waitForExistence(timeout: 6)); attach("f3b1-ios-unknown-readback-confirmed")
        launch("credit-unknown-readback-offline"); element("v15.f3b1.schedule.open").tap()
        replace("25", in: element("v15.f3b1.schedule.statement-day")); replace("10", in: element("v15.f3b1.schedule.due-day")); element("v15.f3b1.schedule.preview").tap(); XCTAssertTrue(element("v15.f3b1.schedule.preview").waitForExistence(timeout: 5)); element("v15.f3b1.schedule.commit").tap()
        XCTAssertTrue(element("v15.f3b1.schedule.unknown").waitForExistence(timeout: 5)); element("v15.f3b1.schedule.unknown.readback").tap()
        let offlineReadback = element("v15.f3b1.schedule.unknown.readback.not-confirmed")
        XCTAssertTrue(offlineReadback.waitForExistence(timeout: 6)); XCTAssertTrue(offlineReadback.label.contains("离线快照不能核对当前服务器事实")); XCTAssertTrue(element("v15.f3b1.schedule.unknown.retry").exists)
        launch("credit-unknown-offline-recovery"); element("v15.f3b1.schedule.open").tap()
        replace("25", in: element("v15.f3b1.schedule.statement-day")); replace("10", in: element("v15.f3b1.schedule.due-day")); element("v15.f3b1.schedule.preview").tap(); XCTAssertTrue(element("v15.f3b1.schedule.preview").waitForExistence(timeout: 5)); element("v15.f3b1.schedule.commit").tap()
        XCTAssertTrue(element("v15.f3b1.schedule.unknown").waitForExistence(timeout: 5))
        let retry = element("v15.f3b1.schedule.unknown.retry")
        XCTAssertFalse(retry.isEnabled); XCTAssertTrue(element("v15.f3b1.schedule.unknown.retry-reason").waitForExistence(timeout: 5))
        element("v15.f3b1.schedule.unknown.readback").tap(); XCTAssertTrue(element("v15.f3b1.schedule.unknown.readback.not-confirmed").waitForExistence(timeout: 5))
        element("v15.f3b1.fixture.reconnect").tap(); XCTAssertTrue(retry.waitForExistence(timeout: 5)); XCTAssertTrue(retry.isEnabled)
        retry.tap(); XCTAssertTrue(element("v15.f3b1.schedule.receipt").waitForExistence(timeout: 6)); attach("f3b1-ios-unknown-offline-recovered")
    }
}
