import XCTest

@MainActor
final class F2BGalleryUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launch(_ route: String = "today", _ arguments: [String] = []) {
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--v15-f2b-route", route, "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryLarge"] + arguments
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// Today deliberately puts the factual cards after the decision queue.
    /// A real VoiceOver/scroll path must therefore reach them rather than
    /// assuming they are instantiated above the fold.
    private func reveal(_ identifier: String) -> XCUIElement {
        let target = element(identifier)
        for _ in 0..<14 {
            if target.exists { return target }
            app.swipeUp()
        }
        XCTAssertTrue(target.waitForExistence(timeout: 2), identifier)
        return target
    }

    private func revealHittable(_ identifier: String) -> XCUIElement {
        let target = reveal(identifier)
        for _ in 0..<14 {
            if target.isHittable { return target }
            app.swipeUp()
        }
        XCTAssertTrue(target.isHittable, identifier)
        return target
    }

    private func revealOnScreen(_ identifier: String) -> XCUIElement {
        let target = reveal(identifier)
        for _ in 0..<6 {
            if target.frame.intersects(app.windows.firstMatch.frame) { return target }
            app.swipeUp()
        }
        XCTAssertTrue(target.frame.intersects(app.windows.firstMatch.frame), identifier)
        return target
    }

    private func attach(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    func testFactsCardsOpenAllFourRevisionBoundScopesAndReadOnlyInspector() {
        launch()
        XCTAssertTrue(element("v15.f2b.today.ios").waitForExistence(timeout: 8))
        XCTAssertTrue(element("v15.f2b.snapshot").waitForExistence(timeout: 5))
        attach("f2b-ios-light-normal")

        for scope in ["cash_accounts", "credit_cycles", "reimbursement_outstanding", "completeness_issues"] {
            let card = reveal("v15.f2b.fact.\(scope)")
            card.tap()
            XCTAssertTrue(element("v15.f2b.scope.sheet").waitForExistence(timeout: 5), scope)
            XCTAssertTrue(element("v15.f2b.scope.close").exists, scope)
            app.buttons["v15.f2b.scope.close"].firstMatch.tap()
        }

        reveal("v15.f2b.fact.cash_accounts").tap()
        let row = element("v15.f2b.scope.row.00000000-0000-0000-0000-00000000F201")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(element("v15.f2b.readonly.inspector").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["账户只读信息"].exists)
        attach("f2b-ios-scope-readonly-inspector")
    }

    func testPageFailureKeepsScopeAndConflictActuallyReloadsFacts() {
        launch("today-page-error")
        XCTAssertTrue(element("v15.f2b.snapshot").waitForExistence(timeout: 8))
        reveal("v15.f2b.fact.cash_accounts").tap()
        let first = element("v15.f2b.scope.row.00000000-0000-0000-0000-00000000F201")
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        element("v15.f2b.scope.next-page").tap()
        XCTAssertTrue(element("v15.f2b.scope.page-error").waitForExistence(timeout: 5))
        XCTAssertTrue(first.exists)
        attach("f2b-ios-scope-page-error")

        launch("today-conflict")
        XCTAssertTrue(element("v15.f2b.snapshot").waitForExistence(timeout: 8))
        reveal("v15.f2b.fact.cash_accounts").tap()
        XCTAssertTrue(element("v15.f2b.scope.conflict").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["暂时无法取得数据"].exists)
        element("v15.f2b.scope.sheet").buttons["重试"].tap()
        XCTAssertTrue(element("v15.f2b.snapshot").waitForExistence(timeout: 5))
        XCTAssertTrue(element("v15.f2b.snapshot").label.contains("数据版本 43"))
        XCTAssertTrue(reveal("v15.f2b.fact.cash_accounts").exists)
        attach("f2b-ios-conflict-reloaded")
    }

    func testAttentionKnownAndUnknownAreSafeAndOfflineStaysReadOnly() {
        launch()
        let known = element("v15.f2b.attention.uncategorized_transaction:00000000-0000-0000-0000-00000000F202")
        XCTAssertTrue(known.waitForExistence(timeout: 8))
        known.tap()
        XCTAssertTrue(element("v15.f2b.readonly.inspector").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["账目只读信息"].exists)

        launch("today-unknown-attention")
        let unknown = element("v15.f2b.attention.future_source:00000000-0000-0000-0000-00000000F203")
        XCTAssertTrue(unknown.waitForExistence(timeout: 8))
        unknown.tap()
        XCTAssertTrue(app.staticTexts["暂不可打开"].waitForExistence(timeout: 5))
        attach("f2b-ios-unknown-attention")

        launch("today-offline", ["--v15-f1a-appearance", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(element("v15.f2b.offline").waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["离线 · 只读"].exists)
        XCTAssertTrue(app.staticTexts["当前显示的事实截止时间：2026年8月16日 00:01；离线期间仅可查看。"].exists)
        XCTAssertFalse(app.staticTexts["当前显示的事实截止时间：2026年8月12日 00:00；离线期间仅可查看。"].exists)
        attach("f2b-ios-offline-facts-as-of")
        XCTAssertTrue(revealHittable("v15.f2b.fact.cash_accounts").isHittable)
        XCTAssertFalse(app.buttons["保存"].exists)
        XCTAssertFalse(app.buttons["提交"].exists)
        attach("f2b-ios-dark-ax5-offline-long-amount")
    }

    func testAllAttentionSeveritiesStayReachableAtAX5InLightAndDark() {
        let ordered: [(String, String)] = [
            ("operation_exception:00000000-0000-0000-0000-00000000F209", "紧急"),
            ("credit_cycle_overdue:00000000-0000-0000-0000-00000000F203", "紧急"),
            ("reconciliation_checkpoint:00000000-0000-0000-0000-00000000F207", "需要留意"),
            ("statement_import_failed:00000000-0000-0000-0000-00000000F211", "需要留意"),
            ("cash_flow_overdue:00000000-0000-0000-0000-00000000F210", "需要留意"),
            ("reimbursement_overdue:00000000-0000-0000-0000-00000000F205", "需要留意"),
            ("uncategorized_transaction:00000000-0000-0000-0000-00000000F202", "提示"),
            ("ai_proposal:00000000-0000-0000-0000-00000000F208", "提示"),
            ("statement_import_review:00000000-0000-0000-0000-00000000F211", "提示"),
            ("reconciliation_missing:00000000-0000-0000-0000-00000000F201", "提示")
        ]
        launch("today", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        for (identifier, severity) in ordered {
            let row = revealHittable("v15.f2b.attention.\(identifier)")
            XCTAssertTrue(row.isHittable, identifier)
            XCTAssertTrue(row.label.hasPrefix(severity), "\(identifier) must retain its text severity")
        }
        attach("f2b-ios-attention-ax5-light-all-severities")

        launch("today", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityExtraLarge"])
        for (identifier, severity) in [ordered[0], ordered[2], ordered[6]] {
            let row = revealHittable("v15.f2b.attention.\(identifier)")
            XCTAssertTrue(row.isHittable && row.label.hasPrefix(severity), "light AX3 \(identifier)")
        }
        attach("f2b-ios-attention-ax3-light-all-severities")

        launch("today", ["--v15-f1a-appearance", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        for (identifier, severity) in [ordered[0], ordered[2], ordered[6]] {
            let row = revealHittable("v15.f2b.attention.\(identifier)")
            XCTAssertTrue(row.isHittable && row.label.hasPrefix(severity), "dark AX5 \(identifier)")
        }
        attach("f2b-ios-attention-ax5-dark-all-severities")

        launch("today-unknown-attention", ["--v15-f1a-appearance", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let unknown = revealHittable("v15.f2b.attention.future_source:00000000-0000-0000-0000-00000000F203")
        XCTAssertTrue(unknown.isHittable && unknown.label.hasPrefix("紧急"))
    }

    func testFutureTotalsAreFactsOnlyAndZeroStateStaysExplicitAtAX5() {
        launch("today-zero-future", ["--v15-f1a-appearance", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let totals = revealOnScreen("v15.f2b.future-totals")
        XCTAssertTrue(totals.exists)
        XCTAssertTrue(element("v15.f2b.future-totals.zero").exists)
        XCTAssertTrue(app.staticTexts["确认后现金（服务端口径）"].exists)
        XCTAssertFalse(app.staticTexts["完整时间轴"].exists)
        attach("f2b-ios-future-totals-zero-dark-ax5")
    }

    func testLinkedReadRetryAndUnknownScopeItemStayReadOnlyAndSafe() {
        launch("today-linked-retry")
        let known = element("v15.f2b.attention.uncategorized_transaction:00000000-0000-0000-0000-00000000F202")
        XCTAssertTrue(known.waitForExistence(timeout: 8))
        known.tap()
        XCTAssertTrue(element("v15.f2b.readonly.error").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["重试"].exists)
        app.buttons["重试"].tap()
        XCTAssertTrue(app.staticTexts["账目只读信息"].waitForExistence(timeout: 5))
        attach("f2b-ios-linked-read-retry")

        launch("today-unknown-scope")
        XCTAssertTrue(element("v15.f2b.snapshot").waitForExistence(timeout: 8))
        reveal("v15.f2b.fact.cash_accounts").tap()
        let unknown = element("v15.f2b.scope.row.unknown")
        XCTAssertTrue(unknown.waitForExistence(timeout: 5))
        unknown.tap()
        XCTAssertTrue(element("v15.f2b.readonly.unavailable").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["暂不可打开"].exists)
        XCTAssertFalse(app.buttons["保存"].exists)
        XCTAssertTrue(element("v15.f2b.readonly.close").exists)
        attach("f2b-ios-unknown-scope-item")
    }

    func testCalmEmptyAndSheetErrorRemainExplicit() {
        launch("today-calm")
        XCTAssertTrue(element("v15.f2b.attention.calm").waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["目前没有需要你决定的事项"].exists)

        launch("today-empty-scopes")
        XCTAssertTrue(element("v15.f2b.snapshot").waitForExistence(timeout: 8))
        reveal("v15.f2b.fact.completeness_issues").tap()
        XCTAssertTrue(element("v15.f2b.scope.empty").waitForExistence(timeout: 5))

        launch("today-scope-error")
        XCTAssertTrue(element("v15.f2b.snapshot").waitForExistence(timeout: 8))
        reveal("v15.f2b.fact.cash_accounts").tap()
        XCTAssertTrue(element("v15.f2b.scope.error").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["重试"].exists)
        attach("f2b-ios-scope-error")
    }
}
