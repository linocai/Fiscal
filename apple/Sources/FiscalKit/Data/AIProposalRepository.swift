import Foundation

public protocol AIProposalRepository: Sendable {
  func list(status: AIProposalStatus?, cursor: String?, limit: Int) async throws -> AIProposalPage
  func get(id: UUID) async throws -> AIProposalDTO
  func create(text: String, idempotencyKey: UUID) async throws -> AIProposalDTO
  func update(id: UUID, request: AIProposalReplacementRequest) async throws -> AIProposalDTO
  func action(id: UUID, action: String, expectedVersion: Int) async throws
    -> AIProposalActionResponse
}

public actor RemoteAIProposalRepository: AIProposalRepository {
  private let transport: APITransport
  public init(transport: APITransport) { self.transport = transport }

  public func list(status: AIProposalStatus?, cursor: String?, limit: Int = 30) async throws
    -> AIProposalPage
  {
    var query = [URLQueryItem(name: "limit", value: String(limit))]
    if let status { query.append(.init(name: "status", value: status.rawValue)) }
    if let cursor { query.append(.init(name: "cursor", value: cursor)) }
    return try await transport.request("ai/proposals", query: query)
  }
  public func get(id: UUID) async throws -> AIProposalDTO {
    try await transport.request("ai/proposals/\(id)")
  }
  public func create(text: String, idempotencyKey: UUID) async throws -> AIProposalDTO {
    try await transport.request(
      "ai/proposals", method: "POST",
      headers: ["Idempotency-Key": idempotencyKey.uuidString],
      body: AIProposalCreateRequest(text: text))
  }
  public func update(id: UUID, request: AIProposalReplacementRequest) async throws
    -> AIProposalDTO
  { try await transport.request("ai/proposals/\(id)", method: "PUT", body: request) }
  public func action(id: UUID, action: String, expectedVersion: Int) async throws
    -> AIProposalActionResponse
  {
    if action == "execute" || action == "undo" {
      return try await transport.request(
        "ai/proposals/\(id)/\(action)", method: "POST",
        body: VersionRequest(version: expectedVersion))
    }
    let proposal: AIProposalDTO = try await transport.request(
      "ai/proposals/\(id)/\(action)", method: "POST",
      body: VersionRequest(version: expectedVersion))
    return AIProposalActionResponse(proposal: proposal, transaction: nil)
  }
}
