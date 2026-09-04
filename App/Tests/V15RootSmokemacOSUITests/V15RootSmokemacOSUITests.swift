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

    private func launchApp(service: String, accessKey: String? = nil, cleanupOnly: Bool = false, forceTransportError: Bool = false) -> XCUIApplication {
        // XCTest's `XCUIApplication().terminate()` does not reliably end a
        // retained macOS process between test methods. Kill the exact app
        // bundle and wait for it to leave the process table before setting this
        // launch's environment, otherwise cold-launch and transport-error
        // assertions can exercise the preceding authenticated shell.
        XCTAssertTrue(V15RootSmokeSupport.terminateRootSmokeApp(), "Root smoke app must exit before changing its launch environment.")
        let app = XCUIApplication()
        // A test cold launch must not ask AppKit to restore a prior V15 shell
        // (or cleanup) window whose SwiftUI content type no longer matches.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["FISCAL_ROOT_SMOKE_KEYCHAIN_SERVICE"] = service
        app.launchEnvironment["FISCAL_ACCESS_KEY"] = accessKey ?? ""
        app.launchEnvironment["FISCAL_ROOT_SMOKE_CLEANUP_ONLY"] = cleanupOnly ? "1" : "0"
        app.launchEnvironment["FISCAL_ROOT_SMOKE_FORCE_TRANSPORT_ERROR"] = forceTransportError ? "1" : "0"
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

    func testLocalServerBootstrapThenOpensV2FinancialTimeline() async throws {
        let qaAccessKey = try await V15RootSmokeSupport.mintQAAccessKey(passphrase: Self.qaOnlyPassphrase)
        let service = uniqueKeychainService()
        let app = launchApp(service: service, accessKey: qaAccessKey)
        defer { _ = V15RootSmokeSupport.terminateRootSmokeApp() }

        XCTAssertTrue(app.descendants(matching: .any)["v151.mac.workspace"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.descendants(matching: .any)["v151.mac.module.timeline"].exists)
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

    func testWorkspaceUsesThreeFinancialSpacesAndKeepsDomainsContextual() async throws {
        let service = uniqueKeychainService()
        let app = launchApp(service: service, accessKey: try await V15RootSmokeSupport.mintQAAccessKey(passphrase: Self.qaOnlyPassphrase))
        defer { _ = V15RootSmokeSupport.terminateRootSmokeApp() }
        XCTAssertTrue(app.descendants(matching: .any)["v151.mac.workspace"].waitForExistence(timeout: 12))
        func element(_ identifier: String) -> XCUIElement {
            app.descendants(matching: .any)[identifier]
        }

        let navigation = ["timeline", "reports", "settings"]
        func assertThreeRootSpacesRemainVisible() {
            for item in navigation {
                XCTAssertTrue(element("v151.mac.module.\(item)").exists, item)
            }
        }
        func assertHiddenKeyboardCommandsStayOutOfAccessibilityTree() {
            for label in ["下一笔", "上一笔", "预览", "提交"] {
                XCTAssertFalse(app.buttons[label].exists, label)
            }
        }

        assertThreeRootSpacesRemainVisible()
        assertHiddenKeyboardCommandsStayOutOfAccessibilityTree()
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
        XCTAssertEqual(element("v151.mac.module.back").label, "返回财务时间线")
        element("v151.mac.module.back").click()
        assertThreeRootSpacesRemainVisible()

        XCTAssertTrue(element("v151.mac.timeline.cash-flow").waitForExistence(timeout: 5))
        element("v151.mac.timeline.cash-flow").click()
        XCTAssertTrue(element("v15.f3d.cash-flow.macos").waitForExistence(timeout: 8))
        XCTAssertEqual(element("v151.mac.module.back").label, "返回财务时间线")
        element("v151.mac.module.back").click()
        XCTAssertTrue(element("v151.mac.ledger.title").waitForExistence(timeout: 8))
        assertThreeRootSpacesRemainVisible()

        XCTAssertTrue(element("v151.mac.ledger.search").exists)
        app.buttons["记一笔"].click()
        XCTAssertEqual(element("v151.mac.module.back").label, "返回财务时间线")
        element("v151.mac.module.back").click()

        element("v151.mac.module.reports").click()
        XCTAssertTrue(element("v15.f4a.reports.macos").exists)
        XCTAssertFalse(element("v151.mac.module.title").exists)

        element("v151.mac.module.settings").click()
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
        XCTAssertEqual(element("v151.mac.module.back").label, "返回设置与治理")
        element("v151.mac.module.back").click()
        XCTAssertTrue(element("v15.settings").waitForExistence(timeout: 5))
        XCTAssertTrue(element("v15.settings.pane.masterData").exists)
        XCTAssertTrue(V15RootSmokeSupport.terminateRootSmokeApp())
        assertAppCleanup(service: service)
    }
}
