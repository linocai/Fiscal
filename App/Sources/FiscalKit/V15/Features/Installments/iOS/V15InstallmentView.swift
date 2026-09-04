import SwiftUI

public struct V15InstallmentView: View {
    private enum Sheet: String, Identifiable { case purchase, existingPurchase, edit, command; var id: String { rawValue } }
    @State private var model: V15InstallmentModel
    @State private var sheet: Sheet?
    private let initialAccountID: UUID?
    private let initialPlanID: UUID?
    private let initialPurchaseTransactionID: UUID?

    @MainActor public init(
        services: V15Services,
        offlineSnapshotAt: Date? = nil,
        initialAccountID: UUID? = nil,
        initialPlanID: UUID? = nil,
        initialPurchaseTransactionID: UUID? = nil,
        now: @escaping () -> Date = { .now }
    ) {
        let model = V15InstallmentModel(services: services, offlineSnapshotAt: offlineSnapshotAt, now: now)
        model.purchaseTransactionIDText = initialPurchaseTransactionID?.uuidString ?? ""
        _model = State(initialValue: model)
        _sheet = State(initialValue: initialPurchaseTransactionID == nil ? nil : .existingPurchase)
        self.initialAccountID = initialAccountID
        self.initialPlanID = initialPlanID
        self.initialPurchaseTransactionID = initialPurchaseTransactionID
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .idle, .loading: V15LoadingSkeleton().padding()
                case .empty: V15EmptyState(title: "还没有分期计划", explanation: "可以为已有信用消费建立计划，或直接录入新的分期消费。", actionTitle: "新建分期消费") { sheet = .purchase }
                case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await loadInitialState() } }.padding()
                case .loaded: content
                }
            }
            .v15IOSScreenCanvas()
            .navigationTitle("分期")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { sheet = .purchase } label: { Label("新分期消费", systemImage: "plus") }.accessibilityIdentifier("v15.f3b2.purchase.open")
                }
            }
            .task { if case .idle = model.phase { await loadInitialState() } }
            .refreshable { await model.refresh() }
            .sheet(item: $sheet, onDismiss: model.dismissEditor) { value in editor(value) }
        }
        .accessibilityIdentifier("v15.f3b2.installments.ios")
    }

    private func loadInitialState() async {
        await model.load(initialAccountID: initialAccountID, initialPlanID: initialPlanID)
        if initialPurchaseTransactionID != nil { await model.checkEligibility() }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: V15Spacing.md) {
                if let snapshot = model.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: snapshot).accessibilityIdentifier("v15.f3b2.offline") }
                V15Section("建立分期") {
                    V15ActionButton("从已有信用消费建立", symbol: "arrow.triangle.branch", kind: .secondary, disabledReason: model.isOffline ? .init(code: "offline_read_only", message: "离线时只可查看，无法建立分期计划。", fieldPath: nil) : nil) {
                        sheet = .existingPurchase
                    }
                    .accessibilityIdentifier("v15.f3b2.existing.open")
                }
                filterBar
                V15Section("计划", detail: "\(model.plans.count) 项") {
                    ForEach(model.plans) { plan in
                        V15LedgerRow(title: plan.title, detail: "\(plan.status.displayName) · \(plan.installmentCount) 期 · 锁定 \(plan.lockedCount) / 未来 \(plan.futureCount)", amountMinor: plan.futureScheduledGrossMinor, direction: .outflow, marker: plan.isDisplayOnly ? .archive : plan.status == .active ? .decision : .ordinary) { Task { await model.selectPlan(plan) } }
                            .accessibilityIdentifier("v15.f3b2.plan.\(plan.id.uuidString)")
                    }
                    pageSurface
                }
                if let plan = model.selectedPlan { detail(plan) }
            }
            .padding(V15Spacing.md)
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: V15Spacing.xs) {
            Picker("状态", selection: Binding(get: { model.filterStatus ?? "all" }, set: { value in Task { await model.setFilters(status: value == "all" ? nil : value, accountID: model.filterAccountID) } })) {
                Text("全部").tag("all"); Text("进行中").tag("active"); Text("已完成").tag("completed"); Text("已提前结清").tag("settled_early"); Text("部分取消").tag("partially_cancelled"); Text("已取消").tag("cancelled")
            }.pickerStyle(.menu).accessibilityIdentifier("v15.f3b2.status-filter")
            Picker("信用账户", selection: Binding(get: { model.filterAccountID }, set: { value in Task { await model.setFilters(status: model.filterStatus, accountID: value) } })) {
                Text("全部账户").tag(UUID?.none)
                ForEach(model.creditAccounts) { Text($0.name).tag(Optional($0.id)) }
            }.pickerStyle(.menu).accessibilityIdentifier("v15.f3b2.account-filter")
        }
    }

    @ViewBuilder private var pageSurface: some View {
        switch model.pagePhase {
        case .idle:
            if model.nextCursor != nil { V15ActionButton("加载更多", kind: .secondary) { Task { await model.loadNextPage() } }.accessibilityIdentifier("v15.f3b2.page.next") }
        case .loading: V15LoadingSkeleton(layout: .compact)
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.loadNextPage() } }.accessibilityIdentifier("v15.f3b2.page.error")
        }
    }

    private func detail(_ plan: V15InstallmentPlan) -> some View {
        V15Section("计划详情", detail: plan.status.displayName) {
            VStack(alignment: .leading, spacing: V15Spacing.sm) {
                if model.detailPhase == .loading { V15LoadingSkeleton(layout: .compact).accessibilityIdentifier("v15.f3b2.detail.loading") }
                if case .failed(let failure) = model.detailPhase {
                    V15ServiceErrorState(message: failure.message) { Task { await model.selectPlan(plan, readCachePolicy: .reloadIgnoringCache) } }
                        .accessibilityIdentifier("v15.f3b2.detail.error")
                }
                HStack { VStack(alignment: .leading) { Text(plan.title).font(V15Typography.cardTitle); Text(plan.status.displayName).font(V15Typography.secondary) }; Spacer(); V15MoneyText(minorUnits: plan.totalFinancedMinor, direction: .outflow) }
                if plan.isDisplayOnly { V15DisplayOnlyState(detail: "暂时无法识别此计划状态，当前只供查看。").accessibilityIdentifier("v15.f3b2.unknown-state") }
                HStack { fact("已锁定", "\(plan.lockedCount) 期"); fact("未来", "\(plan.futureCount) 期"); fact("已取消", "\(plan.cancelledCount) 期") }
                V15Section("金额分层") {
                    HStack(alignment: .top, spacing: V15Spacing.sm) {
                        installmentAmountFact("计划本金", plan.principalMinor)
                        installmentAmountFact("计划手续费", plan.feeMinor)
                    }
                    HStack(alignment: .top, spacing: V15Spacing.sm) {
                        installmentAmountFact("计划总额", plan.totalFinancedMinor)
                        installmentAmountFact("未来未出账", plan.futureScheduledGrossMinor, provisional: true)
                    }
                    Text("未来未出账金额不等于当前欠款；当前欠款请以信用账户和账期页面为准。")
                        .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("v15.f3b2.amount-layers")
                ForEach(plan.periods) { period in
                    V15LedgerRow(title: "第 \(period.sequence) 期 · \(period.status.displayName)", detail: "账单 \(period.effectiveStatementDate) · 到期 \(period.dueDate) · \(period.locked ? "已锁定" : "未来期")", amountMinor: period.amountDueMinor, direction: .outflow, marker: period.locked ? .ordinary : .provisional)
                }
                if let debt = model.liabilities {
                    V15Section("未来负债", detail: "按月汇总") {
                        V15MoneyText(minorUnits: debt.totalFutureScheduledGrossMinor, direction: .outflow)
                        ForEach(debt.groups) { group in Text("\(group.month) · \(group.periodCount) 期 · \(V15MoneyPresentation(minorUnits: group.totalScheduledGrossMinor, direction: .outflow).text)").font(V15Typography.secondary) }
                    }.accessibilityIdentifier("v15.f3b2.liabilities")
                }
                HStack {
                    V15ActionButton("修改计划", kind: .secondary, disabledReason: model.planMutationDisabledReason) { sheet = .edit }.accessibilityIdentifier("v15.f3b2.edit.open")
                    V15ActionButton("计划操作", disabledReason: model.planMutationDisabledReason) { sheet = .command }.accessibilityIdentifier("v15.f3b2.command.open")
                }
            }
            .padding(V15Spacing.md).background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.card))
        }
        .accessibilityIdentifier("v15.f3b2.detail")
    }

    private func fact(_ title: String, _ value: String) -> some View { VStack(alignment: .leading) { Text(title).font(V15Typography.label); Text(value).font(V15Typography.body.weight(.semibold)) }.frame(maxWidth: .infinity, alignment: .leading) }
    private func installmentAmountFact(_ title: String, _ value: V15MinorUnits, provisional: Bool = false) -> some View { VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text(title).font(V15Typography.label); V15MoneyText(minorUnits: value, direction: .neutral, font: V15Typography.body.weight(.semibold)) }.padding(V15Spacing.sm).frame(maxWidth: .infinity, alignment: .leading).background(provisional ? V15Palette.provisional.color : V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control)) }

    @ViewBuilder private func editor(_ value: Sheet) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.md) {
                    sheetErrorSurface
                    switch value {
                    case .purchase: purchaseEditor
                    case .existingPurchase: existingPurchaseEditor
                    case .edit: planEditor
                    case .command: commandEditor
                    }
                }.padding(V15Spacing.md)
            }
            .v15IOSScreenCanvas()
            .navigationTitle(sheetTitle(value))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { sheet = nil }.accessibilityIdentifier("v15.f3b2.sheet.dismiss") } }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("v15.f3b2.sheet.\(value.rawValue)")
    }

    private func sheetTitle(_ value: Sheet) -> String { switch value { case .purchase: "新分期消费"; case .existingPurchase: "已有消费转分期"; case .edit: "修改计划"; case .command: "计划操作" } }

    @ViewBuilder private var sheetErrorSurface: some View {
        V15FieldIssues(issues: model.fieldIssues).accessibilityIdentifier("v15.f3b2.sheet.field-issues")
        if let failure = model.serverFailure { V15ServiceErrorState(message: failure.message) {}.accessibilityIdentifier("v15.f3b2.sheet.error") }
    }

    private var purchaseEditor: some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            Text("1 · 消费信息").font(V15Typography.cardTitle)
            V15Field("标题", text: $model.newPurchaseTitle, prompt: "例如 工作设备", issues: issues("purchase.title")).accessibilityIdentifier("v15.f3b2.purchase.title")
            V15Field("金额（元）", text: $model.newPurchaseAmountText, prompt: "3299.00", issues: issues("purchase.amount_minor"), keyboard: .decimal).accessibilityIdentifier("v15.f3b2.purchase.amount")
            Picker("信用账户", selection: $model.newPurchaseAccountID) { Text("请选择").tag(UUID?.none); ForEach(model.creditAccounts) { Text($0.name).tag(Optional($0.id)) } }.pickerStyle(.menu).accessibilityIdentifier("v15.f3b2.purchase.account")
            purchaseCategorySurface
            Text("2 · 分期设置").font(V15Typography.cardTitle)
            V15Field("期数", text: $model.newPurchaseCountText, prompt: "2–60", issues: issues("installment_count"), keyboard: .integer).accessibilityIdentifier("v15.f3b2.purchase.count")
            V15Field("手续费（元）", text: $model.newPurchaseFeeText, prompt: "0.00", issues: issues("total_fee_minor"), keyboard: .decimal).accessibilityIdentifier("v15.f3b2.purchase.fee")
            if positiveFee(model.newPurchaseFeeText) { feeDetails(categoryID: $model.newPurchaseFeeCategoryID, occurredDateText: $model.newPurchaseFeeOccurredDateText, prefix: "v15.f3b2.purchase") }
            V15Field("起始账单日", text: $model.newPurchaseStartStatementDate, prompt: "YYYY-MM-DD", issues: issues("start_statement_date")).accessibilityIdentifier("v15.f3b2.purchase.start")
            V15ActionButton("查看分期预览", disabledReason: model.purchasePreviewDisabledReason) { Task { await model.requestPurchasePreview() } }.accessibilityIdentifier("v15.f3b2.purchase.preview")
            purchasePreviewSurface
            V15ActionButton("确认创建", disabledReason: model.purchaseCommitDisabledReason) { Task { await model.commitPurchase() } }.accessibilityIdentifier("v15.f3b2.purchase.commit")
        }
    }

    private var existingPurchaseEditor: some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            V15Section("第 1 步 · 找到信用消费") {
                V15Field("消费账目 ID", text: $model.purchaseTransactionIDText, prompt: "粘贴信用消费账目 ID", issues: issues("purchase_transaction_id"))
                    .accessibilityIdentifier("v15.f3b2.eligibility.transaction")
                V15ActionButton("检查是否可分期", symbol: "checkmark.circle", kind: .secondary, disabledReason: model.isOffline ? .init(code: "offline_read_only", message: "离线时不能检查分期资格。", fieldPath: nil) : nil) {
                    Task { await model.checkEligibility() }
                }
                .accessibilityIdentifier("v15.f3b2.eligibility.check")
                eligibilitySurface
            }

            V15Section("第 2 步 · 设置计划") {
                V15Field("期数", text: $model.createInstallmentCountText, prompt: "2–60", issues: issues("installment_count"), keyboard: .integer)
                    .accessibilityIdentifier("v15.f3b2.existing.count")
                V15Field("手续费（元）", text: $model.createFeeText, prompt: "0.00", issues: issues("total_fee_minor"), keyboard: .decimal)
                    .accessibilityIdentifier("v15.f3b2.existing.fee")
                if positiveFee(model.createFeeText) {
                    feeDetails(categoryID: $model.createFeeCategoryID, occurredDateText: $model.createFeeOccurredDateText, prefix: "v15.f3b2.existing")
                }
                Picker("起始账单日", selection: $model.createStartStatementDate) {
                    Text("请选择").tag("")
                    ForEach(model.cycleOptions.filter(\.eligible), id: \.statementDate) { option in
                        Text("\(option.statementDate) · 到期 \(option.dueDate)").tag(option.statementDate)
                    }
                }
                .pickerStyle(.menu)
                .disabled(model.eligibility?.eligible != true || model.isOffline)
                .accessibilityIdentifier("v15.f3b2.existing.start")
                V15ActionButton("确认建立分期", disabledReason: model.createPlanDisabledReason) {
                    Task { await model.createPlan() }
                }
                .accessibilityIdentifier("v15.f3b2.existing.commit")
                existingPurchaseResultSurface
            }
        }
    }

    @ViewBuilder private var eligibilitySurface: some View {
        switch model.eligibilityPhase {
        case .idle: EmptyView()
        case .loading: V15LoadingSkeleton(layout: .compact).accessibilityIdentifier("v15.f3b2.eligibility.loading")
        case .empty: V15EmptyState(title: "没有找到消费", explanation: "请检查账目 ID 后重试。")
        case .failed(let failure): V15ErrorMessageState(title: "暂时无法检查资格", message: failure.message)
        case .loaded:
            if let eligibility = model.eligibility {
                if eligibility.eligible {
                    V15SuccessReceiptState(title: "可以建立分期", detail: "已取得可用账期，请继续设置计划。")
                        .accessibilityIdentifier("v15.f3b2.eligibility.success")
                } else {
                    V15ErrorMessageState(title: "当前不能分期", message: eligibilityReason(eligibility.reasonCode))
                        .accessibilityIdentifier("v15.f3b2.eligibility.reason")
                }
            }
        }
        switch model.eligibilityPurchasePhase {
        case .loaded:
            if let purchase = model.eligibilityPurchase {
                V15LedgerRow(title: purchase.title, detail: "已核对信用消费", amountMinor: purchase.amountMinor, direction: .outflow)
                    .accessibilityIdentifier("v15.f3b2.eligibility.purchase.loaded")
            }
        case .loading: V15LoadingSkeleton(layout: .compact).accessibilityIdentifier("v15.f3b2.eligibility.purchase.loading")
        case .failed(let failure): V15ErrorMessageState(title: "消费详情读取失败", message: failure.message)
        case .idle, .empty: EmptyView()
        }
    }

    @ViewBuilder private var existingPurchaseResultSurface: some View {
        switch model.createPlanPhase {
        case .idle: EmptyView()
        case .previewing, .previewed: EmptyView()
        case .committing: V15LoadingSkeleton(layout: .decisionCard).accessibilityIdentifier("v15.f3b2.existing.loading")
        case .succeeded: V15SuccessReceiptState(title: "分期计划已建立", detail: "原信用消费已关联到新计划。")
            .accessibilityIdentifier("v15.f3b2.existing.success")
        case .unknown:
            V15OutcomeUnknownState(title: "建立结果暂时不明", message: "这项计划可能已经建立。安全检查不会重复创建。", actionTitle: "安全检查建立结果", actionIdentifier: "v15.f3b2.existing.retry") {
                Task { await model.retryUnknownCreatePlan() }
            }
            .accessibilityIdentifier("v15.f3b2.existing.unknown")
        case .conflict(let conflict): V15ConflictState(conflict: conflict) { Task { await model.refresh() } }
        case .failed(let failure): V15ErrorMessageState(message: failure.message)
        }
    }

    @ViewBuilder private var purchaseCategorySurface: some View {
        switch model.feeCategoryPhase {
        case .loading:
            V15LoadingSkeleton(layout: .compact).accessibilityIdentifier("v15.f3b2.purchase.category.loading")
        case .empty:
            V15EmptyState(title: "暂无支出分类", explanation: "请先创建支出分类，再继续建立分期消费。")
                .accessibilityIdentifier("v15.f3b2.purchase.category.empty")
            V15ActionButton("重新读取支出分类", kind: .secondary) { Task { await model.loadFeeCategories() } }
                .accessibilityIdentifier("v15.f3b2.purchase.category.retry")
        case .failed(let failure):
            V15ErrorMessageState(title: "支出分类读取失败", message: failure.message)
                .accessibilityIdentifier("v15.f3b2.purchase.category.error")
            V15ActionButton("重试读取支出分类", kind: .secondary) { Task { await model.loadFeeCategories() } }
                .accessibilityIdentifier("v15.f3b2.purchase.category.retry")
        case .idle:
            V15ActionButton("读取支出分类", kind: .secondary) { Task { await model.loadFeeCategories() } }
                .accessibilityIdentifier("v15.f3b2.purchase.category.retry")
        case .loaded:
            Picker("支出分类", selection: $model.newPurchaseCategoryID) {
                Text("请选择").tag(UUID?.none)
                ForEach(model.expenseCategories) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.menu)
            .disabled(model.isOffline)
            .accessibilityIdentifier("v15.f3b2.purchase.category")
        }
    }

    @ViewBuilder private var purchasePreviewSurface: some View {
        switch model.purchasePhase {
        case .previewing, .committing: V15LoadingSkeleton(layout: .decisionCard).accessibilityIdentifier("v15.f3b2.purchase.loading")
        case .previewed:
            if let preview = model.purchasePreview { V15PreviewState { V15InstallmentPurchasePreviewDetails(preview: preview, prefix: "v15.f3b2.purchase.preview-detail") }.accessibilityIdentifier("v15.f3b2.purchase.preview-result") }
        case .succeeded:
            if model.purchaseReceipt != nil { V15SuccessReceiptState(title: "分期消费已创建", detail: "可以关闭并查看分期计划。").accessibilityIdentifier("v15.f3b2.purchase.receipt") }
        case .unknown:
            VStack(alignment: .leading, spacing: V15Spacing.sm) {
                unknownState("这笔可能已经创建。安全检查不会重复记账。", id: "v15.f3b2.purchase.unknown")
                V15ActionButton("安全检查创建结果", disabledReason: model.isOffline ? .init(code: "offline_read_only", message: "离线时不能检查创建结果。", fieldPath: nil) : nil) { Task { await model.retryUnknownPurchase() } }.accessibilityIdentifier("v15.f3b2.purchase.retry")
            }
        case .conflict(let conflict): V15ConflictState(conflict: conflict) { Task { await model.refresh() } }.accessibilityIdentifier("v15.f3b2.purchase.conflict")
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.requestPurchasePreview() } }
        case .idle: EmptyView()
        }
    }

    private var planEditor: some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            V15Field("标题", text: $model.editTitle, issues: issues("purchase.title")).accessibilityIdentifier("v15.f3b2.edit.title")
            V15Field("消费金额（元）", text: $model.editAmountText, issues: issues("purchase.amount_minor"), keyboard: .decimal).accessibilityIdentifier("v15.f3b2.edit.amount")
            V15Field("期数", text: $model.editCountText, issues: issues("installment_count"), keyboard: .integer).accessibilityIdentifier("v15.f3b2.edit.count")
            V15Field("手续费（元）", text: $model.editFeeText, issues: issues("total_fee_minor"), keyboard: .decimal).accessibilityIdentifier("v15.f3b2.edit.fee")
            if positiveFee(model.editFeeText) { feeDetails(categoryID: $model.editFeeCategoryID, occurredDateText: $model.editFeeOccurredDateText, prefix: "v15.f3b2.edit") }
            V15Field("起始账单日", text: $model.editStartStatementDate, issues: issues("start_statement_date")).accessibilityIdentifier("v15.f3b2.edit.start")
            V15ActionButton("预览锁定期与账期影响", disabledReason: model.planPreviewDisabledReason) { Task { await model.requestPlanPreview() } }.accessibilityIdentifier("v15.f3b2.edit.preview")
            planPreviewSurface
            V15ActionButton("确认修改", disabledReason: model.planCommitDisabledReason) { Task { await model.commitPlanUpdate() } }.accessibilityIdentifier("v15.f3b2.edit.commit")
        }
    }

    @ViewBuilder private var planPreviewSurface: some View {
        switch model.planPhase {
        case .previewing, .committing: V15LoadingSkeleton(layout: .decisionCard)
        case .previewed:
            if let preview = model.planPreview { V15PreviewState(version: "修改预览") { V15InstallmentPlanPreviewDetails(preview: preview, prefix: "v15.f3b2.edit.preview-detail") }.accessibilityIdentifier("v15.f3b2.edit.preview-result") }
        case .unknown:
            VStack(alignment: .leading, spacing: V15Spacing.sm) { unknownState("暂时无法确认修改是否成功。检查最新状态不会重复保存。", id: "v15.f3b2.edit.unknown"); V15ActionButton("检查最新状态") { Task { await model.readBackUnknownPlanUpdate() } }.accessibilityIdentifier("v15.f3b2.edit.readback"); readbackSurface(model.updateReadbackPhase, prefix: "v15.f3b2.edit") }
        case .conflict(let conflict): V15ConflictState(conflict: conflict) { Task { await model.refresh() } }
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.requestPlanPreview() } }
        case .succeeded:
            V15SuccessReceiptState(title: "计划已更新", detail: "可以关闭并查看最新计划。")
                .accessibilityIdentifier(model.updateReadbackPhase == .confirmed ? "v15.f3b2.edit.readback.confirmed" : "v15.f3b2.edit.success")
        case .idle: EmptyView()
        }
    }

    private var commandEditor: some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            Picker("操作", selection: $model.commandKind) { ForEach(V15InstallmentModel.CommandKind.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).accessibilityIdentifier("v15.f3b2.command.kind")
            if model.commandKind == .settleEarly {
                Picker("付款账户", selection: $model.paymentAccountID) { Text("请选择").tag(UUID?.none); ForEach(model.paymentAccounts) { Text($0.name).tag(Optional($0.id)) } }.pickerStyle(.menu).accessibilityIdentifier("v15.f3b2.command.payment")
                V15Field("目标账单日", text: $model.targetStatementDate, prompt: "YYYY-MM-DD", issues: issues("target_statement_date")).accessibilityIdentifier("v15.f3b2.command.target")
            }
            V15ActionButton("查看操作预览", disabledReason: model.commandPreviewDisabledReason) { Task { await model.requestCommandPreview() } }.accessibilityIdentifier("v15.f3b2.command.preview")
            commandPreviewSurface
            V15ActionButton("确认\(model.commandKind.title)", kind: model.commandKind == .cancelFuture ? .destructive : .primary, disabledReason: model.commandCommitDisabledReason) { Task { await model.commitCommand() } }.accessibilityIdentifier("v15.f3b2.command.commit")
        }
    }

    @ViewBuilder private var commandPreviewSurface: some View {
        switch model.commandPhase {
        case .previewing, .committing: V15LoadingSkeleton(layout: .decisionCard).accessibilityIdentifier("v15.f3b2.command.loading")
        case .previewed:
            if let preview = model.commandPreview { V15PreviewState { V15InstallmentCommandPreviewDetails(preview: preview, prefix: "v15.f3b2.command.preview-detail") }.accessibilityIdentifier("v15.f3b2.command.preview-result") }
        case .succeeded:
            if let receipt = model.commandReceipt {
                VStack(alignment: .leading, spacing: V15Spacing.sm) {
                    V15SuccessReceiptState(title: "\(model.commandKind.title)已完成", detail: "已生成 \(receipt.systemTransactionCount) 笔相关账目").accessibilityIdentifier("v15.f3b2.command.receipt")
                    ForEach(receipt.systemTransactions, id: \.id) { transaction in
                        V15LedgerRow(title: transaction.title, detail: "相关账目", amountMinor: transaction.amountMinor, direction: .neutral)
                            .accessibilityIdentifier("v15.f3b2.command.transaction.\(transaction.id.uuidString)")
                    }
                }
            }
            else { V15SuccessReceiptState(title: "操作已确认", detail: "最新状态与本次操作一致。") }
        case .unknown:
            VStack(alignment: .leading, spacing: V15Spacing.sm) { unknownState("暂时无法确认操作结果。安全检查不会重复扣款或记账。", id: "v15.f3b2.command.unknown"); V15ActionButton("安全检查操作结果", disabledReason: model.isOffline ? .init(code: "offline_read_only", message: "离线时不能检查操作结果。", fieldPath: nil) : nil) { Task { await model.retryUnknownCommand() } }.accessibilityIdentifier("v15.f3b2.command.retry"); V15ActionButton("检查最新计划", kind: .secondary) { Task { await model.readBackUnknownCommand() } }.accessibilityIdentifier("v15.f3b2.command.readback"); V15ActionButton("停止恢复并刷新", kind: .quiet) { Task { await model.abandonUnknownCommandAndReload() } }; commandReadbackSurface(model.commandReadbackPhase) }
        case .conflict(let conflict): V15ConflictState(conflict: conflict) { Task { await model.refresh() } }.accessibilityIdentifier("v15.f3b2.command.conflict")
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.requestCommandPreview() } }
        case .idle: EmptyView()
        }
    }

    private func issues(_ path: String) -> [V15FieldIssue] { model.fieldIssues.filter { $0.fieldPath == path || ($0.fieldPath?.hasPrefix(path + ".") == true) } }

    @ViewBuilder private func feeDetails(categoryID: Binding<UUID?>, occurredDateText: Binding<String>, prefix: String) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.sm) {
            switch model.feeCategoryPhase {
            case .loading:
                V15LoadingSkeleton(layout: .compact)
                    .accessibilityIdentifier("\(prefix).fee-category.loading")
            case .empty:
                V15EmptyState(title: "暂无支出分类", explanation: "请先创建分类；正手续费不能在没有分类时提交。")
                    .accessibilityIdentifier("\(prefix).fee-category.empty")
                V15ActionButton("重新读取分类", kind: .secondary) { Task { await model.loadFeeCategories() } }
                    .accessibilityIdentifier("\(prefix).fee-category.retry")
            case .failed(let failure):
                V15ErrorMessageState(title: "支出分类读取失败", message: failure.message)
                    .accessibilityIdentifier("\(prefix).fee-category.error")
                V15ActionButton("重试读取分类", kind: .secondary) { Task { await model.loadFeeCategories() } }
                    .accessibilityIdentifier("\(prefix).fee-category.retry")
            case .idle:
                V15ActionButton("读取手续费支出分类", kind: .secondary) { Task { await model.loadFeeCategories() } }
                    .accessibilityIdentifier("\(prefix).fee-category.retry")
            case .loaded:
                Picker("手续费支出分类", selection: categoryID) {
                    Text("请选择").tag(UUID?.none)
                    ForEach(model.expenseCategories) { Text($0.name).tag(Optional($0.id)) }
                }
                .pickerStyle(.menu)
                .disabled(model.isOffline)
                .accessibilityIdentifier("\(prefix).fee-category")
            }
            V15Field("手续费发生日期（上海）", text: occurredDateText, prompt: "YYYY-MM-DD", issues: issues("fee_occurred_at"))
                .disabled(model.isOffline)
                .accessibilityIdentifier("\(prefix).fee-date")
            if model.isOffline { Text("离线时只可查看，不能填写或保存手续费。").font(V15Typography.secondary).accessibilityIdentifier("\(prefix).fee.offline") }
        }
    }

    private func positiveFee(_ text: String) -> Bool { (CNYAmountParser.minorUnits(text) ?? 0) > 0 }

    private func eligibilityReason(_ code: String?) -> String {
        switch code {
        case "installment_plan_in_use": "这笔消费已经属于另一个分期计划。"
        case "transaction_kind_invalid": "只有信用消费可以建立分期计划。"
        case "transaction_voided": "已作废的消费不能建立分期计划。"
        default: "这笔消费当前不符合分期条件。"
        }
    }

    private func unknownState(_ message: String, id: String) -> some View {
        V15OutcomeUnknownState(title: "需要核对", message: message).accessibilityIdentifier(id)
    }
    @ViewBuilder private func readbackSurface(_ phase: V15InstallmentModel.ReadbackPhase, prefix: String) -> some View {
        switch phase { case .loading: V15LoadingSkeleton(layout: .compact); case .confirmed: Text("最新状态与本次操作一致。") .accessibilityIdentifier("\(prefix).readback.confirmed"); case .notConfirmed: Text("最新状态仍不能确认本次操作结果。") .accessibilityIdentifier("\(prefix).readback.not-confirmed"); case .failed(let failure): Text("核对失败：\(failure.message)").accessibilityIdentifier("\(prefix).readback.error"); case .idle: EmptyView() }
    }
    @ViewBuilder private func commandReadbackSurface(_ phase: V15InstallmentModel.ReadbackPhase) -> some View {
        switch phase {
        case .loading: V15LoadingSkeleton(layout: .compact)
        case .notConfirmed: Text("计划可能已经变化，但仍无法确认付款账户、账单日和时间是否属于本次操作。你仍可继续安全检查。").font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("v15.f3b2.command.readback.not-confirmed")
        case .failed(let failure): Text("读取最新计划失败：\(failure.message)。你仍可继续安全检查。").font(V15Typography.secondary).accessibilityIdentifier("v15.f3b2.command.readback.error")
        case .confirmed: Text("本次操作已安全确认。").font(V15Typography.secondary)
        case .idle: EmptyView()
        }
    }
}
