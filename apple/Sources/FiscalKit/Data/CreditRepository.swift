import Foundation

public protocol CreditRepository: Sendable {
    func listAccounts() async throws -> [CreditAccountSummaryDTO]
    func account(id: UUID) async throws -> CreditAccountSummaryDTO
    func cycles(accountID: UUID, cursor: String?, limit: Int) async throws -> CreditCyclePage
    func cycle(id: UUID) async throws -> CreditCycleDTO
    func transactions(cycleID: UUID, cursor: String?, limit: Int) async throws -> TransactionPage
}

public actor RemoteCreditRepository: CreditRepository {
    private let transport: APITransport
    public init(transport: APITransport) { self.transport = transport }
    public func listAccounts() async throws -> [CreditAccountSummaryDTO] { try await transport.request("credit-accounts") }
    public func account(id: UUID) async throws -> CreditAccountSummaryDTO { try await transport.request("credit-accounts/\(id)") }
    public func cycles(accountID: UUID, cursor: String?, limit: Int = 20) async throws -> CreditCyclePage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]; if let cursor { query.append(.init(name: "cursor", value: cursor)) }
        return try await transport.request("credit-accounts/\(accountID)/cycles", query: query)
    }
    public func cycle(id: UUID) async throws -> CreditCycleDTO { try await transport.request("credit-cycles/\(id)") }
    public func transactions(cycleID: UUID, cursor: String?, limit: Int = 50) async throws -> TransactionPage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]; if let cursor { query.append(.init(name: "cursor", value: cursor)) }
        return try await transport.request("credit-cycles/\(cycleID)/transactions", query: query)
    }
}
