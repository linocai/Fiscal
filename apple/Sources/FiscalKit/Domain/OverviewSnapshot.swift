import Foundation

public struct Money: Sendable, Equatable, Codable {
    public let minorUnits: Int64
    public let currency: String

    public init(minorUnits: Int64, currency: String = "CNY") {
        self.minorUnits = minorUnits
        self.currency = currency
    }

    public var decimal: Decimal { Decimal(minorUnits) / 100 }
}

public enum FinancialDirection: String, Sendable, Codable {
    case income, expense, neutral
}

public struct CategorySpend: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let symbol: String
    public let amount: Money
    public let colorHex: UInt
}

public struct AccountSummary: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable { case debit, cash, credit }
    public let id: String
    public let name: String
    public let detail: String
    public let symbol: String
    public let amount: Money
    public let kind: Kind
}

public struct RecentActivity: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let detail: String
    public let symbol: String
    public let amount: Money
    public let direction: FinancialDirection
    public let tag: String?
    public let dateLabel: String
}

public struct OverviewSnapshot: Sendable, Equatable {
    public let period: String
    public let spend: Money
    public let previousMonthDelta: Decimal
    public let available: Money
    public let netWorth: Money
    public let cashIn: Money
    public let cashOut: Money
    public let creditDue: Money
    public let reimbursementDue: Money
    public let uncategorizedCount: Int
    public let categories: [CategorySpend]
    public let accounts: [AccountSummary]
    public let recent: [RecentActivity]

    public var cashNet: Money {
        Money(minorUnits: cashIn.minorUnits - cashOut.minorUnits)
    }
}
