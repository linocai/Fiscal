import Foundation
import Testing

@testable import FiscalKit

@Suite("FiscalKit P16 transaction H4")
struct P16TransactionTests {
  // MARK: H4 – switching kind clears references that no longer fit the new kind

  @Test("changeKind clears direction/account-incompatible references") @MainActor
  func changeKindClearsIncompatibleReferences() {
    // expense (category + non-credit account) → income drops the wrong-direction category
    let toIncome = TransactionEditorModel()
    toIncome.draft.categoryID = UUID()
    let keptAccount = UUID()
    toIncome.draft.accountID = keptAccount
    toIncome.changeKind(.income)
    #expect(toIncome.draft.categoryID == nil)
    #expect(toIncome.draft.accountID == keptAccount)  // non-credit account fits both kinds

    // expense → credit purchase keeps the expense category but drops the non-credit account
    let toCredit = TransactionEditorModel()
    let expenseCategory = UUID()
    toCredit.draft.categoryID = expenseCategory
    toCredit.draft.accountID = UUID()
    toCredit.changeKind(.creditPurchase)
    #expect(toCredit.draft.categoryID == expenseCategory)
    #expect(toCredit.draft.accountID == nil)

    // transfer → repayment drops the incompatible destination account and keeps no category
    let toRepayment = TransactionEditorModel()
    toRepayment.changeKind(.transfer)
    toRepayment.draft.destinationAccountID = UUID()
    toRepayment.changeKind(.repayment)
    #expect(toRepayment.draft.destinationAccountID == nil)
    #expect(toRepayment.draft.categoryID == nil)
  }

  @Test("validateReferences rejects wrong-typed account/category") @MainActor
  func validateReferencesCatchesTypeMismatch() throws {
    let cash = account(kind: .debit)
    let credit = account(kind: .credit)
    let expenseCategory = try category(direction: .expense)
    let incomeCategory = try category(direction: .income)
    let accounts = [cash, credit]
    let categories = [expenseCategory, incomeCategory]

    // credit purchase must use a credit account
    var purchase = TransactionDraft()
    purchase.kind = .creditPurchase
    purchase.accountID = cash.id
    purchase.categoryID = expenseCategory.id
    #expect(
      TransactionEditorModel.validateReferences(purchase, accounts: accounts, categories: categories)
        != nil)
    purchase.accountID = credit.id
    #expect(
      TransactionEditorModel.validateReferences(purchase, accounts: accounts, categories: categories)
        == nil)

    // expense must use an expense-direction category
    var expense = TransactionDraft()
    expense.kind = .expense
    expense.accountID = cash.id
    expense.categoryID = incomeCategory.id
    #expect(
      TransactionEditorModel.validateReferences(expense, accounts: accounts, categories: categories)
        != nil)

    // repayment must target a credit destination and use a non-credit source
    var repayment = TransactionDraft()
    repayment.kind = .repayment
    repayment.accountID = cash.id
    repayment.destinationAccountID = cash.id
    #expect(
      TransactionEditorModel.validateReferences(
        repayment, accounts: accounts, categories: categories) != nil)
    repayment.destinationAccountID = credit.id
    repayment.creditCycleID = UUID()
    #expect(
      TransactionEditorModel.validateReferences(
        repayment, accounts: accounts, categories: categories) == nil)
  }

  @Test("On-demand borrowing and repayment preserve financial roles and wire fields") @MainActor
  func onDemandDraftSemantics() throws {
    let cash = account(kind: .debit)
    var loan = account(kind: .credit)
    loan.cycleMode = .onDemand
    var draft = TransactionDraft()
    draft.kind = .borrowing
    draft.title = "测试借入"
    draft.amountMinor = 12_345
    draft.accountID = loan.id
    draft.destinationAccountID = cash.id
    #expect(TransactionEditorModel.validate(draft) == nil)
    #expect(TransactionEditorModel.validateReferences(draft, accounts: [loan, cash], categories: []) == nil)
    let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
    #expect(encoded["kind"] as? String == "borrowing")
    #expect(encoded["destination_account_id"] as? String == cash.id.uuidString)
    #expect(encoded["credit_cycle_id"] is NSNull)

    draft.kind = .repayment; draft.accountID = cash.id; draft.destinationAccountID = loan.id
    #expect(TransactionEditorModel.validate(draft) == nil)
    #expect(TransactionEditorModel.validateReferences(draft, accounts: [loan, cash], categories: []) == nil)
    draft.creditCycleID = UUID()
    #expect(TransactionEditorModel.validateReferences(draft, accounts: [loan, cash], categories: []) != nil)

    let editor = TransactionEditorModel()
    editor.changeKind(.borrowing); editor.draft.accountID = loan.id; editor.draft.destinationAccountID = cash.id
    editor.changeKind(.creditPurchase)
    #expect(editor.draft.accountID == nil)
    #expect(editor.draft.destinationAccountID == nil)
    for kind in [TransactionKind.creditPrincipalWaiver, .creditFeeRefund, .creditSettlementFee] {
      draft.kind = kind
      #expect(!TransactionKind.allCases.contains(kind))
      #expect(TransactionEditorModel.validate(draft) != nil)
    }
  }

  @Test("On-demand opening debt needs a real confirmation date without billing fields") @MainActor
  func onDemandOpeningValidation() {
    var draft = AccountDraft()
    draft.kind = .credit; draft.cycleMode = .onDemand; draft.name = "合成借款"
    draft.openingBalanceMinor = 12_345
    #expect(AccountsModel.validate(draft) != nil)
    draft.openingBalanceAsOfDate = "2026-02-30"
    #expect(AccountsModel.validate(draft) != nil)
    draft.openingBalanceAsOfDate = "2026-02-28"
    #expect(AccountsModel.validate(draft) == nil)
    draft.openingDueDate = "2026-03-01"
    #expect(AccountsModel.validate(draft) != nil)
    draft.openingDueDate = nil; draft.creditLimitMinor = 0
    #expect(AccountsModel.validate(draft) != nil)
  }

  @Test("Credit summary decodes an on-demand account with no invented cycle or limit")
  func onDemandSummaryDecodesNulls() throws {
    let payload = Data(#"{"account_id":"00000000-0000-0000-0000-000000002343","name":"合成借款","institution":null,"last_four":null,"credit_limit_minor":null,"statement_day":null,"due_day":null,"cycle_mode":"on_demand","current_debt_minor":12345,"available_credit_minor":null,"over_limit_minor":null,"opening_configuration_required":false,"current_cycle":null,"next_due_cycle":null,"has_overdue_cycle":false,"active_installment_count":0,"future_scheduled_gross_minor":0,"next_installment":null}"#.utf8)
    let summary = try JSONDecoder().decode(CreditAccountSummaryDTO.self, from: payload)
    #expect(summary.cycleMode == .onDemand)
    #expect(summary.creditLimitMinor == nil)
    #expect(summary.availableCreditMinor == nil)
    #expect(summary.currentCycle == nil)
    #expect(summary.currentDebtMinor == 12_345)
  }

  private func account(kind: AccountKind) -> AccountDTO {
    let now = Date(timeIntervalSince1970: 0)
    return AccountDTO(
      id: UUID(), name: "账户", kind: kind, institution: nil, lastFour: nil, openingBalanceMinor: 0,
      currentBalanceMinor: 0, openingBalanceAsOfDate: nil, openingDueDate: nil,
      creditLimitMinor: kind == .credit ? 100_000 : nil, statementDay: kind == .credit ? 10 : nil,
      dueDay: kind == .credit ? 22 : nil, sortOrder: 0, archivedAt: nil, usageCount: 0, version: 1,
      createdAt: now, updatedAt: now)
  }
  private func category(direction: CategoryDirection) throws -> CategoryDTO {
    let json = Data(
      #"""
      {"id":"\#(UUID().uuidString)","name":"分类","direction":"\#(direction.rawValue)","parent_id":null,"icon":"tag","color_hex":"#C0784A","aliases":[],"examples":[],"sort_order":0,"archived_at":null,"usage_count":0,"version":1,"children":[],"created_at":"2026-07-16T00:00:00Z","updated_at":"2026-07-16T00:00:00Z"}
      """#.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(CategoryDTO.self, from: json)
  }
}
