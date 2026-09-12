import XCTest

@MainActor
final class V15RootSmokeUITests: XCTestCase {
    private let qaOnlyPassphrase = "f5b-root-smoke-qa-only"
    private let keychainServicePrefix = "com.linotsai.fiscal.v15-root-smoke.ios.access."

    func testV230ForecastAndSources() {
        let app = launchApp(service: uniqueKeychainService(), reviewScenario: "v230", formalFixture: true)
        let inflow = app.buttons["v230.overview.disposable.inflow"]
        XCTAssertTrue(inflow.waitForExistence(timeout: 8))
        let overview = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        overview.name = "v230-ios-forecast-overview"; overview.lifetime = .keepAlways; add(overview)
        XCTAssertTrue(inflow.isHittable); inflow.tap()
        XCTAssertTrue(app.staticTexts["工资到账"].waitForExistence(timeout: 5))
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "v230-ios-forecast-sources"; capture.lifetime = .keepAlways; add(capture)
    }

    func testV230PayoffSheetKeepsValidationVisible() {
        let app = launchApp(service: uniqueKeychainService(), reviewScenario: "v230", formalFixture: true, uiRoute: "payoff")
        let preview = app.buttons["v230.payoff.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 8))
        for _ in 0..<10 where !preview.isHittable { app.swipeUp() }
        XCTAssertTrue(preview.isHittable); preview.tap()
        let issue = app.staticTexts["请选择实际付款的现金或借记账户。"]
        XCTAssertTrue(issue.waitForExistence(timeout: 5))
        XCTAssertTrue(issue.isHittable)
        let readable = NSPredicate { _, _ in
            let frame = issue.frame
            let window = app.windows.firstMatch.frame
            let toolbarBottom = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : window.minY + 60
            return frame.height > 0 && frame.minY >= toolbarBottom + 8 && frame.maxY <= window.maxY - 48
                && frame.minX >= window.minX && frame.maxX <= window.maxX
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: readable, object: nil)], timeout: 5), .completed,
                       "校验说明应完整显示在导航栏和底部安全区之间")
        XCTAssertFalse(app.staticTexts["全额结清已完成"].exists)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "v230-ios-payoff-validation"; capture.lifetime = .keepAlways; add(capture)
    }

    private func rootTab(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.tabBars.buttons[title]
    }

    private func mintQAAccessKey() async throws -> String {
        struct Response: Decodable { let access_key: String }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8000/api/v1/auth/session")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["passphrase": qaOnlyPassphrase])
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONDecoder().decode(Response.self, from: data).access_key
    }

    private func uniqueKeychainService() -> String {
        "\(keychainServicePrefix)\(UUID().uuidString.lowercased())"
    }

    private func launchApp(service: String, reviewScenario: String = "", accessKey: String? = nil, cleanupOnly: Bool = false, forceTransportError: Bool = false, formalFixture: Bool = false, formalBoundary: Bool = false, scheme: String? = nil, extraArguments: [String] = [], uiRoute: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["FISCAL_ROOT_SMOKE_UI_ROUTE"] = uiRoute
        app.launchEnvironment["FISCAL_ROOT_SMOKE_REVIEW_SCENARIO"] = reviewScenario
        app.launchEnvironment["FISCAL_ROOT_SMOKE_KEYCHAIN_SERVICE"] = service
        if let accessKey {
            app.launchEnvironment["FISCAL_ACCESS_KEY"] = accessKey
        }
        if cleanupOnly {
            app.launchEnvironment["FISCAL_ROOT_SMOKE_CLEANUP_ONLY"] = "1"
        }
        if forceTransportError {
            app.launchEnvironment["FISCAL_ROOT_SMOKE_FORCE_TRANSPORT_ERROR"] = "1"
        }
        if formalFixture {
            app.launchEnvironment["FISCAL_ROOT_SMOKE_FORMAL_FIXTURE"] = "1"
        }
        if formalBoundary {
            app.launchEnvironment["FISCAL_ROOT_SMOKE_FORMAL_BOUNDARY"] = "1"
        }
        if let scheme {
            app.launchEnvironment["FISCAL_ROOT_SMOKE_COLOR_SCHEME"] = scheme
        }
        app.launchArguments = extraArguments
        app.launch()
        return app
    }

    private func assertAppCleanup(service: String) {
        let cleanup = launchApp(service: service, cleanupOnly: true)
        XCTAssertTrue(cleanup.descendants(matching: .any)["v15.rootsmoke.cleanup.complete"].waitForExistence(timeout: 8))
        XCTAssertFalse(cleanup.descendants(matching: .any)["v15.rootsmoke.cleanup.failed"].exists)
        cleanup.terminate()
    }

    func testV221BootstrapRetryReleasesFormalWorkspace() {
        let app = launchApp(service: uniqueKeychainService(), reviewScenario: "bootstrap-retry")
        XCTAssertTrue(app.buttons["重试"].firstMatch.waitForExistence(timeout: 8))
        app.buttons["重试"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["v151.ios.workspace-marker"].waitForExistence(timeout: 8))
    }

    func testV221ClassifiedTransactionOffersCategoryCorrection() {
        let app = launchApp(service: uniqueKeychainService(), formalFixture: true)
        XCTAssertTrue(app.descendants(matching: .any)["v151.ios.workspace-marker"].waitForExistence(timeout: 8))
        rootTab("交易", in: app).tap()
        let row = app.buttons["v221.ios.transaction.00000000-0000-0000-0000-00000000B101"]
        XCTAssertTrue(row.waitForExistence(timeout: 8)); reveal(row, in: app); row.tap()
        let change = app.buttons["修改分类"]
        XCTAssertTrue(change.waitForExistence(timeout: 8)); reveal(change, in: app); change.tap()
        let preview = app.buttons["查看分类影响"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.isEnabled, "当前分类应预填，可进入既有预览流程")
    }

    func testColdLaunchUsesFormalV15BootstrapWithoutGalleryRoute() {
        let app = launchApp(service: uniqueKeychainService())

        XCTAssertTrue(app.descendants(matching: .any)["v15.f1a.bootstrap"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Fiscal"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["v15.gallery.ios"].exists)
    }

    func testLocalServerBootstrapThenNavigatesToLiveReadRoutes() async throws {
        let qaAccessKey = try await mintQAAccessKey()
        let service = uniqueKeychainService()
        let app = launchApp(service: service, accessKey: qaAccessKey)

        XCTAssertTrue(app.descendants(matching: .any)["v151.ios.workspace-marker"].waitForExistence(timeout: 12))
        rootTab("交易", in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["v151.ios.ledger"].waitForExistence(timeout: 8))
        app.terminate()

        assertAppCleanup(service: service)
        let freshLaunch = launchApp(service: service)
        XCTAssertTrue(freshLaunch.descendants(matching: .any)["v15.f1a.bootstrap"].waitForExistence(timeout: 8))
        XCTAssertTrue(freshLaunch.staticTexts["Fiscal"].exists)
        freshLaunch.terminate()
    }

    func testFormalRootExposesTransportErrorAndOfflineReadOnlyWithoutFixtures() async throws {
        let qaAccessKey = try await mintQAAccessKey()

        let errorService = uniqueKeychainService()
        let errorApp = launchApp(service: errorService, accessKey: qaAccessKey, forceTransportError: true)
        XCTAssertTrue(errorApp.descendants(matching: .any)["v15.f1a.bootstrap"].waitForExistence(timeout: 8))
        XCTAssertTrue(errorApp.staticTexts["无法连接"].exists)
        XCTAssertFalse(errorApp.descendants(matching: .any)["v15.gallery.ios"].exists)
        errorApp.terminate()
        assertAppCleanup(service: errorService)

        let offlineService = uniqueKeychainService()
        let connectedApp = launchApp(service: offlineService, accessKey: qaAccessKey)
        XCTAssertTrue(connectedApp.descendants(matching: .any)["v151.ios.workspace-marker"].waitForExistence(timeout: 12))
        XCTAssertTrue(connectedApp.descendants(matching: .any)["v151.ios.today.account-value"].waitForExistence(timeout: 12))
        connectedApp.terminate()

        let offlineApp = launchApp(service: offlineService, forceTransportError: true)
        XCTAssertTrue(offlineApp.descendants(matching: .any)["v151.ios.workspace-marker"].waitForExistence(timeout: 8))
        XCTAssertTrue(offlineApp.descendants(matching: .any)["v151.ios.offline"].waitForExistence(timeout: 8))
        XCTAssertFalse(offlineApp.descendants(matching: .any)["v15.gallery.ios"].exists)
        offlineApp.terminate()
        assertAppCleanup(service: offlineService)
    }

    func testFormalWorkspaceFixtureRendersOnIPhone17ProLightDarkAndAX5() {
        let month = DateFormatter()
        month.locale = Locale(identifier: "en_US_POSIX")
        month.timeZone = TimeZone(identifier: "Asia/Shanghai")
        month.dateFormat = "yyyy-MM"
        let currentMonth = month.string(from: Date())
        let service = uniqueKeychainService()
        let cases: [(name: String, scheme: String?, arguments: [String])] = [
            ("v151-ios-workspace-iphone17pro-light", "light", []),
            ("v151-ios-workspace-iphone17pro-dark", "dark", []),
            ("v151-ios-workspace-iphone17pro-ax5", "light", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        ]
        for testCase in cases {
            let app = launchApp(service: service, formalFixture: true, scheme: testCase.scheme, extraArguments: testCase.arguments)
            let workspace = app.descendants(matching: .any)["v151.ios.workspace-marker"]
            XCTAssertTrue(workspace.waitForExistence(timeout: 8), testCase.name)
            XCTAssertTrue(rootTab("总览", in: app).isHittable, testCase.name)
            XCTAssertTrue(rootTab("交易", in: app).isHittable, testCase.name)
            XCTAssertTrue(rootTab("账户", in: app).isHittable, testCase.name)
            XCTAssertTrue(rootTab("分析", in: app).isHittable, testCase.name)
            XCTAssertTrue(app.buttons.matching(identifier: "v152.ios.record").firstMatch.isHittable, testCase.name)
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", currentMonth + "-01 至")).firstMatch.waitForExistence(timeout: 6), "本月必须来自上海当前月份")
            if testCase.name.hasSuffix("ax5") {
                let due = app.buttons["v151.ios.today.near-term.item.0"]
                XCTAssertTrue(due.waitForExistence(timeout: 6), testCase.name)
                let today = app.descendants(matching: .any)["v151.ios.today"]
                for _ in 0..<12 where !due.isHittable { today.swipeUp() }
                XCTAssertTrue(due.isHittable, "AX5 content below the first screen must remain reachable")
                XCTAssertTrue(rootTab("总览", in: app).isHittable, testCase.name)
            } else {
                XCTAssertTrue(app.buttons.matching(identifier: "v151.ios.today.reports").firstMatch.isHittable, testCase.name)
                XCTAssertTrue(app.buttons.matching(identifier: "v151.ios.today.settings").firstMatch.isHittable, testCase.name)
            }
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = testCase.name
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 8))
        for _ in 0..<15 where !element.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }

    func testOverviewRecentTransactionsConsumeEveryNavigationRequest() {
        let app = launchApp(service: uniqueKeychainService(), formalFixture: true)
        rootTab("交易", in: app).tap()
        for suffix in ["B102", "B101", "B101"] {
            rootTab("总览", in: app).tap()
            let id = "00000000-0000-0000-0000-00000000" + suffix
            let row = app.buttons["v220.ios.recent.transaction." + id]
            reveal(row, in: app)
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
            XCTAssertTrue(app.staticTexts["v220.ios.detail.title." + id].waitForExistence(timeout: 8))
            app.buttons["完成"].firstMatch.tap()
        }
        app.terminate()
    }

    func testOverviewRecentEmptyAndErrorRecoveryAreDistinct() {
        let empty = launchApp(service: uniqueKeychainService(), reviewScenario: "recent-empty", formalFixture: true)
        reveal(empty.staticTexts["v220.ios.recent.empty"], in: empty)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "fix-ios-recent-empty"; shot.lifetime = .keepAlways; add(shot)
        empty.terminate()
        let app = launchApp(service: uniqueKeychainService(), reviewScenario: "recent-error", formalFixture: true)
        let retry = app.buttons["重试"].firstMatch
        reveal(retry, in: app); retry.tap()
        let row = app.buttons["v220.ios.recent.transaction.00000000-0000-0000-0000-00000000B101"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "分类信息不可读取")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "餐饮")).firstMatch.exists)
        app.terminate()
        let references = launchApp(service: uniqueKeychainService(), reviewScenario: "categories-error", formalFixture: true)
        let retryReferences = references.buttons["重试"].firstMatch
        reveal(retryReferences, in: references)
        XCTAssertTrue(references.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "分类暂不可用")).firstMatch.exists)
        retryReferences.tap()
        XCTAssertTrue(references.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "餐饮")).firstMatch.waitForExistence(timeout: 8))
        references.terminate()
    }

    func testOverviewRecentAX5KeepsFullAmountReachable() {
        let app = launchApp(service: uniqueKeychainService(), formalFixture: true, scheme: "light",
                            extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let amount = app.descendants(matching: .any)["v220.ios.recent.amount.00000000-0000-0000-0000-00000000B102"].firstMatch
        reveal(amount, in: app)
        let creation = app.buttons["v152.ios.record"].firstMatch
        for _ in 0..<10 where amount.frame.maxY >= creation.frame.minY - 16 {
            let canvas = app.scrollViews.firstMatch
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.65))
                .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.45)))
        }
        XCTAssertTrue(amount.isHittable)
        XCTAssertLessThan(amount.frame.maxY, creation.frame.minY)
        XCTAssertTrue(amount.label.contains("9,999,999,999.99"))
        XCTAssertGreaterThanOrEqual(amount.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(amount.frame.maxX, app.frame.maxX)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "fix-ios-recent-ax5"; shot.lifetime = .keepAlways; add(shot)
        amount.swipeLeft()
        let scrolled = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        scrolled.name = "fix-ios-recent-ax5-amount-end"; scrolled.lifetime = .keepAlways; add(scrolled)
        app.terminate()
    }

    func testAccountAndAnalysisTabsKeepBottomCreationAvailable() {
        let app = launchApp(service: uniqueKeychainService(), formalFixture: true, scheme: "light")
        for (title, identifier) in [("账户", "v152.ios.accounts"), ("分析", "v15.f4a.reports.ios")] {
            rootTab(title, in: app).tap()
            XCTAssertTrue(app.descendants(matching: .any)[identifier].waitForExistence(timeout: 8))
            XCTAssertTrue(app.buttons.matching(identifier: "v152.ios.record").firstMatch.isHittable)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "v220-ios-" + title
            shot.lifetime = .keepAlways
            add(shot)
        }
        app.terminate()
    }

    /// Run with Reduce Motion and Reduce Transparency enabled in the existing
    /// QA simulator; restore its original preferences after the test batch.
    func testReducedEffectsKeepNavigationAndCreationAvailable() {
        let app = launchApp(service: uniqueKeychainService(), formalFixture: true, scheme: "light")
        let settings = app.descendants(matching: .any)["v220.qa.accessibility-settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        XCTAssertEqual(settings.value as? String, "motion=true;transparency=true")
        for title in ["总览", "交易", "账户", "分析"] {
            rootTab(title, in: app).tap()
            XCTAssertTrue(app.buttons.matching(identifier: "v152.ios.record").firstMatch.isHittable)
        }
        rootTab("总览", in: app).tap()
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "v220-ios-reduced-effects"
        shot.lifetime = .keepAlways
        add(shot)
        app.terminate()
    }

    func testFormalRecordKeepsKeyboardAndReturnPathReachable() {
        let app = launchApp(service: uniqueKeychainService(), formalFixture: true, scheme: "light")
        XCTAssertTrue(app.descendants(matching: .any)["v151.ios.workspace-marker"].waitForExistence(timeout: 8))
        app.buttons.matching(identifier: "v152.ios.record").firstMatch.tap()
        let amount = app.textFields["v15.f1a.record.amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        let keyboard = app.keyboards.firstMatch
        if !keyboard.waitForExistence(timeout: 2) { amount.tap() }
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(keyboard.frame.height, 150)
        let save = app.buttons["保存账目"]
        XCTAssertTrue(save.isHittable)
        XCTAssertLessThanOrEqual(save.frame.maxY, keyboard.frame.minY)
        let date = app.datePickers["业务日期（上海）"]
        XCTAssertTrue(date.isHittable)
        XCTAssertLessThanOrEqual(date.frame.maxY, save.frame.minY)
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "v210-ios-formal-record-keyboard"
        capture.lifetime = .keepAlways
        add(capture)
        app.buttons["关闭"].firstMatch.tap()
        XCTAssertTrue(rootTab("交易", in: app).waitForExistence(timeout: 5))
        app.terminate()
    }

    func testFormalWorkspaceBoundaryKeepsMoneyLocalAndNavigationReachable() {
        let service = uniqueKeychainService()
        let app = launchApp(service: service, formalFixture: true, formalBoundary: true, scheme: "light")
        let accountValue = app.descendants(matching: .any)["v151.ios.today.account-value"]
        XCTAssertTrue(accountValue.waitForExistence(timeout: 8))
        XCTAssertEqual(accountValue.label, "暂无法汇总", "现金上界减去信用溢缴会溢出，净额必须明确不可汇总")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "92,233,720,368,547,758.07")).firstMatch.exists, "原始现金金额仍应可访问")
        let frame = accountValue.frame
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThanOrEqual(frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(frame.maxX, app.frame.maxX)
        XCTAssertTrue(rootTab("总览", in: app).isHittable)
        XCTAssertTrue(rootTab("交易", in: app).isHittable)
        XCTAssertTrue(rootTab("账户", in: app).isHittable)
        XCTAssertTrue(rootTab("分析", in: app).isHittable)
        XCTAssertTrue(app.buttons.matching(identifier: "v152.ios.record").firstMatch.isHittable)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "v151-ios-workspace-boundary-iphone17pro"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    func testFormalWorkspaceLedgerProvidesCompactScopeAndTimeNavigation() {
        let service = uniqueKeychainService()
        let app = launchApp(service: service, formalFixture: true, scheme: "light")
        XCTAssertTrue(app.descendants(matching: .any)["v151.ios.workspace-marker"].waitForExistence(timeout: 8))

        rootTab("交易", in: app).tap()

        let accountScope = app.descendants(matching: .any)["v151.ios.ledger.account-scope"]
        let accountScopeLabel = app.buttons["全部账户"]
        let accountScopeText = app.staticTexts["全部账户"]
        let past = app.descendants(matching: .any)["v151.ios.ledger.time.past"]
        let today = app.descendants(matching: .any)["v151.ios.ledger.time.today"]
        let future = app.descendants(matching: .any)["v151.ios.ledger.time.future"]
        XCTAssertTrue(
            accountScope.waitForExistence(timeout: 8)
            || accountScopeLabel.waitForExistence(timeout: 8)
            || accountScopeText.waitForExistence(timeout: 8)
        )
        XCTAssertTrue(past.isHittable)
        XCTAssertTrue(today.isHittable)
        XCTAssertTrue(future.isHittable)

        let ledgerCapture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        ledgerCapture.name = "v210-ios-formal-ledger"
        ledgerCapture.lifetime = .keepAlways
        add(ledgerCapture)

        let scopeButton = app.buttons["全部账户"]
        if scopeButton.exists { scopeButton.tap() }
        else { accountScope.tap() }
        let cashAccount = app.buttons["日常现金"]
        XCTAssertTrue(cashAccount.waitForExistence(timeout: 5))
        cashAccount.tap()
        let accountDetail = app.buttons.matching(identifier: "v151.ios.ledger.account-detail").firstMatch
        XCTAssertTrue(accountDetail.waitForExistence(timeout: 5))
        XCTAssertTrue(accountDetail.isHittable)
        accountDetail.tap()
        XCTAssertTrue(app.descendants(matching: .any)["v151.ios.account-detail"].waitForExistence(timeout: 8))
        app.buttons.matching(identifier: "v151.ios.account-detail.close").firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["v151.ios.ledger"].waitForExistence(timeout: 5))

        future.tap()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f3a.timeline.ios"].waitForExistence(timeout: 8))
        app.buttons.matching(identifier: "v151.ios.ledger.future.close").firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["v151.ios.ledger"].waitForExistence(timeout: 5))

        future.tap()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f3a.timeline.ios"].waitForExistence(timeout: 8))
        let cashFlowPlan = app.buttons.matching(identifier: "v151.ios.ledger.future.cash-flow").firstMatch
        XCTAssertTrue(cashFlowPlan.isHittable)
        cashFlowPlan.tap()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f3d.cash-flow.ios"].waitForExistence(timeout: 8))
        app.buttons["关闭"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f3a.timeline.ios"].waitForExistence(timeout: 5))
        app.buttons.matching(identifier: "v151.ios.ledger.future.close").firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["v151.ios.ledger"].waitForExistence(timeout: 5))

        let record = app.buttons.matching(identifier: "v152.ios.record").firstMatch
        XCTAssertTrue(record.isHittable)
        let next = app.buttons["v151.ios.ledger.next"]
        for _ in 0..<8 where !next.isHittable { app.swipeUp() }
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertTrue(next.isHittable)
        XCTAssertFalse(next.frame.intersects(record.frame))

        app.terminate()
    }

    func testFormalWorkspaceSettingsAndGovernancePathsRemainReachable() {
        let service = uniqueKeychainService()
        let app = launchApp(service: service, formalFixture: true, scheme: "light")
        XCTAssertTrue(app.descendants(matching: .any)["v151.ios.workspace-marker"].waitForExistence(timeout: 8))

        app.descendants(matching: .any)["v151.ios.today.settings"].tap()
        let settings = app.descendants(matching: .any)["v15.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))

        let proposals = app.descendants(matching: .any)["v15.settings.open.proposals"]
        let statementImport = app.descendants(matching: .any)["v15.settings.open.statement-import"]
        let pendingSync = app.descendants(matching: .any)["v15.settings.open.pending-sync"]
        let security = app.descendants(matching: .any)["v15.settings.open.security"]
        XCTAssertTrue(proposals.isHittable)
        XCTAssertTrue(statementImport.isHittable)
        XCTAssertTrue(pendingSync.isHittable)
        for _ in 0..<6 where !security.isHittable { settings.swipeUp() }
        XCTAssertTrue(security.isHittable)

        pendingSync.tap()
        XCTAssertTrue(app.descendants(matching: .any)["v151.ios.pending-sync"].waitForExistence(timeout: 8))
        app.buttons["返回设置与数据"].tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))

        proposals.tap()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f3f.ai.ios"].waitForExistence(timeout: 8))
        app.buttons.matching(identifier: "v15.f3f.close").firstMatch.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))

        statementImport.tap()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f3g.statement-import.ios"].waitForExistence(timeout: 8))
        app.buttons.matching(identifier: "v15.f3g.close").firstMatch.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))

        security.tap()
        XCTAssertTrue(app.staticTexts["数据与安全"].waitForExistence(timeout: 8))
        app.buttons.matching(identifier: "v15.settings.pane.close").firstMatch.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        app.terminate()
    }
}
