import SwiftUI

public struct V15InstallmentView: View {
    private enum Sheet: String, Identifiable { case purchase, existingPurchase, edit, command; var id: String { rawValue } }
    @State private var model: V15InstallmentModel
    @State private var sheet: Sheet?

    @MainActor public init(services: V15Services, offlineSnapshotAt: Date? = nil, now: @escaping () -> Date = { .now }) {
        _model = State(initialValue: V15InstallmentModel(services: services, offlineSnapshotAt: offlineSnapshotAt, now: now))
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .idle, .loading: V15LoadingSkeleton().padding()
                case .empty: V15EmptyState(title: "还没有分期计划", explanation: "可以为已有信用消费建立计划，或直接录入新的分期消费。", actionTitle: "新建分期消费") { sheet = .purchase }
                case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.load() } }.padding()
                case .loaded: content
                }
            }
            .background(V15Palette.paper.color.ignoresSafeArea())
            .navigationTitle("分期")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { sheet = .existingPurchase } label: { Label("已有消费", systemImage: "link.badge.plus") }.accessibilityIdentifier("v15.f3b2.existing.open")
                    Button { sheet = .purchase } label: { Label("新分期消费", systemImage: "plus") }.accessibilityIdentifier("v15.f3b2.purchase.open")
                }
            }
            .task { if case .idle = model.phase { await model.load() } }
            .refreshable { await model.refresh() }
            .sheet(item: $sheet, onDismiss: model.dismissEditor) { value in editor(value) }
        }
        .accessibilityIdentifier("v15.f3b2.installments.ios")
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: V15Spacing.md) {
                if let snapshot = model.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: snapshot).accessibilityIdentifier("v15.f3b2.offline") }
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
        case .loading: ProgressView("正在读取下一页")
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.loadNextPage() } }.accessibilityIdentifier("v15.f3b2.page.error")
        }
    }

    private func detail(_ plan: V15InstallmentPlan) -> some View {
        V15Section("计划详情", detail: "v\(plan.version)") {
            VStack(alignment: .leading, spacing: V15Spacing.sm) {
                HStack { VStack(alignment: .leading) { Text(plan.title).font(V15Typography.cardTitle); Text(plan.status.displayName).font(V15Typography.secondary) }; Spacer(); V15MoneyText(minorUnits: plan.totalFinancedMinor, direction: .outflow) }
                if plan.isDisplayOnly { V15ArchiveReadOnlyState { Text("未知 future state 仅展示；当前客户端不会猜测可用操作。").fixedSize(horizontal: false, vertical: true) }.accessibilityIdentifier("v15.f3b2.unknown-state") }
                HStack { fact("已锁定", "\(plan.lockedCount) 期"); fact("未来", "\(plan.futureCount) 期"); fact("已取消", "\(plan.cancelledCount) 期") }
                ForEach(plan.periods) { period in
                    V15LedgerRow(title: "第 \(period.sequence) 期 · \(period.status.rawValue)", detail: "账单 \(period.effectiveStatementDate) · 到期 \(period.dueDate) · \(period.locked ? "已锁定" : "未来期")", amountMinor: period.amountDueMinor, direction: .outflow, marker: period.locked ? .ordinary : .provisional)
                }
                if let debt = model.liabilities {
                    V15Section("未来负债", detail: "服务端口径") {
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
            .background(V15Palette.paper.color)
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
            Text("1 · 消费事实").font(V15Typography.cardTitle)
            V15Field("标题", text: $model.newPurchaseTitle, prompt: "例如 工作设备", issues: issues("purchase.title")).accessibilityIdentifier("v15.f3b2.purchase.title")
            V15Field("金额（元）", text: $model.newPurchaseAmountText, prompt: "3299.00", issues: issues("purchase.amount_minor")).accessibilityIdentifier("v15.f3b2.purchase.amount")
            Picker("信用账户", selection: $model.newPurchaseAccountID) { Text("请选择").tag(UUID?.none); ForEach(model.creditAccounts) { Text($0.name).tag(Optional($0.id)) } }.pickerStyle(.menu).accessibilityIdentifier("v15.f3b2.purchase.account")
            purchaseCategorySurface
            Text("2 · 分期设置").font(V15Typography.cardTitle)
            V15Field("期数", text: $model.newPurchaseCountText, prompt: "2–60", issues: issues("installment_count")).accessibilityIdentifier("v15.f3b2.purchase.count")
            V15Field("手续费（元）", text: $model.newPurchaseFeeText, prompt: "0.00", issues: issues("total_fee_minor")).accessibilityIdentifier("v15.f3b2.purchase.fee")
            if positiveFee(model.newPurchaseFeeText) { feeDetails(categoryID: $model.newPurchaseFeeCategoryID, occurredDateText: $model.newPurchaseFeeOccurredDateText, prefix: "v15.f3b2.purchase") }
            V15Field("起始账单日", text: $model.newPurchaseStartStatementDate, prompt: "YYYY-MM-DD", issues: issues("start_statement_date")).accessibilityIdentifier("v15.f3b2.purchase.start")
            V15ActionButton("预览服务端拆分", disabledReason: model.purchasePreviewDisabledReason) { Task { await model.requestPurchasePreview() } }.accessibilityIdentifier("v15.f3b2.purchase.preview")
            purchasePreviewSurface
            V15ActionButton("确认创建", disabledReason: model.purchaseCommitDisabledReason) { Task { await model.commitPurchase() } }.accessibilityIdentifier("v15.f3b2.purchase.commit")
        }
    }

    @ViewBuilder private var purchaseCategorySurface: some View {
        switch model.feeCategoryPhase {
        case .loading:
            ProgressView("正在读取支出分类").accessibilityIdentifier("v15.f3b2.purchase.category.loading")
        case .empty:
            unknownState("暂无支出分类，请先创建分类。", id: "v15.f3b2.purchase.category.empty")
            V15ActionButton("重新读取支出分类", kind: .secondary) { Task { await model.loadFeeCategories() } }
                .accessibilityIdentifier("v15.f3b2.purchase.category.retry")
        case .failed(let failure):
            unknownState("支出分类读取失败：\(failure.message)", id: "v15.f3b2.purchase.category.error")
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
        case .previewing, .committing: ProgressView("正在取得服务端结果").accessibilityIdentifier("v15.f3b2.purchase.loading")
        case .previewed:
            if let preview = model.purchasePreview { V15PreviewState { V15InstallmentPurchasePreviewDetails(preview: preview, prefix: "v15.f3b2.purchase.preview-detail") }.accessibilityIdentifier("v15.f3b2.purchase.preview-result") }
        case .succeeded:
            if let receipt = model.purchaseReceipt { V15SuccessReceiptState(title: "分期消费已创建", detail: "计划 \(receipt.plan.id.uuidString) · v\(receipt.plan.version)").accessibilityIdentifier("v15.f3b2.purchase.receipt") }
        case .unknown:
            VStack(alignment: .leading, spacing: V15Spacing.sm) {
                unknownState("创建结果未知；只能使用完全相同的 body 与 Idempotency-Key 重试。", id: "v15.f3b2.purchase.unknown")
                V15ActionButton("同一请求凭证重试", disabledReason: model.isOffline ? .init(code: "offline_read_only", message: "离线时不能重试写入。", fieldPath: nil) : nil) { Task { await model.retryUnknownPurchase() } }.accessibilityIdentifier("v15.f3b2.purchase.retry")
            }
        case .conflict(let conflict): V15ConflictState(conflict: conflict) { Task { await model.refresh() } }.accessibilityIdentifier("v15.f3b2.purchase.conflict")
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.requestPurchasePreview() } }
        case .idle: EmptyView()
        }
    }

    private var existingPurchaseEditor: some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            V15Field("消费账目 ID", text: $model.purchaseTransactionIDText, prompt: "UUID", issues: issues("purchase_transaction_id")).accessibilityIdentifier("v15.f3b2.eligibility.transaction")
            V15ActionButton("检查分期资格") { Task { await model.checkEligibility() } }.accessibilityIdentifier("v15.f3b2.eligibility.check")
            switch model.eligibilityPhase {
            case .loading: ProgressView("正在询问服务端")
            case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.checkEligibility() } }
            default: if let value = model.eligibility { eligibilitySurface(value) }
            }
            switch model.eligibilityPurchasePhase {
            case .loading:
                ProgressView("正在读取权威消费发生时间").accessibilityIdentifier("v15.f3b2.eligibility.purchase.loading")
            case .failed(let failure):
                V15ServiceErrorState(message: "消费详情读取失败：\(failure.message)") { Task { await model.checkEligibility() } }
                    .accessibilityIdentifier("v15.f3b2.eligibility.purchase.error")
            case .loaded:
                if let purchase = model.eligibilityPurchase {
                    V15SuccessReceiptState(title: "消费详情已读取", detail: "服务端业务日期 \(purchase.businessDate) · 精确发生时间已用于手续费边界")
                        .accessibilityIdentifier("v15.f3b2.eligibility.purchase.loaded")
                }
            case .empty, .idle: EmptyView()
            }
            V15Field("期数", text: $model.createInstallmentCountText, prompt: "2–60", issues: issues("installment_count"))
            V15Field("手续费（元）", text: $model.createFeeText, prompt: "0.00", issues: issues("total_fee_minor"))
                .accessibilityIdentifier("v15.f3b2.existing.fee")
            if positiveFee(model.createFeeText) { feeDetails(categoryID: $model.createFeeCategoryID, occurredDateText: $model.createFeeOccurredDateText, prefix: "v15.f3b2.existing") }
            Picker("起始账期", selection: $model.createStartStatementDate) { Text("请选择").tag(""); ForEach(model.cycleOptions.filter(\.eligible)) { Text("\($0.statementDate) · 到期 \($0.dueDate)").tag($0.statementDate) } }.pickerStyle(.menu).accessibilityIdentifier("v15.f3b2.eligibility.options")
            V15ActionButton("创建计划", disabledReason: model.createPlanDisabledReason) { Task { await model.createPlan() } }.accessibilityIdentifier("v15.f3b2.existing.commit")
            if model.createPlanPhase == .succeeded { V15SuccessReceiptState(title: "分期计划已创建", detail: "服务端已返回计划事实。").accessibilityIdentifier("v15.f3b2.existing.success") }
            if model.createPlanPhase == .unknown {
                unknownState("创建结果未知；不得换 key 再建，只能复用完全相同的请求凭证。", id: "v15.f3b2.existing.unknown")
                V15ActionButton("同一请求凭证重试", disabledReason: model.isOffline ? .init(code: "offline_read_only", message: "离线时不能重试写入。", fieldPath: nil) : nil) { Task { await model.retryUnknownCreatePlan() } }.accessibilityIdentifier("v15.f3b2.existing.retry")
            }
        }
    }

    private func eligibilitySurface(_ value: V15InstallmentEligibility) -> some View {
        Group {
            if value.eligible { V15SuccessReceiptState(title: "可分期", detail: "服务端本金 \(V15MoneyPresentation(minorUnits: value.principalMinor, direction: .outflow).text) · 自然账期 \(value.naturalStatementDate)").accessibilityIdentifier("v15.f3b2.eligibility.success") }
            else { unknownState("不可分期：\(value.reasonCode ?? "服务端未提供原因码")", id: "v15.f3b2.eligibility.reason") }
        }
    }

    private var planEditor: some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            V15Field("标题", text: $model.editTitle, issues: issues("purchase.title")).accessibilityIdentifier("v15.f3b2.edit.title")
            V15Field("消费金额（元）", text: $model.editAmountText, issues: issues("purchase.amount_minor")).accessibilityIdentifier("v15.f3b2.edit.amount")
            V15Field("期数", text: $model.editCountText, issues: issues("installment_count")).accessibilityIdentifier("v15.f3b2.edit.count")
            V15Field("手续费（元）", text: $model.editFeeText, issues: issues("total_fee_minor")).accessibilityIdentifier("v15.f3b2.edit.fee")
            if positiveFee(model.editFeeText) { feeDetails(categoryID: $model.editFeeCategoryID, occurredDateText: $model.editFeeOccurredDateText, prefix: "v15.f3b2.edit") }
            V15Field("起始账单日", text: $model.editStartStatementDate, issues: issues("start_statement_date")).accessibilityIdentifier("v15.f3b2.edit.start")
            V15ActionButton("预览锁定期与账期影响", disabledReason: model.planPreviewDisabledReason) { Task { await model.requestPlanPreview() } }.accessibilityIdentifier("v15.f3b2.edit.preview")
            planPreviewSurface
            V15ActionButton("确认修改（无重试凭证）", disabledReason: model.planCommitDisabledReason) { Task { await model.commitPlanUpdate() } }.accessibilityIdentifier("v15.f3b2.edit.commit")
        }
    }

    @ViewBuilder private var planPreviewSurface: some View {
        switch model.planPhase {
        case .previewing, .committing: ProgressView("正在处理")
        case .previewed:
            if let preview = model.planPreview { V15PreviewState(version: "计划 v\(preview.currentPlan.version)") { V15InstallmentPlanPreviewDetails(preview: preview, prefix: "v15.f3b2.edit.preview-detail") }.accessibilityIdentifier("v15.f3b2.edit.preview-result") }
        case .unknown:
            VStack(alignment: .leading, spacing: V15Spacing.sm) { unknownState("PUT 结果未知；没有 token/key，绝不会自动重发。只能 fresh GET 计划与消费后逐字段核对。", id: "v15.f3b2.edit.unknown"); V15ActionButton("刷新事实核对") { Task { await model.readBackUnknownPlanUpdate() } }.accessibilityIdentifier("v15.f3b2.edit.readback"); readbackSurface(model.updateReadbackPhase, prefix: "v15.f3b2.edit") }
        case .conflict(let conflict): V15ConflictState(conflict: conflict) { Task { await model.refresh() } }
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.requestPlanPreview() } }
        case .succeeded:
            V15SuccessReceiptState(title: "计划事实已更新", detail: "服务端已返回或 fresh GET 已逐字段确认。")
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
            V15ActionButton("预览服务端影响", disabledReason: model.commandPreviewDisabledReason) { Task { await model.requestCommandPreview() } }.accessibilityIdentifier("v15.f3b2.command.preview")
            commandPreviewSurface
            V15ActionButton("确认\(model.commandKind.title)", kind: model.commandKind == .cancelFuture ? .destructive : .primary, disabledReason: model.commandCommitDisabledReason) { Task { await model.commitCommand() } }.accessibilityIdentifier("v15.f3b2.command.commit")
        }
    }

    @ViewBuilder private var commandPreviewSurface: some View {
        switch model.commandPhase {
        case .previewing, .committing: ProgressView("正在处理").accessibilityIdentifier("v15.f3b2.command.loading")
        case .previewed:
            if let preview = model.commandPreview { V15PreviewState { V15InstallmentCommandPreviewDetails(preview: preview, prefix: "v15.f3b2.command.preview-detail") }.accessibilityIdentifier("v15.f3b2.command.preview-result") }
        case .succeeded:
            if let receipt = model.commandReceipt {
                VStack(alignment: .leading, spacing: V15Spacing.sm) {
                    V15SuccessReceiptState(title: "\(model.commandKind.title)已完成", detail: "operation_id \(receipt.operationID.uuidString) · replayed \(receipt.replayed ? "是" : "否") · 系统流水 \(receipt.systemTransactionCount) 笔").accessibilityIdentifier("v15.f3b2.command.receipt")
                    ForEach(receipt.systemTransactions, id: \.id) { transaction in
                        V15LedgerRow(title: transaction.title, detail: "\(transaction.kind) · \(transaction.id.uuidString)", amountMinor: transaction.amountMinor, direction: .neutral)
                            .accessibilityIdentifier("v15.f3b2.command.transaction.\(transaction.id.uuidString)")
                    }
                }
            }
            else { V15SuccessReceiptState(title: "服务端事实已确认", detail: "刷新结果与请求意图一致。") }
        case .unknown:
            VStack(alignment: .leading, spacing: V15Spacing.sm) { unknownState("结果未知；只有完全相同的 body + Idempotency-Key 重放并取得 operation receipt 才能确认。fresh GET 只能提示计划事实变化，不能归因于本请求。", id: "v15.f3b2.command.unknown"); V15ActionButton("同一请求凭证重试", disabledReason: model.isOffline ? .init(code: "offline_read_only", message: "离线时不能重试写入。", fieldPath: nil) : nil) { Task { await model.retryUnknownCommand() } }.accessibilityIdentifier("v15.f3b2.command.retry"); V15ActionButton("刷新计划事实（不确认请求）", kind: .secondary) { Task { await model.readBackUnknownCommand() } }.accessibilityIdentifier("v15.f3b2.command.readback"); V15ActionButton("放弃请求凭证并刷新", kind: .quiet) { Task { await model.abandonUnknownCommandAndReload() } }; commandReadbackSurface(model.commandReadbackPhase) }
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
                ProgressView("正在读取手续费支出分类")
                    .accessibilityIdentifier("\(prefix).fee-category.loading")
            case .empty:
                unknownState("暂无支出分类，请先创建分类；正手续费不能提交。", id: "\(prefix).fee-category.empty")
                V15ActionButton("重新读取分类", kind: .secondary) { Task { await model.loadFeeCategories() } }
                    .accessibilityIdentifier("\(prefix).fee-category.retry")
            case .failed(let failure):
                unknownState("支出分类读取失败：\(failure.message)", id: "\(prefix).fee-category.error")
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
            if model.isOffline { Text("离线快照仅可查看，不能填写或提交手续费事实。").font(V15Typography.secondary).accessibilityIdentifier("\(prefix).fee.offline") }
        }
    }

    private func positiveFee(_ text: String) -> Bool { (CNYAmountParser.minorUnits(text) ?? 0) > 0 }

    private func unknownState(_ message: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.xs) { Label("需要核对", systemImage: V15Symbol.warning).font(V15Typography.cardTitle); Text(message).font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true) }
            .padding(V15Spacing.md).background(V15Palette.provisional.color, in: RoundedRectangle(cornerRadius: V15Radius.control)).accessibilityElement(children: .combine).accessibilityIdentifier(id)
    }
    @ViewBuilder private func readbackSurface(_ phase: V15InstallmentModel.ReadbackPhase, prefix: String) -> some View {
        switch phase { case .loading: ProgressView("正在强制读取最新事实"); case .confirmed: Text("最新事实与请求意图一致。") .accessibilityIdentifier("\(prefix).readback.confirmed"); case .notConfirmed: Text("最新事实不能确认该请求已生效；仍保持结果未知。") .accessibilityIdentifier("\(prefix).readback.not-confirmed"); case .failed(let failure): Text("核对失败：\(failure.message)").accessibilityIdentifier("\(prefix).readback.error"); case .idle: EmptyView() }
    }
    @ViewBuilder private func commandReadbackSurface(_ phase: V15InstallmentModel.ReadbackPhase) -> some View {
        switch phase {
        case .loading: ProgressView("正在强制读取最新计划事实")
        case .notConfirmed: Text("计划事实可能已变化或操作可能已发生，但 GET 无法证明付款账户、目标账单日、发生时间和 operation receipt 属于本请求；同一请求凭证仍保留。").font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("v15.f3b2.command.readback.not-confirmed")
        case .failed(let failure): Text("事实读取失败：\(failure.message)；同一请求凭证仍保留。").font(V15Typography.secondary).accessibilityIdentifier("v15.f3b2.command.readback.error")
        case .confirmed: Text("仅同一 key 重放返回的 operation receipt 可以确认该请求。").font(V15Typography.secondary)
        case .idle: EmptyView()
        }
    }
}
