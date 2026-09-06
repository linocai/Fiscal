import AppKit
import XCTest

private enum V15RootSmokeSupport {
    static let appBundleIdentifier = "com.linotsai.fiscal.v15-root-smoke.macos"

    nonisolated static func mintQAAccessKey(passphrase: String) async throws -> String {
        struct Response: Decodable { let access_key: String }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8000/api/v1/auth/session")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["passphrase": passphrase])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Response.self, from: data).access_key
    }

    @discardableResult
    static func terminateRootSmokeApp() -> Bool {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: appBundleIdentifier)
            guard !runningApps.isEmpty else { return true }
            runningApps.forEach { $0.forceTerminate() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline

        return NSRunningApplication.runningApplications(withBundleIdentifier: appBundleIdentifier).isEmpty
    }
}

@MainActor
final class V15RootSmokemacOSUITests: XCTestCase {
    private static let qaOnlyPassphrase = "f5b-root-smoke-qa-only"
    private let keychainServicePrefix = "com.linotsai.fiscal.v15-root-smoke.macos.access."

    private func uniqueKeychainService() -> String {
        "\(keychainServicePrefix)\(UUID().uuidString.lowercased())"
    }

    private func launchApp(service: String, reviewScenario: String = "", accessKey: String? = nil, cleanupOnly: Bool = false, forceTransportError: Bool = false, formalFixture: Bool = false, scheme: String? = nil, accountOverflow: Bool = false, windowWidth: Int? = nil) -> XCUIApplication {
        // XCTest's `XCUIApplication().terminate()` does not reliably end a
        // retained macOS process between test methods. Kill the exact app
        // bundle and wait for it to leave the process table before setting this
        // launch's environment, otherwise cold-launch and transport-error
        // assertions can exercise the preceding authenticated shell.
        XCTAssertTrue(V15RootSmokeSupport.terminateRootSmokeApp(), "Root smoke app must exit before changing its launch environment.")
        let app = XCUIApplication()
        app.launchEnvironment["FISCAL_ROOT_SMOKE_REVIEW_SCENARIO"] = reviewScenario
        // A test cold launch must not ask AppKit to restore a prior V15 shell
        // (or cleanup) window whose SwiftUI content type no longer matches.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["FISCAL_ROOT_SMOKE_KEYCHAIN_SERVICE"] = service
        app.launchEnvironment["FISCAL_ACCESS_KEY"] = accessKey ?? ""
        app.launchEnvironment["FISCAL_ROOT_SMOKE_CLEANUP_ONLY"] = cleanupOnly ? "1" : "0"
        app.launchEnvironment["FISCAL_ROOT_SMOKE_FORCE_TRANSPORT_ERROR"] = forceTransportError ? "1" : "0"
        app.launchEnvironment["FISCAL_ROOT_SMOKE_FORMAL_FIXTURE"] = formalFixture ? "1" : "0"
        app.launchEnvironment["FISCAL_ROOT_SMOKE_COLOR_SCHEME"] = scheme ?? ""
        app.launchEnvironment["FISCAL_ROOT_SMOKE_ACCOUNT_OVERFLOW"] = accountOverflow ? "1" : "0"
        app.launchEnvironment["FISCAL_ROOT_SMOKE_WINDOW_WIDTH"] = windowWidth.map(String.init) ?? "1280"
        app.launch()
        return app
    }

    override func tearDown() {
        XCTAssertTrue(V15RootSmokeSupport.terminateRootSmokeApp(), "Root smoke app must exit after each test.")
        super.tearDown()
    }

    private func assertAppCleanup(service: String) {
        let cleanup = launchApp(service: service, cleanupOnly: true)
        XCTAssertTrue(cleanup.descendants(matching: .any)["v15.rootsmoke.cleanup.complete"].waitForExistence(timeout: 8))
        XCTAssertFalse(cleanup.descendants(matching: .any)["v15.rootsmoke.cleanup.failed"].exists)
        XCTAssertTrue(V15RootSmokeSupport.terminateRootSmokeApp())
    }

    func testColdLaunchUsesFormalV15BootstrapWithoutGalleryRoute() {
        let app = launchApp(service: uniqueKeychainService())
        defer { _ = V15RootSmokeSupport.terminateRootSmokeApp() }

        XCTAssertTrue(app.descendants(matching: .any)["v15.f1a.bootstrap"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)["v15.gallery.macos"].exists)
    }

    func testFixtureTimelineSelectionSurvivesAnalysisRoundTrip() {
        let app = launchApp(service: uniqueKeychainService(), formalFixture: true, scheme: "light")
        XCTAssertTrue(app.descendants(matching: .any)["v151.mac.workspace"].waitForExistence(timeout: 8))
        app.descendants(matching: .any)["v151.mac.module.timeline"].firstMatch.click()
        let inspector = app.descendants(matching: .any)["v151.mac.inspector"].firstMatch
        XCTAssertFalse(inspector.exists)
        let transaction = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "v151.mac.transaction.")).firstMatch
        XCTAssertTrue(transaction.waitForExistence(timeout: 8))
        transaction.click()
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))

        app.descendants(matching: .any)["v151.mac.module.reports"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f4a.reports.macos"].waitForExistence(timeout: 8))
        app.descendants(matching: .any)["v151.mac.module.timeline"].firstMatch.click()
        XCTAssertTrue(inspector.waitForExistence(timeout: 5), "Returning from analysis must preserve the selected transaction context")
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "v210-mac-timeline-selected"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.typeKey("n", modifierFlags: .command)
        let amount = app.textFields["v15.f1a.record.amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.click()
        amount.typeText("1280.50")
        XCTAssertEqual(amount.value as? String, "1280.50")
        let recordCapture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        recordCapture.name = "v210-mac-formal-record"
        recordCapture.lifetime = .keepAlways
        add(recordCapture)
        app.buttons["v151.mac.module.back"].click()
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))
    }

    func testAccountHubAndSidebarPopoverKeepOverflowAccountsDiscoverable() {
        let app = launchApp(service: uniqueKeychainService(), formalFixture: true, accountOverflow: true)
        let accounts = app.descendants(matching: .any)["v151.mac.module.accounts"].firstMatch
        XCTAssertTrue(accounts.waitForExistence(timeout: 8))
        accounts.click()
        XCTAssertTrue(app.descendants(matching: .any)["v152.mac.accounts"].waitForExistence(timeout: 5))

        let cashSummary = app.buttons["v152.mac.sidebar.accounts.cash"]
        XCTAssertTrue(cashSummary.isHittable)
        cashSummary.click()
        let pickerSearch = app.textFields["v22.account-picker.search"]
        XCTAssertTrue(pickerSearch.waitForExistence(timeout: 5))
        let popoverCapture = XCTAttachment(screenshot: app.popovers.firstMatch.screenshot())
        popoverCapture.name = "v220-mac-account-popover"
        popoverCapture.lifetime = .keepAlways
        add(popoverCapture)
        pickerSearch.click()
        // Send native keys to the current first responder in the popover.
        for character in "no-such-account" { app.typeKey(String(character), modifierFlags: []) }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "没有匹配账户", "没有匹配账户")).firstMatch.waitForExistence(timeout: 3))
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        let fifth = app.buttons["v152.mac.sidebar.popover.account.00000000-0000-0000-0000-000000000205"]
        XCTAssertTrue(fifth.waitForExistence(timeout: 3))
        for _ in 0..<3 { app.typeKey(.downArrow, modifierFlags: []) }
        XCTAssertEqual(fifth.value as? String, "已选")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.descendants(matching: .any)["v151.mac.account.scope"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["v151.mac.inspector"].firstMatch.exists)
        app.buttons["v152.mac.sidebar.accounts.credit"].click()
        XCTAssertTrue(pickerSearch.waitForExistence(timeout: 4))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(pickerSearch.waitForNonExistence(timeout: 3))
    }

    func testOverviewDarkAndNarrowWindowKeepNavigationReadable() {
        for (scheme, width) in [("dark", 1280), ("light", 1000)] {
            let app = launchApp(service: uniqueKeychainService(), formalFixture: true, scheme: scheme, accountOverflow: true, windowWidth: width)
            let overview = app.descendants(matching: .any)["v152.mac.overview"]
            XCTAssertTrue(overview.waitForExistence(timeout: 8))
            for destination in ["overview", "timeline", "accounts", "reports"] {
                XCTAssertTrue(app.buttons["v151.mac.module.\(destination)"].isHittable)
            }
            XCTAssertTrue(app.staticTexts["每日实际支出"].waitForExistence(timeout: 6))
            XCTAssertLessThanOrEqual(app.windows.firstMatch.frame.width, CGFloat(width + 2))
            let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            capture.name = "v220-mac-overview-\(scheme)-\(width)"
            capture.lifetime = .keepAlways
            add(capture)
            app.buttons["v220.mac.overview.record"].click()
            XCTAssertTrue(app.textFields["v15.f1a.record.amount"].waitForExistence(timeout: 5))
            app.buttons["v151.mac.module.back"].click()
            XCTAssertTrue(overview.waitForExistence(timeout: 5))
            XCTAssertTrue(V15RootSmokeSupport.terminateRootSmokeApp())
        }
    }

    func testOverviewRecentQuerySurvivesAccountFilterAndOpensExactDetail() {
        let app = launchApp(service: uniqueKeychainService(), formalFixture: true, accountOverflow: true)
        app.buttons["v151.mac.module.accounts"].click()
        let fifth = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "测试账户5")).firstMatch
        XCTAssertTrue(fifth.waitForExistence(timeout: 8)); fifth.click()
        app.buttons["v151.mac.module.overview"].click()
        let id = "00000000-0000-0000-0000-00000000B102"
        let row = app.buttons["v220.mac.recent.transaction." + id]
        XCTAssertTrue(row.waitForExistence(timeout: 8)); row.click()
        XCTAssertTrue(app.staticTexts["v220.mac.detail.title." + id].waitForExistence(timeout: 8))
    }

    func testOverviewFutureFailureRetriesAndReturnsToOverview() {
        let app = launchApp(service: uniqueKeychainService(), reviewScenario: "future-retry", formalFixture: true, scheme: "light")
        let event = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "v220.mac.overview.future.credit_cycle:")).firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 8))
        XCTAssertTrue(event.isHittable, "Upcoming work must appear on the first 1280 × 820 screen")
        let initial = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        initial.name = "fix-mac-overview-light"; initial.lifetime = .keepAlways; add(initial)
        event.click()
        let retry = app.buttons["v220.mac.overview.future.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 8)); retry.click()
        let back = app.buttons["v151.mac.module.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 8))
        XCTAssertTrue(back.label.contains("总览")); back.click()
        XCTAssertTrue(app.descendants(matching: .any)["v152.mac.overview"].waitForExistence(timeout: 8))
        app.buttons["v220.mac.overview.future.all"].click()
        XCTAssertTrue(back.waitForExistence(timeout: 8))
        XCTAssertTrue(back.label.contains("总览")); back.click()
        XCTAssertTrue(app.descendants(matching: .any)["v152.mac.overview"].waitForExistence(timeout: 8))
    }

    func testAccountReadFailureRetriesAndEmptyStateIsHonest() {
        let app = launchApp(service: uniqueKeychainService(), reviewScenario: "accounts-error", formalFixture: true)
        app.buttons["v151.mac.module.accounts"].click()
        let retry = app.buttons["v220.mac.accounts.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 8)); retry.click()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "日常现金")).firstMatch.waitForExistence(timeout: 8))
        _ = V15RootSmokeSupport.terminateRootSmokeApp()
        let empty = launchApp(service: uniqueKeychainService(), reviewScenario: "accounts-empty", formalFixture: true)
        empty.buttons["v151.mac.module.accounts"].click()
        XCTAssertTrue(empty.descendants(matching: .any)["v220.mac.accounts.empty"].waitForExistence(timeout: 8))
        XCTAssertTrue(empty.buttons["添加账户"].isHittable)
        XCTAssertFalse(empty.staticTexts["没有符合当前搜索条件的账户。"].exists)
    }

    func testMutableModuleReturnRefreshesOverviewAndAccounts() {
        let app = launchApp(service: uniqueKeychainService(), reviewScenario: "refresh", formalFixture: true)
        let net = app.staticTexts["v220.mac.overview.net"]
        XCTAssertTrue(net.waitForExistence(timeout: 8))
        XCTAssertTrue((net.value as? String ?? "").contains("1,932.17"))
        app.buttons["v151.mac.module.accounts"].click()
        app.buttons["设置与数据"].firstMatch.click()
        app.buttons["v151.mac.module.overview"].click()
        let refreshed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "2,932.17"), object: net)
        XCTAssertEqual(XCTWaiter.wait(for: [refreshed], timeout: 8), .completed)
        app.buttons["v151.mac.module.accounts"].click()
        app.buttons["设置与数据"].firstMatch.click()
        app.buttons["v151.mac.module.accounts"].click()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "复核后现金")).firstMatch.waitForExistence(timeout: 8))
    }

    func testOverviewLabelsOfflineSnapshotAndPendingChanges() {
        let app = launchApp(service: uniqueKeychainService(), reviewScenario: "offline-pending", formalFixture: true)
        XCTAssertTrue(app.descendants(matching: .any)["v220.mac.overview.offline"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["v220.mac.overview.pending"].waitForExistence(timeout: 8))
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "fix-mac-overview-offline"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["核验"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["v151.mac.pending-sync"].waitForExistence(timeout: 8))
    }

    func testLocalServerBootstrapThenOpensV2FinancialTimeline() async throws {
        let qaAccessKey = try await V15RootSmokeSupport.mintQAAccessKey(passphrase: Self.qaOnlyPassphrase)
        let service = uniqueKeychainService()
        let app = launchApp(service: service, accessKey: qaAccessKey)
        defer { _ = V15RootSmokeSupport.terminateRootSmokeApp() }

        XCTAssertTrue(app.descendants(matching: .any)["v151.mac.workspace"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.descendants(matching: .any)["v151.mac.module.timeline"].exists)
        app.descendants(matching: .any)["v151.mac.module.timeline"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["v151.mac.ledger.title"].waitForExistence(timeout: 8))
        XCTAssertTrue(V15RootSmokeSupport.terminateRootSmokeApp())

        assertAppCleanup(service: service)
        let freshLaunch = launchApp(service: service)
        XCTAssertTrue(freshLaunch.descendants(matching: .any)["v15.f1a.bootstrap"].waitForExistence(timeout: 8))
        XCTAssertTrue(V15RootSmokeSupport.terminateRootSmokeApp())
    }

    func testFormalRootExposesTransportErrorAndOfflineReadOnlyWithoutFixtures() async throws {
        let qaAccessKey = try await V15RootSmokeSupport.mintQAAccessKey(passphrase: Self.qaOnlyPassphrase)

        let errorService = uniqueKeychainService()
        let errorApp = launchApp(service: errorService, accessKey: qaAccessKey, forceTransportError: true)
        defer { _ = V15RootSmokeSupport.terminateRootSmokeApp() }
        XCTAssertTrue(errorApp.descendants(matching: .any)["v15.f1a.bootstrap"].waitForExistence(timeout: 8))
        XCTAssertTrue(errorApp.buttons["重试"].waitForExistence(timeout: 8))
        XCTAssertFalse(errorApp.descendants(matching: .any)["v15.gallery.macos"].exists)
        XCTAssertTrue(V15RootSmokeSupport.terminateRootSmokeApp())
        assertAppCleanup(service: errorService)

        let offlineService = uniqueKeychainService()
        let connectedApp = launchApp(service: offlineService, accessKey: qaAccessKey)
        defer { _ = V15RootSmokeSupport.terminateRootSmokeApp() }
        XCTAssertTrue(connectedApp.descendants(matching: .any)["v151.mac.workspace"].waitForExistence(timeout: 12))
        XCTAssertTrue(V15RootSmokeSupport.terminateRootSmokeApp())

        let offlineApp = launchApp(service: offlineService, forceTransportError: true)
        defer { _ = V15RootSmokeSupport.terminateRootSmokeApp() }
        XCTAssertTrue(offlineApp.descendants(matching: .any)["v151.mac.workspace"].waitForExistence(timeout: 12))
        let offlineBanner = offlineApp.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "离线 · 只读")).firstMatch
        XCTAssertTrue(offlineBanner.waitForExistence(timeout: 8))
        XCTAssertFalse(offlineApp.descendants(matching: .any)["v15.gallery.macos"].exists)
        XCTAssertTrue(V15RootSmokeSupport.terminateRootSmokeApp())
        assertAppCleanup(service: offlineService)
    }

    func testWorkspaceUsesFourFinancialSpacesAndKeepsDomainsContextual() {
        let service = uniqueKeychainService()
        let app = launchApp(service: service, formalFixture: true, accountOverflow: true)
        defer { _ = V15RootSmokeSupport.terminateRootSmokeApp() }
        XCTAssertTrue(app.descendants(matching: .any)["v151.mac.workspace"].waitForExistence(timeout: 12))
        func element(_ identifier: String) -> XCUIElement {
            app.descendants(matching: .any)[identifier]
        }

        let navigation = ["overview", "timeline", "accounts", "reports"]
        func assertFourRootSpacesRemainVisible() {
            for item in navigation {
                XCTAssertTrue(element("v151.mac.module.\(item)").exists, item)
            }
        }
        func assertHiddenKeyboardCommandsStayOutOfAccessibilityTree() {
            for label in ["下一笔", "上一笔", "预览", "提交"] {
                XCTAssertFalse(app.buttons[label].exists, label)
            }
        }

        assertFourRootSpacesRemainVisible()
        assertHiddenKeyboardCommandsStayOutOfAccessibilityTree()
        XCTAssertTrue(element("v152.mac.overview").exists)
        let overviewCapture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        overviewCapture.name = "v220-mac-overview"
        overviewCapture.lifetime = .keepAlways
        add(overviewCapture)
        element("v151.mac.module.timeline").click()
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "v151.mac.ledger.title").count, 1)
        XCTAssertTrue(element("v151.mac.timeline.today-anchor").exists)
        XCTAssertTrue(element("v151.mac.timeline.known-future").exists)
        let loadedAccountScope = element("v151.mac.account.scope.summary").waitForExistence(timeout: 8)
        let emptyAccountScope = loadedAccountScope ? false : element("v151.mac.account.scope.empty").waitForExistence(timeout: 3)
        XCTAssertTrue(loadedAccountScope || emptyAccountScope, "账户范围应显示可选范围或空账户说明。")
        if loadedAccountScope {
            XCTAssertTrue(element("v151.mac.account.scope").exists)
        }
        let accountCards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "v151.mac.account.card."))
        XCTAssertEqual(accountCards.count, 0, "账户只作为紧凑范围，不再形成卡片墙。")

        for removedRoot in ["today", "ledger", "more", "future", "credit", "installments", "reimbursements", "cashFlow", "proposals", "statementImport", "archive", "pendingSync"] {
            XCTAssertFalse(element("v151.mac.module.\(removedRoot)").exists, removedRoot)
        }

        XCTAssertTrue(app.buttons["查看全部有来源未来"].waitForExistence(timeout: 5))
        app.buttons["查看全部有来源未来"].click()
        XCTAssertTrue(element("v15.f3a.timeline.macos").waitForExistence(timeout: 8))
        XCTAssertEqual(element("v151.mac.module.back").label, "返回交易")
        element("v151.mac.module.back").click()
        assertFourRootSpacesRemainVisible()

        XCTAssertTrue(element("v151.mac.timeline.cash-flow").waitForExistence(timeout: 5))
        element("v151.mac.timeline.cash-flow").click()
        XCTAssertTrue(element("v15.f3d.cash-flow.macos").waitForExistence(timeout: 8))
        XCTAssertEqual(element("v151.mac.module.back").label, "返回交易")
        element("v151.mac.module.back").click()
        XCTAssertTrue(element("v151.mac.ledger.title").waitForExistence(timeout: 8))
        assertFourRootSpacesRemainVisible()

        XCTAssertTrue(element("v151.mac.ledger.search").exists)
        app.buttons["记一笔"].click()
        XCTAssertEqual(element("v151.mac.module.back").label, "返回交易")
        element("v151.mac.module.back").click()

        element("v151.mac.module.reports").click()
        XCTAssertTrue(element("v15.f4a.reports.macos").exists)
        XCTAssertFalse(element("v151.mac.module.title").exists)

        element("v151.mac.module.accounts").click()
        XCTAssertTrue(element("v152.mac.accounts").waitForExistence(timeout: 5))
        app.buttons["设置与数据"].firstMatch.click()
        XCTAssertTrue(element("v15.settings").exists)
        XCTAssertFalse(element("v151.mac.module.title").exists)
        XCTAssertTrue(element("v15.settings.pane.masterData").exists)
        XCTAssertTrue(element("v15.settings.pane.proposals").exists)
        XCTAssertTrue(element("v15.settings.pane.statementImport").exists)

        element("v15.settings.pane.archive").click()
        XCTAssertTrue(element("v15.settings.archive").waitForExistence(timeout: 5))
        XCTAssertTrue(element("v15.settings").exists)

        element("v15.settings.pane.security").click()
        XCTAssertTrue(element("v15.f4c.security.macos").waitForExistence(timeout: 5))
        XCTAssertTrue(element("v15.settings").exists)

        element("v15.settings.open.pending-sync").click()
        XCTAssertTrue(element("v151.mac.pending-sync").waitForExistence(timeout: 5))
        XCTAssertEqual(element("v151.mac.module.back").label, "返回设置与数据")
        element("v151.mac.module.back").click()
        XCTAssertTrue(element("v15.settings").waitForExistence(timeout: 5))
        XCTAssertTrue(element("v15.settings.pane.masterData").exists)
        XCTAssertTrue(V15RootSmokeSupport.terminateRootSmokeApp())
        assertAppCleanup(service: service)
    }
}
