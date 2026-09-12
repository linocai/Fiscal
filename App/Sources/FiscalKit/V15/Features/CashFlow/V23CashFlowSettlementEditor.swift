import SwiftUI

struct V23CashFlowSettlementEditor: View {
    @Bindable var model: V15CashFlowModel
    @State private var useExisting = false
    @State private var candidates: [V15Transaction] = []
    @State private var selectedID: UUID?
    @State private var loading = false
    @State private var loadFailure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let item = model.selectedItem {
                Text("计划剩余 \(money(item.effectiveRemainingMinor))").font(V15Typography.cardTitle)
                Text("原计划 \(money(item.plannedAmountMinor)) · 已完成 \(money(item.settledAmountMinor ?? 0))")
                    .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.65))
            }
#if os(macOS)
            V23ChoiceGroup("本次处理方式", selection: $useExisting, choices: [V23Choice(false, "记录本次收付", symbol: "plus.circle"), V23Choice(true, "关联已有账目", symbol: "link")], identifier: "v230.cash-flow.settle.method")
#else
            Picker("本次处理方式", selection: $useExisting) { Text("记录本次收付").tag(false); Text("关联已有账目").tag(true) }
                .pickerStyle(.segmented).accessibilityIdentifier("v230.cash-flow.settle.method")
#endif
            if useExisting { existingSection } else { newSection }
            Toggle("本次已完成全部，不再保留剩余计划", isOn: $model.settleCompleteRemaining)
                .accessibilityIdentifier("v230.cash-flow.settle.complete")
            Text("默认只扣减本次真实收付，未完成部分继续保留；全部完成或明确勾选后才关闭计划。")
                .font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.62))
            if let item = model.selectedItem, let actual = enteredAmount, actual > item.effectiveRemainingMinor {
                Text("本次实际金额 \(money(actual))，超过计划剩余 \(money(item.effectiveRemainingMinor))。请核对差额；实际账目保留真实金额。")
                    .font(V15Typography.secondary).foregroundStyle(V15Palette.warning.color)
            }
            if useExisting {
                V15ActionButton("确认关联，不新建账目", symbol: "link") {
                    if let transaction = candidates.first(where: { $0.id == selectedID }) {
                        Task { await model.settleExisting(transaction: transaction, completeRemaining: model.settleCompleteRemaining) }
                    }
                }.disabled(selectedID == nil || loading || model.writeLocked).accessibilityIdentifier("v230.cash-flow.settle-existing.submit")
            } else {
                V15ActionButton("确认本次入账", symbol: "checkmark", disabledReasons: model.settleReasons) { Task { await model.settle() } }
                    .accessibilityIdentifier("v15.f3d.settle.submit")
            }
            V15FieldIssues(issues: model.settleIssues)
        }
        .disabled(model.writeLocked)
        .task(id: useExisting) { if useExisting { await loadCandidates() } }
    }
    private var newSection: some View {
        V22FormSection("真实发生的收付") {
            V15AmountInput(text: $model.settleAmountText, accessibilityIdentifier: "v15.f3d.settle.amount")
            V15Field("发生日期", text: $model.settleDateText, prompt: "YYYY-MM-DD").accessibilityIdentifier("v15.f3d.settle.date")
            accountSelection("付款或收款账户", selection: $model.settleAccountID)
            if model.selectedItem?.direction == .transfer { accountSelection("转入账户", selection: $model.settleDestinationAccountID) }
            else {
#if os(macOS)
                V23ChoiceGroup("分类", selection: $model.settleCategoryID, choices: [V23Choice(UUID?.none, "未分类")] + categories.map { V23Choice(Optional($0.id), $0.name) }, identifier: "v230.cash-flow.settle.category")
#else
                Picker("分类", selection: $model.settleCategoryID) { Text("未分类").tag(UUID?.none); ForEach(categories) { Text($0.name).tag(Optional($0.id)) } }
#endif
            }
            V15Field("入账标题", text: $model.settleTitle)
            V15Field("备注", text: $model.settleNote, axis: .vertical)
        }
    }
    @ViewBuilder private var existingSection: some View {
        V22FormSection("核对已有正式账目") {
            Text("选择已经入账的收付（包括导入账目）。关联仅更新计划完成进度，不重复生成收支。")
                .font(V15Typography.secondary)
            if loading { V15LoadingSkeleton(layout: .compact) }
            else if let loadFailure { V15ServiceErrorState(message: loadFailure) { Task { await loadCandidates() } } }
            else if candidates.isEmpty { V15EmptyState(title: "暂无可关联账目", explanation: "请核对账户、收付方向和正式入账状态。") }
            else {
                ForEach(candidates, id: \.id) { transaction in
                    V23ChoiceButton("\(transaction.businessDate) · \(transaction.title) · \(money(transaction.amountMinor))", symbol: "doc.text", selected: selectedID == transaction.id) { selectedID = transaction.id }
                        .accessibilityIdentifier("v230.cash-flow.existing.\(transaction.id)")
                }
            }
        }
    }
    @ViewBuilder private func accountSelection(_ title: String, selection: Binding<UUID?>) -> some View {
#if os(macOS)
        V23ChoiceGroup(title, selection: selection, choices: model.cashAccounts.map { V23Choice(Optional($0.id), $0.name, symbol: "wallet.bifold") }, identifier: "v230.cash-flow.account.\(title)")
#else
        Picker(title, selection: selection) { Text("请选择").tag(UUID?.none); ForEach(model.cashAccounts) { Text($0.name).tag(Optional($0.id)) } }
#endif
    }
    private var categories: [V15CategoryResponse] { model.selectedItem?.direction == .inflow ? model.incomeCategories : model.expenseCategories }
    private var enteredAmount: Int64? { useExisting ? candidates.first(where: { $0.id == selectedID })?.amountMinor : CNYAmountParser.minorUnits(model.settleAmountText) }
    private func money(_ amount: Int64) -> String { V15MoneyPresentation(minorUnits: amount, direction: .balance).text }
    private func loadCandidates() async {
        loading = true; loadFailure = nil
        do {
            let values = try await model.settlementCandidates()
            guard !Task.isCancelled else { return }
            candidates = values
            if !values.contains(where: { $0.id == selectedID }) { selectedID = nil }
        } catch {
            guard !Task.isCancelled else { return }
            loadFailure = (error as? V15Failure)?.message ?? "已有账目读取失败，请重试。"
        }
        loading = false
    }
}
