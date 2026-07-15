import Foundation

public protocol TransactionRepository: Sendable {
    func list(_ query: TransactionQuery) async throws -> TransactionPage
    func get(id: UUID) async throws -> TransactionDTO
    func create(_ draft: TransactionDraft, idempotencyKey: UUID) async throws -> TransactionDTO
    func update(id: UUID, version: Int, draft: TransactionDraft) async throws -> TransactionDTO
    func void(_ transaction: TransactionDTO) async throws -> TransactionDTO
    func restore(_ transaction: TransactionDTO) async throws -> TransactionDTO
}

public actor RemoteTransactionRepository: TransactionRepository {
    private let transport: APITransport
    public init(transport: APITransport) { self.transport = transport }

    public func list(_ query: TransactionQuery) async throws -> TransactionPage {
        var items = [URLQueryItem(name: "limit", value: String(query.limit)), .init(name: "include_voided", value: String(query.includeVoided))]
        if let value = query.cursor { items.append(.init(name: "cursor", value: value)) }
        if let value = query.kind { items.append(.init(name: "kind", value: value.rawValue)) }
        if let value = query.accountID { items.append(.init(name: "account_id", value: value.uuidString)) }
        if let value = query.categoryID { items.append(.init(name: "category_id", value: value.uuidString)) }
        if let value = query.dateFrom { items.append(.init(name: "date_from", value: value)) }
        if let value = query.dateTo { items.append(.init(name: "date_to", value: value)) }
        if !query.search.isEmpty { items.append(.init(name: "query", value: query.search)) }
        return try await transport.request("transactions", query: items)
    }
    public func get(id: UUID) async throws -> TransactionDTO { try await transport.request("transactions/\(id)") }
    public func create(_ draft: TransactionDraft, idempotencyKey: UUID) async throws -> TransactionDTO {
        try await transport.request("transactions", method: "POST", headers: ["Idempotency-Key": idempotencyKey.uuidString], body: draft)
    }
    public func update(id: UUID, version: Int, draft: TransactionDraft) async throws -> TransactionDTO {
        try await transport.request("transactions/\(id)", method: "PUT", body: VersionedTransactionDraft(draft: draft, expectedVersion: version))
    }
    public func void(_ transaction: TransactionDTO) async throws -> TransactionDTO {
        try await transport.request("transactions/\(transaction.id)/void", method: "POST", body: VersionRequest(version: transaction.version))
    }
    public func restore(_ transaction: TransactionDTO) async throws -> TransactionDTO {
        try await transport.request("transactions/\(transaction.id)/restore", method: "POST", body: VersionRequest(version: transaction.version))
    }
}
