import Foundation

public protocol ReimbursementRepository: Sendable {
  func list(status: ReimbursementClaimStatus?, includeArchived: Bool, cursor: String?, limit: Int)
    async throws -> ReimbursementClaimPage
  func get(id: UUID) async throws -> ReimbursementClaimDTO
  func create(_ request: ReimbursementClaimCreateRequest, idempotencyKey: UUID) async throws
    -> ReimbursementClaimDTO
  func preview(id: UUID, request: ReimbursementClaimReplacementRequest) async throws
    -> ReimbursementClaimPreview
  func update(id: UUID, request: ReimbursementClaimReplacementRequest) async throws
    -> ReimbursementClaimDTO
  func lifecycle(id: UUID, action: String, version: Int) async throws -> ReimbursementClaimDTO
  func cancelPreview(id: UUID, version: Int) async throws -> ReimbursementCancelPreview
  func receipts(claimID: UUID, cursor: String?, limit: Int) async throws -> ReimbursementReceiptPage
  func receipt(id: UUID) async throws -> ReimbursementReceiptDTO
  func receiptPreview(
    id: UUID?, claimID: UUID, create: ReimbursementReceiptRequest?,
    replace: ReimbursementReceiptReplacementRequest?
  ) async throws -> ReimbursementReceiptPreview
  func createReceipt(claimID: UUID, request: ReimbursementReceiptRequest, idempotencyKey: UUID)
    async throws -> ReimbursementReceiptDTO
  func updateReceipt(id: UUID, request: ReimbursementReceiptReplacementRequest) async throws
    -> ReimbursementReceiptDTO
  func receiptLifecycle(id: UUID, action: String, request: ReimbursementReceiptVersionRequest)
    async throws -> ReimbursementReceiptDTO
  func expenseOptions(search: String?) async throws -> [ReimbursementExpenseOption]
  func summary(dateFrom: String?, dateTo: String?) async throws -> ReimbursementSummary
}

public actor RemoteReimbursementRepository: ReimbursementRepository {
  private let transport: APITransport
  public init(transport: APITransport) { self.transport = transport }

  public func list(
    status: ReimbursementClaimStatus?, includeArchived: Bool, cursor: String?, limit: Int = 30
  ) async throws -> ReimbursementClaimPage {
    var query = [
      URLQueryItem(name: "limit", value: String(limit)),
      .init(name: "include_archived", value: String(includeArchived)),
    ]
    if let status { query.append(.init(name: "status", value: status.rawValue)) }
    if let cursor { query.append(.init(name: "cursor", value: cursor)) }
    return try await transport.request("reimbursement-claims", query: query)
  }
  public func get(id: UUID) async throws -> ReimbursementClaimDTO {
    try await transport.request("reimbursement-claims/\(id)")
  }
  public func create(_ request: ReimbursementClaimCreateRequest, idempotencyKey: UUID) async throws
    -> ReimbursementClaimDTO
  {
    try await transport.request(
      "reimbursement-claims", method: "POST",
      headers: ["Idempotency-Key": idempotencyKey.uuidString], body: request)
  }
  public func preview(id: UUID, request: ReimbursementClaimReplacementRequest) async throws
    -> ReimbursementClaimPreview
  {
    try await transport.request("reimbursement-claims/\(id)/preview", method: "POST", body: request)
  }
  public func update(id: UUID, request: ReimbursementClaimReplacementRequest) async throws
    -> ReimbursementClaimDTO
  { try await transport.request("reimbursement-claims/\(id)", method: "PUT", body: request) }
  public func lifecycle(id: UUID, action: String, version: Int) async throws
    -> ReimbursementClaimDTO
  {
    try await transport.request(
      "reimbursement-claims/\(id)/\(action)", method: "POST",
      body: ReimbursementVersionRequest(expectedVersion: version))
  }
  public func cancelPreview(id: UUID, version: Int) async throws -> ReimbursementCancelPreview {
    try await transport.request(
      "reimbursement-claims/\(id)/cancel-preview", method: "POST",
      body: ReimbursementVersionRequest(expectedVersion: version))
  }
  public func receipts(claimID: UUID, cursor: String?, limit: Int = 30) async throws
    -> ReimbursementReceiptPage
  {
    var query = [URLQueryItem(name: "limit", value: String(limit))]
    if let cursor { query.append(.init(name: "cursor", value: cursor)) }
    return try await transport.request("reimbursement-claims/\(claimID)/receipts", query: query)
  }
  public func receipt(id: UUID) async throws -> ReimbursementReceiptDTO {
    try await transport.request("reimbursement-receipts/\(id)")
  }
  public func receiptPreview(
    id: UUID?, claimID: UUID, create: ReimbursementReceiptRequest?,
    replace: ReimbursementReceiptReplacementRequest?
  ) async throws -> ReimbursementReceiptPreview {
    if let id, let replace {
      return try await transport.request(
        "reimbursement-receipts/\(id)/preview", method: "POST", body: replace)
    }
    guard let create else { throw FiscalAPIError.invalidResponse }
    return try await transport.request(
      "reimbursement-claims/\(claimID)/receipt-preview", method: "POST", body: create)
  }
  public func createReceipt(
    claimID: UUID, request: ReimbursementReceiptRequest, idempotencyKey: UUID
  ) async throws -> ReimbursementReceiptDTO {
    try await transport.request(
      "reimbursement-claims/\(claimID)/receipts", method: "POST",
      headers: ["Idempotency-Key": idempotencyKey.uuidString], body: request)
  }
  public func updateReceipt(id: UUID, request: ReimbursementReceiptReplacementRequest) async throws
    -> ReimbursementReceiptDTO
  { try await transport.request("reimbursement-receipts/\(id)", method: "PUT", body: request) }
  public func receiptLifecycle(
    id: UUID, action: String, request: ReimbursementReceiptVersionRequest
  ) async throws -> ReimbursementReceiptDTO {
    try await transport.request(
      "reimbursement-receipts/\(id)/\(action)", method: "POST", body: request)
  }
  public func expenseOptions(search: String?) async throws -> [ReimbursementExpenseOption] {
    let query =
      search.flatMap { $0.isEmpty ? nil : [URLQueryItem(name: "search", value: $0)] } ?? []
    return try await transport.request("reimbursement-expense-options", query: query)
  }
  public func summary(dateFrom: String?, dateTo: String?) async throws -> ReimbursementSummary {
    var query: [URLQueryItem] = []
    if let dateFrom { query.append(.init(name: "date_from", value: dateFrom)) }
    if let dateTo { query.append(.init(name: "date_to", value: dateTo)) }
    return try await transport.request("reimbursements/summary", query: query)
  }
}
