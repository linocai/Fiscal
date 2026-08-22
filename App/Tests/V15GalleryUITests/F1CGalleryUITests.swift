import XCTest

@MainActor final class F1CGalleryUITests: XCTestCase {
    private var app: XCUIApplication!
    private func launch(_ route: String = "master", _ arguments: [String] = []) { app?.terminate(); app = XCUIApplication(); app.launchArguments = ["--v15-f1c-route", route] + arguments; app.launch() }
    private func attach(_ name: String) { let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment) }
    func testMasterDataShowsPrivacySafeAccountsAndLongMerchant() {
        launch(); XCTAssertTrue(app.descendants(matching: .any)["v15.f1c.master.ios"].waitForExistence(timeout: 8)); XCTAssertTrue(app.staticTexts["日常现金"].exists); XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '1234'")).firstMatch.exists)
        app.buttons["商户"].tap(); XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '一段很长的咖啡店'")).firstMatch.waitForExistence(timeout: 5)); attach("f1c-ios-light-long-merchant")
        app.buttons["账户"].tap(); let account = app.descendants(matching: .any)["v15.f1c.account.00000000-0000-0000-0000-00000000C101"]; XCTAssertTrue(account.waitForExistence(timeout: 5)); app.buttons["v15.f1c.add"].tap(); XCTAssertTrue(app.descendants(matching: .any)["v15.f1c.editor"].waitForExistence(timeout: 5)); attach("f1c-ios-light-account-editor")
    }
    func testOfflineArchiveIsDisabledWithReason() {
        launch("master-offline", ["--v15-f1a-appearance", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]); let account = app.descendants(matching: .any)["v15.f1c.account.00000000-0000-0000-0000-00000000C101"]; XCTAssertTrue(account.waitForExistence(timeout: 8)); XCTAssertTrue(app.staticTexts["离线 · 只读"].waitForExistence(timeout: 5)); let add = app.buttons["v15.f1c.add"]; XCTAssertTrue(add.exists); XCTAssertFalse(add.isEnabled); attach("f1c-ios-dark-ax5-offline")
    }
}
