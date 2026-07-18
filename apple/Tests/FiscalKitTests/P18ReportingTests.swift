import Foundation
import Testing

@testable import FiscalKit

@Suite("FiscalKit P18 reporting")
struct FiscalKitP18ReportingTests {
  @Test("Overview decodes grouped credit due events")
  func groupedCreditDueContract() throws {
    let data = Data(#"{"meta":{"timezone":"Asia/Shanghai","currency":"CNY","date_from":"2026-07-01","date_to":"2026-07-31","as_of":"2026-07-18T00:00:00Z"},"account_value_minor":120000,"current_credit_debt_minor":50000,"reimbursement_outstanding_minor":0,"spending":{"gross_consumption_minor":30000,"merchant_refund_minor":0,"net_consumption_minor":30000,"expected_reimbursement_minor":0,"received_reimbursement_minor":0,"personal_expected_minor":30000,"personal_realized_minor":30000},"cash_flow":{"inflow_minor":0,"outflow_minor":0,"net_minor":0},"uncategorized_count":0,"uncategorized_amount_minor":0,"recent_transactions":[],"forecast":{"today":"2026-07-18","date_to":"2026-08-16","exact_due_outflow_minor":0,"expected_receipt_inflow_minor":0,"undated_expected_receipt_minor":0,"events":[]},"credit_due_events":[{"account_id":"00000000-0000-0000-0000-000000018001","account_name":"信用卡","due_date":"2026-07-22","remaining_minor":50000,"cycle_ids":["00000000-0000-0000-0000-000000018011","00000000-0000-0000-0000-000000018012"]}]}"#.utf8)
    let report = try JSONDecoder().decode(OverviewReport.self, from: data)
    #expect(report.accountValueMinor == 120_000)
    #expect(report.creditDueEvents.count == 1)
    #expect(report.creditDueEvents[0].remainingMinor == 50_000)
    #expect(report.creditDueEvents[0].cycleIDs.count == 2)
  }
}
