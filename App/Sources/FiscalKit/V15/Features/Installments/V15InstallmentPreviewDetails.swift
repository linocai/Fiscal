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
            periodSection("分期期次", periods: preview.periods, prefix: "\(prefix).period")
        }
    }
}

struct V15InstallmentPlanPreviewDetails: View {
    let preview: V15InstallmentPlanChangePreview
    let prefix: String

    var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            HStack(alignment: .top, spacing: V15Spacing.sm) {
                planComparison(
                    "当前计划",
                    count: preview.currentPlan.installmentCount,
                    start: preview.currentPlan.startStatementDate,
                    total: preview.currentPlan.totalFinancedMinor,
                    future: preview.currentPlan.futureScheduledGrossMinor,
                    provisional: false
                )
                planComparison(
                    "拟更新",
                    count: preview.proposedPlan.installmentCount,
                    start: preview.proposedPlan.startStatementDate,
                    total: preview.proposedPlan.totalFinancedMinor,
                    future: preview.proposedPlan.futureScheduledGrossMinor,
                    provisional: true
                )
            }
            .accessibilityIdentifier("\(prefix).comparison")
            periodSection("锁定期（保持不变）", periods: preview.lockedPeriods, prefix: "\(prefix).locked")
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
                VStack(alignment: .leading, spacing: V15Spacing.sm) {
                    Text("提前结清预览").font(V15Typography.body.weight(.semibold))
                    V15MoneyText(minorUnits: value.amountMinor, direction: .outflow, font: V15Typography.moneyLarge)
                    HStack(alignment: .top, spacing: V15Spacing.sm) {
                        beforeAfter("付款账户余额", before: value.paymentBalanceBeforeMinor, after: value.paymentBalanceAfterMinor, direction: .balance)
                        beforeAfter("当前信用欠款", before: value.debtBeforeMinor, after: value.debtAfterMinor, direction: .outflow)
                    }
                    Text("请分别核对结清款、付款账户余额和当前信用欠款；确认后将按下方计划终止未来期次。")
                        .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("\(prefix).settlement.facts")
                periodSection("结清后的期次", periods: value.proposedPlan.periods, prefix: "\(prefix).settlement.period")
                cycleSection(value.affectedCycles, prefix: "\(prefix).settlement.cycle")
                warningSection(value.warnings, prefix: "\(prefix).settlement.warning")
            case .reverse(let value):
                VStack(alignment: .leading, spacing: V15Spacing.sm) {
                    Text("\(value.eligible ? "可以撤销" : "暂时不能撤销") · 原还款 \(value.repaymentTransaction.title)")
                        .font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: V15Spacing.sm) {
                        beforeAfter("付款账户余额", before: value.paymentBalanceBeforeMinor, after: value.paymentBalanceAfterMinor, direction: .balance)
                        beforeAfter("当前信用欠款", before: value.debtBeforeMinor, after: value.debtAfterMinor, direction: .outflow)
                    }
                }.accessibilityIdentifier("\(prefix).reverse.eligibility")
                periodSection("恢复期次", periods: value.restoredPeriods, prefix: "\(prefix).reverse.period")
                cycleSection(value.affectedCycles, prefix: "\(prefix).reverse.cycle")
                warningSection(value.warnings, prefix: "\(prefix).reverse.warning")
            case .cancellation(let value):
                VStack(alignment: .leading, spacing: V15Spacing.sm) {
                    HStack { previewFact("本金退款", value.principalRefundMinor, .inflow); previewFact("手续费退款", value.feeRefundMinor, .inflow) }
                    HStack(alignment: .top, spacing: V15Spacing.sm) {
                        beforeAfter("当前信用欠款", before: value.debtBeforeMinor, after: value.debtAfterMinor, direction: .outflow)
                        beforeAfter("费用变化", before: value.expenseBeforeMinor, after: value.expenseAfterMinor, direction: .outflow)
                    }
                }
                periodSection("取消期次", periods: value.cancelledPeriods, prefix: "\(prefix).cancellation.period")
                periodSection("取消后的期次", periods: value.proposedPlan.periods, prefix: "\(prefix).cancellation.proposed-period")
                cycleSection(value.affectedCycles, prefix: "\(prefix).cancellation.cycle")
                warningSection(value.warnings, prefix: "\(prefix).cancellation.warning")
            }
        }
    }
}

@MainActor
private func planComparison(_ title: String, count: Int, start: String, total: V15MinorUnits, future: V15MinorUnits, provisional: Bool) -> some View {
    VStack(alignment: .leading, spacing: V15Spacing.xs) {
        Text(title).font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.62))
        Text("\(count) 期").font(V15Typography.cardTitle)
        Text("起始账单 \(start)").font(V15Typography.secondary)
        Text("计划合计 \(money(total, .neutral))").font(V15Typography.secondary)
        Text("未来未出账 \(money(future, .neutral))").font(V15Typography.secondary.weight(.semibold))
    }
    .padding(V15Spacing.sm).frame(maxWidth: .infinity, alignment: .topLeading)
    .background(provisional ? V15Palette.provisional.color : V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
    .overlay { RoundedRectangle(cornerRadius: V15Radius.control).stroke(provisional ? V15Palette.yellow.color : V15Palette.hairline.color, style: StrokeStyle(lineWidth: 1, dash: provisional ? [4, 3] : [])) }
}

@MainActor
private func beforeAfter(_ title: String, before: V15MinorUnits, after: V15MinorUnits, direction: V15MoneyDirection) -> some View {
    VStack(alignment: .leading, spacing: V15Spacing.xxs) {
        Text(title).font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.62))
        Text(money(before, direction)).font(V15Typography.secondary.monospacedDigit())
        Image(systemName: "arrow.down").font(.caption).foregroundStyle(V15Palette.ink.color.opacity(0.45))
        Text(money(after, direction)).font(V15Typography.body.weight(.semibold).monospacedDigit())
    }
    .padding(V15Spacing.sm).frame(maxWidth: .infinity, alignment: .leading)
    .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
}

@MainActor
private func previewFact(_ title: String, _ value: V15MinorUnits, _ direction: V15MoneyDirection) -> some View {
    VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text(title).font(V15Typography.label); Text(money(value, direction)).font(V15Typography.body.weight(.semibold).monospacedDigit()) }
        .padding(V15Spacing.sm).frame(maxWidth: .infinity, alignment: .leading).background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
}

@ViewBuilder
@MainActor
private func periodSection<Period: V15InstallmentPeriodFact>(_ title: String, periods: [Period], prefix: String) -> some View {
    V15Section(title, detail: "\(periods.count) 期") {
        if periods.isEmpty {
            Text("没有期次。")
                .font(V15Typography.secondary)
        } else {
            ForEach(Array(periods.enumerated()), id: \.offset) { _, period in
                VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("第 \(period.sequence) 期 · \(period.status.displayName) · \(period.locked ? "已锁定" : "未来期")")
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
            Text("没有受影响的账期。")
                .font(V15Typography.secondary)
        } else {
            ForEach(cycles) { cycle in
                VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                    Text("账单 \(cycle.statementDate)")
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
    V15Section("提示与原因", detail: "\(warnings.count) 条") {
        if warnings.isEmpty {
            Text("没有额外提示。")
                .font(V15Typography.secondary)
        } else {
            ForEach(warnings) { warning in
                Text(warning.message)
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
