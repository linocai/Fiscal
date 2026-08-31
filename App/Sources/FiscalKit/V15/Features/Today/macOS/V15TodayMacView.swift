import SwiftUI

#if os(macOS)

/// macOS Today is an information hierarchy, not a collection of endpoint
/// tabs.  The sidebar changes the current facts lens; all detail still goes
/// through the one F2-A read model and its revision gate.
public struct V15TodayMacView: View {
    private enum Lens: String, CaseIterable, Identifiable { case today, cashAccounts, creditCycles, reimbursements, completeness
        var id: String { rawValue }
        var title: String { switch self { case .today: "Today 焦点"; case .cashAccounts: "现金账户"; case .creditCycles: "信用账期"; case .reimbursements: "报销待回款"; case .completeness: "完整性" } }
        var scopeType: String? { self == .today ? nil : rawValue == "cashAccounts" ? "cash_accounts" : rawValue == "creditCycles" ? "credit_cycles" : rawValue == "reimbursements" ? "reimbursement_outstanding" : "completeness_issues" }
    }
    private enum Selection: Hashable { case attention(String), future(String), scopeItem(Int), lens(Lens), none }

    @State private var model: V15TodayReadModel
    @State private var lens: Lens = .today
    @State private var selection: Selection = .none
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let initialScopeType: String?

    public init(services: V15Services, offlineSnapshotAt: Date? = nil, initialScopeType: String? = nil) {
        _model = State(initialValue: V15TodayReadModel(services: services, offlineSnapshotProvider: { offlineSnapshotAt ?? services.offlineSnapshotAt }))
        self.initialScopeType = initialScopeType
    }

    public var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 900 || dynamicTypeSize.isAccessibilitySize
            HStack(spacing: 0) {
                indexPane.frame(width: compact ? 176 : 210)
                Divider()
                spinePane.frame(minWidth: compact ? 300 : 340, idealWidth: 480, maxWidth: .infinity)
                Divider()
                inspectorPane.frame(width: compact ? 270 : 310)
            }
            .background(V15Palette.paper.color)
        }
        .frame(minWidth: 720, minHeight: 540)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f2c.today.macos")
        .task {
            await model.refresh()
            if let initialScopeType { await model.openScope(type: initialScopeType); lens = .cashAccounts; selection = .lens(.cashAccounts) }
        }
    }

    private var indexPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: V15Spacing.sm) {
                Text("TODAY").font(V15Typography.label).foregroundStyle(V15Palette.teal.color)
                Text("今日概览").font(V15Typography.cardTitle).foregroundStyle(V15Palette.ink.color)
                if let facts = model.facts { Text("截至 \(V15TodayReadModel.shanghaiDateLabel(facts.meta.asOf))\n人民币 · 上海时区").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true) }
                if let offline = model.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: model.offlineAsOf ?? offline).accessibilityIdentifier("v15.f2c.offline") }
                Divider()
                ForEach(Lens.allCases) { item in
                    Button { chooseLens(item) } label: {
                        HStack { Image(systemName: item == .today ? "sun.max" : "square.grid.2x2").accessibilityHidden(true); Text(item.title); Spacer(); if lens == item { Image(systemName: "checkmark").accessibilityHidden(true) } }
                            .font(V15Typography.secondary.weight(lens == item ? .semibold : .regular)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, V15Spacing.xs)
                    }
                    .buttonStyle(.plain).padding(.horizontal, V15Spacing.xs).background(lens == item ? V15Palette.selected.color : .clear, in: RoundedRectangle(cornerRadius: V15Radius.control))
                    .accessibilityIdentifier("v15.f2c.lens.\(item.scopeType ?? "today")")
                    .accessibilityHint(item == .today ? "显示需要处理的事项和未来安排。" : "打开只读明细。")
                    .keyboardShortcut(keyEquivalent(for: item), modifiers: .command)
                }
                Spacer(minLength: V15Spacing.lg)
                V15ActionButton("重新读取", symbol: V15Symbol.retry, kind: .secondary, disabledReason: model.requiresFactsReload ? nil : nil) { Task { await refreshCurrentLens() } }
                    .accessibilityIdentifier("v15.f2c.refresh")
                    .keyboardShortcut("r", modifiers: .command)
            }.padding(V15Spacing.md)
        }
    }

    @ViewBuilder private var spinePane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: V15Spacing.md) {
                switch model.factsPhase {
                case .idle, .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f2c.facts.loading")
                case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await refreshCurrentLens() } }.accessibilityIdentifier("v15.f2c.facts.error")
                case .requiresReload(let failure): reloadGate(failure).accessibilityIdentifier("v15.f2c.facts.conflict")
                case .loaded: contentSpine
                }
            }.padding(V15Spacing.md)
        }
        .accessibilityIdentifier("v15.f2c.spine")
    }

    @ViewBuilder private var contentSpine: some View {
        if lens == .today {
            V15Section("需要你决定", detail: "按严重程度与日期") {
                switch model.attentionPhase {
                case .idle, .loading: V15LoadingSkeleton()
                case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.refreshAttention() } }.accessibilityIdentifier("v15.f2c.attention.error")
                case .loaded:
                    let items = model.attention.sorted(by: attentionOrder)
                    if items.isEmpty { V15EmptyState(title: "目前没有需要你决定的事项", explanation: "这只表示待办列表为空，不代表没有财务数据。") }
                    else { ForEach(items) { attentionRow($0) } }
                }
            }
            if let facts = model.facts {
                V15Section("未来安排", detail: "已确认事项") {
                    if facts.knownFutureEvents.isEmpty { Text("当前窗口没有已知未来事项。它不代表未来没有变化。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }
                    else { ForEach(facts.knownFutureEvents) { futureRow($0) } }
                }
                V15TodayMacFutureTotals(future: facts.future)
                V15Section("统计范围", detail: "上海业务日 · CNY") {
                    Text("\(facts.window.dateFrom) 至 \(facts.window.dateTo)").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else { scopeSpine }
    }

    private func attentionRow(_ item: V15AttentionItem) -> some View {
        let presentation = attentionPresentation(item)
        return Button { selection = .attention(item.id); Task { await model.openAttention(item) } } label: {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: V15Spacing.xs) {
                        HStack(alignment: .top, spacing: V15Spacing.sm) { Image(systemName: presentation.symbol).foregroundStyle(presentation.color).frame(width: 22).accessibilityHidden(true); VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text(presentation.label).font(V15Typography.label).foregroundStyle(presentation.color); Text(V15AttentionUserCopy.explanation(for: item)).font(V15Typography.body).foregroundStyle(V15Palette.ink.color).fixedSize(horizontal: false, vertical: true); Text(V15AttentionUserCopy.suggestedAction(for: item)).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true) } }
                        if let amount = item.amountMinor { HStack { Spacer(); V15MoneyText(minorUnits: amount, direction: .neutral, font: V15Typography.secondary) } }
                    }
                } else {
                    VStack(alignment: .leading, spacing: V15Spacing.xs) {
                        HStack(alignment: .top, spacing: V15Spacing.sm) {
                            Image(systemName: presentation.symbol).foregroundStyle(presentation.color).frame(width: 22).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                                Text(presentation.label).font(V15Typography.label).foregroundStyle(presentation.color)
                                Text(V15AttentionUserCopy.explanation(for: item)).font(V15Typography.body).foregroundStyle(V15Palette.ink.color).fixedSize(horizontal: false, vertical: true)
                                Text(V15AttentionUserCopy.suggestedAction(for: item)).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if let amount = item.amountMinor { HStack { Spacer(); V15MoneyText(minorUnits: amount, direction: .neutral, font: V15Typography.secondary) } }
                    }
                }
            }.padding(V15Spacing.sm).frame(maxWidth: .infinity, alignment: .leading).background(selection == .attention(item.id) ? V15Palette.selected.color : V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
        }.buttonStyle(.plain).v15PlatformHitArea().accessibilityIdentifier("v15.f2c.attention.\(item.id)").accessibilityLabel("\(presentation.label)，\(V15AttentionUserCopy.explanation(for: item))，\(V15AttentionUserCopy.suggestedAction(for: item))")
    }

    private func futureRow(_ item: V15FutureEvent) -> some View {
        Button { selection = .future(item.id); Task { await model.openLinkedRead(item.deepLink) } } label: {
            HStack(alignment: .firstTextBaseline) { VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text(item.date).font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.66)); Text(item.title).font(V15Typography.body).foregroundStyle(V15Palette.ink.color); Text(certaintyLabel(item.certainty.rawValue)).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }; Spacer(); V15MoneyText(minorUnits: item.amountMinor, direction: item.direction == .inflow ? .inflow : .outflow, font: V15Typography.secondary) }
                .padding(V15Spacing.sm).frame(maxWidth: .infinity, alignment: .leading).background(selection == .future(item.id) ? V15Palette.selected.color : V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
        }.buttonStyle(.plain).v15PlatformHitArea().accessibilityIdentifier("v15.f2c.future.\(item.id)")
    }

    @ViewBuilder private var scopeSpine: some View {
        V15Section(lens.title, detail: "只读明细") {
            switch model.scopePhase {
            case .idle: V15EmptyState(title: "选择一个范围", explanation: "从左侧选择要查看的内容。")
                .accessibilityIdentifier("v15.f2c.scope.idle")
            case .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f2c.scope.loading")
            case .empty: V15EmptyState(title: "这个范围目前为空", explanation: "这不代表其他财务数据为空。").accessibilityIdentifier("v15.f2c.scope.empty")
            case .failed(let failure): V15ServiceErrorState(message: failure.message) { openCurrentLens() }.accessibilityIdentifier("v15.f2c.scope.error")
            case .requiresFactsReload(let failure): reloadGate(failure).accessibilityIdentifier("v15.f2c.scope.conflict")
            case .loaded:
                ForEach(Array(model.scopeItems.enumerated()), id: \.offset) { index, item in scopeRow(item, index: index) }
                if model.hasNextPage { V15ActionButton("读取下一页", kind: .secondary, disabledReason: model.isLoadingNextPage ? .init(code: "loading_next_page", message: "正在读取下一页。", fieldPath: nil) : nil) { Task { await model.loadNextPage() } }.accessibilityIdentifier("v15.f2c.scope.next").keyboardShortcut(.downArrow, modifiers: [.command, .option]) }
                if let failure = model.nextPageFailure { V15ServiceErrorState(message: failure.message) { Task { await model.loadNextPage() } }.accessibilityIdentifier("v15.f2c.scope.page.error") }
            }
        }
        .accessibilityIdentifier("v15.f2c.scope.title.\(lens.scopeType ?? "today")")
    }

    private func scopeRow(_ item: V15FactDrillDownItem, index: Int) -> some View {
        let summary = scopeSummary(item)
        let scopeType = model.selectedScope?.scopeType ?? "unknown"
        return Button { selection = .scopeItem(index); Task { await model.openFactItem(item) } } label: {
            HStack { VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text(summary.title).font(V15Typography.body).foregroundStyle(V15Palette.ink.color); Text(summary.detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true) }; Spacer(); if let amount = summary.amount { V15MoneyText(minorUnits: amount.0, direction: amount.1, font: V15Typography.secondary) } }
                .padding(V15Spacing.sm).frame(maxWidth: .infinity, alignment: .leading).background(selection == .scopeItem(index) ? V15Palette.selected.color : V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
        }.buttonStyle(.plain).v15PlatformHitArea().accessibilityIdentifier("v15.f2c.scope.row.\(scopeType).\(index)")
    }

    private var inspectorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: V15Spacing.md) {
                HStack { Text("详情").font(V15Typography.cardTitle).foregroundStyle(V15Palette.ink.color); Spacer(); Button("关闭") { selection = .none; model.closeLinkedRead() }.buttonStyle(.borderless).accessibilityIdentifier("v15.f2c.inspector.close") }
                inspectorContent
                Divider()
                Text("只读说明").font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.66))
                Text("当前仅供查看，不会提交或忽略任何事项。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
            }.padding(V15Spacing.md)
        }.accessibilityIdentifier("v15.f2c.inspector")
    }

    @ViewBuilder private var inspectorContent: some View {
        switch model.linkedReadPhase {
        case .idle: V15EmptyState(title: "选择一项", explanation: "从列表选择后，在这里显示只读详情。")
        case .loading: V15LoadingSkeleton()
        case .requiresFactsReload(let failure): reloadGate(failure).accessibilityIdentifier("v15.f2c.inspector.conflict")
        case .localFactsInspector(let label): V15Section("当前范围") { Text(label).font(V15Typography.body); Text("当前仅供查看。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }
        case .account(let account): V15Section("账户详情") { Text(account.name).font(V15Typography.body); Text("当前仅供查看。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }
        case .transaction(let transaction): V15Section("账目详情") { Text(transaction.title).font(V15Typography.body); V15MoneyText(minorUnits: transaction.amountMinor, direction: transaction.amountMinor < 0 ? .outflow : .inflow); Text("业务日（上海）：\(transaction.businessDate)").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }
        case .unavailable(let reason): V15EmptyState(title: "当前不能打开该目标", explanation: reason).accessibilityIdentifier("v15.f2c.inspector.unavailable")
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.retryLinkedRead() } }.accessibilityIdentifier("v15.f2c.inspector.error")
        }
    }

    private func chooseLens(_ item: Lens) { lens = item; selection = .lens(item); if item == .today { model.closeScopeInspector() } else { openCurrentLens() } }
    private func openCurrentLens() { if let type = lens.scopeType { Task { await model.openScope(type: type) } } }
    /// Facts refresh invalidates every revision-bound cursor and scope. Read
    /// the lens only after that await: a user may have switched panes while a
    /// refresh was in flight, and only the then-current scope may reopen.
    private func refreshCurrentLens() async {
        await model.refresh()
        guard !model.requiresFactsReload else { return }
        guard case .loaded = model.factsPhase else { return }
        guard let type = V15TodayMacRefreshPolicy.scopeTypeToReopen(currentScopeType: lens.scopeType) else { return }
        await model.openScope(type: type)
    }
    private func scopeSummary(_ item: V15FactDrillDownItem) -> (title: String, detail: String, amount: (Int64, V15MoneyDirection)?) {
        switch item {
        case .cashAccount(let value): return (value.name, value.lastReconciledAt.map { "最近核对 \(V15TodayReadModel.shanghaiDateLabel($0))" } ?? "尚无核对时间", (value.currentBalanceMinor, .balance))
        case .creditCycle(let value): return (value.accountName, "到期 \(value.dueDate)", (value.remainingMinor, .outflow))
        case .reimbursementOutstanding(let value): return (value.partyName, value.expectedDate.map { "预计 \($0)" } ?? "尚未提供预计日期", (value.outstandingMinor, .inflow))
        case .completenessIssue(let value): return ("完整性：\(String(describing: value.issueType))", "\(value.count) 项", value.amountMinor.map { ($0, .neutral) })
        case .unknown: return ("暂时无法识别的条目", "当前仅可查看。", nil)
        }
    }

    private func attentionPresentation(_ item: V15AttentionItem) -> (label: String, symbol: String, color: Color) {
        switch item.severity {
        case .critical: ("紧急", "exclamationmark.octagon.fill", V15Palette.gold.color)
        case .warning: ("需要留意", "exclamationmark.triangle.fill", V15Palette.gold.color)
        case .info: ("提示", "info.circle", V15Palette.teal.color)
        }
    }
    private func attentionOrder(_ lhs: V15AttentionItem, _ rhs: V15AttentionItem) -> Bool {
        let rank: (V15AttentionSeverity) -> Int = { switch $0 { case .critical: 0; case .warning: 1; case .info: 2 } }
        if rank(lhs.severity) != rank(rhs.severity) { return rank(lhs.severity) < rank(rhs.severity) }
        switch (lhs.occurredAt, rhs.occurredAt) { case let (left?, right?) where left != right: return left < right; case (_?, nil): return true; case (nil, _?): return false; default: return lhs.id < rhs.id }
    }
    private func certaintyLabel(_ value: String) -> String {
        switch value { case "exact_due": "到期日已确认"; case "confirmed": "已确认"; case "expected": "预计"; case "scheduled": "已排期"; default: "状态待确认 · 仅供查看" }
    }
    private func keyEquivalent(for item: Lens) -> KeyEquivalent {
        switch item { case .today: "0"; case .cashAccounts: "1"; case .creditCycles: "2"; case .reimbursements: "3"; case .completeness: "4" }
    }
    private func reloadGate(_ failure: V15Failure) -> some View {
        V15Section("数据已更新") {
            Text("\(failure.message) 需取得最新数据后才能继续。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
            V15ActionButton("取最新数据重新决定", symbol: V15Symbol.conflict) { Task { await refreshCurrentLens() } }
        }
    }
}

/// A refresh may resume after a different sidebar choice.  This policy keeps
/// that ownership explicit and makes Today a deliberate no-reopen state.
enum V15TodayMacRefreshPolicy {
    static func scopeTypeToReopen(currentScopeType: String?) -> String? {
        switch currentScopeType {
        case "cash_accounts", "credit_cycles", "reimbursement_outstanding", "completeness_issues": currentScopeType
        default: nil
        }
    }
}

/// F2 surfaces only the compact future totals included by `reports/facts`.
/// It does not derive a forecast or request the F3 future-events timeline.
private struct V15TodayMacFutureTotals: View {
    let future: V15Facts.FutureTotals

    var body: some View {
        V15Section("未来安排", detail: "不计入当前现金") {
            if isZero {
                Text("目前没有会影响现金的未来安排。")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    .accessibilityIdentifier("v15.f2c.future-totals.zero")
            }
            totalRow("确切到期流出", amount: future.exactDueOutflowMinor, direction: .outflow)
            totalPair("已确认", outflow: future.confirmedOutflowMinor, inflow: future.confirmedInflowMinor)
            totalPair("预计", outflow: future.expectedOutflowMinor, inflow: future.expectedInflowMinor)
            totalPair("已安排", outflow: future.scheduledOutflowMinor, inflow: future.scheduledInflowMinor)
            totalRow("预计变动后现金", amount: future.afterConfirmedOutflowMinor, direction: .balance)
        }
        .accessibilityIdentifier("v15.f2c.future-totals")
    }

    private var isZero: Bool {
        [future.exactDueOutflowMinor, future.confirmedOutflowMinor, future.expectedOutflowMinor,
         future.scheduledOutflowMinor, future.confirmedInflowMinor, future.expectedInflowMinor,
         future.scheduledInflowMinor, future.afterConfirmedOutflowMinor].allSatisfy { $0 == 0 }
    }

    private func totalRow(_ title: String, amount: V15MinorUnits, direction: V15MoneyDirection) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.xxs) {
            Text(title).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.72))
            HStack { Spacer(minLength: V15Spacing.xs); V15MoneyText(minorUnits: amount, direction: direction, font: V15Typography.secondary).lineLimit(1).minimumScaleFactor(0.72) }
        }
        .padding(V15Spacing.sm)
        .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
        .accessibilityElement(children: .combine)
    }

    private func totalPair(_ title: String, outflow: V15MinorUnits, inflow: V15MinorUnits) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.xxs) {
            Text(title).font(V15Typography.secondary.weight(.semibold)).foregroundStyle(V15Palette.ink.color.opacity(0.72))
            totalAmount("流出", amount: outflow, direction: .outflow)
            totalAmount("流入", amount: inflow, direction: .inflow)
        }
        .padding(V15Spacing.sm)
        .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
        .accessibilityElement(children: .combine)
    }

    private func totalAmount(_ label: String, amount: V15MinorUnits, direction: V15MoneyDirection) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: V15Spacing.sm) {
            Text(label).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
            Spacer(minLength: V15Spacing.xs)
            V15MoneyText(minorUnits: amount, direction: direction, font: V15Typography.secondary).lineLimit(1).minimumScaleFactor(0.72)
        }
    }
}

#endif
