import SwiftUI

private func installmentDisplayError(_ error: Error) -> String { (error as? FiscalAPIError)?.displayMessage ?? error.localizedDescription }

private extension InstallmentPlanStatus {
    var color: Color {
        switch self { case .active: FiscalColor.debt; case .completed, .settledEarly: FiscalColor.income; case .partiallyCancelled: FiscalColor.reimbursement; case .cancelled: FiscalColor.tertiary }
    }
}

private extension InstallmentPeriodStatus {
    var color: Color {
        switch self { case .scheduled, .billed: FiscalColor.debt; case .partial: FiscalColor.reimbursement; case .cycleSettled, .settledEarly: FiscalColor.income; case .overdue: FiscalColor.expense; case .cancelled: FiscalColor.tertiary }
    }
}

private struct InstallmentStatusPill: View {
    let title: String; let color: Color
    var body: some View { Text(title).font(.caption2.weight(.semibold)).foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 4).background(color.opacity(0.11), in: .capsule) }
}

private struct InstallmentEditorCanvas<Content: View, Actions: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    init(@ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.content = content(); self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            Divider()
            actions
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .background(.regularMaterial)
        }
        .background(FiscalColor.iOSBackground)
    }
}

private struct InstallmentEditorCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.content = content()
    }

    var body: some View {
        FiscalCard(radius: 18) {
            VStack(alignment: .leading, spacing: 12) {
                if let title { Text(title).font(.headline) }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct InstallmentEditorNotice: View {
    let message: String; let symbol: String; let color: Color
    var body: some View {
        Label(message, systemImage: symbol)
            .font(.subheadline).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public struct InstallmentCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var installments: InstallmentModel
    let purchase: TransactionDTO
    let categories: CategoriesModel
    @State private var installmentCount = 6
    @State private var feeText = "0"
    @State private var feeCategoryID: UUID?
    @State private var feeOccurredAt = Date()
    @State private var startStatementDate = ""
    @State private var categoryOptions: [CategoryDTO] = []
    @State private var idempotencyKey = UUID()
    @State private var validation: String?
    @State private var optionsLoading = true
    @State private var optionsError: String?

    public init(installments: InstallmentModel, purchase: TransactionDTO, categories: CategoriesModel) { self.installments = installments; self.purchase = purchase; self.categories = categories }

    public var body: some View {
        NavigationStack {
            InstallmentEditorCanvas {
                InstallmentEditorCard("关联信用消费") {
                    LabeledContent("消费", value: purchase.title)
                    LabeledContent("本金", value: Money(minorUnits: purchase.amountMinor).formatted())
                }
                InstallmentEditorCard("分期安排") {
                    Stepper("期数：\(installmentCount)", value: $installmentCount, in: 2...60)
                    TextField("固定手续费", text: $feeText)
#if os(iOS)
                        .keyboardType(.decimalPad)
#endif
                    if feeMinor > 0 {
                        Picker("手续费分类", selection: $feeCategoryID) { Text("请选择").tag(Optional<UUID>.none); ForEach(categoryOptions.filter { $0.direction == .expense && $0.archivedAt == nil }) { Text($0.name).tag(Optional($0.id)) } }
                        DatePicker("手续费确认时间", selection: $feeOccurredAt)
                    }
                    Picker("起始账单日", selection: $startStatementDate) {
                        Text("请选择").tag("")
                        ForEach(installments.eligibility?.startOptions.filter(\.eligible) ?? []) { Text("\($0.statementDate) · 到期 \($0.dueDate)").tag($0.statementDate) }
                    }
                }
                if let eligibility = installments.eligibility, !eligibility.eligible {
                    InstallmentEditorCard { InstallmentEditorNotice(message: eligibility.reasonCode ?? "该消费当前不能分期", symbol: "exclamationmark.triangle", color: FiscalColor.expense) }
                }
                if optionsLoading { InstallmentEditorCard { ProgressView("正在读取分类…") } }
                if let optionsError {
                    InstallmentEditorCard {
                        InstallmentEditorNotice(message: optionsError, symbol: "wifi.exclamationmark", color: FiscalColor.expense)
                        Button("重试") { Task { await loadDependencies() } }
                    }
                }
                if let message = validation ?? installments.message {
                    InstallmentEditorCard { InstallmentEditorNotice(message: message, symbol: "exclamationmark.triangle", color: FiscalColor.expense) }
                }
                Text("分期只安排已记入账本的本金与固定手续费；不会再次记录消费。未来计划额是未扣除通用部分还款的毛额。")
                    .font(.caption).foregroundStyle(FiscalColor.tertiary).padding(.horizontal, 4)
            } actions: {
                Button("创建分期计划") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(installments.isMutating || installments.eligibility?.eligible != true || optionsLoading || optionsError != nil)
            }
            .navigationTitle("创建分期计划")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .task { await loadDependencies() }
        }.installmentEditorFrame(width: 500, height: 600)
    }

    private var feeMinor: Int64 { CNYAmountParser.minorUnits(feeText) ?? -1 }
    private func loadDependencies() async {
        optionsLoading = true; optionsError = nil
        await installments.checkEligibility(transactionID: purchase.id)
        if let value = installments.eligibility { startStatementDate = value.startOptions.first(where: \.eligible)?.statementDate ?? "" }
        do { categoryOptions = try await categories.transactionOptions(); feeCategoryID = purchase.categoryID }
        catch { categoryOptions = []; optionsError = "分类读取失败：\(installmentDisplayError(error))" }
        optionsLoading = false
    }
    private func create() {
        guard (0...Int64.max).contains(feeMinor), !startStatementDate.isEmpty else { validation = "请输入有效手续费并选择起始账单日。"; return }
        guard feeMinor == 0 || feeCategoryID != nil else { validation = "非零手续费需要支出分类。"; return }
        validation = nil
        let request = InstallmentCreateRequest(purchaseTransactionID: purchase.id, installmentCount: installmentCount, totalFeeMinor: feeMinor, feeCategoryID: feeMinor == 0 ? nil : feeCategoryID, feeOccurredAt: feeMinor == 0 ? nil : feeOccurredAt, startStatementDate: startStatementDate)
        Task { if await installments.create(request, idempotencyKey: idempotencyKey) != nil { dismiss() } }
    }
}

public struct InstallmentEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var installments: InstallmentModel
    let plan: InstallmentPlanDTO
    let purchase: TransactionDTO
    let accounts: AccountsModel
    let categories: CategoriesModel
    @State private var replacement: InstallmentPurchaseReplacement
    @State private var installmentCount: Int
    @State private var feeText: String
    @State private var feeCategoryID: UUID?
    @State private var feeOccurredAt: Date
    @State private var startStatementDate: String
    @State private var categoryOptions: [CategoryDTO] = []
    @State private var accountOptions: [AccountDTO] = []
    @State private var validation: String?
    @State private var optionsLoading = true
    @State private var optionsError: String?

    public init(installments: InstallmentModel, plan: InstallmentPlanDTO, purchase: TransactionDTO, accounts: AccountsModel, categories: CategoriesModel) {
        self.installments = installments; self.plan = plan; self.purchase = purchase; self.accounts = accounts; self.categories = categories
        // A credit purchase always carries an account and category, but decode defensively rather
        // than force-unwrapping (L1); a missing reference is caught in request() before any save.
        _replacement = State(initialValue: .init(amountMinor: purchase.amountMinor, occurredAt: purchase.occurredAt, title: purchase.title, note: purchase.note, accountID: purchase.accountID ?? Self.missingReference, categoryID: purchase.categoryID ?? Self.missingReference))
        _installmentCount = State(initialValue: plan.installmentCount); _feeText = State(initialValue: Self.major(plan.feeMinor)); _feeCategoryID = State(initialValue: plan.feeCategoryID)
        _feeOccurredAt = State(initialValue: plan.feeOccurredAt ?? purchase.occurredAt); _startStatementDate = State(initialValue: plan.startStatementDate)
    }

    public var body: some View {
        NavigationStack {
            InstallmentEditorCanvas {
                InstallmentEditorCard("消费") {
                    TextField("标题", text: $replacement.title)
                    TextField("备注", text: Binding(get: { replacement.note ?? "" }, set: { replacement.note = $0.isEmpty ? nil : $0 }))
                    TextField("本金", text: amountBinding).disabled(plan.lockedCount > 0)
                    DatePicker("发生时间", selection: $replacement.occurredAt).disabled(plan.lockedCount > 0)
                    Picker("信用账户", selection: $replacement.accountID) { ForEach(accountOptions.filter { $0.kind == .credit && ($0.archivedAt == nil || $0.id == purchase.accountID) }) { Text($0.name).tag($0.id) } }.disabled(plan.lockedCount > 0)
                    Picker("消费分类", selection: $replacement.categoryID) { ForEach(categoryOptions.filter { $0.direction == .expense && ($0.archivedAt == nil || $0.id == purchase.categoryID) }) { Text($0.name).tag($0.id) } }.disabled(plan.lockedCount > 0)
                }
                InstallmentEditorCard("未来期次") {
                    Stepper("总期数：\(installmentCount)", value: $installmentCount, in: installmentCountRange)
                    TextField("固定手续费", text: $feeText).disabled(plan.lockedCount > 0)
                    if feeMinor > 0 { Picker("手续费分类", selection: $feeCategoryID) { Text("请选择").tag(Optional<UUID>.none); ForEach(categoryOptions.filter { $0.direction == .expense && $0.archivedAt == nil }) { Text($0.name).tag(Optional($0.id)) } }.disabled(plan.lockedCount > 0); DatePicker("手续费确认时间", selection: $feeOccurredAt).disabled(plan.lockedCount > 0) }
                    Picker("起始账单日", selection: $startStatementDate) {
                        if let legacyStartStatementDate {
                            Text("\(legacyStartStatementDate) · 原计划起始账单日").tag(legacyStartStatementDate)
                        }
                        ForEach(eligibleCycleOptions) { Text("\($0.statementDate) · 到期 \($0.dueDate)").tag($0.statementDate) }
                    }.disabled(plan.lockedCount > 0)
                    if plan.lockedCount > 0 { Label("前 \(plan.lockedCount) 期已锁定；只能调整标题、备注和未来期数。", systemImage: "lock.fill").font(.caption).foregroundStyle(FiscalColor.secondary) }
                }
                if let preview = installments.changePreview {
                    InstallmentEditorCard("服务器影响预览") {
                        LabeledContent("未来计划毛额", value: Money(minorUnits: preview.proposedPlan.futureScheduledGrossMinor).formatted())
                        LabeledContent("受影响账期", value: "\(preview.affectedCycles.count) 个")
                        ForEach(preview.warnings) { Label($0.message, systemImage: "exclamationmark.triangle") }
                    }
                }
                if optionsLoading { InstallmentEditorCard { ProgressView("正在读取账户、分类与账期…") } }
                if let optionsError {
                    InstallmentEditorCard {
                        InstallmentEditorNotice(message: optionsError, symbol: "wifi.exclamationmark", color: FiscalColor.expense)
                        Button("重试") { Task { await loadDependencies() } }
                    }
                }
                if installments.conflictDetected {
                    InstallmentEditorCard {
                        InstallmentEditorNotice(message: "计划已在其他操作中变化。", symbol: "arrow.triangle.2.circlepath", color: FiscalColor.expense)
                        Button("刷新计划") { refreshConflict() }
                    }
                }
                if let message = validation ?? installments.message {
                    InstallmentEditorCard { InstallmentEditorNotice(message: message, symbol: "exclamationmark.triangle", color: FiscalColor.expense) }
                }
            } actions: {
                if installments.changePreview == nil {
                    Button("预览服务器影响") { preview() }
                        .buttonStyle(.borderedProminent).disabled(optionsLoading || optionsError != nil)
                } else {
                    Button("确认保存") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(installments.isMutating || optionsLoading || optionsError != nil)
                }
            }
            .navigationTitle("编辑分期")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .task { await loadDependencies() }
            .onChange(of: replacement) { _, _ in installments.invalidateChangePreview() }
            .onChange(of: installmentCount) { _, _ in installments.invalidateChangePreview() }
            .onChange(of: feeText) { _, _ in installments.invalidateChangePreview() }
            .onChange(of: feeCategoryID) { _, _ in installments.invalidateChangePreview() }
            .onChange(of: feeOccurredAt) { _, _ in installments.invalidateChangePreview() }
            .onChange(of: startStatementDate) { _, _ in installments.invalidateChangePreview() }
        }.installmentEditorFrame(width: 520, height: 650)
    }
    private var installmentCountRange: ClosedRange<Int> {
        guard plan.futureCount > 0 else { return plan.installmentCount...plan.installmentCount }
        return max(2, plan.lockedCount + 1)...60
    }
    private var feeMinor: Int64 { CNYAmountParser.minorUnits(feeText) ?? -1 }
    private var eligibleCycleOptions: [InstallmentCycleOption] { installments.cycleOptions.filter(\.eligible) }
    private var legacyStartStatementDate: String? { Self.legacyStartStatementDate(planStartDate: plan.startStatementDate, eligibleStatementDates: eligibleCycleOptions.map(\.statementDate)) }
    static func legacyStartStatementDate(planStartDate: String, eligibleStatementDates: [String]) -> String? { eligibleStatementDates.contains(planStartDate) ? nil : planStartDate }
    private func loadDependencies() async {
        optionsLoading = true; optionsError = nil
        do {
            async let categoriesValue = categories.transactionOptions(); async let accountsValue = accounts.transactionOptions()
            let (loadedCategories, loadedAccounts) = try await (categoriesValue, accountsValue)
            guard await installments.loadCycleOptions(transactionID: plan.purchaseTransactionID) else { optionsError = installments.message ?? "账期选项读取失败。"; optionsLoading = false; return }
            categoryOptions = loadedCategories; accountOptions = loadedAccounts
        } catch { categoryOptions = []; accountOptions = []; optionsError = "账户或分类读取失败：\(installmentDisplayError(error))" }
        optionsLoading = false
    }
    private func refreshConflict() { Task { await installments.loadPlan(plan.id); dismiss() } }
    private var amountBinding: Binding<String> { Binding(get: { Self.major(replacement.amountMinor) }, set: { if let value = CNYAmountParser.minorUnits($0) { replacement.amountMinor = value } }) }
    private static let missingReference = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    private func request() -> InstallmentReplacementRequest? {
        guard replacement.accountID != Self.missingReference, replacement.categoryID != Self.missingReference else {
            validation = "该消费缺少信用账户或分类，无法编辑分期。"; return nil
        }
        guard feeMinor >= 0, feeMinor == 0 || feeCategoryID != nil else { validation = "手续费或分类无效。"; return nil }
        return .init(expectedVersion: plan.version, purchase: replacement, installmentCount: installmentCount, totalFeeMinor: feeMinor, feeCategoryID: feeMinor == 0 ? nil : feeCategoryID, feeOccurredAt: feeMinor == 0 ? nil : feeOccurredAt, startStatementDate: startStatementDate)
    }
    private func preview() { guard let request = request() else { return }; Task { _ = await installments.preview(request) } }
    private func save() { guard let request = request() else { return }; Task { if await installments.update(request) != nil { dismiss() } } }
    private static func major(_ minor: Int64) -> String { NSDecimalNumber(decimal: Decimal(minor) / 100).stringValue }
}

public struct InstallmentSettlementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var installments: InstallmentModel
    let plan: InstallmentPlanDTO; let accounts: AccountsModel
    @State private var paymentAccountID: UUID?
    @State private var targetStatementDate = ""
    @State private var occurredAt = Date()
    @State private var accountOptions: [AccountDTO] = []
    @State private var idempotencyKey = UUID()
    @State private var optionsLoading = true
    @State private var optionsError: String?
    public init(installments: InstallmentModel, plan: InstallmentPlanDTO, accounts: AccountsModel) { self.installments = installments; self.plan = plan; self.accounts = accounts }
    public var body: some View {
        NavigationStack {
            InstallmentEditorCanvas {
                InstallmentEditorCard("提前结清") {
                    Picker("付款账户", selection: $paymentAccountID) { Text("请选择").tag(Optional<UUID>.none); ForEach(accountOptions.filter { $0.kind != .credit && $0.archivedAt == nil }) { Text($0.name).tag(Optional($0.id)) } }
                    Picker("目标账单日", selection: $targetStatementDate) { Text("请选择").tag(""); ForEach(installments.cycleOptions.filter(\.eligible)) { Text("\($0.statementDate) · 到期 \($0.dueDate)").tag($0.statementDate) } }
                    DatePicker("还款时间", selection: $occurredAt)
                }
                if let value = installments.settlementPreview {
                    InstallmentEditorCard("服务器确认") {
                        LabeledContent("实际还款", value: Money(minorUnits: value.amountMinor).formatted())
                        LabeledContent("还款后信用负债", value: Money(minorUnits: value.debtAfterMinor).formatted())
                        ForEach(value.warnings) { Label($0.message, systemImage: "exclamationmark.triangle") }
                    }
                }
                if optionsLoading { InstallmentEditorCard { ProgressView("正在读取付款账户与账期…") } }
                if let optionsError {
                    InstallmentEditorCard {
                        InstallmentEditorNotice(message: optionsError, symbol: "wifi.exclamationmark", color: FiscalColor.expense)
                        Button("重试") { Task { await loadDependencies() } }
                    }
                }
                if installments.conflictDetected {
                    InstallmentEditorCard {
                        InstallmentEditorNotice(message: "计划版本已变化。", symbol: "arrow.triangle.2.circlepath", color: FiscalColor.expense)
                        Button("刷新计划") { refreshConflict() }
                    }
                }
                if let message = installments.message {
                    InstallmentEditorCard { InstallmentEditorNotice(message: message, symbol: "exclamationmark.triangle", color: FiscalColor.expense) }
                }
            } actions: {
                if installments.settlementPreview == nil {
                    Button("预览结清影响") { preview() }
                        .buttonStyle(.borderedProminent).disabled(optionsLoading || optionsError != nil)
                } else {
                    Button("确认还款") { settle() }
                        .buttonStyle(.borderedProminent)
                        .disabled(installments.isMutating || optionsLoading || optionsError != nil)
                }
            }
            .navigationTitle("提前结清")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .task { await loadDependencies() }
            .onChange(of: paymentAccountID) { _, _ in installments.invalidateSettlementPreview() }
            .onChange(of: targetStatementDate) { _, _ in installments.invalidateSettlementPreview() }
            .onChange(of: occurredAt) { _, _ in installments.invalidateSettlementPreview() }
        }.installmentEditorFrame(width: 500, height: 540)
    }
    private func request() -> InstallmentSettlementRequest? { guard let paymentAccountID, !targetStatementDate.isEmpty else { return nil }; return .init(expectedVersion: plan.version, paymentAccountID: paymentAccountID, targetStatementDate: targetStatementDate, occurredAt: occurredAt) }
    private func preview() { guard let request = request() else { return }; Task { _ = await installments.previewSettlement(request) } }
    private func settle() { guard let request = request() else { return }; Task { if await installments.settle(request, idempotencyKey: idempotencyKey) { dismiss() } } }
    private func loadDependencies() async {
        optionsLoading = true; optionsError = nil
        do {
            accountOptions = try await accounts.transactionOptions()
            guard await installments.loadCycleOptions(transactionID: plan.purchaseTransactionID) else { optionsError = installments.message ?? "账期选项读取失败。"; optionsLoading = false; return }
            targetStatementDate = installments.cycleOptions.first(where: \.eligible)?.statementDate ?? ""
        } catch { accountOptions = []; optionsError = "付款账户读取失败：\(installmentDisplayError(error))" }
        optionsLoading = false
    }
    private func refreshConflict() { Task { await installments.loadPlan(plan.id); dismiss() } }
}

public struct InstallmentCancellationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var installments: InstallmentModel
    let plan: InstallmentPlanDTO
    @State private var occurredAt = Date(); @State private var idempotencyKey = UUID()
    public init(installments: InstallmentModel, plan: InstallmentPlanDTO) { self.installments = installments; self.plan = plan }
    public var body: some View {
        NavigationStack {
            InstallmentEditorCanvas {
                InstallmentEditorCard("取消安排") {
                    DatePicker("退款确认时间", selection: $occurredAt)
                    InstallmentEditorNotice(
                        message: "仅取消未锁定的完整未来期次，并生成真实退款。此操作不可恢复。",
                        symbol: "exclamationmark.triangle",
                        color: FiscalColor.secondary)
                }
                if let value = installments.cancellationPreview {
                    InstallmentEditorCard("服务器确认") {
                        LabeledContent("本金退款", value: Money(minorUnits: value.principalRefundMinor).formatted())
                        LabeledContent("手续费退款", value: Money(minorUnits: value.feeRefundMinor).formatted())
                        LabeledContent("取消期数", value: "\(value.cancelledPeriods.count) 期")
                        LabeledContent("退款后信用负债", value: Money(minorUnits: value.debtAfterMinor).formatted())
                    }
                }
                if installments.conflictDetected {
                    InstallmentEditorCard {
                        InstallmentEditorNotice(message: "计划版本已变化。", symbol: "arrow.triangle.2.circlepath", color: FiscalColor.expense)
                        Button("刷新计划") { refreshConflict() }
                    }
                }
                if let message = installments.message {
                    InstallmentEditorCard { InstallmentEditorNotice(message: message, symbol: "exclamationmark.triangle", color: FiscalColor.expense) }
                }
            } actions: {
                if installments.cancellationPreview == nil {
                    Button("预览退款") { preview() }.buttonStyle(.borderedProminent)
                } else {
                    Button("确认取消未来期次", role: .destructive) { cancel() }
                        .buttonStyle(.borderedProminent).tint(FiscalColor.expense)
                        .disabled(installments.isMutating)
                }
            }
            .navigationTitle("取消未来期次")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .onChange(of: occurredAt) { _, _ in installments.invalidateCancellationPreview() }
        }.installmentEditorFrame(width: 480, height: 460)
    }
    private var request: InstallmentOperationRequest { .init(expectedVersion: plan.version, occurredAt: occurredAt) }
    private func preview() { Task { _ = await installments.previewCancellation(request) } }
    private func cancel() { Task { if await installments.cancelFuture(request, idempotencyKey: idempotencyKey) { dismiss() } } }
    private func refreshConflict() { Task { await installments.loadPlan(plan.id); dismiss() } }
}

public struct InstallmentReverseSettlementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var installments: InstallmentModel
    let plan: InstallmentPlanDTO
    @State private var occurredAt = Date(); @State private var idempotencyKey = UUID()
    public init(installments: InstallmentModel, plan: InstallmentPlanDTO) { self.installments = installments; self.plan = plan }
    public var body: some View {
        NavigationStack {
            InstallmentEditorCanvas {
                InstallmentEditorCard("撤销结清") {
                    DatePicker("撤销时间", selection: $occurredAt)
                    InstallmentEditorNotice(
                        message: "只在后续没有依赖这笔结清还款时可撤销。服务器会恢复原期次与账期。",
                        symbol: "arrow.uturn.backward.circle",
                        color: FiscalColor.secondary)
                }
                if let value = installments.reversePreview {
                    InstallmentEditorCard("服务器确认") {
                        LabeledContent("可撤销", value: value.eligible ? "是" : "否")
                        LabeledContent("撤销后信用负债", value: Money(minorUnits: value.debtAfterMinor).formatted())
                        LabeledContent("恢复期次", value: "\(value.restoredPeriods.count) 期")
                    }
                }
                if installments.conflictDetected {
                    InstallmentEditorCard {
                        InstallmentEditorNotice(message: "计划版本已变化。", symbol: "arrow.triangle.2.circlepath", color: FiscalColor.expense)
                        Button("刷新计划") { refreshConflict() }
                    }
                }
                if let message = installments.message {
                    InstallmentEditorCard { InstallmentEditorNotice(message: message, symbol: "exclamationmark.triangle", color: FiscalColor.expense) }
                }
            } actions: {
                if installments.reversePreview == nil {
                    Button("预览撤销影响") { preview() }.buttonStyle(.borderedProminent)
                } else {
                    Button("确认撤销提前结清", role: .destructive) { reverse() }
                        .buttonStyle(.borderedProminent).tint(FiscalColor.expense)
                        .disabled(installments.reversePreview?.eligible != true || installments.isMutating)
                }
            }
            .navigationTitle("撤销提前结清")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .onChange(of: occurredAt) { _, _ in installments.invalidateReversePreview() }
        }.installmentEditorFrame(width: 480, height: 440)
    }
    private var request: InstallmentOperationRequest { .init(expectedVersion: plan.version, occurredAt: occurredAt) }
    private func preview() { Task { _ = await installments.previewReverse(request) } }
    private func reverse() { Task { if await installments.reverseSettlement(request, idempotencyKey: idempotencyKey) { dismiss() } } }
    private func refreshConflict() { Task { await installments.loadPlan(plan.id); dismiss() } }
}

#if os(iOS)
public struct IOSInstallmentPlanDetail: View {
    @Bindable var installments: InstallmentModel
    let planID: UUID; let accounts: AccountsModel; let categories: CategoriesModel; let readOnly: Bool
    @State private var showEdit = false; @State private var showSettlement = false; @State private var showCancellation = false; @State private var showReverse = false
    public init(installments: InstallmentModel, planID: UUID, accounts: AccountsModel, categories: CategoriesModel, readOnly: Bool = false) { self.installments = installments; self.planID = planID; self.accounts = accounts; self.categories = categories; self.readOnly = readOnly }
    public var body: some View {
        Group { if let plan = installments.selectedPlan, plan.id == planID { VStack(spacing: 0) { if installments.conflictDetected { HStack { Label("计划已变化", systemImage: "arrow.triangle.2.circlepath"); Spacer(); Button("刷新") { Task { await installments.loadPlan(planID); installments.clearConflict() } } }.font(.caption).foregroundStyle(FiscalColor.expense).padding(12).background(FiscalColor.expense.opacity(0.08)) }; ScrollView { VStack(spacing: 14) { summary(plan); periods(plan) }.padding(16) }.background(FiscalColor.iOSBackground) } } else { stateView } }
            .background(FiscalColor.iOSBackground.ignoresSafeArea())
            .navigationTitle("分期详情").task { await installments.loadPlan(planID) }
            .toolbar { if !readOnly, let plan = installments.selectedPlan, plan.id == planID { ToolbarItem(placement: .primaryAction) { Menu { if plan.status == .active || plan.status == .partiallyCancelled { Button("编辑计划", systemImage: "pencil") { showEdit = true }; if plan.futureCount > 0 { Button("提前结清", systemImage: "checkmark.circle") { showSettlement = true }; Button("取消未来期次", systemImage: "xmark.circle", role: .destructive) { showCancellation = true } } }; if plan.status == .settledEarly { Button("撤销提前结清", systemImage: "arrow.uturn.backward") { showReverse = true } } } label: { Image(systemName: "ellipsis.circle") } } } }
            .sheet(isPresented: $showEdit) { if let plan = installments.selectedPlan, let purchase = installments.selectedPurchase { InstallmentEditorSheet(installments: installments, plan: plan, purchase: purchase, accounts: accounts, categories: categories) } }
            .sheet(isPresented: $showSettlement) { if let plan = installments.selectedPlan { InstallmentSettlementSheet(installments: installments, plan: plan, accounts: accounts) } }
            .sheet(isPresented: $showCancellation) { if let plan = installments.selectedPlan { InstallmentCancellationSheet(installments: installments, plan: plan) } }
            .sheet(isPresented: $showReverse) { if let plan = installments.selectedPlan { InstallmentReverseSettlementSheet(installments: installments, plan: plan) } }
    }
    private func summary(_ plan: InstallmentPlanDTO) -> some View { FiscalCard(radius: 20) { VStack(alignment: .leading, spacing: 11) { HStack { Text(plan.title).font(.headline); Spacer(); InstallmentStatusPill(title: plan.status.title, color: plan.status.color) }; Text("\(plan.cycleSettledCount + plan.cancelledCount) / \(plan.installmentCount) 期").font(.title2.bold()); ProgressView(value: Double(plan.cycleSettledCount + plan.cancelledCount), total: Double(max(1, plan.installmentCount))).tint(FiscalColor.debt); LabeledContent("融资总额", value: Money(minorUnits: plan.totalFinancedMinor).formatted()); LabeledContent("未来计划毛额", value: Money(minorUnits: plan.futureScheduledGrossMinor).formatted()); Text("未来计划毛额未扣除通用部分还款；精确已还与待还以所属账期为准。") .font(.caption).foregroundStyle(FiscalColor.tertiary) } } }
    private func periods(_ plan: InstallmentPlanDTO) -> some View { VStack(alignment: .leading, spacing: 10) { Text("全部期次").font(.headline); FiscalCard(radius: 18) { VStack(spacing: 0) { ForEach(plan.periods) { period in HStack { VStack(alignment: .leading, spacing: 4) { Text("第 \(period.sequence) 期 · \(period.effectiveStatementDate)").font(.subheadline.weight(.medium)); Text("本金 \(Money(minorUnits: period.principalMinor).formatted()) · 手续费 \(Money(minorUnits: period.feeMinor).formatted()) · 到期 \(period.dueDate)").font(.caption).foregroundStyle(FiscalColor.tertiary) }; Spacer(); InstallmentStatusPill(title: period.status.title, color: period.status.color); if period.locked { Image(systemName: "lock.fill").font(.caption).foregroundStyle(FiscalColor.tertiary) } }.padding(.vertical, 9); Divider() } } } } }
    @ViewBuilder private var stateView: some View { switch installments.phase { case .unauthorized: retryState("设备密钥无效", "key"); case .offline: retryState("无法连接个人 VPS", "wifi.slash"); case .failed: retryState("分期读取失败", "exclamationmark.triangle"); default: ProgressView("正在读取分期…") } }
    private func retryState(_ title: String, _ symbol: String) -> some View { ContentUnavailableView { Label(title, systemImage: symbol) } description: { Text(installments.message ?? "请重试") } actions: { Button("重试") { Task { await installments.loadPlan(planID) } } } }
}
#endif

private extension View {
    @ViewBuilder
    func installmentEditorFrame(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
        frame(width: width, height: height)
        #else
        self
        #endif
    }
}
