import SwiftUI

public struct V15InstallmentMacView: View {
    private enum InspectorMode: String, CaseIterable { case facts = "详情", edit = "修改", command = "操作" }
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
                spine.frame(minWidth: V15MacLayout.compactInstallmentWidths.spine, idealWidth: 300, maxWidth: 380)
                schedule.frame(minWidth: V15MacLayout.compactInstallmentWidths.schedule, idealWidth: 560, maxWidth: .infinity)
                inspector.frame(minWidth: V15MacLayout.compactInstallmentWidths.inspector, idealWidth: 410, maxWidth: 520)
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
            case .empty: V15EmptyState(title: "暂无计划", explanation: "创建后会显示在这里。")
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
                        HStack(alignment: .firstTextBaseline) { VStack(alignment: .leading) { Text(plan.title).font(V15Typography.surfaceTitle); Text(plan.status.displayName).font(V15Typography.secondary) }; Spacer(); V15MoneyText(minorUnits: plan.totalFinancedMinor, direction: .outflow, font: V15Typography.moneyLarge) }
                        if plan.isDisplayOnly { V15DisplayOnlyState(detail: "暂时无法识别此计划状态，当前只供查看。").accessibilityIdentifier("v15.f3b2.mac.unknown") }
                        HStack(spacing: V15Spacing.sm) { metric("锁定", plan.lockedCount); metric("未来", plan.futureCount); metric("取消", plan.cancelledCount); metric("已结账期", plan.cycleSettledCount) }
                        V15Section("金额分层") {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: V15Spacing.sm)], alignment: .leading, spacing: V15Spacing.sm) {
                                amountMetric("计划本金", plan.principalMinor)
                                amountMetric("计划手续费", plan.feeMinor)
                                amountMetric("计划总额", plan.totalFinancedMinor)
                                amountMetric("未来未出账", plan.futureScheduledGrossMinor, provisional: true)
                            }
                            Text("未来未出账计划不等于当前精确信用欠款；当前欠款只在信用账户与账期中确认。")
                                .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
                        }.accessibilityIdentifier("v15.f3b2.mac.amount-layers")
                        V15Section("分期期次") {
                            ForEach(plan.periods) { period in
                                V15LedgerRow(title: "第 \(period.sequence) 期 · \(period.status.displayName)", detail: "账单 \(period.effectiveStatementDate) · 到期 \(period.dueDate) · \(period.locked ? "已锁定" : "未来")", amountMinor: period.amountDueMinor, direction: .outflow, marker: period.locked ? .ordinary : .provisional)
                                    .accessibilityIdentifier("v15.f3b2.period.\(period.id.uuidString)")
                            }
                        }
                        if let liabilities = model.liabilities {
                            V15Section("未来负债", detail: "按月汇总") {
                                HStack { V15MoneyText(minorUnits: liabilities.totalFutureScheduledGrossMinor, direction: .outflow); Spacer(); Text("\(liabilities.groups.count) 个月").font(V15Typography.secondary) }
                                ForEach(liabilities.groups) { group in V15LedgerRow(title: group.month, detail: "\(group.periodCount) 期 · 含本金与手续费", amountMinor: group.totalScheduledGrossMinor, direction: .outflow) }
                            }.accessibilityIdentifier("v15.f3b2.mac.liabilities")
                        }
                    }.padding(V15Spacing.xl)
                }
            } else { V15EmptyState(title: "选择一项计划", explanation: "中间显示分期期次，右侧显示详情与操作。") }
        }
        .accessibilityIdentifier("v15.f3b2.mac.schedule")
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text(title.uppercased()).font(V15Typography.label); Text("\(value) 期").font(V15Typography.cardTitle) }.padding(V15Spacing.md).frame(maxWidth: .infinity, alignment: .leading).background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.card))
    }
    private func amountMetric(_ title: String, _ value: V15MinorUnits, provisional: Bool = false) -> some View { VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text(title).font(V15Typography.label); V15MoneyText(minorUnits: value, direction: .neutral, font: V15Typography.body.weight(.semibold)) }.padding(V15Spacing.sm).frame(maxWidth: .infinity, alignment: .leading).background(provisional ? V15Palette.provisional.color : V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control)) }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("详情", selection: $inspectorMode) { ForEach(InspectorMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).padding(V15Spacing.md)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.md) {
                    if let plan = model.selectedPlan {
                        switch inspectorMode {
                        case .facts: factInspector(plan)
                        case .edit: editInspector
                        case .command: commandInspector
                        }
                    } else { V15EmptyState(title: "没有选择", explanation: "从左侧选择一项计划。") }
                }.padding(V15Spacing.md)
            }
        }
        .accessibilityIdentifier("v15.f3b2.mac.inspector")
    }

    private func factInspector(_ plan: V15InstallmentPlan) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            Text("计划详情").font(V15Typography.cardTitle)
            LabeledContent("状态", value: plan.status.displayName); LabeledContent("起始账单", value: plan.startStatementDate)
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
            if let preview = model.planPreview { V15PreviewState(version: "修改预览") { V15InstallmentPlanPreviewDetails(preview: preview, prefix: "v15.f3b2.mac.edit.preview-detail") }.accessibilityIdentifier("v15.f3b2.mac.edit.preview-result") }
            V15ActionButton("确认修改", disabledReason: model.planCommitDisabledReason) { Task { await model.commitPlanUpdate() } }.accessibilityIdentifier("v15.f3b2.mac.edit.commit")
            planUpdateState
        }
    }

    @ViewBuilder private var planUpdateState: some View {
        switch model.planPhase {
        case .unknown:
            warning("暂时无法确认修改是否成功。检查最新状态不会重复保存。", id: "v15.f3b2.mac.edit.unknown")
            V15ActionButton("检查最新状态", kind: .secondary) { Task { await model.readBackUnknownPlanUpdate() } }.accessibilityIdentifier("v15.f3b2.mac.edit.readback")
            readback(model.updateReadbackPhase, prefix: "v15.f3b2.mac.edit")
        case .conflict(let conflict): V15ConflictState(conflict: conflict) { Task { await model.refresh() } }
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.requestPlanPreview() } }
        case .succeeded: V15SuccessReceiptState(title: "计划已更新", detail: "可以继续查看或操作。")
        case .previewing, .committing: V15LoadingSkeleton(layout: .decisionCard)
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
            V15ActionButton("查看操作预览", disabledReason: model.commandPreviewDisabledReason) { Task { await model.requestCommandPreview() } }.accessibilityIdentifier("v15.f3b2.mac.command.preview")
            if let preview = model.commandPreview { V15PreviewState { V15InstallmentCommandPreviewDetails(preview: preview, prefix: "v15.f3b2.mac.command.preview-detail") }.accessibilityIdentifier("v15.f3b2.mac.command.preview-result") }
            V15ActionButton("确认\(model.commandKind.title)", kind: model.commandKind == .cancelFuture ? .destructive : .primary, disabledReason: model.commandCommitDisabledReason) { Task { await model.commitCommand() } }.accessibilityIdentifier("v15.f3b2.mac.command.commit")
            commandState
        }
    }

    @ViewBuilder private var commandState: some View {
        switch model.commandPhase {
        case .unknown:
            warning("暂时无法确认操作结果。安全检查不会重复扣款或记账。", id: "v15.f3b2.mac.command.unknown")
            V15ActionButton("安全检查操作结果", disabledReason: model.isOffline ? .init(code: "offline_read_only", message: "离线时不能检查操作结果。", fieldPath: nil) : nil) { Task { await model.retryUnknownCommand() } }.accessibilityIdentifier("v15.f3b2.mac.command.retry")
            V15ActionButton("检查最新计划", kind: .secondary) { Task { await model.readBackUnknownCommand() } }
            commandReadback(model.commandReadbackPhase)
        case .conflict(let conflict): V15ConflictState(conflict: conflict) { Task { await model.refresh() } }
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.requestCommandPreview() } }
        case .succeeded:
            if let receipt = model.commandReceipt {
                V15SuccessReceiptState(title: "操作完成", detail: "已生成 \(receipt.systemTransactionCount) 笔相关账目").accessibilityIdentifier("v15.f3b2.mac.command.receipt")
                ForEach(receipt.systemTransactions, id: \.id) { transaction in
                    V15LedgerRow(title: transaction.title, detail: "相关账目", amountMinor: transaction.amountMinor, direction: .neutral)
                        .accessibilityIdentifier("v15.f3b2.mac.command.transaction.\(transaction.id.uuidString)")
                }
            }
            else { warning("暂时无法确认这次操作是否成功，请检查最新计划。", id: "v15.f3b2.mac.command.no-receipt") }
        case .previewing, .committing: V15LoadingSkeleton(layout: .decisionCard)
        default: EmptyView()
        }
    }

    private func warning(_ text: String, id: String) -> some View { Text(text).font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true).padding(V15Spacing.md).background(V15Palette.provisional.color, in: RoundedRectangle(cornerRadius: V15Radius.control)).accessibilityIdentifier(id) }
    @ViewBuilder private func readback(_ phase: V15InstallmentModel.ReadbackPhase, prefix: String) -> some View { switch phase { case .loading: V15LoadingSkeleton(layout: .compact); case .confirmed: Text("最新状态与本次操作一致").accessibilityIdentifier("\(prefix).confirmed"); case .notConfirmed: Text("最新状态仍不能确认本次操作结果").accessibilityIdentifier("\(prefix).not-confirmed"); case .failed(let failure): Text("核对失败：\(failure.message)").accessibilityIdentifier("\(prefix).error"); case .idle: EmptyView() } }
    @ViewBuilder private func commandReadback(_ phase: V15InstallmentModel.ReadbackPhase) -> some View { switch phase { case .loading: V15LoadingSkeleton(layout: .compact); case .notConfirmed: Text("计划可能已经变化，但仍无法确认付款账户、账单日和时间是否属于本次操作。你仍可继续安全检查。").font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("v15.f3b2.mac.command.readback.not-confirmed"); case .failed(let failure): Text("读取最新计划失败：\(failure.message)。你仍可继续安全检查。").font(V15Typography.secondary).accessibilityIdentifier("v15.f3b2.mac.command.readback.error"); case .confirmed: Text("本次操作已安全确认。"); case .idle: EmptyView() } }
    @ViewBuilder private func feeDetails(categoryID: Binding<UUID?>, occurredDateText: Binding<String>, prefix: String) -> some View {
        switch model.feeCategoryPhase {
        case .loading: V15LoadingSkeleton(layout: .compact).accessibilityIdentifier("\(prefix).fee-category.loading")
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
    @Bindable var model: V15InstallmentModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            HStack { Text("新分期消费").font(V15Typography.surfaceTitle); Spacer(); Button("关闭") { dismiss() }.accessibilityIdentifier("v15.f3b2.mac.create.dismiss") }
            ScrollView { VStack(alignment: .leading, spacing: V15Spacing.md) { purchaseForm }.frame(maxWidth: .infinity, alignment: .leading) }
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
            V15ActionButton("查看分期预览", disabledReason: model.purchasePreviewDisabledReason) { Task { await model.requestPurchasePreview() } }.accessibilityIdentifier("v15.f3b2.mac.purchase.preview")
            if let preview = model.purchasePreview { V15PreviewState { V15InstallmentPurchasePreviewDetails(preview: preview, prefix: "v15.f3b2.mac.purchase.preview-detail") }.accessibilityIdentifier("v15.f3b2.mac.purchase.preview-result") }
            V15ActionButton("确认创建", disabledReason: model.purchaseCommitDisabledReason) { Task { await model.commitPurchase() } }.accessibilityIdentifier("v15.f3b2.mac.purchase.commit")
            if model.purchasePhase == .unknown { Text("这笔可能已经创建。安全检查不会重复记账。").foregroundStyle(V15Palette.gold.color).accessibilityIdentifier("v15.f3b2.mac.purchase.unknown"); V15ActionButton("安全检查创建结果") { Task { await model.retryUnknownPurchase() } }.accessibilityIdentifier("v15.f3b2.mac.purchase.retry") }
        }
    }

    @ViewBuilder private var purchaseCategorySurface: some View {
        switch model.feeCategoryPhase {
        case .loading:
            V15LoadingSkeleton(layout: .compact).accessibilityIdentifier("v15.f3b2.mac.purchase.category.loading")
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

    @ViewBuilder private func feeDetails(categoryID: Binding<UUID?>, occurredDateText: Binding<String>, prefix: String) -> some View {
        switch model.feeCategoryPhase {
        case .loading: V15LoadingSkeleton(layout: .compact).accessibilityIdentifier("\(prefix).fee-category.loading")
        case .loaded: Picker("手续费支出分类", selection: categoryID) { Text("请选择").tag(UUID?.none); ForEach(model.expenseCategories) { Text($0.name).tag(Optional($0.id)) } }.pickerStyle(.menu).disabled(model.isOffline).accessibilityIdentifier("\(prefix).fee-category")
        case .empty: Text("暂无支出分类，请先创建分类；正手续费不能提交。").font(V15Typography.secondary).accessibilityIdentifier("\(prefix).fee-category.empty"); V15ActionButton("重新读取分类", kind: .secondary) { Task { await model.loadFeeCategories() } }.accessibilityIdentifier("\(prefix).fee-category.retry")
        case .failed(let failure): Text("支出分类读取失败：\(failure.message)").font(V15Typography.secondary).accessibilityIdentifier("\(prefix).fee-category.error"); V15ActionButton("重试读取分类", kind: .secondary) { Task { await model.loadFeeCategories() } }.accessibilityIdentifier("\(prefix).fee-category.retry")
        case .idle: V15ActionButton("读取手续费支出分类", kind: .secondary) { Task { await model.loadFeeCategories() } }.accessibilityIdentifier("\(prefix).fee-category.retry")
        }
        V15Field("手续费发生日期（上海）", text: occurredDateText, issues: model.fieldIssues.filter { $0.fieldPath == "fee_occurred_at" }).disabled(model.isOffline).accessibilityIdentifier("\(prefix).fee-date")
    }
    private func positiveFee(_ text: String) -> Bool { (CNYAmountParser.minorUnits(text) ?? 0) > 0 }
}
