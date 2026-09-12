import SwiftUI

public struct V15CreditPayoffView: View {
    @State private var model: V15CreditPayoffModel
    @State private var payoffPreviewExpired = false
    @State private var reversePreviewExpired = false
    private let accountName: String
    private let operationID: UUID?
    @Environment(\.dismiss) private var dismiss
    public init(services: V15Services, accountID: UUID, accountName: String, operationID: UUID? = nil) {
        _model = State(initialValue: .init(services: services, accountID: accountID))
        self.accountName = accountName; self.operationID = operationID
    }
    public var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    V22PageHeader("全额结清", symbol: "checkmark.seal", subtitle: accountName)
                    Text("统一核对已出账、未出账和剩余分期。以银行实际扣款为准，先查看完整影响再确认。")
                        .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.65))
                    if model.receipt == nil && !model.hasPendingRequest && !model.operations.isEmpty {
                        V22FormSection("历史结清回执") {
                            ForEach(model.operations, id: \.operationID) { operation in
                                V15ActionButton("\(ShanghaiBusinessDate.string(for: operation.occurredAt)) · \(money(operation.actualAmountMinor)) · \(operation.status == "reversed" ? "已撤销" : "已结清")", symbol: "doc.text", kind: .secondary) {
                                    Task { await model.loadReceipt(operationID: operation.operationID) }
                                }
                            }
                        }
                    }
                    if let receipt = model.receipt { receiptSection(receipt) }
                    else { inputSection.disabled(model.hasPendingRequest || model.phase == .submitting) }
                    if let failure = model.historyFailure { V15ServiceErrorState(message: failure.message) { Task { await model.loadHistory() } } }
                    VStack(alignment: .leading, spacing: 12) {
                        phaseSection
                        V15FieldIssues(issues: model.fieldIssues)
                    }.id("payoff-validation")
                    if let preview = model.preview { previewSection(preview) }
                    if let reverse = model.reversePreview {
                        V22FormSection("整组撤销影响") {
                            Text("恢复本组结清前的账簿状态。此操作不向银行申请退款；存在后续依赖时不能撤销。")
                            ForEach(reverse.warnings, id: \.self) { Text($0).foregroundStyle(V15Palette.warning.color) }
                            if reversePreviewExpired {
                                Text("撤销预览已过期，请重新查看影响。").foregroundStyle(V15Palette.warning.color)
                                V15ActionButton("重新查看撤销影响", symbol: "arrow.clockwise", kind: .secondary) { Task { await model.previewReverse() } }
                            }
                            V15ActionButton("确认撤销整组结清", symbol: "arrow.uturn.backward", kind: .destructive) { Task { await model.reverse() } }
                                .disabled(!model.canReverse || reversePreviewExpired).accessibilityIdentifier("v230.payoff.reverse.commit")
                        }
                    }
                    if model.hasPendingRequest {
                        V15ActionButton("安全恢复原请求", symbol: "arrow.clockwise") { Task { await model.recoverPending() } }
                            .disabled(model.phase == .submitting).accessibilityIdentifier("v230.payoff.recover")
                    } else if model.receipt == nil {
                        V15ActionButton("查看结清影响", symbol: "eye", kind: .secondary) { Task { await model.previewPayoff() } }
                            .disabled(model.phase == .loading || model.phase == .submitting).accessibilityIdentifier("v230.payoff.preview")
                        if model.preview != nil {
                            V15ActionButton("确认全额结清", symbol: "checkmark.seal.fill") { Task { await model.commit() } }
                                .disabled(!model.canCommit || payoffPreviewExpired).accessibilityIdentifier("v230.payoff.commit")
                        }
                    }
                }.padding(22)
            }.v22PageCanvas()
#if os(iOS)
            .task(id: validationMessages) {
                guard !validationMessages.isEmpty else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation { scroll.scrollTo("payoff-validation", anchor: .center) }
            }
#endif
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { model.dismiss(); dismiss() } } }
        }
#if os(macOS)
        .frame(minWidth: 620, idealWidth: 740, minHeight: 640)
#endif
        .task { await model.load(); if let operationID { await model.loadReceipt(operationID: operationID) } }
        .task(id: model.preview?.previewExpiresAt) {
            payoffPreviewExpired = false
            guard let expiry = model.preview?.previewExpiresAt else { return }
            do { try await Task.sleep(for: .seconds(max(expiry.timeIntervalSinceNow, 0))) } catch { return }
            guard !Task.isCancelled else { return }
            payoffPreviewExpired = true
        }
        .task(id: model.reversePreview?.previewExpiresAt) {
            reversePreviewExpired = false
            guard let expiry = model.reversePreview?.previewExpiresAt else { return }
            do { try await Task.sleep(for: .seconds(max(expiry.timeIntervalSinceNow, 0))) } catch { return }
            guard !Task.isCancelled else { return }
            reversePreviewExpired = true
        }
        .onDisappear { model.dismiss() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v230.payoff.sheet")
    }
    private var validationMessages: [String] {
        var messages = model.fieldIssues.map(\.message)
        if case .failed(let failure) = model.phase { messages.append(failure.message) }
        return messages
    }
    private var inputSection: some View {
        V22FormSection("银行核对") {
#if os(macOS)
            V23ChoiceGroup("实际付款账户", selection: $model.paymentAccountID, choices: model.paymentAccounts.map { V23Choice(Optional($0.id), $0.name, symbol: "wallet.bifold") }, identifier: "v230.payoff.payment-account")
#else
            Picker("实际付款账户", selection: $model.paymentAccountID) {
                Text("请选择").tag(UUID?.none)
                ForEach(model.paymentAccounts) { Text($0.name).tag(Optional($0.id)) }
            }.accessibilityIdentifier("v230.payoff.payment-account")
#endif
            V23BusinessDatePicker("实际结清日期", selection: $model.occurredAt)
            V15Field("银行实扣（元）", text: $model.actualAmountText, prompt: "0.00", keyboard: .decimal).accessibilityIdentifier("v230.payoff.actual")
            V15AdaptiveStack(spacing: 14) {
                V15Field("额外手续费（元）", text: $model.additionalFeeText, keyboard: .decimal).accessibilityIdentifier("v230.payoff.additional-fee")
                V15Field("本金减免（元）", text: $model.waivedPrincipalText, keyboard: .decimal).accessibilityIdentifier("v230.payoff.waived-principal")
                V15Field("手续费减免（元）", text: $model.waivedFeeText, keyboard: .decimal).accessibilityIdentifier("v230.payoff.waived-fee")
            }
            Text("实扣 = 账面剩余欠款 − 本金减免 − 手续费减免 ＋ 额外手续费。差额须与银行核对，不自动填成减免。")
                .font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.62))
            V15Field("银行核对说明", text: $model.note, prompt: "存在费用或减免时必填", axis: .vertical)
            Toggle("我已确认银行将此账户全额结清", isOn: $model.bankConfirmedSettled)
                .accessibilityIdentifier("v230.payoff.bank-confirmed")
        }
    }
    private func previewSection(_ value: V15CreditPayoffPreview) -> some View {
        V22FormSection("一次结清的完整影响") {
            amountRow("付款账户余额", before: value.paymentBalanceBeforeMinor, after: value.paymentBalanceAfterMinor)
            amountRow("信用欠款", before: value.debtBeforeMinor, after: value.debtAfterMinor)
            V22Metric("银行实际扣款", minorUnits: value.actualAmountMinor, direction: .outflow)
            Text("本金 \(money(value.principalMinor)) · 已有费用 \(money(value.feeMinor))")
            Text("本金减免 \(money(value.waivedPrincipalMinor)) · 费用减免 \(money(value.waivedFeeMinor)) · 额外费用 \(money(value.additionalFeeMinor))")
            Text("将关闭 \(value.closingInstallmentPlanIDs.count) 个剩余分期计划")
            allocations(value.allocations)
            ForEach(value.warnings, id: \.self) { Text($0).foregroundStyle(V15Palette.warning.color) }
            if payoffPreviewExpired { Text("结清预览已过期，请重新查看结清影响后确认。").foregroundStyle(V15Palette.warning.color) }
            if !value.executable { Text("当前无法执行，请核对以上信息并重新预览。").foregroundStyle(V15Palette.danger.color) }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("v230.payoff.preview.details")
    }
    private func receiptSection(_ value: V15CreditPayoffReceipt) -> some View {
        V22FormSection(value.status == "reversed" ? "整组结清已撤销" : "全额结清已完成") {
            Text("\(value.status == "reversed" ? "原结清实扣" : "银行实扣") \(money(value.actualAmountMinor))").font(V15Typography.cardTitle)
            amountRow("信用欠款", before: value.debtBeforeMinor, after: value.debtAfterMinor)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("v230.payoff.receipt.debt-change")
                .accessibilityValue("\(money(value.debtBeforeMinor)) → \(money(value.debtAfterMinor))")
            DisclosureGroup("查看内部账目与分摊（\(value.transactionIDs.count) 笔）") {
                allocations(value.allocations)
                ForEach(value.transactionIDs, id: \.self) { Text("账目 \($0.uuidString)").font(V15Typography.label).textSelection(.enabled) }
            }
            if value.status != "reversed" && model.reversePreview == nil {
                V15ActionButton("查看整组撤销影响", symbol: "arrow.uturn.backward", kind: .secondary) { Task { await model.previewReverse() } }
                    .disabled(model.phase == .loading || model.hasPendingRequest).accessibilityIdentifier("v230.payoff.reverse.preview")
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("v230.payoff.receipt")
    }
    @ViewBuilder private var phaseSection: some View {
        switch model.phase {
        case .loading, .submitting: V15LoadingSkeleton(layout: .compact)
        case .unknown: V15OutcomeUnknownState(message: "暂时无法确认结果。原请求已保留，请安全恢复，不会另建一笔结清。")
        case .failed(let failure):
            VStack(alignment: .leading, spacing: 6) {
                Label("未能完成，请核对", systemImage: "exclamationmark.circle").font(V15Typography.body.weight(.semibold))
                Text(failure.message).font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
            }.foregroundStyle(V15Palette.danger.color).padding(14).v22FormSurface().accessibilityIdentifier("v230.payoff.error")
        default: EmptyView()
        }
    }
    private func amountRow(_ title: String, before: Int64, after: Int64) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(V15Typography.secondary); Text("\(money(before)) → \(money(after))").font(V15Typography.money).monospacedDigit() }
    }
    private func allocations(_ values: [V15CreditPayoffAllocation]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.cycleID == nil ? "随借随还账户" : "账期 \(index + 1)").font(V15Typography.body.weight(.semibold))
                    Text("剩余 \(money(item.remainingMinor)) · 实还 \(money(item.repaidMinor))")
                    Text("本金 \(money(item.principalMinor)) · 费用 \(money(item.feeMinor)) · 减免本金 \(money(item.waivedPrincipalMinor)) · 减免费用 \(money(item.waivedFeeMinor))")
                    if !item.installmentPlanIDs.isEmpty { Text("覆盖 \(item.installmentPlanIDs.count) 个分期计划") }
                }.font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func money(_ amount: Int64) -> String { V15MoneyPresentation(minorUnits: amount, direction: .balance).text }
}
