import XCTest

@MainActor final class F3DGalleryUITests: XCTestCase {
    private var app = XCUIApplication()

    private func launch(_ route: String = "cash-flow", extra: [String] = []) {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--v15-f3d-route", route, "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryLarge"] + extra
        app.launch()
        XCTAssertTrue(element("v15.f3d.cash-flow.ios").waitForExistence(timeout: 10))
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
    private func button(_ id: String) -> XCUIElement { app.buttons[id] }

    @discardableResult private func reveal(_ id: String, swipes: Int = 10, down: Bool = false) -> XCUIElement {
        let value = element(id)
        for _ in 0..<swipes {
            if value.exists { break }
            down ? app.swipeDown() : app.swipeUp()
        }
        XCTAssertTrue(value.waitForExistence(timeout: 6), "missing \(id)")
        return value
    }

    @discardableResult private func revealButton(_ id: String, enabled: Bool? = nil, swipes: Int = 10) -> XCUIElement {
        let value = button(id)
        for _ in 0..<swipes {
            if value.exists, value.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(value.waitForExistence(timeout: 6), "missing button \(id)")
        if let enabled { XCTAssertEqual(value.isEnabled, enabled, "unexpected enabled state for \(id)") }
        return value
    }

    private func replace(_ text: String, in fieldID: String) {
        let field = app.textFields[fieldID]
        for _ in 0..<8 where !field.exists || !field.isHittable { app.swipeDown() }
        XCTAssertTrue(field.waitForExistence(timeout: 6), "missing field \(fieldID)")
        field.tap()
        field.press(forDuration: 0.7)
        var selectedAll = false
        if app.menuItems["Select All"].waitForExistence(timeout: 1) { app.menuItems["Select All"].tap(); selectedAll = true }
        else if app.menuItems["全选"].waitForExistence(timeout: 1) { app.menuItems["全选"].tap(); selectedAll = true }
        if !selectedAll, let current = field.value as? String, !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text.isEmpty ? XCUIKeyboardKey.delete.rawValue : text)
    }

    private func attach(_ name: String) {
        let value = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        value.name = name; value.lifetime = .keepAlways; add(value)
    }

    func testActiveHistoryDetailEmptyErrorOfflineAndUnknownAreReachable() {
        launch()
        XCTAssertTrue(element("v15.f3d.summary").waitForExistence(timeout: 6))
        revealButton("v15.f3d.item.00000000-0000-0000-0000-00000000D311").tap()
        XCTAssertTrue(reveal("v15.f3d.detail").waitForExistence(timeout: 6))
        attach("f3d-ios-active-detail")

        element("v15.f3d.scope").buttons["历史"].tap()
        XCTAssertTrue(reveal("v15.f3d.item.00000000-0000-0000-0000-00000000D313").waitForExistence(timeout: 6))
        XCTAssertTrue(element("v15.f3d.item.00000000-0000-0000-0000-00000000D311").waitForNonExistence(timeout: 6))

        launch("cash-flow-empty")
        XCTAssertTrue(reveal("v15.f3d.active.empty").waitForExistence(timeout: 6))
        launch("cash-flow-error")
        XCTAssertTrue(reveal("v15.f3d.active.error").waitForExistence(timeout: 6))
        launch("cash-flow-offline")
        XCTAssertTrue(reveal("v15.f3d.offline").waitForExistence(timeout: 6))
        XCTAssertFalse(revealButton("v15.f3d.create.open", enabled: false).isEnabled)
        launch("cash-flow-long")
        let unknownStatus = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "未知状态（future_state）"))
            .firstMatch
        XCTAssertTrue(unknownStatus.waitForExistence(timeout: 8))
        attach("f3d-ios-display-only-ax5")
    }

    func testCreateShowsEveryReasonThenCompletesAndFieldIssuesStayInSheet() {
        launch()
        revealButton("v15.f3d.create.open").tap()
        XCTAssertTrue(element("v15.f3d.editor").waitForExistence(timeout: 6))
        XCTAssertFalse(revealButton("v15.f3d.create.submit", enabled: false).isEnabled)
        XCTAssertTrue(app.staticTexts["请填写标题。"].exists)
        XCTAssertTrue(app.staticTexts["计划金额须为正数，最多两位小数。"].exists)
        replace("新建现金流", in: "v15.f3d.editor.title")
        replace("12.345", in: "v15.f3d.editor.amount")
        XCTAssertFalse(revealButton("v15.f3d.create.submit", enabled: false).isEnabled)
        XCTAssertTrue(app.staticTexts["计划金额须为正数，最多两位小数。"].exists)
        replace("123.45", in: "v15.f3d.editor.amount")
        XCTAssertTrue(revealButton("v15.f3d.create.submit", enabled: true).isEnabled)
        attach("f3d-ios-create-invalid-valid")
        revealButton("v15.f3d.create.submit").tap()
        XCTAssertTrue(element("v15.f3d.editor").waitForNonExistence(timeout: 8))
        XCTAssertTrue(reveal("v15.f3d.item.00000000-0000-0000-0000-00000000D314").waitForExistence(timeout: 8))

        launch("cash-flow-field-error")
        revealButton("v15.f3d.create.open").tap()
        replace("字段原因", in: "v15.f3d.editor.title")
        replace("123.45", in: "v15.f3d.editor.amount")
        revealButton("v15.f3d.create.submit").tap()
        XCTAssertTrue(reveal("v15.f3d.editor.remote-issues", down: true).waitForExistence(timeout: 7))
        XCTAssertTrue(app.staticTexts["标题不可用。"].exists)
        XCTAssertTrue(app.staticTexts["账户已停用。"].exists)
        XCTAssertTrue(element("v15.f3d.editor").exists)
        attach("f3d-ios-field-errors-in-sheet")
    }

    func testSeriesEditKeepsBoundaryServerOwnedAndHidesCreateOnlyControls() {
        launch()
        revealButton("v15.f3d.item.00000000-0000-0000-0000-00000000D311").tap()
        revealButton("v15.f3d.edit.open").tap()
        XCTAssertTrue(element("v15.f3d.editor").waitForExistence(timeout: 6))
        XCTAssertFalse(element("v15.f3d.editor.recurrence").exists)
        XCTAssertFalse(element("v15.f3d.editor.recurrence-end").exists)
        XCTAssertTrue(reveal("v15.f3d.editor.series-boundary", down: true).waitForExistence(timeout: 6))
        XCTAssertTrue(revealButton("v15.f3d.update.submit", enabled: true).isEnabled)
        attach("f3d-ios-server-owned-series-boundary")
    }

    func testSettleUnknownSameKeyRecoveryAndDirectUnknownFreshReadback() {
        launch("cash-flow-unknown")
        revealButton("v15.f3d.item.00000000-0000-0000-0000-00000000D312").tap()
        revealButton("v15.f3d.settle.open").tap()
        XCTAssertTrue(element("v15.f3d.editor").waitForExistence(timeout: 6))
        XCTAssertTrue(revealButton("v15.f3d.settle.submit", enabled: true).isEnabled)
        revealButton("v15.f3d.settle.submit").tap()
        XCTAssertTrue(reveal("v15.f3d.unknown", down: true).waitForExistence(timeout: 8))
        XCTAssertTrue(revealButton("v15.f3d.unknown.retry-same-key").isEnabled)
        attach("f3d-ios-settle-unknown")
        revealButton("v15.f3d.unknown.retry-same-key").tap()
        XCTAssertTrue(element("v15.f3d.editor").waitForNonExistence(timeout: 8))
        let settled = revealButton("v15.f3d.item.00000000-0000-0000-0000-00000000D312")
        XCTAssertTrue(settled.label.contains("已入账"))

        launch("cash-flow-direct-unknown")
        revealButton("v15.f3d.item.00000000-0000-0000-0000-00000000D311").tap()
        revealButton("v15.f3d.edit.open").tap()
        XCTAssertTrue(revealButton("v15.f3d.update.submit", enabled: true).isEnabled)
        revealButton("v15.f3d.update.submit").tap()
        XCTAssertTrue(reveal("v15.f3d.unknown", down: true).waitForExistence(timeout: 8))
        XCTAssertFalse(revealButton("v15.f3d.unknown.abandon-direct", enabled: false).isEnabled)
        revealButton("v15.f3d.unknown.readback").tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "无法把该事实归因")).firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(revealButton("v15.f3d.unknown.abandon-direct", enabled: true).isEnabled)
        attach("f3d-ios-direct-unknown-readback")
    }
}
