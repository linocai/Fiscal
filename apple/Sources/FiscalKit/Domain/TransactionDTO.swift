import Foundation

public enum TransactionKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case expense, income, transfer
    case creditPurchase = "credit_purchase"
    case repayment
    case installmentFee = "installment_fee"
    case installmentRefund = "installment_refund"
    case reimbursementReceipt = "reimbursement_receipt"
    public static let allCases: [TransactionKind] = [.expense, .income, .transfer, .creditPurchase, .repayment]
    public var id: Self { self }
    public var title: String { switch self { case .expense: "支出"; case .income: "收入"; case .transfer: "转账"; case .creditPurchase: "信用消费"; case .repayment: "还款"; case .installmentFee: "分期手续费"; case .installmentRefund: "分期退款"; case .reimbursementReceipt: "报销回款" } }
    public var symbol: String { switch self { case .expense: "arrow.up.right"; case .income: "arrow.down.left"; case .transfer: "arrow.left.arrow.right"; case .creditPurchase: "creditcard.fill"; case .repayment: "arrow.uturn.backward"; case .installmentFee: "percent"; case .installmentRefund: "arrow.uturn.left.circle"; case .reimbursementReceipt: "arrow.uturn.backward.circle.fill" } }
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
    public let creditCycleID: UUID?
    public let installmentPlanID: UUID?
    public let installmentRelation: InstallmentRelation?
    public let reimbursementRelations: [ReimbursementRelation]
    public let source: String
    public let postings: [PostingDTO]
    public let version: Int
    public let voidedAt: Date?
    public let createdAt: Date
    public let updatedAt: Date
    enum CodingKeys: String, CodingKey {
        case id, kind, title, note, source, postings, version
        case occurredAt = "occurred_at"; case businessDate = "business_date"; case amountMinor = "amount_minor"
        case categoryID = "category_id"; case accountID = "account_id"; case destinationAccountID = "destination_account_id"; case creditCycleID = "credit_cycle_id"
        case installmentPlanID = "installment_plan_id"; case installmentRelation = "installment_relation"; case reimbursementRelations = "reimbursement_relations"; case voidedAt = "voided_at"
        case createdAt = "created_at"; case updatedAt = "updated_at"
    }

    public init(id: UUID, kind: TransactionKind, occurredAt: Date, businessDate: String, title: String, note: String?, amountMinor: Int64, categoryID: UUID?, accountID: UUID?, destinationAccountID: UUID?, creditCycleID: UUID?, installmentPlanID: UUID? = nil, installmentRelation: InstallmentRelation? = nil, reimbursementRelations: [ReimbursementRelation] = [], source: String, postings: [PostingDTO], version: Int, voidedAt: Date?, createdAt: Date, updatedAt: Date) {
        self.id = id; self.kind = kind; self.occurredAt = occurredAt; self.businessDate = businessDate; self.title = title; self.note = note; self.amountMinor = amountMinor
        self.categoryID = categoryID; self.accountID = accountID; self.destinationAccountID = destinationAccountID; self.creditCycleID = creditCycleID
        self.installmentPlanID = installmentPlanID; self.installmentRelation = installmentRelation; self.reimbursementRelations = reimbursementRelations; self.source = source; self.postings = postings; self.version = version; self.voidedAt = voidedAt; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id); kind = try values.decode(TransactionKind.self, forKey: .kind)
        occurredAt = try values.decode(Date.self, forKey: .occurredAt); businessDate = try values.decode(String.self, forKey: .businessDate)
        title = try values.decode(String.self, forKey: .title); note = try values.decodeIfPresent(String.self, forKey: .note)
        amountMinor = try values.decode(Int64.self, forKey: .amountMinor); categoryID = try values.decodeIfPresent(UUID.self, forKey: .categoryID)
        accountID = try values.decodeIfPresent(UUID.self, forKey: .accountID); destinationAccountID = try values.decodeIfPresent(UUID.self, forKey: .destinationAccountID)
        creditCycleID = try values.decodeIfPresent(UUID.self, forKey: .creditCycleID)
        installmentPlanID = try values.decodeIfPresent(UUID.self, forKey: .installmentPlanID)
        installmentRelation = try values.decodeIfPresent(InstallmentRelation.self, forKey: .installmentRelation)
        reimbursementRelations = try values.decode([ReimbursementRelation].self, forKey: .reimbursementRelations)
        source = try values.decode(String.self, forKey: .source); postings = try values.decode([PostingDTO].self, forKey: .postings)
        version = try values.decode(Int.self, forKey: .version); voidedAt = try values.decodeIfPresent(Date.self, forKey: .voidedAt)
        createdAt = try values.decode(Date.self, forKey: .createdAt); updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }

    public var isUserEditable: Bool { source == "manual" || source == "ai_text" || source == "ocr" }
}

public struct TransactionPage: Codable, Sendable, Equatable {
    public let items: [TransactionDTO]
    public let nextCursor: String?
    enum CodingKeys: String, CodingKey { case items; case nextCursor = "next_cursor" }
}

public enum TransactionClassificationFilter: String, Codable, Sendable, CaseIterable, Identifiable {
    case all, categorized, uncategorized
    public var id: Self { self }
    public var title: String {
        switch self { case .all: "全部"; case .categorized: "已归类"; case .uncategorized: "待归类" }
    }
}

public struct TransactionBatchClassificationItem: Codable, Sendable, Equatable {
    public let transactionID: UUID
    public let expectedVersion: Int
    enum CodingKeys: String, CodingKey {
        case transactionID = "transaction_id"
        case expectedVersion = "expected_version"
    }
    public init(transactionID: UUID, expectedVersion: Int) {
        self.transactionID = transactionID; self.expectedVersion = expectedVersion
    }
}

public struct TransactionBatchClassificationRequest: Codable, Sendable, Equatable {
    public let items: [TransactionBatchClassificationItem]
    public let categoryID: UUID
    enum CodingKeys: String, CodingKey { case items; case categoryID = "category_id" }
    public init(items: [TransactionBatchClassificationItem], categoryID: UUID) {
        self.items = items; self.categoryID = categoryID
    }
}

public struct TransactionBatchClassificationResponse: Codable, Sendable, Equatable {
    public let items: [TransactionDTO]
    public let changedCount: Int
    enum CodingKeys: String, CodingKey { case items; case changedCount = "changed_count" }
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
    public var creditCycleID: UUID?

    public init() {}
    public init(transaction: TransactionDTO) {
        kind = transaction.kind; occurredAt = transaction.occurredAt; title = transaction.title
        note = transaction.note ?? ""; amountMinor = transaction.amountMinor; categoryID = transaction.categoryID
        accountID = transaction.accountID; destinationAccountID = transaction.destinationAccountID; creditCycleID = transaction.creditCycleID
    }
    enum CodingKeys: String, CodingKey {
        case kind, title, note
        case occurredAt = "occurred_at"; case amountMinor = "amount_minor"; case categoryID = "category_id"
        case accountID = "account_id"; case destinationAccountID = "destination_account_id"; case creditCycleID = "credit_cycle_id"
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind); try c.encode(occurredAt, forKey: .occurredAt)
        try c.encode(title.trimmingCharacters(in: .whitespacesAndNewlines), forKey: .title)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        try c.encode(trimmedNote.isEmpty ? nil : trimmedNote, forKey: .note)
        try c.encode(amountMinor, forKey: .amountMinor)
        try c.encode(kind == .expense || kind == .income || kind == .creditPurchase ? categoryID : nil, forKey: .categoryID)
        try c.encode(accountID, forKey: .accountID)
        try c.encode(kind == .transfer || kind == .repayment ? destinationAccountID : nil, forKey: .destinationAccountID)
        try c.encode(kind == .repayment ? creditCycleID : nil, forKey: .creditCycleID)
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
    public var classification: TransactionClassificationFilter = .all
    public var source: String?
    public var amountMinMinor: Int64?
    public var amountMaxMinor: Int64?
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
