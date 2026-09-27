import Foundation

// MARK: - F3-F AI proposal wire facts

/// Read values are forward-compatible. Unknown server values remain visible,
/// but never become writable selections or action capabilities.
public enum V15AIProposalStatus: Sendable, Equatable, Hashable, Codable {
    case processing, pending, executed, failed, ignored, undone
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = switch value {
        case "processing": .processing
        case "pending": .pending
        case "executed": .executed
        case "failed": .failed
        case "ignored": .ignored
        case "undone": .undone
        default: .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var rawValue: String {
        switch self {
        case .processing: "processing"
        case .pending: "pending"
        case .executed: "executed"
        case .failed: "failed"
        case .ignored: "ignored"
        case .undone: "undone"
        case .unknown(let value): value
        }
    }

    public var isDisplayOnly: Bool { if case .unknown = self { true } else { false } }
}

public enum V15AIProposalSource: String, Codable, Sendable, CaseIterable, Identifiable {
    case text, ocr, shortcutText = "shortcut_text"
    public var id: String { rawValue }
    public var displayName: String { switch self { case .text: "文本"; case .ocr: "OCR"; case .shortcutText: "快捷指令" } }
}

public enum V15AIProposalTarget: Sendable, Equatable, Codable {
    case transaction, cashFlow, unknown(String)
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = value == "transaction" ? .transaction : value == "cash_flow" ? .cashFlow : .unknown(value)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public var rawValue: String { switch self { case .transaction: "transaction"; case .cashFlow: "cash_flow"; case .unknown(let value): value } }
    public var isDisplayOnly: Bool { if case .unknown = self { true } else { false } }
}

public enum V15AITransactionKind: Sendable, Equatable, Codable {
    case known(V15ManualTransactionKind)
    case unknown(String)
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = V15ManualTransactionKind(rawValue: raw).map(Self.known) ?? .unknown(raw)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public var rawValue: String { switch self { case .known(let value): value.rawValue; case .unknown(let value): value } }
}

public struct V15AIFieldConfidences: Codable, Sendable, Equatable {
    public let kind, amountMinor, occurredAt, title, note, accountID, categoryID, destinationAccountID: Int
    enum CodingKeys: String, CodingKey { case kind, title, note; case amountMinor = "amount_minor", occurredAt = "occurred_at", accountID = "account_id", categoryID = "category_id", destinationAccountID = "destination_account_id" }
}

public struct V15AISettings: Codable, Sendable, Equatable {
    public let ocrSourceEnabled: Bool
    public let shortcutTextSourceEnabled: Bool
    public let providerConfigured: Bool
    public let version: Int
    public let createdAt: Date
    public let updatedAt: Date
    enum CodingKeys: String, CodingKey {
        case ocrSourceEnabled = "ocr_source_enabled"
        case shortcutTextSourceEnabled = "shortcut_text_source_enabled"
        case providerConfigured = "provider_configured"
        case version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct V15AISettingsUpdateRequest: Codable, Sendable, Equatable {
    public let ocrSourceEnabled: Bool
    public let shortcutTextSourceEnabled: Bool
    public let expectedVersion: Int
    public init(ocrSourceEnabled: Bool, shortcutTextSourceEnabled: Bool, expectedVersion: Int) {
        self.ocrSourceEnabled = ocrSourceEnabled
        self.shortcutTextSourceEnabled = shortcutTextSourceEnabled
        self.expectedVersion = expectedVersion
    }
    enum CodingKeys: String, CodingKey {
        case ocrSourceEnabled = "ocr_source_enabled"
        case shortcutTextSourceEnabled = "shortcut_text_source_enabled"
        case expectedVersion = "expected_version"
    }
}

public struct V15AIProposal: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let source: V15AIProposalSource
    public let text, contentFingerprint: String
    public let provider, model: String?
    public let target: V15AIProposalTarget
    public let kind: V15AITransactionKind?
    public let amountMinor: V15MinorUnits?
    public let occurredAt: Date?
    public let title, note: String?
    public let accountID, categoryID, destinationAccountID, creditCycleID: UUID?
    public let fieldConfidences: V15AIFieldConfidences
    public let overallConfidenceBPS: Int?
    public let missingFields, reasonCodes: [String]
    public let explanation: String?
    public let status: V15AIProposalStatus
    public let errorCode, errorMessage: String?
    public let transactionID: UUID?
    public let transactionVersion: Int?
    public let cashFlowItemID: UUID?
    public let cashFlowItemVersion: Int?
    public let version: Int
    public let createdAt, updatedAt: Date
    public let executedAt, ignoredAt, undoneAt: Date?
    enum CodingKeys: String, CodingKey {
        case id, source, text, provider, model, target, kind, title, note, status, version, explanation
        case contentFingerprint = "content_fingerprint", amountMinor = "amount_minor", occurredAt = "occurred_at", accountID = "account_id", categoryID = "category_id", destinationAccountID = "destination_account_id", creditCycleID = "credit_cycle_id", fieldConfidences = "field_confidences", overallConfidenceBPS = "overall_confidence_bps", missingFields = "missing_fields", reasonCodes = "reason_codes", errorCode = "error_code", errorMessage = "error_message", transactionID = "transaction_id", transactionVersion = "transaction_version", cashFlowItemID = "cash_flow_item_id", cashFlowItemVersion = "cash_flow_item_version", createdAt = "created_at", updatedAt = "updated_at", executedAt = "executed_at", ignoredAt = "ignored_at", undoneAt = "undone_at"
    }
    public var isDisplayOnly: Bool { status.isDisplayOnly || target.isDisplayOnly || (kind.map { if case .unknown = $0 { true } else { false } } ?? false) }
}

public struct V15AIProposalPage: Codable, Sendable, Equatable {
    public let items: [V15AIProposal]
    public let nextCursor: String?
    public let pendingCount: Int
    enum CodingKeys: String, CodingKey { case items; case nextCursor = "next_cursor", pendingCount = "pending_count" }
}

public struct V15AIProposalCreate: Codable, Sendable, Equatable {
    public let source: V15AIProposalSource
    public let text: String
    public init(source: V15AIProposalSource, text: String) { self.source = source; self.text = text }
}

public struct V15AIProposalReplace: Codable, Sendable, Equatable {
    public let draft: V15TransactionCreateRequest
    public let expectedVersion: Int
    public init(draft: V15TransactionCreateRequest, expectedVersion: Int) { self.draft = draft; self.expectedVersion = expectedVersion }
    enum CodingKeys: String, CodingKey { case draft; case expectedVersion = "expected_version" }
}

/// The AI API deliberately keeps its replacement wire compatible with
/// `TransactionDraft`, even when the server will execute a future proposal as
/// a cash-flow item.  This local type prevents the UI from presenting that
/// cash-flow review as an ordinary posting while preserving the authoritative
/// p8 body shape at the boundary.
public struct V15AICashFlowReviewDraft: Sendable, Equatable {
    public let title: String
    public let note: String?
    public let direction: V15CashFlowDirection
    public let plannedAmountMinor: V15MinorUnits
    public let expectedDate: Date
    public let accountID: UUID?
    public let destinationAccountID: UUID?
    public let categoryID: UUID?
    public let wireDraft: V15TransactionCreateRequest

    public init(wireDraft: V15TransactionCreateRequest) {
        self.wireDraft = wireDraft
        title = wireDraft.title
        note = wireDraft.note
        plannedAmountMinor = wireDraft.amountMinor
        expectedDate = wireDraft.occurredAt
        accountID = wireDraft.accountID
        destinationAccountID = wireDraft.destinationAccountID
        categoryID = wireDraft.categoryID
        direction = switch wireDraft.kind {
        case .income, .borrowing: .inflow
        case .expense: .outflow
        case .transfer: .transfer
        case .creditPurchase, .repayment: .outflow
        }
    }
}

public enum V15AIProposalReviewDraft: Sendable, Equatable {
    case transaction(V15TransactionCreateRequest)
    case cashFlow(V15AICashFlowReviewDraft)

    public var wireDraft: V15TransactionCreateRequest {
        switch self {
        case .transaction(let draft): draft
        case .cashFlow(let draft): draft.wireDraft
        }
    }
}

public struct V15AIProposalVersionRequest: Codable, Sendable, Equatable {
    public let expectedVersion: Int
    public init(expectedVersion: Int) { self.expectedVersion = expectedVersion }
    enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version" }
}

public struct V15AIProposalUndoRequest: Codable, Sendable, Equatable {
    public let expectedVersion: Int
    public let expectedTransactionVersion: Int?
    public init(expectedVersion: Int, expectedTransactionVersion: Int?) { self.expectedVersion = expectedVersion; self.expectedTransactionVersion = expectedTransactionVersion }
    enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version", expectedTransactionVersion = "expected_transaction_version" }
}

public struct V15AIProposalMutation: Codable, Sendable, Equatable {
    public let proposal: V15AIProposal
    public let transaction: V15Transaction?
    public let cashFlowItem: V15CashFlowItem?
    enum CodingKeys: String, CodingKey { case proposal, transaction; case cashFlowItem = "cash_flow_item" }
}

public struct V15AIProviderSettings: Codable, Sendable, Equatable {
    public let provider: String?
    public let baseURL: String?
    public let model: String?
    public let apiKeyConfigured: Bool
    public let version: Int
    public let updatedAt: Date
    enum CodingKeys: String, CodingKey {
        case provider, model, version
        case baseURL = "base_url"
        case apiKeyConfigured = "api_key_configured"
        case updatedAt = "updated_at"
    }
}

public struct V15AIService: Sendable {
    private let transport: any V15Transporting
    private let writable: @MainActor @Sendable () throws -> Void
    init(transport: any V15Transporting, writable: @escaping @MainActor @Sendable () throws -> Void) { self.transport = transport; self.writable = writable }

    public func settings(readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15AISettings {
        try await transport.send(.init(path: "ai/settings", readCachePolicy: readCachePolicy), body: nil)
    }

    public func updateSettings(_ request: V15AISettingsUpdateRequest) async throws -> V15AISettings {
        try await writable()
        return try await transport.send(.init(path: "ai/settings", method: "PUT"), body: try V15BodyEncoder.encode(request))
    }

    public func proposals(status: V15AIProposalStatus? = nil, cursor: String? = nil, limit: Int = 50, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15AIProposalPage {
        guard (1...100).contains(limit) else { throw V15Failure(kind: .decoding, code: "invalid_ai_limit", message: "AI 提案每页数量须在 1 到 100 之间。") }
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let status {
            guard !status.isDisplayOnly else { throw V15Failure(kind: .decoding, code: "unknown_ai_status_filter", message: "未知状态不能作为查询条件。") }
            query.append(.init(name: "status", value: status.rawValue))
        }
        if let cursor { query.append(.init(name: "cursor", value: cursor)) }
        return try await transport.send(.init(path: "ai/proposals", query: query, readCachePolicy: readCachePolicy), body: nil)
    }

    public func proposal(id: UUID, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15AIProposal {
        try await transport.send(.init(path: "ai/proposals/\(id)", readCachePolicy: readCachePolicy), body: nil)
    }

    public func providerSettings(readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15AIProviderSettings {
        try await transport.send(.init(path: "ai/provider-settings", readCachePolicy: readCachePolicy), body: nil)
    }

    public func create(_ request: V15AIProposalCreate, idempotencyKey: UUID) async throws -> V15AIProposal {
        try await writable()
        return try await transport.send(.init(path: "ai/proposals", method: "POST", headers: ["Idempotency-Key": idempotencyKey.uuidString]), body: try V15BodyEncoder.encode(request))
    }

    public func replace(id: UUID, request: V15AIProposalReplace) async throws -> V15AIProposal {
        try await writable()
        return try await transport.send(.init(path: "ai/proposals/\(id)", method: "PUT"), body: try V15BodyEncoder.encode(request))
    }

    public func execute(id: UUID, expectedVersion: Int) async throws -> V15AIProposalMutation {
        try await writable()
        return try await transport.send(.init(path: "ai/proposals/\(id)/execute", method: "POST"), body: try V15BodyEncoder.encode(V15AIProposalVersionRequest(expectedVersion: expectedVersion)))
    }

    public func ignore(id: UUID, expectedVersion: Int) async throws -> V15AIProposal {
        try await writable()
        return try await transport.send(.init(path: "ai/proposals/\(id)/ignore", method: "POST"), body: try V15BodyEncoder.encode(V15AIProposalVersionRequest(expectedVersion: expectedVersion)))
    }

    public func retry(id: UUID, expectedVersion: Int) async throws -> V15AIProposal {
        try await writable()
        return try await transport.send(.init(path: "ai/proposals/\(id)/retry", method: "POST"), body: try V15BodyEncoder.encode(V15AIProposalVersionRequest(expectedVersion: expectedVersion)))
    }

    public func delete(id: UUID, expectedVersion: Int) async throws {
        try await writable()
        try await transport.sendNoContent(
            .init(
                path: "ai/proposals/\(id)",
                method: "DELETE",
                query: [.init(name: "expected_version", value: String(expectedVersion))]
            ),
            body: nil
        )
    }

    public func undo(id: UUID, expectedVersion: Int, expectedTransactionVersion: Int?) async throws -> V15AIProposalMutation {
        try await writable()
        return try await transport.send(.init(path: "ai/proposals/\(id)/undo", method: "POST"), body: try V15BodyEncoder.encode(V15AIProposalUndoRequest(expectedVersion: expectedVersion, expectedTransactionVersion: expectedTransactionVersion)))
    }
}
