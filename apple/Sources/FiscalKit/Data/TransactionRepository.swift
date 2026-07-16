import Foundation

public protocol TransactionRepository: Sendable {
    func list(_ query: TransactionQuery) async throws -> TransactionPage
    func get(id: UUID) async throws -> TransactionDTO
    func create(_ draft: TransactionDraft, idempotencyKey: UUID) async throws -> TransactionDTO
    func update(id: UUID, version: Int, draft: TransactionDraft) async throws -> TransactionDTO
    func void(_ transaction: TransactionDTO) async throws -> TransactionDTO
    func restore(_ transaction: TransactionDTO) async throws -> TransactionDTO
    func batchClassify(_ request: TransactionBatchClassificationRequest) async throws -> TransactionBatchClassificationResponse
    func exportCSV(_ query: TransactionQuery) async throws -> Data
}

public extension TransactionRepository {
    func batchClassify(_ request: TransactionBatchClassificationRequest) async throws -> TransactionBatchClassificationResponse {
        throw FiscalAPIError.transport("当前流水仓库不支持批量分类")
    }
    func exportCSV(_ query: TransactionQuery) async throws -> Data {
        throw FiscalAPIError.transport("当前流水仓库不支持 CSV 导出")
    }
}

public actor RemoteTransactionRepository: TransactionRepository {
    private let transport: APITransport
    public init(transport: APITransport) { self.transport = transport }

    public func list(_ query: TransactionQuery) async throws -> TransactionPage {
        var items = filterQueryItems(query)
        items.insert(.init(name: "limit", value: String(query.limit)), at: 0)
        if let value = query.cursor { items.insert(.init(name: "cursor", value: value), at: 1) }
        return try await transport.request("transactions", query: items)
    }
    private func filterQueryItems(_ query: TransactionQuery) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "include_voided", value: String(query.includeVoided))]
        if let value = query.kind { items.append(.init(name: "kind", value: value.rawValue)) }
        if let value = query.accountID { items.append(.init(name: "account_id", value: value.uuidString)) }
        if let value = query.categoryID { items.append(.init(name: "category_id", value: value.uuidString)) }
        if let value = query.dateFrom { items.append(.init(name: "date_from", value: value)) }
        if let value = query.dateTo { items.append(.init(name: "date_to", value: value)) }
        items.append(.init(name: "classification", value: query.classification.rawValue))
        if let value = query.source { items.append(.init(name: "source", value: value)) }
        if let value = query.amountMinMinor { items.append(.init(name: "amount_min_minor", value: String(value))) }
        if let value = query.amountMaxMinor { items.append(.init(name: "amount_max_minor", value: String(value))) }
        if !query.search.isEmpty { items.append(.init(name: "query", value: query.search)) }
        return items
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
    public func batchClassify(_ request: TransactionBatchClassificationRequest) async throws -> TransactionBatchClassificationResponse {
        try await transport.request("transactions/bulk-category", method: "POST", body: request)
    }
    public func exportCSV(_ query: TransactionQuery) async throws -> Data {
        try await transport.rawDataGET(
            "transactions/export.csv",
            query: filterQueryItems(query),
            accept: "text/csv")
    }
}
