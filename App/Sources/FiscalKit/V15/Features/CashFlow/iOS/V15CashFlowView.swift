import SwiftUI

#if os(iOS)
public struct V15CashFlowView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model: V15CashFlowModel
    @State private var showsHistory = false
    private let initialItem: V15CashFlowItem?

    public init(services: V15Services, offlineSnapshotAt: Date? = nil, initialItem: V15CashFlowItem? = nil) { _model = State(initialValue: V15CashFlowModel(services: services, offlineSnapshotAt: offlineSnapshotAt)); self.initialItem = initialItem }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.lg) {
                    header
                    if let snapshot = model.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: snapshot).accessibilityIdentifier("v15.f3d.offline") }
                    Picker("现金流视图", selection: Binding(get: { showsHistory }, set: { value in showsHistory = value; Task { await model.setVisibleList(value ? .history : .active) } })) { Text("未来事项").tag(false); Text("历史").tag(true) }
                        .pickerStyle(.segmented)
                        .disabled(model.selectionLocked)
                        .accessibilityIdentifier("v15.f3d.scope")
                    if showsHistory { historySurface } else { activeSurface }
                    if let item = model.selectedItem { detail(item) }
                    mutationBanner
                }
                .padding(V15Spacing.md)
                .frame(maxWidth: 760, alignment: .leading)
            }
            .v15IOSScreenCanvas()
            .navigationTitle("现金流")
            .toolbar { ToolbarItem(placement: .primaryAction) { Button { Task { await model.refresh() } } label: { Image(systemName: V15Symbol.retry) }.accessibilityLabel("刷新现金流数据").accessibilityIdentifier("v15.f3d.refresh") } }
        }
        .task { if model.phase == .idle { await model.load() }; if let initialItem { model.showVerifiedItem(initialItem) } }
        .sheet(isPresented: Binding(get: { model.editorMode != .none }, set: { if !$0 { model.dismissEditor() } })) { editorSheet }
        .accessibilityIdentifier("v15.f3d.cash-flow.ios")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: V15Spacing.sm) {
            Text("逐笔看清计划与实际").font(V15Typography.surfaceTitle).foregroundStyle(V15Palette.ink.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("v15.f3d.header.title")
            Text("集中查看未来收支、已完成记录，以及报销和信用账单安排。")
                .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("v15.f3d.header.detail")
            if let summary = model.active?.summary {
                VStack(spacing: V15Spacing.sm) {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: V15Spacing.sm) {
                            metric("30 日流入", summary.inflowMinor, .inflow, id: "inflow")
                            metric("30 日流出", summary.outflowMinor, .outflow, id: "outflow")
                        }
                    } else {
                        HStack(alignment: .top, spacing: V15Spacing.sm) {
                            metric("30 日流入", summary.inflowMinor, .inflow, id: "inflow")
                            metric("30 日流出", summary.outflowMinor, .outflow, id: "outflow")
                        }
                    }
                    metric("净额", summary.netMinor, netDirection(summary.netMinor), id: "net")
                }
            }
            V15PickerRow("账户筛选", selection: Binding(get: { model.accountFilterID }, set: { value in Task { await model.setAccountFilter(value) } })) {
                Text("全部账户").tag(UUID?.none)
                ForEach(model.accounts) { account in Text(account.name).tag(UUID?.some(account.id)) }
            }
            .disabled(model.selectionLocked)
            V15ActionButton("新建现金流", symbol: "plus", disabledReasons: model.openCreateReasons) { model.openCreate() }.accessibilityIdentifier("v15.f3d.create.open")
        }
        .padding(V15Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .v15IOSCard()
    }

    private func metric(_ title: String, _ amount: V15MinorUnits, _ direction: V15MoneyDirection, id: String) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.xxs) {
            Text(title)
                .font(V15Typography.label)
                .foregroundStyle(V15Palette.ink.color.opacity(0.62))
                .accessibilityIdentifier("v15.f3d.summary.\(id).label")
            V15MoneyText(minorUnits: amount, direction: direction)
                .accessibilityIdentifier("v15.f3d.summary.\(id).amount")
        }
            .padding(V15Spacing.sm).frame(maxWidth: .infinity, alignment: .leading).background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
    }

    private func netDirection(_ amount: V15MinorUnits) -> V15MoneyDirection {
        amount > 0 ? .inflow : amount < 0 ? .outflow : .neutral
    }

    @ViewBuilder private var activeSurface: some View {
        switch model.phase {
        case .idle, .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f3d.active.loading")
        case .empty: V15EmptyState(title: "没有未来现金流", explanation: "可以新建一次性或按月重复事项。", actionTitle: "新建") { model.openCreate() }.accessibilityIdentifier("v15.f3d.active.empty")
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.refresh() } }.accessibilityIdentifier("v15.f3d.active.error")
        case .loaded: itemList(model.active?.items ?? [], title: "未来事项", list: .active)
        }
    }

    @ViewBuilder private var historySurface: some View {
        VStack(alignment: .leading, spacing: V15Spacing.sm) {
            V15Field("历史月份", text: Binding(get: { model.historyMonth }, set: { value in Task { await model.setHistoryMonth(value) } }), prompt: "YYYY-MM")
                .disabled(model.selectionLocked)
                .accessibilityIdentifier("v15.f3d.history.month")
            switch model.historyPhase {
            case .idle, .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f3d.history.loading")
            case .empty: V15EmptyState(title: "本月没有现金流历史", explanation: "已入账、取消或完成的事项会显示在这里。", actionTitle: "重试") { Task { await model.setHistoryMonth(model.historyMonth) } }.accessibilityIdentifier("v15.f3d.history.empty")
            case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.setHistoryMonth(model.historyMonth) } }.accessibilityIdentifier("v15.f3d.history.error")
            case .loaded: itemList(model.history?.items ?? [], title: model.history?.month ?? "历史", list: .history)
            }
        }
    }

    private func itemList(_ items: [V15CashFlowItem], title: String, list: V15CashFlowModel.ListKind) -> some View {
        V15Section(title, detail: "\(items.count) 项") {
            VStack(spacing: 0) {
                ForEach(items) { item in
                    V15LedgerRow(title: item.title, detail: "\(item.expectedDate) · \(item.status.displayName) · \(sourceLabel(item))", amountMinor: item.plannedAmountMinor, direction: moneyDirection(item), marker: item.isDisplayOnly ? .provisional : item.status == .expected ? .provisional : .decision) { Task { await model.selectItem(item, from: list) } }
                        .disabled(model.selectionLocked)
                        .accessibilityIdentifier("v15.f3d.item.\(item.id)")
                    Divider()
                }
            }
        }
    }

    private func detail(_ item: V15CashFlowItem) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.sm) {
            V15AdaptiveStack(spacing: V15Spacing.xs) {
                Text(item.isSystem ? "系统派生" : "手工计划").font(V15Typography.label)
                    .padding(.horizontal, V15Spacing.xs).padding(.vertical, V15Spacing.xxs)
                    .background(item.isSystem ? V15Palette.provisional.color : V15Palette.selected.color, in: RoundedRectangle(cornerRadius: V15Radius.tag))
                if item.isSystem { Text(sourceLabel(item)).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.62)) }
            }
            V15AdaptiveStack(horizontalAlignment: .firstTextBaseline) { Text(item.title).font(V15Typography.cardTitle); Spacer(); Text(item.status.displayName).font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.62)) }
                .accessibilityIdentifier("v15.f3d.detail")
            Text("\(item.expectedDate) · \(item.direction.displayName) · \(item.status.displayName)").font(V15Typography.secondary)
            V15AdaptiveStack(spacing: V15Spacing.sm) {
                cashFlowFact("计划金额", value: item.plannedAmountMinor, date: item.expectedDate, provisional: true)
                if let actual = item.actualAmountMinor { cashFlowFact("实际入账", value: actual, date: item.actualDate ?? "日期未提供", provisional: false) }
                else { cashFlowUnavailableFact("实际入账", detail: item.isSystem ? "回来源流程确认" : "尚未结算") }
            }
            .accessibilityIdentifier("v15.f3d.plan-actual")
            if item.isOverdue { Label("已逾期", systemImage: V15Symbol.warning).foregroundStyle(V15Palette.gold.color) }
            if item.isDisplayOnly { Text("暂时无法识别此事项的状态或方向，当前只供查看。") .font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color).accessibilityIdentifier("v15.f3d.display-only") }
            if item.isSystem {
                Label(item.systemKind == .creditCycle ? "信用账单安排 · 请到还款页面处理" : "报销到账安排 · 请到报销页面登记", systemImage: "link")
                    .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
                V15ActionButton("修改显示信息", kind: .secondary, disabledReasons: systemOpenReasons(item)) { model.openEdit(item) }.accessibilityIdentifier("v15.f3d.system.edit.open")
            } else {
                V15AdaptiveStack(spacing: V15Spacing.sm) {
                    if let preview = model.confirmPreview, preview.itemBefore.id == item.id {
                        V15ActionButton(model.confirmCommitIsInFlight ? "正在提交" : "确认本次", kind: .secondary, disabledReasons: model.actionReasons(.confirm, for: item)) { Task { await model.commitConfirmPreview() } }.accessibilityIdentifier("v15.f3d.confirm.commit")
                    } else {
                        V15ActionButton("查看确认影响", kind: .secondary, disabledReasons: model.actionReasons(.confirm, for: item)) { Task { await model.previewConfirm(item) } }.accessibilityIdentifier("v15.f3d.confirm.preview")
                    }
                    V15ActionButton("入账", disabledReasons: settleOpenReasons(item)) { model.openSettle(item) }.accessibilityIdentifier("v15.f3d.settle.open")
                }
                V15AdaptiveStack(spacing: V15Spacing.sm) {
                    V15ActionButton("修改", kind: .quiet, disabledReasons: editOpenReasons(item)) { model.openEdit(item) }.accessibilityIdentifier("v15.f3d.edit.open")
                    V15ActionButton("取消", kind: .destructive, disabledReasons: model.actionReasons(.cancel, for: item)) { Task { await model.perform(.cancel, on: item) } }.accessibilityIdentifier("v15.f3d.cancel")
                }
            }
            if let preview = model.confirmPreview, preview.itemBefore.id == item.id {
                V15ServerFactState(title: "确认影响", detail: "\(preview.itemBefore.title)：\(preview.itemBefore.status.displayName) → 已确认。不会创建入账交易。")
            }
            ForEach(item.creditCycleParts) { part in Text("账期 \(part.periodStart)–\(part.periodEnd) · \(money(part.remainingMinor))").font(V15Typography.secondary) }
        }
        .padding(V15Spacing.md).background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.decisionCard)).overlay { RoundedRectangle(cornerRadius: V15Radius.decisionCard).stroke(V15Palette.hairline.color) }
    }
    private func cashFlowFact(_ title: String, value: V15MinorUnits, date: String, provisional: Bool) -> some View { VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text(title).font(V15Typography.label); V15MoneyText(minorUnits: value, direction: .neutral, font: V15Typography.body.weight(.semibold)); Text(date).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.62)) }.padding(V15Spacing.sm).frame(maxWidth: .infinity, alignment: .leading).background(provisional ? V15Palette.provisional.color : V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control)) }
    private func cashFlowUnavailableFact(_ title: String, detail: String) -> some View { VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text(title).font(V15Typography.label); Text("—").font(V15Typography.body.weight(.semibold)); Text(detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.62)) }.padding(V15Spacing.sm).frame(maxWidth: .infinity, alignment: .leading).background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control)) }

    private var editorSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.md) {
                    editorMessage
                    switch model.editorMode {
                    case .create, .edit: manualEditor
                    case .settle: settlementEditor
                    case .systemEdit: systemEditor
                    case .none: EmptyView()
                    }
                }
                .padding(V15Spacing.md)
            }
            .scrollDismissesKeyboard(.immediately)
            .v15IOSScreenCanvas()
            .navigationTitle(editorTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { model.dismissEditor() }.accessibilityIdentifier("v15.f3d.editor.close") }
                if case .create = model.editorMode {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("创建") { Task { await model.create() } }
                            .disabled(!model.createReasons.isEmpty)
                            .accessibilityIdentifier("v15.f3d.create.submit")
                    }
                }
                if case .edit = model.editorMode {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { Task { await model.update() } }
                            .disabled(!model.updateReasons.isEmpty)
                            .accessibilityIdentifier("v15.f3d.update.submit")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("v15.f3d.editor")
    }

    private var manualEditor: some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            V15Field("标题", text: $model.title, issues: visibleEditorIssues("title")).accessibilityIdentifier("v15.f3d.editor.title")
            V15Field("计划金额（元）", text: $model.amountText, prompt: "0.00", issues: visibleEditorIssues("planned_amount_minor"), keyboard: .decimal).accessibilityIdentifier("v15.f3d.editor.amount")
            Picker("方向", selection: $model.direction) { ForEach([V15CashFlowDirection.inflow, .outflow, .transfer]) { Text($0.displayName).tag($0) } }.pickerStyle(.segmented).accessibilityIdentifier("v15.f3d.editor.direction")
            V15Field("预计日期", text: $model.expectedDateText, prompt: "YYYY-MM-DD", issues: issues(model.editorIssues, "expected_date")).accessibilityIdentifier("v15.f3d.editor.date")
            accountPickers(source: $model.selectedAccountID, destination: $model.selectedDestinationAccountID, transfer: model.direction == .transfer)
            if model.direction != .transfer { categoryPicker(selection: $model.selectedCategoryID, categories: model.visibleCategories) }
            if case .create = model.editorMode {
                Toggle("每月重复", isOn: $model.recurrenceEnabled).accessibilityIdentifier("v15.f3d.editor.recurrence")
                if model.recurrenceEnabled { V15Field("重复结束日期", text: $model.recurrenceEndDateText, prompt: "YYYY-MM-DD", issues: issues(model.editorIssues, "recurrence_end_date")).accessibilityIdentifier("v15.f3d.editor.recurrence-end") }
            }
            if case .edit = model.editorMode, model.selectedItem?.seriesID != nil {
                Picker("修改范围", selection: $model.mutationScope) { ForEach(V15CashFlowMutationScope.allCases) { Text($0.displayName).tag($0) } }.pickerStyle(.segmented).accessibilityIdentifier("v15.f3d.editor.scope")
                Text("选择“本次及以后”会按原来的月份顺序移动，不改变结束日期或总次数。")
                    .font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("v15.f3d.editor.series-boundary")
            }
            V15Field("备注", text: $model.note, issues: issues(model.editorIssues, "note"), axis: .vertical)
            recoveryActions
        }
    }

    private var settlementEditor: some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            Text("计划金额不会自动成为实际金额；请填写本次真实入账金额。") .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
            V15Field("实际金额（元）", text: $model.settleAmountText, issues: issues(model.settleIssues, "actual_amount_minor"), keyboard: .decimal).accessibilityIdentifier("v15.f3d.settle.amount")
            V15Field("发生日期", text: $model.settleDateText, prompt: "YYYY-MM-DD", issues: issues(model.settleIssues, "occurred_at")).accessibilityIdentifier("v15.f3d.settle.date")
            accountPickers(source: $model.settleAccountID, destination: $model.settleDestinationAccountID, transfer: model.selectedItem?.direction == .transfer)
            if model.selectedItem?.direction != .transfer { categoryPicker(selection: $model.settleCategoryID, categories: model.selectedItem?.direction == .inflow ? model.incomeCategories : model.expenseCategories) }
            V15Field("入账标题", text: $model.settleTitle)
            V15Field("备注", text: $model.settleNote, axis: .vertical)
            V15ActionButton("确认入账", disabledReasons: model.settleReasons) { Task { await model.settle() } }.accessibilityIdentifier("v15.f3d.settle.submit")
            recoveryActions
        }
    }

    private var systemEditor: some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            Text("这里只能修改标题、备注与预计日期。实际到账请回到报销页面登记。") .font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
            V15Field("显示标题", text: $model.title)
            V15Field("预计日期", text: $model.expectedDateText, prompt: "YYYY-MM-DD")
            V15Field("显示备注", text: $model.note, axis: .vertical)
            if let item = model.selectedItem { Text("计划金额：\(money(item.plannedAmountMinor))（不可编辑）").font(V15Typography.money).monospacedDigit() }
            V15ActionButton("保存显示信息", disabledReasons: model.systemUpdateReasons) { Task { await model.updateSystem() } }.accessibilityIdentifier("v15.f3d.system.update")
            recoveryActions
        }
    }

    @ViewBuilder private var editorMessage: some View {
        V15FieldIssues(issues: model.serverIssues).accessibilityIdentifier("v15.f3d.editor.remote-issues")
        mutationBanner
    }

    @ViewBuilder private var mutationBanner: some View {
        if let message = model.factRefreshMessage {
            V15ServiceErrorState(message: message) { Task { await model.retryFactRefresh() } }.accessibilityIdentifier("v15.f3d.fact-refresh")
        } else {
            switch model.mutationPhase {
            case .unknown: V15OutcomeUnknownState(message: model.directReadbackMessage ?? "暂时无法确认操作结果。安全检查不会重复保存。", actionTitle: "安全检查最新状态") { if model.hasUnknownStableAttempt { Task { await model.retryUnknownStable() } } else { Task { await model.readBackUnknownDirect() } } }.accessibilityIdentifier("v15.f3d.unknown")
            case .conflict(let conflict): V15ConflictState(conflict: conflict) { Task { await model.reloadAfterConflict() } }.accessibilityIdentifier("v15.f3d.conflict")
            case .failed(let failure): V15ServiceErrorState(message: failure.message) { if model.hasFactRefreshGate { Task { await model.retryFactRefresh() } } else { Task { await model.refresh() } } }.accessibilityIdentifier("v15.f3d.mutation.error")
            case .succeeded: V15SuccessReceiptState(title: "现金流已更新", detail: "未来安排、历史与详情均已更新。").accessibilityIdentifier("v15.f3d.success")
            case .loading: V15LoadingSkeleton()
            case .idle: EmptyView()
            }
        }
    }

    @ViewBuilder private var recoveryActions: some View {
        if model.hasUnknownStableAttempt {
            HStack(alignment: .top) { V15ActionButton("安全检查保存结果", kind: .secondary, disabledReason: model.isOffline ? .init(code: "offline_read_only", message: "离线时不能检查保存结果。", fieldPath: nil) : nil) { Task { await model.retryUnknownStable() } }.accessibilityIdentifier("v15.f3d.unknown.retry-same-key"); V15ActionButton("停止恢复", kind: .quiet) { model.abandonUnknownStable() }.accessibilityIdentifier("v15.f3d.unknown.abandon-stable") }
        }
        if model.hasUnknownDirectAttempt {
            V15ActionButton("检查最新状态", kind: .secondary) { Task { await model.readBackUnknownDirect() } }.accessibilityIdentifier("v15.f3d.unknown.readback")
            V15ActionButton("核对后继续", kind: .quiet, disabledReason: model.canAbandonUnknownDirect ? nil : .init(code: "fresh_readback_required", message: "请先检查最新状态。", fieldPath: nil)) { model.abandonUnknownDirect() }.accessibilityIdentifier("v15.f3d.unknown.abandon-direct")
        }
    }

    private func accountPickers(source: Binding<UUID?>, destination: Binding<UUID?>, transfer: Bool) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.xs) {
            V15PickerRow(transfer ? "来源账户" : "计划账户", selection: source) { Text("未指定").tag(UUID?.none); ForEach(model.cashAccounts) { Text($0.name).tag(UUID?.some($0.id)) } }
            if transfer { V15PickerRow("目标账户", selection: destination) { Text("请选择").tag(UUID?.none); ForEach(model.cashAccounts) { Text($0.name).tag(UUID?.some($0.id)) } } }
        }
    }
    private func categoryPicker(selection: Binding<UUID?>, categories: [V15CategoryResponse]) -> some View { V15PickerRow("分类", selection: selection) { Text("未分类").tag(UUID?.none); ForEach(categories) { Text($0.name).tag(UUID?.some($0.id)) } } }
    private func issues(_ values: [V15FieldIssue], _ path: String) -> [V15FieldIssue] { values.filter { $0.fieldPath == path || $0.fieldPath?.hasPrefix(path + ".") == true } }
    private func visibleEditorIssues(_ path: String) -> [V15FieldIssue] {
        if path == "title", model.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        if path == "planned_amount_minor", model.amountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        return issues(model.editorIssues, path)
    }
    private func sourceLabel(_ item: V15CashFlowItem) -> String { item.isSystem ? "自动生成" : item.source == "manual" ? "手工" : "其他" }
    private func moneyDirection(_ item: V15CashFlowItem) -> V15MoneyDirection { item.direction == .inflow ? .inflow : item.direction == .outflow ? .outflow : .neutral }
    private func money(_ value: V15MinorUnits) -> String { V15MoneyPresentation(minorUnits: value, direction: .neutral, includeCurrency: true).text }
    private var editorTitle: String { switch model.editorMode { case .create: "新建现金流"; case .edit: "修改现金流"; case .settle: "兑现入账"; case .systemEdit: "系统事项显示"; case .none: "现金流" } }
    private func editOpenReasons(_ item: V15CashFlowItem) -> [V15DisabledReason] { var reasons: [V15DisabledReason] = []; if model.writeLocked { reasons.append(.init(code: "write_locked", message: "上一项操作还没有完成。", fieldPath: nil)) }; if !item.allows(.edit) { reasons.append(.init(code: "server_action_unavailable", message: "当前状态不能修改。", fieldPath: "actions")) }; return reasons }
    private func settleOpenReasons(_ item: V15CashFlowItem) -> [V15DisabledReason] { var reasons: [V15DisabledReason] = []; if model.writeLocked { reasons.append(.init(code: "write_locked", message: "上一项操作还没有完成。", fieldPath: nil)) }; if !item.allows(.settle) { reasons.append(.init(code: "server_action_unavailable", message: "当前状态不能入账。", fieldPath: "actions")) }; return reasons }
    private func systemOpenReasons(_ item: V15CashFlowItem) -> [V15DisabledReason] { var reasons: [V15DisabledReason] = []; if model.writeLocked { reasons.append(.init(code: "write_locked", message: "上一项操作还没有完成。", fieldPath: nil)) }; if item.systemKind == .creditCycle { reasons.append(.init(code: "credit_projection_read_only", message: "信用账单安排只供查看。", fieldPath: "system_kind")) }; if !item.allows(.edit) { reasons.append(.init(code: "server_action_unavailable", message: "当前状态不能修改。", fieldPath: "actions")) }; return reasons }
}
#endif
