import SwiftUI

public struct V15InstallmentMacView: View {
    private enum InspectorMode: String, CaseIterable { case facts = "事实", edit = "修改", command = "操作" }
    @State private var model: V15InstallmentModel
    @State private var inspectorMode: InspectorMode = .facts
    @State private var showsCreation = false
    @State private var appliedGalleryScenario = false
    private let initialGalleryScenario: String?

    @MainActor public init(services: V15Services, offlineSnapshotAt: Date? = nil, initialGalleryScenario: String? = nil, now: @escaping () -> Date = { .now }) {
        _model = State(initialValue: V15InstallmentModel(services: services, offlineSnapshotAt: offlineSnapshotAt, now: now))
        self.initialGalleryScenario = initialGalleryScenario
    }

    public var body: some View {
        Group {
            #if os(macOS)
            HSplitView {
                spine.frame(minWidth: 240, idealWidth: 300, maxWidth: 380)
                schedule.frame(minWidth: 380, idealWidth: 560, maxWidth: .infinity)
                inspector.frame(minWidth: 330, idealWidth: 410, maxWidth: 520)
            }
            #else
            HStack(spacing: 0) {
                spine.frame(width: 300)
                schedule.frame(maxWidth: .infinity)
                inspector.frame(width: 410)
            }
            #endif
        }
        .background(V15Palette.paper.color)
        .toolbar {
            Button { Task { await model.refresh() } } label: { Label("刷新", systemImage: V15Symbol.retry) }.keyboardShortcut("r", modifiers: .command)
            Button { showsCreation = true } label: { Label("新分期", systemImage: "plus") }.accessibilityIdentifier("v15.f3b2.mac.create")
        }
        .task {
            if case .idle = model.phase { await model.load() }
            guard !appliedGalleryScenario else { return }
            appliedGalleryScenario = true
            switch initialGalleryScenario {
            case "installments-page-error": await model.loadNextPage()
            case "installments-update-unknown-confirmed":
                guard let plan = model.plans.first else { return }
                await model.selectPlan(plan); inspectorMode = .edit; await model.requestPlanPreview()
            case "installments-command-unknown":
                guard let plan = model.plans.first else { return }
                await model.selectPlan(plan); inspectorMode = .command; await model.requestCommandPreview()
            default: break
            }
        }
        .sheet(isPresented: $showsCreation, onDismiss: model.dismissEditor) { V15InstallmentMacCreationView(model: model).frame(minWidth: 620, minHeight: 640) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f3b2.installments.macos")
    }

    private var spine: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("分期计划").font(V15Typography.cardTitle); Spacer(); Text("\(model.plans.count)").font(V15Typography.label) }.padding(V15Spacing.md)
            Divider()
            if let snapshot = model.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: snapshot).padding(V15Spacing.sm).accessibilityIdentifier("v15.f3b2.mac.offline") }
            Picker("状态", selection: Binding(get: { model.filterStatus ?? "all" }, set: { value in Task { await model.setFilters(status: value == "all" ? nil : value, accountID: model.filterAccountID) } })) {
                Text("全部").tag("all"); Text("进行中").tag("active"); Text("已完成").tag("completed"); Text("提前结清").tag("settled_early"); Text("部分取消").tag("partially_cancelled"); Text("已取消").tag("cancelled")
            }.pickerStyle(.menu).padding(.horizontal, V15Spacing.md)
            switch model.phase {
            case .idle, .loading: V15LoadingSkeleton().padding()
            case .empty: V15EmptyState(title: "暂无计划", explanation: "创建后将按服务端状态显示。")
            case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.load() } }.padding()
            case .loaded:
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: V15Spacing.xxs) {
                        ForEach(model.plans) { plan in
                            Button {
                                Task { await model.selectPlan(plan) }
                            } label: {
                                VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                                    Text(plan.title).font(V15Typography.body).fixedSize(horizontal: false, vertical: true)
                                    HStack {
                                        Text(plan.status.displayName)
                                        Spacer()
                                        Text(V15MoneyPresentation(minorUnits: plan.futureScheduledGrossMinor, direction: .outflow, includeCurrency: false).text).monospacedDigit()
                                    }
                                    .font(V15Typography.secondary)
                                    .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(V15Spacing.sm)
                                .background(model.selectedPlan?.id == plan.id ? V15Palette.selected.color : Color.clear, in: RoundedRectangle(cornerRadius: V15Radius.control))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("v15.f3b2.plan.\(plan.id.uuidString)")
                        }
                        if model.nextCursor != nil {
                            Button("加载更多") { Task { await model.loadNextPage() } }
                                .buttonStyle(.plain)
                                .padding(V15Spacing.sm)
                                .accessibilityIdentifier("v15.f3b2.mac.page.next")
                        }
                    }
                    .padding(V15Spacing.sm)
                }
                if case .failed(let failure) = model.pagePhase { V15ServiceErrorState(message: failure.message) { Task { await model.loadNextPage() } }.padding(V15Spacing.sm).accessibilityIdentifier("v15.f3b2.mac.page.error") }
            }
        }
        .accessibilityIdentifier("v15.f3b2.mac.spine")
    }

    private var schedule: some View {
        Group {
            if let plan = model.selectedPlan {
                ScrollView {
                    VStack(alignment: .leading, spacing: V15Spacing.lg) {
                        HStack(alignment: .firstTextBaseline) { VStack(alignment: .leading) { Text(plan.title).font(V15Typography.surfaceTitle); Text("\(plan.status.displayName) · v\(plan.version)").font(V15Typography.secondary) }; Spacer(); V15MoneyText(minorUnits: plan.totalFinancedMinor, direction: .outflow, font: V15Typography.moneyLarge) }
                        if plan.isDisplayOnly { V15ArchiveReadOnlyState { Text("未知 future state 仅展示；不会推断操作或生命周期跃迁。") }.accessibilityIdentifier("v15.f3b2.mac.unknown") }
                        HStack(spacing: V15Spacing.sm) { metric("锁定", plan.lockedCount); metric("未来", plan.futureCount); metric("取消", plan.cancelledCount); metric("已结账期", plan.cycleSettledCount) }
                        V15Section("期次脊柱") {
                            ForEach(plan.periods) { period in
                                V15LedgerRow(title: "第 \(period.sequence) 期 · \(period.status.rawValue)", detail: "账单 \(period.effectiveStatementDate) · 到期 \(period.dueDate) · \(period.locked ? "已锁定" : "未来")", amountMinor: period.amountDueMinor, direction: .outflow, marker: period.locked ? .ordinary : .provisional)
                                    .accessibilityIdentifier("v15.f3b2.period.\(period.id.uuidString)")
                            }
                        }
                        if let liabilities = model.liabilities {
                            V15Section("未来负债", detail: "服务端口径") {
                                HStack { V15MoneyText(minorUnits: liabilities.totalFutureScheduledGrossMinor, direction: .outflow); Spacer(); Text("\(liabilities.groups.count) 个月").font(V15Typography.secondary) }
                                ForEach(liabilities.groups) { group in V15LedgerRow(title: group.month, detail: "\(group.periodCount) 期 · 本金/手续费均由服务端汇总", amountMinor: group.totalScheduledGrossMinor, direction: .outflow) }
                            }.accessibilityIdentifier("v15.f3b2.mac.liabilities")
                        }
                    }.padding(V15Spacing.xl)
                }
            } else { V15EmptyState(title: "选择一项计划", explanation: "中栏显示服务端期次，右栏显示事实与操作。") }
        }
        .accessibilityIdentifier("v15.f3b2.mac.schedule")
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text(title.uppercased()).font(V15Typography.label); Text("\(value) 期").font(V15Typography.cardTitle) }.padding(V15Spacing.md).frame(maxWidth: .infinity, alignment: .leading).background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.card))
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("检查器", selection: $inspectorMode) { ForEach(InspectorMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).padding(V15Spacing.md)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.md) {
                    if let plan = model.selectedPlan {
                        switch inspectorMode {
                        case .facts: factInspector(plan)
                        case .edit: editInspector
                        case .command: commandInspector
                        }
                    } else { V15EmptyState(title: "没有选择", explanation: "从左侧计划脊柱选择一项。") }
                }.padding(V15Spacing.md)
            }
        }
        .accessibilityIdentifier("v15.f3b2.mac.inspector")
    }

    private func factInspector(_ plan: V15InstallmentPlan) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            Text("计划事实").font(V15Typography.cardTitle)
            LabeledContent("状态", value: plan.status.displayName); LabeledContent("版本", value: "v\(plan.version)"); LabeledContent("消费账目", value: plan.purchaseTransactionID.uuidString); LabeledContent("起始账单", value: plan.startStatementDate)
            if let period = plan.nextPeriod { Divider(); Text("下一期").font(V15Typography.label); Text("\(period.effectiveStatementDate) · \(V15MoneyPresentation(minorUnits: period.amountDueMinor, direction: .outflow).text)") }
            V15ActionButton("修改计划", kind: .secondary, disabledReason: model.planMutationDisabledReason) { inspectorMode = .edit }.accessibilityIdentifier("v15.f3b2.mac.edit.open")
            V15ActionButton("计划操作", disabledReason: model.planMutationDisabledReason) { inspectorMode = .command }.accessibilityIdentifier("v15.f3b2.mac.command.open")
        }
    }

    private var editInspector: some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            Text("修改计划").font(V15Typography.cardTitle)
            V15Field("标题", text: $model.editTitle, issues: model.fieldIssues.filter { $0.fieldPath == "purchase.title" })
            V15Field("消费金额（元）", text: $model.editAmountText, issues: model.fieldIssues.filter { $0.fieldPath == "purchase.amount_minor" })
            V15Field("期数", text: $model.editCountText, issues: model.fieldIssues.filter { $0.fieldPath == "installment_count" })
            V15Field("手续费（元）", text: $model.editFeeText, issues: model.fieldIssues.filter { $0.fieldPath == "total_fee_minor" })
            if positiveFee(model.editFeeText) { feeDetails(categoryID: $model.editFeeCategoryID, occurredDateText: $model.editFeeOccurredDateText, prefix: "v15.f3b2.mac.edit") }
            V15Field("起始账单日", text: $model.editStartStatementDate, issues: model.fieldIssues.filter { $0.fieldPath == "start_statement_date" })
            V15ActionButton("预览", disabledReason: model.planPreviewDisabledReason) { Task { await model.requestPlanPreview() } }.accessibilityIdentifier("v15.f3b2.mac.edit.preview")
            if let preview = model.planPreview { V15PreviewState(version: "v\(preview.currentPlan.version)") { V15InstallmentPlanPreviewDetails(preview: preview, prefix: "v15.f3b2.mac.edit.preview-detail") }.accessibilityIdentifier("v15.f3b2.mac.edit.preview-result") }
            V15ActionButton("确认修改（无重试凭证）", disabledReason: model.planCommitDisabledReason) { Task { await model.commitPlanUpdate() } }.accessibilityIdentifier("v15.f3b2.mac.edit.commit")
            planUpdateState
        }
    }

    @ViewBuilder private var planUpdateState: some View {
        switch model.planPhase {
        case .unknown:
            warning("PUT 结果未知；不会重发，只能 fresh GET 计划与消费逐字段核对。", id: "v15.f3b2.mac.edit.unknown")
            V15ActionButton("刷新事实核对", kind: .secondary) { Task { await model.readBackUnknownPlanUpdate() } }.accessibilityIdentifier("v15.f3b2.mac.edit.readback")
            readback(model.updateReadbackPhase, prefix: "v15.f3b2.mac.edit")
        case .conflict(let conflict): V15ConflictState(conflict: conflict) { Task { await model.refresh() } }
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.requestPlanPreview() } }
        case .succeeded: V15SuccessReceiptState(title: "计划已更新", detail: "服务端响应或 fresh GET 已确认。")
        case .previewing, .committing: ProgressView("正在处理")
        default: EmptyView()
        }
    }

    private var commandInspector: some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            Text("计划操作").font(V15Typography.cardTitle)
            Picker("操作", selection: $model.commandKind) { ForEach(V15InstallmentModel.CommandKind.allCases) { Text($0.title).tag($0) } }.pickerStyle(.menu).accessibilityIdentifier("v15.f3b2.mac.command.kind")
            if model.commandKind == .settleEarly {
                Picker("付款账户", selection: $model.paymentAccountID) { Text("请选择").tag(UUID?.none); ForEach(model.paymentAccounts) { Text($0.name).tag(Optional($0.id)) } }.pickerStyle(.menu)
                V15Field("目标账单日", text: $model.targetStatementDate, issues: model.fieldIssues.filter { $0.fieldPath == "target_statement_date" })
            }
            V15ActionButton("预览服务端影响", disabledReason: model.commandPreviewDisabledReason) { Task { await model.requestCommandPreview() } }.accessibilityIdentifier("v15.f3b2.mac.command.preview")
            if let preview = model.commandPreview { V15PreviewState { V15InstallmentCommandPreviewDetails(preview: preview, prefix: "v15.f3b2.mac.command.preview-detail") }.accessibilityIdentifier("v15.f3b2.mac.command.preview-result") }
            V15ActionButton("确认\(model.commandKind.title)", kind: model.commandKind == .cancelFuture ? .destructive : .primary, disabledReason: model.commandCommitDisabledReason) { Task { await model.commitCommand() } }.accessibilityIdentifier("v15.f3b2.mac.command.commit")
            commandState
        }
    }

    @ViewBuilder private var commandState: some View {
        switch model.commandPhase {
        case .unknown:
            warning("结果未知；只有同 body + 同 key 重放取得 operation receipt 才能确认。fresh GET 只能显示计划事实变化，不能归因于本请求。", id: "v15.f3b2.mac.command.unknown")
            V15ActionButton("同一请求凭证重试", disabledReason: model.isOffline ? .init(code: "offline_read_only", message: "离线时不能重试写入。", fieldPath: nil) : nil) { Task { await model.retryUnknownCommand() } }.accessibilityIdentifier("v15.f3b2.mac.command.retry")
            V15ActionButton("刷新计划事实（不确认请求）", kind: .secondary) { Task { await model.readBackUnknownCommand() } }
            commandReadback(model.commandReadbackPhase)
        case .conflict(let conflict): V15ConflictState(conflict: conflict) { Task { await model.refresh() } }
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.requestCommandPreview() } }
        case .succeeded:
            if let receipt = model.commandReceipt {
                V15SuccessReceiptState(title: "操作完成", detail: "operation_id \(receipt.operationID.uuidString) · replayed \(receipt.replayed ? "是" : "否") · 系统流水 \(receipt.systemTransactionCount) 笔").accessibilityIdentifier("v15.f3b2.mac.command.receipt")
                ForEach(receipt.systemTransactions, id: \.id) { transaction in
                    V15LedgerRow(title: transaction.title, detail: "\(transaction.kind) · \(transaction.id.uuidString)", amountMinor: transaction.amountMinor, direction: .neutral)
                        .accessibilityIdentifier("v15.f3b2.mac.command.transaction.\(transaction.id.uuidString)")
                }
            }
            else { warning("没有 operation receipt，不能把计划状态变化当作本请求成功。", id: "v15.f3b2.mac.command.no-receipt") }
        case .previewing, .committing: ProgressView("正在处理")
        default: EmptyView()
        }
    }

    private func warning(_ text: String, id: String) -> some View { Text(text).font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true).padding(V15Spacing.md).background(V15Palette.provisional.color, in: RoundedRectangle(cornerRadius: V15Radius.control)).accessibilityIdentifier(id) }
    @ViewBuilder private func readback(_ phase: V15InstallmentModel.ReadbackPhase, prefix: String) -> some View { switch phase { case .loading: ProgressView(); case .confirmed: Text("最新事实已确认").accessibilityIdentifier("\(prefix).confirmed"); case .notConfirmed: Text("最新事实不能确认该请求已生效").accessibilityIdentifier("\(prefix).not-confirmed"); case .failed(let failure): Text("核对失败：\(failure.message)").accessibilityIdentifier("\(prefix).error"); case .idle: EmptyView() } }
    @ViewBuilder private func commandReadback(_ phase: V15InstallmentModel.ReadbackPhase) -> some View { switch phase { case .loading: ProgressView("正在读取最新计划事实"); case .notConfirmed: Text("计划事实可能已变化或操作可能已发生，但 GET 无法证明付款账户、目标账单日、发生时间和 operation receipt 属于本请求；同一请求凭证仍保留。").font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("v15.f3b2.mac.command.readback.not-confirmed"); case .failed(let failure): Text("事实读取失败：\(failure.message)；同一请求凭证仍保留。").font(V15Typography.secondary).accessibilityIdentifier("v15.f3b2.mac.command.readback.error"); case .confirmed: Text("仅同一 key 重放 receipt 可确认。"); case .idle: EmptyView() } }
    @ViewBuilder private func feeDetails(categoryID: Binding<UUID?>, occurredDateText: Binding<String>, prefix: String) -> some View {
        switch model.feeCategoryPhase {
        case .loading: ProgressView("正在读取手续费支出分类").accessibilityIdentifier("\(prefix).fee-category.loading")
        case .loaded:
            Picker("手续费支出分类", selection: categoryID) { Text("请选择").tag(UUID?.none); ForEach(model.expenseCategories) { Text($0.name).tag(Optional($0.id)) } }.pickerStyle(.menu).disabled(model.isOffline).accessibilityIdentifier("\(prefix).fee-category")
        case .empty: warning("暂无支出分类，请先创建分类；正手续费不能提交。", id: "\(prefix).fee-category.empty"); V15ActionButton("重新读取分类", kind: .secondary) { Task { await model.loadFeeCategories() } }.accessibilityIdentifier("\(prefix).fee-category.retry")
        case .failed(let failure): V15ServiceErrorState(message: "支出分类读取失败：\(failure.message)") { Task { await model.loadFeeCategories() } }.accessibilityIdentifier("\(prefix).fee-category.error"); V15ActionButton("重试读取分类", kind: .secondary) { Task { await model.loadFeeCategories() } }.accessibilityIdentifier("\(prefix).fee-category.retry")
        case .idle: V15ActionButton("读取手续费支出分类", kind: .secondary) { Task { await model.loadFeeCategories() } }.accessibilityIdentifier("\(prefix).fee-category.retry")
        }
        V15Field("手续费发生日期（上海）", text: occurredDateText, issues: model.fieldIssues.filter { $0.fieldPath == "fee_occurred_at" }).disabled(model.isOffline).accessibilityIdentifier("\(prefix).fee-date")
    }
    private func positiveFee(_ text: String) -> Bool { (CNYAmountParser.minorUnits(text) ?? 0) > 0 }
}

private struct V15InstallmentMacCreationView: View {
    private enum Mode: String, CaseIterable { case purchase = "新分期消费", existing = "已有消费转分期" }
    @Bindable var model: V15InstallmentModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .purchase
    var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            HStack { Text(mode.rawValue).font(V15Typography.surfaceTitle); Spacer(); Button("关闭") { dismiss() }.accessibilityIdentifier("v15.f3b2.mac.create.dismiss") }
            Picker("创建方式", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).accessibilityIdentifier("v15.f3b2.mac.create.mode")
            ScrollView { VStack(alignment: .leading, spacing: V15Spacing.md) { if mode == .purchase { purchaseForm } else { existingForm } }.frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(V15Spacing.xl).accessibilityIdentifier("v15.f3b2.mac.create.sheet")
    }

    private var purchaseForm: some View {
        Group {
            V15Field("标题", text: $model.newPurchaseTitle); V15Field("金额（元）", text: $model.newPurchaseAmountText)
            Picker("信用账户", selection: $model.newPurchaseAccountID) { Text("请选择").tag(UUID?.none); ForEach(model.creditAccounts) { Text($0.name).tag(Optional($0.id)) } }.pickerStyle(.menu)
            purchaseCategorySurface
            HStack { V15Field("期数", text: $model.newPurchaseCountText); V15Field("手续费（元）", text: $model.newPurchaseFeeText) }
            if positiveFee(model.newPurchaseFeeText) { feeDetails(categoryID: $model.newPurchaseFeeCategoryID, occurredDateText: $model.newPurchaseFeeOccurredDateText, prefix: "v15.f3b2.mac.purchase") }
            V15Field("起始账单日", text: $model.newPurchaseStartStatementDate); V15FieldIssues(issues: model.fieldIssues)
            V15ActionButton("预览服务端拆分", disabledReason: model.purchasePreviewDisabledReason) { Task { await model.requestPurchasePreview() } }.accessibilityIdentifier("v15.f3b2.mac.purchase.preview")
            if let preview = model.purchasePreview { V15PreviewState { V15InstallmentPurchasePreviewDetails(preview: preview, prefix: "v15.f3b2.mac.purchase.preview-detail") }.accessibilityIdentifier("v15.f3b2.mac.purchase.preview-result") }
            V15ActionButton("确认创建", disabledReason: model.purchaseCommitDisabledReason) { Task { await model.commitPurchase() } }.accessibilityIdentifier("v15.f3b2.mac.purchase.commit")
            if model.purchasePhase == .unknown { Text("结果未知；仅可同 body + 同 key 重试。").foregroundStyle(V15Palette.gold.color).accessibilityIdentifier("v15.f3b2.mac.purchase.unknown"); V15ActionButton("同一请求凭证重试") { Task { await model.retryUnknownPurchase() } }.accessibilityIdentifier("v15.f3b2.mac.purchase.retry") }
        }
    }

    @ViewBuilder private var purchaseCategorySurface: some View {
        switch model.feeCategoryPhase {
        case .loading:
            ProgressView("正在读取支出分类").accessibilityIdentifier("v15.f3b2.mac.purchase.category.loading")
        case .loaded:
            Picker("支出分类", selection: $model.newPurchaseCategoryID) { Text("请选择").tag(UUID?.none); ForEach(model.expenseCategories) { Text($0.name).tag(Optional($0.id)) } }
                .pickerStyle(.menu).disabled(model.isOffline).accessibilityIdentifier("v15.f3b2.mac.purchase.category")
        case .empty:
            Text("暂无支出分类，请先创建分类。").font(V15Typography.secondary).accessibilityIdentifier("v15.f3b2.mac.purchase.category.empty")
            V15ActionButton("重新读取支出分类", kind: .secondary) { Task { await model.loadFeeCategories() } }.accessibilityIdentifier("v15.f3b2.mac.purchase.category.retry")
        case .failed(let failure):
            Text("支出分类读取失败：\(failure.message)").font(V15Typography.secondary).accessibilityIdentifier("v15.f3b2.mac.purchase.category.error")
            V15ActionButton("重试读取支出分类", kind: .secondary) { Task { await model.loadFeeCategories() } }.accessibilityIdentifier("v15.f3b2.mac.purchase.category.retry")
        case .idle:
            V15ActionButton("读取支出分类", kind: .secondary) { Task { await model.loadFeeCategories() } }.accessibilityIdentifier("v15.f3b2.mac.purchase.category.retry")
        }
    }

    private var existingForm: some View {
        Group {
            V15Field("消费账目 ID", text: $model.purchaseTransactionIDText)
            V15ActionButton("检查分期资格") { Task { await model.checkEligibility() } }.accessibilityIdentifier("v15.f3b2.mac.eligibility.check")
            if let eligibility = model.eligibility { Text(eligibility.eligible ? "可分期 · 服务端本金 \(eligibility.principalMinor) 分" : "不可分期 · \(eligibility.reasonCode ?? "无原因码")").foregroundStyle(eligibility.eligible ? V15Palette.teal.color : V15Palette.gold.color).accessibilityIdentifier("v15.f3b2.mac.eligibility.result") }
            switch model.eligibilityPurchasePhase {
            case .loading: ProgressView("正在读取权威消费发生时间").accessibilityIdentifier("v15.f3b2.mac.eligibility.purchase.loading")
            case .failed(let failure):
                Text("消费详情读取失败：\(failure.message)").font(V15Typography.secondary).accessibilityIdentifier("v15.f3b2.mac.eligibility.purchase.error")
                V15ActionButton("重试消费详情", kind: .secondary) { Task { await model.checkEligibility() } }.accessibilityIdentifier("v15.f3b2.mac.eligibility.purchase.retry")
            case .loaded:
                if let purchase = model.eligibilityPurchase { Text("消费详情已读取 · 服务端业务日期 \(purchase.businessDate) · 精确发生时间已用于手续费边界").font(V15Typography.secondary).accessibilityIdentifier("v15.f3b2.mac.eligibility.purchase.loaded") }
            case .empty, .idle: EmptyView()
            }
            HStack { V15Field("期数", text: $model.createInstallmentCountText); V15Field("手续费（元）", text: $model.createFeeText) }
            if positiveFee(model.createFeeText) { feeDetails(categoryID: $model.createFeeCategoryID, occurredDateText: $model.createFeeOccurredDateText, prefix: "v15.f3b2.mac.existing") }
            Picker("起始账期", selection: $model.createStartStatementDate) { Text("请选择").tag(""); ForEach(model.cycleOptions.filter(\.eligible)) { Text("\($0.statementDate) · 到期 \($0.dueDate)").tag($0.statementDate) } }.pickerStyle(.menu)
            V15FieldIssues(issues: model.fieldIssues)
            V15ActionButton("创建计划", disabledReason: model.createPlanDisabledReason) { Task { await model.createPlan() } }.accessibilityIdentifier("v15.f3b2.mac.existing.commit")
            if model.createPlanPhase == .succeeded { V15SuccessReceiptState(title: "分期计划已创建", detail: "服务端已返回计划事实。").accessibilityIdentifier("v15.f3b2.mac.existing.success") }
            if model.createPlanPhase == .unknown { Text("结果未知；不得换 key，只能同一请求凭证重试。").foregroundStyle(V15Palette.gold.color).accessibilityIdentifier("v15.f3b2.mac.existing.unknown"); V15ActionButton("同一请求凭证重试") { Task { await model.retryUnknownCreatePlan() } }.accessibilityIdentifier("v15.f3b2.mac.existing.retry") }
        }
    }

    @ViewBuilder private func feeDetails(categoryID: Binding<UUID?>, occurredDateText: Binding<String>, prefix: String) -> some View {
        switch model.feeCategoryPhase {
        case .loading: ProgressView("正在读取手续费支出分类").accessibilityIdentifier("\(prefix).fee-category.loading")
        case .loaded: Picker("手续费支出分类", selection: categoryID) { Text("请选择").tag(UUID?.none); ForEach(model.expenseCategories) { Text($0.name).tag(Optional($0.id)) } }.pickerStyle(.menu).disabled(model.isOffline).accessibilityIdentifier("\(prefix).fee-category")
        case .empty: Text("暂无支出分类，请先创建分类；正手续费不能提交。").font(V15Typography.secondary).accessibilityIdentifier("\(prefix).fee-category.empty"); V15ActionButton("重新读取分类", kind: .secondary) { Task { await model.loadFeeCategories() } }.accessibilityIdentifier("\(prefix).fee-category.retry")
        case .failed(let failure): Text("支出分类读取失败：\(failure.message)").font(V15Typography.secondary).accessibilityIdentifier("\(prefix).fee-category.error"); V15ActionButton("重试读取分类", kind: .secondary) { Task { await model.loadFeeCategories() } }.accessibilityIdentifier("\(prefix).fee-category.retry")
        case .idle: V15ActionButton("读取手续费支出分类", kind: .secondary) { Task { await model.loadFeeCategories() } }.accessibilityIdentifier("\(prefix).fee-category.retry")
        }
        V15Field("手续费发生日期（上海）", text: occurredDateText, issues: model.fieldIssues.filter { $0.fieldPath == "fee_occurred_at" }).disabled(model.isOffline).accessibilityIdentifier("\(prefix).fee-date")
    }
    private func positiveFee(_ text: String) -> Bool { (CNYAmountParser.minorUnits(text) ?? 0) > 0 }
}
