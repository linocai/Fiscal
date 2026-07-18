import Foundation

public struct ReportMeta: Codable, Sendable, Equatable {
  public let timezone: String
  public let currency: String
  public let dateFrom: String
  public let dateTo: String
  public let asOf: String
  enum CodingKeys: String, CodingKey {
    case timezone, currency
    case dateFrom = "date_from"
    case dateTo = "date_to"
    case asOf = "as_of"
  }
}
public typealias ReportScope = ReportMeta

public struct SpendingMetrics: Codable, Sendable, Equatable {
  public let grossConsumptionMinor: Int64
  public let merchantRefundMinor: Int64
  public let netConsumptionMinor: Int64
  public let expectedReimbursementMinor: Int64
  public let receivedReimbursementMinor: Int64
  public let personalExpectedMinor: Int64
  public let personalRealizedMinor: Int64
  enum CodingKeys: String, CodingKey {
    case grossConsumptionMinor = "gross_consumption_minor"
    case merchantRefundMinor = "merchant_refund_minor"
    case netConsumptionMinor = "net_consumption_minor"
    case expectedReimbursementMinor = "expected_reimbursement_minor"
    case receivedReimbursementMinor = "received_reimbursement_minor"
    case personalExpectedMinor = "personal_expected_minor"
    case personalRealizedMinor = "personal_realized_minor"
  }
}

public struct SpendingBucket: Codable, Sendable, Equatable, Identifiable {
  public var id: String { categoryID?.uuidString ?? "uncategorized" }
  public let grossConsumptionMinor: Int64
  public let merchantRefundMinor: Int64
  public let netConsumptionMinor: Int64
  public let expectedReimbursementMinor: Int64
  public let receivedReimbursementMinor: Int64
  public let personalExpectedMinor: Int64
  public let personalRealizedMinor: Int64
  public let categoryID: UUID?
  public let rootCategoryID: UUID?
  public let name: String
  public let icon: String?
  public let colorHex: String?
  public let transactionCount: Int
  enum CodingKeys: String, CodingKey {
    case grossConsumptionMinor = "gross_consumption_minor"
    case merchantRefundMinor = "merchant_refund_minor"
    case netConsumptionMinor = "net_consumption_minor"
    case expectedReimbursementMinor = "expected_reimbursement_minor"
    case receivedReimbursementMinor = "received_reimbursement_minor"
    case personalExpectedMinor = "personal_expected_minor"
    case personalRealizedMinor = "personal_realized_minor"
    case categoryID = "category_id"
    case rootCategoryID = "root_category_id"
    case name, icon
    case colorHex = "color_hex"
    case transactionCount = "transaction_count"
  }
  public var metrics: SpendingMetrics {
    .init(
      grossConsumptionMinor: grossConsumptionMinor, merchantRefundMinor: merchantRefundMinor,
      netConsumptionMinor: netConsumptionMinor,
      expectedReimbursementMinor: expectedReimbursementMinor,
      receivedReimbursementMinor: receivedReimbursementMinor,
      personalExpectedMinor: personalExpectedMinor, personalRealizedMinor: personalRealizedMinor)
  }
}

public struct SpendingCategoryRoot: Codable, Sendable, Equatable, Identifiable {
  public var id: String { categoryID?.uuidString ?? "uncategorized" }
  public let grossConsumptionMinor: Int64
  public let merchantRefundMinor: Int64
  public let netConsumptionMinor: Int64
  public let expectedReimbursementMinor: Int64
  public let receivedReimbursementMinor: Int64
  public let personalExpectedMinor: Int64
  public let personalRealizedMinor: Int64
  public let categoryID: UUID?
  public let rootCategoryID: UUID?
  public let name: String
  public let icon: String?
  public let colorHex: String?
  public let transactionCount: Int
  public let direct: SpendingBucket
  public let children: [SpendingBucket]
  enum CodingKeys: String, CodingKey {
    case grossConsumptionMinor = "gross_consumption_minor"
    case merchantRefundMinor = "merchant_refund_minor"
    case netConsumptionMinor = "net_consumption_minor"
    case expectedReimbursementMinor = "expected_reimbursement_minor"
    case receivedReimbursementMinor = "received_reimbursement_minor"
    case personalExpectedMinor = "personal_expected_minor"
    case personalRealizedMinor = "personal_realized_minor"
    case categoryID = "category_id"
    case rootCategoryID = "root_category_id"
    case name, icon, direct, children
    case colorHex = "color_hex"
    case transactionCount = "transaction_count"
  }
  public var rollup: SpendingMetrics {
    .init(
      grossConsumptionMinor: grossConsumptionMinor, merchantRefundMinor: merchantRefundMinor,
      netConsumptionMinor: netConsumptionMinor,
      expectedReimbursementMinor: expectedReimbursementMinor,
      receivedReimbursementMinor: receivedReimbursementMinor,
      personalExpectedMinor: personalExpectedMinor, personalRealizedMinor: personalRealizedMinor)
  }
}
public typealias SpendingCategoryRow = SpendingCategoryRoot

public struct SpendingTrendPoint: Codable, Sendable, Equatable, Identifiable {
  public var id: String { date }
  public let date: String
  public let grossConsumptionMinor: Int64
  public let merchantRefundMinor: Int64
  public let netConsumptionMinor: Int64
  public let expectedReimbursementMinor: Int64
  public let receivedReimbursementMinor: Int64
  public let personalExpectedMinor: Int64
  public let personalRealizedMinor: Int64
  enum CodingKeys: String, CodingKey {
    case date
    case grossConsumptionMinor = "gross_consumption_minor"
    case merchantRefundMinor = "merchant_refund_minor"
    case netConsumptionMinor = "net_consumption_minor"
    case expectedReimbursementMinor = "expected_reimbursement_minor"
    case receivedReimbursementMinor = "received_reimbursement_minor"
    case personalExpectedMinor = "personal_expected_minor"
    case personalRealizedMinor = "personal_realized_minor"
  }
  public var metrics: SpendingMetrics {
    .init(
      grossConsumptionMinor: grossConsumptionMinor, merchantRefundMinor: merchantRefundMinor,
      netConsumptionMinor: netConsumptionMinor,
      expectedReimbursementMinor: expectedReimbursementMinor,
      receivedReimbursementMinor: receivedReimbursementMinor,
      personalExpectedMinor: personalExpectedMinor, personalRealizedMinor: personalRealizedMinor)
  }
  public var dateFrom: String { date }
}
public typealias SpendingTrendBucket = SpendingTrendPoint

public struct ReportCoverage: Sendable, Equatable {
  public let classifiedMinor: Int64
  public let uncategorizedMinor: Int64
  public let uncategorizedCount: Int
  public let isComplete: Bool
}

public struct SpendingReport: Codable, Sendable, Equatable {
  public let grossConsumptionMinor: Int64
  public let merchantRefundMinor: Int64
  public let netConsumptionMinor: Int64
  public let expectedReimbursementMinor: Int64
  public let receivedReimbursementMinor: Int64
  public let personalExpectedMinor: Int64
  public let personalRealizedMinor: Int64
  public let meta: ReportMeta
  public let uncategorized: SpendingBucket
  public let categories: [SpendingCategoryRoot]
  public let trend: [SpendingTrendPoint]
  enum CodingKeys: String, CodingKey {
    case grossConsumptionMinor = "gross_consumption_minor"
    case merchantRefundMinor = "merchant_refund_minor"
    case netConsumptionMinor = "net_consumption_minor"
    case expectedReimbursementMinor = "expected_reimbursement_minor"
    case receivedReimbursementMinor = "received_reimbursement_minor"
    case personalExpectedMinor = "personal_expected_minor"
    case personalRealizedMinor = "personal_realized_minor"
    case meta, uncategorized, categories, trend
  }
  public var scope: ReportMeta { meta }
  public var totals: SpendingMetrics {
    .init(
      grossConsumptionMinor: grossConsumptionMinor, merchantRefundMinor: merchantRefundMinor,
      netConsumptionMinor: netConsumptionMinor,
      expectedReimbursementMinor: expectedReimbursementMinor,
      receivedReimbursementMinor: receivedReimbursementMinor,
      personalExpectedMinor: personalExpectedMinor, personalRealizedMinor: personalRealizedMinor)
  }
  public var coverage: ReportCoverage {
    .init(
      classifiedMinor: max(0, netConsumptionMinor - uncategorized.netConsumptionMinor),
      uncategorizedMinor: uncategorized.netConsumptionMinor,
      uncategorizedCount: uncategorized.transactionCount,
      isComplete: uncategorized.transactionCount == 0)
  }
}

public struct CashFlowMetrics: Sendable, Equatable {
  public let inflowMinor: Int64
  public let outflowMinor: Int64
  public let netMinor: Int64
  public let internalTransferInMinor: Int64
  public let internalTransferOutMinor: Int64
}
public struct CashFlowTrendPoint: Codable, Sendable, Equatable, Identifiable {
  public var id: String { date }
  public let date: String
  public let inflowMinor: Int64
  public let outflowMinor: Int64
  public let netMinor: Int64
  enum CodingKeys: String, CodingKey {
    case date
    case inflowMinor = "inflow_minor"
    case outflowMinor = "outflow_minor"
    case netMinor = "net_minor"
  }
  public var metrics: CashFlowMetrics { .init(inflowMinor: inflowMinor, outflowMinor: outflowMinor, netMinor: netMinor, internalTransferInMinor: 0, internalTransferOutMinor: 0) }
}
public typealias CashFlowTrendBucket = CashFlowTrendPoint

public struct CashFlowAccountRow: Codable, Sendable, Equatable, Identifiable {
  public var id: UUID { accountID }
  public let accountID: UUID
  public let accountName: String
  public let accountKind: String
  public let inflowMinor: Int64
  public let outflowMinor: Int64
  public let netMinor: Int64
  public let internalTransferInflowMinor: Int64
  public let internalTransferOutflowMinor: Int64
  enum CodingKeys: String, CodingKey {
    case accountID = "account_id"
    case accountName = "account_name"
    case accountKind = "account_kind"
    case inflowMinor = "inflow_minor"
    case outflowMinor = "outflow_minor"
    case netMinor = "net_minor"
    case internalTransferInflowMinor = "internal_transfer_inflow_minor"
    case internalTransferOutflowMinor = "internal_transfer_outflow_minor"
  }
  public var name: String { accountName }
  public var kind: String { accountKind }
  public var metrics: CashFlowMetrics { .init(inflowMinor: inflowMinor, outflowMinor: outflowMinor, netMinor: netMinor, internalTransferInMinor: internalTransferInflowMinor, internalTransferOutMinor: internalTransferOutflowMinor) }
}

public enum ForecastDirection: String, Codable, Sendable { case inflow, outflow }
public struct ForecastEvent: Codable, Sendable, Equatable, Identifiable {
  public var id: UUID { sourceID }
  public let sourceID: UUID
  public let date: String
  public let direction: ForecastDirection
  public let amountMinor: Int64
  public let basis: String
  public let certainty: String
  public let title: String
  public let accountID: UUID?
  public let cycleID: UUID?
  public let claimID: UUID?
  public let partyID: UUID?
  enum CodingKeys: String, CodingKey {
    case sourceID = "source_id"
    case date, direction, basis, certainty, title
    case amountMinor = "amount_minor"
    case accountID = "account_id"
    case cycleID = "cycle_id"
    case claimID = "claim_id"
    case partyID = "party_id"
  }
}
public struct ForecastSummary: Codable, Sendable, Equatable {
  public let today: String
  public let dateTo: String
  public let exactDueOutflowMinor: Int64
  public let expectedReceiptInflowMinor: Int64
  public let undatedExpectedReceiptMinor: Int64
  public let events: [ForecastEvent]
  enum CodingKeys: String, CodingKey {
    case today
    case dateTo = "date_to"
    case exactDueOutflowMinor = "exact_due_outflow_minor"
    case expectedReceiptInflowMinor = "expected_receipt_inflow_minor"
    case undatedExpectedReceiptMinor = "undated_expected_receipt_minor"
    case events
  }
}
public typealias CashFlowForecast = ForecastSummary

public struct CashFlowReport: Codable, Sendable, Equatable {
  public let inflowMinor: Int64
  public let outflowMinor: Int64
  public let netMinor: Int64
  public let meta: ReportMeta
  public let internalTransferInflowMinor: Int64
  public let internalTransferOutflowMinor: Int64
  public let accounts: [CashFlowAccountRow]
  public let trend: [CashFlowTrendPoint]
  public let forecast: ForecastSummary
  enum CodingKeys: String, CodingKey {
    case inflowMinor = "inflow_minor"
    case outflowMinor = "outflow_minor"
    case netMinor = "net_minor"
    case meta
    case internalTransferInflowMinor = "internal_transfer_inflow_minor"
    case internalTransferOutflowMinor = "internal_transfer_outflow_minor"
    case accounts, trend, forecast
  }
  public var scope: ReportMeta { meta }
  public var actual: CashFlowMetrics { .init(inflowMinor: inflowMinor, outflowMinor: outflowMinor, netMinor: netMinor, internalTransferInMinor: internalTransferInflowMinor, internalTransferOutMinor: internalTransferOutflowMinor) }
}

public struct DebtCycleRow: Codable, Sendable, Equatable, Identifiable {
  public var id: UUID { cycleID }
  public let cycleID: UUID
  public let accountID: UUID
  public let accountName: String
  public let periodStart: String
  public let periodEnd: String
  public let statementDate: String
  public let dueDate: String
  public let amountDueMinor: Int64
  public let repaidMinor: Int64
  public let remainingMinor: Int64
  public let status: String
  public let isOverdue: Bool
  enum CodingKeys: String, CodingKey {
    case cycleID = "cycle_id"
    case accountID = "account_id"
    case accountName = "account_name"
    case periodStart = "period_start"
    case periodEnd = "period_end"
    case statementDate = "statement_date"
    case dueDate = "due_date"
    case amountDueMinor = "amount_due_minor"
    case repaidMinor = "repaid_minor"
    case remainingMinor = "remaining_minor"
    case status
    case isOverdue = "is_overdue"
  }
  public var overdue: Bool { isOverdue }
}
public struct DebtAccountRow: Codable, Sendable, Equatable, Identifiable {
  public var id: UUID { accountID }
  public let accountID: UUID
  public let accountName: String
  public let institution: String?
  public let lastFour: String?
  public let creditLimitMinor: Int64
  public let currentDebtMinor: Int64
  public let availableCreditMinor: Int64
  public let overLimitMinor: Int64
  public let overdueMinor: Int64
  public let openingConfigurationRequired: Bool
  public let hasOverdueCycle: Bool
  public let nextDueCycle: DebtCycleRow?
  enum CodingKeys: String, CodingKey {
    case accountID = "account_id"
    case accountName = "account_name"
    case institution
    case lastFour = "last_four"
    case creditLimitMinor = "credit_limit_minor"
    case currentDebtMinor = "current_debt_minor"
    case availableCreditMinor = "available_credit_minor"
    case overLimitMinor = "over_limit_minor"
    case overdueMinor = "overdue_minor"
    case openingConfigurationRequired = "opening_configuration_required"
    case hasOverdueCycle = "has_overdue_cycle"
    case nextDueCycle = "next_due_cycle"
  }
  public var name: String { accountName }
  public var hasOverdue: Bool { hasOverdueCycle }
  public var cycles: [DebtCycleRow] { nextDueCycle.map { [$0] } ?? [] }
}
public struct DebtInstallmentGroup: Codable, Sendable, Equatable, Identifiable {
  public var id: String { month }
  public let month: String
  public let principalScheduledGrossMinor: Int64
  public let feeScheduledGrossMinor: Int64
  public let totalScheduledGrossMinor: Int64
  public let periodCount: Int
  enum CodingKeys: String, CodingKey {
    case month
    case principalScheduledGrossMinor = "principal_scheduled_gross_minor"
    case feeScheduledGrossMinor = "fee_scheduled_gross_minor"
    case totalScheduledGrossMinor = "total_scheduled_gross_minor"
    case periodCount = "period_count"
  }
  public var includedInCurrentDebt: Bool { true }
}
public struct DebtReport: Codable, Sendable, Equatable {
  public let timezone: String
  public let currency: String
  public let asOf: String
  public let currentCreditDebtMinor: Int64
  public let totalAvailableCreditMinor: Int64
  public let overdueMinor: Int64
  public let accounts: [DebtAccountRow]
  public let cycles: [DebtCycleRow]
  public let installments: [DebtInstallmentGroup]
  enum CodingKeys: String, CodingKey {
    case timezone, currency
    case asOf = "as_of"
    case currentCreditDebtMinor = "current_credit_debt_minor"
    case totalAvailableCreditMinor = "total_available_credit_minor"
    case overdueMinor = "overdue_minor"
    case accounts, cycles, installments
  }
  public var installmentGroups: [DebtInstallmentGroup] { installments }
}

public struct OverviewReport: Codable, Sendable, Equatable {
  public let meta: ReportMeta
  public let accountValueMinor: Int64
  public let currentCreditDebtMinor: Int64
  public let reimbursementOutstandingMinor: Int64
  public let spending: SpendingMetrics
  public let cashFlow: OverviewCashFlow
  public let uncategorizedCount: Int
  public let uncategorizedAmountMinor: Int64
  public let recentTransactions: [TransactionDTO]
  public let forecast: ForecastSummary
  public let creditDueEvents: [OverviewCreditDueEvent]
  enum CodingKeys: String, CodingKey {
    case meta
    case accountValueMinor = "account_value_minor"
    case currentCreditDebtMinor = "current_credit_debt_minor"
    case reimbursementOutstandingMinor = "reimbursement_outstanding_minor"
    case spending
    case cashFlow = "cash_flow"
    case uncategorizedCount = "uncategorized_count"
    case uncategorizedAmountMinor = "uncategorized_amount_minor"
    case recentTransactions = "recent_transactions"
    case forecast
    case creditDueEvents = "credit_due_events"
  }
  public var scope: ReportMeta { meta }
  public var coverage: ReportCoverage { .init(classifiedMinor: max(0, spending.netConsumptionMinor - uncategorizedAmountMinor), uncategorizedMinor: uncategorizedAmountMinor, uncategorizedCount: uncategorizedCount, isComplete: uncategorizedCount == 0) }
  public var forecastEvents: [ForecastEvent] { forecast.events }
}
public struct OverviewCreditDueEvent: Codable, Sendable, Equatable, Identifiable {
  public var id: String { "\(accountID.uuidString):\(dueDate)" }
  public let accountID: UUID
  public let accountName: String
  public let dueDate: String
  public let remainingMinor: Int64
  public let cycleIDs: [UUID]
  enum CodingKeys: String, CodingKey {
    case accountID = "account_id"
    case accountName = "account_name"
    case dueDate = "due_date"
    case remainingMinor = "remaining_minor"
    case cycleIDs = "cycle_ids"
  }
}
public struct OverviewCashFlow: Codable, Sendable, Equatable {
  public let inflowMinor: Int64
  public let outflowMinor: Int64
  public let netMinor: Int64
  enum CodingKeys: String, CodingKey { case inflowMinor = "inflow_minor"; case outflowMinor = "outflow_minor"; case netMinor = "net_minor" }
}

public enum ReportLens: String, Codable, Sendable, CaseIterable, Hashable { case spending; case cashFlow = "cash_flow"; case debt }
public struct ReportLineItem: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let transactionID: UUID
  public let lens: ReportLens
  public let occurredAt: Date
  public let businessDate: String
  public let title: String
  public let kind: TransactionKind
  public let signedAmountMinor: Int64
  public let accountID: UUID?
  public let accountName: String?
  public let categoryID: UUID?
  public let categoryName: String?
  public let rootCategoryID: UUID?
  public let rootCategoryName: String?
  public let internalTransfer: Bool
  public let grossConsumptionMinor: Int64
  public let merchantRefundMinor: Int64
  public let expectedReimbursementMinor: Int64
  public let receivedReimbursementMinor: Int64
  enum CodingKeys: String, CodingKey {
    case id, lens, title, kind
    case transactionID = "transaction_id"
    case occurredAt = "occurred_at"
    case businessDate = "business_date"
    case signedAmountMinor = "signed_amount_minor"
    case accountID = "account_id"
    case accountName = "account_name"
    case categoryID = "category_id"
    case categoryName = "category_name"
    case rootCategoryID = "root_category_id"
    case rootCategoryName = "root_category_name"
    case internalTransfer = "internal_transfer"
    case grossConsumptionMinor = "gross_consumption_minor"
    case merchantRefundMinor = "merchant_refund_minor"
    case expectedReimbursementMinor = "expected_reimbursement_minor"
    case receivedReimbursementMinor = "received_reimbursement_minor"
  }
  public var sourceID: UUID { id }
  public var amountMinor: Int64 { signedAmountMinor }
  public var direction: String { signedAmountMinor >= 0 ? "inflow" : "outflow" }
}
public struct ReportDrillDownPage: Codable, Sendable, Equatable {
  public let items: [ReportLineItem]
  public let nextCursor: String?
  enum CodingKeys: String, CodingKey { case items; case nextCursor = "next_cursor" }
}
