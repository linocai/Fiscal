import SwiftUI

private protocol V15InstallmentPeriodFact {
    var sequence: Int { get }
    var scheduledStatementDate: String { get }
    var effectiveStatementDate: String { get }
    var dueDate: String { get }
    var principalMinor: V15MinorUnits { get }
    var feeMinor: V15MinorUnits { get }
    var amountDueMinor: V15MinorUnits { get }
    var locked: Bool { get }
    var status: V15InstallmentPeriodStatus { get }
}

extension V15InstallmentPeriodPreview: V15InstallmentPeriodFact {}
extension V15CreditCycleInstallmentPeriod: V15InstallmentPeriodFact {}

struct V15InstallmentPurchasePreviewDetails: View {
    let preview: V15InstallmentPurchasePreview
    let prefix: String

    var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            Text("起始账单 \(preview.startStatementDate) · 消费 \(money(preview.purchaseAmountMinor, .outflow)) · 手续费 \(money(preview.totalFeeMinor, .outflow))")
                .font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
            V15MoneyText(minorUnits: preview.totalFinancedMinor, direction: .outflow)
            periodSection("服务端拆分期次", periods: preview.periods, prefix: "\(prefix).period")
        }
    }
}

struct V15InstallmentPlanPreviewDetails: View {
    let preview: V15InstallmentPlanChangePreview
    let prefix: String

    var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            Text("当前 v\(preview.currentPlan.version) · 拟更新 \(preview.proposedPlan.installmentCount) 期 · 起始账单 \(preview.proposedPlan.startStatementDate) · 合计 \(money(preview.proposedPlan.totalFinancedMinor, .outflow))")
                .font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
            periodSection("锁定期（保持服务端事实）", periods: preview.lockedPeriods, prefix: "\(prefix).locked")
            periodSection("未来期（拟更新）", periods: preview.futurePeriods, prefix: "\(prefix).future")
            cycleSection(preview.affectedCycles, prefix: "\(prefix).cycle")
            warningSection(preview.warnings, prefix: "\(prefix).warning")
        }
    }
}

struct V15InstallmentCommandPreviewDetails: View {
    let preview: V15InstallmentModel.CommandPreview
    let prefix: String

    var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            switch preview {
            case .settlement(let value):
                Text("结清金额 \(money(value.amountMinor, .outflow)) · 付款余额 \(money(value.paymentBalanceBeforeMinor, .neutral)) → \(money(value.paymentBalanceAfterMinor, .neutral)) · 债务 \(money(value.debtBeforeMinor, .outflow)) → \(money(value.debtAfterMinor, .outflow))")
                    .font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
                periodSection("结清后的服务端期次", periods: value.proposedPlan.periods, prefix: "\(prefix).settlement.period")
                cycleSection(value.affectedCycles, prefix: "\(prefix).settlement.cycle")
                warningSection(value.warnings, prefix: "\(prefix).settlement.warning")
            case .reverse(let value):
                Text("服务端允许撤销：\(value.eligible ? "是" : "否") · 原还款 \(value.repaymentTransaction.title)（\(value.repaymentTransaction.id.uuidString)） · 付款余额 \(money(value.paymentBalanceBeforeMinor, .neutral)) → \(money(value.paymentBalanceAfterMinor, .neutral)) · 债务 \(money(value.debtBeforeMinor, .outflow)) → \(money(value.debtAfterMinor, .outflow))")
                    .font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(prefix).reverse.eligibility")
                periodSection("恢复期次", periods: value.restoredPeriods, prefix: "\(prefix).reverse.period")
                cycleSection(value.affectedCycles, prefix: "\(prefix).reverse.cycle")
                warningSection(value.warnings, prefix: "\(prefix).reverse.warning")
            case .cancellation(let value):
                Text("本金退款 \(money(value.principalRefundMinor, .inflow)) · 手续费退款 \(money(value.feeRefundMinor, .inflow)) · 债务 \(money(value.debtBeforeMinor, .outflow)) → \(money(value.debtAfterMinor, .outflow)) · 费用 \(money(value.expenseBeforeMinor, .outflow)) → \(money(value.expenseAfterMinor, .outflow))")
                    .font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
                periodSection("取消期次", periods: value.cancelledPeriods, prefix: "\(prefix).cancellation.period")
                periodSection("取消后的服务端期次", periods: value.proposedPlan.periods, prefix: "\(prefix).cancellation.proposed-period")
                cycleSection(value.affectedCycles, prefix: "\(prefix).cancellation.cycle")
                warningSection(value.warnings, prefix: "\(prefix).cancellation.warning")
            }
        }
    }
}

@ViewBuilder
@MainActor
private func periodSection<Period: V15InstallmentPeriodFact>(_ title: String, periods: [Period], prefix: String) -> some View {
    V15Section(title, detail: "\(periods.count) 期") {
        if periods.isEmpty {
            Text("服务端未返回期次。")
                .font(V15Typography.secondary)
        } else {
            ForEach(Array(periods.enumerated()), id: \.offset) { _, period in
                VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("第 \(period.sequence) 期 · \(period.status.rawValue) · \(period.locked ? "已锁定" : "未来期")")
                            .font(V15Typography.body.weight(.semibold))
                        Spacer()
                        V15MoneyText(minorUnits: period.amountDueMinor, direction: .outflow)
                    }
                    Text("计划账单 \(period.scheduledStatementDate) · 生效账单 \(period.effectiveStatementDate) · 到期 \(period.dueDate)")
                    Text("本金 \(money(period.principalMinor, .outflow)) · 手续费 \(money(period.feeMinor, .outflow))")
                }
                .font(V15Typography.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(V15Spacing.sm)
                .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("\(prefix).\(period.sequence)")
            }
        }
    }
}

@ViewBuilder
@MainActor
private func cycleSection(_ cycles: [V15InstallmentAffectedCycle], prefix: String) -> some View {
    V15Section("受影响账期", detail: "\(cycles.count) 个") {
        if cycles.isEmpty {
            Text("服务端未返回受影响账期。")
                .font(V15Typography.secondary)
        } else {
            ForEach(cycles) { cycle in
                VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                    Text("账单 \(cycle.statementDate) · cycle \(cycle.cycleID?.uuidString ?? "尚未生成")")
                        .font(V15Typography.body.weight(.semibold))
                    Text("到期额 \(money(cycle.beforeDueMinor, .outflow)) → \(money(cycle.afterDueMinor, .outflow)) · 变化 \(money(cycle.deltaMinor, .neutral))")
                        .font(V15Typography.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("\(prefix).\(cycle.statementDate)")
            }
        }
    }
}

@ViewBuilder
@MainActor
private func warningSection(_ warnings: [V15InstallmentWarning], prefix: String) -> some View {
    V15Section("服务端警告与原因", detail: "\(warnings.count) 条") {
        if warnings.isEmpty {
            Text("服务端未返回警告。")
                .font(V15Typography.secondary)
        } else {
            ForEach(warnings) { warning in
                Text("\(warning.code)：\(warning.message)")
                    .font(V15Typography.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(V15Spacing.sm)
                    .background(V15Palette.provisional.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
                    .accessibilityIdentifier("\(prefix).\(warning.code)")
            }
        }
    }
}

private func money(_ minor: V15MinorUnits, _ direction: V15MoneyDirection) -> String {
    V15MoneyPresentation(minorUnits: minor, direction: direction).text
}
