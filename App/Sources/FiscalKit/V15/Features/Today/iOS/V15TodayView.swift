import SwiftUI

#if os(iOS)

/// iOS is a calm decision surface: it reads the one server facts snapshot and
/// only opens revision-bound, read-only detail.  It intentionally has no
/// endpoint-family navigation, mutation controls, or future timeline.
public struct V15TodayView: View {
    @State private var model: V15TodayReadModel
    @State private var scopePresented = false
    @State private var detailPresented = false
    @State private var scopeDetailPresented = false

    public init(services: V15Services, offlineSnapshotAt: Date? = nil) {
        _model = State(initialValue: V15TodayReadModel(services: services, offlineSnapshotProvider: { offlineSnapshotAt ?? services.offlineSnapshotAt }))
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.section) {
                    V15TodayHeader(model: model)
                    if let snapshotAt = model.offlineSnapshotAt {
                        V15TodayOfflineStatus(factsAsOf: model.offlineAsOf, fallbackSnapshotAt: snapshotAt)
                            .accessibilityIdentifier("v15.f2b.offline")
                    }
                    factsSurface
                }
                .padding(V15Spacing.md)
                .frame(maxWidth: 680, alignment: .leading)
            }
            .background(V15Palette.paper.color)
            .navigationTitle("今日")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await model.refresh() } } label: { Label("重新读取", systemImage: V15Symbol.retry) }
                        .accessibilityIdentifier("v15.f2b.refresh")
                        .accessibilityHint("只重新读取服务器当前事实。")
                }
            }
        }
        .sheet(isPresented: $scopePresented, onDismiss: { model.closeScopeInspector() }) {
            V15TodayScopeSheet(model: model, detailPresented: $scopeDetailPresented, dismissScope: { scopePresented = false })
                .presentationDetents([.medium, .large])
                .accessibilityIdentifier("v15.f2b.scope.sheet")
        }
        .sheet(isPresented: $detailPresented, onDismiss: { model.closeLinkedRead() }) {
            V15TodayReadOnlyInspector(model: model, close: { detailPresented = false })
                .presentationDetents([.medium, .large])
                .accessibilityIdentifier("v15.f2b.readonly.sheet")
        }
        .accessibilityIdentifier("v15.f2b.today.ios")
        .task { await model.refresh() }
    }

    @ViewBuilder private var factsSurface: some View {
        switch model.factsPhase {
        case .idle, .loading:
            V15LoadingSkeleton().accessibilityIdentifier("v15.f2b.facts.loading")
        case .failed(let failure):
            V15ServiceErrorState(message: failure.message, retry: { Task { await model.refresh() } })
                .accessibilityIdentifier("v15.f2b.facts.error")
        case .requiresReload(let failure):
            V15TodayReloadRequired(failure: failure, reload: { Task { await model.refresh() } })
                .accessibilityIdentifier("v15.f2b.facts.conflict")
        case .loaded:
            if let facts = model.facts {
                V15TodayAttentionQueue(model: model, open: openAttention)
                V15TodayFutureTotals(future: facts.future)
                V15TodayKnownFuture(events: facts.knownFutureEvents)
                V15TodayFactsCards(facts: facts, open: openScope)
            }
        }
    }

    private func openScope(_ scope: V15DrillDownScope?) {
        guard let scope else { return }
        scopePresented = true
        Task { await model.openScope(scope) }
    }

    private func openAttention(_ item: V15AttentionItem) {
        detailPresented = true
        Task { await model.openAttention(item) }
    }
}

private struct V15TodayHeader: View {
    let model: V15TodayReadModel
    var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.xs) {
            Text("当前事实")
                .font(V15Typography.label)
                .foregroundStyle(V15Palette.teal.color)
            if let facts = model.facts {
                Text("截至 \(V15TodayReadModel.shanghaiDateLabel(facts.meta.asOf))")
                    .font(V15Typography.surfaceTitle)
                    .foregroundStyle(V15Palette.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                Text("近 \(facts.window.dateFrom) 至 \(facts.window.dateTo) · \(facts.meta.currency) · 数据版本 \(facts.meta.dataRevision)")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("正在取得当前事实")
                    .font(V15Typography.surfaceTitle)
                    .foregroundStyle(V15Palette.ink.color)
                Text("口径为 Asia/Shanghai · CNY")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.66))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.facts.map { "当前事实，截至 \(V15TodayReadModel.shanghaiDateLabel($0.meta.asOf))，CNY，数据版本 \($0.meta.dataRevision)" } ?? "正在取得当前事实，Asia Shanghai，CNY")
        .accessibilityIdentifier("v15.f2b.snapshot")
    }
}

private struct V15TodayAttentionQueue: View {
    let model: V15TodayReadModel
    let open: (V15AttentionItem) -> Void
    var body: some View {
        V15Section("需要你决定", detail: "按严重程度与日期排序") {
            switch model.attentionPhase {
            case .idle, .loading: V15LoadingSkeleton()
            case .failed(let failure): V15ServiceErrorState(message: failure.message, retry: { Task { await model.refreshAttention() } }).accessibilityIdentifier("v15.f2b.attention.error")
            case .loaded:
                let items = model.attention.sorted(by: V15TodayPresentation.attentionOrder)
                if items.isEmpty {
                    V15EmptyState(title: "目前没有需要你决定的事项", explanation: "这只表示关注队列为空，不代表没有财务数据。")
                        .accessibilityIdentifier("v15.f2b.attention.calm")
                } else {
                    ForEach(items) { item in
                        V15TodayAttentionRow(item: item, open: { open(item) })
                            .accessibilityIdentifier("v15.f2b.attention.\(item.id)")
                    }
                }
            }
        }
    }
}

private struct V15TodayAttentionRow: View {
    let item: V15AttentionItem
    let open: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var presentation: V15TodayPresentation.AttentionPresentation { .init(item: item) }
    var body: some View {
        Button(action: open) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: V15Spacing.sm) {
                        HStack(alignment: .center, spacing: V15Spacing.sm) {
                            badge
                            Text(presentation.label).font(V15Typography.label).foregroundStyle(presentation.color)
                            Spacer(minLength: V15Spacing.xs)
                            chevron
                        }
                        copy
                    }
                } else {
                    HStack(alignment: .top, spacing: V15Spacing.sm) {
                        badge
                        copy
                        Spacer(minLength: V15Spacing.xs)
                        chevron
                    }
                }
            }
            .padding(V15Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.card))
            .overlay { RoundedRectangle(cornerRadius: V15Radius.card).stroke(V15Palette.hairline.color, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .v15PlatformHitArea()
        .v15ActionAccessibility(label: "\(presentation.label)：\(item.explanation)", hint: "打开只读说明。\(item.suggestedAction)")
    }

    /// The visual glyph is intentionally fixed-size inside a 44pt badge. It
    /// must not inherit AX text scaling and overlap the decision copy.
    private var badge: some View {
        Image(systemName: presentation.symbol)
            .font(.system(size: 18, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(presentation.color)
            .frame(width: 44, height: 44, alignment: .center)
            .accessibilityHidden(true)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(V15Palette.ink.color.opacity(0.5))
            .frame(width: 24, height: 44, alignment: .trailing)
            .accessibilityHidden(true)
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: V15Spacing.xxs) {
            if !dynamicTypeSize.isAccessibilitySize {
                Text(presentation.label).font(V15Typography.label).foregroundStyle(presentation.color)
            }
            Text(item.explanation).font(V15Typography.body.weight(.semibold)).foregroundStyle(V15Palette.ink.color).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            Text(item.suggestedAction).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            if let date = item.occurredAt { Text("发生于 \(V15TodayReadModel.shanghaiDateLabel(date))").font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.60)) }
        }
        .layoutPriority(1)
    }
}

private struct V15TodayKnownFuture: View {
    let events: [V15FutureEvent]
    var body: some View {
        if !events.isEmpty {
            V15Section("已知未来", detail: "仅提示，完整时间轴在后续阶段") {
                ForEach(events.prefix(2)) { event in
                    HStack(alignment: .top, spacing: V15Spacing.sm) {
                        Image(systemName: "calendar").foregroundStyle(V15Palette.ink.color.opacity(0.6)).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                            Text(event.title).font(V15Typography.secondary.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                            Text("\(event.date) · \(V15TodayPresentation.certaintyLabel(event.certainty.rawValue))").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
                        }
                        Spacer(minLength: V15Spacing.xs)
                        V15MoneyText(minorUnits: event.amountMinor, direction: event.direction == .inflow ? .inflow : .outflow, font: V15Typography.secondary)
                    }
                    .padding(V15Spacing.md)
                    .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.card))
                }
            }
            .accessibilityIdentifier("v15.f2b.known-future")
        }
    }
}

/// F2 only surfaces the one facts response's compact future totals.  It never
/// derives a forecast locally or fetches the F3 future-events timeline.
private struct V15TodayFutureTotals: View {
    let future: V15Facts.FutureTotals
    var body: some View {
        V15Section("未来口径", detail: "服务端当前窗口；不计入当前现金") {
            if isZero {
                Text("当前窗口内未来口径均为零。")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    .accessibilityIdentifier("v15.f2b.future-totals.zero")
            }
            V15TodayFutureTotalRow(title: "确切到期流出", amount: future.exactDueOutflowMinor, direction: .outflow)
            V15TodayFutureTotalPair(title: "已确认", outflow: future.confirmedOutflowMinor, inflow: future.confirmedInflowMinor)
            V15TodayFutureTotalPair(title: "预计", outflow: future.expectedOutflowMinor, inflow: future.expectedInflowMinor)
            V15TodayFutureTotalPair(title: "已安排", outflow: future.scheduledOutflowMinor, inflow: future.scheduledInflowMinor)
            V15TodayFutureTotalRow(title: "确认后现金（服务端口径）", amount: future.afterConfirmedOutflowMinor, direction: .balance)
        }
        .accessibilityIdentifier("v15.f2b.future-totals")
    }

    private var isZero: Bool {
        [future.exactDueOutflowMinor, future.confirmedOutflowMinor, future.expectedOutflowMinor,
         future.scheduledOutflowMinor, future.confirmedInflowMinor, future.expectedInflowMinor,
         future.scheduledInflowMinor, future.afterConfirmedOutflowMinor].allSatisfy { $0 == 0 }
    }
}

private struct V15TodayFutureTotalRow: View {
    let title: String
    let amount: V15MinorUnits
    let direction: V15MoneyDirection
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: V15Spacing.sm) {
            Text(title).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.72))
            Spacer(minLength: V15Spacing.xs)
            V15MoneyText(minorUnits: amount, direction: direction, font: V15Typography.secondary)
        }
        .padding(V15Spacing.sm)
        .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
        .accessibilityElement(children: .combine)
    }
}

private struct V15TodayFutureTotalPair: View {
    let title: String
    let outflow: V15MinorUnits
    let inflow: V15MinorUnits
    var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.xxs) {
            Text(title).font(V15Typography.secondary.weight(.semibold)).foregroundStyle(V15Palette.ink.color.opacity(0.72))
            HStack(alignment: .firstTextBaseline, spacing: V15Spacing.sm) {
                V15MoneyText(minorUnits: outflow, direction: .outflow, font: V15Typography.secondary)
                Spacer(minLength: V15Spacing.xs)
                V15MoneyText(minorUnits: inflow, direction: .inflow, font: V15Typography.secondary)
            }
        }
        .padding(V15Spacing.sm)
        .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
        .accessibilityElement(children: .combine)
    }
}

private struct V15TodayFactsCards: View {
    let facts: V15Facts
    let open: (V15DrillDownScope?) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        V15Section("四项事实", detail: "同一数据版本 \(facts.meta.dataRevision)") {
            if dynamicTypeSize.isAccessibilitySize || requiresSingleColumn {
                VStack(spacing: V15Spacing.sm) { cards }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: V15Spacing.sm), GridItem(.flexible(), spacing: V15Spacing.sm)], spacing: V15Spacing.sm) { cards }
            }
        }
    }

    /// A grid must never force a monetary value outside its card.  In the
    /// exceptional long-value case, preserve the complete one-line amount by
    /// giving each fact the full reading width.
    private var requiresSingleColumn: Bool {
        [facts.cash.currentBalanceMinor,
         facts.credit.currentDebtMinor,
         facts.reimbursements.outstandingMinor,
         facts.completeness.uncategorizedTransactionAmountMinor]
            .contains { String($0).count > 12 }
    }

    @ViewBuilder private var cards: some View {
        V15TodayFactCard(title: "现金可用余额", detail: "账户余额", amount: facts.cash.currentBalanceMinor, direction: .balance, scope: facts.cash.scope, open: open, identifier: "cash_accounts")
        V15TodayFactCard(title: "信用卡待还", detail: "当前账期债务", amount: facts.credit.currentDebtMinor, direction: .outflow, scope: facts.credit.scope, open: open, identifier: "credit_cycles")
        V15TodayFactCard(title: "待回款", detail: "尚未收到", amount: facts.reimbursements.outstandingMinor, direction: .inflow, scope: facts.reimbursements.scope, open: open, identifier: "reimbursement_outstanding")
        V15TodayFactCard(title: "待完善记录", detail: "未分类 \(facts.completeness.uncategorizedTransactionCount) · 导入异常 \(facts.completeness.failedImportCount)", amount: facts.completeness.uncategorizedTransactionAmountMinor, direction: .neutral, scope: facts.completeness.scope, open: open, identifier: "completeness_issues")
    }
}

private struct V15TodayFactCard: View {
    let title: String; let detail: String; let amount: V15MinorUnits; let direction: V15MoneyDirection; let scope: V15DrillDownScope?; let open: (V15DrillDownScope?) -> Void; let identifier: String
    var body: some View {
        Button { open(scope) } label: {
            VStack(alignment: .leading, spacing: V15Spacing.sm) {
                Text(title).font(V15Typography.secondary.weight(.semibold)).foregroundStyle(V15Palette.ink.color).fixedSize(horizontal: false, vertical: true)
                V15MoneyText(minorUnits: amount, direction: direction, font: V15Typography.money)
                Text(detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
                Text(scope == nil ? "该事实范围当前不可打开" : "查看同版本明细").font(V15Typography.label).foregroundStyle(V15Palette.teal.color)
            }
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
            .padding(V15Spacing.md)
            .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.card))
            .overlay { RoundedRectangle(cornerRadius: V15Radius.card).stroke(V15Palette.hairline.color, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .disabled(scope == nil)
        .v15PlatformHitArea()
        .v15ActionAccessibility(label: title, hint: scope == nil ? "该事实范围当前不可打开。" : "打开同一数据版本的只读明细。")
        .accessibilityIdentifier("v15.f2b.fact.\(identifier)")
    }
}

private struct V15TodayScopeSheet: View {
    let model: V15TodayReadModel
    @Binding var detailPresented: Bool
    let dismissScope: () -> Void
    var body: some View {
        if detailPresented {
            V15TodayReadOnlyInspector(model: model, close: { detailPresented = false })
                .accessibilityIdentifier("v15.f2b.readonly.sheet")
        } else {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.md) {
                    if let snapshotAt = model.offlineSnapshotAt { V15TodayOfflineStatus(factsAsOf: model.offlineAsOf, fallbackSnapshotAt: snapshotAt) }
                    switch model.scopePhase {
                    case .idle, .loading: V15LoadingSkeleton()
                    case .empty: V15EmptyState(title: "该范围暂无明细", explanation: "这是当前事实范围的空结果，不代表全部财务数据为空。")
                        .accessibilityIdentifier("v15.f2b.scope.empty")
                    case .failed(let failure): V15ServiceErrorState(message: failure.message, retry: { retryScope() })
                        .accessibilityIdentifier("v15.f2b.scope.error")
                    case .requiresFactsReload(let failure): V15TodayReloadRequired(failure: failure, reload: reloadFacts)
                        .accessibilityIdentifier("v15.f2b.scope.conflict")
                    case .loaded:
                        ForEach(Array(model.scopeItems.enumerated()), id: \.offset) { _, item in
                            V15TodayScopeRow(item: item, open: { open(item) })
                        }
                        if let failure = model.nextPageFailure {
                            V15ServiceErrorState(message: failure.message, retry: { Task { await model.loadNextPage() } })
                                .accessibilityIdentifier("v15.f2b.scope.page-error")
                        }
                        if model.hasNextPage {
                            V15ActionButton(model.isLoadingNextPage ? "正在读取下一页" : "读取下一页", symbol: "chevron.down", disabledReason: model.isLoadingNextPage ? .init(code: "page_loading", message: "正在读取下一页。", fieldPath: nil) : nil, action: { Task { await model.loadNextPage() } })
                                .accessibilityIdentifier("v15.f2b.scope.next-page")
                        }
                    }
                }
                .padding(V15Spacing.md)
            }
            .background(V15Palette.paper.color)
            .navigationTitle(scopeTitle)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭", action: dismissScope).accessibilityIdentifier("v15.f2b.scope.close") } }
        }
        .accessibilityIdentifier("v15.f2b.scope.sheet")
        }
    }
    private var scopeTitle: String {
        switch model.selectedScope?.scopeType {
        case "cash_accounts": "事实明细 · 账户余额"
        case "credit_cycles": "事实明细 · 信用账期"
        case "reimbursement_outstanding": "事实明细 · 待回款"
        case "completeness_issues": "事实明细 · 待完善记录"
        default: "事实明细 · 当前范围"
        }
    }
    private func retryScope() { if let scope = model.selectedScope { Task { await model.openScope(scope) } } }
    private func reloadFacts() { Task { await model.refresh(); if !model.requiresFactsReload { dismissScope() } } }
    private func open(_ item: V15FactDrillDownItem) {
        Task {
            await model.openFactItem(item)
            detailPresented = true
        }
    }
}

private struct V15TodayScopeRow: View {
    let item: V15FactDrillDownItem
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: V15Spacing.sm) {
                VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                    Text(title).font(V15Typography.body.weight(.semibold)).foregroundStyle(V15Palette.ink.color).fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: V15Spacing.xs)
                if let money { V15MoneyText(minorUnits: money.0, direction: money.1, font: V15Typography.secondary) }
                Image(systemName: "chevron.right").foregroundStyle(V15Palette.ink.color.opacity(0.5)).accessibilityHidden(true)
            }
            .padding(V15Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.card))
        }
        .buttonStyle(.plain)
        .v15PlatformHitArea()
        .v15ActionAccessibility(label: title, hint: isUnknown ? "未知服务器项目，只显示安全说明。" : "打开只读检查器。")
        .accessibilityIdentifier("v15.f2b.scope.row.\(safeID)")
    }
    private var isUnknown: Bool { if case .unknown = item { true } else { false } }
    private var title: String { switch item { case .cashAccount(let v): v.name; case .creditCycle(let v): v.accountName; case .reimbursementOutstanding(let v): v.partyName; case .completenessIssue(let v): "记录待完善 · \(String(describing: v.issueType))"; case .unknown: "未知服务器明细" } }
    private var detail: String { switch item { case .cashAccount(let v): v.lastReconciledAt.map { "最近核对 \(V15TodayReadModel.shanghaiDateLabel($0))" } ?? "服务器未提供核对时间"; case .creditCycle(let v): "还款日 \(v.dueDate)"; case .reimbursementOutstanding(let v): v.expectedDate.map { "预计 \($0)" } ?? "服务器未提供预计日"; case .completenessIssue(let v): "共 \(v.count) 项"; case .unknown: "当前版本无法安全打开该项目。" } }
    private var money: (V15MinorUnits, V15MoneyDirection)? { switch item { case .cashAccount(let v): (v.currentBalanceMinor, .balance); case .creditCycle(let v): (v.remainingMinor, .outflow); case .reimbursementOutstanding(let v): (v.outstandingMinor, .inflow); case .completenessIssue(let v): v.amountMinor.map { ($0, .neutral) }; case .unknown: nil } }
    private var safeID: String { switch item { case .cashAccount(let v): v.accountID.uuidString; case .creditCycle(let v): v.cycleID.uuidString; case .reimbursementOutstanding(let v): v.claimID.uuidString; case .completenessIssue(let v): "issue-\(v.count)"; case .unknown: "unknown" } }
}

private struct V15TodayReadOnlyInspector: View {
    let model: V15TodayReadModel
    let close: () -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.md) {
                    switch model.linkedReadPhase {
                    case .idle, .loading: V15LoadingSkeleton()
                    case .requiresFactsReload(let failure): V15TodayReloadRequired(failure: failure, reload: { Task { await model.refresh() } })
                    case .localFactsInspector(let label): V15EmptyState(title: label, explanation: "当前阶段仅展示同版本事实说明，不发起额外请求。")
                    case .unavailable(let explanation): V15EmptyState(title: "暂不可打开", explanation: explanation)
                        .accessibilityIdentifier("v15.f2b.readonly.unavailable")
                    case .failed(let failure): V15ServiceErrorState(message: failure.message, retry: { Task { await model.retryLinkedRead() } })
                        .accessibilityIdentifier("v15.f2b.readonly.error")
                    case .account(let account):
                        V15Section("账户只读信息", detail: "服务器版本 \(account.version)") { Text(account.name).font(V15Typography.surfaceTitle); Text("这是只读检查器；不会显示或执行写入操作。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }
                    case .transaction(let transaction):
                        V15Section("账目只读信息", detail: "服务器版本 \(transaction.version)") { Text(transaction.title).font(V15Typography.surfaceTitle); V15MoneyText(minorUnits: transaction.amountMinor, direction: transaction.amountMinor < 0 ? .outflow : .inflow); Text("业务日（上海）：\(transaction.businessDate)").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)); Text("这是只读检查器；不会显示或执行写入操作。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }
                    }
                }
                .padding(V15Spacing.md)
                .accessibilityIdentifier(inspectorIdentifier)
            }
            .background(V15Palette.paper.color)
            .navigationTitle("只读说明")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { model.closeLinkedRead(); close() }.accessibilityIdentifier("v15.f2b.readonly.close") } }
        }
        .accessibilityIdentifier("v15.f2b.readonly.sheet")
    }

    private var inspectorIdentifier: String {
        switch model.linkedReadPhase {
        case .failed: "v15.f2b.readonly.error"
        case .unavailable: "v15.f2b.readonly.unavailable"
        default: "v15.f2b.readonly.inspector"
        }
    }
}

private struct V15TodayOfflineStatus: View {
    let factsAsOf: Date?
    let fallbackSnapshotAt: Date
    private var displayedAt: Date { factsAsOf ?? fallbackSnapshotAt }
    var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.xxs) {
            V15OfflineReadOnlyBanner(snapshotAt: displayedAt)
            Text(factsAsOf == nil
                 ? "尚未取得当前事实；显示离线快照保存时间。"
                 : "当前显示的事实截止时间：\(V15OfflineReadOnlyBanner.snapshotLabel(for: displayedAt))；离线期间仅可查看。")
                .font(V15Typography.secondary)
                .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(factsAsOf == nil
                            ? "离线只读，尚未取得当前事实，显示离线快照保存时间。"
                            : "离线只读，当前显示的事实截止时间：\(V15OfflineReadOnlyBanner.snapshotLabel(for: displayedAt))。")
    }
}

private struct V15TodayReloadRequired: View {
    let failure: V15Failure
    let reload: () -> Void
    var body: some View {
        V15ServiceErrorState(message: "\(failure.message) 需重新读取当前事实后才能继续。", retry: reload)
            .accessibilityLabel("当前事实版本已变化。\(failure.message)。取最新数据重新决定。")
    }
}

enum V15TodayPresentation {
    struct AttentionPresentation {
        let label: String; let symbol: String; let color: Color
        init(item: V15AttentionItem) {
            switch item.severity {
            case .critical: label = "紧急"; symbol = "exclamationmark.octagon.fill"; color = V15Palette.gold.color
            case .warning: label = "需要留意"; symbol = "exclamationmark.triangle.fill"; color = V15Palette.gold.color
            case .info: label = "提示"; symbol = "info.circle"; color = V15Palette.teal.color
            }
        }
    }
    static func attentionOrder(_ lhs: V15AttentionItem, _ rhs: V15AttentionItem) -> Bool {
        let rank: (V15AttentionSeverity) -> Int = { switch $0 { case .critical: 0; case .warning: 1; case .info: 2 } }
        if rank(lhs.severity) != rank(rhs.severity) { return rank(lhs.severity) < rank(rhs.severity) }
        switch (lhs.occurredAt, rhs.occurredAt) {
        case let (left?, right?) where left != right: return left < right
        case (_?, nil): return true
        case (nil, _?): return false
        default: return lhs.id < rhs.id
        }
    }
    static func certaintyLabel(_ certainty: String) -> String {
        switch certainty { case "exact_due": "确切到期"; case "confirmed": "已确认"; case "expected": "预计"; case "scheduled": "已安排"; default: "服务器状态待确认" }
    }
}

#else

/// F2-B owns the iOS decision surface only.  The parallel gallery still
/// links every source file into the shared framework on macOS, so retain a
/// deliberately non-functional placeholder until F2-C owns the desktop
/// information architecture.
public struct V15TodayView: View {
    public init(services: V15Services, offlineSnapshotAt: Date? = nil) {}
    public var body: some View {
        EmptyView()
    }
}

#endif
