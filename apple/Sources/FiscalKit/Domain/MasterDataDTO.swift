import Foundation

public enum AccountKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case cash, debit, credit
    public var id: Self { self }
    public var title: String { switch self { case .cash: "现金"; case .debit: "储蓄卡"; case .credit: "信用卡" } }
    public var symbol: String { switch self { case .cash: "banknote"; case .debit: "creditcard"; case .credit: "creditcard.fill" } }
}

public struct AccountDTO: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let kind: AccountKind
    public let institution: String?
    public let lastFour: String?
    public let openingBalanceMinor: Int64
    public let creditLimitMinor: Int64?
    public let statementDay: Int?
    public let dueDay: Int?
    public let sortOrder: Int
    public let archivedAt: Date?
    public let usageCount: Int
    public let version: Int
    public let createdAt: Date
    public let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, kind, institution, version
        case lastFour = "last_four"
        case openingBalanceMinor = "opening_balance_minor"
        case creditLimitMinor = "credit_limit_minor"
        case statementDay = "statement_day"
        case dueDay = "due_day"
        case sortOrder = "sort_order"
        case archivedAt = "archived_at"
        case usageCount = "usage_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct AccountDraft: Codable, Sendable, Equatable {
    public var name = ""
    public var kind: AccountKind = .debit
    public var institution = ""
    public var lastFour = ""
    public var openingBalanceMinor: Int64 = 0
    public var creditLimitMinor: Int64?
    public var statementDay: Int?
    public var dueDay: Int?

    public init() {}
    public init(account: AccountDTO) {
        name = account.name; kind = account.kind; institution = account.institution ?? ""; lastFour = account.lastFour ?? ""
        openingBalanceMinor = account.openingBalanceMinor; creditLimitMinor = account.creditLimitMinor
        statementDay = account.statementDay; dueDay = account.dueDay
    }
    enum CodingKeys: String, CodingKey {
        case name, kind, institution
        case lastFour = "last_four"; case openingBalanceMinor = "opening_balance_minor"; case creditLimitMinor = "credit_limit_minor"
        case statementDay = "statement_day"; case dueDay = "due_day"
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name); try c.encode(kind, forKey: .kind)
        try c.encode(institution.nilIfEmpty, forKey: .institution); try c.encode(lastFour.nilIfEmpty, forKey: .lastFour)
        try c.encode(openingBalanceMinor, forKey: .openingBalanceMinor); try c.encode(creditLimitMinor, forKey: .creditLimitMinor)
        try c.encode(statementDay, forKey: .statementDay); try c.encode(dueDay, forKey: .dueDay)
    }
}

public enum CategoryDirection: String, Codable, Sendable, CaseIterable, Identifiable {
    case income, expense
    public var id: Self { self }
    public var title: String { self == .income ? "收入" : "支出" }
}

public struct CategoryDTO: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let direction: CategoryDirection
    public let parentID: UUID?
    public let icon: String
    public let colorHex: String
    public let aliases: [String]
    public let examples: [String]
    public let sortOrder: Int
    public let archivedAt: Date?
    public let usageCount: Int
    public let version: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let children: [CategoryDTO]

    enum CodingKeys: String, CodingKey {
        case id, name, direction, icon, aliases, examples, version, children
        case parentID = "parent_id"
        case colorHex = "color_hex"
        case sortOrder = "sort_order"
        case archivedAt = "archived_at"
        case usageCount = "usage_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        direction = try c.decode(CategoryDirection.self, forKey: .direction); parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        icon = try c.decode(String.self, forKey: .icon); colorHex = try c.decode(String.self, forKey: .colorHex)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []; examples = try c.decodeIfPresent([String].self, forKey: .examples) ?? []
        sortOrder = try c.decode(Int.self, forKey: .sortOrder); archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        usageCount = try c.decode(Int.self, forKey: .usageCount); version = try c.decode(Int.self, forKey: .version)
        createdAt = try c.decode(Date.self, forKey: .createdAt); updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        children = try c.decodeIfPresent([CategoryDTO].self, forKey: .children) ?? []
    }
}

public struct CategoryDraft: Codable, Sendable, Equatable {
    public var name = ""
    public var direction: CategoryDirection = .expense
    public var parentID: UUID?
    public var icon = "tag"
    public var colorHex = "#2E68D6"
    public var aliases: [String] = []
    public var examples: [String] = []

    public init() {}
    public init(category: CategoryDTO) {
        name = category.name; direction = category.direction; parentID = category.parentID
        icon = category.icon; colorHex = category.colorHex; aliases = category.aliases
        examples = category.examples
    }
    enum CodingKeys: String, CodingKey { case name, direction, icon, aliases, examples; case parentID = "parent_id"; case colorHex = "color_hex" }
}

public struct VersionRequest: Codable, Sendable {
    public let expectedVersion: Int
    enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version" }
    public init(version: Int) { expectedVersion = version }
}
public struct OrderedIDsRequest: Codable, Sendable {
    public let orderedIDs: [UUID]
    enum CodingKeys: String, CodingKey { case orderedIDs = "ordered_ids" }
    public init(orderedIDs: [UUID]) { self.orderedIDs = orderedIDs }
}
public struct MergeCategoryRequest: Codable, Sendable {
    public let targetID: UUID; public let sourceExpectedVersion: Int; public let targetExpectedVersion: Int
    enum CodingKeys: String, CodingKey { case targetID = "target_id"; case sourceExpectedVersion = "source_expected_version"; case targetExpectedVersion = "target_expected_version" }
    public init(targetID: UUID, sourceExpectedVersion: Int, targetExpectedVersion: Int) { self.targetID = targetID; self.sourceExpectedVersion = sourceExpectedVersion; self.targetExpectedVersion = targetExpectedVersion }
}
public struct SplitCategoryRequest: Codable, Sendable {
    public let rootExpectedVersion: Int; public let children: [CategoryDraft]
    enum CodingKeys: String, CodingKey { case rootExpectedVersion = "root_expected_version"; case children }
    public init(rootExpectedVersion: Int, children: [CategoryDraft]) { self.rootExpectedVersion = rootExpectedVersion; self.children = children }
}

public struct VersionedAccountDraft: Codable, Sendable {
    public let version: Int
    public let draft: AccountDraft
    public init(version: Int, draft: AccountDraft) { self.version = version; self.draft = draft }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode(version, forKey: .init("expected_version")); try c.encode(draft.name, forKey: .init("name")); try c.encode(draft.kind, forKey: .init("kind"))
        try c.encode(draft.institution.nilIfEmpty, forKey: .init("institution")); try c.encode(draft.lastFour.nilIfEmpty, forKey: .init("last_four"))
        try c.encode(draft.openingBalanceMinor, forKey: .init("opening_balance_minor")); try c.encode(draft.creditLimitMinor, forKey: .init("credit_limit_minor"))
        try c.encode(draft.statementDay, forKey: .init("statement_day")); try c.encode(draft.dueDay, forKey: .init("due_day"))
    }
}

public struct VersionedCategoryDraft: Codable, Sendable {
    public let version: Int
    public let draft: CategoryDraft
    public init(version: Int, draft: CategoryDraft) { self.version = version; self.draft = draft }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode(version, forKey: .init("expected_version")); try c.encode(draft.name, forKey: .init("name")); try c.encode(draft.direction, forKey: .init("direction"))
        try c.encode(draft.parentID, forKey: .init("parent_id")); try c.encode(draft.icon, forKey: .init("icon")); try c.encode(draft.colorHex, forKey: .init("color_hex"))
        try c.encode(draft.aliases, forKey: .init("aliases")); try c.encode(draft.examples, forKey: .init("examples"))
    }
}

public struct DynamicCodingKey: CodingKey, Sendable {
    public let stringValue: String
    public let intValue: Int? = nil
    public init(_ string: String) { stringValue = string }
    public init?(stringValue: String) { self.init(stringValue) }
    public init?(intValue: Int) { return nil }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
