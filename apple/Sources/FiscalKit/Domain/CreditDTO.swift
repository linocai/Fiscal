import Foundation

public enum CreditCycleStatus: String, Codable, Sendable, CaseIterable {
    case open, settled, partial, unpaid, overdue
    public var title: String {
        switch self { case .open: "进行中"; case .settled: "已结清"; case .partial: "部分还款"; case .unpaid: "待还款"; case .overdue: "已逾期" }
    }
}

public struct CreditCycleDTO: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let accountID: UUID
    public let periodStart: String
    public let periodEnd: String
    public let statementDate: String
    public let dueDate: String
    public let isOpeningCycle: Bool
    public let purchaseMinor: Int64
    public let openingMinor: Int64
    public let amountDueMinor: Int64
    public let repaidMinor: Int64
    public let remainingMinor: Int64
    public let status: CreditCycleStatus
    public let isOverdue: Bool
    public let version: Int
    public let createdAt: Date
    public let updatedAt: Date
    enum CodingKeys: String, CodingKey {
        case id, status, version
        case accountID = "account_id"; case periodStart = "period_start"; case periodEnd = "period_end"
        case statementDate = "statement_date"; case dueDate = "due_date"; case isOpeningCycle = "is_opening_cycle"
        case purchaseMinor = "purchase_minor"; case openingMinor = "opening_minor"; case amountDueMinor = "amount_due_minor"
        case repaidMinor = "repaid_minor"; case remainingMinor = "remaining_minor"; case isOverdue = "is_overdue"
        case createdAt = "created_at"; case updatedAt = "updated_at"
    }
}

public struct CreditAccountSummaryDTO: Codable, Sendable, Equatable, Identifiable {
    public let accountID: UUID
    public let name: String
    public let institution: String?
    public let lastFour: String?
    public let creditLimitMinor: Int64
    public let statementDay: Int
    public let dueDay: Int
    public let currentDebtMinor: Int64
    public let availableCreditMinor: Int64
    public let overLimitMinor: Int64
    public let openingConfigurationRequired: Bool
    public let currentCycle: CreditCycleDTO?
    public let nextDueCycle: CreditCycleDTO?
    public let hasOverdueCycle: Bool
    public var id: UUID { accountID }
    enum CodingKeys: String, CodingKey {
        case name, institution
        case accountID = "account_id"; case lastFour = "last_four"; case creditLimitMinor = "credit_limit_minor"
        case statementDay = "statement_day"; case dueDay = "due_day"; case currentDebtMinor = "current_debt_minor"
        case availableCreditMinor = "available_credit_minor"; case overLimitMinor = "over_limit_minor"; case openingConfigurationRequired = "opening_configuration_required"; case currentCycle = "current_cycle"; case nextDueCycle = "next_due_cycle"
        case hasOverdueCycle = "has_overdue_cycle"
    }
}

public struct CreditCyclePage: Codable, Sendable, Equatable {
    public let items: [CreditCycleDTO]
    public let nextCursor: String?
    enum CodingKeys: String, CodingKey { case items; case nextCursor = "next_cursor" }
}
