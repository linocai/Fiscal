import Foundation
import Testing

@testable import FiscalKit

@Suite("FiscalKit P17 credit cash flow")
struct FiscalKitP17Tests {
  @Test("Credit accounts decode and encode an explicit natural-month mode")
  func creditCycleModeContract() throws {
    let data = Data(#"{"id":"00000000-0000-0000-0000-000000017001","name":"花呗","kind":"credit","institution":null,"last_four":null,"opening_balance_minor":0,"current_balance_minor":-90000,"opening_balance_as_of_date":null,"opening_due_date":null,"credit_limit_minor":1000000,"statement_day":1,"due_day":8,"cycle_mode":"previous_calendar_month","sort_order":0,"archived_at":null,"usage_count":1,"version":2,"created_at":"2026-07-18T00:00:00Z","updated_at":"2026-07-18T00:00:00Z"}"#.utf8)
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let account = try decoder.decode(AccountDTO.self, from: data)
    #expect(account.cycleMode == .previousCalendarMonth)

    let draft = AccountDraft(account: account)
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
    #expect(object["cycle_mode"] as? String == "previous_calendar_month")
  }

  @Test("Atomic installment purchase defaults to three periods and nests the purchase")
  func atomicPurchasePayload() throws {
    var purchase = TransactionDraft()
    purchase.kind = .creditPurchase
    purchase.amountMinor = 90_000
    purchase.title = "淘宝分期商品"
    purchase.accountID = UUID(uuidString: "00000000-0000-0000-0000-000000017001")
    purchase.categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000017002")
    let request = InstallmentPurchaseCreateRequest(purchase: purchase)
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let object = try #require(
      JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any])
    let nested = try #require(object["purchase"] as? [String: Any])
    #expect(object["installment_count"] as? Int == 3)
    #expect(object["total_fee_minor"] as? Int == 0)
    #expect(nested["kind"] as? String == "credit_purchase")
    #expect(nested["amount_minor"] as? Int == 90_000)
    #expect(object["purchase_transaction_id"] == nil)
  }

  @Test("Schedule change request binds optimistic version and new rule")
  func scheduleChangePayload() throws {
    let request = CreditScheduleChangeRequest(
      expectedVersion: 7, cycleMode: .previousCalendarMonth, statementDay: 1, dueDay: 8)
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    #expect(object["expected_version"] as? Int == 7)
    #expect(object["cycle_mode"] as? String == "previous_calendar_month")
    #expect(object["statement_day"] as? Int == 1)
    #expect(object["due_day"] as? Int == 8)
  }

  @Test("Credit cash flow carries separately repayable cycle parts")
  func groupedCreditProjection() throws {
    let data = Data(#"{"id":"credit_cycles:00000000-0000-0000-0000-000000017001:2026-08-08","manual_item_id":null,"system_kind":"credit_cycle","system_reference_id":"00000000-0000-0000-0000-000000017011","series_id":null,"title":"工商3576 账单应还","note":null,"direction":"outflow","planned_amount_minor":194472,"expected_date":"2026-08-08","account_id":"00000000-0000-0000-0000-000000017001","destination_account_id":null,"category_id":null,"status":"confirmed","source":"system","version":1,"linked_transaction_id":null,"actual_amount_minor":null,"actual_date":null,"is_overdue":false,"actions":["confirm_repayment"],"credit_cycle_parts":[{"cycle_id":"00000000-0000-0000-0000-000000017011","remaining_minor":179767,"period_start":"2026-05-15","period_end":"2026-05-15","statement_date":"2026-05-15","due_date":"2026-08-08"},{"cycle_id":"00000000-0000-0000-0000-000000017012","remaining_minor":14705,"period_start":"2026-06-26","period_end":"2026-07-25","statement_date":"2026-07-25","due_date":"2026-08-08"}],"created_at":null,"updated_at":null}"#.utf8)
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let item = try decoder.decode(FutureCashFlowItem.self, from: data)
    #expect(item.creditCycleParts.count == 2)
    #expect(item.creditCycleParts.map(\.remainingMinor).reduce(0, +) == item.plannedAmountMinor)
  }
}
