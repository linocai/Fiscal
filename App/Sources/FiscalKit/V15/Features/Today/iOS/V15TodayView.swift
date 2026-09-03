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
            .v15IOSScreenCanvas()
            .navigationTitle("今日")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await model.refresh() } } label: { Label("重新读取", systemImage: V15Symbol.retry) }
                        .accessibilityIdentifier("v15.f2b.refresh")
                        .accessibilityHint("重新取得最新数据。")
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

}

private struct V15TodayHeader: View {
    let model: V15TodayReadModel
    var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.xs) {
            Text("今日概览")
                .font(V15Typography.label)
                .foregroundStyle(V15Palette.teal.color)
            if let facts = model.facts {
                Text("截至 \(V15TodayReadModel.shanghaiDateLabel(facts.meta.asOf))")
                    .font(V15Typography.surfaceTitle)
                    .foregroundStyle(V15Palette.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(facts.window.dateFrom) 至 \(facts.window.dateTo) · \(facts.meta.currency)")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("正在更新概览")
                    .font(V15Typography.surfaceTitle)
                    .foregroundStyle(V15Palette.ink.color)
                Text("上海业务日 · CNY")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.66))
            }
        }
        .padding(V15Spacing.md)
        .v15IOSCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.facts.map { "今日概览，截至 \(V15TodayReadModel.shanghaiDateLabel($0.meta.asOf))，人民币" } ?? "正在更新今日概览")
        .accessibilityIdentifier("v15.f2b.snapshot")
    }
}

private struct V15TodayKnownFuture: View {
    let events: [V15FutureEvent]
    var body: some View {
        if !events.isEmpty {
            V15Section("已知未来", detail: "已确认事项") {
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
        V15Section("未来安排", detail: "不计入当前现金") {
            if isZero {
                Text("目前没有会影响现金的未来安排。")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    .accessibilityIdentifier("v15.f2b.future-totals.zero")
            }
            V15TodayFutureTotalRow(title: "确切到期流出", amount: future.exactDueOutflowMinor, direction: .outflow)
            V15TodayFutureTotalPair(title: "已确认", outflow: future.confirmedOutflowMinor, inflow: future.confirmedInflowMinor)
            V15TodayFutureTotalPair(title: "预计", outflow: future.expectedOutflowMinor, inflow: future.expectedInflowMinor)
            V15TodayFutureTotalPair(title: "已安排", outflow: future.scheduledOutflowMinor, inflow: future.scheduledInflowMinor)
            V15TodayFutureTotalRow(title: "预计变动后现金", amount: future.afterConfirmedOutflowMinor, direction: .balance)
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
        V15Section("财务概览") {
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
                Text(scope == nil ? "当前无法查看此范围" : "查看明细").font(V15Typography.label).foregroundStyle(V15Palette.teal.color)
            }
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
            .padding(V15Spacing.md)
            .v15IOSCard()
        }
        .buttonStyle(.plain)
        .disabled(scope == nil)
        .v15PlatformHitArea()
        .v15ActionAccessibility(label: title, hint: scope == nil ? "当前无法查看此范围。" : "打开只读明细。")
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
                    case .empty: V15EmptyState(title: "该范围暂无明细", explanation: "这不代表其他财务数据为空。")
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
            .v15IOSScreenCanvas()
            .navigationTitle(scopeTitle)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭", action: dismissScope).accessibilityIdentifier("v15.f2b.scope.close") } }
        }
        .accessibilityIdentifier("v15.f2b.scope.sheet")
        }
    }
    private var scopeTitle: String {
        switch model.selectedScope?.scopeType {
        case "cash_accounts": "明细 · 账户余额"
        case "credit_cycles": "明细 · 信用账期"
        case "reimbursement_outstanding": "明细 · 待回款"
        case "completeness_issues": "明细 · 待完善记录"
        default: "明细"
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
        .v15ActionAccessibility(label: title, hint: isUnknown ? "暂时无法识别，只能查看。" : "打开只读详情。")
        .accessibilityIdentifier("v15.f2b.scope.row.\(safeID)")
    }
    private var isUnknown: Bool { if case .unknown = item { true } else { false } }
    private var title: String { switch item { case .cashAccount(let v): v.name; case .creditCycle(let v): v.accountName; case .reimbursementOutstanding(let v): v.partyName; case .completenessIssue(let v): "记录待完善 · \(String(describing: v.issueType))"; case .unknown: "暂时无法识别的明细" } }
    private var detail: String { switch item { case .cashAccount: "当前余额"; case .creditCycle(let v): "还款日 \(v.dueDate)"; case .reimbursementOutstanding(let v): v.expectedDate.map { "预计 \($0)" } ?? "暂无预计日"; case .completenessIssue(let v): "共 \(v.count) 项"; case .unknown: "当前只能查看，不能操作。" } }
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
                    case .localFactsInspector(let label): V15EmptyState(title: label, explanation: "当前仅供查看。")
                    case .unavailable(let explanation): V15EmptyState(title: "暂不可打开", explanation: explanation)
                        .accessibilityIdentifier("v15.f2b.readonly.unavailable")
                    case .failed(let failure): V15ServiceErrorState(message: failure.message, retry: { Task { await model.retryLinkedRead() } })
                        .accessibilityIdentifier("v15.f2b.readonly.error")
                    case .account(let account):
                        V15Section("账户详情") { Text(account.name).font(V15Typography.surfaceTitle); Text("当前仅供查看。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }
                    case .transaction(let transaction):
                        V15Section("账目详情") { Text(transaction.title).font(V15Typography.surfaceTitle); V15MoneyText(minorUnits: transaction.amountMinor, direction: transaction.amountMinor < 0 ? .outflow : .inflow); Text("业务日（上海）：\(transaction.businessDate)").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)); Text("当前仅供查看。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }
                    }
                }
                .padding(V15Spacing.md)
                .accessibilityIdentifier(inspectorIdentifier)
            }
            .v15IOSScreenCanvas()
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
                 ? "尚未取得最新数据；显示上次保存时间。"
                 : "当前数据截止于 \(V15OfflineReadOnlyBanner.snapshotLabel(for: displayedAt))；离线期间仅可查看。")
                .font(V15Typography.secondary)
                .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(factsAsOf == nil
                            ? "离线时只可查看，尚未取得最新数据；这里显示上次保存时间。"
                            : "离线只读，当前数据截止于 \(V15OfflineReadOnlyBanner.snapshotLabel(for: displayedAt))。")
    }
}

private struct V15TodayReloadRequired: View {
    let failure: V15Failure
    let reload: () -> Void
    var body: some View {
        V15ServiceErrorState(message: "\(failure.message) 需取得最新数据后才能继续。", retry: reload)
            .accessibilityLabel("数据已变化。\(failure.message)。取最新数据重新决定。")
    }
}

enum V15TodayPresentation {
    static func certaintyLabel(_ certainty: String) -> String {
        switch certainty { case "exact_due": "确切到期"; case "confirmed": "已确认"; case "expected": "预计"; case "scheduled": "已安排"; default: "状态待确认" }
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
