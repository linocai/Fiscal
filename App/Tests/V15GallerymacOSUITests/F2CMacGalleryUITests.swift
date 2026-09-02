import XCTest

@MainActor final class F2CMacGalleryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ route: String) {
        app = launchGalleryMac(["--v15-f2c-route", route])
        XCTAssertTrue(app.descendants(matching: .any)["v15.f2c.today.macos"].waitForExistence(timeout: 8))
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func openCashAccounts() {
        let lens = element("v15.f2c.lens.cash_accounts")
        XCTAssertTrue(lens.waitForExistence(timeout: 5), "facts must finish loading before a range can be opened")
        lens.click()
    }

    func testScopesPaginationAndInspectorCloseAreClickable() {
        launch("today")
        openCashAccounts()
        XCTAssertTrue(element("v15.f2c.scope.row.cash_accounts.0").waitForExistence(timeout: 5))
        element("v15.f2c.scope.row.cash_accounts.0").click()
        XCTAssertTrue(element("v15.f2c.inspector").waitForExistence(timeout: 3))
        element("v15.f2c.inspector.close").click()
        XCTAssertTrue(element("v15.f2c.inspector").waitForNonExistence(timeout: 3))
        element("v15.f2c.scope.next").click()
        XCTAssertTrue(element("v15.f2c.scope.row.cash_accounts.1").waitForExistence(timeout: 3))
    }

    func testRefreshWithoutOpenScopeDoesNotNavigateOrOpenAnInspector() {
        launch("today-refresh-delay")
        XCTAssertFalse(element("v15.f2c.scope.title.cash_accounts").exists)
        element("v15.f2c.refresh").click()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertFalse(element("v15.f2c.scope.title.cash_accounts").exists)
        XCTAssertFalse(element("v15.f2c.inspector").exists)
    }

    func testScopeFailureRetryConflictUnknownAndKeyboardRefresh() {
        launch("today-scope-error")
        openCashAccounts()
        XCTAssertTrue(element("v15.f2c.scope.error").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["重试"].exists)

        launch("today-conflict")
        openCashAccounts()
        XCTAssertTrue(element("v15.f2c.facts.conflict").waitForExistence(timeout: 5))
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(element("v15.f2c.scope.row.cash_accounts.0").waitForExistence(timeout: 5), "refresh must reopen the selected scope with the new revision")

        launch("today-unknown")
        openCashAccounts()
        XCTAssertTrue(element("v15.f2c.scope.row.cash_accounts.0").waitForExistence(timeout: 5))
        element("v15.f2c.scope.row.cash_accounts.0").click()
        XCTAssertTrue(element("v15.f2c.inspector").waitForExistence(timeout: 4))
    }

    func testRefreshUsesTheLensChosenWhileRefreshWasInFlight() {
        launch("today-refresh-lens-race")
        element("v15.f2c.lens.cash_accounts").click()
        XCTAssertTrue(element("v15.f2c.facts.conflict").waitForExistence(timeout: 5))

        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(element("v15.f2c.facts.loading").waitForExistence(timeout: 3), "fixture must keep the refresh in flight before the lens changes")
        element("v15.f2c.lens.credit_cycles").click()

        XCTAssertTrue(element("v15.f2c.scope.row.credit_cycles.0").waitForExistence(timeout: 5))
        XCTAssertTrue(element("v15.f2c.scope.title.credit_cycles").exists)
        XCTAssertFalse(element("v15.f2c.scope.row.cash_accounts.0").exists)
        XCTAssertFalse(element("v15.f2c.scope.title.cash_accounts").exists)
    }
}
