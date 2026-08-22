import Foundation

// MARK: - Boundary primitives

public typealias V15MinorUnits = Int64

public struct V15ArchiveExportRequest: Encodable, Sendable, Equatable {
    public let password: String
    public let includeAIRaw: Bool
    public init(password: String, includeAIRaw: Bool) { self.password = password; self.includeAIRaw = includeAIRaw }
    enum CodingKeys: String, CodingKey { case password; case includeAIRaw = "include_ai_raw" }
}

public struct V15Page<Value: Codable & Sendable>: Codable, Sendable {
    public let items: [Value]
    public let nextCursor: String?
    public init(items: [Value], nextCursor: String?) { self.items = items; self.nextCursor = nextCursor }
    enum CodingKeys: String, CodingKey { case items; case nextCursor = "next_cursor" }
}

public struct V15FactsMeta: Codable, Sendable, Equatable {
    public let timezone: String
    public let currency: String
    public let asOf: Date
    public let dataRevision: Int64
    public let schemaVersion: String
    enum CodingKeys: String, CodingKey { case timezone, currency; case asOf = "as_of"; case dataRevision = "data_revision"; case schemaVersion = "schema_version" }
}

public struct V15BusinessDateRange: Codable, Sendable, Equatable {
    public let dateFrom: String
    public let dateTo: String
    enum CodingKeys: String, CodingKey { case dateFrom = "date_from"; case dateTo = "date_to" }
}

public struct V15DrillDownScope: Codable, Sendable, Equatable {
    public let scopeType: String
    public let schemaVersion: String
    public let expectedDataRevision: Int64
    public let readPath: String
    public let deepLink: String
    enum CodingKeys: String, CodingKey { case scopeType = "scope_type"; case schemaVersion = "schema_version"; case expectedDataRevision = "expected_data_revision"; case readPath = "read_path"; case deepLink = "deep_link" }
}

public struct V15Facts: Codable, Sendable {
    public struct Cash: Codable, Sendable { public let currentBalanceMinor: V15MinorUnits; public let scope: V15DrillDownScope?; enum CodingKeys: String, CodingKey { case currentBalanceMinor = "current_balance_minor", scope } }
    public struct Credit: Codable, Sendable { public let currentDebtMinor: V15MinorUnits; public let scope: V15DrillDownScope?; enum CodingKeys: String, CodingKey { case currentDebtMinor = "current_debt_minor", scope } }
    public struct Reimbursements: Codable, Sendable { public let outstandingMinor: V15MinorUnits; public let scope: V15DrillDownScope?; enum CodingKeys: String, CodingKey { case outstandingMinor = "outstanding_minor", scope } }
    public struct Completeness: Codable, Sendable {
        public let unresolvedImportCount: Int; public let failedImportCount: Int; public let uncategorizedTransactionCount: Int; public let openReconciliationDifferenceCount: Int; public let lastReconciledAt: Date?; public let uncategorizedTransactionAmountMinor: V15MinorUnits; public let scope: V15DrillDownScope?
        enum CodingKeys: String, CodingKey { case unresolvedImportCount = "unresolved_import_count", failedImportCount = "failed_import_count", uncategorizedTransactionCount = "uncategorized_transaction_count", openReconciliationDifferenceCount = "open_reconciliation_difference_count", lastReconciledAt = "last_reconciled_at", uncategorizedTransactionAmountMinor = "uncategorized_transaction_amount_minor", scope }
    }
    public struct FutureTotals: Codable, Sendable, Equatable {
        public let exactDueOutflowMinor: V15MinorUnits; public let confirmedOutflowMinor: V15MinorUnits; public let expectedOutflowMinor: V15MinorUnits; public let scheduledOutflowMinor: V15MinorUnits; public let confirmedInflowMinor: V15MinorUnits; public let expectedInflowMinor: V15MinorUnits; public let scheduledInflowMinor: V15MinorUnits; public let afterConfirmedOutflowMinor: V15MinorUnits
        enum CodingKeys: String, CodingKey { case exactDueOutflowMinor = "exact_due_outflow_minor", confirmedOutflowMinor = "confirmed_outflow_minor", expectedOutflowMinor = "expected_outflow_minor", scheduledOutflowMinor = "scheduled_outflow_minor", confirmedInflowMinor = "confirmed_inflow_minor", expectedInflowMinor = "expected_inflow_minor", scheduledInflowMinor = "scheduled_inflow_minor", afterConfirmedOutflowMinor = "after_confirmed_outflow_minor" }
    }
    public let meta: V15FactsMeta
    public let window: V15BusinessDateRange
    public let cash: Cash
    public let credit: Credit
    public let reimbursements: Reimbursements
    public let completeness: Completeness
    public let future: FutureTotals
    public let knownFutureEvents: [V15FutureEvent]
    enum CodingKeys: String, CodingKey { case meta, window, cash, credit, reimbursements, completeness, future; case knownFutureEvents = "known_future_events" }
}

public enum V15FactDrillDownItem: Decodable, Sendable, Equatable {
    public enum CompletenessIssueType: Sendable, Equatable, Decodable {
        case unresolvedImports, failedImports, uncategorizedTransactions, openReconciliationDifferences, unknown(String)
        public init(from decoder: Decoder) throws {
            switch try decoder.singleValueContainer().decode(String.self) {
            case "unresolved_imports": self = .unresolvedImports
            case "failed_imports": self = .failedImports
            case "uncategorized_transactions": self = .uncategorizedTransactions
            case "open_reconciliation_differences": self = .openReconciliationDifferences
            case let value: self = .unknown(value)
            }
        }
    }
    public struct CashAccount: Decodable, Sendable, Equatable, Identifiable {
        public let itemType: String; public let accountID: UUID; public let name: String; public let currentBalanceMinor: V15MinorUnits; public let lastReconciledAt: Date?; public let readPath: String; public let deepLink: String
        public var id: UUID { accountID }
        enum CodingKeys: String, CodingKey { case itemType = "item_type", accountID = "account_id", name, currentBalanceMinor = "current_balance_minor", lastReconciledAt = "last_reconciled_at", readPath = "read_path", deepLink = "deep_link" }
    }
    public struct CreditCycle: Decodable, Sendable, Equatable, Identifiable {
        public let itemType: String; public let cycleID: UUID; public let accountID: UUID; public let accountName: String; public let dueDate: String; public let amountDueMinor: V15MinorUnits; public let repaidMinor: V15MinorUnits; public let remainingMinor: V15MinorUnits; public let readPath: String; public let deepLink: String
        public var id: UUID { cycleID }
        enum CodingKeys: String, CodingKey { case itemType = "item_type", cycleID = "cycle_id", accountID = "account_id", accountName = "account_name", dueDate = "due_date", amountDueMinor = "amount_due_minor", repaidMinor = "repaid_minor", remainingMinor = "remaining_minor", readPath = "read_path", deepLink = "deep_link" }
    }
    public struct ReimbursementOutstanding: Decodable, Sendable, Equatable, Identifiable {
        public let itemType: String; public let claimID: UUID; public let partyID: UUID; public let partyName: String; public let expectedDate: String?; public let expectedMinor: V15MinorUnits; public let receivedMinor: V15MinorUnits; public let outstandingMinor: V15MinorUnits; public let readPath: String; public let deepLink: String
        public var id: UUID { partyID }
        enum CodingKeys: String, CodingKey { case itemType = "item_type", claimID = "claim_id", partyID = "party_id", partyName = "party_name", expectedDate = "expected_date", expectedMinor = "expected_minor", receivedMinor = "received_minor", outstandingMinor = "outstanding_minor", readPath = "read_path", deepLink = "deep_link" }
    }
    public struct CompletenessIssue: Decodable, Sendable, Equatable, Identifiable {
        public let itemType: String; public let issueType: CompletenessIssueType; public let count: Int; public let amountMinor: V15MinorUnits?; public let readPath: String; public let deepLink: String
        public var id: String { String(describing: issueType) }
        enum CodingKeys: String, CodingKey { case itemType = "item_type", issueType = "issue_type", count, amountMinor = "amount_minor", readPath = "read_path", deepLink = "deep_link" }
    }
    /// Forward-compatible rows are deliberately display-only. Their payload is
    /// not exposed to feature code, so a new server type cannot become a link
    /// or action accidentally.
    case unknown(itemType: String?)
    case cashAccount(CashAccount)
    case creditCycle(CreditCycle)
    case reimbursementOutstanding(ReimbursementOutstanding)
    case completenessIssue(CompletenessIssue)

    private enum TypeKey: String, CodingKey { case itemType = "item_type" }
    public init(from decoder: Decoder) throws {
        let type = try decoder.container(keyedBy: TypeKey.self).decodeIfPresent(String.self, forKey: .itemType)
        switch type {
        case "cash_account": self = .cashAccount(try CashAccount(from: decoder))
        case "credit_cycle": self = .creditCycle(try CreditCycle(from: decoder))
        case "reimbursement_outstanding": self = .reimbursementOutstanding(try ReimbursementOutstanding(from: decoder))
        case "completeness_issue": self = .completenessIssue(try CompletenessIssue(from: decoder))
        default: self = .unknown(itemType: type)
        }
    }
}

public struct V15FactDrillDown: Decodable, Sendable {
    public let meta: V15FactsMeta
    public let scope: V15DrillDownScope
    public let items: [V15FactDrillDownItem]
    public let nextCursor: String?
    enum CodingKeys: String, CodingKey { case meta, scope, items; case nextCursor = "next_cursor" }
}

public enum V15AttentionSeverity: String, Decodable, Sendable, Equatable { case info, warning, critical }

public struct V15AttentionItem: Decodable, Sendable, Equatable, Identifiable {
    public let sourceType: String; public let sourceID: UUID; public let severity: V15AttentionSeverity; public let amountMinor: V15MinorUnits?; public let occurredAt: Date?; public let explanation: String; public let suggestedAction: String; public let deepLink: String; public let availableActions: [V15AvailableAction]
    public var id: String { "\(sourceType):\(sourceID.uuidString)" }
    enum CodingKeys: String, CodingKey { case sourceType = "source_type", sourceID = "source_id", severity, amountMinor = "amount_minor", occurredAt = "occurred_at", explanation, suggestedAction = "suggested_action", deepLink = "deep_link", availableActions = "available_actions" }
}

public struct V15AttentionPage: Decodable, Sendable, Equatable { public let items: [V15AttentionItem] }

public enum V15FutureEventSource: String, Codable, Sendable, Equatable, CaseIterable { case creditCycle = "credit_cycle", reimbursementParty = "reimbursement_party", cashFlowItem = "cash_flow_item" }
public enum V15FutureEventDirection: String, Codable, Sendable, Equatable { case inflow, outflow }
public enum V15FutureEventCertainty: String, Codable, Sendable, Equatable, CaseIterable { case exactDue = "exact_due", confirmed, expected, scheduled }

/// Schema-shaped response for the server-owned future-event timeline.  The
/// source, direction and certainty are closed backend enums rather than UI
/// guesses; any decode failure therefore keeps an unknown future state out of
/// an executable surface.
public struct V15FutureEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(sourceType.rawValue):\(sourceID)" }
    public let sourceType: V15FutureEventSource
    public let sourceID: UUID
    public let date: String
    public let direction: V15FutureEventDirection
    public let amountMinor: V15MinorUnits
    public let certainty: V15FutureEventCertainty
    public let title: String
    public let deepLink: String
    public let accountID: UUID?
    public let claimID: UUID?
    public let partyID: UUID?
    public let cycleID: UUID?
    enum CodingKeys: String, CodingKey { case sourceType = "source_type", sourceID = "source_id", date, direction; case amountMinor = "amount_minor"; case certainty, title; case deepLink = "deep_link"; case accountID = "account_id", claimID = "claim_id", partyID = "party_id", cycleID = "cycle_id" }
}

public struct V15FutureEvents: Codable, Sendable {
    public let meta: V15FactsMeta
    public let window: V15BusinessDateRange
    public let accountID: UUID?
    public let items: [V15FutureEvent]
    public let nextCursor: String?
    enum CodingKeys: String, CodingKey { case meta, window; case accountID = "account_id"; case items; case nextCursor = "next_cursor" }
}

public enum V15ReportPeriodKind: Sendable, Equatable, Codable {
    case month, year, unknown(String)
    public init(from decoder: Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "month": self = .month
        case "year": self = .year
        case let raw: self = .unknown(raw)
        }
    }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public var rawValue: String { switch self { case .month: "month"; case .year: "year"; case .unknown(let raw): raw } }
    var routeSegment: String? { switch self { case .month: "monthly"; case .year: "yearly"; case .unknown: nil } }
    public var isKnown: Bool { if case .unknown = self { false } else { true } }
}
public struct V15ReportMonth: Sendable, Equatable, Hashable {
    public let rawValue: String
    public init?(_ rawValue: String) {
        guard rawValue.range(of: "^[0-9]{4}-(0[1-9]|1[0-2])$", options: .regularExpression) != nil,
              let year = Int(rawValue.prefix(4)), (2...9998).contains(year) else { return nil }
        self.rawValue = rawValue
    }
}
public struct V15ReportYear: Sendable, Equatable, Hashable {
    public let rawValue: String
    public init?(_ rawValue: String) {
        guard rawValue.range(of: "^[0-9]{4}$", options: .regularExpression) != nil,
              let year = Int(rawValue), (2...9998).contains(year) else { return nil }
        self.rawValue = rawValue
    }
}
public enum V15ReportPeriod: Sendable, Equatable, Hashable { case month(V15ReportMonth), year(V15ReportYear)
    public var kind: V15ReportPeriodKind { switch self { case .month: .month; case .year: .year } }
    public var rawValue: String { switch self { case .month(let value): value.rawValue; case .year(let value): value.rawValue } }
}
public enum V15ReportArtifactFormat: String, Sendable, Equatable { case csv, pdf
    var accept: String { self == .pdf ? "application/pdf" : "text/csv" }
}

public struct V15ReportMeta: Codable, Sendable, Equatable {
    public let periodKind: V15ReportPeriodKind; public let period: String; public let dateFrom: String; public let dateTo: String; public let timezone: String; public let currency: String; public let asOf: Date; public let dataRevision: Int64; public let reportSchemaVersion: String; public let generatedAt: Date
    enum CodingKeys: String, CodingKey { case periodKind = "period_kind", period; case dateFrom = "date_from", dateTo = "date_to", timezone, currency; case asOf = "as_of", dataRevision = "data_revision", reportSchemaVersion = "report_schema_version"; case generatedAt = "generated_at" }
}

public struct V15PeriodReport: Codable, Sendable {
    public struct Summary: Codable, Sendable {
        public let incomeMinor: V15MinorUnits; public let grossConsumptionMinor: V15MinorUnits; public let merchantRefundMinor: V15MinorUnits; public let netConsumptionMinor: V15MinorUnits; public let expectedReimbursementMinor: V15MinorUnits; public let receivedReimbursementMinor: V15MinorUnits; public let personalExpectedMinor: V15MinorUnits; public let personalRealizedMinor: V15MinorUnits; public let netIncomeExpenseMinor: V15MinorUnits; public let cashInflowMinor: V15MinorUnits; public let cashOutflowMinor: V15MinorUnits; public let cashNetMinor: V15MinorUnits; public let internalTransferInflowMinor: V15MinorUnits; public let internalTransferOutflowMinor: V15MinorUnits; public let creditDebtAtPeriodEndMinor: V15MinorUnits; public let reimbursementOutstandingAtPeriodEndMinor: V15MinorUnits
        enum CodingKeys: String, CodingKey { case incomeMinor = "income_minor", grossConsumptionMinor = "gross_consumption_minor", merchantRefundMinor = "merchant_refund_minor", netConsumptionMinor = "net_consumption_minor", expectedReimbursementMinor = "expected_reimbursement_minor", receivedReimbursementMinor = "received_reimbursement_minor", personalExpectedMinor = "personal_expected_minor", personalRealizedMinor = "personal_realized_minor", netIncomeExpenseMinor = "net_income_expense_minor", cashInflowMinor = "cash_inflow_minor", cashOutflowMinor = "cash_outflow_minor", cashNetMinor = "cash_net_minor", internalTransferInflowMinor = "internal_transfer_inflow_minor", internalTransferOutflowMinor = "internal_transfer_outflow_minor", creditDebtAtPeriodEndMinor = "credit_debt_at_period_end_minor", reimbursementOutstandingAtPeriodEndMinor = "reimbursement_outstanding_at_period_end_minor" }
    }
    public struct Account: Codable, Sendable { public let accountID: UUID; public let accountName: String; public let accountKind: V15ReportAccountKind; public let openingBalanceMinor: V15MinorUnits; public let closingBalanceMinor: V15MinorUnits; public let periodInflowMinor: V15MinorUnits; public let periodOutflowMinor: V15MinorUnits; public let internalTransferInflowMinor: V15MinorUnits; public let internalTransferOutflowMinor: V15MinorUnits; enum CodingKeys: String, CodingKey { case accountID = "account_id", accountName = "account_name", accountKind = "account_kind", openingBalanceMinor = "opening_balance_minor", closingBalanceMinor = "closing_balance_minor", periodInflowMinor = "period_inflow_minor", periodOutflowMinor = "period_outflow_minor", internalTransferInflowMinor = "internal_transfer_inflow_minor", internalTransferOutflowMinor = "internal_transfer_outflow_minor" } }
    public struct Category: Codable, Sendable { public let categoryID: UUID?; public let categoryName: String; public let grossConsumptionMinor: V15MinorUnits; public let merchantRefundMinor: V15MinorUnits; public let netConsumptionMinor: V15MinorUnits; public let transactionCount: Int; enum CodingKeys: String, CodingKey { case categoryID = "category_id", categoryName = "category_name", grossConsumptionMinor = "gross_consumption_minor", merchantRefundMinor = "merchant_refund_minor", netConsumptionMinor = "net_consumption_minor", transactionCount = "transaction_count" } }
    public struct Merchant: Codable, Sendable { public let merchantID: UUID?; public let merchantName: String; public let netConsumptionMinor: V15MinorUnits; public let transactionCount: Int; enum CodingKeys: String, CodingKey { case merchantID = "merchant_id", merchantName = "merchant_name", netConsumptionMinor = "net_consumption_minor", transactionCount = "transaction_count" } }
    public struct Source: Codable, Sendable { public let source: V15ReportTransactionSource; public let transactionCount: Int; enum CodingKeys: String, CodingKey { case source; case transactionCount = "transaction_count" } }
    public struct Completeness: Codable, Sendable { public let unresolvedImportCount: Int; public let failedImportCount: Int; public let uncategorizedTransactionCount: Int; public let openReconciliationDifferenceCount: Int; enum CodingKeys: String, CodingKey { case unresolvedImportCount = "unresolved_import_count", failedImportCount = "failed_import_count", uncategorizedTransactionCount = "uncategorized_transaction_count", openReconciliationDifferenceCount = "open_reconciliation_difference_count" } }
    public let meta: V15ReportMeta
    public let summary: Summary
    public let accounts: [Account]
    public let categories: [Category]
    public let merchants: [Merchant]
    public let sources: [Source]
    public let completeness: Completeness
    public let drillDownPath: String
    enum CodingKeys: String, CodingKey { case meta, summary, accounts, categories, merchants, sources, completeness; case drillDownPath = "drill_down_path" }
}

public enum V15ReportAccountKind: Sendable, Equatable, Codable { case cash, debit, credit, unknown(String)
    public init(from decoder: Decoder) throws { switch try decoder.singleValueContainer().decode(String.self) { case "cash": self = .cash; case "debit": self = .debit; case "credit": self = .credit; case let raw: self = .unknown(raw) } }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public var rawValue: String { switch self { case .cash: "cash"; case .debit: "debit"; case .credit: "credit"; case .unknown(let raw): raw } }
    public var isKnown: Bool { if case .unknown = self { false } else { true } }
}
public enum V15ReportTransactionKind: Sendable, Equatable, Codable { case income, expense, transfer, creditPurchase, repayment, installmentFee, installmentRefund, reimbursementReceipt, unknown(String)
    public init(from decoder: Decoder) throws { switch try decoder.singleValueContainer().decode(String.self) { case "income": self = .income; case "expense": self = .expense; case "transfer": self = .transfer; case "credit_purchase": self = .creditPurchase; case "repayment": self = .repayment; case "installment_fee": self = .installmentFee; case "installment_refund": self = .installmentRefund; case "reimbursement_receipt": self = .reimbursementReceipt; case let raw: self = .unknown(raw) } }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public var rawValue: String { switch self { case .income: "income"; case .expense: "expense"; case .transfer: "transfer"; case .creditPurchase: "credit_purchase"; case .repayment: "repayment"; case .installmentFee: "installment_fee"; case .installmentRefund: "installment_refund"; case .reimbursementReceipt: "reimbursement_receipt"; case .unknown(let raw): raw } }
}
public enum V15ReportTransactionSource: Sendable, Equatable, Hashable, Codable { case manual, system, aiText, ocr, legacyImport, cashFlow, statementImport, unknown(String)
    public init(from decoder: Decoder) throws { switch try decoder.singleValueContainer().decode(String.self) { case "manual": self = .manual; case "system": self = .system; case "ai_text": self = .aiText; case "ocr": self = .ocr; case "legacy_import": self = .legacyImport; case "cash_flow": self = .cashFlow; case "statement_import": self = .statementImport; case let raw: self = .unknown(raw) } }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public var rawValue: String { switch self { case .manual: "manual"; case .system: "system"; case .aiText: "ai_text"; case .ocr: "ocr"; case .legacyImport: "legacy_import"; case .cashFlow: "cash_flow"; case .statementImport: "statement_import"; case .unknown(let raw): raw } }
    public var isKnown: Bool { if case .unknown = self { false } else { true } }
}
public enum V15ReportDrillDimension: Sendable, Equatable, Codable { case ledger, unknown(String)
    public init(from decoder: Decoder) throws { let raw = try decoder.singleValueContainer().decode(String.self); self = raw == "ledger" ? .ledger : .unknown(raw) }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public var rawValue: String { switch self { case .ledger: "ledger"; case .unknown(let raw): raw } }
}
public enum V15ReportDrillFilter: Sendable, Equatable, Hashable {
    case category(UUID), account(UUID), merchant(UUID), source(V15ReportTransactionSource)
    public var queryItem: URLQueryItem? { switch self { case .category(let id): .init(name: "category_id", value: id.uuidString); case .account(let id): .init(name: "account_id", value: id.uuidString); case .merchant(let id): .init(name: "merchant_id", value: id.uuidString); case .source(let source): source.isKnown ? .init(name: "source", value: source.rawValue) : nil } }
}
public enum V15ReportDrillCapability: Sendable, Equatable {
    case enabled(V15ReportDrillFilter)
    case disabled(String)
}
public extension V15PeriodReport.Account { var drillCapability: V15ReportDrillCapability { accountKind.isKnown ? .enabled(.account(accountID)) : .disabled("此汇总没有可安全定位的明细筛选条件") } }
public extension V15PeriodReport.Category { var drillCapability: V15ReportDrillCapability { categoryID.map { .enabled(.category($0)) } ?? .disabled("此汇总没有可安全定位的明细筛选条件") } }
public extension V15PeriodReport.Merchant { var drillCapability: V15ReportDrillCapability { merchantID.map { .enabled(.merchant($0)) } ?? .disabled("此汇总没有可安全定位的明细筛选条件") } }
public extension V15PeriodReport.Source { var drillCapability: V15ReportDrillCapability { source.isKnown ? .enabled(.source(source)) : .disabled("此汇总没有可安全定位的明细筛选条件") } }

public struct V15PeriodReportDrillDown: Codable, Sendable {
    public struct Item: Codable, Sendable, Identifiable { public let transactionID: UUID; public let occurredAt: Date; public let businessDate: String; public let kind: V15ReportTransactionKind; public let source: V15ReportTransactionSource; public let categoryID: UUID?; public let categoryName: String?; public let merchantID: UUID?; public let merchantName: String?; public let externalCashAmountMinor: V15MinorUnits; public let grossConsumptionMinor: V15MinorUnits; public let merchantRefundMinor: V15MinorUnits; public let netConsumptionMinor: V15MinorUnits; public var id: UUID { transactionID }; enum CodingKeys: String, CodingKey { case transactionID = "transaction_id", occurredAt = "occurred_at", businessDate = "business_date", kind, source, categoryID = "category_id", categoryName = "category_name", merchantID = "merchant_id", merchantName = "merchant_name", externalCashAmountMinor = "external_cash_amount_minor", grossConsumptionMinor = "gross_consumption_minor", merchantRefundMinor = "merchant_refund_minor", netConsumptionMinor = "net_consumption_minor" } }
    public let meta: V15ReportMeta
    public let dimension: V15ReportDrillDimension
    public let categoryID: UUID?
    public let accountID: UUID?
    public let merchantID: UUID?
    public let source: V15ReportTransactionSource?
    public let items: [Item]
    public let nextCursor: String?
    enum CodingKeys: String, CodingKey { case meta, dimension; case categoryID = "category_id", accountID = "account_id", merchantID = "merchant_id", source, items; case nextCursor = "next_cursor" }
}

public struct V15AvailableAction: Codable, Sendable, Equatable {
    public let action: String
    public let enabled: Bool
    public let reasonCode: String?
    public let reasonMessage: String?
    enum CodingKeys: String, CodingKey { case action, enabled; case reasonCode = "reason_code"; case reasonMessage = "reason_message" }
    /// The server owns the capability vocabulary. Unknown actions never become
    /// clickable by accident; a feature must explicitly recognize them.
    public func capability(knownActions: Set<String>) -> V15Capability {
        guard knownActions.contains(action) else { return .disabled(action: action, reason: .unknownCapability) }
        return enabled ? .enabled(action: action) : .disabled(action: action, reason: .init(code: reasonCode ?? "action_unavailable", message: reasonMessage ?? "此操作当前不可用。", fieldPath: nil))
    }
}

public struct V15VersionedCapabilityResource: Codable, Sendable {
    public let id: UUID
    public let version: Int
    public let availableActions: [V15AvailableAction]
    enum CodingKeys: String, CodingKey { case id, version; case availableActions = "available_actions" }
}

public struct V15EligibilityReason: Codable, Sendable, Equatable {
    public let code: String; public let message: String; public let fieldPath: String?
    enum CodingKeys: String, CodingKey { case code, message; case fieldPath = "field_path" }
}

public struct V15ReimbursementCandidate: Codable, Sendable, Equatable {
    public let transactionID: UUID; public let title: String; public let businessDate: String; public let kind: String; public let accountID: UUID; public let categoryID: UUID?; public let canonicalAmountMinor: V15MinorUnits; public let allocatedMinor: V15MinorUnits; public let availableMinor: V15MinorUnits; public let eligibility: Eligibility
    public struct Eligibility: Codable, Sendable, Equatable {
        public let eligible: Bool; public let transactionID: UUID; public let canonicalAmountMinor: V15MinorUnits; public let allocatedMinor: V15MinorUnits; public let availableMinor: V15MinorUnits; public let reasons: [String]; public let reasonDetails: [V15EligibilityReason]
        enum CodingKeys: String, CodingKey { case eligible, transactionID = "transaction_id", canonicalAmountMinor = "canonical_amount_minor", allocatedMinor = "allocated_minor", availableMinor = "available_minor", reasons; case reasonDetails = "reason_details" }
    }
    enum CodingKeys: String, CodingKey { case transactionID = "transaction_id", title; case businessDate = "business_date"; case kind; case accountID = "account_id", categoryID = "category_id"; case canonicalAmountMinor = "canonical_amount_minor", allocatedMinor = "allocated_minor", availableMinor = "available_minor", eligibility }
}

public struct V15ReceiptAccountOption: Codable, Sendable, Equatable, Identifiable { public let id: UUID; public let name: String; public let kind: String }
public struct V15ReceiptAccountOptions: Codable, Sendable, Equatable { public let items: [V15ReceiptAccountOption] }

public struct V15Preview: Codable, Sendable, Equatable {
    public let previewToken: UUID
    public let inputDigest: String?
    public let expiresAt: Date?
    public let revision: Int64?
    enum CodingKeys: String, CodingKey { case previewToken = "preview_token"; case inputDigest = "input_digest"; case expiresAt = "preview_expires_at"; case revision = "data_revision" }
}

public enum V15CreditCycleMode: String, Codable, Sendable, Equatable, CaseIterable {
    case statementDayCutoff = "statement_day_cutoff"
    case previousCalendarMonth = "previous_calendar_month"
    case unknown
    public init(from decoder: Decoder) throws { self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown }
}

/// The schedule endpoint deliberately uses a narrower action representation
/// than normal resources: P33 returns names only.  Keep that distinction
/// explicit rather than inventing `enabled` or a server reason that was never
/// sent.
public struct V15CreditSchedulePreview: Codable, Sendable, Equatable {
    public struct AffectedCycle: Codable, Sendable, Equatable { public let cycleID: UUID; public let currentVersion: Int; public let expectedVersion: Int; public let oldStatementDate: String; public let oldDueDate: String; public let newStatementDate: String; public let newDueDate: String; public let remainingMinor: V15MinorUnits; public let oldIsOverdue: Bool; public let newIsOverdue: Bool; public let preservedCheckpointCount: Int; enum CodingKeys: String, CodingKey { case cycleID = "cycle_id", currentVersion = "current_version", expectedVersion = "expected_version", oldStatementDate = "old_statement_date", oldDueDate = "old_due_date", newStatementDate = "new_statement_date", newDueDate = "new_due_date", remainingMinor = "remaining_minor", oldIsOverdue = "old_is_overdue", newIsOverdue = "new_is_overdue", preservedCheckpointCount = "preserved_checkpoint_count" } }
    public let accountID: UUID; public let cycleMode: String; public let statementDay: Int; public let dueDay: Int; public let oldCycleMode: String?; public let oldStatementDay: Int?; public let oldDueDay: Int?; public let affectedCycleCount: Int; public let purchaseCount: Int; public let repaymentCount: Int; public let installmentPeriodCount: Int; public let affectedCycles: [AffectedCycle]; public let oldOverdueCycleCount: Int; public let newOverdueCycleCount: Int; public let conflicts: [String]; public let previewToken: UUID?; public let previewExpiresAt: Date?; public let currentAccountVersion: Int?; public let expectedAccountVersion: Int?; public let warnings: [String]; public let availableActions: [String]; public let dataRevision: Int64?
    enum CodingKeys: String, CodingKey { case accountID = "account_id", cycleMode = "cycle_mode", statementDay = "statement_day", dueDay = "due_day", oldCycleMode = "old_cycle_mode", oldStatementDay = "old_statement_day", oldDueDay = "old_due_day", affectedCycleCount = "affected_cycle_count", purchaseCount = "purchase_count", repaymentCount = "repayment_count", installmentPeriodCount = "installment_period_count", affectedCycles = "affected_cycles", oldOverdueCycleCount = "old_overdue_cycle_count", newOverdueCycleCount = "new_overdue_cycle_count", conflicts, previewToken = "preview_token", previewExpiresAt = "preview_expires_at", currentAccountVersion = "current_account_version", expectedAccountVersion = "expected_account_version", warnings, availableActions = "available_actions", dataRevision = "data_revision" }
}

// MARK: - P31 category transform previews

public struct V15CategoryDependency: Codable, Sendable, Equatable { public let categoryID: UUID; public let transactionCount: Int; public let amountMinor: V15MinorUnits; enum CodingKeys: String, CodingKey { case categoryID = "category_id", transactionCount = "transaction_count", amountMinor = "amount_minor" } }
public struct V15CategoryChildMappingRequirement: Codable, Sendable, Equatable { public let sourceChildID: UUID; public let sourceChildName: String; public let targetChildIDs: [UUID]; enum CodingKeys: String, CodingKey { case sourceChildID = "source_child_id", sourceChildName = "source_child_name", targetChildIDs = "target_child_ids" } }
public struct V15CategoryMergePreviewRequest: Codable, Sendable, Equatable { public let targetID: UUID; public let sourceExpectedVersion: Int; public let targetExpectedVersion: Int; public init(targetID: UUID, sourceExpectedVersion: Int, targetExpectedVersion: Int) { self.targetID = targetID; self.sourceExpectedVersion = sourceExpectedVersion; self.targetExpectedVersion = targetExpectedVersion }; enum CodingKeys: String, CodingKey { case targetID = "target_id", sourceExpectedVersion = "source_expected_version", targetExpectedVersion = "target_expected_version" } }
public struct V15CategoryDraft: Codable, Sendable, Equatable { public let name: String; public let direction: String; public let parentID: UUID?; public let icon: String; public let colorHex: String; public let aliases: [String]; public let examples: [String]; public let isBalanceAdjustment: Bool; public init(name: String, direction: String, parentID: UUID? = nil, icon: String, colorHex: String, aliases: [String] = [], examples: [String] = [], isBalanceAdjustment: Bool = false) { self.name = name; self.direction = direction; self.parentID = parentID; self.icon = icon; self.colorHex = colorHex; self.aliases = aliases; self.examples = examples; self.isBalanceAdjustment = isBalanceAdjustment }; enum CodingKeys: String, CodingKey { case name, direction, parentID = "parent_id", icon, colorHex = "color_hex", aliases, examples, isBalanceAdjustment = "is_balance_adjustment" } }
public struct V15CategorySplitPreviewRequest: Codable, Sendable, Equatable { public let rootExpectedVersion: Int; public let children: [V15CategoryDraft]; public init(rootExpectedVersion: Int, children: [V15CategoryDraft]) { self.rootExpectedVersion = rootExpectedVersion; self.children = children }; enum CodingKeys: String, CodingKey { case rootExpectedVersion = "root_expected_version", children } }
public struct V15CategoryMergePreview: Codable, Sendable, Equatable { public let previewToken: UUID; public let source: V15CategoryDependency; public let targetID: UUID; public let childMappingRequirements: [V15CategoryChildMappingRequirement]; public let atomic: Bool; enum CodingKeys: String, CodingKey { case previewToken = "preview_token", source, targetID = "target_id", childMappingRequirements = "child_mapping_requirements", atomic } }
public struct V15CategorySplitPreview: Codable, Sendable, Equatable { public let previewToken: UUID; public let root: V15CategoryDependency; public let requiredTransactionIDs: [UUID]; public let childNames: [String]; public let atomic: Bool; enum CodingKeys: String, CodingKey { case previewToken = "preview_token", root, requiredTransactionIDs = "required_transaction_ids", childNames = "child_names", atomic } }
public struct V15CategoryChildMapping: Codable, Sendable, Equatable { public let sourceChildID: UUID; public let targetChildID: UUID; public init(sourceChildID: UUID, targetChildID: UUID) { self.sourceChildID = sourceChildID; self.targetChildID = targetChildID }; enum CodingKeys: String, CodingKey { case sourceChildID = "source_child_id", targetChildID = "target_child_id" } }
public struct V15CategoryMergeCommitRequest: Codable, Sendable, Equatable { public let previewToken: UUID; public let childMappings: [V15CategoryChildMapping]; public init(previewToken: UUID, childMappings: [V15CategoryChildMapping] = []) { self.previewToken = previewToken; self.childMappings = childMappings }; enum CodingKeys: String, CodingKey { case previewToken = "preview_token", childMappings = "child_mappings" } }
public struct V15CategorySplitAssignment: Codable, Sendable, Equatable { public let transactionID: UUID; public let childName: String; public init(transactionID: UUID, childName: String) { self.transactionID = transactionID; self.childName = childName }; enum CodingKeys: String, CodingKey { case transactionID = "transaction_id", childName = "child_name" } }
public struct V15CategorySplitCommitRequest: Codable, Sendable, Equatable { public let previewToken: UUID; public let assignments: [V15CategorySplitAssignment]; public init(previewToken: UUID, assignments: [V15CategorySplitAssignment]) { self.previewToken = previewToken; self.assignments = assignments }; enum CodingKeys: String, CodingKey { case previewToken = "preview_token", assignments } }
public struct V15CategoryResponse: Codable, Sendable, Equatable, Identifiable { public let id: UUID; public let name: String; public let direction: String; public let parentID: UUID?; public let icon: String; public let colorHex: String; public let aliases: [String]; public let examples: [String]; public let isBalanceAdjustment: Bool; public let sortOrder: Int; public let archivedAt: Date?; public let usageCount: Int; public let version: Int; public let createdAt: Date; public let updatedAt: Date; public let children: [V15CategoryResponse]; enum CodingKeys: String, CodingKey { case id, name, direction, parentID = "parent_id", icon, colorHex = "color_hex", aliases, examples, isBalanceAdjustment = "is_balance_adjustment", sortOrder = "sort_order", archivedAt = "archived_at", usageCount = "usage_count", version, createdAt = "created_at", updatedAt = "updated_at", children } }
public struct V15CategoryTransformReceipt: Codable, Sendable, Equatable { public let action: String; public let categories: [V15CategoryResponse]; public let reclassifiedTransactionCount: Int; enum CodingKeys: String, CodingKey { case action, categories; case reclassifiedTransactionCount = "reclassified_transaction_count" } }

// MARK: - Typed mutation requests

public struct V15CreditScheduleChangeRequest: Codable, Sendable, Equatable { public let expectedVersion: Int; public let cycleMode: String; public let statementDay: Int; public let dueDay: Int; public init(expectedVersion: Int, cycleMode: String, statementDay: Int, dueDay: Int) { self.expectedVersion = expectedVersion; self.cycleMode = cycleMode; self.statementDay = statementDay; self.dueDay = dueDay }; enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version", cycleMode = "cycle_mode", statementDay = "statement_day", dueDay = "due_day" } }
public struct V15CreditScheduleChangeCommitRequest: Codable, Sendable, Equatable { public let expectedVersion: Int; public let cycleMode: String; public let statementDay: Int; public let dueDay: Int; public let previewToken: UUID; public init(expectedVersion: Int, cycleMode: String, statementDay: Int, dueDay: Int, previewToken: UUID) { self.expectedVersion = expectedVersion; self.cycleMode = cycleMode; self.statementDay = statementDay; self.dueDay = dueDay; self.previewToken = previewToken }; enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version", cycleMode = "cycle_mode", statementDay = "statement_day", dueDay = "due_day", previewToken = "preview_token" } }

public struct V15ReimbursementAllocationDraft: Codable, Sendable, Equatable { public let id: UUID?; public let transactionID: UUID; public let amountMinor: V15MinorUnits; public init(id: UUID? = nil, transactionID: UUID, amountMinor: V15MinorUnits) { self.id = id; self.transactionID = transactionID; self.amountMinor = amountMinor }; enum CodingKeys: String, CodingKey { case id, transactionID = "transaction_id", amountMinor = "amount_minor" } }
public struct V15ReimbursementPartyDraft: Codable, Sendable, Equatable { public let id: UUID?; public let name: String; public let expectedDate: String?; public let note: String?; public let allocations: [V15ReimbursementAllocationDraft]; public init(id: UUID? = nil, name: String, expectedDate: String? = nil, note: String? = nil, allocations: [V15ReimbursementAllocationDraft]) { self.id = id; self.name = name; self.expectedDate = expectedDate; self.note = note; self.allocations = allocations }; enum CodingKeys: String, CodingKey { case id, name, expectedDate = "expected_date", note, allocations } }
public struct V15ReimbursementClaimDraft: Codable, Sendable, Equatable { public let title: String; public let note: String?; public let parties: [V15ReimbursementPartyDraft]; public init(title: String, note: String? = nil, parties: [V15ReimbursementPartyDraft]) { self.title = title; self.note = note; self.parties = parties } }
public struct V15ReimbursementClaimPreviewRequest: Codable, Sendable, Equatable { public let title: String; public let note: String?; public let parties: [V15ReimbursementPartyDraft]; public let expectedVersion: Int; public init(title: String, note: String? = nil, parties: [V15ReimbursementPartyDraft], expectedVersion: Int) { self.title = title; self.note = note; self.parties = parties; self.expectedVersion = expectedVersion }; enum CodingKeys: String, CodingKey { case title, note, parties, expectedVersion = "expected_version" } }
public struct V15ReimbursementClaimCommitRequest: Codable, Sendable, Equatable { public let title: String; public let note: String?; public let parties: [V15ReimbursementPartyDraft]; public let expectedVersion: Int; public let previewToken: UUID; public init(title: String, note: String? = nil, parties: [V15ReimbursementPartyDraft], expectedVersion: Int, previewToken: UUID) { self.title = title; self.note = note; self.parties = parties; self.expectedVersion = expectedVersion; self.previewToken = previewToken }; enum CodingKeys: String, CodingKey { case title, note, parties, expectedVersion = "expected_version", previewToken = "preview_token" } }
public struct V15ReimbursementVersionRequest: Codable, Sendable, Equatable { public let expectedVersion: Int; public init(expectedVersion: Int) { self.expectedVersion = expectedVersion }; enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version" } }
public struct V15ReimbursementCancelCommitRequest: Codable, Sendable, Equatable { public let expectedVersion: Int; public let previewToken: UUID; public init(expectedVersion: Int, previewToken: UUID) { self.expectedVersion = expectedVersion; self.previewToken = previewToken }; enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version", previewToken = "preview_token" } }
public struct V15ReimbursementReceiptDraft: Codable, Sendable, Equatable { public let expectedClaimVersion: Int; public let partyID: UUID; public let amountMinor: V15MinorUnits; public let receivedAt: Date; public let destinationAccountID: UUID; public let title: String; public let note: String?; public init(expectedClaimVersion: Int, partyID: UUID, amountMinor: V15MinorUnits, receivedAt: Date, destinationAccountID: UUID, title: String, note: String? = nil) { self.expectedClaimVersion = expectedClaimVersion; self.partyID = partyID; self.amountMinor = amountMinor; self.receivedAt = receivedAt; self.destinationAccountID = destinationAccountID; self.title = title; self.note = note }; enum CodingKeys: String, CodingKey { case expectedClaimVersion = "expected_claim_version", partyID = "party_id", amountMinor = "amount_minor", receivedAt = "received_at", destinationAccountID = "destination_account_id", title, note } }
public struct V15ReimbursementReceiptReplacePreviewRequest: Codable, Sendable, Equatable { public let expectedClaimVersion: Int; public let partyID: UUID; public let amountMinor: V15MinorUnits; public let receivedAt: Date; public let destinationAccountID: UUID; public let title: String; public let note: String?; public let expectedReceiptVersion: Int; public init(expectedClaimVersion: Int, partyID: UUID, amountMinor: V15MinorUnits, receivedAt: Date, destinationAccountID: UUID, title: String, note: String? = nil, expectedReceiptVersion: Int) { self.expectedClaimVersion = expectedClaimVersion; self.partyID = partyID; self.amountMinor = amountMinor; self.receivedAt = receivedAt; self.destinationAccountID = destinationAccountID; self.title = title; self.note = note; self.expectedReceiptVersion = expectedReceiptVersion }; enum CodingKeys: String, CodingKey { case expectedClaimVersion = "expected_claim_version", partyID = "party_id", amountMinor = "amount_minor", receivedAt = "received_at", destinationAccountID = "destination_account_id", title, note, expectedReceiptVersion = "expected_receipt_version" } }
public struct V15ReimbursementReceiptReplaceCommitRequest: Codable, Sendable, Equatable { public let expectedClaimVersion: Int; public let partyID: UUID; public let amountMinor: V15MinorUnits; public let receivedAt: Date; public let destinationAccountID: UUID; public let title: String; public let note: String?; public let expectedReceiptVersion: Int; public let previewToken: UUID; public init(expectedClaimVersion: Int, partyID: UUID, amountMinor: V15MinorUnits, receivedAt: Date, destinationAccountID: UUID, title: String, note: String? = nil, expectedReceiptVersion: Int, previewToken: UUID) { self.expectedClaimVersion = expectedClaimVersion; self.partyID = partyID; self.amountMinor = amountMinor; self.receivedAt = receivedAt; self.destinationAccountID = destinationAccountID; self.title = title; self.note = note; self.expectedReceiptVersion = expectedReceiptVersion; self.previewToken = previewToken }; enum CodingKeys: String, CodingKey { case expectedClaimVersion = "expected_claim_version", partyID = "party_id", amountMinor = "amount_minor", receivedAt = "received_at", destinationAccountID = "destination_account_id", title, note, expectedReceiptVersion = "expected_receipt_version", previewToken = "preview_token" } }
public struct V15ReimbursementReceiptCreateCommitRequest: Codable, Sendable, Equatable { public let expectedClaimVersion: Int; public let partyID: UUID; public let amountMinor: V15MinorUnits; public let receivedAt: Date; public let destinationAccountID: UUID; public let title: String; public let note: String?; public let previewToken: UUID; public init(expectedClaimVersion: Int, partyID: UUID, amountMinor: V15MinorUnits, receivedAt: Date, destinationAccountID: UUID, title: String, note: String? = nil, previewToken: UUID) { self.expectedClaimVersion = expectedClaimVersion; self.partyID = partyID; self.amountMinor = amountMinor; self.receivedAt = receivedAt; self.destinationAccountID = destinationAccountID; self.title = title; self.note = note; self.previewToken = previewToken }; enum CodingKeys: String, CodingKey { case expectedClaimVersion = "expected_claim_version", partyID = "party_id", amountMinor = "amount_minor", receivedAt = "received_at", destinationAccountID = "destination_account_id", title, note, previewToken = "preview_token" } }
public struct V15ReimbursementReceiptVersionRequest: Codable, Sendable, Equatable { public let expectedClaimVersion: Int; public let expectedReceiptVersion: Int; public init(expectedClaimVersion: Int, expectedReceiptVersion: Int) { self.expectedClaimVersion = expectedClaimVersion; self.expectedReceiptVersion = expectedReceiptVersion }; enum CodingKeys: String, CodingKey { case expectedClaimVersion = "expected_claim_version", expectedReceiptVersion = "expected_receipt_version" } }
public struct V15InstallmentActionRequest: Codable, Sendable, Equatable { public let expectedVersion: Int; public let occurredAt: Date; public init(expectedVersion: Int, occurredAt: Date) { self.expectedVersion = expectedVersion; self.occurredAt = occurredAt }; enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version", occurredAt = "occurred_at" } }
public struct V15InstallmentSettlementRequest: Codable, Sendable, Equatable { public let expectedVersion: Int; public let occurredAt: Date; public let paymentAccountID: UUID; public let targetStatementDate: String; public init(expectedVersion: Int, occurredAt: Date, paymentAccountID: UUID, targetStatementDate: String) { self.expectedVersion = expectedVersion; self.occurredAt = occurredAt; self.paymentAccountID = paymentAccountID; self.targetStatementDate = targetStatementDate }; enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version", occurredAt = "occurred_at", paymentAccountID = "payment_account_id", targetStatementDate = "target_statement_date" } }
public struct V15StatementProviderAuthorization: Codable, Sendable, Equatable { public let confirmed: Bool; public let provider: String; public let providerModel: String; public let promptVersion: String; public let schemaVersion: String; public let evidenceSHA256: String; public let pageNumbers: [Int]; public let rowCount: Int; public let redactionVersion: String; public let redactionCount: Int; public init(confirmed: Bool, provider: String, providerModel: String, promptVersion: String, schemaVersion: String, evidenceSHA256: String, pageNumbers: [Int], rowCount: Int, redactionVersion: String, redactionCount: Int) { self.confirmed = confirmed; self.provider = provider; self.providerModel = providerModel; self.promptVersion = promptVersion; self.schemaVersion = schemaVersion; self.evidenceSHA256 = evidenceSHA256; self.pageNumbers = pageNumbers; self.rowCount = rowCount; self.redactionVersion = redactionVersion; self.redactionCount = redactionCount }; enum CodingKeys: String, CodingKey { case confirmed, provider, providerModel = "provider_model", promptVersion = "prompt_version", schemaVersion = "schema_version", evidenceSHA256 = "evidence_sha256", pageNumbers = "page_numbers", rowCount = "row_count", redactionVersion = "redaction_version", redactionCount = "redaction_count" } }
public struct V15StatementProviderAttemptCreate: Codable, Sendable, Equatable { public let expectedVersion: Int; public let evidenceSHA256: String; public let authorization: V15StatementProviderAuthorization; public init(expectedVersion: Int, evidenceSHA256: String, authorization: V15StatementProviderAuthorization) { self.expectedVersion = expectedVersion; self.evidenceSHA256 = evidenceSHA256; self.authorization = authorization }; enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version", evidenceSHA256 = "evidence_sha256", authorization } }

public struct V15MutationReceipt: Codable, Sendable, Equatable {
    public let action: String?
    public let dataRevision: Int64?
    public let receiptID: UUID?
    enum CodingKeys: String, CodingKey { case action; case dataRevision = "data_revision"; case receiptID = "receipt_id" }
}

public struct V15StatementProviderAttempt: Codable, Sendable, Equatable {
    public let providerAttemptID: String; public let attemptID: String; public let providerStatus: String; public let candidateCount: Int; public let replay: Bool; public let executionScope: String
    enum CodingKeys: String, CodingKey { case providerAttemptID = "provider_attempt_id", attemptID = "attempt_id", providerStatus = "provider_status", candidateCount = "candidate_count", replay; case executionScope = "execution_scope" }
    public var isRequestBound: Bool { executionScope == "request_bound" }
}

public struct V15Merchant: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID; public let name: String; public let aliases: [String]; public let version: Int
    public let archivedAt: Date?; public let createdAt: Date; public let updatedAt: Date
    enum CodingKeys: String, CodingKey { case id, name, aliases, version; case archivedAt = "archived_at", createdAt = "created_at", updatedAt = "updated_at" }
}

// MARK: - Reimbursement preview effects (P30-C/P33)

public struct V15Posting: Codable, Sendable, Equatable { public let id: UUID; public let accountID: UUID; public let role: String; public let amountMinor: V15MinorUnits; public let position: Int; enum CodingKeys: String, CodingKey { case id, accountID = "account_id", role, amountMinor = "amount_minor", position } }
public struct V15InstallmentRelation: Codable, Sendable, Equatable { public let planID: UUID; public let role: String; public let planTitle: String; public let planStatus: String; enum CodingKeys: String, CodingKey { case planID = "plan_id", role, planTitle = "plan_title", planStatus = "plan_status" } }
public struct V15ReimbursementRelation: Codable, Sendable, Equatable { public let role: String; public let claimID: UUID; public let claimTitle: String; public let claimStatus: String; public let partyID: UUID?; public let partyName: String?; public let receiptID: UUID?; public let allocatedMinor: V15MinorUnits; public let receivedMinor: V15MinorUnits; public let outstandingMinor: V15MinorUnits; enum CodingKeys: String, CodingKey { case role, claimID = "claim_id", claimTitle = "claim_title", claimStatus = "claim_status", partyID = "party_id", partyName = "party_name", receiptID = "receipt_id", allocatedMinor = "allocated_minor", receivedMinor = "received_minor", outstandingMinor = "outstanding_minor" } }
public struct V15Transaction: Codable, Sendable, Equatable { public let id: UUID; public let kind: String; public let amountMinor: V15MinorUnits; public let occurredAt: Date; public let businessDate: String; public let title: String; public let note: String?; public let categoryID: UUID?; public let accountID: UUID?; public let destinationAccountID: UUID?; public let creditCycleID: UUID?; public let source: String; public let postings: [V15Posting]; public let version: Int; public let voidedAt: Date?; public let createdAt: Date; public let updatedAt: Date; public let installmentPlanID: UUID?; public let installmentRelation: V15InstallmentRelation?; public let reimbursementRelations: [V15ReimbursementRelation]; public let availableActions: [V15AvailableAction]; enum CodingKeys: String, CodingKey { case id, kind, amountMinor = "amount_minor", occurredAt = "occurred_at", businessDate = "business_date", title, note, categoryID = "category_id", accountID = "account_id", destinationAccountID = "destination_account_id", creditCycleID = "credit_cycle_id", source, postings, version, voidedAt = "voided_at", createdAt = "created_at", updatedAt = "updated_at", installmentPlanID = "installment_plan_id", installmentRelation = "installment_relation", reimbursementRelations = "reimbursement_relations", availableActions = "available_actions" } }

// MARK: - F1-A bootstrap, master-data read, and manual ledger contracts

public struct V15SessionRequest: Codable, Sendable, Equatable {
    public let passphrase: String
    public init(passphrase: String) { self.passphrase = passphrase }
}

public struct V15SessionResponse: Codable, Sendable, Equatable {
    public let accessKey: String
    public let credentialGeneration: Int
    enum CodingKeys: String, CodingKey { case accessKey = "access_key", credentialGeneration = "credential_generation" }
}

public struct V15AuthStatus: Codable, Sendable, Equatable {
    public let authenticationMode: String
    public let passphraseSet: Bool
    public let credentialGeneration: Int
    public let lastRotatedAt: Date?
    public let activeAccessKeyCount: Int
    public let serverTime: Date
    enum CodingKeys: String, CodingKey { case authenticationMode = "authentication_mode", passphraseSet = "passphrase_set", credentialGeneration = "credential_generation", lastRotatedAt = "last_rotated_at", activeAccessKeyCount = "active_access_key_count", serverTime = "server_time" }
}

public struct V15SystemStatus: Codable, Sendable, Equatable {
    public let service: String; public let version: String; public let environment: String
    public let status: String; public let database: String; public let currency: String
    public let businessTimezone: String; public let timestamp: Date
    enum CodingKeys: String, CodingKey { case service, version, environment, status, database, currency; case businessTimezone = "business_timezone"; case timestamp }
    public var isReady: Bool { status == "operational" && database == "ready" && currency == "CNY" && businessTimezone == "Asia/Shanghai" }
}

/// Unknown account strings deliberately stay readable but cannot satisfy a
/// transaction type predicate. This keeps new server enum values safe.
public enum V15AccountKind: String, Codable, Sendable, Equatable { case cash, debit, credit, unknown
    public init(from decoder: Decoder) throws { self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown }
}

public struct V15AccountResponse: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID; public let name: String; public let kind: V15AccountKind
    public let institution: String?; public let lastFour: String?; public let openingBalanceMinor: V15MinorUnits
    public let currentBalanceMinor: V15MinorUnits; public let creditLimitMinor: V15MinorUnits?
    public let statementDay: Int?; public let dueDay: Int?; public let cycleMode: String?
    public let openingBalanceAsOfDate: String?; public let openingDueDate: String?; public let sortOrder: Int
    public let archivedAt: Date?; public let usageCount: Int; public let version: Int; public let createdAt: Date; public let updatedAt: Date
    enum CodingKeys: String, CodingKey { case id, name, kind, institution; case lastFour = "last_four", openingBalanceMinor = "opening_balance_minor", currentBalanceMinor = "current_balance_minor", creditLimitMinor = "credit_limit_minor", statementDay = "statement_day", dueDay = "due_day", cycleMode = "cycle_mode", openingBalanceAsOfDate = "opening_balance_as_of_date", openingDueDate = "opening_due_date", sortOrder = "sort_order", archivedAt = "archived_at", usageCount = "usage_count", version, createdAt = "created_at", updatedAt = "updated_at" }
    public var isActive: Bool { archivedAt == nil }
}

public struct V15AccountDraft: Codable, Sendable, Equatable {
    public let name: String; public let kind: V15AccountKind; public let institution: String?; public let lastFour: String?; public let openingBalanceMinor: V15MinorUnits; public let creditLimitMinor: V15MinorUnits?; public let statementDay: Int?; public let dueDay: Int?; public let cycleMode: String?; public let openingBalanceAsOfDate: String?; public let openingDueDate: String?
    public init(name: String, kind: V15AccountKind, institution: String? = nil, lastFour: String? = nil, openingBalanceMinor: V15MinorUnits = 0, creditLimitMinor: V15MinorUnits? = nil, statementDay: Int? = nil, dueDay: Int? = nil, cycleMode: String? = nil, openingBalanceAsOfDate: String? = nil, openingDueDate: String? = nil) { self.name = name; self.kind = kind; self.institution = institution; self.lastFour = lastFour; self.openingBalanceMinor = openingBalanceMinor; self.creditLimitMinor = creditLimitMinor; self.statementDay = statementDay; self.dueDay = dueDay; self.cycleMode = cycleMode; self.openingBalanceAsOfDate = openingBalanceAsOfDate; self.openingDueDate = openingDueDate }
    enum CodingKeys: String, CodingKey { case name, kind, institution; case lastFour = "last_four", openingBalanceMinor = "opening_balance_minor", creditLimitMinor = "credit_limit_minor", statementDay = "statement_day", dueDay = "due_day", cycleMode = "cycle_mode", openingBalanceAsOfDate = "opening_balance_as_of_date", openingDueDate = "opening_due_date" }
}
public enum V15NullablePatchValue<Value: Encodable & Sendable>: Sendable { case omitted, value(Value), null }
public struct V15AccountPatch: Encodable, Sendable { public let expectedVersion: Int; public let name: String?; public let institution: String?; public let openingBalanceMinor: V15MinorUnits?; public let creditLimitMinor: V15MinorUnits?; public let statementDay: Int?; public let dueDay: Int?; public let cycleMode: String?; public let openingBalanceAsOfDate: V15NullablePatchValue<String>; public let openingDueDate: V15NullablePatchValue<String>; public init(expectedVersion: Int, name: String? = nil, institution: String? = nil, openingBalanceMinor: V15MinorUnits? = nil, creditLimitMinor: V15MinorUnits? = nil, statementDay: Int? = nil, dueDay: Int? = nil, cycleMode: String? = nil, openingBalanceAsOfDate: V15NullablePatchValue<String> = .omitted, openingDueDate: V15NullablePatchValue<String> = .omitted) { self.expectedVersion = expectedVersion; self.name = name; self.institution = institution; self.openingBalanceMinor = openingBalanceMinor; self.creditLimitMinor = creditLimitMinor; self.statementDay = statementDay; self.dueDay = dueDay; self.cycleMode = cycleMode; self.openingBalanceAsOfDate = openingBalanceAsOfDate; self.openingDueDate = openingDueDate }; enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version", name, institution; case openingBalanceMinor = "opening_balance_minor", creditLimitMinor = "credit_limit_minor", statementDay = "statement_day", dueDay = "due_day", cycleMode = "cycle_mode", openingBalanceAsOfDate = "opening_balance_as_of_date", openingDueDate = "opening_due_date" }; public func encode(to encoder: Encoder) throws { var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(expectedVersion, forKey: .expectedVersion); try c.encodeIfPresent(name, forKey: .name); try c.encodeIfPresent(institution, forKey: .institution); try c.encodeIfPresent(openingBalanceMinor, forKey: .openingBalanceMinor); try c.encodeIfPresent(creditLimitMinor, forKey: .creditLimitMinor); try c.encodeIfPresent(statementDay, forKey: .statementDay); try c.encodeIfPresent(dueDay, forKey: .dueDay); try c.encodeIfPresent(cycleMode, forKey: .cycleMode); try encode(openingBalanceAsOfDate, key: .openingBalanceAsOfDate, container: &c); try encode(openingDueDate, key: .openingDueDate, container: &c) }; private func encode(_ value: V15NullablePatchValue<String>, key: CodingKeys, container: inout KeyedEncodingContainer<CodingKeys>) throws { switch value { case .omitted: break; case .value(let value): try container.encode(value, forKey: key); case .null: try container.encodeNil(forKey: key) } } }
public struct V15AccountOrderState: Codable, Sendable, Equatable { public let items: [V15AccountResponse]; public let listRevision: String; enum CodingKeys: String, CodingKey { case items; case listRevision = "list_revision" } }
public struct V15OrderRequest: Codable, Sendable, Equatable { public let orderedIDs: [UUID]; public let expectedListRevision: String; public init(orderedIDs: [UUID], expectedListRevision: String) { self.orderedIDs = orderedIDs; self.expectedListRevision = expectedListRevision }; enum CodingKeys: String, CodingKey { case orderedIDs = "ordered_ids", expectedListRevision = "expected_list_revision" } }

public enum V15CategoryDirection: String, Codable, Sendable, Equatable { case income, expense, unknown
    public init(from decoder: Decoder) throws { self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown }
}
public struct V15CategoryPatch: Codable, Sendable, Equatable { public let expectedVersion: Int; public let name: String?; public let direction: String?; public let icon: String?; public let colorHex: String?; public init(expectedVersion: Int, name: String? = nil, direction: String? = nil, icon: String? = nil, colorHex: String? = nil) { self.expectedVersion = expectedVersion; self.name = name; self.direction = direction; self.icon = icon; self.colorHex = colorHex }; enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version", name, direction, icon; case colorHex = "color_hex" } }
public struct V15CategoryOrderState: Codable, Sendable, Equatable { public let parentID: UUID?; public let direction: V15CategoryDirection; public let items: [V15CategoryResponse]; public let listRevision: String; enum CodingKeys: String, CodingKey { case parentID = "parent_id", direction, items; case listRevision = "list_revision" } }
public struct V15MerchantDraft: Codable, Sendable, Equatable { public let name: String; public let aliases: [String]; public init(name: String, aliases: [String] = []) { self.name = name; self.aliases = aliases } }
public struct V15MerchantPatch: Codable, Sendable, Equatable { public let expectedVersion: Int; public let name: String?; public let aliases: [String]?; public init(expectedVersion: Int, name: String? = nil, aliases: [String]? = nil) { self.expectedVersion = expectedVersion; self.name = name; self.aliases = aliases }; enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version", name, aliases } }
public struct V15MerchantMapping: Codable, Sendable, Equatable { public let transactionID: UUID; public let merchant: V15Merchant; public let mappingVersion: Int; public let confirmedAt: Date; public let provenance: String; enum CodingKeys: String, CodingKey { case transactionID = "transaction_id", merchant; case mappingVersion = "mapping_version", confirmedAt = "confirmed_at", provenance } }
public struct V15MerchantMappingRequest: Codable, Sendable, Equatable { public let merchantID: UUID; public let expectedMappingVersion: Int?; public init(merchantID: UUID, expectedMappingVersion: Int? = nil) { self.merchantID = merchantID; self.expectedMappingVersion = expectedMappingVersion }; enum CodingKeys: String, CodingKey { case merchantID = "merchant_id", expectedMappingVersion = "expected_mapping_version" } }
public struct V15MerchantMappingReleaseRequest: Codable, Sendable, Equatable { public let expectedMappingVersion: Int; public init(expectedMappingVersion: Int) { self.expectedMappingVersion = expectedMappingVersion }; enum CodingKeys: String, CodingKey { case expectedMappingVersion = "expected_mapping_version" } }
public struct V15MerchantMappingReceipt: Codable, Sendable, Equatable { public let action: String; public let mapping: V15MerchantMapping?; public let transactionVersion: Int; enum CodingKeys: String, CodingKey { case action, mapping; case transactionVersion = "transaction_version" } }

public enum V15ManualTransactionKind: String, Codable, CaseIterable, Sendable, Equatable, Identifiable { case expense, income, transfer, creditPurchase = "credit_purchase", repayment
    public var id: String { rawValue }
    public var displayName: String { switch self { case .expense: "支出"; case .income: "收入"; case .transfer: "转账"; case .creditPurchase: "信用卡消费"; case .repayment: "还款" } }
}

/// Read filters mirror every backend `TransactionKind`; they are deliberately
/// separate from the narrower kinds permitted by manual create/replace.
public enum V15LedgerReadKind: String, Codable, CaseIterable, Sendable, Equatable, Identifiable {
    case income, expense, transfer, creditPurchase = "credit_purchase", repayment
    case installmentFee = "installment_fee", installmentRefund = "installment_refund", reimbursementReceipt = "reimbursement_receipt"
    public var id: String { rawValue }
    public var displayName: String { switch self { case .income: "收入"; case .expense: "支出"; case .transfer: "转账"; case .creditPurchase: "信用卡消费"; case .repayment: "还款"; case .installmentFee: "分期手续费"; case .installmentRefund: "分期退款"; case .reimbursementReceipt: "报销回款" } }
}

/// Read filters mirror every backend `TransactionSource`, including facts
/// generated by the system and therefore not selectable by manual entry.
public enum V15LedgerReadSource: String, Codable, CaseIterable, Sendable, Equatable, Identifiable {
    case manual, system, aiText = "ai_text", ocr, legacyImport = "legacy_import", cashFlow = "cash_flow", statementImport = "statement_import"
    public var id: String { rawValue }
    public var displayName: String { switch self { case .manual: "手工录入"; case .system: "系统生成"; case .aiText: "AI 文本"; case .ocr: "OCR"; case .legacyImport: "历史导入"; case .cashFlow: "现金流"; case .statementImport: "账单导入" } }
}

public struct V15TransactionCreateRequest: Codable, Sendable, Equatable {
    public let kind: V15ManualTransactionKind; public let amountMinor: V15MinorUnits; public let occurredAt: Date
    public let title: String; public let note: String?; public let accountID: UUID?; public let categoryID: UUID?
    public let destinationAccountID: UUID?; public let creditCycleID: UUID?
    public init(kind: V15ManualTransactionKind, amountMinor: V15MinorUnits, occurredAt: Date, title: String, note: String? = nil, accountID: UUID? = nil, categoryID: UUID? = nil, destinationAccountID: UUID? = nil, creditCycleID: UUID? = nil) { self.kind = kind; self.amountMinor = amountMinor; self.occurredAt = occurredAt; self.title = title; self.note = note; self.accountID = accountID; self.categoryID = categoryID; self.destinationAccountID = destinationAccountID; self.creditCycleID = creditCycleID }
    enum CodingKeys: String, CodingKey { case kind, title, note; case amountMinor = "amount_minor", occurredAt = "occurred_at", accountID = "account_id", categoryID = "category_id", destinationAccountID = "destination_account_id", creditCycleID = "credit_cycle_id" }
}

// MARK: - F1-B ledger library and immutable history

/// The query mirrors the public `/transactions` contract.  Enum values remain
/// server strings here: an additive server value can still be queried/read,
/// while the feature presents it as an unrecognised read-only fact.
public struct V15LedgerFilter: Sendable, Equatable {
    public var cursor: String?
    public var limit: Int
    public var kind: String?
    public var accountID: UUID?
    public var categoryID: UUID?
    public var dateFrom: String?
    public var dateTo: String?
    public var query: String?
    public var includeVoided: Bool
    public var classification: String
    public var source: String?
    public var amountMinMinor: V15MinorUnits?
    public var amountMaxMinor: V15MinorUnits?
    public init(cursor: String? = nil, limit: Int = 50, kind: String? = nil, accountID: UUID? = nil, categoryID: UUID? = nil, dateFrom: String? = nil, dateTo: String? = nil, query: String? = nil, includeVoided: Bool = false, classification: String = "all", source: String? = nil, amountMinMinor: V15MinorUnits? = nil, amountMaxMinor: V15MinorUnits? = nil) {
        self.cursor = cursor; self.limit = limit; self.kind = kind; self.accountID = accountID; self.categoryID = categoryID; self.dateFrom = dateFrom; self.dateTo = dateTo; self.query = query; self.includeVoided = includeVoided; self.classification = classification; self.source = source; self.amountMinMinor = amountMinMinor; self.amountMaxMinor = amountMaxMinor
    }
}

public struct V15TransactionReplaceRequest: Codable, Sendable, Equatable {
    public let kind: V15ManualTransactionKind; public let amountMinor: V15MinorUnits; public let occurredAt: Date
    public let title: String; public let note: String?; public let accountID: UUID?; public let categoryID: UUID?
    public let destinationAccountID: UUID?; public let creditCycleID: UUID?; public let expectedVersion: Int
    public init(draft: V15TransactionCreateRequest, expectedVersion: Int) {
        kind = draft.kind; amountMinor = draft.amountMinor; occurredAt = draft.occurredAt; title = draft.title; note = draft.note; accountID = draft.accountID; categoryID = draft.categoryID; destinationAccountID = draft.destinationAccountID; creditCycleID = draft.creditCycleID; self.expectedVersion = expectedVersion
    }
    enum CodingKeys: String, CodingKey { case kind, title, note; case amountMinor = "amount_minor", occurredAt = "occurred_at", accountID = "account_id", categoryID = "category_id", destinationAccountID = "destination_account_id", creditCycleID = "credit_cycle_id", expectedVersion = "expected_version" }
}

public struct V15TransactionVersionRequest: Codable, Sendable, Equatable { public let expectedVersion: Int; public init(expectedVersion: Int) { self.expectedVersion = expectedVersion }; enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version" } }

public struct V15TransactionRevision: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID; public let version: Int; public let event: String; public let snapshot: JSONValue; public let createdAt: Date
    enum CodingKeys: String, CodingKey { case id, version, event, snapshot; case createdAt = "created_at" }
}

public struct V15TransactionRevisionPage: Codable, Sendable, Equatable { public let items: [V15TransactionRevision]; public let nextCursor: String?; enum CodingKeys: String, CodingKey { case items; case nextCursor = "next_cursor" } }

public struct V15TransactionProvenanceLink: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(sourceType):\(targetType):\(targetID?.uuidString ?? "none"): \(recordedAt.timeIntervalSince1970)" }
    public let sourceType: String; public let targetType: String; public let targetID: UUID?; public let deepLink: String?; public let recordedAt: Date
    enum CodingKeys: String, CodingKey { case sourceType = "source_type", targetType = "target_type", targetID = "target_id", deepLink = "deep_link", recordedAt = "recorded_at" }
}

public struct V15TransactionProvenance: Codable, Sendable, Equatable { public let transactionID: UUID; public let source: String; public let links: [V15TransactionProvenanceLink]; enum CodingKeys: String, CodingKey { case transactionID = "transaction_id", source, links } }

/// Read-only F1-A repayment selection. The backend exposes business dates as
/// ISO date strings, not instants; preserving that distinction avoids a
/// device-timezone conversion when presenting a cycle to the user.
public enum V15CreditCycleStatus: String, Codable, Sendable, Equatable { case open, unpaid, partial, overdue, settled, unknown
    public init(from decoder: Decoder) throws { self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown }
}

public enum V15InstallmentPeriodStatus: String, Codable, Sendable, Equatable { case scheduled, billed, partial, cycleSettled = "cycle_settled", overdue, cancelled, settledEarly = "settled_early", unknown
    public init(from decoder: Decoder) throws { self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown }
}

/// P33 nests these records in a credit-cycle read.  They remain read facts;
/// lifecycle editing belongs exclusively to F3-B2.
public struct V15CreditCycleInstallmentPeriod: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID; public let planID: UUID; public let sequence: Int; public let scheduledCycleID: UUID; public let effectiveCycleID: UUID
    public let scheduledStatementDate: String; public let effectiveStatementDate: String; public let dueDate: String
    public let principalMinor: V15MinorUnits; public let feeMinor: V15MinorUnits; public let amountDueMinor: V15MinorUnits
    public let locked: Bool; public let status: V15InstallmentPeriodStatus; public let cycleStatus: V15CreditCycleStatus
    public let cancelledAt: Date?; public let settledEarlyAt: Date?; public let version: Int; public let createdAt: Date; public let updatedAt: Date
    enum CodingKeys: String, CodingKey { case id, planID = "plan_id", sequence, scheduledCycleID = "scheduled_cycle_id", effectiveCycleID = "effective_cycle_id", scheduledStatementDate = "scheduled_statement_date", effectiveStatementDate = "effective_statement_date", dueDate = "due_date", principalMinor = "principal_minor", feeMinor = "fee_minor", amountDueMinor = "amount_due_minor", locked, status, cycleStatus = "cycle_status", cancelledAt = "cancelled_at", settledEarlyAt = "settled_early_at", version, createdAt = "created_at", updatedAt = "updated_at" }
}

public struct V15CreditCycle: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID; public let accountID: UUID
    public let periodStart: String; public let periodEnd: String; public let statementDate: String; public let dueDate: String
    public let isOpeningCycle: Bool; public let purchaseMinor: V15MinorUnits; public let openingMinor: V15MinorUnits; public let amountDueMinor: V15MinorUnits; public let repaidMinor: V15MinorUnits; public let remainingMinor: V15MinorUnits
    public let status: V15CreditCycleStatus; public let isOverdue: Bool; public let version: Int; public let createdAt: Date; public let updatedAt: Date
    public let installmentPrincipalMinor: V15MinorUnits; public let installmentFeeMinor: V15MinorUnits; public let installmentPeriods: [V15CreditCycleInstallmentPeriod]
    enum CodingKeys: String, CodingKey { case id, accountID = "account_id", periodStart = "period_start", periodEnd = "period_end", statementDate = "statement_date", dueDate = "due_date", isOpeningCycle = "is_opening_cycle", purchaseMinor = "purchase_minor", openingMinor = "opening_minor", amountDueMinor = "amount_due_minor", repaidMinor = "repaid_minor", remainingMinor = "remaining_minor", status, isOverdue = "is_overdue", version, createdAt = "created_at", updatedAt = "updated_at", installmentPrincipalMinor = "installment_principal_minor", installmentFeeMinor = "installment_fee_minor", installmentPeriods = "installment_periods" }
}

public struct V15CreditCyclePage: Codable, Sendable, Equatable {
    public let items: [V15CreditCycle]; public let nextCursor: String?
    enum CodingKeys: String, CodingKey { case items, nextCursor = "next_cursor" }
}

public struct V15CreditAccountSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID { accountID }
    public let accountID: UUID; public let name: String; public let institution: String?; public let lastFour: String?
    public let creditLimitMinor: V15MinorUnits; public let currentDebtMinor: V15MinorUnits; public let availableCreditMinor: V15MinorUnits; public let overLimitMinor: V15MinorUnits
    public let openingConfigurationRequired: Bool; public let statementDay: Int; public let dueDay: Int; public let cycleMode: V15CreditCycleMode
    public let currentCycle: V15CreditCycle; public let nextDueCycle: V15CreditCycle?; public let hasOverdueCycle: Bool
    public let activeInstallmentCount: Int; public let futureScheduledGrossMinor: V15MinorUnits
    /// This is a read-only P33 teaser. Installment lifecycle mutations remain
    /// owned by F3-B2; retaining it here prevents silently dropping a server
    /// field from the credit account contract.
    public let nextInstallment: V15CreditAccountInstallmentTeaser?
    enum CodingKeys: String, CodingKey { case accountID = "account_id", name, institution, lastFour = "last_four", creditLimitMinor = "credit_limit_minor", currentDebtMinor = "current_debt_minor", availableCreditMinor = "available_credit_minor", overLimitMinor = "over_limit_minor", openingConfigurationRequired = "opening_configuration_required", statementDay = "statement_day", dueDay = "due_day", cycleMode = "cycle_mode", currentCycle = "current_cycle", nextDueCycle = "next_due_cycle", hasOverdueCycle = "has_overdue_cycle", activeInstallmentCount = "active_installment_count", futureScheduledGrossMinor = "future_scheduled_gross_minor", nextInstallment = "next_installment" }
}

public struct V15CreditAccountInstallmentTeaser: Codable, Sendable, Equatable {
    public let planID: UUID; public let title: String; public let status: String
    public let installmentCount: Int; public let futureCount: Int; public let futureScheduledGrossMinor: V15MinorUnits
    public let nextPeriod: V15CreditCycleInstallmentPeriod?
    enum CodingKeys: String, CodingKey { case planID = "plan_id", title, status, installmentCount = "installment_count", futureCount = "future_count", futureScheduledGrossMinor = "future_scheduled_gross_minor", nextPeriod = "next_period" }
}
public struct V15ReimbursementAllocation: Codable, Sendable, Equatable { public let id: UUID; public let transactionID: UUID; public let expenseTitle: String; public let expenseAmountMinor: V15MinorUnits; public let amountMinor: V15MinorUnits; public let receivedMinor: V15MinorUnits; public let outstandingMinor: V15MinorUnits; public let locked: Bool; public let position: Int; enum CodingKeys: String, CodingKey { case id, transactionID = "transaction_id", expenseTitle = "expense_title", expenseAmountMinor = "expense_amount_minor", amountMinor = "amount_minor", receivedMinor = "received_minor", outstandingMinor = "outstanding_minor", locked, position } }
public struct V15ReimbursementParty: Codable, Sendable, Equatable { public let id: UUID; public let name: String; public let expectedDate: String?; public let note: String?; public let claimedMinor: V15MinorUnits; public let receivedMinor: V15MinorUnits; public let outstandingMinor: V15MinorUnits; public let status: String; public let position: Int; public let allocations: [V15ReimbursementAllocation]; enum CodingKeys: String, CodingKey { case id, name, expectedDate = "expected_date", note, claimedMinor = "claimed_minor", receivedMinor = "received_minor", outstandingMinor = "outstanding_minor", status, position, allocations } }
public struct V15ReimbursementReceiptAllocation: Codable, Sendable, Equatable { public let id: UUID; public let allocationID: UUID; public let amountMinor: V15MinorUnits; public let position: Int; enum CodingKeys: String, CodingKey { case id, allocationID = "allocation_id", amountMinor = "amount_minor", position } }
public struct V15ReimbursementReceipt: Codable, Sendable, Equatable { public let id: UUID; public let claimID: UUID; public let partyID: UUID; public let amountMinor: V15MinorUnits; public let receivedAt: Date; public let destinationAccountID: UUID; public let title: String; public let note: String?; public let transaction: V15Transaction; public let allocations: [V15ReimbursementReceiptAllocation]; public let version: Int; public let voidedAt: Date?; public let createdAt: Date; public let updatedAt: Date; enum CodingKeys: String, CodingKey { case id, claimID = "claim_id", partyID = "party_id", amountMinor = "amount_minor", receivedAt = "received_at", destinationAccountID = "destination_account_id", title, note, transaction, allocations, version, voidedAt = "voided_at", createdAt = "created_at", updatedAt = "updated_at" } }
public enum V15ReimbursementClaimStatus: Sendable, Equatable, Hashable, Codable {
    case draft, pending, partialReceived, received, cancelled, partiallyReceivedCancelled, unknown(String)
    public init(from decoder: Decoder) throws { let value = try decoder.singleValueContainer().decode(String.self); switch value { case "draft": self = .draft; case "pending": self = .pending; case "partial_received": self = .partialReceived; case "received": self = .received; case "cancelled": self = .cancelled; case "partially_received_cancelled": self = .partiallyReceivedCancelled; default: self = .unknown(value) } }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public var rawValue: String { switch self { case .draft: "draft"; case .pending: "pending"; case .partialReceived: "partial_received"; case .received: "received"; case .cancelled: "cancelled"; case .partiallyReceivedCancelled: "partially_received_cancelled"; case .unknown(let value): value } }
    public var displayName: String { switch self { case .draft: "草稿"; case .pending: "待到账"; case .partialReceived: "部分到账"; case .received: "已到账"; case .cancelled: "已取消"; case .partiallyReceivedCancelled: "部分到账后取消"; case .unknown(let value): "未知状态（\(value)）" } }
    public var isKnown: Bool { if case .unknown = self { false } else { true } }
}
public struct V15ReimbursementClaim: Codable, Sendable, Equatable { public let id: UUID; public let title: String; public let note: String?; public let status: V15ReimbursementClaimStatus; public let totalClaimedMinor: V15MinorUnits; public let receivedMinor: V15MinorUnits; public let outstandingMinor: V15MinorUnits; public let expenseCount: Int; public let partyCount: Int; public let receiptCount: Int; public let parties: [V15ReimbursementParty]; public let latestReceipt: V15ReimbursementReceipt?; public let version: Int; public let submittedAt: Date?; public let cancelledAt: Date?; public let voidedAt: Date?; public let archivedAt: Date?; public let createdAt: Date; public let updatedAt: Date; enum CodingKeys: String, CodingKey { case id, title, note, status, totalClaimedMinor = "total_claimed_minor", receivedMinor = "received_minor", outstandingMinor = "outstanding_minor", expenseCount = "expense_count", partyCount = "party_count", receiptCount = "receipt_count", parties, latestReceipt = "latest_receipt", version, submittedAt = "submitted_at", cancelledAt = "cancelled_at", voidedAt = "voided_at", archivedAt = "archived_at", createdAt = "created_at", updatedAt = "updated_at" } }
public struct V15ReimbursementClaimPreview: Codable, Sendable { public let previewToken: UUID; public let inputDigest: String; public let claimVersion: Int; public let receiptVersion: Int?; public let current: V15ReimbursementClaim; public let proposed: V15ReimbursementClaim; public let releasedMinor: V15MinorUnits; public let newlyClaimedMinor: V15MinorUnits; public let warnings: [String]; enum CodingKeys: String, CodingKey { case previewToken = "preview_token", inputDigest = "input_digest", claimVersion = "claim_version", receiptVersion = "receipt_version", current, proposed, releasedMinor = "released_minor", newlyClaimedMinor = "newly_claimed_minor", warnings } }
public struct V15ReimbursementCancelPreview: Codable, Sendable { public let previewToken: UUID; public let inputDigest: String; public let claimVersion: Int; public let receiptVersion: Int?; public let current: V15ReimbursementClaim; public let proposedStatus: String; public let releasedMinor: V15MinorUnits; public let retainedReceivedMinor: V15MinorUnits; enum CodingKeys: String, CodingKey { case previewToken = "preview_token", inputDigest = "input_digest", claimVersion = "claim_version", receiptVersion = "receipt_version", current, proposedStatus = "proposed_status", releasedMinor = "released_minor", retainedReceivedMinor = "retained_received_minor" } }
public struct V15ReimbursementReceiptPreview: Codable, Sendable { public let previewToken: UUID; public let inputDigest: String; public let claimVersion: Int; public let receiptVersion: Int?; public let claimBefore: V15ReimbursementClaim; public let claimAfter: V15ReimbursementClaim; public let partyID: UUID; public let amountMinor: V15MinorUnits; public let partyReceivedBeforeMinor: V15MinorUnits; public let partyReceivedAfterMinor: V15MinorUnits; public let claimReceivedBeforeMinor: V15MinorUnits; public let claimReceivedAfterMinor: V15MinorUnits; public let persistedAllocations: [V15ReimbursementReceiptAllocation]; enum CodingKeys: String, CodingKey { case previewToken = "preview_token", inputDigest = "input_digest", claimVersion = "claim_version", receiptVersion = "receipt_version", claimBefore = "claim_before", claimAfter = "claim_after", partyID = "party_id", amountMinor = "amount_minor", partyReceivedBeforeMinor = "party_received_before_minor", partyReceivedAfterMinor = "party_received_after_minor", claimReceivedBeforeMinor = "claim_received_before_minor", claimReceivedAfterMinor = "claim_received_after_minor", persistedAllocations = "persisted_allocations" } }
