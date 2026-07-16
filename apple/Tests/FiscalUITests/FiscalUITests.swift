import XCTest

@MainActor
final class FiscalUITests: XCTestCase {
  private var app: XCUIApplication!

  private func launchApp() throws {
    continueAfterFailure = false
    let token = try XCTUnwrap(
      ProcessInfo.processInfo.environment["FISCAL_UI_TEST_DEVICE_TOKEN"],
      "Set FISCAL_UI_TEST_DEVICE_TOKEN for authenticated integration UI tests."
    )
    app = XCUIApplication()
    app.launchEnvironment["FISCAL_DEVICE_TOKEN"] = token
    app.launch()
  }

  func testAccountsUseRealAPIAndOnlyOneCustomBottomBar() throws {
    try launchApp()
    XCTAssertEqual(
      app.tabBars.count, 0, "The native TabView bar must not exist beneath Fiscal's custom bar.")
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: "fiscal.customBottomBar").count, 1)
    let more = app.buttons["更多"]
    XCTAssertTrue(more.waitForExistence(timeout: 5))
    more.tap()

    let accounts = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "账户")).firstMatch
    XCTAssertTrue(accounts.waitForExistence(timeout: 5))
    accounts.tap()

    XCTAssertTrue(app.staticTexts["招行储蓄卡"].waitForExistence(timeout: 8))
    keepScreenshot(named: "ios-p2-accounts")
  }

  func testP3TransactionListAndRecordSheetUseRealAPI() throws {
    try launchApp()
    XCTAssertEqual(app.tabBars.count, 0)
    let customBar = app.descendants(matching: .any).matching(identifier: "fiscal.customBottomBar")
    XCTAssertEqual(customBar.count, 1)

    app.buttons["流水"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["transactions.screen"].waitForExistence(timeout: 8))
    let search = app.searchFields["搜索标题、备注、账户或分类"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    XCTAssertLessThan(
      search.frame.maxY, customBar.element.frame.minY,
      "iOS 26 must keep search above the custom bottom bar.")
    XCTAssertTrue(app.staticTexts["手冲咖啡与午餐"].waitForExistence(timeout: 8))
    keepScreenshot(named: "ios-p3-transactions")

    let rowMenu = app.buttons
      .matching(identifier: "transaction.rowMenu")
      .matching(NSPredicate(format: "label == %@", "More"))
      .firstMatch
    XCTAssertTrue(rowMenu.waitForExistence(timeout: 5))
    rowMenu.tap()
    let voidMenuItem = app.buttons["作废"]
    XCTAssertTrue(voidMenuItem.waitForExistence(timeout: 3))
    voidMenuItem.tap()
    let confirmVoid = app.alerts.buttons["作废"]
    XCTAssertTrue(confirmVoid.waitForExistence(timeout: 3))
    confirmVoid.tap()
    let undoBar = app.descendants(matching: .any)["transaction.undoBar"]
    XCTAssertTrue(undoBar.waitForExistence(timeout: 5))
    XCTAssertLessThanOrEqual(
      undoBar.frame.maxY, customBar.element.frame.minY,
      "Undo must remain fully above the custom bottom bar.")
    app.buttons["撤销"].tap()
    XCTAssertTrue(undoBar.waitForNonExistence(timeout: 5))

    app.buttons["记一笔"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["transaction.editor"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["支出"].exists)
    XCTAssertTrue(app.buttons["收入"].exists)
    XCTAssertTrue(app.buttons["转账"].exists)
    keepScreenshot(named: "ios-p3-record")
  }

  func testCategoriesReadTheSharedAPIHierarchy() throws {
    try launchApp()
    let more = app.buttons["更多"]
    XCTAssertTrue(more.waitForExistence(timeout: 5))
    more.tap()

    let categories = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "分类设置"))
      .firstMatch
    XCTAssertTrue(categories.waitForExistence(timeout: 5))
    categories.tap()

    XCTAssertTrue(app.staticTexts["餐饮"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["咖啡"].waitForExistence(timeout: 5))
    keepScreenshot(named: "ios-p2-categories")
  }

  func testP4CreditCycleAndRepaymentUseRealAPI() throws {
    try launchApp()
    XCTAssertEqual(app.tabBars.count, 0)
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: "fiscal.customBottomBar").count, 1)

    app.buttons["更多"].tap()
    let creditEntry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "信用账期"))
      .firstMatch
    XCTAssertTrue(creditEntry.waitForExistence(timeout: 5))
    creditEntry.tap()

    let card = app.staticTexts["招行信用卡"]
    XCTAssertTrue(card.waitForExistence(timeout: 8))
    card.tap()
    XCTAssertTrue(app.staticTexts["当前信用负债"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["已逾期"].exists)
    keepScreenshot(named: "ios-credit-account")

    let details = app.buttons["查看明细"]
    XCTAssertTrue(details.waitForExistence(timeout: 5))
    details.tap()
    XCTAssertTrue(app.staticTexts["差旅酒店"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["已逾期"].exists)
    waitForVisualStability()
    keepScreenshot(named: "ios-credit-cycle")

    let repay = app.buttons["全额或部分还款"]
    XCTAssertTrue(repay.waitForExistence(timeout: 5))
    repay.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["transaction.editor"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["目标账期"].exists)
    waitForVisualStability()
    keepScreenshot(named: "ios-credit-repayment")
  }

  func testP5InstallmentSummaryAndDetailUseRealAPI() throws {
    try launchApp()
    XCTAssertEqual(app.tabBars.count, 0)
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: "fiscal.customBottomBar").count, 1)

    app.buttons["更多"].tap()
    let creditEntry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "信用账期与分期"))
      .firstMatch
    XCTAssertTrue(creditEntry.waitForExistence(timeout: 5))
    creditEntry.tap()

    let card = app.staticTexts["招行信用卡"]
    XCTAssertTrue(card.waitForExistence(timeout: 8))
    card.tap()
    XCTAssertTrue(app.staticTexts["分期计划"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["未来计划毛额 ¥3,399.00"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.tabBars.count, 0)
    waitForVisualStability()
    keepScreenshot(named: "ios-installment-summary")

    let plan = app.staticTexts["京东数码 · 配件"]
    XCTAssertTrue(plan.waitForExistence(timeout: 5))
    plan.tap()
    XCTAssertTrue(app.staticTexts["分期详情"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["全部期次"].exists)
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "第 1 期")).firstMatch
        .exists)
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "未来计划毛额")).firstMatch.exists
    )
    XCTAssertEqual(app.tabBars.count, 0)
    waitForVisualStability()
    keepScreenshot(named: "ios-installment-detail")

    let planMenu = app.buttons.matching(NSPredicate(format: "label == %@", "More")).firstMatch
    XCTAssertTrue(planMenu.waitForExistence(timeout: 5))
    planMenu.tap()
    let editPlan = app.buttons["编辑计划"]
    XCTAssertTrue(editPlan.waitForExistence(timeout: 3))
    editPlan.tap()
    XCTAssertTrue(app.staticTexts["编辑分期"].waitForExistence(timeout: 5))
    let preview = app.buttons["预览服务器影响"]
    XCTAssertTrue(preview.waitForExistence(timeout: 8))
    preview.tap()
    XCTAssertTrue(app.buttons["确认保存"].waitForExistence(timeout: 8))
    waitForVisualStability()
    keepScreenshot(named: "ios-installment-edit-preview")
  }

  func testP6ReimbursementDetailAndReceiptPreviewUseRealAPI() throws {
    try launchApp()
    XCTAssertEqual(app.tabBars.count, 0)
    let customBar = app.descendants(matching: .any).matching(identifier: "fiscal.customBottomBar")
    XCTAssertEqual(customBar.count, 1)

    app.buttons["更多"].tap()
    let entry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "报销")).firstMatch
    XCTAssertTrue(entry.waitForExistence(timeout: 5))
    entry.tap()
    XCTAssertTrue(app.staticTexts["报销概览"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["差旅报销单 · 7月"].waitForExistence(timeout: 8))
    XCTAssertEqual(app.tabBars.count, 0)
    keepScreenshot(named: "ios-reimbursements")

    app.staticTexts["差旅报销单 · 7月"].tap()
    XCTAssertTrue(app.staticTexts["付款主体"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["关联垫付 · 主体 × 支出"].exists)
    XCTAssertTrue(app.staticTexts["回款记录"].exists)
    waitForVisualStability()
    keepScreenshot(named: "ios-reimbursement-detail")

    let register = app.buttons["登记到账"].firstMatch
    XCTAssertTrue(register.waitForExistence(timeout: 5))
    register.tap()
    XCTAssertTrue(app.staticTexts["到账信息"].waitForExistence(timeout: 5))
    let amount = app.textFields["金额（分）"]
    XCTAssertTrue(amount.waitForExistence(timeout: 3))
    amount.tap()
    amount.typeText("20000")
    let preview = app.buttons["预览影响"]
    XCTAssertTrue(preview.waitForExistence(timeout: 3))
    preview.tap()
    let confirm = app.buttons["确认到账"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 8))
    if app.keyboards.firstMatch.exists {
      let done = app.buttons["完成"]
      XCTAssertTrue(done.waitForExistence(timeout: 3))
      done.tap()
      XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
    }
    waitForVisualStability()
    keepScreenshot(named: "ios-reimbursement-receipt-preview")
    confirm.tap()
    XCTAssertTrue(app.staticTexts["到账信息"].waitForNonExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["报销到账"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["+¥200.00"].waitForExistence(timeout: 8))
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已到账")).firstMatch.exists)
  }

  func testP7OverviewCashFlowAndReportsUseRealAPI() throws {
    try launchApp()
    XCTAssertEqual(app.tabBars.count, 0)
    let customBar = app.descendants(matching: .any).matching(identifier: "fiscal.customBottomBar")
    XCTAssertEqual(customBar.count, 1)

    XCTAssertTrue(app.staticTexts["本月消费"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["本月实际现金流"].exists)
    XCTAssertTrue(app.staticTexts["当前信用负债"].exists)
    waitForVisualStability()
    keepScreenshot(named: "ios-p7-overview")

    app.buttons["现金流"].tap()
    XCTAssertTrue(app.staticTexts["现金流摘要"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["本月账户收支"].exists)
    XCTAssertEqual(app.tabBars.count, 0)
    waitForVisualStability()
    keepScreenshot(named: "ios-p7-cash-flow")

    app.buttons["更多"].tap()
    let reportEntry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "报表"))
      .firstMatch
    XCTAssertTrue(reportEntry.waitForExistence(timeout: 5))
    reportEntry.tap()
    XCTAssertTrue(app.staticTexts["报表"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["分类构成"].exists)
    XCTAssertFalse(app.segmentedControls.buttons["现金流"].exists)
    XCTAssertEqual(app.tabBars.count, 0)
    waitForVisualStability()
    keepScreenshot(named: "ios-p7-reports")

    app.buttons["负债"].tap()
    XCTAssertTrue(app.staticTexts["分期 · 未来计划毛额"].waitForExistence(timeout: 5))
    keepScreenshot(named: "ios-p7-debt")
  }

  func testP8AIQueueAndSettingsUseRealAPI() throws {
    try launchApp()
    XCTAssertEqual(app.tabBars.count, 0)
    XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "fiscal.customBottomBar").count, 1)

    let overviewAI = app.buttons.matching(identifier: "overview.aiPending").firstMatch
    XCTAssertTrue(overviewAI.waitForExistence(timeout: 10))
    waitForVisualStability()
    keepScreenshot(named: "ios-p8-overview-ai-badge")
    overviewAI.tap()
    XCTAssertTrue(app.navigationBars["AI 待确认"].waitForExistence(timeout: 8))
    waitForVisualStability()
    keepScreenshot(named: "ios-p8-ai-pending")
    let editProposal = app.buttons["编辑"].firstMatch
    XCTAssertTrue(editProposal.waitForExistence(timeout: 5))
    editProposal.tap()
    XCTAssertTrue(app.navigationBars["编辑 AI 提案"].waitForExistence(timeout: 5))
    waitForVisualStability()
    keepScreenshot(named: "ios-p8-ai-edit")
    app.buttons["取消"].tap()
    app.buttons["关闭"].tap()

    app.buttons["更多"].tap()
    let aiEntry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "AI 待确认")).firstMatch
    XCTAssertTrue(aiEntry.waitForExistence(timeout: 8))
    let settings = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "设置")).firstMatch
    XCTAssertTrue(settings.exists)
    settings.tap()
    XCTAssertTrue(app.staticTexts["AI 自动记账"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.buttons.matching(identifier: "ai.settings.save").firstMatch.exists)
    XCTAssertFalse(app.staticTexts["端到端加密"].exists)
    XCTAssertFalse(app.staticTexts["退出登录"].exists)
    waitForVisualStability()
    keepScreenshot(named: "ios-p8-settings-ai")
  }

  func testP9CaptureSettingsAndOCRSourceUseRealAPI() throws {
    try launchApp()
    app.buttons["更多"].tap()
    let settings = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "设置"))
      .firstMatch
    XCTAssertTrue(settings.waitForExistence(timeout: 8))
    settings.tap()
    XCTAssertTrue(app.staticTexts["快捷录入"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["快捷指令文本"].exists)
    XCTAssertTrue(app.staticTexts["截图 OCR"].exists)
    XCTAssertTrue(app.staticTexts["Back Tap 需手工配置"].exists)
    XCTAssertTrue(app.staticTexts["最新截图访问"].exists)
    XCTAssertTrue(app.staticTexts["记账结果通知"].exists)
    waitForVisualStability()
    keepScreenshot(named: "ios-p9-settings-capture")

    app.navigationBars["设置"].buttons["更多"].tap()
    let aiEntry = app.buttons.matching(NSPredicate(
      format: "label CONTAINS %@ AND label CONTAINS %@", "AI 待确认", "1 笔"
    )).firstMatch
    XCTAssertTrue(aiEntry.waitForExistence(timeout: 8))
    aiEntry.tap()
    XCTAssertTrue(app.staticTexts["截图 OCR"].waitForExistence(timeout: 8))
    waitForVisualStability()
    keepScreenshot(named: "ios-p9-ai-ocr-source")

    app.buttons["新建 AI 提案"].tap()
    XCTAssertTrue(app.buttons["截图记账"].waitForExistence(timeout: 5))
    app.buttons["截图记账"].tap()
    XCTAssertTrue(app.navigationBars["截图记账"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["选择图片"].exists)
    XCTAssertTrue(app.buttons["最新截图"].exists)
    waitForVisualStability()
    keepScreenshot(named: "ios-p9-ocr-capture")
  }

  func testP10SingleBottomBarSafeAreaAndModernTransactionEditor() throws {
    try launchApp()
    XCTAssertEqual(app.tabBars.count, 0)
    let customBars = app.descendants(matching: .any).matching(
      identifier: "fiscal.customBottomBar")
    XCTAssertEqual(customBars.count, 1)

    app.buttons["流水"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["transactions.screen"].waitForExistence(timeout: 8))
    let search = app.searchFields["搜索标题、备注、账户或分类"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    XCTAssertLessThan(
      search.frame.maxY, customBars.element.frame.minY,
      "The global ledger search must remain above the one custom safe-area bar.")

    app.buttons["记一笔"].tap()
    let editor = app.descendants(matching: .any)["transaction.editor"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    XCTAssertTrue(app.textFields["金额，例如 38.50"].exists)
    XCTAssertTrue(app.textFields["标题"].exists)
    XCTAssertTrue(app.textFields["备注（可选）"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["transaction.save"].exists)
    XCTAssertEqual(app.tables.count, 0, "The modern transaction editor must not regress to Form.")
    keepScreenshot(named: "ios-p10-modern-transaction-editor")

    app.navigationBars["记一笔"].buttons["取消"].tap()
    XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
    XCTAssertEqual(customBars.count, 1)
  }

  func testP10SettingsExposePreferencesCacheAndRealCSVBoundary() throws {
    try launchApp()
    app.buttons["更多"].tap()
    let settings = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "设置"))
      .firstMatch
    XCTAssertTrue(settings.waitForExistence(timeout: 8))
    settings.tap()

    let preferences = app.descendants(matching: .any)["settings.recordingPreferences"]
    XCTAssertTrue(preferences.waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["记账偏好"].exists)
    XCTAssertTrue(app.staticTexts["默认账户"].exists)
    XCTAssertTrue(app.staticTexts["默认类型"].exists)
    XCTAssertTrue(
      app.descendants(matching: .any).matching(
        NSPredicate(format: "label CONTAINS %@", "保存后停留在记一笔")).firstMatch.exists)

    let cacheTitle = app.staticTexts["本地只读缓存"]
    scrollToElement(cacheTitle)
    XCTAssertTrue(cacheTitle.exists)
    XCTAssertTrue(app.staticTexts["导出当前流水 CSV"].exists)
    XCTAssertTrue(
      app.staticTexts["当前没有缓存响应"].exists
        || app.staticTexts.matching(
          NSPredicate(format: "label CONTAINS %@", "个短时响应")).firstMatch.exists)
    XCTAssertTrue(app.buttons["清除"].exists)
    keepScreenshot(named: "ios-p10-settings-data-boundaries")

    let export = app.buttons["导出"]
    XCTAssertTrue(export.waitForExistence(timeout: 3))
    export.tap()
    let generated = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "CSV 已由服务器生成")).firstMatch
    XCTAssertTrue(
      generated.waitForExistence(timeout: 10),
      "The real filtered CSV response must be returned before the system exporter opens.")
  }

  func testP10UncategorizedAdvancedFiltersAndBatchEntryWithoutCommit() throws {
    try launchApp()
    let inbox = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", "笔待归类")).firstMatch
    XCTAssertTrue(inbox.waitForExistence(timeout: 10))
    inbox.tap()

    XCTAssertTrue(
      app.descendants(matching: .any)["transactions.screen"].waitForExistence(timeout: 8))
    let advancedFilters = app.buttons["高级筛选"]
    XCTAssertTrue(advancedFilters.waitForExistence(timeout: 5))
    advancedFilters.tap()
    XCTAssertTrue(app.navigationBars["高级筛选"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["归类与来源"].exists)
    XCTAssertTrue(app.staticTexts["金额范围"].exists)
    let sourcePicker = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", "来源")).firstMatch
    XCTAssertTrue(sourcePicker.exists)
    sourcePicker.tap()
    XCTAssertTrue(app.buttons["截图 OCR"].waitForExistence(timeout: 3))
    app.buttons["全部"].firstMatch.tap()
    keepScreenshot(named: "ios-p10-advanced-filters")
    app.navigationBars["高级筛选"].buttons["应用"].tap()

    let select = app.buttons["选择"]
    XCTAssertTrue(select.waitForExistence(timeout: 8))
    select.tap()
    let classifiableRow = app.descendants(matching: .any)
      .matching(identifier: "transaction.classifiableRow").firstMatch
    XCTAssertTrue(classifiableRow.waitForExistence(timeout: 8))
    classifiableRow.tap()

    let batchBar = app.descendants(matching: .any)["transactions.batchBar"]
    XCTAssertTrue(batchBar.waitForExistence(timeout: 5))
    batchBar.buttons["重新分类"].tap()
    XCTAssertTrue(app.navigationBars["批量重新分类"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["原子批量操作"].exists)
    let confirm = app.buttons["确认重新分类"]
    XCTAssertTrue(confirm.exists)
    XCTAssertFalse(confirm.isEnabled, "QA must not choose a target category or submit the batch.")
    keepScreenshot(named: "ios-p10-batch-classification-entry")

    app.navigationBars["批量重新分类"].buttons["取消"].tap()
    XCTAssertTrue(batchBar.waitForExistence(timeout: 5))
    batchBar.buttons["取消"].tap()
    XCTAssertTrue(batchBar.waitForNonExistence(timeout: 5))
  }

  func testP10DarkLargeTextLedgerKeepsSafeAreaAndHierarchy() throws {
    try launchApp()
    XCTAssertEqual(app.tabBars.count, 0)
    let customBars = app.descendants(matching: .any).matching(
      identifier: "fiscal.customBottomBar")
    XCTAssertEqual(customBars.count, 1)

    app.buttons["流水"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["transactions.screen"].waitForExistence(timeout: 8))
    let search = app.searchFields["搜索标题、备注、账户或分类"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    XCTAssertLessThan(
      search.frame.maxY, customBars.element.frame.minY,
      "AX text must not let ledger controls overlap the one custom safe-area bar.")
    waitForVisualStability()
    keepScreenshot(named: "ios-p10-dark-large-text-transactions")
  }

  private func keepScreenshot(named name: String) {
    let screenshot = app.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    if let directory = ProcessInfo.processInfo.environment["FISCAL_QA_SCREENSHOT_DIR"] {
      let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(
        "\(name).png")
      try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? screenshot.pngRepresentation.write(to: url, options: .atomic)
    }
  }

  private func waitForVisualStability() {
    let expectation = expectation(description: "wait for navigation and sheet animations")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { expectation.fulfill() }
    wait(for: [expectation], timeout: 2)
  }

  private func scrollToElement(_ element: XCUIElement, swipes: Int = 8) {
    for _ in 0..<swipes {
      if element.isHittable { return }
      app.swipeUp()
    }
  }
}
