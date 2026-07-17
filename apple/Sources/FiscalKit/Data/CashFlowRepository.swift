import Foundation

public protocol FutureCashFlowRepository: Sendable {
  func active(accountID: UUID?) async throws -> FutureCashFlowActive
  func history(month: String) async throws -> FutureCashFlowHistory
  func create(_ draft: FutureCashFlowDraft, idempotencyKey: UUID) async throws -> FutureCashFlowCreateResponse
  func update(id: UUID, request: FutureCashFlowReplace) async throws -> FutureCashFlowCreateResponse
  func confirm(id: UUID, version: Int) async throws -> FutureCashFlowItem
  func cancel(id: UUID, version: Int, scope: FutureCashFlowMutationScope) async throws -> FutureCashFlowCreateResponse
  func settle(id: UUID, request: FutureCashFlowSettlement, idempotencyKey: UUID) async throws -> FutureCashFlowItem
}

public actor RemoteFutureCashFlowRepository: FutureCashFlowRepository {
  private let transport: APITransport
  public init(transport: APITransport) { self.transport = transport }

  public func active(accountID: UUID? = nil) async throws -> FutureCashFlowActive {
    let query = accountID.map { [URLQueryItem(name: "account_id", value: $0.uuidString)] } ?? []
    return try await transport.request("cash-flow-items", query: query)
  }

  public func history(month: String) async throws -> FutureCashFlowHistory {
    try await transport.request(
      "cash-flow-items/history", query: [.init(name: "month", value: month)])
  }

  public func create(
    _ draft: FutureCashFlowDraft, idempotencyKey: UUID
  ) async throws -> FutureCashFlowCreateResponse {
    try await transport.request(
      "cash-flow-items", method: "POST",
      headers: ["Idempotency-Key": idempotencyKey.uuidString], body: draft)
  }

  public func update(
    id: UUID, request: FutureCashFlowReplace
  ) async throws -> FutureCashFlowCreateResponse {
    try await transport.request("cash-flow-items/\(id.uuidString)", method: "PUT", body: request)
  }

  public func confirm(id: UUID, version: Int) async throws -> FutureCashFlowItem {
    try await transport.request(
      "cash-flow-items/\(id.uuidString)/confirm", method: "POST",
      body: FutureCashFlowVersionRequest(version: version))
  }

  public func cancel(
    id: UUID, version: Int, scope: FutureCashFlowMutationScope
  ) async throws -> FutureCashFlowCreateResponse {
    try await transport.request(
      "cash-flow-items/\(id.uuidString)/cancel", method: "POST",
      body: FutureCashFlowVersionRequest(version: version, scope: scope))
  }

  public func settle(
    id: UUID, request: FutureCashFlowSettlement, idempotencyKey: UUID
  ) async throws -> FutureCashFlowItem {
    try await transport.request(
      "cash-flow-items/\(id.uuidString)/settle", method: "POST",
      headers: ["Idempotency-Key": idempotencyKey.uuidString], body: request)
  }
}
