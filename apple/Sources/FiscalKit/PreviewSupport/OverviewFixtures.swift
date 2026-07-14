import Foundation

public enum OverviewFixture: String, CaseIterable, Sendable {
    case normal, empty, loading, offline, unauthorized, longContent

    public var snapshot: OverviewSnapshot {
        switch self {
        case .empty, .loading, .offline, .unauthorized:
            return .empty
        case .normal:
            return .sample
        case .longContent:
            return .longContent
        }
    }
}

public extension OverviewSnapshot {
    static let empty = OverviewSnapshot(
        period: "2026 年 7 月 · 本月", spend: .init(minorUnits: 0), previousMonthDelta: 0,
        available: .init(minorUnits: 0), netWorth: .init(minorUnits: 0), cashIn: .init(minorUnits: 0),
        cashOut: .init(minorUnits: 0), creditDue: .init(minorUnits: 0), reimbursementDue: .init(minorUnits: 0),
        uncategorizedCount: 0, categories: [], accounts: [], recent: []
    )

    static let sample = OverviewSnapshot(
        period: "2026 年 7 月 · 本月", spend: .init(minorUnits: 15_420_80), previousMonthDelta: -8.2,
        available: .init(minorUnits: 39_162_15), netWorth: .init(minorUnits: 32_319_85),
        cashIn: .init(minorUnits: 22_702_00), cashOut: .init(minorUnits: 19_015_30),
        creditDue: .init(minorUnits: 6_842_30), reimbursementDue: .init(minorUnits: 601_00),
        uncategorizedCount: 1,
        categories: [
            .init(id: "housing", name: "居住", symbol: "house", amount: .init(minorUnits: 5_800_00), colorHex: 0x4F9A86),
            .init(id: "digital", name: "数码", symbol: "desktopcomputer", amount: .init(minorUnits: 3_299_00), colorHex: 0x77809F),
            .init(id: "food", name: "餐饮", symbol: "fork.knife", amount: .init(minorUnits: 2_146_50), colorHex: 0xC0784A),
            .init(id: "shopping", name: "购物", symbol: "bag", amount: .init(minorUnits: 1_688_20), colorHex: 0x9B78B5)
        ],
        accounts: [
            .init(id: "cmb", name: "招行储蓄卡", detail: "尾号 6621", symbol: "creditcard", amount: .init(minorUnits: 38_642_15), kind: .debit),
            .init(id: "cash", name: "现金", detail: "现金", symbol: "banknote", amount: .init(minorUnits: 520_00), kind: .cash),
            .init(id: "cmb-credit", name: "招行信用卡", detail: "额度 ¥50,000.00", symbol: "creditcard.fill", amount: .init(minorUnits: -6_842_30), kind: .credit)
        ],
        recent: [
            .init(id: "1", title: "山姆会员店", detail: "购物 · 招行信用卡", symbol: "bag", amount: .init(minorUnits: -486_20), direction: .expense, tag: "信用", dateLabel: "今天"),
            .init(id: "2", title: "差旅报销回款", detail: "报销回款 · 招行储蓄卡", symbol: "arrow.uturn.backward", amount: .init(minorUnits: 1_280_00), direction: .income, tag: nil, dateLabel: "今天"),
            .init(id: "3", title: "午餐", detail: "餐饮 · 招行储蓄卡", symbol: "fork.knife", amount: .init(minorUnits: -48_00), direction: .expense, tag: "AI", dateLabel: "昨天"),
            .init(id: "4", title: "待确认商户", detail: "待归类 · 招行信用卡", symbol: "questionmark", amount: .init(minorUnits: -128_00), direction: .expense, tag: "待归类", dateLabel: "7月12日")
        ]
    )

    static let longContent = OverviewSnapshot(
        period: sample.period, spend: sample.spend, previousMonthDelta: sample.previousMonthDelta,
        available: sample.available, netWorth: sample.netWorth, cashIn: sample.cashIn, cashOut: sample.cashOut,
        creditDue: sample.creditDue, reimbursementDue: sample.reimbursementDue, uncategorizedCount: 12,
        categories: sample.categories,
        accounts: sample.accounts + [.init(id: "long", name: "一个用于验证极长账户名称不会破坏布局的个人储蓄账户", detail: "尾号 0000", symbol: "creditcard", amount: .init(minorUnits: 1_00), kind: .debit)],
        recent: sample.recent + [.init(id: "long", title: "这是一笔名称非常长的交易用于验证窄屏幕和动态文字布局", detail: "非常长的分类名称 · 非常长的账户名称", symbol: "doc.text", amount: .init(minorUnits: -9_999_99), direction: .expense, tag: "可报销", dateLabel: "7月11日")]
    )
}
