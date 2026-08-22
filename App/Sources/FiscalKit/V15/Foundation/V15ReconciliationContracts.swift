import Foundation

// MARK: - F3-E reconciliation facts

public enum V15ReconciliationTargetKind: String, Codable, Sendable, Equatable, Hashable, CaseIterable, Identifiable {
    case account
    case creditCycle = "credit_cycle"
    public var id: String { rawValue }
}

public enum V15ReconciliationState: Sendable, Equatable, Codable {
    case open, reconciled
    case unknown(String)

    public init(from decoder: Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "open": self = .open
        case "reconciled": self = .reconciled
        case let value: self = .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .open: try container.encode("open")
        case .reconciled: try container.encode("reconciled")
        case .unknown(let value): try container.encode(value)
        }
    }

    public var isKnown: Bool { if case .unknown = self { false } else { true } }
}

public struct V15ReconciliationTarget: Sendable, Equatable, Hashable, Identifiable {
    public let kind: V15ReconciliationTargetKind
    public let resourceID: UUID
    public let label: String
    public let accountID: UUID?
    public var id: String { "\(kind.rawValue):\(resourceID.uuidString)" }

    public init(kind: V15ReconciliationTargetKind, resourceID: UUID, label: String, accountID: UUID? = nil) {
        self.kind = kind
        self.resourceID = resourceID
        self.label = label
        self.accountID = accountID
    }
}

public struct V15ReconciliationCheckpoint: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let targetKind: V15ReconciliationTargetKind
    public let accountID: UUID?
    public let creditCycleID: UUID?
    public let asOf: Date
    public let actualBalanceMinor: V15MinorUnits
    public let bookBalanceMinor: V15MinorUnits
    public let differenceMinor: V15MinorUnits
    public let state: V15ReconciliationState
    public let note: String?
    public let createdAt: Date
    enum CodingKeys: String, CodingKey {
        case id, state, note
        case targetKind = "target_kind", accountID = "account_id", creditCycleID = "credit_cycle_id"
        case asOf = "as_of", actualBalanceMinor = "actual_balance_minor", bookBalanceMinor = "book_balance_minor", differenceMinor = "difference_minor", createdAt = "created_at"
    }
}

public struct V15ReconciliationDiagnosisEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID { transactionID }
    public let transactionID: UUID
    public let occurredAt: Date
    public let title: String
    public let amountMinor: V15MinorUnits
    public let accountImpactMinor: V15MinorUnits
    enum CodingKeys: String, CodingKey { case transactionID = "transaction_id", occurredAt = "occurred_at", title, amountMinor = "amount_minor", accountImpactMinor = "account_impact_minor" }
}

public struct V15ReconciliationDiagnosis: Codable, Sendable, Equatable {
    public let targetKind: V15ReconciliationTargetKind
    public let accountID: UUID?
    public let creditCycleID: UUID?
    public let asOf: Date
    public let fromAsOf: Date?
    public let openingBalanceMinor: V15MinorUnits
    public let bookBalanceMinor: V15MinorUnits
    public let actualBalanceMinor: V15MinorUnits?
    public let differenceMinor: V15MinorUnits?
    public let entries: [V15ReconciliationDiagnosisEntry]
    enum CodingKeys: String, CodingKey {
        case targetKind = "target_kind", accountID = "account_id", creditCycleID = "credit_cycle_id"
        case asOf = "as_of", fromAsOf = "from_as_of", openingBalanceMinor = "opening_balance_minor", bookBalanceMinor = "book_balance_minor", actualBalanceMinor = "actual_balance_minor", differenceMinor = "difference_minor", entries
    }
}

public struct V15ReconciliationCheckpointCreate: Codable, Sendable, Equatable {
    public let targetKind: V15ReconciliationTargetKind
    public let accountID: UUID?
    public let creditCycleID: UUID?
    public let asOf: Date
    public let actualBalanceMinor: V15MinorUnits
    public let note: String?
    public init(targetKind: V15ReconciliationTargetKind, accountID: UUID?, creditCycleID: UUID?, asOf: Date, actualBalanceMinor: V15MinorUnits, note: String?) {
        self.targetKind = targetKind; self.accountID = accountID; self.creditCycleID = creditCycleID
        self.asOf = asOf; self.actualBalanceMinor = actualBalanceMinor; self.note = note
    }
    enum CodingKeys: String, CodingKey { case targetKind = "target_kind", accountID = "account_id", creditCycleID = "credit_cycle_id", asOf = "as_of", actualBalanceMinor = "actual_balance_minor", note }
}

public struct V15AttentionIgnoreRequest: Codable, Sendable, Equatable {
    public let expiresAt: Date
    public init(expiresAt: Date) { self.expiresAt = expiresAt }
    enum CodingKeys: String, CodingKey { case expiresAt = "expires_at" }
}

public struct V15ReconciliationService: Sendable {
    private let transport: any V15Transporting
    private let writable: @MainActor @Sendable () throws -> Void
    init(transport: any V15Transporting, writable: @escaping @MainActor @Sendable () throws -> Void) { self.transport = transport; self.writable = writable }

    public func checkpoints(target: V15ReconciliationTarget, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> [V15ReconciliationCheckpoint] {
        let name = target.kind == .account ? "account_id" : "credit_cycle_id"
        return try await transport.send(.init(path: "reconciliation/checkpoints", query: [.init(name: name, value: target.resourceID.uuidString)], readCachePolicy: readCachePolicy), body: nil)
    }

    public func checkpoint(id: UUID, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15ReconciliationCheckpoint {
        try await transport.send(.init(path: "reconciliation/checkpoints/\(id)", readCachePolicy: readCachePolicy), body: nil)
    }

    public func diagnosis(target: V15ReconciliationTarget, asOf: Date, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15ReconciliationDiagnosis {
        let idName = target.kind == .account ? "account_id" : "credit_cycle_id"
        let timestamp = ISO8601DateFormatter().string(from: asOf)
        return try await transport.send(.init(path: "reconciliation/diagnosis", query: [
            .init(name: "target_kind", value: target.kind.rawValue),
            .init(name: "as_of", value: timestamp),
            .init(name: idName, value: target.resourceID.uuidString)
        ], readCachePolicy: readCachePolicy), body: nil)
    }

    public func attention(readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15AttentionPage {
        try await transport.send(.init(path: "reconciliation/attention", readCachePolicy: readCachePolicy), body: nil)
    }

    public func createCheckpoint(_ request: V15ReconciliationCheckpointCreate) async throws -> V15ReconciliationCheckpoint {
        try await writable()
        guard (request.targetKind == .account && request.accountID != nil && request.creditCycleID == nil) ||
                (request.targetKind == .creditCycle && request.accountID == nil && request.creditCycleID != nil)
        else { throw V15Failure(kind: .decoding, code: "invalid_reconciliation_target", message: "核对目标必须且只能包含一个账户或账期。") }
        return try await transport.send(.init(path: "reconciliation/checkpoints", method: "POST"), body: try V15BodyEncoder.encode(request))
    }

    public func ignoreAttention(sourceType: String, sourceID: UUID, request: V15AttentionIgnoreRequest) async throws {
        try await writable()
        try await transport.sendNoContent(.init(path: "reconciliation/attention/\(sourceType)/\(sourceID)/ignore", method: "POST"), body: try V15BodyEncoder.encode(request))
    }
}
