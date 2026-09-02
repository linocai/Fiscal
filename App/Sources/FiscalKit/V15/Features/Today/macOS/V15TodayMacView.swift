import SwiftUI

#if os(macOS)

/// Read-only desktop companion for the current-facts home. The workspace keeps
/// the facts, selected range, and safe linked read visible at once.
public struct V15TodayMacView: View {
    @State private var model: V15TodayReadModel
    @State private var preferredScopeType = "cash_accounts"
    @State private var hasChosenScope = false
    @State private var showsDetailInspector = false
    @State private var showsUnavailableInspector = false
    private let initialScopeType: String?

    public init(services: V15Services, offlineSnapshotAt: Date? = nil, initialScopeType: String? = nil) {
        _model = State(initialValue: V15TodayReadModel(services: services, offlineSnapshotProvider: { offlineSnapshotAt ?? services.offlineSnapshotAt }))
        self.initialScopeType = initialScopeType
    }

    public var body: some View {
        HStack(alignment: .top, spacing: V15Spacing.lg) {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.lg) {
                    header
                    factsSurface
                    scopeSurface
                }
                .padding(V15MacLayout.contentPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if showsDetailInspector {
                V15TodayMacInspector(model: model, showsUnavailableInspector: showsUnavailableInspector, close: {
                    showsDetailInspector = false
                    showsUnavailableInspector = false
                    model.closeLinkedRead()
                })
                    .frame(width: V15MacLayout.inspectorWidth)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .v15MacPanel()
            }
        }
        .v15MacWorkspaceCanvas()
        .accessibilityIdentifier("v15.f2c.today.macos")
        .task {
            await model.refresh()
            if let initialScopeType {
                hasChosenScope = true
                showsDetailInspector = true
                preferredScopeType = initialScopeType
                await model.openScope(type: initialScopeType)
            }
        }
        .onExitCommand { showsDetailInspector = false; showsUnavailableInspector = false; model.closeLinkedRead() }
        .background {
            Button("") { refreshPreservingLens() }
                .keyboardShortcut("r", modifiers: .command)
                .hidden()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: V15Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: V15Spacing.md) {
                VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                    Text("今日概览").font(V15Typography.surfaceTitle)
                    if let facts = model.facts {
                        Text("截至 \(V15TodayReadModel.shanghaiDateLabel(facts.meta.asOf)) · \(facts.window.dateFrom) 至 \(facts.window.dateTo)")
                            .font(V15Typography.secondary)
                            .foregroundStyle(V15Palette.ink.color.opacity(0.64))
                    } else {
                        Text("上海业务日 · CNY").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.64))
                    }
                }
                Spacer(minLength: V15Spacing.md)
                V15ActionButton("重新读取", symbol: V15Symbol.retry, kind: .secondary, action: refreshPreservingLens)
                    .accessibilityIdentifier("v15.f2c.refresh")
            }
            HStack(spacing: V15Spacing.xs) {
                scopeLens("账户余额", type: "cash_accounts")
                scopeLens("信用账期", type: "credit_cycles")
                scopeLens("待回款", type: "reimbursement_outstanding")
                scopeLens("待完善", type: "completeness_issues")
            }
        }
        .v15MacPanel()
    }

    @ViewBuilder private var factsSurface: some View {
        switch model.factsPhase {
        case .idle, .loading:
            V15LoadingSkeleton().accessibilityIdentifier("v15.f2c.facts.loading")
        case .failed(let failure):
            V15ServiceErrorState(message: failure.message, retry: { Task { await model.refresh() } })
                .accessibilityIdentifier("v15.f2c.facts.error")
        case .requiresReload(let failure):
            V15TodayMacReloadRequired(failure: failure, reload: { Task { await model.refresh() } })
                .accessibilityIdentifier("v15.f2c.facts.conflict")
        case .loaded:
            if let facts = model.facts {
                VStack(alignment: .leading, spacing: V15Spacing.sm) {
                    Text("财务概览").font(V15Typography.cardTitle)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: V15Spacing.sm)], spacing: V15Spacing.sm) {
                        V15TodayMacFactCard(title: "现金可用余额", detail: "账户余额", amount: facts.cash.currentBalanceMinor, direction: .balance, scope: facts.cash.scope, open: { openScope($0, type: "cash_accounts") }, identifier: "cash_accounts")
                        V15TodayMacFactCard(title: "信用卡待还", detail: "当前账期债务", amount: facts.credit.currentDebtMinor, direction: .outflow, scope: facts.credit.scope, open: { openScope($0, type: "credit_cycles") }, identifier: "credit_cycles")
                        V15TodayMacFactCard(title: "待回款", detail: "尚未收到", amount: facts.reimbursements.outstandingMinor, direction: .inflow, scope: facts.reimbursements.scope, open: { openScope($0, type: "reimbursement_outstanding") }, identifier: "reimbursement_outstanding")
                        V15TodayMacFactCard(title: "待完善记录", detail: "未分类 \(facts.completeness.uncategorizedTransactionCount) · 导入异常 \(facts.completeness.failedImportCount)", amount: facts.completeness.uncategorizedTransactionAmountMinor, direction: .neutral, scope: facts.completeness.scope, open: { openScope($0, type: "completeness_issues") }, identifier: "completeness_issues")
                    }
                }
                .v15MacPanel()
            }
        }
    }

    @ViewBuilder private var scopeSurface: some View {
        if let scope = model.selectedScope {
            VStack(alignment: .leading, spacing: V15Spacing.sm) {
                HStack {
                    VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                        Text(scopeTitle(scope.scopeType)).font(V15Typography.cardTitle)
                            .accessibilityIdentifier("v15.f2c.scope.title.\(scope.scopeType)")
                        Text("只读明细 · 与当前概览版本绑定").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.64))
                    }
                    Spacer()
                    Button("关闭", action: closeScopeInspector)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("v15.f2c.scope.close")
                }

                switch model.scopePhase {
                case .idle, .loading:
                    V15LoadingSkeleton()
                case .empty:
                    V15EmptyState(title: "该范围暂无明细", explanation: "这不代表其他财务数据为空。")
                        .accessibilityIdentifier("v15.f2c.scope.empty")
                case .failed(let failure):
                    V15ServiceErrorState(message: failure.message, retry: { Task { await model.openScope(scope) } })
                        .accessibilityIdentifier("v15.f2c.scope.error")
                case .requiresFactsReload(let failure):
                    V15TodayMacReloadRequired(failure: failure, reload: { Task { await model.refresh() } })
                        .accessibilityIdentifier("v15.f2c.facts.conflict")
                case .loaded:
                    ForEach(Array(model.scopeItems.enumerated()), id: \.offset) { index, item in
                        V15TodayMacScopeRow(item: item, open: {
                            showsDetailInspector = true
                            if case .unknown = item { showsUnavailableInspector = true } else { showsUnavailableInspector = false }
                            Task { await model.openFactItem(item) }
                        })
                            .accessibilityIdentifier("v15.f2c.scope.row.\(scope.scopeType).\(index)")
                    }
                    if let failure = model.nextPageFailure {
                        V15ServiceErrorState(message: failure.message, retry: { Task { await model.loadNextPage() } })
                            .accessibilityIdentifier("v15.f2c.scope.page-error")
                    }
                    if model.hasNextPage {
                        V15ActionButton(model.isLoadingNextPage ? "正在读取下一页" : "读取下一页", symbol: "chevron.down", kind: .secondary, disabledReason: model.isLoadingNextPage ? .init(code: "page_loading", message: "正在读取下一页。", fieldPath: nil) : nil, action: { Task { await model.loadNextPage() } })
                            .accessibilityIdentifier("v15.f2c.scope.next")
                    }
                }
            }
            .v15MacPanel()
        }
    }

    private func scopeLens(_ title: String, type: String) -> some View {
        Button(title) { chooseScope(type) }
            .buttonStyle(.borderless)
            .foregroundStyle(preferredScopeType == type ? V15Palette.teal.color : V15Palette.ink.color.opacity(0.66))
            .accessibilityIdentifier("v15.f2c.lens.\(type)")
    }

    private func chooseScope(_ type: String) {
        preferredScopeType = type
        hasChosenScope = true
        showsDetailInspector = true
        showsUnavailableInspector = false
        model.closeLinkedRead()
        guard model.facts != nil else { return }
        Task { await model.openScope(type: type) }
    }

    private func openScope(_ scope: V15DrillDownScope?, type: String) {
        preferredScopeType = type
        hasChosenScope = true
        showsDetailInspector = true
        showsUnavailableInspector = false
        model.closeLinkedRead()
        guard let scope else { return }
        Task { await model.openScope(scope) }
    }

    private func refreshPreservingLens() {
        showsDetailInspector = false
        showsUnavailableInspector = false
        Task {
            await model.refresh()
            guard !model.requiresFactsReload else { return }
            guard hasChosenScope,
                  let scopeType = V15TodayMacRefreshPolicy.scopeTypeToReopen(currentScopeType: preferredScopeType) else { return }
            preferredScopeType = scopeType
            await model.openScope(type: scopeType)
            showsDetailInspector = true
        }
    }

    private func closeScopeInspector() {
        hasChosenScope = false
        showsDetailInspector = false
        showsUnavailableInspector = false
        model.closeScopeInspector()
    }

    private func scopeTitle(_ type: String) -> String {
        switch type {
        case "cash_accounts": "账户余额"
        case "credit_cycles": "信用账期"
        case "reimbursement_outstanding": "待回款"
        case "completeness_issues": "待完善记录"
        default: "相关明细"
        }
    }
}

private struct V15TodayMacFactCard: View {
    let title: String; let detail: String; let amount: V15MinorUnits; let direction: V15MoneyDirection; let scope: V15DrillDownScope?; let open: (V15DrillDownScope?) -> Void; let identifier: String
    var body: some View {
        Button { open(scope) } label: {
            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                Text(title).font(V15Typography.secondary.weight(.semibold))
                V15MoneyText(minorUnits: amount, direction: direction, font: V15Typography.money)
                Text(detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.64))
                Text(scope == nil ? "当前无法查看此范围" : "查看明细").font(V15Typography.label).foregroundStyle(V15Palette.teal.color)
            }
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
            .padding(V15Spacing.md)
        }
        .buttonStyle(.plain)
        .disabled(scope == nil)
        .v15MacPanel()
        .accessibilityIdentifier("v15.f2c.fact.\(identifier)")
    }
}

private struct V15TodayMacScopeRow: View {
    let item: V15FactDrillDownItem
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: V15Spacing.sm) {
                VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                    Text(title).font(V15Typography.body.weight(.semibold))
                    Text(detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.64))
                }
                Spacer(minLength: V15Spacing.sm)
                if let money { V15MoneyText(minorUnits: money.0, direction: money.1, font: V15Typography.secondary) }
                Image(systemName: "chevron.right").foregroundStyle(V15Palette.ink.color.opacity(0.48))
            }
            .padding(V15Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .background(V15Palette.ink.color.opacity(0.035), in: RoundedRectangle(cornerRadius: V15Radius.control))
    }
    private var title: String { switch item { case .cashAccount(let value): value.name; case .creditCycle(let value): value.accountName; case .reimbursementOutstanding(let value): value.partyName; case .completenessIssue(let value): "记录待完善 · \(String(describing: value.issueType))"; case .unknown: "暂时无法识别的明细" } }
    private var detail: String { switch item { case .cashAccount: "当前余额"; case .creditCycle(let value): "还款日 \(value.dueDate)"; case .reimbursementOutstanding(let value): value.expectedDate.map { "预计 \($0)" } ?? "暂无预计日"; case .completenessIssue(let value): "共 \(value.count) 项"; case .unknown: "当前只能查看，不能操作。" } }
    private var money: (V15MinorUnits, V15MoneyDirection)? { switch item { case .cashAccount(let value): (value.currentBalanceMinor, .balance); case .creditCycle(let value): (value.remainingMinor, .outflow); case .reimbursementOutstanding(let value): (value.outstandingMinor, .inflow); case .completenessIssue(let value): value.amountMinor.map { ($0, .neutral) }; case .unknown: nil } }
}

private struct V15TodayMacInspector: View {
    let model: V15TodayReadModel
    let showsUnavailableInspector: Bool
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            HStack {
                Text("详情").font(V15Typography.cardTitle).accessibilityIdentifier("v15.f2c.inspector")
                if showsUnavailableInspector || isUnavailable {
                    Text("暂不可打开").font(V15Typography.label).foregroundStyle(V15Palette.gold.color)
                }
                Spacer()
                Button("关闭", action: close).buttonStyle(.borderless).accessibilityIdentifier("v15.f2c.inspector.close")
            }
            switch model.linkedReadPhase {
            case .idle: V15EmptyState(title: "选择一项明细", explanation: "在左侧选择项目以查看只读信息。")
            case .loading: V15LoadingSkeleton()
            case .requiresFactsReload(let failure): V15TodayMacReloadRequired(failure: failure, reload: { Task { await model.refresh() } })
            case .localFactsInspector(let label): V15EmptyState(title: label, explanation: "当前仅供查看。")
            case .unavailable(let explanation):
                VStack(alignment: .leading, spacing: V15Spacing.xs) {
                    Text("暂不可打开").font(V15Typography.cardTitle)
                    Text(explanation).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.64))
                }
                .v15MacPanel()
            case .failed(let failure):
                VStack { V15ServiceErrorState(message: failure.message, retry: { Task { await model.retryLinkedRead() } }) }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("v15.f2c.inspector.error")
            case .account(let account): V15Section("账户详情") { Text(account.name).font(V15Typography.surfaceTitle); Text("当前仅供查看。").font(V15Typography.secondary) }
            case .transaction(let transaction): V15Section("账目详情") { Text(transaction.title).font(V15Typography.surfaceTitle); V15MoneyText(minorUnits: transaction.amountMinor, direction: transaction.amountMinor < 0 ? .outflow : .inflow); Text("业务日（上海）：\(transaction.businessDate)").font(V15Typography.secondary) }
            }
        }
        .padding(V15Spacing.md)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f2c.inspector")
    }
    private var isUnavailable: Bool { if case .unavailable = model.linkedReadPhase { true } else { false } }
}

private struct V15TodayMacReloadRequired: View {
    let failure: V15Failure
    let reload: () -> Void
    var body: some View { V15ServiceErrorState(message: failure.message, retry: reload) }
}

enum V15TodayMacRefreshPolicy {
    static func scopeTypeToReopen(currentScopeType: String?) -> String? {
        switch currentScopeType {
        case "cash_accounts", "credit_cycles", "reimbursement_outstanding", "completeness_issues": currentScopeType
        default: nil
        }
    }
}

#endif
