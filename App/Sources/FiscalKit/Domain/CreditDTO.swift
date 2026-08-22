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
    public let installmentPrincipalMinor: Int64
    public let installmentFeeMinor: Int64
    public let installmentPeriods: [InstallmentPeriodDTO]
    public let version: Int
    public let createdAt: Date
    public let updatedAt: Date
    enum CodingKeys: String, CodingKey {
        case id, status, version
        case accountID = "account_id"; case periodStart = "period_start"; case periodEnd = "period_end"
        case statementDate = "statement_date"; case dueDate = "due_date"; case isOpeningCycle = "is_opening_cycle"
        case purchaseMinor = "purchase_minor"; case openingMinor = "opening_minor"; case amountDueMinor = "amount_due_minor"
        case repaidMinor = "repaid_minor"; case remainingMinor = "remaining_minor"; case isOverdue = "is_overdue"
        case installmentPrincipalMinor = "installment_principal_minor"; case installmentFeeMinor = "installment_fee_minor"; case installmentPeriods = "installment_periods"
        case createdAt = "created_at"; case updatedAt = "updated_at"
    }

    public init(id: UUID, accountID: UUID, periodStart: String, periodEnd: String, statementDate: String, dueDate: String, isOpeningCycle: Bool, purchaseMinor: Int64, openingMinor: Int64, amountDueMinor: Int64, repaidMinor: Int64, remainingMinor: Int64, status: CreditCycleStatus, isOverdue: Bool, installmentPrincipalMinor: Int64 = 0, installmentFeeMinor: Int64 = 0, installmentPeriods: [InstallmentPeriodDTO] = [], version: Int, createdAt: Date, updatedAt: Date) {
        self.id = id; self.accountID = accountID; self.periodStart = periodStart; self.periodEnd = periodEnd; self.statementDate = statementDate; self.dueDate = dueDate; self.isOpeningCycle = isOpeningCycle
        self.purchaseMinor = purchaseMinor; self.openingMinor = openingMinor; self.amountDueMinor = amountDueMinor; self.repaidMinor = repaidMinor; self.remainingMinor = remainingMinor; self.status = status; self.isOverdue = isOverdue
        self.installmentPrincipalMinor = installmentPrincipalMinor; self.installmentFeeMinor = installmentFeeMinor; self.installmentPeriods = installmentPeriods; self.version = version; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id); accountID = try values.decode(UUID.self, forKey: .accountID)
        periodStart = try values.decode(String.self, forKey: .periodStart); periodEnd = try values.decode(String.self, forKey: .periodEnd)
        statementDate = try values.decode(String.self, forKey: .statementDate); dueDate = try values.decode(String.self, forKey: .dueDate)
        isOpeningCycle = try values.decode(Bool.self, forKey: .isOpeningCycle); purchaseMinor = try values.decode(Int64.self, forKey: .purchaseMinor)
        openingMinor = try values.decode(Int64.self, forKey: .openingMinor); amountDueMinor = try values.decode(Int64.self, forKey: .amountDueMinor)
        repaidMinor = try values.decode(Int64.self, forKey: .repaidMinor); remainingMinor = try values.decode(Int64.self, forKey: .remainingMinor)
        status = try values.decode(CreditCycleStatus.self, forKey: .status); isOverdue = try values.decode(Bool.self, forKey: .isOverdue)
        installmentPrincipalMinor = try values.decode(Int64.self, forKey: .installmentPrincipalMinor)
        installmentFeeMinor = try values.decode(Int64.self, forKey: .installmentFeeMinor)
        installmentPeriods = try values.decode([InstallmentPeriodDTO].self, forKey: .installmentPeriods)
        version = try values.decode(Int.self, forKey: .version); createdAt = try values.decode(Date.self, forKey: .createdAt); updatedAt = try values.decode(Date.self, forKey: .updatedAt)
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
    public let cycleMode: CreditCycleMode
    public let currentDebtMinor: Int64
    public let availableCreditMinor: Int64
    public let overLimitMinor: Int64
    public let openingConfigurationRequired: Bool
    public let currentCycle: CreditCycleDTO?
    public let nextDueCycle: CreditCycleDTO?
    public let hasOverdueCycle: Bool
    public let activeInstallmentCount: Int
    public let futureScheduledGrossMinor: Int64
    public let nextInstallment: InstallmentTeaser?
    public var id: UUID { accountID }
    enum CodingKeys: String, CodingKey {
        case name, institution
        case accountID = "account_id"; case lastFour = "last_four"; case creditLimitMinor = "credit_limit_minor"
        case statementDay = "statement_day"; case dueDay = "due_day"; case cycleMode = "cycle_mode"; case currentDebtMinor = "current_debt_minor"
        case availableCreditMinor = "available_credit_minor"; case overLimitMinor = "over_limit_minor"; case openingConfigurationRequired = "opening_configuration_required"; case currentCycle = "current_cycle"; case nextDueCycle = "next_due_cycle"
        case hasOverdueCycle = "has_overdue_cycle"; case activeInstallmentCount = "active_installment_count"
        case futureScheduledGrossMinor = "future_scheduled_gross_minor"; case nextInstallment = "next_installment"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try values.decode(UUID.self, forKey: .accountID); name = try values.decode(String.self, forKey: .name)
        institution = try values.decodeIfPresent(String.self, forKey: .institution); lastFour = try values.decodeIfPresent(String.self, forKey: .lastFour)
        creditLimitMinor = try values.decode(Int64.self, forKey: .creditLimitMinor); statementDay = try values.decode(Int.self, forKey: .statementDay); dueDay = try values.decode(Int.self, forKey: .dueDay)
        cycleMode = try values.decodeIfPresent(CreditCycleMode.self, forKey: .cycleMode) ?? .statementDayCutoff
        currentDebtMinor = try values.decode(Int64.self, forKey: .currentDebtMinor); availableCreditMinor = try values.decode(Int64.self, forKey: .availableCreditMinor); overLimitMinor = try values.decode(Int64.self, forKey: .overLimitMinor)
        openingConfigurationRequired = try values.decode(Bool.self, forKey: .openingConfigurationRequired)
        currentCycle = try values.decode(Optional<CreditCycleDTO>.self, forKey: .currentCycle); nextDueCycle = try values.decode(Optional<CreditCycleDTO>.self, forKey: .nextDueCycle)
        hasOverdueCycle = try values.decode(Bool.self, forKey: .hasOverdueCycle)
        activeInstallmentCount = try values.decode(Int.self, forKey: .activeInstallmentCount)
        futureScheduledGrossMinor = try values.decode(Int64.self, forKey: .futureScheduledGrossMinor)
        nextInstallment = try values.decode(Optional<InstallmentTeaser>.self, forKey: .nextInstallment)
    }
}

public struct CreditCyclePage: Codable, Sendable, Equatable {
    public let items: [CreditCycleDTO]
    public let nextCursor: String?
    enum CodingKeys: String, CodingKey { case items; case nextCursor = "next_cursor" }
}
