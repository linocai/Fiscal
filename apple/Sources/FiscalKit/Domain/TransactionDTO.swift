import Foundation

public enum TransactionKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case expense, income, transfer
    public var id: Self { self }
    public var title: String { switch self { case .expense: "支出"; case .income: "收入"; case .transfer: "转账" } }
    public var symbol: String { switch self { case .expense: "arrow.up.right"; case .income: "arrow.down.left"; case .transfer: "arrow.left.arrow.right" } }
}

public enum PostingRole: String, Codable, Sendable { case account, source, destination }

public struct PostingDTO: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let accountID: UUID
    public let role: PostingRole
    public let amountMinor: Int64
    public let position: Int
    enum CodingKeys: String, CodingKey {
        case id, role, position
        case accountID = "account_id"; case amountMinor = "amount_minor"
    }
}

public struct TransactionDTO: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: TransactionKind
    public let occurredAt: Date
    public let businessDate: String
    public let title: String
    public let note: String?
    public let amountMinor: Int64
    public let categoryID: UUID?
    public let accountID: UUID?
    public let destinationAccountID: UUID?
    public let source: String
    public let postings: [PostingDTO]
    public let version: Int
    public let voidedAt: Date?
    public let createdAt: Date
    public let updatedAt: Date
    enum CodingKeys: String, CodingKey {
        case id, kind, title, note, source, postings, version
        case occurredAt = "occurred_at"; case businessDate = "business_date"; case amountMinor = "amount_minor"
        case categoryID = "category_id"; case accountID = "account_id"; case destinationAccountID = "destination_account_id"; case voidedAt = "voided_at"
        case createdAt = "created_at"; case updatedAt = "updated_at"
    }
}

public struct TransactionPage: Codable, Sendable, Equatable {
    public let items: [TransactionDTO]
    public let nextCursor: String?
    enum CodingKeys: String, CodingKey { case items; case nextCursor = "next_cursor" }
}

public struct TransactionDraft: Codable, Sendable, Equatable {
    public var kind: TransactionKind = .expense
    public var occurredAt = Date()
    public var title = ""
    public var note = ""
    public var amountMinor: Int64 = 0
    public var categoryID: UUID?
    public var accountID: UUID?
    public var destinationAccountID: UUID?

    public init() {}
    public init(transaction: TransactionDTO) {
        kind = transaction.kind; occurredAt = transaction.occurredAt; title = transaction.title
        note = transaction.note ?? ""; amountMinor = transaction.amountMinor; categoryID = transaction.categoryID
        accountID = transaction.accountID; destinationAccountID = transaction.destinationAccountID
    }
    enum CodingKeys: String, CodingKey {
        case kind, title, note
        case occurredAt = "occurred_at"; case amountMinor = "amount_minor"; case categoryID = "category_id"
        case accountID = "account_id"; case destinationAccountID = "destination_account_id"
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind); try c.encode(occurredAt, forKey: .occurredAt)
        try c.encode(title.trimmingCharacters(in: .whitespacesAndNewlines), forKey: .title)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        try c.encode(trimmedNote.isEmpty ? nil : trimmedNote, forKey: .note)
        try c.encode(amountMinor, forKey: .amountMinor)
        try c.encode(kind == .transfer ? nil : categoryID, forKey: .categoryID)
        try c.encode(accountID, forKey: .accountID)
        try c.encode(kind == .transfer ? destinationAccountID : nil, forKey: .destinationAccountID)
    }
}

public struct VersionedTransactionDraft: Codable, Sendable {
    public let draft: TransactionDraft
    public let expectedVersion: Int
    public init(draft: TransactionDraft, expectedVersion: Int) { self.draft = draft; self.expectedVersion = expectedVersion }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        let data = try JSONEncoder.fiscal.encode(draft)
        let values = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        for (key, value) in values { try c.encode(JSONValue(any: value), forKey: .init(key)) }
        try c.encode(expectedVersion, forKey: .init("expected_version"))
    }
}

public struct TransactionQuery: Sendable, Equatable {
    public var cursor: String?; public var limit = 50; public var kind: TransactionKind?
    public var accountID: UUID?; public var categoryID: UUID?; public var dateFrom: String?; public var dateTo: String?
    public var search = ""; public var includeVoided = false
    public init() {}
}

private extension JSONEncoder { static var fiscal: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e } }
private extension JSONValue {
    init(any: Any) {
        switch any {
        case let value as String: self = .string(value)
        case let value as NSNumber where CFGetTypeID(value) == CFBooleanGetTypeID(): self = .bool(value.boolValue)
        case let value as NSNumber: self = .integer(value.int64Value)
        case let value as [String: Any]: self = .object(value.mapValues(JSONValue.init(any:)))
        case let value as [Any]: self = .array(value.map(JSONValue.init(any:)))
        default: self = .null
        }
    }
}
