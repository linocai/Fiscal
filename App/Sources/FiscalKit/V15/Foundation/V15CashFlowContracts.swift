import Foundation

// MARK: - F3-D cash-flow read facts

public enum V15CashFlowDirection: Sendable, Equatable, Hashable, Codable, Identifiable {
    case inflow, outflow, transfer, unknown(String)

    public var id: String { rawValue }
    public init(from decoder: Decoder) throws { self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public init(rawValue: String) { switch rawValue { case "inflow": self = .inflow; case "outflow": self = .outflow; case "transfer": self = .transfer; default: self = .unknown(rawValue) } }
    public var rawValue: String { switch self { case .inflow: "inflow"; case .outflow: "outflow"; case .transfer: "transfer"; case .unknown(let value): value } }
    public var displayName: String { switch self { case .inflow: "流入"; case .outflow: "流出"; case .transfer: "转账"; case .unknown(let value): "未知方向（\(value)）" } }
    public var isActionable: Bool { if case .unknown = self { false } else { true } }
}

public enum V15CashFlowStatus: Sendable, Equatable, Hashable, Codable {
    case expected, confirmed, settled, cancelled, completed, unknown(String)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value { case "expected": self = .expected; case "confirmed": self = .confirmed; case "settled": self = .settled; case "cancelled": self = .cancelled; case "completed": self = .completed; default: self = .unknown(value) }
    }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public var rawValue: String { switch self { case .expected: "expected"; case .confirmed: "confirmed"; case .settled: "settled"; case .cancelled: "cancelled"; case .completed: "completed"; case .unknown(let value): value } }
    public var displayName: String { switch self { case .expected: "预计"; case .confirmed: "已确认"; case .settled: "已入账"; case .cancelled: "已取消"; case .completed: "已完成"; case .unknown(let value): "未知状态（\(value)）" } }
    public var isKnown: Bool { if case .unknown = self { false } else { true } }
}

public enum V15CashFlowMutationScope: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    case occurrence
    case thisAndFuture = "this_and_future"
    public var id: String { rawValue }
    public var displayName: String { self == .occurrence ? "仅本次" : "本次及以后" }
}

public enum V15CashFlowSystemKind: String, Codable, Sendable, Equatable {
    case creditCycle = "credit_cycle"
    case reimbursement
}

public enum V15CashFlowAction: Sendable, Equatable, Hashable, Codable {
    case confirm, settle, edit, cancel, confirmRepayment, markReceived, unknown(String)
    public init(from decoder: Decoder) throws { let value = try decoder.singleValueContainer().decode(String.self); switch value { case "confirm": self = .confirm; case "settle": self = .settle; case "edit": self = .edit; case "cancel": self = .cancel; case "confirm_repayment": self = .confirmRepayment; case "mark_received": self = .markReceived; default: self = .unknown(value) } }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public var rawValue: String { switch self { case .confirm: "confirm"; case .settle: "settle"; case .edit: "edit"; case .cancel: "cancel"; case .confirmRepayment: "confirm_repayment"; case .markReceived: "mark_received"; case .unknown(let value): value } }
}

public struct V15CashFlowCreditCyclePart: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID { cycleID }
    public let cycleID: UUID
    public let remainingMinor: V15MinorUnits
    public let periodStart: String
    public let periodEnd: String
    public let statementDate: String
    public let dueDate: String
    enum CodingKeys: String, CodingKey { case cycleID = "cycle_id", remainingMinor = "remaining_minor", periodStart = "period_start", periodEnd = "period_end", statementDate = "statement_date", dueDate = "due_date" }
}

public struct V15CashFlowItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let manualItemID: UUID?
    public let systemKind: V15CashFlowSystemKind?
    public let systemReferenceID: UUID?
    public let seriesID: UUID?
    public let title: String
    public let note: String?
    public let direction: V15CashFlowDirection
    public let plannedAmountMinor: V15MinorUnits
    public let expectedDate: String
    public let accountID: UUID?
    public let destinationAccountID: UUID?
    public let categoryID: UUID?
    public let status: V15CashFlowStatus
    public let source: String
    public let version: Int
    public let linkedTransactionID: UUID?
    public let actualAmountMinor: V15MinorUnits?
    public let actualDate: String?
    public let isOverdue: Bool
    public let actions: [V15CashFlowAction]
    public let creditCycleParts: [V15CashFlowCreditCyclePart]
    public let createdAt: Date?
    public let updatedAt: Date?

    public var isSystem: Bool { systemKind != nil }
    public var isDisplayOnly: Bool { !status.isKnown || !direction.isActionable }
    public func allows(_ action: V15CashFlowAction) -> Bool { actions.contains(action) && !isDisplayOnly }

    enum CodingKeys: String, CodingKey {
        case id, title, note, direction, status, source, version, actions
        case manualItemID = "manual_item_id", systemKind = "system_kind", systemReferenceID = "system_reference_id", seriesID = "series_id"
        case plannedAmountMinor = "planned_amount_minor", expectedDate = "expected_date", accountID = "account_id", destinationAccountID = "destination_account_id", categoryID = "category_id"
        case linkedTransactionID = "linked_transaction_id", actualAmountMinor = "actual_amount_minor", actualDate = "actual_date", isOverdue = "is_overdue", creditCycleParts = "credit_cycle_parts", createdAt = "created_at", updatedAt = "updated_at"
    }
}

public struct V15CashFlowSummary: Codable, Sendable, Equatable {
    public let dateFrom: String
    public let dateTo: String
    public let inflowMinor: V15MinorUnits
    public let outflowMinor: V15MinorUnits
    public let netMinor: V15MinorUnits
    enum CodingKeys: String, CodingKey { case dateFrom = "date_from", dateTo = "date_to", inflowMinor = "inflow_minor", outflowMinor = "outflow_minor", netMinor = "net_minor" }
}

public struct V15CashFlowActiveResponse: Codable, Sendable, Equatable { public let summary: V15CashFlowSummary; public let items: [V15CashFlowItem] }
public struct V15CashFlowHistoryResponse: Codable, Sendable, Equatable { public let month: String; public let items: [V15CashFlowItem] }
public struct V15CashFlowCreateResponse: Codable, Sendable, Equatable { public let items: [V15CashFlowItem] }

// MARK: - F3-D endpoint-shaped writes

public struct V15CashFlowDraft: Codable, Sendable, Equatable {
    public let title: String
    public let note: String?
    public let direction: V15CashFlowDirection
    public let plannedAmountMinor: V15MinorUnits
    public let expectedDate: String
    public let accountID: UUID?
    public let destinationAccountID: UUID?
    public let categoryID: UUID?
    public let recurrence: String?
    public let recurrenceEndDate: String?
    public init(title: String, note: String? = nil, direction: V15CashFlowDirection, plannedAmountMinor: V15MinorUnits, expectedDate: String, accountID: UUID? = nil, destinationAccountID: UUID? = nil, categoryID: UUID? = nil, recurrence: String? = nil, recurrenceEndDate: String? = nil) { self.title = title; self.note = note; self.direction = direction; self.plannedAmountMinor = plannedAmountMinor; self.expectedDate = expectedDate; self.accountID = accountID; self.destinationAccountID = destinationAccountID; self.categoryID = categoryID; self.recurrence = recurrence; self.recurrenceEndDate = recurrenceEndDate }
    enum CodingKeys: String, CodingKey { case title, note, direction, recurrence; case plannedAmountMinor = "planned_amount_minor", expectedDate = "expected_date", accountID = "account_id", destinationAccountID = "destination_account_id", categoryID = "category_id", recurrenceEndDate = "recurrence_end_date" }
}

public struct V15CashFlowReplace: Codable, Sendable, Equatable {
    public let title: String; public let note: String?; public let direction: V15CashFlowDirection; public let plannedAmountMinor: V15MinorUnits; public let expectedDate: String; public let accountID: UUID?; public let destinationAccountID: UUID?; public let categoryID: UUID?; public let expectedVersion: Int; public let scope: V15CashFlowMutationScope
    public init(draft: V15CashFlowDraft, expectedVersion: Int, scope: V15CashFlowMutationScope) { title = draft.title; note = draft.note; direction = draft.direction; plannedAmountMinor = draft.plannedAmountMinor; expectedDate = draft.expectedDate; accountID = draft.accountID; destinationAccountID = draft.destinationAccountID; categoryID = draft.categoryID; self.expectedVersion = expectedVersion; self.scope = scope }
    enum CodingKeys: String, CodingKey { case title, note, direction, scope; case plannedAmountMinor = "planned_amount_minor", expectedDate = "expected_date", accountID = "account_id", destinationAccountID = "destination_account_id", categoryID = "category_id", expectedVersion = "expected_version" }
}

public struct V15CashFlowVersionRequest: Codable, Sendable, Equatable { public let expectedVersion: Int; public let scope: V15CashFlowMutationScope; public init(expectedVersion: Int, scope: V15CashFlowMutationScope = .occurrence) { self.expectedVersion = expectedVersion; self.scope = scope }; enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version", scope } }

public struct V15CashFlowSettlementDraft: Codable, Sendable, Equatable {
    public let expectedVersion: Int; public let actualAmountMinor: V15MinorUnits; public let occurredAt: Date; public let accountID: UUID; public let destinationAccountID: UUID?; public let categoryID: UUID?; public let title: String?; public let note: String?
    public init(expectedVersion: Int, actualAmountMinor: V15MinorUnits, occurredAt: Date, accountID: UUID, destinationAccountID: UUID? = nil, categoryID: UUID? = nil, title: String? = nil, note: String? = nil) { self.expectedVersion = expectedVersion; self.actualAmountMinor = actualAmountMinor; self.occurredAt = occurredAt; self.accountID = accountID; self.destinationAccountID = destinationAccountID; self.categoryID = categoryID; self.title = title; self.note = note }
    enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version", actualAmountMinor = "actual_amount_minor", occurredAt = "occurred_at", accountID = "account_id", destinationAccountID = "destination_account_id", categoryID = "category_id", title, note }
}

public struct V15CashFlowSystemReplace: Codable, Sendable, Equatable {
    public let title: String; public let note: String?; public let expectedDate: String; public let status: V15CashFlowStatus; public let expectedVersion: Int
    public init(title: String, note: String?, expectedDate: String, status: V15CashFlowStatus, expectedVersion: Int) { self.title = title; self.note = note; self.expectedDate = expectedDate; self.status = status; self.expectedVersion = expectedVersion }
    enum CodingKeys: String, CodingKey { case title, note, status; case expectedDate = "expected_date", expectedVersion = "expected_version" }
}

// MARK: - Typed transport surface

public struct V15CashFlowService: Sendable {
    private let transport: any V15Transporting
    private let writable: @MainActor @Sendable () throws -> Void
    init(transport: any V15Transporting, writable: @escaping @MainActor @Sendable () throws -> Void) { self.transport = transport; self.writable = writable }

    public func active(accountID: UUID? = nil, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15CashFlowActiveResponse { var query: [URLQueryItem] = []; if let accountID { query.append(.init(name: "account_id", value: accountID.uuidString)) }; return try await transport.send(.init(path: "cash-flow-items", query: query, readCachePolicy: readCachePolicy), body: nil) }
    public func history(month: String? = nil, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15CashFlowHistoryResponse { var query: [URLQueryItem] = []; if let month { guard month.range(of: "^[0-9]{4}-(0[1-9]|1[0-2])$", options: .regularExpression) != nil else { throw V15Failure(kind: .decoding, code: "invalid_cash_flow_month", message: "月份必须使用 YYYY-MM。") }; query.append(.init(name: "month", value: month)) }; return try await transport.send(.init(path: "cash-flow-items/history", query: query, readCachePolicy: readCachePolicy), body: nil) }
    public func item(id: UUID, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15CashFlowItem { try await transport.send(.init(path: "cash-flow-items/\(id)", readCachePolicy: readCachePolicy), body: nil) }
    public func create(_ request: V15CashFlowDraft, idempotencyKey: UUID) async throws -> V15CashFlowCreateResponse { try await writable(); return try await transport.send(.init(path: "cash-flow-items", method: "POST", headers: ["Idempotency-Key": idempotencyKey.uuidString]), body: try V15BodyEncoder.encode(request)) }
    public func update(itemID: UUID, request: V15CashFlowReplace) async throws -> V15CashFlowCreateResponse { try await writable(); return try await transport.send(.init(path: "cash-flow-items/\(itemID)", method: "PUT"), body: try V15BodyEncoder.encode(request)) }
    public func updateSystem(kind: V15CashFlowSystemKind, referenceID: UUID, request: V15CashFlowSystemReplace) async throws -> V15CashFlowItem { try await writable(); return try await transport.send(.init(path: "cash-flow-system-items/\(kind.rawValue)/\(referenceID)", method: "PUT"), body: try V15BodyEncoder.encode(request)) }
    public func confirm(itemID: UUID, request: V15CashFlowVersionRequest) async throws -> V15CashFlowItem { try await writable(); return try await transport.send(.init(path: "cash-flow-items/\(itemID)/confirm", method: "POST"), body: try V15BodyEncoder.encode(request)) }
    public func cancel(itemID: UUID, request: V15CashFlowVersionRequest) async throws -> V15CashFlowCreateResponse { try await writable(); return try await transport.send(.init(path: "cash-flow-items/\(itemID)/cancel", method: "POST"), body: try V15BodyEncoder.encode(request)) }
    public func settle(itemID: UUID, request: V15CashFlowSettlementDraft, idempotencyKey: UUID) async throws -> V15CashFlowItem { try await writable(); return try await transport.send(.init(path: "cash-flow-items/\(itemID)/settle", method: "POST", headers: ["Idempotency-Key": idempotencyKey.uuidString]), body: try V15BodyEncoder.encode(request)) }
}
