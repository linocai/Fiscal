import Foundation

public enum FutureCashFlowDirection: String, Codable, Sendable, CaseIterable, Identifiable {
  case inflow, outflow, transfer
  public var id: Self { self }
  public var title: String { switch self { case .inflow: "进账"; case .outflow: "出账"; case .transfer: "转账" } }
  public var symbol: String { switch self { case .inflow: "arrow.down.left"; case .outflow: "arrow.up.right"; case .transfer: "arrow.left.arrow.right" } }
}

public enum FutureCashFlowStatus: String, Codable, Sendable {
  case expected, confirmed, settled, cancelled, completed
  public var title: String { switch self { case .expected: "预计"; case .confirmed: "已确认"; case .settled: "已入账"; case .cancelled: "已取消"; case .completed: "已完成" } }
}

public enum FutureCashFlowAction: String, Codable, Sendable {
  case confirm, settle, edit, cancel
  case confirmRepayment = "confirm_repayment"
  case markReceived = "mark_received"
}

public enum FutureCashFlowSystemKind: String, Codable, Sendable {
  case creditCycle = "credit_cycle"
  case reimbursement
}

public enum FutureCashFlowRecurrence: String, Codable, Sendable { case monthly }
public enum FutureCashFlowMutationScope: String, Codable, Sendable { case occurrence; case thisAndFuture = "this_and_future" }

public struct FutureCashFlowSummary: Codable, Sendable, Equatable {
  public let dateFrom: String
  public let dateTo: String
  public let inflowMinor: Int64
  public let outflowMinor: Int64
  public let netMinor: Int64
  enum CodingKeys: String, CodingKey {
    case dateFrom = "date_from"; case dateTo = "date_to"
    case inflowMinor = "inflow_minor"; case outflowMinor = "outflow_minor"; case netMinor = "net_minor"
  }
}

public struct FutureCashFlowCreditCyclePart: Codable, Sendable, Equatable, Identifiable {
  public var id: UUID { cycleID }
  public let cycleID: UUID
  public let remainingMinor: Int64
  public let periodStart: String
  public let periodEnd: String
  public let statementDate: String
  public let dueDate: String
  enum CodingKeys: String, CodingKey {
    case cycleID = "cycle_id"; case remainingMinor = "remaining_minor"
    case periodStart = "period_start"; case periodEnd = "period_end"
    case statementDate = "statement_date"; case dueDate = "due_date"
  }
}

public struct FutureCashFlowItem: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let manualItemID: UUID?
  public let systemKind: FutureCashFlowSystemKind?
  public let systemReferenceID: UUID?
  public let seriesID: UUID?
  public let title: String
  public let note: String?
  public let direction: FutureCashFlowDirection
  public let plannedAmountMinor: Int64
  public let expectedDate: String
  public let accountID: UUID?
  public let destinationAccountID: UUID?
  public let categoryID: UUID?
  public let status: FutureCashFlowStatus
  public let source: String
  public let version: Int
  public let linkedTransactionID: UUID?
  public let actualAmountMinor: Int64?
  public let actualDate: String?
  public let isOverdue: Bool
  public let actions: [FutureCashFlowAction]
  public var creditCycleParts: [FutureCashFlowCreditCyclePart] = []
  public let createdAt: Date?
  public let updatedAt: Date?
  enum CodingKeys: String, CodingKey {
    case id, title, note, direction, status, source, version, actions
    case creditCycleParts = "credit_cycle_parts"
    case manualItemID = "manual_item_id"; case systemKind = "system_kind"
    case systemReferenceID = "system_reference_id"; case seriesID = "series_id"
    case plannedAmountMinor = "planned_amount_minor"; case expectedDate = "expected_date"
    case accountID = "account_id"; case destinationAccountID = "destination_account_id"
    case categoryID = "category_id"; case linkedTransactionID = "linked_transaction_id"
    case actualAmountMinor = "actual_amount_minor"; case actualDate = "actual_date"
    case isOverdue = "is_overdue"; case createdAt = "created_at"; case updatedAt = "updated_at"
  }
}

public struct FutureCashFlowActive: Codable, Sendable, Equatable {
  public let summary: FutureCashFlowSummary
  public let items: [FutureCashFlowItem]
}

public struct FutureCashFlowHistory: Codable, Sendable, Equatable {
  public let month: String
  public let items: [FutureCashFlowItem]
}

public struct FutureCashFlowCreateResponse: Codable, Sendable, Equatable {
  public let items: [FutureCashFlowItem]
}

public struct FutureCashFlowDraft: Codable, Sendable, Equatable {
  public var title: String
  public var note: String?
  public var direction: FutureCashFlowDirection
  public var plannedAmountMinor: Int64
  public var expectedDate: String
  public var accountID: UUID?
  public var destinationAccountID: UUID?
  public var categoryID: UUID?
  public var recurrence: FutureCashFlowRecurrence?
  public var recurrenceEndDate: String?
  public init(
    title: String, note: String? = nil, direction: FutureCashFlowDirection,
    plannedAmountMinor: Int64, expectedDate: String, accountID: UUID? = nil,
    destinationAccountID: UUID? = nil, categoryID: UUID? = nil,
    recurrence: FutureCashFlowRecurrence? = nil, recurrenceEndDate: String? = nil
  ) {
    self.title = title; self.note = note; self.direction = direction
    self.plannedAmountMinor = plannedAmountMinor; self.expectedDate = expectedDate
    self.accountID = accountID; self.destinationAccountID = destinationAccountID
    self.categoryID = categoryID; self.recurrence = recurrence
    self.recurrenceEndDate = recurrenceEndDate
  }
  enum CodingKeys: String, CodingKey {
    case title, note, direction, recurrence
    case plannedAmountMinor = "planned_amount_minor"; case expectedDate = "expected_date"
    case accountID = "account_id"; case destinationAccountID = "destination_account_id"
    case categoryID = "category_id"; case recurrenceEndDate = "recurrence_end_date"
  }
}

public struct FutureCashFlowReplace: Encodable, Sendable {
  public let draft: FutureCashFlowDraft
  public let expectedVersion: Int
  public let scope: FutureCashFlowMutationScope
  enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version", scope }
  public init(draft: FutureCashFlowDraft, expectedVersion: Int, scope: FutureCashFlowMutationScope) {
    self.draft = draft; self.expectedVersion = expectedVersion; self.scope = scope
  }
  public func encode(to encoder: Encoder) throws {
    try draft.encode(to: encoder)
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(expectedVersion, forKey: .expectedVersion)
    try container.encode(scope, forKey: .scope)
  }
}

public struct FutureCashFlowVersionRequest: Codable, Sendable {
  public let expectedVersion: Int
  public let scope: FutureCashFlowMutationScope
  enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version", scope }
  public init(version: Int, scope: FutureCashFlowMutationScope = .occurrence) {
    expectedVersion = version; self.scope = scope
  }
}

public struct FutureCashFlowSettlement: Codable, Sendable {
  public let expectedVersion: Int
  public let actualAmountMinor: Int64
  public let occurredAt: Date
  public let accountID: UUID
  public let destinationAccountID: UUID?
  public let categoryID: UUID?
  public let title: String?
  public let note: String?
  enum CodingKeys: String, CodingKey {
    case expectedVersion = "expected_version"; case actualAmountMinor = "actual_amount_minor"
    case occurredAt = "occurred_at"; case accountID = "account_id"
    case destinationAccountID = "destination_account_id"; case categoryID = "category_id"
    case title, note
  }
  public init(
    version: Int, amountMinor: Int64, occurredAt: Date, accountID: UUID,
    destinationAccountID: UUID?, categoryID: UUID?, title: String? = nil, note: String? = nil
  ) {
    expectedVersion = version; actualAmountMinor = amountMinor; self.occurredAt = occurredAt
    self.accountID = accountID; self.destinationAccountID = destinationAccountID
    self.categoryID = categoryID; self.title = title; self.note = note
  }
}

public struct FutureCashFlowSystemReplace: Codable, Sendable {
  public let title: String
  public let note: String?
  public let plannedAmountMinor: Int64
  public let expectedDate: String
  public let status: FutureCashFlowStatus
  public let expectedVersion: Int
  enum CodingKeys: String, CodingKey {
    case title, note, status
    case plannedAmountMinor = "planned_amount_minor"
    case expectedDate = "expected_date"
    case expectedVersion = "expected_version"
  }
}
