import Foundation

public enum InstallmentPlanStatus: String, Codable, Sendable, CaseIterable {
    case active, completed
    case settledEarly = "settled_early"
    case partiallyCancelled = "partially_cancelled"
    case cancelled

    public var title: String {
        switch self {
        case .active: "进行中"
        case .completed: "已完成"
        case .settledEarly: "已提前结清"
        case .partiallyCancelled: "部分取消"
        case .cancelled: "已取消"
        }
    }
}

public enum InstallmentPeriodStatus: String, Codable, Sendable {
    case scheduled, billed, partial, overdue, cancelled
    case cycleSettled = "cycle_settled"
    case settledEarly = "settled_early"

    public var title: String {
        switch self {
        case .scheduled: "待出账"
        case .billed: "已出账"
        case .partial: "账期部分还款"
        case .cycleSettled: "账期已结清"
        case .overdue: "账期逾期"
        case .cancelled: "已取消"
        case .settledEarly: "已提前结清"
        }
    }
}

public enum InstallmentLedgerRole: String, Codable, Sendable {
    case purchase, fee
    case principalRefund = "principal_refund"
    case feeRefund = "fee_refund"
    case settlementRepayment = "settlement_repayment"
}

public struct InstallmentPeriodDTO: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let planID: UUID
    public let sequence: Int
    public let scheduledCycleID: UUID
    public let effectiveCycleID: UUID
    public let scheduledStatementDate: String
    public let effectiveStatementDate: String
    public let dueDate: String
    public let principalMinor: Int64
    public let feeMinor: Int64
    public let amountDueMinor: Int64
    public let locked: Bool
    public let status: InstallmentPeriodStatus
    public let cycleStatus: CreditCycleStatus
    public let cancelledAt: Date?
    public let settledEarlyAt: Date?
    public let version: Int
    public let createdAt: Date
    public let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, sequence, locked, status, version
        case planID = "plan_id"; case scheduledCycleID = "scheduled_cycle_id"; case effectiveCycleID = "effective_cycle_id"
        case scheduledStatementDate = "scheduled_statement_date"; case effectiveStatementDate = "effective_statement_date"; case dueDate = "due_date"
        case principalMinor = "principal_minor"; case feeMinor = "fee_minor"; case amountDueMinor = "amount_due_minor"; case cycleStatus = "cycle_status"
        case cancelledAt = "cancelled_at"; case settledEarlyAt = "settled_early_at"; case createdAt = "created_at"; case updatedAt = "updated_at"
    }
}

public struct InstallmentPeriodPreview: Codable, Sendable, Equatable, Identifiable {
    public var id: Int { sequence }
    public let sequence: Int
    public let scheduledCycleID: UUID?
    public let effectiveCycleID: UUID?
    public let scheduledStatementDate: String
    public let effectiveStatementDate: String
    public let dueDate: String
    public let principalMinor: Int64
    public let feeMinor: Int64
    public let amountDueMinor: Int64
    public let locked: Bool
    public let status: InstallmentPeriodStatus

    enum CodingKeys: String, CodingKey {
        case sequence, locked, status
        case scheduledCycleID = "scheduled_cycle_id"; case effectiveCycleID = "effective_cycle_id"
        case scheduledStatementDate = "scheduled_statement_date"; case effectiveStatementDate = "effective_statement_date"; case dueDate = "due_date"
        case principalMinor = "principal_minor"; case feeMinor = "fee_minor"; case amountDueMinor = "amount_due_minor"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try values.decode(Int.self, forKey: .sequence)
        scheduledCycleID = try values.decode(Optional<UUID>.self, forKey: .scheduledCycleID); effectiveCycleID = try values.decode(Optional<UUID>.self, forKey: .effectiveCycleID)
        scheduledStatementDate = try values.decode(String.self, forKey: .scheduledStatementDate); effectiveStatementDate = try values.decode(String.self, forKey: .effectiveStatementDate)
        dueDate = try values.decode(String.self, forKey: .dueDate); principalMinor = try values.decode(Int64.self, forKey: .principalMinor); feeMinor = try values.decode(Int64.self, forKey: .feeMinor)
        amountDueMinor = try values.decode(Int64.self, forKey: .amountDueMinor); locked = try values.decode(Bool.self, forKey: .locked); status = try values.decode(InstallmentPeriodStatus.self, forKey: .status)
    }
}

public struct InstallmentPlanDTO: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let purchaseTransactionID: UUID
    public let creditAccountID: UUID
    public let feeTransactionID: UUID?
    public let feeCategoryID: UUID?
    public let feeOccurredAt: Date?
    public let title: String
    public let status: InstallmentPlanStatus
    public let principalMinor: Int64
    public let feeMinor: Int64
    public let totalFinancedMinor: Int64
    public let installmentCount: Int
    public let startStatementDate: String
    public let lockedCount: Int
    public let futureCount: Int
    public let cancelledCount: Int
    public let cycleSettledCount: Int
    public let scheduledGrossMinor: Int64
    public let futureScheduledGrossMinor: Int64
    public let nextPeriod: InstallmentPeriodDTO?
    public let periods: [InstallmentPeriodDTO]
    public let version: Int
    public let createdAt: Date
    public let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title, status, periods, version
        case purchaseTransactionID = "purchase_transaction_id"; case creditAccountID = "credit_account_id"; case feeTransactionID = "fee_transaction_id"; case feeCategoryID = "fee_category_id"; case feeOccurredAt = "fee_occurred_at"
        case principalMinor = "principal_minor"; case feeMinor = "fee_minor"; case totalFinancedMinor = "total_financed_minor"
        case installmentCount = "installment_count"; case startStatementDate = "start_statement_date"; case lockedCount = "locked_count"; case futureCount = "future_count"
        case cancelledCount = "cancelled_count"; case cycleSettledCount = "cycle_settled_count"; case scheduledGrossMinor = "scheduled_gross_minor"
        case futureScheduledGrossMinor = "future_scheduled_gross_minor"; case nextPeriod = "next_period"; case createdAt = "created_at"; case updatedAt = "updated_at"
    }


    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id); purchaseTransactionID = try values.decode(UUID.self, forKey: .purchaseTransactionID); creditAccountID = try values.decode(UUID.self, forKey: .creditAccountID)
        feeTransactionID = try values.decode(Optional<UUID>.self, forKey: .feeTransactionID); feeCategoryID = try values.decode(Optional<UUID>.self, forKey: .feeCategoryID); feeOccurredAt = try values.decode(Optional<Date>.self, forKey: .feeOccurredAt)
        title = try values.decode(String.self, forKey: .title); status = try values.decode(InstallmentPlanStatus.self, forKey: .status)
        principalMinor = try values.decode(Int64.self, forKey: .principalMinor); feeMinor = try values.decode(Int64.self, forKey: .feeMinor); totalFinancedMinor = try values.decode(Int64.self, forKey: .totalFinancedMinor)
        installmentCount = try values.decode(Int.self, forKey: .installmentCount); startStatementDate = try values.decode(String.self, forKey: .startStatementDate)
        lockedCount = try values.decode(Int.self, forKey: .lockedCount); futureCount = try values.decode(Int.self, forKey: .futureCount); cancelledCount = try values.decode(Int.self, forKey: .cancelledCount); cycleSettledCount = try values.decode(Int.self, forKey: .cycleSettledCount)
        scheduledGrossMinor = try values.decode(Int64.self, forKey: .scheduledGrossMinor); futureScheduledGrossMinor = try values.decode(Int64.self, forKey: .futureScheduledGrossMinor)
        nextPeriod = try values.decode(Optional<InstallmentPeriodDTO>.self, forKey: .nextPeriod); periods = try values.decode([InstallmentPeriodDTO].self, forKey: .periods)
        version = try values.decode(Int.self, forKey: .version); createdAt = try values.decode(Date.self, forKey: .createdAt); updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }
}

public struct InstallmentPlanPreview: Codable, Sendable, Equatable {
    public let id: UUID?
    public let purchaseTransactionID: UUID
    public let creditAccountID: UUID
    public let feeTransactionID: UUID?
    public let feeCategoryID: UUID?
    public let feeOccurredAt: Date?
    public let title: String
    public let status: InstallmentPlanStatus
    public let principalMinor: Int64
    public let feeMinor: Int64
    public let totalFinancedMinor: Int64
    public let installmentCount: Int
    public let startStatementDate: String
    public let lockedCount: Int
    public let futureCount: Int
    public let cancelledCount: Int
    public let cycleSettledCount: Int
    public let scheduledGrossMinor: Int64
    public let futureScheduledGrossMinor: Int64
    public let nextPeriod: InstallmentPeriodPreview?
    public let periods: [InstallmentPeriodPreview]

    enum CodingKeys: String, CodingKey {
        case id, title, status, periods
        case purchaseTransactionID = "purchase_transaction_id"; case creditAccountID = "credit_account_id"; case feeTransactionID = "fee_transaction_id"; case feeCategoryID = "fee_category_id"; case feeOccurredAt = "fee_occurred_at"
        case principalMinor = "principal_minor"; case feeMinor = "fee_minor"; case totalFinancedMinor = "total_financed_minor"
        case installmentCount = "installment_count"; case startStatementDate = "start_statement_date"; case lockedCount = "locked_count"; case futureCount = "future_count"
        case cancelledCount = "cancelled_count"; case cycleSettledCount = "cycle_settled_count"; case scheduledGrossMinor = "scheduled_gross_minor"
        case futureScheduledGrossMinor = "future_scheduled_gross_minor"; case nextPeriod = "next_period"
    }


    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Optional<UUID>.self, forKey: .id); purchaseTransactionID = try values.decode(UUID.self, forKey: .purchaseTransactionID); creditAccountID = try values.decode(UUID.self, forKey: .creditAccountID)
        feeTransactionID = try values.decode(Optional<UUID>.self, forKey: .feeTransactionID); feeCategoryID = try values.decode(Optional<UUID>.self, forKey: .feeCategoryID); feeOccurredAt = try values.decode(Optional<Date>.self, forKey: .feeOccurredAt)
        title = try values.decode(String.self, forKey: .title); status = try values.decode(InstallmentPlanStatus.self, forKey: .status)
        principalMinor = try values.decode(Int64.self, forKey: .principalMinor); feeMinor = try values.decode(Int64.self, forKey: .feeMinor); totalFinancedMinor = try values.decode(Int64.self, forKey: .totalFinancedMinor)
        installmentCount = try values.decode(Int.self, forKey: .installmentCount); startStatementDate = try values.decode(String.self, forKey: .startStatementDate)
        lockedCount = try values.decode(Int.self, forKey: .lockedCount); futureCount = try values.decode(Int.self, forKey: .futureCount); cancelledCount = try values.decode(Int.self, forKey: .cancelledCount); cycleSettledCount = try values.decode(Int.self, forKey: .cycleSettledCount)
        scheduledGrossMinor = try values.decode(Int64.self, forKey: .scheduledGrossMinor); futureScheduledGrossMinor = try values.decode(Int64.self, forKey: .futureScheduledGrossMinor)
        nextPeriod = try values.decode(Optional<InstallmentPeriodPreview>.self, forKey: .nextPeriod); periods = try values.decode([InstallmentPeriodPreview].self, forKey: .periods)
    }
}

public struct InstallmentPlanPage: Codable, Sendable, Equatable {
    public let items: [InstallmentPlanDTO]
    public let nextCursor: String?
    enum CodingKeys: String, CodingKey { case items; case nextCursor = "next_cursor" }
}

public struct InstallmentTeaser: Codable, Sendable, Equatable {
    public let planID: UUID
    public let title: String
    public let status: InstallmentPlanStatus
    public let installmentCount: Int
    public let futureCount: Int
    public let futureScheduledGrossMinor: Int64
    public let nextPeriod: InstallmentPeriodDTO?
    enum CodingKeys: String, CodingKey {
        case title, status; case planID = "plan_id"; case installmentCount = "installment_count"; case futureCount = "future_count"
        case futureScheduledGrossMinor = "future_scheduled_gross_minor"; case nextPeriod = "next_period"
    }
}

public struct InstallmentRelation: Codable, Sendable, Equatable {
    public let planID: UUID
    public let role: InstallmentLedgerRole
    public let planTitle: String
    public let planStatus: InstallmentPlanStatus
    enum CodingKeys: String, CodingKey { case role; case planID = "plan_id"; case planTitle = "plan_title"; case planStatus = "plan_status" }
}

public struct InstallmentCycleOption: Codable, Sendable, Equatable, Identifiable {
    public var id: String { statementDate }
    public let cycleID: UUID?
    public let statementDate: String
    public let dueDate: String
    public let existing: Bool
    public let eligible: Bool
    enum CodingKeys: String, CodingKey { case existing, eligible; case cycleID = "cycle_id"; case statementDate = "statement_date"; case dueDate = "due_date" }
    public init(from decoder: Decoder) throws { let values = try decoder.container(keyedBy: CodingKeys.self); cycleID = try values.decode(Optional<UUID>.self, forKey: .cycleID); statementDate = try values.decode(String.self, forKey: .statementDate); dueDate = try values.decode(String.self, forKey: .dueDate); existing = try values.decode(Bool.self, forKey: .existing); eligible = try values.decode(Bool.self, forKey: .eligible) }
}

public struct InstallmentEligibility: Codable, Sendable, Equatable {
    public let purchaseTransactionID: UUID
    public let eligible: Bool
    public let reasonCode: String?
    public let creditAccountID: UUID
    public let principalMinor: Int64
    public let naturalStatementDate: String
    public let startOptions: [InstallmentCycleOption]
    enum CodingKeys: String, CodingKey {
        case eligible; case purchaseTransactionID = "purchase_transaction_id"; case reasonCode = "reason_code"; case creditAccountID = "credit_account_id"
        case principalMinor = "principal_minor"; case naturalStatementDate = "natural_statement_date"; case startOptions = "start_options"
    }
}

public struct InstallmentPurchaseReplacement: Codable, Sendable, Equatable {
    public var amountMinor: Int64
    public var occurredAt: Date
    public var title: String
    public var note: String?
    public var accountID: UUID
    public var categoryID: UUID
    enum CodingKeys: String, CodingKey { case title, note; case amountMinor = "amount_minor"; case occurredAt = "occurred_at"; case accountID = "account_id"; case categoryID = "category_id" }
}

public struct InstallmentCreateRequest: Codable, Sendable, Equatable {
    public var purchaseTransactionID: UUID
    public var installmentCount: Int
    public var totalFeeMinor: Int64
    public var feeCategoryID: UUID?
    public var feeOccurredAt: Date?
    public var startStatementDate: String
    enum CodingKeys: String, CodingKey {
        case purchaseTransactionID = "purchase_transaction_id"; case installmentCount = "installment_count"; case totalFeeMinor = "total_fee_minor"
        case feeCategoryID = "fee_category_id"; case feeOccurredAt = "fee_occurred_at"; case startStatementDate = "start_statement_date"
    }
}

public struct InstallmentReplacementRequest: Codable, Sendable, Equatable {
    public var expectedVersion: Int
    public var purchase: InstallmentPurchaseReplacement
    public var installmentCount: Int
    public var totalFeeMinor: Int64
    public var feeCategoryID: UUID?
    public var feeOccurredAt: Date?
    public var startStatementDate: String
    enum CodingKeys: String, CodingKey {
        case purchase; case expectedVersion = "expected_version"; case installmentCount = "installment_count"; case totalFeeMinor = "total_fee_minor"
        case feeCategoryID = "fee_category_id"; case feeOccurredAt = "fee_occurred_at"; case startStatementDate = "start_statement_date"
    }
}

public struct InstallmentAffectedCycle: Codable, Sendable, Equatable, Identifiable {
    public var id: String { statementDate }
    public let statementDate: String
    public let cycleID: UUID?
    public let beforeDueMinor: Int64
    public let afterDueMinor: Int64
    public let deltaMinor: Int64
    enum CodingKeys: String, CodingKey { case statementDate = "statement_date"; case cycleID = "cycle_id"; case beforeDueMinor = "before_due_minor"; case afterDueMinor = "after_due_minor"; case deltaMinor = "delta_minor" }
}

public struct InstallmentWarning: Codable, Sendable, Equatable, Identifiable {
    public var id: String { code }
    public let code: String
    public let message: String
}

public struct InstallmentPlanChangePreview: Codable, Sendable, Equatable {
    public let currentPlan: InstallmentPlanDTO
    public let proposedPlan: InstallmentPlanPreview
    public let lockedPeriods: [InstallmentPeriodDTO]
    public let futurePeriods: [InstallmentPeriodPreview]
    public let affectedCycles: [InstallmentAffectedCycle]
    public let warnings: [InstallmentWarning]
    enum CodingKeys: String, CodingKey {
        case warnings; case currentPlan = "current_plan"; case proposedPlan = "proposed_plan"; case lockedPeriods = "locked_periods"; case futurePeriods = "future_periods"; case affectedCycles = "affected_cycles"
    }
}

public struct InstallmentSettlementRequest: Codable, Sendable, Equatable {
    public var expectedVersion: Int
    public var paymentAccountID: UUID
    public var targetStatementDate: String
    public var occurredAt: Date
    enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version"; case paymentAccountID = "payment_account_id"; case targetStatementDate = "target_statement_date"; case occurredAt = "occurred_at" }
}

public struct InstallmentSettlementPreview: Codable, Sendable, Equatable {
    public let amountMinor: Int64
    public let currentPlan: InstallmentPlanDTO
    public let proposedPlan: InstallmentPlanPreview
    public let affectedCycles: [InstallmentAffectedCycle]
    public let paymentBalanceBeforeMinor: Int64
    public let paymentBalanceAfterMinor: Int64
    public let debtBeforeMinor: Int64
    public let debtAfterMinor: Int64
    public let warnings: [InstallmentWarning]
    enum CodingKeys: String, CodingKey {
        case warnings; case amountMinor = "amount_minor"; case currentPlan = "current_plan"; case proposedPlan = "proposed_plan"; case affectedCycles = "affected_cycles"
        case paymentBalanceBeforeMinor = "payment_balance_before_minor"; case paymentBalanceAfterMinor = "payment_balance_after_minor"; case debtBeforeMinor = "debt_before_minor"; case debtAfterMinor = "debt_after_minor"
    }
}

public struct InstallmentOperationRequest: Codable, Sendable, Equatable {
    public var expectedVersion: Int
    public var occurredAt: Date
    enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version"; case occurredAt = "occurred_at" }
}

public struct InstallmentCancellationPreview: Codable, Sendable, Equatable {
    public let principalRefundMinor: Int64
    public let feeRefundMinor: Int64
    public let cancelledPeriods: [InstallmentPeriodPreview]
    public let currentPlan: InstallmentPlanDTO
    public let proposedPlan: InstallmentPlanPreview
    public let affectedCycles: [InstallmentAffectedCycle]
    public let debtBeforeMinor: Int64
    public let debtAfterMinor: Int64
    public let expenseBeforeMinor: Int64
    public let expenseAfterMinor: Int64
    public let warnings: [InstallmentWarning]
    enum CodingKeys: String, CodingKey {
        case warnings; case principalRefundMinor = "principal_refund_minor"; case feeRefundMinor = "fee_refund_minor"; case cancelledPeriods = "cancelled_periods"
        case currentPlan = "current_plan"; case proposedPlan = "proposed_plan"; case affectedCycles = "affected_cycles"; case debtBeforeMinor = "debt_before_minor"; case debtAfterMinor = "debt_after_minor"
        case expenseBeforeMinor = "expense_before_minor"; case expenseAfterMinor = "expense_after_minor"
    }
}

public struct InstallmentReversePreview: Codable, Sendable, Equatable {
    public let eligible: Bool
    public let repaymentTransaction: TransactionDTO
    public let restoredPeriods: [InstallmentPeriodPreview]
    public let affectedCycles: [InstallmentAffectedCycle]
    public let paymentBalanceBeforeMinor: Int64
    public let paymentBalanceAfterMinor: Int64
    public let debtBeforeMinor: Int64
    public let debtAfterMinor: Int64
    public let warnings: [InstallmentWarning]
    enum CodingKeys: String, CodingKey {
        case eligible, warnings; case repaymentTransaction = "repayment_transaction"; case restoredPeriods = "restored_periods"; case affectedCycles = "affected_cycles"
        case paymentBalanceBeforeMinor = "payment_balance_before_minor"; case paymentBalanceAfterMinor = "payment_balance_after_minor"; case debtBeforeMinor = "debt_before_minor"; case debtAfterMinor = "debt_after_minor"
    }
}

public struct InstallmentSettlementResult: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let plan: InstallmentPlanDTO
    public let repaymentTransaction: TransactionDTO
    public let replayed: Bool
    enum CodingKeys: String, CodingKey { case plan, replayed; case operationID = "operation_id"; case repaymentTransaction = "repayment_transaction" }
}

public struct InstallmentReverseResult: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let plan: InstallmentPlanDTO
    public let voidedRepaymentTransaction: TransactionDTO
    public let replayed: Bool
    enum CodingKeys: String, CodingKey { case plan, replayed; case operationID = "operation_id"; case voidedRepaymentTransaction = "voided_repayment_transaction" }
}

public struct InstallmentCancellationResult: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let plan: InstallmentPlanDTO
    public let refundTransactions: [TransactionDTO]
    public let replayed: Bool
    enum CodingKeys: String, CodingKey { case plan, replayed; case operationID = "operation_id"; case refundTransactions = "refund_transactions" }
}

public struct InstallmentLiabilityGroup: Codable, Sendable, Equatable, Identifiable {
    public var id: String { month }
    public let month: String
    public let principalScheduledGrossMinor: Int64
    public let feeScheduledGrossMinor: Int64
    public let totalScheduledGrossMinor: Int64
    public let periodCount: Int
    public let plans: [InstallmentTeaser]
    enum CodingKeys: String, CodingKey {
        case month, plans; case principalScheduledGrossMinor = "principal_scheduled_gross_minor"; case feeScheduledGrossMinor = "fee_scheduled_gross_minor"
        case totalScheduledGrossMinor = "total_scheduled_gross_minor"; case periodCount = "period_count"
    }
}

public struct InstallmentLiabilities: Codable, Sendable, Equatable {
    public let accountID: UUID
    public let totalFutureScheduledGrossMinor: Int64
    public let groups: [InstallmentLiabilityGroup]
    enum CodingKeys: String, CodingKey { case groups; case accountID = "account_id"; case totalFutureScheduledGrossMinor = "total_future_scheduled_gross_minor" }
    public init(from decoder: Decoder) throws { let values = try decoder.container(keyedBy: CodingKeys.self); accountID = try values.decode(UUID.self, forKey: .accountID); totalFutureScheduledGrossMinor = try values.decode(Int64.self, forKey: .totalFutureScheduledGrossMinor); groups = try values.decode([InstallmentLiabilityGroup].self, forKey: .groups) }
}
