import Foundation

public protocol AccountRepository: Sendable {
    func list(includeArchived: Bool) async throws -> [AccountDTO]
    func get(id: UUID) async throws -> AccountDTO
    func create(_ draft: AccountDraft) async throws -> AccountDTO
    func update(id: UUID, version: Int, draft: AccountDraft) async throws -> AccountDTO
    func archive(_ account: AccountDTO) async throws -> AccountDTO
    func restore(_ account: AccountDTO) async throws -> AccountDTO
    func delete(_ account: AccountDTO) async throws
    func reorder(ids: [UUID]) async throws -> [AccountDTO]
}

public actor RemoteAccountRepository: AccountRepository {
    private let transport: APITransport
    public init(transport: APITransport) { self.transport = transport }
    public func list(includeArchived: Bool) async throws -> [AccountDTO] {
        try await transport.request("accounts", query: [.init(name: "include_archived", value: String(includeArchived))])
    }
    public func get(id: UUID) async throws -> AccountDTO { try await transport.request("accounts/\(id)") }
    public func create(_ draft: AccountDraft) async throws -> AccountDTO { try await transport.request("accounts", method: "POST", body: draft) }
    public func update(id: UUID, version: Int, draft: AccountDraft) async throws -> AccountDTO { try await transport.request("accounts/\(id)", method: "PATCH", body: VersionedAccountDraft(version: version, draft: draft)) }
    public func archive(_ account: AccountDTO) async throws -> AccountDTO { try await transport.request("accounts/\(account.id)/archive", method: "POST", body: VersionRequest(version: account.version)) }
    public func restore(_ account: AccountDTO) async throws -> AccountDTO { try await transport.request("accounts/\(account.id)/restore", method: "POST", body: VersionRequest(version: account.version)) }
    public func delete(_ account: AccountDTO) async throws { try await transport.requestNoContent("accounts/\(account.id)", method: "DELETE", query: [.init(name: "expected_version", value: String(account.version))]) }
    public func reorder(ids: [UUID]) async throws -> [AccountDTO] { try await transport.request("accounts/order", method: "PUT", body: OrderedIDsRequest(orderedIDs: ids)) }
}

public protocol CategoryRepository: Sendable {
    func list(direction: CategoryDirection?, includeArchived: Bool) async throws -> [CategoryDTO]
    func get(id: UUID) async throws -> CategoryDTO
    func create(_ draft: CategoryDraft) async throws -> CategoryDTO
    func update(id: UUID, version: Int, draft: CategoryDraft) async throws -> CategoryDTO
    func archive(_ category: CategoryDTO) async throws -> CategoryDTO
    func restore(_ category: CategoryDTO) async throws -> CategoryDTO
    func delete(_ category: CategoryDTO) async throws
    func reorder(ids: [UUID], parentID: UUID?) async throws -> [CategoryDTO]
    func merge(source: CategoryDTO, target: CategoryDTO) async throws -> CategoryDTO
    func split(root: CategoryDTO, children: [CategoryDraft]) async throws -> [CategoryDTO]
}

public actor RemoteCategoryRepository: CategoryRepository {
    private let transport: APITransport
    public init(transport: APITransport) { self.transport = transport }
    public func list(direction: CategoryDirection?, includeArchived: Bool) async throws -> [CategoryDTO] {
        var query = [URLQueryItem(name: "include_archived", value: String(includeArchived))]
        if let direction { query.append(.init(name: "direction", value: direction.rawValue)) }
        return try await transport.request("categories", query: query)
    }
    public func get(id: UUID) async throws -> CategoryDTO { try await transport.request("categories/\(id)") }
    public func create(_ draft: CategoryDraft) async throws -> CategoryDTO { try await transport.request("categories", method: "POST", body: draft) }
    public func update(id: UUID, version: Int, draft: CategoryDraft) async throws -> CategoryDTO { try await transport.request("categories/\(id)", method: "PATCH", body: VersionedCategoryDraft(version: version, draft: draft)) }
    public func archive(_ category: CategoryDTO) async throws -> CategoryDTO { try await transport.request("categories/\(category.id)/archive", method: "POST", body: VersionRequest(version: category.version)) }
    public func restore(_ category: CategoryDTO) async throws -> CategoryDTO { try await transport.request("categories/\(category.id)/restore", method: "POST", body: VersionRequest(version: category.version)) }
    public func delete(_ category: CategoryDTO) async throws { try await transport.requestNoContent("categories/\(category.id)", method: "DELETE", query: [.init(name: "expected_version", value: String(category.version))]) }
    public func reorder(ids: [UUID], parentID: UUID?) async throws -> [CategoryDTO] {
        try await transport.request("categories/order", method: "PUT", body: CategoryOrderRequest(orderedIDs: ids, parentID: parentID))
    }
    public func merge(source: CategoryDTO, target: CategoryDTO) async throws -> CategoryDTO { try await transport.request("categories/\(source.id)/merge", method: "POST", body: MergeCategoryRequest(targetID: target.id, sourceExpectedVersion: source.version, targetExpectedVersion: target.version)) }
    public func split(root: CategoryDTO, children: [CategoryDraft]) async throws -> [CategoryDTO] { try await transport.request("categories/\(root.id)/split", method: "POST", body: SplitCategoryRequest(rootExpectedVersion: root.version, children: children)) }
}

public struct CategoryOrderRequest: Codable, Sendable {
    public let orderedIDs: [UUID]; public let parentID: UUID?
    enum CodingKeys: String, CodingKey { case orderedIDs = "ordered_ids"; case parentID = "parent_id" }
    public init(orderedIDs: [UUID], parentID: UUID?) { self.orderedIDs = orderedIDs; self.parentID = parentID }
}
