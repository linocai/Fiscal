import Foundation

public protocol ReconciliationRepository: Sendable {
    func checkpoints(accountID: UUID) async throws -> [ReconciliationCheckpointDTO]
    func create(_ draft: ReconciliationCheckpointDraft) async throws -> ReconciliationCheckpointDTO
    func diagnosis(accountID: UUID, asOf: Date) async throws -> BalanceDiagnosisDTO
    func attention() async throws -> AttentionPageDTO
    func ignore(item: AttentionItemDTO, until: Date) async throws
}

public struct RemoteReconciliationRepository: ReconciliationRepository {
    private let transport: APITransport
    public init(transport: APITransport) { self.transport = transport }

    public func checkpoints(accountID: UUID) async throws -> [ReconciliationCheckpointDTO] {
        try await transport.request(
            "reconciliation/checkpoints",
            query: [.init(name: "account_id", value: accountID.uuidString)]
        )
    }

    public func create(_ draft: ReconciliationCheckpointDraft) async throws -> ReconciliationCheckpointDTO {
        try await transport.request("reconciliation/checkpoints", method: "POST", body: draft)
    }

    public func diagnosis(accountID: UUID, asOf: Date) async throws -> BalanceDiagnosisDTO {
        let instant = ISO8601DateFormatter().string(from: asOf)
        return try await transport.request(
            "reconciliation/diagnosis",
            query: [
                .init(name: "target_kind", value: "account"),
                .init(name: "account_id", value: accountID.uuidString),
                .init(name: "as_of", value: instant),
            ]
        )
    }

    public func attention() async throws -> AttentionPageDTO {
        try await transport.request("reconciliation/attention")
    }

    public func ignore(item: AttentionItemDTO, until: Date) async throws {
        try await transport.requestNoContent(
            "reconciliation/attention/\(item.sourceType)/\(item.sourceID.uuidString)/ignore",
            method: "POST",
            body: AttentionIgnoreDraft(expiresAt: until)
        )
    }
}
