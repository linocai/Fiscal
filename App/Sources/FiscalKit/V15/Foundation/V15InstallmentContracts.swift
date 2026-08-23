import Foundation

// MARK: - F3-B2 installment read facts

/// The five backend lifecycle values are actionable. An additive future value
/// stays readable, but deliberately cannot enter a mutation workflow.
public enum V15InstallmentPlanStatus: Sendable, Equatable, Hashable, Codable {
    case active, completed, settledEarly, partiallyCancelled, cancelled
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "active": self = .active
        case "completed": self = .completed
        case "settled_early": self = .settledEarly
        case "partially_cancelled": self = .partiallyCancelled
        case "cancelled": self = .cancelled
        default: self = .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var rawValue: String {
        switch self {
        case .active: "active"
        case .completed: "completed"
        case .settledEarly: "settled_early"
        case .partiallyCancelled: "partially_cancelled"
        case .cancelled: "cancelled"
        case .unknown(let value): value
        }
    }

    public var displayName: String {
        switch self {
        case .active: "进行中"
        case .completed: "已完成"
        case .settledEarly: "已提前结清"
        case .partiallyCancelled: "部分取消"
        case .cancelled: "已取消"
        case .unknown: "暂时无法识别"
        }
    }

    public var isActionable: Bool { if case .unknown = self { false } else { true } }
}

public struct V15InstallmentPeriodPreview: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(sequence)-\(scheduledStatementDate)" }
    public let sequence: Int
    public let scheduledCycleID: UUID?
    public let effectiveCycleID: UUID?
    public let scheduledStatementDate: String
    public let effectiveStatementDate: String
    public let dueDate: String
    public let principalMinor: V15MinorUnits
    public let feeMinor: V15MinorUnits
    public let amountDueMinor: V15MinorUnits
    public let locked: Bool
    public let status: V15InstallmentPeriodStatus
    enum CodingKeys: String, CodingKey {
        case sequence, locked, status
        case scheduledCycleID = "scheduled_cycle_id", effectiveCycleID = "effective_cycle_id"
        case scheduledStatementDate = "scheduled_statement_date", effectiveStatementDate = "effective_statement_date", dueDate = "due_date"
        case principalMinor = "principal_minor", feeMinor = "fee_minor", amountDueMinor = "amount_due_minor"
    }
}

public typealias V15InstallmentPeriod = V15CreditCycleInstallmentPeriod

public struct V15InstallmentPlan: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let purchaseTransactionID: UUID
    public let creditAccountID: UUID
    public let feeTransactionID: UUID?
    public let feeCategoryID: UUID?
    public let feeOccurredAt: Date?
    public let title: String
    public let status: V15InstallmentPlanStatus
    public let principalMinor: V15MinorUnits
    public let feeMinor: V15MinorUnits
    public let totalFinancedMinor: V15MinorUnits
    public let installmentCount: Int
    public let startStatementDate: String
    public let lockedCount: Int
    public let futureCount: Int
    public let cancelledCount: Int
    public let cycleSettledCount: Int
    public let scheduledGrossMinor: V15MinorUnits
    public let futureScheduledGrossMinor: V15MinorUnits
    public let nextPeriod: V15InstallmentPeriod?
    public let periods: [V15InstallmentPeriod]
    public let version: Int
    public let createdAt: Date
    public let updatedAt: Date
    public var isCompleted: Bool { status == .completed }
    public var isDisplayOnly: Bool { !status.isActionable }
    enum CodingKeys: String, CodingKey {
        case id, title, status, periods, version
        case purchaseTransactionID = "purchase_transaction_id", creditAccountID = "credit_account_id"
        case feeTransactionID = "fee_transaction_id", feeCategoryID = "fee_category_id", feeOccurredAt = "fee_occurred_at"
        case principalMinor = "principal_minor", feeMinor = "fee_minor", totalFinancedMinor = "total_financed_minor"
        case installmentCount = "installment_count", startStatementDate = "start_statement_date"
        case lockedCount = "locked_count", futureCount = "future_count", cancelledCount = "cancelled_count", cycleSettledCount = "cycle_settled_count"
        case scheduledGrossMinor = "scheduled_gross_minor", futureScheduledGrossMinor = "future_scheduled_gross_minor", nextPeriod = "next_period"
        case createdAt = "created_at", updatedAt = "updated_at"
    }
}

public struct V15InstallmentPlanPage: Codable, Sendable, Equatable {
    public let items: [V15InstallmentPlan]
    public let nextCursor: String?
    enum CodingKeys: String, CodingKey { case items; case nextCursor = "next_cursor" }
}

public struct V15InstallmentCycleOption: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(statementDate)-\(cycleID?.uuidString ?? "future")" }
    public let cycleID: UUID?
    public let statementDate: String
    public let dueDate: String
    public let existing: Bool
    public let eligible: Bool
    enum CodingKeys: String, CodingKey { case cycleID = "cycle_id", statementDate = "statement_date", dueDate = "due_date", existing, eligible }
}

public struct V15InstallmentEligibility: Codable, Sendable, Equatable {
    public let purchaseTransactionID: UUID
    public let eligible: Bool
    public let reasonCode: String?
    public let creditAccountID: UUID
    public let principalMinor: V15MinorUnits
    public let naturalStatementDate: String
    public let startOptions: [V15InstallmentCycleOption]
    enum CodingKeys: String, CodingKey { case purchaseTransactionID = "purchase_transaction_id", eligible, reasonCode = "reason_code", creditAccountID = "credit_account_id", principalMinor = "principal_minor", naturalStatementDate = "natural_statement_date", startOptions = "start_options" }
}

public struct V15InstallmentTeaser: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID { planID }
    public let planID: UUID
    public let title: String
    public let status: V15InstallmentPlanStatus
    public let installmentCount: Int
    public let futureCount: Int
    public let futureScheduledGrossMinor: V15MinorUnits
    public let nextPeriod: V15InstallmentPeriod?
    enum CodingKeys: String, CodingKey { case planID = "plan_id", title, status, installmentCount = "installment_count", futureCount = "future_count", futureScheduledGrossMinor = "future_scheduled_gross_minor", nextPeriod = "next_period" }
}

public struct V15InstallmentLiabilityGroup: Codable, Sendable, Equatable, Identifiable {
    public var id: String { month }
    public let month: String
    public let principalScheduledGrossMinor: V15MinorUnits
    public let feeScheduledGrossMinor: V15MinorUnits
    public let totalScheduledGrossMinor: V15MinorUnits
    public let periodCount: Int
    public let plans: [V15InstallmentTeaser]
    enum CodingKeys: String, CodingKey { case month, plans; case principalScheduledGrossMinor = "principal_scheduled_gross_minor", feeScheduledGrossMinor = "fee_scheduled_gross_minor", totalScheduledGrossMinor = "total_scheduled_gross_minor", periodCount = "period_count" }
}

public struct V15InstallmentLiabilities: Codable, Sendable, Equatable {
    public let accountID: UUID
    public let totalFutureScheduledGrossMinor: V15MinorUnits
    public let groups: [V15InstallmentLiabilityGroup]
    enum CodingKeys: String, CodingKey { case accountID = "account_id", totalFutureScheduledGrossMinor = "total_future_scheduled_gross_minor", groups }
}

// MARK: - F3-B2 requests and server previews

public struct V15InstallmentCreateRequest: Codable, Sendable, Equatable {
    public let purchaseTransactionID: UUID; public let installmentCount: Int; public let totalFeeMinor: V15MinorUnits
    public let feeCategoryID: UUID?; public let feeOccurredAt: Date?; public let startStatementDate: String
    public init(purchaseTransactionID: UUID, installmentCount: Int, totalFeeMinor: V15MinorUnits, feeCategoryID: UUID? = nil, feeOccurredAt: Date? = nil, startStatementDate: String) { self.purchaseTransactionID = purchaseTransactionID; self.installmentCount = installmentCount; self.totalFeeMinor = totalFeeMinor; self.feeCategoryID = feeCategoryID; self.feeOccurredAt = feeOccurredAt; self.startStatementDate = startStatementDate }
    enum CodingKeys: String, CodingKey { case purchaseTransactionID = "purchase_transaction_id", installmentCount = "installment_count", totalFeeMinor = "total_fee_minor", feeCategoryID = "fee_category_id", feeOccurredAt = "fee_occurred_at", startStatementDate = "start_statement_date" }
}

public struct V15InstallmentPurchaseCreateRequest: Codable, Sendable, Equatable {
    public let purchase: V15TransactionCreateRequest; public let installmentCount: Int; public let totalFeeMinor: V15MinorUnits
    public let feeCategoryID: UUID?; public let feeOccurredAt: Date?; public let startStatementDate: String?
    public init(purchase: V15TransactionCreateRequest, installmentCount: Int = 3, totalFeeMinor: V15MinorUnits = 0, feeCategoryID: UUID? = nil, feeOccurredAt: Date? = nil, startStatementDate: String? = nil) { self.purchase = purchase; self.installmentCount = installmentCount; self.totalFeeMinor = totalFeeMinor; self.feeCategoryID = feeCategoryID; self.feeOccurredAt = feeOccurredAt; self.startStatementDate = startStatementDate }
    enum CodingKeys: String, CodingKey { case purchase, installmentCount = "installment_count", totalFeeMinor = "total_fee_minor", feeCategoryID = "fee_category_id", feeOccurredAt = "fee_occurred_at", startStatementDate = "start_statement_date" }
}

public struct V15InstallmentPurchasePreview: Codable, Sendable, Equatable {
    public let purchaseAmountMinor: V15MinorUnits; public let totalFeeMinor: V15MinorUnits; public let totalFinancedMinor: V15MinorUnits
    public let startStatementDate: String; public let periods: [V15InstallmentPeriodPreview]
    enum CodingKeys: String, CodingKey { case purchaseAmountMinor = "purchase_amount_minor", totalFeeMinor = "total_fee_minor", totalFinancedMinor = "total_financed_minor", startStatementDate = "start_statement_date", periods }
}

public struct V15InstallmentPurchaseCreateResponse: Codable, Sendable, Equatable { public let purchase: V15Transaction; public let plan: V15InstallmentPlan }

public struct V15InstallmentPurchaseReplacement: Codable, Sendable, Equatable {
    public let amountMinor: V15MinorUnits; public let occurredAt: Date; public let title: String; public let note: String?
    public let accountID: UUID; public let categoryID: UUID
    public init(amountMinor: V15MinorUnits, occurredAt: Date, title: String, note: String? = nil, accountID: UUID, categoryID: UUID) { self.amountMinor = amountMinor; self.occurredAt = occurredAt; self.title = title; self.note = note; self.accountID = accountID; self.categoryID = categoryID }
    enum CodingKeys: String, CodingKey { case amountMinor = "amount_minor", occurredAt = "occurred_at", title, note, accountID = "account_id", categoryID = "category_id" }
}

public struct V15InstallmentReplacementRequest: Codable, Sendable, Equatable {
    public let expectedVersion: Int; public let purchase: V15InstallmentPurchaseReplacement; public let installmentCount: Int
    public let totalFeeMinor: V15MinorUnits; public let feeCategoryID: UUID?; public let feeOccurredAt: Date?; public let startStatementDate: String
    public init(expectedVersion: Int, purchase: V15InstallmentPurchaseReplacement, installmentCount: Int, totalFeeMinor: V15MinorUnits, feeCategoryID: UUID? = nil, feeOccurredAt: Date? = nil, startStatementDate: String) { self.expectedVersion = expectedVersion; self.purchase = purchase; self.installmentCount = installmentCount; self.totalFeeMinor = totalFeeMinor; self.feeCategoryID = feeCategoryID; self.feeOccurredAt = feeOccurredAt; self.startStatementDate = startStatementDate }
    enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version", purchase, installmentCount = "installment_count", totalFeeMinor = "total_fee_minor", feeCategoryID = "fee_category_id", feeOccurredAt = "fee_occurred_at", startStatementDate = "start_statement_date" }
}

public struct V15InstallmentPlanPreview: Codable, Sendable, Equatable {
    public let id: UUID?; public let purchaseTransactionID: UUID; public let creditAccountID: UUID; public let feeTransactionID: UUID?; public let feeCategoryID: UUID?; public let feeOccurredAt: Date?
    public let title: String; public let status: V15InstallmentPlanStatus; public let principalMinor: V15MinorUnits; public let feeMinor: V15MinorUnits; public let totalFinancedMinor: V15MinorUnits
    public let installmentCount: Int; public let startStatementDate: String; public let lockedCount: Int; public let futureCount: Int; public let cancelledCount: Int; public let cycleSettledCount: Int
    public let scheduledGrossMinor: V15MinorUnits; public let futureScheduledGrossMinor: V15MinorUnits; public let nextPeriod: V15InstallmentPeriodPreview?; public let periods: [V15InstallmentPeriodPreview]
    enum CodingKeys: String, CodingKey { case id, title, status, periods; case purchaseTransactionID = "purchase_transaction_id", creditAccountID = "credit_account_id", feeTransactionID = "fee_transaction_id", feeCategoryID = "fee_category_id", feeOccurredAt = "fee_occurred_at", principalMinor = "principal_minor", feeMinor = "fee_minor", totalFinancedMinor = "total_financed_minor", installmentCount = "installment_count", startStatementDate = "start_statement_date", lockedCount = "locked_count", futureCount = "future_count", cancelledCount = "cancelled_count", cycleSettledCount = "cycle_settled_count", scheduledGrossMinor = "scheduled_gross_minor", futureScheduledGrossMinor = "future_scheduled_gross_minor", nextPeriod = "next_period" }
}

public struct V15InstallmentAffectedCycle: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(statementDate)-\(cycleID?.uuidString ?? "future")" }
    public let statementDate: String; public let cycleID: UUID?; public let beforeDueMinor: V15MinorUnits; public let afterDueMinor: V15MinorUnits; public let deltaMinor: V15MinorUnits
    enum CodingKeys: String, CodingKey { case statementDate = "statement_date", cycleID = "cycle_id", beforeDueMinor = "before_due_minor", afterDueMinor = "after_due_minor", deltaMinor = "delta_minor" }
}

public struct V15InstallmentWarning: Codable, Sendable, Equatable, Identifiable { public var id: String { "\(code)-\(message)" }; public let code: String; public let message: String }

public struct V15InstallmentPlanChangePreview: Codable, Sendable, Equatable {
    public let currentPlan: V15InstallmentPlan; public let proposedPlan: V15InstallmentPlanPreview; public let lockedPeriods: [V15InstallmentPeriod]
    public let futurePeriods: [V15InstallmentPeriodPreview]; public let affectedCycles: [V15InstallmentAffectedCycle]; public let warnings: [V15InstallmentWarning]
    enum CodingKeys: String, CodingKey { case currentPlan = "current_plan", proposedPlan = "proposed_plan", lockedPeriods = "locked_periods", futurePeriods = "future_periods", affectedCycles = "affected_cycles", warnings }
}

public struct V15InstallmentSettlementPreview: Codable, Sendable, Equatable {
    public let amountMinor: V15MinorUnits; public let currentPlan: V15InstallmentPlan; public let proposedPlan: V15InstallmentPlanPreview; public let affectedCycles: [V15InstallmentAffectedCycle]
    public let paymentBalanceBeforeMinor: V15MinorUnits; public let paymentBalanceAfterMinor: V15MinorUnits; public let debtBeforeMinor: V15MinorUnits; public let debtAfterMinor: V15MinorUnits; public let warnings: [V15InstallmentWarning]
    enum CodingKeys: String, CodingKey { case amountMinor = "amount_minor", currentPlan = "current_plan", proposedPlan = "proposed_plan", affectedCycles = "affected_cycles", paymentBalanceBeforeMinor = "payment_balance_before_minor", paymentBalanceAfterMinor = "payment_balance_after_minor", debtBeforeMinor = "debt_before_minor", debtAfterMinor = "debt_after_minor", warnings }
}

public struct V15InstallmentReverseSettlementPreview: Codable, Sendable, Equatable {
    public let eligible: Bool; public let repaymentTransaction: V15Transaction; public let restoredPeriods: [V15InstallmentPeriodPreview]; public let affectedCycles: [V15InstallmentAffectedCycle]
    public let paymentBalanceBeforeMinor: V15MinorUnits; public let paymentBalanceAfterMinor: V15MinorUnits; public let debtBeforeMinor: V15MinorUnits; public let debtAfterMinor: V15MinorUnits; public let warnings: [V15InstallmentWarning]
    enum CodingKeys: String, CodingKey { case eligible, repaymentTransaction = "repayment_transaction", restoredPeriods = "restored_periods", affectedCycles = "affected_cycles", paymentBalanceBeforeMinor = "payment_balance_before_minor", paymentBalanceAfterMinor = "payment_balance_after_minor", debtBeforeMinor = "debt_before_minor", debtAfterMinor = "debt_after_minor", warnings }
}

public struct V15InstallmentCancellationPreview: Codable, Sendable, Equatable {
    public let principalRefundMinor: V15MinorUnits; public let feeRefundMinor: V15MinorUnits; public let cancelledPeriods: [V15InstallmentPeriodPreview]
    public let currentPlan: V15InstallmentPlan; public let proposedPlan: V15InstallmentPlanPreview; public let affectedCycles: [V15InstallmentAffectedCycle]
    public let debtBeforeMinor: V15MinorUnits; public let debtAfterMinor: V15MinorUnits; public let expenseBeforeMinor: V15MinorUnits; public let expenseAfterMinor: V15MinorUnits; public let warnings: [V15InstallmentWarning]
    enum CodingKeys: String, CodingKey { case principalRefundMinor = "principal_refund_minor", feeRefundMinor = "fee_refund_minor", cancelledPeriods = "cancelled_periods", currentPlan = "current_plan", proposedPlan = "proposed_plan", affectedCycles = "affected_cycles", debtBeforeMinor = "debt_before_minor", debtAfterMinor = "debt_after_minor", expenseBeforeMinor = "expense_before_minor", expenseAfterMinor = "expense_after_minor", warnings }
}

public struct V15InstallmentSettlementResult: Codable, Sendable, Equatable { public let operationID: UUID; public let plan: V15InstallmentPlan; public let repaymentTransaction: V15Transaction; public let replayed: Bool; enum CodingKeys: String, CodingKey { case operationID = "operation_id", plan, repaymentTransaction = "repayment_transaction", replayed } }
public struct V15InstallmentReverseSettlementResult: Codable, Sendable, Equatable { public let operationID: UUID; public let plan: V15InstallmentPlan; public let voidedRepaymentTransaction: V15Transaction; public let replayed: Bool; enum CodingKeys: String, CodingKey { case operationID = "operation_id", plan, voidedRepaymentTransaction = "voided_repayment_transaction", replayed } }
public struct V15InstallmentCancellationResult: Codable, Sendable, Equatable { public let operationID: UUID; public let plan: V15InstallmentPlan; public let refundTransactions: [V15Transaction]; public let replayed: Bool; enum CodingKeys: String, CodingKey { case operationID = "operation_id", plan, refundTransactions = "refund_transactions", replayed } }
