import Foundation

public protocol InstallmentRepository: Sendable {
    func list(accountID: UUID?, status: InstallmentPlanStatus?, cursor: String?, limit: Int) async throws -> InstallmentPlanPage
    func get(id: UUID) async throws -> InstallmentPlanDTO
    func eligibility(transactionID: UUID) async throws -> InstallmentEligibility
    func cycleOptions(transactionID: UUID, months: Int) async throws -> [InstallmentCycleOption]
    func liabilities(accountID: UUID?) async throws -> InstallmentLiabilities
    func create(_ request: InstallmentCreateRequest, idempotencyKey: UUID) async throws -> InstallmentPlanDTO
    func preview(id: UUID, request: InstallmentReplacementRequest) async throws -> InstallmentPlanChangePreview
    func update(id: UUID, request: InstallmentReplacementRequest) async throws -> InstallmentPlanDTO
    func settlementPreview(id: UUID, request: InstallmentSettlementRequest) async throws -> InstallmentSettlementPreview
    func settleEarly(id: UUID, request: InstallmentSettlementRequest, idempotencyKey: UUID) async throws -> InstallmentSettlementResult
    func reversePreview(id: UUID, request: InstallmentOperationRequest) async throws -> InstallmentReversePreview
    func reverseSettlement(id: UUID, request: InstallmentOperationRequest, idempotencyKey: UUID) async throws -> InstallmentReverseResult
    func cancellationPreview(id: UUID, request: InstallmentOperationRequest) async throws -> InstallmentCancellationPreview
    func cancelFuture(id: UUID, request: InstallmentOperationRequest, idempotencyKey: UUID) async throws -> InstallmentCancellationResult
}

public actor RemoteInstallmentRepository: InstallmentRepository {
    private let transport: APITransport
    public init(transport: APITransport) { self.transport = transport }

    public func list(accountID: UUID?, status: InstallmentPlanStatus?, cursor: String?, limit: Int = 20) async throws -> InstallmentPlanPage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let accountID { query.append(.init(name: "account_id", value: accountID.uuidString)) }
        if let status { query.append(.init(name: "status", value: status.rawValue)) }
        if let cursor { query.append(.init(name: "cursor", value: cursor)) }
        return try await transport.request("installment-plans", query: query)
    }

    public func get(id: UUID) async throws -> InstallmentPlanDTO { try await transport.request("installment-plans/\(id)") }
    public func eligibility(transactionID: UUID) async throws -> InstallmentEligibility { try await transport.request("transactions/\(transactionID)/installment-eligibility") }
    public func cycleOptions(transactionID: UUID, months: Int = 60) async throws -> [InstallmentCycleOption] {
        try await transport.request("installment-cycle-options", query: [.init(name: "purchase_transaction_id", value: transactionID.uuidString), .init(name: "months", value: String(months))])
    }
    public func liabilities(accountID: UUID?) async throws -> InstallmentLiabilities {
        let query = accountID.map { [URLQueryItem(name: "account_id", value: $0.uuidString)] } ?? []
        return try await transport.request("installment-liabilities", query: query)
    }
    public func create(_ request: InstallmentCreateRequest, idempotencyKey: UUID) async throws -> InstallmentPlanDTO {
        try await transport.request("installment-plans", method: "POST", headers: ["Idempotency-Key": idempotencyKey.uuidString], body: request)
    }
    public func preview(id: UUID, request: InstallmentReplacementRequest) async throws -> InstallmentPlanChangePreview {
        try await transport.request("installment-plans/\(id)/preview", method: "POST", body: request)
    }
    public func update(id: UUID, request: InstallmentReplacementRequest) async throws -> InstallmentPlanDTO {
        try await transport.request("installment-plans/\(id)", method: "PUT", body: request)
    }
    public func settlementPreview(id: UUID, request: InstallmentSettlementRequest) async throws -> InstallmentSettlementPreview {
        try await transport.request("installment-plans/\(id)/settlement-preview", method: "POST", body: request)
    }
    public func settleEarly(id: UUID, request: InstallmentSettlementRequest, idempotencyKey: UUID) async throws -> InstallmentSettlementResult {
        try await transport.request("installment-plans/\(id)/settle-early", method: "POST", headers: ["Idempotency-Key": idempotencyKey.uuidString], body: request)
    }
    public func reversePreview(id: UUID, request: InstallmentOperationRequest) async throws -> InstallmentReversePreview {
        try await transport.request("installment-plans/\(id)/reverse-settlement-preview", method: "POST", body: request)
    }
    public func reverseSettlement(id: UUID, request: InstallmentOperationRequest, idempotencyKey: UUID) async throws -> InstallmentReverseResult {
        try await transport.request("installment-plans/\(id)/reverse-settlement", method: "POST", headers: ["Idempotency-Key": idempotencyKey.uuidString], body: request)
    }
    public func cancellationPreview(id: UUID, request: InstallmentOperationRequest) async throws -> InstallmentCancellationPreview {
        try await transport.request("installment-plans/\(id)/cancel-preview", method: "POST", body: request)
    }
    public func cancelFuture(id: UUID, request: InstallmentOperationRequest, idempotencyKey: UUID) async throws -> InstallmentCancellationResult {
        try await transport.request("installment-plans/\(id)/cancel-future", method: "POST", headers: ["Idempotency-Key": idempotencyKey.uuidString], body: request)
    }
}
