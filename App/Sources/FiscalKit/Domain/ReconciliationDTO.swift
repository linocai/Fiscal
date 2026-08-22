import Foundation

public enum ReconciliationTargetKind: String, Codable, Sendable {
    case account
    case creditCycle = "credit_cycle"
}

public enum ReconciliationState: String, Codable, Sendable {
    case open, reconciled
}

public struct ReconciliationCheckpointDTO: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let targetKind: ReconciliationTargetKind
    public let accountID: UUID?
    public let creditCycleID: UUID?
    public let asOf: Date
    public let actualBalanceMinor: Int64
    public let bookBalanceMinor: Int64
    public let differenceMinor: Int64
    public let state: ReconciliationState
    public let note: String?
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, state, note
        case targetKind = "target_kind"
        case accountID = "account_id"
        case creditCycleID = "credit_cycle_id"
        case asOf = "as_of"
        case actualBalanceMinor = "actual_balance_minor"
        case bookBalanceMinor = "book_balance_minor"
        case differenceMinor = "difference_minor"
        case createdAt = "created_at"
    }
}

public struct ReconciliationCheckpointDraft: Codable, Sendable {
    public let targetKind: ReconciliationTargetKind
    public let accountID: UUID?
    public let creditCycleID: UUID?
    public let asOf: Date
    public let actualBalanceMinor: Int64
    public let note: String?

    enum CodingKeys: String, CodingKey {
        case targetKind = "target_kind"
        case accountID = "account_id"
        case creditCycleID = "credit_cycle_id"
        case asOf = "as_of"
        case actualBalanceMinor = "actual_balance_minor"
        case note
    }
}

public enum AttentionSeverity: String, Codable, Sendable { case info, warning, critical }

public struct AttentionItemDTO: Codable, Sendable, Identifiable, Equatable {
    public var id: String { "\(sourceType):\(sourceID.uuidString)" }
    public let sourceType: String
    public let sourceID: UUID
    public let severity: AttentionSeverity
    public let amountMinor: Int64?
    public let occurredAt: Date?
    public let explanation: String
    public let suggestedAction: String
    public let deepLink: String

    enum CodingKeys: String, CodingKey {
        case severity, explanation
        case sourceType = "source_type"
        case sourceID = "source_id"
        case amountMinor = "amount_minor"
        case occurredAt = "occurred_at"
        case suggestedAction = "suggested_action"
        case deepLink = "deep_link"
    }
}

public struct AttentionPageDTO: Codable, Sendable { public let items: [AttentionItemDTO] }

public struct BalanceDiagnosisEntryDTO: Codable, Sendable, Identifiable, Equatable {
    public let transactionID: UUID
    public var id: UUID { transactionID }
    public let occurredAt: Date
    public let title: String
    public let amountMinor: Int64
    public let accountImpactMinor: Int64

    enum CodingKeys: String, CodingKey {
        case title
        case transactionID = "transaction_id"
        case occurredAt = "occurred_at"
        case amountMinor = "amount_minor"
        case accountImpactMinor = "account_impact_minor"
    }
}

public struct BalanceDiagnosisDTO: Codable, Sendable, Equatable {
    public let bookBalanceMinor: Int64
    public let actualBalanceMinor: Int64?
    public let differenceMinor: Int64?
    public let entries: [BalanceDiagnosisEntryDTO]

    enum CodingKeys: String, CodingKey {
        case entries
        case bookBalanceMinor = "book_balance_minor"
        case actualBalanceMinor = "actual_balance_minor"
        case differenceMinor = "difference_minor"
    }
}

public struct AttentionIgnoreDraft: Codable, Sendable {
    public let expiresAt: Date
    enum CodingKeys: String, CodingKey { case expiresAt = "expires_at" }
}
