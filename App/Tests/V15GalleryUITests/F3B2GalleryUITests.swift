import XCTest

@MainActor final class F3B2GalleryUITests: XCTestCase {
    private var app = XCUIApplication()

    private func launch(_ route: String, extra: [String] = []) {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--v15-f3b2-route", route] + extra
        app.launch()
        XCTAssertTrue(element("v15.f3b2.installments.ios").waitForExistence(timeout: 10))
        XCTAssertTrue(element("v15.f3b2.detail").waitForExistence(timeout: 10))
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
    private func button(_ id: String) -> XCUIElement { app.buttons[id] }
    private func textField(_ id: String) -> XCUIElement { app.textFields[id] }

    @discardableResult private func reveal(_ id: String, swipes: Int = 8) -> XCUIElement {
        let value = element(id)
        for _ in 0..<swipes where !value.exists || !value.isHittable { app.swipeUp() }
        XCTAssertTrue(value.waitForExistence(timeout: 5), "missing \(id)")
        return value
    }

    @discardableResult private func revealButton(_ id: String, requireHittable: Bool = true, swipes: Int = 8) -> XCUIElement {
        let value = button(id)
        for _ in 0..<swipes where !value.exists || (requireHittable && !value.isHittable) { app.swipeUp() }
        XCTAssertTrue(value.waitForExistence(timeout: 5), "missing button \(id)")
        return value
    }

    @discardableResult private func revealTextField(_ id: String, upward: Bool = true) -> XCUIElement {
        let value = textField(id)
        for _ in 0..<8 where !value.exists || !value.isHittable { upward ? app.swipeUp() : app.swipeDown() }
        XCTAssertTrue(value.waitForExistence(timeout: 5), "missing text field \(id)")
        return value
    }

    private func replace(_ value: String, in field: XCUIElement) {
        field.tap(); field.press(forDuration: 0.8)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        else if app.menuItems["全选"].waitForExistence(timeout: 2) { app.menuItems["全选"].tap() }
        field.typeText(value)
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testLedgerHandoffOpensExistingPurchaseWithTransactionPrefilled() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--v15-f3b2-route", "installments-existing-prefilled"]
        app.launch()
        XCTAssertTrue(element("v15.f3b2.installments.ios").waitForExistence(timeout: 10))
        XCTAssertTrue(element("v15.f3b2.sheet.existingPurchase").waitForExistence(timeout: 6))
        let transaction = textField("v15.f3b2.eligibility.transaction")
        XCTAssertTrue(transaction.waitForExistence(timeout: 5))
        XCTAssertEqual((transaction.value as? String)?.lowercased(), "00000000-0000-0000-0000-00000000b410")
        button("v15.f3b2.eligibility.check").tap()
        XCTAssertTrue(reveal("v15.f3b2.eligibility.success").waitForExistence(timeout: 6))
    }

    func testFiveStatesFutureUnknownAndOfflineReadOnlyAreVisible() {
        launch("installments")
        for id in [
            "00000000-0000-0000-0000-00000000B401", "00000000-0000-0000-0000-00000000B402",
            "00000000-0000-0000-0000-00000000B403", "00000000-0000-0000-0000-00000000B404",
            "00000000-0000-0000-0000-00000000B405", "00000000-0000-0000-0000-00000000B406"
        ] { XCTAssertTrue(revealButton("v15.f3b2.plan.\(id)").exists) }
        revealButton("v15.f3b2.plan.00000000-0000-0000-0000-00000000B406").tap()
        XCTAssertTrue(reveal("v15.f3b2.unknown-state").waitForExistence(timeout: 6)); attach("f3b2-ios-five-states-unknown")

        launch("installments-offline", extra: ["--v15-f1a-appearance", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(element("v15.f3b2.offline").waitForExistence(timeout: 5))
        XCTAssertFalse(revealButton("v15.f3b2.command.open", requireHittable: false).isEnabled); attach("f3b2-ios-offline-dark-ax5")
    }

    func testCommandSuccessUnknownSameKeyRecoveryAndConflictAreReachable() {
        launch("installments")
        revealButton("v15.f3b2.command.open").tap(); XCTAssertTrue(element("v15.f3b2.sheet.command").waitForExistence(timeout: 5))
        revealButton("v15.f3b2.command.preview").tap(); XCTAssertTrue(reveal("v15.f3b2.command.preview-result").waitForExistence(timeout: 5))
        XCTAssertTrue(reveal("v15.f3b2.command.preview-detail.settlement.period.1").exists)
        XCTAssertTrue(reveal("v15.f3b2.command.preview-detail.settlement.period.7").exists)
        XCTAssertTrue(reveal("v15.f3b2.command.preview-detail.settlement.cycle.2026-11-10").exists)
        XCTAssertTrue(reveal("v15.f3b2.command.preview-detail.settlement.warning.locked_periods_retained").exists)
        revealButton("v15.f3b2.command.commit").tap(); XCTAssertTrue(reveal("v15.f3b2.command.receipt").waitForExistence(timeout: 8))
        XCTAssertTrue(reveal("v15.f3b2.command.transaction.00000000-0000-0000-0000-00000000B416").exists); attach("f3b2-ios-command-receipt")

        launch("installments-command-unknown")
        revealButton("v15.f3b2.command.open").tap(); revealButton("v15.f3b2.command.preview").tap()
        XCTAssertTrue(reveal("v15.f3b2.command.preview-result").waitForExistence(timeout: 5)); revealButton("v15.f3b2.command.commit").tap()
        XCTAssertTrue(reveal("v15.f3b2.command.unknown").waitForExistence(timeout: 5))
        XCTAssertFalse(button("v15.f3b2.command.preview").isEnabled); XCTAssertFalse(button("v15.f3b2.command.commit").isEnabled)
        revealButton("v15.f3b2.command.readback").tap()
        XCTAssertTrue(reveal("v15.f3b2.command.readback.not-confirmed").waitForExistence(timeout: 8)); XCTAssertTrue(element("v15.f3b2.command.unknown").exists)
        revealButton("v15.f3b2.command.retry").tap(); XCTAssertTrue(reveal("v15.f3b2.command.receipt").waitForExistence(timeout: 8)); attach("f3b2-ios-command-same-key-replayed")

        launch("installments-command-conflict")
        revealButton("v15.f3b2.command.open").tap(); revealButton("v15.f3b2.command.preview").tap(); XCTAssertTrue(reveal("v15.f3b2.command.preview-result").waitForExistence(timeout: 5)); revealButton("v15.f3b2.command.commit").tap()
        XCTAssertTrue(reveal("v15.f3b2.command.conflict").waitForExistence(timeout: 6)); attach("f3b2-ios-command-conflict")
    }

    func testNoKeyPlanPUTUsesFreshReadbackForConfirmedNotConfirmedAndFailure() {
        launch("installments-update-unknown-confirmed")
        revealButton("v15.f3b2.edit.open").tap()
        replace("更新后的设备计划", in: revealTextField("v15.f3b2.edit.title")); replace("3399.00", in: revealTextField("v15.f3b2.edit.amount")); replace("7", in: revealTextField("v15.f3b2.edit.count"))
        revealButton("v15.f3b2.edit.preview").tap(); XCTAssertTrue(reveal("v15.f3b2.edit.preview-result").waitForExistence(timeout: 5)); revealButton("v15.f3b2.edit.commit").tap()
        XCTAssertTrue(reveal("v15.f3b2.edit.unknown").waitForExistence(timeout: 5)); revealButton("v15.f3b2.edit.readback").tap()
        XCTAssertTrue(reveal("v15.f3b2.edit.readback.confirmed").waitForExistence(timeout: 8)); attach("f3b2-ios-put-readback-confirmed")

        launch("installments-update-unknown-not-confirmed")
        revealButton("v15.f3b2.edit.open").tap(); revealButton("v15.f3b2.edit.preview").tap(); revealButton("v15.f3b2.edit.commit").tap(); XCTAssertTrue(reveal("v15.f3b2.edit.unknown").waitForExistence(timeout: 5)); revealButton("v15.f3b2.edit.readback").tap()
        XCTAssertTrue(reveal("v15.f3b2.edit.readback.not-confirmed").waitForExistence(timeout: 8))

        launch("installments-update-fee-date-mismatch")
        revealButton("v15.f3b2.edit.open").tap(); replace("更新后的设备计划", in: revealTextField("v15.f3b2.edit.title")); replace("3399.00", in: revealTextField("v15.f3b2.edit.amount")); replace("7", in: revealTextField("v15.f3b2.edit.count"))
        revealButton("v15.f3b2.edit.preview").tap(); revealButton("v15.f3b2.edit.commit").tap(); XCTAssertTrue(reveal("v15.f3b2.edit.unknown").waitForExistence(timeout: 5)); revealButton("v15.f3b2.edit.readback").tap()
        XCTAssertTrue(reveal("v15.f3b2.edit.readback.not-confirmed").waitForExistence(timeout: 8)); attach("f3b2-ios-put-fee-date-mismatch")

        launch("installments-update-readback-error")
        revealButton("v15.f3b2.edit.open").tap(); revealButton("v15.f3b2.edit.preview").tap(); revealButton("v15.f3b2.edit.commit").tap(); XCTAssertTrue(reveal("v15.f3b2.edit.unknown").waitForExistence(timeout: 5)); revealButton("v15.f3b2.edit.readback").tap()
        XCTAssertTrue(reveal("v15.f3b2.edit.readback.error").waitForExistence(timeout: 8)); attach("f3b2-ios-put-readback-failure")
    }

    func testEligibilityReasonPageFailureAndPurchaseInputInvalidationAreVisible() {
        launch("installments-ineligible")
        button("v15.f3b2.existing.open").tap(); XCTAssertTrue(element("v15.f3b2.sheet.existingPurchase").waitForExistence(timeout: 5))
        let transaction = textField("v15.f3b2.eligibility.transaction"); XCTAssertTrue(transaction.waitForExistence(timeout: 4)); replace("00000000-0000-0000-0000-00000000B410", in: transaction)
        button("v15.f3b2.eligibility.check").tap(); XCTAssertTrue(reveal("v15.f3b2.eligibility.reason").waitForExistence(timeout: 6)); XCTAssertFalse(button("v15.f3b2.existing.commit").isEnabled); attach("f3b2-ios-ineligible-reason")

        launch("installments-page-error")
        revealButton("v15.f3b2.page.next").tap(); XCTAssertTrue(reveal("v15.f3b2.page.error").waitForExistence(timeout: 6)); attach("f3b2-ios-page-local-failure")

        launch("installments")
        button("v15.f3b2.purchase.open").tap(); XCTAssertTrue(element("v15.f3b2.sheet.purchase").waitForExistence(timeout: 5))
        XCTAssertFalse(button("v15.f3b2.purchase.preview").isEnabled)
        replace("工作设备", in: revealTextField("v15.f3b2.purchase.title")); replace("3299.00", in: revealTextField("v15.f3b2.purchase.amount"))
        button("v15.f3b2.purchase.account").tap(); app.buttons["日常信用账户"].tap()
        button("v15.f3b2.purchase.category").tap(); app.buttons["数码设备"].tap()
        replace("99.96", in: revealTextField("v15.f3b2.purchase.fee")); XCTAssertFalse(button("v15.f3b2.purchase.preview").isEnabled)
        revealButton("v15.f3b2.purchase.fee-category").tap(); app.buttons["数码设备"].tap(); XCTAssertFalse(button("v15.f3b2.purchase.preview").isEnabled)
        replace("2026-08-15", in: revealTextField("v15.f3b2.purchase.fee-date"))
        replace("2026-09-10", in: revealTextField("v15.f3b2.purchase.start"))
        XCTAssertTrue(revealButton("v15.f3b2.purchase.preview").isEnabled); revealButton("v15.f3b2.purchase.preview").tap()
        XCTAssertTrue(reveal("v15.f3b2.purchase.preview-result").waitForExistence(timeout: 6)); XCTAssertTrue(reveal("v15.f3b2.purchase.preview-detail.period.1").exists); XCTAssertTrue(reveal("v15.f3b2.purchase.preview-detail.period.3").exists); XCTAssertTrue(button("v15.f3b2.purchase.commit").isEnabled)
        replace("invalid", in: revealTextField("v15.f3b2.purchase.amount", upward: false)); XCTAssertFalse(button("v15.f3b2.purchase.commit").isEnabled); XCTAssertFalse(element("v15.f3b2.purchase.preview-result").exists); attach("f3b2-ios-purchase-preview-invalidated")
        replace("3299.00", in: revealTextField("v15.f3b2.purchase.amount", upward: false)); revealButton("v15.f3b2.purchase.preview").tap(); revealButton("v15.f3b2.purchase.commit").tap()
        XCTAssertTrue(reveal("v15.f3b2.purchase.receipt").waitForExistence(timeout: 8)); attach("f3b2-ios-positive-fee-purchase-success")
    }

    func testPositiveFeeExistingPurchaseAndEditFlowsExposeCategoryDateAndComplete() {
        launch("installments-category-error")
        button("v15.f3b2.purchase.open").tap()
        // The purchase's main category is authoritative even when fee == 0.
        XCTAssertTrue(reveal("v15.f3b2.purchase.category.error").waitForExistence(timeout: 5)); XCTAssertFalse(button("v15.f3b2.purchase.preview").isEnabled)
        revealButton("v15.f3b2.purchase.category.retry").tap(); XCTAssertTrue(revealButton("v15.f3b2.purchase.category").waitForExistence(timeout: 6))
        replace("零手续费工作设备", in: revealTextField("v15.f3b2.purchase.title")); replace("3299.00", in: revealTextField("v15.f3b2.purchase.amount"))
        revealButton("v15.f3b2.purchase.account").tap(); app.buttons["日常信用账户"].tap()
        revealButton("v15.f3b2.purchase.category").tap(); app.buttons["数码设备"].tap()
        replace("2026-09-10", in: revealTextField("v15.f3b2.purchase.start"))
        XCTAssertTrue(revealButton("v15.f3b2.purchase.preview").isEnabled); revealButton("v15.f3b2.purchase.preview").tap()
        XCTAssertTrue(reveal("v15.f3b2.purchase.preview-result").waitForExistence(timeout: 6)); revealButton("v15.f3b2.purchase.commit").tap()
        XCTAssertTrue(reveal("v15.f3b2.purchase.receipt").waitForExistence(timeout: 8)); attach("f3b2-ios-zero-fee-category-retry-success")

        launch("installments-category-error")
        button("v15.f3b2.purchase.open").tap(); replace("99.96", in: revealTextField("v15.f3b2.purchase.fee"))
        XCTAssertTrue(reveal("v15.f3b2.purchase.fee-category.error").waitForExistence(timeout: 5)); XCTAssertFalse(button("v15.f3b2.purchase.preview").isEnabled)

        launch("installments")
        button("v15.f3b2.existing.open").tap(); XCTAssertTrue(element("v15.f3b2.sheet.existingPurchase").waitForExistence(timeout: 5))
        replace("00000000-0000-0000-0000-00000000b410", in: revealTextField("v15.f3b2.eligibility.transaction")); button("v15.f3b2.eligibility.check").tap()
        XCTAssertTrue(reveal("v15.f3b2.eligibility.success").waitForExistence(timeout: 6))
        XCTAssertTrue(reveal("v15.f3b2.eligibility.purchase.loaded").waitForExistence(timeout: 6))
        replace("99.96", in: revealTextField("v15.f3b2.existing.fee")); XCTAssertFalse(button("v15.f3b2.existing.commit").isEnabled)
        revealButton("v15.f3b2.existing.fee-category").tap(); app.buttons["数码设备"].tap(); XCTAssertFalse(button("v15.f3b2.existing.commit").isEnabled)
        replace("2026-08-14", in: revealTextField("v15.f3b2.existing.fee-date")); XCTAssertFalse(revealButton("v15.f3b2.existing.commit").isEnabled)
        replace("2026-08-15", in: revealTextField("v15.f3b2.existing.fee-date")); XCTAssertTrue(revealButton("v15.f3b2.existing.commit").isEnabled)
        revealButton("v15.f3b2.existing.commit").tap(); XCTAssertTrue(reveal("v15.f3b2.existing.success").waitForExistence(timeout: 8)); attach("f3b2-ios-positive-fee-existing-success")

        launch("installments")
        revealButton("v15.f3b2.edit.open").tap(); XCTAssertTrue(element("v15.f3b2.sheet.edit").waitForExistence(timeout: 5))
        replace("0.00", in: revealTextField("v15.f3b2.edit.fee")); replace("99.96", in: revealTextField("v15.f3b2.edit.fee")); XCTAssertFalse(button("v15.f3b2.edit.preview").isEnabled)
        revealButton("v15.f3b2.edit.fee-category").tap(); app.buttons["数码设备"].tap(); XCTAssertFalse(button("v15.f3b2.edit.preview").isEnabled)
        replace("2026-08-15", in: revealTextField("v15.f3b2.edit.fee-date")); XCTAssertTrue(revealButton("v15.f3b2.edit.preview").isEnabled)
        revealButton("v15.f3b2.edit.preview").tap(); XCTAssertTrue(reveal("v15.f3b2.edit.preview-result").waitForExistence(timeout: 6))
        XCTAssertTrue(reveal("v15.f3b2.edit.preview-detail.locked.1").exists); XCTAssertTrue(reveal("v15.f3b2.edit.preview-detail.future.7").exists)
        XCTAssertTrue(reveal("v15.f3b2.edit.preview-detail.cycle.2026-11-10").exists); XCTAssertTrue(reveal("v15.f3b2.edit.preview-detail.warning.future_cycles_shifted").exists)
        revealButton("v15.f3b2.edit.commit").tap(); XCTAssertTrue(reveal("v15.f3b2.edit.success").waitForExistence(timeout: 8)); attach("f3b2-ios-positive-fee-edit-success")
    }

    func testReverseAndCancelPreviewExposeConcreteFirstLastPeriodsCyclesAndWarnings() {
        launch("installments")
        revealButton("v15.f3b2.command.open").tap(); app.buttons["撤销结清"].tap(); revealButton("v15.f3b2.command.preview").tap()
        XCTAssertTrue(reveal("v15.f3b2.command.preview-detail.reverse.eligibility").waitForExistence(timeout: 6))
        XCTAssertTrue(reveal("v15.f3b2.command.preview-detail.reverse.period.1").exists); XCTAssertTrue(reveal("v15.f3b2.command.preview-detail.reverse.period.7").exists)
        XCTAssertTrue(reveal("v15.f3b2.command.preview-detail.reverse.cycle.2026-11-10").exists); XCTAssertTrue(reveal("v15.f3b2.command.preview-detail.reverse.warning.repayment_void").exists)

        launch("installments")
        revealButton("v15.f3b2.command.open").tap(); app.buttons["取消未来期次"].tap(); revealButton("v15.f3b2.command.preview").tap()
        XCTAssertTrue(reveal("v15.f3b2.command.preview-detail.cancellation.period.2").waitForExistence(timeout: 6)); XCTAssertTrue(reveal("v15.f3b2.command.preview-detail.cancellation.period.7").exists)
        XCTAssertTrue(reveal("v15.f3b2.command.preview-detail.cancellation.cycle.2026-11-10").exists); XCTAssertTrue(reveal("v15.f3b2.command.preview-detail.cancellation.warning.future_only").exists); attach("f3b2-ios-command-preview-details")
    }
}
