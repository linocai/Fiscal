@testable import FiscalPreviewSupportmacOS
import Foundation
import Testing
@testable import FiscalKit

@Suite("v1.7 macOS ledger context")
struct V151MacLedgerScopeTests {
  @Test("Account balance cards distinguish assets from credit debt")
  func accountBalanceCardSemantics() {
    #expect(V151MacAccountBalanceSemantics.kindLabel(.cash) == "现金")
    #expect(V151MacAccountBalanceSemantics.kindLabel(.debit) == "借记")
    #expect(V151MacAccountBalanceSemantics.kindLabel(.credit) == "信用")
    #expect(V151MacAccountBalanceSemantics.amountLabel(.cash, minorUnits: 100) == "余额")
    #expect(V151MacAccountBalanceSemantics.amountLabel(.debit, minorUnits: 100) == "余额")
    #expect(V151MacAccountBalanceSemantics.amountLabel(.credit, minorUnits: 100) == "欠款")
    #expect(V151MacAccountBalanceSemantics.direction(.debit, minorUnits: 100) == .balance)
    #expect(V151MacAccountBalanceSemantics.direction(.credit, minorUnits: 100) == .outflow)
    #expect(V151MacAccountBalanceSemantics.direction(.credit, minorUnits: 0) == .balance)
    #expect(V151MacAccountBalanceSemantics.amountLabel(.credit, minorUnits: -100) == "信用溢缴")
    #expect(V151MacAccountBalanceSemantics.direction(.credit, minorUnits: -100) == .neutral)
  }

  @Test("Month context uses the Shanghai business-month range")
  func monthContextUsesShanghaiRange() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let july = try #require(calendar.date(from: .init(year: 2026, month: 7, day: 15)))
    let range = try #require(V151MacBusinessDateRange.monthDateRange(containing: july))
    #expect(range == .init(from: "2026-07-01", to: "2026-07-31"))
  }

  @Test("Ledger account filter survives detail changes and clears only after references remove it")
  func accountFilterAndDetailOwnershipStaySeparate() {
    let retained = V15F1BFixtures.accountID
    let other = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let accounts = [
      V15AccountResponse(
        id: retained,
        name: "保留账户",
        kind: .cash,
        institution: nil,
        lastFour: nil,
        openingBalanceMinor: 0,
        currentBalanceMinor: 100,
        creditLimitMinor: nil,
        statementDay: nil,
        dueDay: nil,
        cycleMode: nil,
        openingBalanceAsOfDate: nil,
        openingDueDate: nil,
        sortOrder: 0,
        archivedAt: nil,
        usageCount: 0,
        version: 1,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
      )
    ]

    var context = V151MacLedgerAccountContext(filterID: nil, detailID: nil)
    context.selectAccount(retained)
    context.selectTransaction()
    #expect(context.filterID == retained)
    #expect(context.detailID == nil)
    context.selectDetailAccount(retained)
    context.showFilteredLedger()
    #expect(context.filterID == retained)
    #expect(context.detailID == nil)
    #expect(context.clearMissingFilter(availableAccounts: accounts) == nil)
    #expect(context.filterID == retained)
    context.selectDetailAccount(retained)
    #expect(context.clearMissingFilter(availableAccounts: []) == retained)
    #expect(context.filterID == nil)
    #expect(context.detailID == nil)
    #expect(V151MacLedgerAccountFilter.retainedAccountID(other, availableAccounts: accounts) == nil)
    context.selectAccount(retained)
    context.clearAllAccounts()
    #expect(context.filterID == nil)
    #expect(context.detailID == nil)
  }

  @Test("Ledger search draft changes only on explicit confirmation")
  func searchDraftRequiresConfirmation() {
    #expect(V151MacLedgerSearch.committedQuery(from: "午餐") == "午餐")
    #expect(V151MacLedgerSearch.committedQuery(from: "") == nil)
  }
}
