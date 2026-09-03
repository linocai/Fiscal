import XCTest

@MainActor
final class V15RootSmokeUITests: XCTestCase {
    private let qaOnlyPassphrase = "f5b-root-smoke-qa-only"
    private let keychainServicePrefix = "com.linotsai.fiscal.v15-root-smoke.ios.access."

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

    private func launchApp(service: String, accessKey: String? = nil, cleanupOnly: Bool = false, forceTransportError: Bool = false, formalFixture: Bool = false, formalBoundary: Bool = false, scheme: String? = nil, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
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
        app.buttons.matching(identifier: "v151.ios.bottom.ledger").firstMatch.tap()
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

    func testFormalWorkspaceFixtureRendersAt390x844LightDarkAndAX5() {
        let service = uniqueKeychainService()
        let cases: [(name: String, scheme: String?, arguments: [String])] = [
            ("v151-ios-workspace-390x844-light", "light", []),
            ("v151-ios-workspace-390x844-dark", "dark", []),
            ("v151-ios-workspace-390x844-ax5", "light", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        ]
        for testCase in cases {
            let app = launchApp(service: service, formalFixture: true, scheme: testCase.scheme, extraArguments: testCase.arguments)
            let workspace = app.descendants(matching: .any)["v151.ios.workspace-marker"]
            XCTAssertTrue(workspace.waitForExistence(timeout: 8), testCase.name)
            let monthlyExpense = app.descendants(matching: .any)["v151.ios.today.monthly-expense"]
            XCTAssertTrue(monthlyExpense.waitForExistence(timeout: 8), testCase.name)
            XCTAssertTrue(monthlyExpense.label.contains("1,234.56"), testCase.name)
            XCTAssertFalse(app.staticTexts["暂不可用"].exists, testCase.name)
            XCTAssertTrue(app.buttons.matching(identifier: "v151.ios.bottom.today").firstMatch.isHittable, testCase.name)
            XCTAssertTrue(app.buttons.matching(identifier: "v151.ios.bottom.ledger").firstMatch.isHittable, testCase.name)
            XCTAssertTrue(app.buttons.matching(identifier: "v151.ios.record").firstMatch.isHittable, testCase.name)
            if testCase.name.hasSuffix("ax5") {
                let future = app.buttons["v151.ios.today.known-future.item.0"]
                XCTAssertTrue(future.waitForExistence(timeout: 6), testCase.name)
                let today = app.descendants(matching: .any)["v151.ios.today"]
                for _ in 0..<12 where !future.isHittable { today.swipeUp() }
                XCTAssertTrue(future.isHittable, "AX5 content below the first screen must remain reachable")
                XCTAssertTrue(app.buttons.matching(identifier: "v151.ios.bottom.today").firstMatch.isHittable, testCase.name)
            }
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = testCase.name
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    func testFormalWorkspaceBoundaryKeepsMoneyLocalAndNavigationReachable() {
        let service = uniqueKeychainService()
        let app = launchApp(service: service, formalFixture: true, formalBoundary: true, scheme: "light")
        let accountValue = app.descendants(matching: .any)["v151.ios.today.account-value"]
        XCTAssertTrue(accountValue.waitForExistence(timeout: 8))
        XCTAssertTrue(accountValue.label.contains("92,233,720,368,547,758.07"))
        let frame = accountValue.frame
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThanOrEqual(frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(frame.maxX, app.frame.maxX)
        XCTAssertTrue(app.buttons.matching(identifier: "v151.ios.bottom.today").firstMatch.isHittable)
        XCTAssertTrue(app.buttons.matching(identifier: "v151.ios.bottom.ledger").firstMatch.isHittable)
        XCTAssertTrue(app.buttons.matching(identifier: "v151.ios.record").firstMatch.isHittable)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "v151-ios-workspace-boundary-390x844"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    func testFormalWorkspaceLedgerKeepsAccountBalanceBoardVisible() {
        let service = uniqueKeychainService()
        let app = launchApp(service: service, formalFixture: true, scheme: "light")
        XCTAssertTrue(app.descendants(matching: .any)["v151.ios.workspace-marker"].waitForExistence(timeout: 8))

        app.buttons.matching(identifier: "v151.ios.bottom.ledger").firstMatch.tap()

        XCTAssertTrue(app.staticTexts["账户余额"].waitForExistence(timeout: 8))
        let cash = app.descendants(matching: .any)["v151.ios.ledger.account.00000000-0000-0000-0000-000000000101"]
        let credit = app.descendants(matching: .any)["v151.ios.ledger.account.00000000-0000-0000-0000-000000000103"]
        XCTAssertTrue(cash.waitForExistence(timeout: 6))
        XCTAssertTrue(credit.waitForExistence(timeout: 6))
        XCTAssertTrue(cash.label.contains("可用余额"))
        XCTAssertTrue(credit.label.contains("信用欠款"))
        let record = app.buttons.matching(identifier: "v151.ios.record").firstMatch
        XCTAssertTrue(record.isHittable)
        let next = app.buttons["v151.ios.ledger.next"]
        for _ in 0..<8 where !next.isHittable { app.swipeUp() }
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertTrue(next.isHittable)
        XCTAssertFalse(next.frame.intersects(record.frame))

        app.terminate()
    }
}
