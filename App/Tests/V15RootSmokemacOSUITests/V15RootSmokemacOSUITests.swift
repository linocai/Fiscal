import XCTest

@MainActor
final class V15RootSmokemacOSUITests: XCTestCase {
    private let qaOnlyPassphrase = "f5b-root-smoke-qa-only"
    private let keychainServicePrefix = "com.linotsai.fiscal.v15-root-smoke.macos.access."

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

    private func launchApp(service: String, accessKey: String? = nil, cleanupOnly: Bool = false, forceTransportError: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        // A test cold launch must not ask AppKit to restore a prior V15 shell
        // (or cleanup) window whose SwiftUI content type no longer matches.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["FISCAL_ROOT_SMOKE_KEYCHAIN_SERVICE"] = service
        if let accessKey {
            app.launchEnvironment["FISCAL_ACCESS_KEY"] = accessKey
        }
        app.launchEnvironment["FISCAL_ROOT_SMOKE_CLEANUP_ONLY"] = cleanupOnly ? "1" : "0"
        if forceTransportError {
            app.launchEnvironment["FISCAL_ROOT_SMOKE_FORCE_TRANSPORT_ERROR"] = "1"
        }
        app.launch()
        return app
    }

    private func assertAppCleanup(service: String) {
        let cleanup = launchApp(service: service, cleanupOnly: true)
        XCTAssertTrue(cleanup.descendants(matching: .any)["v15.rootsmoke.cleanup.complete"].waitForExistence(timeout: 8))
        XCTAssertFalse(cleanup.descendants(matching: .any)["v15.rootsmoke.cleanup.failed"].exists)
        cleanup.terminate()
    }

    func testColdLaunchUsesFormalV15BootstrapWithoutGalleryRoute() {
        let app = launchApp(service: uniqueKeychainService())

        XCTAssertTrue(app.staticTexts["连接 Fiscal"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)["v15.gallery.macos"].exists)
    }

    func testLocalServerBootstrapThenNavigatesToLiveReadRoutes() async throws {
        let qaAccessKey = try await mintQAAccessKey()
        let service = uniqueKeychainService()
        let app = launchApp(service: service, accessKey: qaAccessKey)

        XCTAssertTrue(app.descendants(matching: .any)["v15.f2c.today.macos"].waitForExistence(timeout: 12))
        app.staticTexts["账目库"].click()
        XCTAssertTrue(app.descendants(matching: .any)["v15.f1b.ledger.macos"].waitForExistence(timeout: 8))
        app.terminate()

        assertAppCleanup(service: service)
        let freshLaunch = launchApp(service: service)
        XCTAssertTrue(freshLaunch.staticTexts["连接 Fiscal"].waitForExistence(timeout: 8))
        freshLaunch.terminate()
    }

    func testFormalRootExposesTransportErrorAndOfflineReadOnlyWithoutFixtures() async throws {
        let qaAccessKey = try await mintQAAccessKey()

        let errorService = uniqueKeychainService()
        let errorApp = launchApp(service: errorService, accessKey: qaAccessKey, forceTransportError: true)
        XCTAssertTrue(errorApp.staticTexts["暂时无法取得数据"].waitForExistence(timeout: 8))
        XCTAssertFalse(errorApp.descendants(matching: .any)["v15.gallery.macos"].exists)
        errorApp.terminate()
        assertAppCleanup(service: errorService)

        let offlineService = uniqueKeychainService()
        let connectedApp = launchApp(service: offlineService, accessKey: qaAccessKey)
        XCTAssertTrue(connectedApp.descendants(matching: .any)["v15.f2c.today.macos"].waitForExistence(timeout: 12))
        connectedApp.terminate()

        let offlineApp = launchApp(service: offlineService, forceTransportError: true)
        XCTAssertTrue(offlineApp.descendants(matching: .any)["v15.f2c.offline"].waitForExistence(timeout: 8))
        XCTAssertFalse(offlineApp.descendants(matching: .any)["v15.gallery.macos"].exists)
        offlineApp.terminate()
        assertAppCleanup(service: offlineService)
    }

    func testWorkspaceKeepsFiveModuleNavigationAndSystemDataEntrypointsReachable() async throws {
        let service = uniqueKeychainService()
        let app = launchApp(service: service, accessKey: try await mintQAAccessKey())
        XCTAssertTrue(app.descendants(matching: .any)["v151.mac.workspace"].waitForExistence(timeout: 12))
        func element(_ identifier: String) -> XCUIElement {
            app.descendants(matching: .any)[identifier]
        }

        let navigation = ["ledger", "future", "reports", "archive", "settings"]
        func assertNavigationRemainsVisible() {
            for item in navigation {
                XCTAssertTrue(element("v151.mac.module.\(item)").exists, item)
            }
        }
        func assertHiddenKeyboardCommandsStayOutOfAccessibilityTree() {
            for label in ["下一笔", "上一笔", "预览", "提交"] {
                XCTAssertFalse(app.buttons[label].exists, label)
            }
        }

        assertNavigationRemainsVisible()
        assertHiddenKeyboardCommandsStayOutOfAccessibilityTree()
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "v151.mac.ledger.title").count, 1)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Fiscal /")).count, 0)

        element("v151.mac.module.future").click()
        XCTAssertTrue(element("v151.mac.module.title").waitForExistence(timeout: 5))
        assertHiddenKeyboardCommandsStayOutOfAccessibilityTree()
        XCTAssertTrue(element("v151.mac.future.installments").exists)
        element("v151.mac.future.installments").click()
        XCTAssertTrue(element("v151.mac.module.title").exists)
        XCTAssertTrue(element("v151.mac.module.back").exists)
        element("v151.mac.module.back").click()
        assertNavigationRemainsVisible()

        element("v151.mac.module.ledger").click()
        XCTAssertTrue(element("v151.mac.ledger.search").exists)

        element("v151.mac.module.archive").click()
        XCTAssertTrue(element("v151.mac.module.title").exists)
        assertHiddenKeyboardCommandsStayOutOfAccessibilityTree()
        XCTAssertTrue(element("v151.mac.system.ai-proposals").exists)
        XCTAssertTrue(element("v151.mac.system.statement-import").exists)
        assertNavigationRemainsVisible()

        element("v151.mac.system.ai-proposals").click()
        XCTAssertTrue(element("v151.mac.module.title").exists)
        XCTAssertTrue(element("v151.mac.module.back").exists)
        assertNavigationRemainsVisible()
        element("v151.mac.module.back").click()

        element("v151.mac.system.statement-import").click()
        XCTAssertTrue(element("v151.mac.module.title").exists)
        XCTAssertTrue(element("v151.mac.module.back").exists)
        assertNavigationRemainsVisible()
        app.terminate()
        assertAppCleanup(service: service)
    }
}
