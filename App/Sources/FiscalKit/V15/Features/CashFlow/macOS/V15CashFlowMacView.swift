import SwiftUI

#if os(macOS)
public struct V15CashFlowMacView: View {
    @State private var model: V15CashFlowModel
    @State private var section: Section = .active
    private let initialGalleryScenario: String?

    private enum Section: String, CaseIterable { case active, history; var title: String { self == .active ? "未来事项" : "历史" } }

    public init(services: V15Services, offlineSnapshotAt: Date? = nil, initialGalleryScenario: String? = nil) {
        _model = State(initialValue: V15CashFlowModel(services: services, offlineSnapshotAt: offlineSnapshotAt))
        self.initialGalleryScenario = initialGalleryScenario
    }

    public var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 190, idealWidth: 220, maxWidth: 250)
            spine.frame(minWidth: 380, idealWidth: 520, maxWidth: .infinity)
            inspector.frame(minWidth: 320, idealWidth: 390, maxWidth: 460)
        }
        .background(V15Palette.paper.color)
        .task { if model.phase == .idle { await model.load(); await applyInitialScenario() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f3d.cash-flow.macos")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            Text("现金流").font(V15Typography.surfaceTitle).foregroundStyle(V15Palette.ink.color)
            Text("计划与事实分层").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.62))
            ForEach(Section.allCases, id: \.rawValue) { value in
                Button { section = value; Task { await model.setVisibleList(value == .active ? .active : .history) } } label: { HStack { Image(systemName: value == .active ? "calendar.badge.clock" : "clock.arrow.circlepath"); Text(value.title); Spacer() }.padding(.horizontal, V15Spacing.sm).padding(.vertical, V15Spacing.xs).background(section == value ? V15Palette.selected.color : .clear, in: RoundedRectangle(cornerRadius: V15Radius.control)) }
                    .buttonStyle(.plain).v15PlatformHitArea().accessibilityIdentifier("v15.f3d.mac.section.\(value.rawValue)")
            }
            Divider()
            V15PickerRow("账户筛选", selection: Binding(get: { model.accountFilterID }, set: { value in Task { await model.setAccountFilter(value) } })) { Text("全部账户").tag(UUID?.none); ForEach(model.accounts) { Text($0.name).tag(UUID?.some($0.id)) } }
            if section == .history { V15Field("月份", text: Binding(get: { model.historyMonth }, set: { value in Task { await model.setHistoryMonth(value) } }), prompt: "YYYY-MM").accessibilityIdentifier("v15.f3d.mac.history.month") }
            Spacer()
            if let snapshot = model.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: snapshot).accessibilityIdentifier("v15.f3d.mac.offline") }
            V15ActionButton("新建现金流", symbol: "plus", disabledReasons: model.createReasons) { model.openCreate() }.accessibilityIdentifier("v15.f3d.mac.create.open")
            V15ActionButton("刷新", symbol: V15Symbol.retry, kind: .quiet) { Task { await model.refresh() } }.accessibilityIdentifier("v15.f3d.mac.refresh")
        }
        .padding(V15Spacing.md).background(V15Palette.card.color.opacity(0.55))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f3d.mac.sidebar")
    }

    private var spine: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: V15Spacing.md) {
                if section == .active, let summary = model.active?.summary { summaryView(summary) }
                surface
            }
            .padding(V15Spacing.md).frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f3d.mac.spine")
    }

    @ViewBuilder private var surface: some View {
        let phase = section == .active ? model.phase : model.historyPhase
        switch phase {
        case .idle, .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f3d.mac.loading")
        case .empty: V15EmptyState(title: section == .active ? "没有未来现金流" : "本月没有历史", explanation: "服务端没有返回此范围内的事项。", actionTitle: "刷新") { Task { await model.refresh() } }.accessibilityIdentifier("v15.f3d.mac.empty")
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.refresh() } }.accessibilityIdentifier("v15.f3d.mac.error")
        case .loaded:
            let items = section == .active ? model.active?.items ?? [] : model.history?.items ?? []
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    V15LedgerRow(title: item.title, detail: "\(item.expectedDate) · \(item.status.displayName) · \(item.isSystem ? "系统事实" : item.source)", amountMinor: item.plannedAmountMinor, direction: item.direction == .inflow ? .inflow : item.direction == .outflow ? .outflow : .neutral, marker: item.isDisplayOnly || item.status == .expected ? .provisional : .decision) { Task { await model.selectItem(item, from: section == .active ? .active : .history) } }
                        .background(model.selectedItem?.id == item.id ? V15Palette.selected.color : Color.clear)
                        .accessibilityIdentifier("v15.f3d.mac.item.\(item.id)")
                    Divider()
                }
            }
        }
    }

    private func summaryView(_ summary: V15CashFlowSummary) -> some View {
        HStack(spacing: V15Spacing.sm) {
            summaryMetric("流入", summary.inflowMinor, .inflow)
            summaryMetric("流出", summary.outflowMinor, .outflow)
            summaryMetric("净额", summary.netMinor, netDirection(summary.netMinor))
        }
        .accessibilityIdentifier("v15.f3d.mac.summary")
    }
    private func summaryMetric(_ title: String, _ value: V15MinorUnits, _ direction: V15MoneyDirection) -> some View { VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text(title).font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.62)); Text(V15MoneyPresentation(minorUnits: value, direction: direction, includeCurrency: true).text).font(V15Typography.money).monospacedDigit().lineLimit(1) }.padding(V15Spacing.sm).frame(maxWidth: .infinity, alignment: .leading).background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control)) }

    private func netDirection(_ amount: V15MinorUnits) -> V15MoneyDirection {
        amount > 0 ? .inflow : amount < 0 ? .outflow : .neutral
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: V15Spacing.md) {
                if model.editorMode != .none { editorInspector }
                else if let item = model.selectedItem { itemInspector(item) }
                else { V15EmptyState(title: "选择一项现金流", explanation: "检查服务端状态、金额、来源与可用动作。") }
                mutationSurface
            }
            .padding(V15Spacing.md).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(V15Palette.card.color.opacity(0.35))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f3d.mac.inspector")
    }

    private func itemInspector(_ item: V15CashFlowItem) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            HStack(spacing: V15Spacing.xs) {
                Text(item.isSystem ? "系统派生" : "手工计划").font(V15Typography.label)
                    .padding(.horizontal, V15Spacing.xs).padding(.vertical, V15Spacing.xxs)
                    .background(item.isSystem ? V15Palette.provisional.color : V15Palette.selected.color, in: RoundedRectangle(cornerRadius: V15Radius.tag))
                if item.isSystem { Text(sourceLabel(item)).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.62)) }
            }
            Text(item.title).font(V15Typography.cardTitle).foregroundStyle(V15Palette.ink.color).fixedSize(horizontal: false, vertical: true)
            Text("\(item.expectedDate) · \(item.direction.displayName) · \(item.status.displayName) · v\(item.version)").font(V15Typography.secondary)
            HStack(alignment: .top, spacing: V15Spacing.sm) {
                cashFlowFact("计划金额", value: item.plannedAmountMinor, date: item.expectedDate, provisional: true)
                if let actual = item.actualAmountMinor { cashFlowFact("实际入账", value: actual, date: item.actualDate ?? "日期未提供", provisional: false) }
                else { cashFlowUnavailableFact("实际入账", detail: item.isSystem ? "回来源流程确认" : "尚未结算") }
            }.accessibilityIdentifier("v15.f3d.mac.plan-actual")
            if item.isDisplayOnly { Label("未知状态或方向，只读展示", systemImage: V15Symbol.warning).foregroundStyle(V15Palette.teal.color).accessibilityIdentifier("v15.f3d.mac.display-only") }
            if item.isSystem {
                V15Section("系统来源") { Text(item.systemKind == .creditCycle ? "信用账单应还来自真实账期；请到还款流程。" : "报销金额跟随报销事实；实际到账请到报销流程。").font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true) }
                V15ActionButton("修改显示信息", kind: .secondary, disabledReasons: systemOpenReasons(item)) { model.openEdit(item) }.accessibilityIdentifier("v15.f3d.mac.system.edit.open")
            } else {
                V15Section("服务端动作") {
                    V15ActionButton("确认事项", kind: .secondary, disabledReasons: model.actionReasons(.confirm, for: item)) { Task { await model.perform(.confirm, on: item) } }.accessibilityIdentifier("v15.f3d.mac.confirm")
                    V15ActionButton("兑现入账", disabledReasons: settleOpenReasons(item)) { model.openSettle(item) }.accessibilityIdentifier("v15.f3d.mac.settle.open")
                    V15ActionButton("修改事项", kind: .quiet, disabledReasons: editOpenReasons(item)) { model.openEdit(item) }.accessibilityIdentifier("v15.f3d.mac.edit.open")
                    if item.seriesID != nil { Picker("取消范围", selection: $model.mutationScope) { ForEach(V15CashFlowMutationScope.allCases) { Text($0.displayName).tag($0) } }.pickerStyle(.segmented).accessibilityIdentifier("v15.f3d.mac.cancel.scope") }
                    V15ActionButton("取消事项", kind: .destructive, disabledReasons: model.actionReasons(.cancel, for: item)) { Task { await model.perform(.cancel, on: item) } }.accessibilityIdentifier("v15.f3d.mac.cancel")
                }
            }
            if !item.creditCycleParts.isEmpty { V15Section("服务端账期构成") { ForEach(item.creditCycleParts) { part in Text("\(part.periodStart)–\(part.periodEnd) · \(money(part.remainingMinor))").font(V15Typography.secondary) } } }
        }
    }

    private var editorInspector: some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            HStack { Text(editorTitle).font(V15Typography.cardTitle); Spacer(); Button("关闭") { model.dismissEditor() }.accessibilityIdentifier("v15.f3d.mac.editor.close") }
            V15FieldIssues(issues: model.serverIssues)
            switch model.editorMode {
            case .create, .edit:
                V15Field("标题", text: $model.title, issues: fieldIssues(model.editorIssues, "title")); V15Field("计划金额（元）", text: $model.amountText, issues: fieldIssues(model.editorIssues, "planned_amount_minor")); Picker("方向", selection: $model.direction) { ForEach([V15CashFlowDirection.inflow, .outflow, .transfer]) { Text($0.displayName).tag($0) } }.pickerStyle(.segmented)
                V15Field("预计日期", text: $model.expectedDateText, prompt: "YYYY-MM-DD"); accountControls(source: $model.selectedAccountID, destination: $model.selectedDestinationAccountID, transfer: model.direction == .transfer)
                if model.direction != .transfer { categoryControl(selection: $model.selectedCategoryID, categories: model.visibleCategories) }
                if case .create = model.editorMode {
                    Toggle("每月重复", isOn: $model.recurrenceEnabled)
                    if model.recurrenceEnabled { V15Field("重复结束日期", text: $model.recurrenceEndDateText, prompt: "YYYY-MM-DD") }
                }
                if case .edit = model.editorMode, model.selectedItem?.seriesID != nil {
                    Picker("修改范围", selection: $model.mutationScope) { ForEach(V15CashFlowMutationScope.allCases) { Text($0.displayName).tag($0) } }.pickerStyle(.segmented).accessibilityIdentifier("v15.f3d.mac.editor.scope")
                    Text("重复边界由服务端原系列保留；“本次及以后”只按原月序移动，不修改结束日期或系列长度。")
                        .font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("v15.f3d.mac.editor.series-boundary")
                }
                V15Field("备注", text: $model.note, axis: .vertical)
                if case .create = model.editorMode { V15ActionButton("创建", disabledReasons: model.createReasons) { Task { await model.create() } }.accessibilityIdentifier("v15.f3d.mac.create.submit") }
                else { V15ActionButton("保存修改", disabledReasons: model.updateReasons) { Task { await model.update() } }.accessibilityIdentifier("v15.f3d.mac.update.submit") }
            case .settle:
                Text("填写真实发生金额与日期；计划值不会自动当作已入账事实。") .font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
                V15Field("实际金额（元）", text: $model.settleAmountText, issues: fieldIssues(model.settleIssues, "actual_amount_minor")); V15Field("发生日期", text: $model.settleDateText, prompt: "YYYY-MM-DD"); accountControls(source: $model.settleAccountID, destination: $model.settleDestinationAccountID, transfer: model.selectedItem?.direction == .transfer)
                if model.selectedItem?.direction != .transfer { categoryControl(selection: $model.settleCategoryID, categories: model.selectedItem?.direction == .inflow ? model.incomeCategories : model.expenseCategories) }
                V15Field("入账标题", text: $model.settleTitle); V15Field("备注", text: $model.settleNote, axis: .vertical)
                V15ActionButton("确认入账", disabledReasons: model.settleReasons) { Task { await model.settle() } }.accessibilityIdentifier("v15.f3d.mac.settle.submit")
            case .systemEdit:
                Text("计划金额恒等于当前服务端报销事实；这里只改标题、备注与预计日期。") .font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
                V15Field("显示标题", text: $model.title); V15Field("预计日期", text: $model.expectedDateText, prompt: "YYYY-MM-DD"); V15Field("显示备注", text: $model.note, axis: .vertical)
                if let item = model.selectedItem { Text("事实金额 \(money(item.plannedAmountMinor))（不可编辑）").font(V15Typography.money).monospacedDigit() }
                V15ActionButton("保存显示信息", disabledReasons: model.systemUpdateReasons) { Task { await model.updateSystem() } }.accessibilityIdentifier("v15.f3d.mac.system.update")
            case .none: EmptyView()
            }
            recoveryActions
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f3d.mac.editor")
    }

    @ViewBuilder private var mutationSurface: some View {
        if let message = model.factRefreshMessage { V15ServiceErrorState(message: message) { Task { await model.retryFactRefresh() } }.accessibilityIdentifier("v15.f3d.mac.fact-refresh") }
        else { switch model.mutationPhase { case .idle: EmptyView(); case .loading: V15LoadingSkeleton(); case .unknown: V15ServiceErrorState(message: model.directReadbackMessage ?? "请求结果未知；不会换键或重发无键命令。") { if model.hasUnknownStableAttempt { Task { await model.retryUnknownStable() } } else { Task { await model.readBackUnknownDirect() } } }.accessibilityIdentifier("v15.f3d.mac.unknown"); case .conflict(let conflict): V15ConflictState(conflict: conflict) { Task { await model.reloadAfterConflict() } }.accessibilityIdentifier("v15.f3d.mac.conflict"); case .failed(let failure): V15ServiceErrorState(message: failure.message) { if model.hasFactRefreshGate { Task { await model.retryFactRefresh() } } else { Task { await model.refresh() } } }; case .succeeded: V15SuccessReceiptState(title: "事实已更新", detail: "服务端 active、history 与详情已重新读取。").accessibilityIdentifier("v15.f3d.mac.success") } }
    }

    @ViewBuilder private var recoveryActions: some View {
        if model.hasUnknownStableAttempt { V15ActionButton("同一请求键重试", kind: .secondary, disabledReason: model.isOffline ? .init(code: "offline_read_only", message: "离线不能重试写入。", fieldPath: nil) : nil) { Task { await model.retryUnknownStable() } }.accessibilityIdentifier("v15.f3d.mac.unknown.retry-same-key"); V15ActionButton("放弃恢复", kind: .quiet) { model.abandonUnknownStable() } }
        if model.hasUnknownDirectAttempt { V15ActionButton("只读取最新事实", kind: .secondary) { Task { await model.readBackUnknownDirect() } }.accessibilityIdentifier("v15.f3d.mac.unknown.readback"); V15ActionButton("按最新事实解除写入锁", kind: .quiet, disabledReason: model.canAbandonUnknownDirect ? nil : .init(code: "fresh_readback_required", message: "请先完成 fresh GET。", fieldPath: nil)) { model.abandonUnknownDirect() }.accessibilityIdentifier("v15.f3d.mac.unknown.abandon") }
    }

    private func accountControls(source: Binding<UUID?>, destination: Binding<UUID?>, transfer: Bool) -> some View { VStack(alignment: .leading) { V15PickerRow(transfer ? "来源账户" : "计划账户", selection: source) { Text("未指定").tag(UUID?.none); ForEach(model.cashAccounts) { Text($0.name).tag(UUID?.some($0.id)) } }; if transfer { V15PickerRow("目标账户", selection: destination) { Text("请选择").tag(UUID?.none); ForEach(model.cashAccounts) { Text($0.name).tag(UUID?.some($0.id)) } } } } }
    private func categoryControl(selection: Binding<UUID?>, categories: [V15CategoryResponse]) -> some View { V15PickerRow("分类", selection: selection) { Text("未分类").tag(UUID?.none); ForEach(categories) { Text($0.name).tag(UUID?.some($0.id)) } } }
    private func fieldIssues(_ values: [V15FieldIssue], _ path: String) -> [V15FieldIssue] { values.filter { $0.fieldPath == path || $0.fieldPath?.hasPrefix(path + ".") == true } }
    private func money(_ value: V15MinorUnits) -> String { V15MoneyPresentation(minorUnits: value, direction: .neutral, includeCurrency: true).text }
    private func sourceLabel(_ item: V15CashFlowItem) -> String { item.systemKind == .creditCycle ? "由信用周期派生" : item.systemKind == .reimbursement ? "由报销事实派生" : item.source }
    private func cashFlowFact(_ title: String, value: V15MinorUnits, date: String, provisional: Bool) -> some View { VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text(title).font(V15Typography.label); V15MoneyText(minorUnits: value, direction: .neutral, font: V15Typography.body.weight(.semibold)); Text(date).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.62)) }.padding(V15Spacing.sm).frame(maxWidth: .infinity, alignment: .leading).background(provisional ? V15Palette.provisional.color : V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control)) }
    private func cashFlowUnavailableFact(_ title: String, detail: String) -> some View { VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text(title).font(V15Typography.label); Text("—").font(V15Typography.body.weight(.semibold)); Text(detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.62)) }.padding(V15Spacing.sm).frame(maxWidth: .infinity, alignment: .leading).background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control)) }
    private var editorTitle: String { switch model.editorMode { case .create: "新建现金流"; case .edit: "修改现金流"; case .settle: "兑现入账"; case .systemEdit: "系统事项显示"; case .none: "检查器" } }
    private func editOpenReasons(_ item: V15CashFlowItem) -> [V15DisabledReason] { var values: [V15DisabledReason] = []; if model.writeLocked { values.append(.init(code: "write_locked", message: "当前有未完成写入或事实刷新。", fieldPath: nil)) }; if !item.allows(.edit) { values.append(.init(code: "server_action_unavailable", message: "服务端未允许修改。", fieldPath: "actions")) }; return values }
    private func settleOpenReasons(_ item: V15CashFlowItem) -> [V15DisabledReason] { var values: [V15DisabledReason] = []; if model.writeLocked { values.append(.init(code: "write_locked", message: "当前有未完成写入或事实刷新。", fieldPath: nil)) }; if !item.allows(.settle) { values.append(.init(code: "server_action_unavailable", message: "服务端未允许入账。", fieldPath: "actions")) }; return values }
    private func systemOpenReasons(_ item: V15CashFlowItem) -> [V15DisabledReason] { var values: [V15DisabledReason] = []; if model.writeLocked { values.append(.init(code: "write_locked", message: "当前有未完成写入或事实刷新。", fieldPath: nil)) }; if item.systemKind == .creditCycle { values.append(.init(code: "credit_projection_read_only", message: "信用账单投影只读。", fieldPath: "system_kind")) }; if !item.allows(.edit) { values.append(.init(code: "server_action_unavailable", message: "服务端未允许修改。", fieldPath: "actions")) }; return values }

    private func applyInitialScenario() async {
        guard let scenario = initialGalleryScenario else { return }
        if scenario.contains("history") { section = .history; await model.setVisibleList(.history); if let item = model.history?.items.first { await model.selectItem(item, from: .history) } }
        else if let item = model.active?.items.first { await model.selectItem(item) }
        if scenario.contains("conflict"), let item = model.active?.items.first {
            await model.selectItem(item); model.openEdit(item); model.title = "冲突中的现金流修改"; await model.update()
        }
        else if scenario.contains("unknown"), let item = model.active?.items.first(where: { $0.id == V15F3DFixtures.transferID.uuidString }) {
            await model.selectItem(item); model.openSettle(item); await model.settle()
        }
        else if scenario.contains("partial-refresh") {
            model.openCreate(); model.title = "新建现金流"; model.amountText = "123.45"; model.expectedDateText = "2026-08-28"; await model.create()
        }
        else if scenario.contains("create") { model.openCreate(); model.title = "新建现金流"; model.amountText = scenario.contains("invalid") ? "12.345" : "123.45"; model.expectedDateText = "2026-08-28" }
        else if scenario.contains("settle"), let item = model.active?.items.first(where: { $0.id == V15F3DFixtures.transferID.uuidString }) { await model.selectItem(item); model.openSettle(item) }
        else if scenario.contains("system"), let item = model.active?.items.first(where: { $0.systemKind == .reimbursement }) { await model.selectItem(item); model.openEdit(item) }
        else if scenario.contains("edit"), let item = model.active?.items.first { await model.selectItem(item); model.openEdit(item); model.mutationScope = .thisAndFuture }
    }
}
#endif
