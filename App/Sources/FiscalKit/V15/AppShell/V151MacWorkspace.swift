import Foundation
import SwiftUI

#if os(macOS)
import AppKit

enum V151MacBusinessDateRange {
    struct MonthDateRange: Equatable {
        let from: String
        let to: String
    }

    static func monthDateRange(containing date: Date) -> MonthDateRange? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_Hans_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        guard let interval = calendar.dateInterval(of: .month, for: date) else { return nil }
        let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return .init(from: formatter.string(from: interval.start), to: formatter.string(from: lastDay))
    }
}

enum V151MacLedgerAccountFilter {
    static func retainedAccountID(
        _ accountFilterID: UUID?,
        availableAccounts: [V15AccountResponse]
    ) -> UUID? {
        guard let accountFilterID else { return nil }
        return availableAccounts.contains(where: { $0.id == accountFilterID })
            ? accountFilterID
            : nil
    }
}

struct V151MacLedgerAccountContext: Equatable {
    private(set) var filterID: UUID?
    private(set) var detailID: UUID?

    mutating func selectAccount(_ id: UUID) {
        filterID = id
        detailID = id
    }

    mutating func selectTransaction() { detailID = nil }
    mutating func showFilteredLedger() { detailID = nil }
    mutating func selectDetailAccount(_ id: UUID) { detailID = id }
    mutating func clearAllAccounts() { filterID = nil; detailID = nil }

    mutating func clearMissingFilter(availableAccounts: [V15AccountResponse]) -> UUID? {
        guard let filterID,
              V151MacLedgerAccountFilter.retainedAccountID(filterID, availableAccounts: availableAccounts) == nil
        else { return nil }
        self.filterID = nil
        if detailID == filterID { detailID = nil }
        return filterID
    }
}

enum V151MacAccountBalanceSemantics {
    static func kindLabel(_ kind: V15AccountKind) -> String {
        switch kind {
        case .cash: "现金"
        case .debit: "借记"
        case .credit: "信用"
        case .unknown: "其他"
        }
    }

    static func amountLabel(_ kind: V15AccountKind, minorUnits: Int64) -> String {
        if kind == .credit { return minorUnits < 0 ? "信用溢缴" : "欠款" }
        return "余额"
    }

    static func direction(_ kind: V15AccountKind, minorUnits: Int64) -> V15MoneyDirection {
        guard minorUnits != 0 else { return .balance }
        return kind == .credit ? (minorUnits < 0 ? .neutral : .outflow) : .balance
    }
}

enum V151MacLedgerSearch {
    static func committedQuery(from draft: String) -> String? {
        draft.isEmpty ? nil : draft
    }
}

/// v1.5.2 keeps the user-approved macOS prototype as the formal live root.
/// It keeps the V15 services and models, but owns every visible navigation and
/// layout decision instead of inheriting the system split-view appearance.
public struct V151MacWorkspace: View {
    fileprivate enum Destination: String, Identifiable, Equatable {
        case overview, timeline, accounts, reports, settings, record, future, credit, installments, reimbursements, cashFlow, pendingSync
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: "总览"
            case .timeline: "交易"
            case .accounts: "账户"
            case .record: "记一笔"
            case .future: "有来源未来"
            case .credit: "信用账期"
            case .installments: "分期"
            case .reimbursements: "报销"
            case .cashFlow: "现金流"
            case .reports: "财务分析"
            case .pendingSync: "待同步"
            case .settings: "设置与数据"
            }
        }
    }

    private enum AccountDetailPhase: Equatable {
        case idle, loading, loaded, failed(V15Failure)
    }

    fileprivate enum KnownFutureOpenPhase: Equatable {
        case idle
        case loading(String)
        case failed(id: String, message: String)
    }

    private enum SidebarAccountGroup: String, Identifiable {
        case cash, credit
        var id: String { rawValue }
        var title: String { self == .cash ? "现金与储蓄" : "信用账户" }
    }

    /// Specialist pages are contextual, never root spaces.  Keep the page that
    /// supplied the context so Back does not silently turn a timeline action
    /// into a future-timeline detour (or vice versa).
    private enum ContextualOrigin {
        case overview
        case timeline
        case future

        var destination: Destination {
            switch self {
            case .overview: .overview
            case .timeline: .timeline
            case .future: .future
            }
        }
    }

    private static let transactionRowHeight: CGFloat = 39

    private let services: V15Services
    @State private var ledger: V15LedgerModel
    @State private var overviewLedger: V15LedgerModel
    @State private var facts: V15TodayReadModel
    @State private var destination: Destination = .overview
    @State private var selectedID: UUID?
    @State private var selectedIDs: Set<UUID> = []
    @State private var searchPresented = false
    @State private var categoryPresented = false
    @State private var categoryID: UUID?
    @State private var categoryPreviewed = false
    @State private var categoryCommitNotice: String?
    @State private var batchCategoryID: UUID?
    @State private var batchPreviewed = false
    @State private var batchWorking = false
    @State private var batchResult: V15LedgerModel.BatchCategoryResult?
    @State private var selectedMonth = Date()
    @State private var allLedgerTime = false
    /// The only owner of the ledger's account filter.  It intentionally remains
    /// active while a transaction is selected or the account inspector closes.
    @State private var accountContext = V151MacLedgerAccountContext()
    @State private var selectedAccount: V15AccountResponse?
    @State private var accountDetailPhase: AccountDetailPhase = .idle
    @State private var accountDetail: V15AccountDetailModel
    @State private var searchDraft = ""
    @State private var futureTarget: V15FutureOpenTarget?
    @State private var knownFuture: V15FutureTimelineModel
    @State private var futureTimeline: V15FutureTimelineModel
    @State private var futureTimelineSelectedID: String?
    @State private var recordOrigin: Destination = .timeline
    @State private var futureOverviewOrigin: Destination = .timeline
    @State private var sidebarAccountGroup: SidebarAccountGroup?
    @State private var knownFutureOpenPhase: KnownFutureOpenPhase = .idle
    @State private var knownFutureOpenGeneration: UInt64 = 0
    @State private var contextualOrigin: ContextualOrigin = .timeline
    @State private var initialCreditAccountID: UUID?
    @State private var initialInstallmentAccountID: UUID?
    @State private var initialInstallmentPlanID: UUID?
    @State private var initialInstallmentPurchaseTransactionID: UUID?
    @State private var initialReimbursementClaimID: UUID?
    @State private var initialReimbursementPartyID: UUID?
    @State private var initialReimbursementTransactionID: UUID?
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    public init(services: V15Services) {
        self.services = services
        _ledger = State(initialValue: V15LedgerModel(services: services))
        _overviewLedger = State(initialValue: V15LedgerModel(services: services))
        _accountDetail = State(initialValue: V15AccountDetailModel(services: services))
        _facts = State(initialValue: V15TodayReadModel(services: services, offlineSnapshotProvider: { services.offlineSnapshotAt }))
        _knownFuture = State(initialValue: V15FutureTimelineModel(services: services, offlineSnapshotProvider: { services.offlineSnapshotAt }))
        _futureTimeline = State(initialValue: V15FutureTimelineModel(services: services, offlineSnapshotProvider: { services.offlineSnapshotAt }))
    }

    public var body: some View {
        workspace
        .frame(minWidth: V15MacLayout.minimumWindowWidth, minHeight: V15MacLayout.minimumWindowHeight)
        .background(V15Palette.canvas.color.ignoresSafeArea())
        .tint(V15Palette.teal.color)
        .task { await loadInitialFacts() }
        .onChange(of: services.confirmedWriteRevision) { _, _ in Task { await refreshAfterConfirmedRecord() } }
        .sheet(isPresented: $categoryPresented) { categorySheet }
        .overlay { if destination == .timeline { keyboardCommands } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v151.mac.workspace")
    }

    private var workspace: some View {
        GeometryReader { geometry in
        let compact = geometry.size.width < 1_160
        let sidebarWidth = compact ? V15MacLayout.compactSidebarWidth : V15MacLayout.sidebarWidth
        NavigationSplitView {
            indexPane(compact: compact)
                .navigationSplitViewColumnWidth(min: sidebarWidth, ideal: sidebarWidth, max: sidebarWidth)
        } detail: {
            if destination == .timeline {
                // Keep the reading column stable; the supporting inspector is
                // only present when the selected fact has useful context.
                HStack(spacing: 0) {
                    spinePane.frame(minWidth: timelineInspectorVisible ? 440 : 560, maxWidth: .infinity)
                    if timelineInspectorVisible {
                        Rectangle().fill(V15Palette.hairline.color).frame(width: 1)
                        inspectorPane.frame(width: compact ? 280 : 320)
                    }
                }
            } else {
                modulePane.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(V15Palette.canvas.color.ignoresSafeArea())
            }
        }
        .navigationSplitViewStyle(.balanced)
        }
    }

    private func indexPane(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                Button { navigateRoot(to: .overview) } label: {
                    if compact {
                        Text("F")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(V15Palette.brandInk.color)
                            .frame(width: 36, height: 36)
                            .background(V15Palette.yellow.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
                            .accessibilityLabel("Fiscal 个人财务工作台，返回总览")
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("FISCAL").font(.system(size: 12, weight: .bold, design: .rounded))
                                .tracking(1.4)
                                .foregroundStyle(V15Palette.brandInk.color)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(V15Palette.yellow.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
                            Text("个人财务工作台").font(V15Typography.secondary)
                                .foregroundStyle(Color.white.opacity(0.62))
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            .padding(.horizontal, compact ? 10 : 18)
            .padding(.top, 20)
            .padding(.bottom, 18)
            VStack(alignment: .leading, spacing: 3) {
                moduleNavigation("总览", symbol: "square.grid.2x2", destination: .overview, compact: compact)
                moduleNavigation("交易", symbol: "list.bullet.rectangle", destination: .timeline, compact: compact)
                moduleNavigation("账户", symbol: "building.columns", destination: .accounts, compact: compact)
                moduleNavigation("分析", symbol: "chart.line.uptrend.xyaxis", destination: .reports, compact: compact)
            }
            .padding(.horizontal, compact ? 10 : 12)
            if !compact {
                sidebarAccounts
                    .padding(.horizontal, 12)
                    .padding(.top, 22)
            }
            Spacer()
        }
        .background(V15Palette.sidebarDeep.color)
    }

    @ViewBuilder private var sidebarAccounts: some View {
        if case .loaded = ledger.referencePhase, !ledger.accounts.isEmpty {
            let cash = ledger.accounts.filter { $0.kind != .credit }
            let credit = ledger.accounts.filter { $0.kind == .credit }
            VStack(alignment: .leading, spacing: 10) {
                Text("账户概览")
                    .font(V15Typography.label)
                    .foregroundStyle(Color.white.opacity(0.62))
                    .padding(.horizontal, 12)
                VStack(spacing: 0) {
                    sidebarAccountSummary(.cash, accounts: cash, amount: sidebarTotal(cash), direction: .balance)
                    Rectangle().fill(Color.white.opacity(0.13)).frame(height: 1).padding(.horizontal, 12)
                    sidebarAccountSummary(.credit, accounts: credit, amount: sidebarTotal(credit), direction: .outflow)
                }
                .background(V15Palette.sidebarRaised.color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .popover(item: $sidebarAccountGroup, arrowEdge: .trailing) { group in
                    sidebarAccountPopover(group).id(group.id)
                }
            }
        }
    }

    private func sidebarAccountSummary(_ group: SidebarAccountGroup, accounts: [V15AccountResponse], amount: V15OverviewAmountGate.Result, direction: V15MoneyDirection) -> some View {
        let overpaid: Bool
        if case .amount(let value) = amount { overpaid = group == .credit && value < 0 }
        else { overpaid = false }
        return Button { sidebarAccountGroup = group } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: group == .cash ? "building.columns" : "creditcard")
                        .foregroundStyle(group == .cash ? V15Palette.yellow.color : Color.white.opacity(0.84))
                        .frame(width: 16)
                    Text(group.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                    Text("\(accounts.count) 个")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.64))
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.white.opacity(0.58))
                }
                Text(group == .cash ? "当前余额" : overpaid ? "当前溢缴" : "当前欠款")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.60))
                switch amount {
                case .amount(let value):
                    Text(V15MoneyPresentation(minorUnits: value, direction: overpaid ? .neutral : direction, includeCurrency: false).text)
                        .font(.system(size: 19, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                case .unavailable:
                    Text("暂不可汇总")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.88))
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("v152.mac.sidebar.accounts.\(group.rawValue)")
    }

    private func sidebarTotal(_ accounts: [V15AccountResponse]) -> V15OverviewAmountGate.Result { V15OverviewAmountGate.sum(accounts.map(\.currentBalanceMinor)) }

    private func sidebarAccountPopover(_ group: SidebarAccountGroup) -> some View {
        let accounts = ledger.accounts.filter { group == .credit ? $0.kind == .credit : $0.kind != .credit }
        return V22AccountPicker(
            title: group.title,
            accounts: accounts,
            onSelect: { id in
                sidebarAccountGroup = nil
                navigateRoot(to: .timeline)
                selectAccount(id)
            },
            onManage: {
                sidebarAccountGroup = nil
                navigateRoot(to: .accounts)
            },
            onClose: { sidebarAccountGroup = nil }
        )
    }

    private func moduleNavigation(_ title: String, symbol: String, destination value: Destination, compact: Bool) -> some View {
        Button { navigateRoot(to: value) } label: {
            Group {
                if compact {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: destination == value ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                } else {
                    Label(title, systemImage: symbol)
                        .font(.system(size: 14, weight: destination == value ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 11)
                }
            }
                .foregroundStyle(destination == value ? V15Palette.brandInk.color : Color.white.opacity(0.70))
                .frame(height: 40)
                .background(destination == value ? V15Palette.yellow.color : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("v151.mac.module.\(value.rawValue)")
    }

    private var spinePane: some View {
        VStack(spacing: 0) {
            ledgerHeader
            Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    if let snapshotAt = ledger.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: snapshotAt, pendingCount: services.pendingWrites.count).padding(12) }
                    timelineAnchor
                    timelineSectionLabel("正式账目", detail: "已发生并已确认的账目；未来计划不会混入余额或流水。")
                    transactionRows
                    if ledger.nextCursor != nil { loadMoreRow }
                    knownFutureSection
                }
            }
            Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
            spineFooter
        }
        .background(V15Palette.paper.color)
    }

    private var ledgerHeader: some View {
        VStack(spacing: 0) {
            spineToolbar
            Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
            accountBalanceBoard
        }
        .background(V15Palette.card.color)
    }

    private var spineToolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 10) {
            Text("财务时间线").font(.system(size: 15, weight: .semibold))
                .accessibilityIdentifier("v151.mac.ledger.title")
            Spacer(minLength: 8)
            if let query = ledger.filter.query {
                Text("搜索：\(query)")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .accessibilityIdentifier("v151.mac.ledger.search.active")
                Button(action: clearSearch) { Label("清除搜索", systemImage: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("v151.mac.ledger.search.clear")
            } else {
                Button {
                    searchDraft = ledger.filter.query ?? ""
                    searchPresented = true
                } label: { Label("搜索", systemImage: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("f", modifiers: .command)
                    .accessibilityIdentifier("v151.mac.ledger.search")
                    .popover(isPresented: $searchPresented, arrowEdge: .top) { searchPopover }
            }
            Button { openRecord() } label: { Label("记一笔", systemImage: "plus") }
                .buttonStyle(V22MacWorkspaceButtonStyle(primary: true))
                .keyboardShortcut("n", modifiers: .command)
        }
        HStack(spacing: 10) {
            V23ChoiceButton("上月", symbol: "chevron.left") { shiftLedgerMonth(-1) }.help("上一个月").accessibilityIdentifier("v221.mac.ledger.previous-month")
            V23BusinessDatePicker("查询月份", selection: Binding(get: { selectedMonth }, set: { applyMonth(monthParser.string(from: $0)) }), dateFormat: "yyyy年M月")
                .accessibilityIdentifier("v221.mac.ledger.month")
                .accessibilityValue(monthParser.string(from: selectedMonth))
            V23ChoiceButton("下月", symbol: "chevron.right") { shiftLedgerMonth(1) }.help("下一个月").accessibilityIdentifier("v221.mac.ledger.next-month")
            V23ChoiceButton("全部时间", symbol: "calendar.badge.clock", selected: allLedgerTime) {
                if allLedgerTime { applyMonth(monthParser.string(from: selectedMonth)) }
                else { applyAllLedgerTime() }
            }
            .accessibilityHint(allLedgerTime ? "再次点击返回所选月份" : "显示所有日期的账目")
            .accessibilityIdentifier("v221.mac.ledger.all-time")
            Spacer(minLength: 0)
        }
        }
        .padding(.horizontal, V15MacLayout.contentPadding).padding(.vertical, 10)
    }

    @ViewBuilder private var accountBalanceBoard: some View {
        switch ledger.referencePhase {
        case .idle, .loading:
            V15LoadingSkeleton(layout: .compact)
                .padding(.horizontal, V15MacLayout.contentPadding)
                .padding(.vertical, 10)
                .accessibilityIdentifier("v151.mac.account.scope.loading")
        case .failed(let failure):
            V15ServiceErrorState(message: failure.message) {
                Task { await refreshLedgerReferencesAndReconcileSelectedAccount() }
            }
            .padding(.horizontal, V15MacLayout.contentPadding)
            .padding(.vertical, 10)
            .accessibilityIdentifier("v151.mac.account.scope.error")
        case .empty:
            V15EmptyState(title: "还没有可用账户", explanation: "请先在设置中建立账户。")
                .padding(.horizontal, V15MacLayout.contentPadding)
                .padding(.vertical, 10)
                .accessibilityIdentifier("v151.mac.account.scope.empty")
        case .loaded:
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("切换账户").font(V15Typography.secondary.weight(.semibold))
                    Spacer()
                    Text(accountScopeDetail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.62))
                }
                if ledger.accounts.count > 6 {
                    ScrollViewReader { proxy in
                        ScrollView {
                            visibleAccountChoices
                        }.frame(maxHeight: 170)
                        .accessibilityIdentifier("v230.account-switcher.scroll")
                        .onAppear { if let id = filteredAccount?.id { proxy.scrollTo(id, anchor: .center) } }
                        .onChange(of: filteredAccount?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                    }
                } else { visibleAccountChoices }
                HStack(spacing: 12) {
                if let value = facts.facts {
                    accountSummaryRow("资产", minorUnits: value.cash.currentBalanceMinor, direction: .balance)
                    Divider().frame(height: 18)
                    accountSummaryRow(value.credit.currentDebtMinor < 0 ? "信用溢缴" : "信用欠款", minorUnits: value.credit.currentDebtMinor, direction: value.credit.currentDebtMinor < 0 ? .neutral : .outflow)
                } else {
                    Text(factsSummaryPlaceholder)
                        .font(.system(size: 12))
                        .foregroundStyle(V15Palette.ink.color.opacity(0.56))
                }
                Spacer(minLength: 0)
                Text(accountScopeDetail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(V15Palette.ink.color.opacity(0.56))
                    .lineLimit(1)
            }
                }
            .padding(.horizontal, V15MacLayout.contentPadding)
            .padding(.vertical, 10)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("v151.mac.account.scope.summary")
        }
    }

    private var visibleAccountChoices: some View {
        V23WrappingLayout {
            V23ChoiceButton("全部账户", symbol: "square.grid.2x2", selected: filteredAccount == nil) { selectAllAccounts() }
                .accessibilityIdentifier("v151.mac.account.scope.all")
            ForEach(ledger.accounts) { account in
                V23ChoiceButton(account.name, symbol: account.kind == .credit ? "creditcard" : "building.columns", selected: filteredAccount?.id == account.id) { selectAccount(account.id) }
                    .id(account.id)
                    .accessibilityIdentifier("v151.mac.account.scope.\(account.id)")
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("v151.mac.account.scope")
    }

    private func accountSummaryRow(_ label: String, minorUnits: Int64, direction: V15MoneyDirection) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label).font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.62))
            Spacer(minLength: 3)
            V15MoneyText(
                minorUnits: minorUnits,
                direction: minorUnits == 0 ? .balance : direction,
                font: .system(size: 14, weight: .semibold, design: .monospaced)
            )
                .minimumScaleFactor(0.76)
        }
    }

    private var factsSummaryPlaceholder: String {
        switch facts.factsPhase {
        case .idle, .loading: "正在读取资产与信用欠款…"
        case .loaded: "资产与信用欠款暂不可用"
        case .failed, .requiresReload: "资产与信用欠款读取失败"
        }
    }

    private var accountScopeDetail: String {
        if let account = filteredAccount {
            let direction = V151MacAccountBalanceSemantics.direction(account.kind, minorUnits: account.currentBalanceMinor)
            return "\(V151MacAccountBalanceSemantics.amountLabel(account.kind, minorUnits: account.currentBalanceMinor)) \(V15MoneyPresentation(minorUnits: account.currentBalanceMinor, direction: direction).text)"
        }
        return "\(ledger.accounts.count) 个账户"
    }

    private var timelineAnchor: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.inset.filled")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(V15Palette.teal.color)
            VStack(alignment: .leading, spacing: 2) {
                Text("今天 · \(shanghaiBusinessDate)")
                    .font(.system(size: 13, weight: .semibold))
                Text("从这里读回已发生账目，也读向有来源的未来事项。")
                    .font(.system(size: 12))
                    .foregroundStyle(V15Palette.ink.color.opacity(0.58))
            }
            Spacer(minLength: 0)
            Button("回到本月") { applyMonth(monthParser.string(from: Date())) }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, V15MacLayout.contentPadding)
        .padding(.vertical, 12)
        .background(V15Palette.selected.color.opacity(0.45))
        .accessibilityIdentifier("v151.mac.timeline.today-anchor")
    }

    private func timelineSectionLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(V15Palette.ink.color.opacity(0.56))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, V15MacLayout.contentPadding)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .accessibilityIdentifier("v151.mac.timeline.section.\(title)")
    }

    private var knownFutureSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            timelineSectionLabel("有来源未来", detail: "只显示来自信用账期、报销对象或现金流计划的已知事项。")
            switch knownFuture.phase {
            case .idle, .loading:
                V15LoadingSkeleton(layout: .compact)
                    .padding(.horizontal, V15MacLayout.contentPadding)
                    .padding(.bottom, 16)
            case .failed(let failure), .requiresReload(let failure):
                V15ServiceErrorState(message: failure.message) { reloadKnownFuture() }
                    .padding(.horizontal, V15MacLayout.contentPadding)
                    .padding(.bottom, 16)
            case .empty:
                Text("当前读取范围没有已知未来事项。")
                    .font(.system(size: 12))
                    .foregroundStyle(V15Palette.ink.color.opacity(0.58))
                    .padding(.horizontal, V15MacLayout.contentPadding)
                    .padding(.bottom, 16)
            case .loaded:
                ForEach(Array(knownFuture.events.prefix(3))) { event in
                    knownFutureRow(event)
                    knownFutureOpenState(for: event)
                }
            }
            Button {
                openFutureOverview()
            } label: {
                Label("查看全部有来源未来", systemImage: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, V15MacLayout.contentPadding)
            .padding(.vertical, 12)
            .accessibilityIdentifier("v151.mac.timeline.future")
            Button {
                openCashFlow(from: .timeline)
            } label: {
                Label("管理现金流计划", systemImage: "calendar.badge.clock")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, V15MacLayout.contentPadding)
            .padding(.bottom, 12)
            .accessibilityIdentifier("v151.mac.timeline.cash-flow")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v151.mac.timeline.known-future")
    }

    private func knownFutureRow(_ event: V15FutureEvent) -> some View {
        Button {
            openKnownFuture(event)
        } label: {
            HStack(spacing: 12) {
                Text(event.date)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(V15Palette.ink.color.opacity(0.56))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(knownFutureSourceLabel(event.sourceType))
                        .font(.system(size: 11))
                        .foregroundStyle(V15Palette.ink.color.opacity(0.56))
                }
                Spacer(minLength: 8)
                V15MoneyText(
                    minorUnits: event.amountMinor,
                    direction: event.direction == .inflow ? .inflow : .outflow,
                    includeCurrency: false,
                    font: .system(size: 13, weight: .semibold, design: .monospaced)
                )
            }
            .padding(.horizontal, V15MacLayout.contentPadding)
            .frame(height: Self.transactionRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isOpeningKnownFuture)
        .overlay(alignment: .bottom) { Rectangle().fill(V15Palette.hairline.color).frame(height: 1) }
        .accessibilityIdentifier("v151.mac.timeline.future-event.\(event.id)")
    }

    @ViewBuilder private func knownFutureOpenState(for event: V15FutureEvent) -> some View {
        switch knownFutureOpenPhase {
        case .loading(let id) where id == event.id:
            V15LoadingSkeleton(layout: .compact)
                .padding(.horizontal, V15MacLayout.contentPadding)
                .padding(.bottom, 10)
                .accessibilityIdentifier("v151.mac.timeline.future-event.loading.\(event.id)")
        case .failed(let id, let message) where id == event.id:
            V15ServiceErrorState(message: message) { openKnownFuture(event) }
                .padding(.horizontal, V15MacLayout.contentPadding)
                .padding(.bottom, 10)
                .accessibilityIdentifier("v151.mac.timeline.future-event.error.\(event.id)")
        default:
            EmptyView()
        }
    }

    private var isOpeningKnownFuture: Bool {
        if case .loading = knownFutureOpenPhase { return true }
        return false
    }

    private func openKnownFuture(_ event: V15FutureEvent, from origin: ContextualOrigin = .timeline) {
        guard !isOpeningKnownFuture else { return }
        knownFutureOpenGeneration &+= 1
        let generation = knownFutureOpenGeneration
        knownFutureOpenPhase = .loading(event.id)
        Task {
            guard let target = await knownFuture.resolveOpenTarget(event) else {
                guard generation == knownFutureOpenGeneration else { return }
                guard case .loading(let id) = knownFutureOpenPhase, id == event.id else { return }
                let message: String
                if case .failed(let value) = knownFuture.openPhase { message = value }
                else { message = "暂时无法核验这项未来事项的最新归属。" }
                knownFutureOpenPhase = .failed(id: event.id, message: message)
                return
            }
            guard generation == knownFutureOpenGeneration else { return }
            guard case .loading(let id) = knownFutureOpenPhase, id == event.id else { return }
            knownFutureOpenPhase = .idle
            openVerifiedFutureTarget(target, from: origin)
        }
    }

    private func knownFutureSourceLabel(_ source: V15FutureEventSource) -> String {
        switch source {
        case .creditCycle: "信用账期 · 有来源"
        case .reimbursementParty: "报销对象 · 有来源"
        case .cashFlowItem: "现金流事项 · 有来源"
        }
    }

    @ViewBuilder private var transactionRows: some View {
        switch ledger.phase {
        case .idle, .loading: V15LoadingSkeleton(layout: .list(rows: 6)).padding(18)
        case .empty: V15EmptyState(title: "这里还没有账目", explanation: "可以更换筛选条件或时间范围。").padding(20)
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await ledger.load() } }.padding(20)
        case .loaded:
            if visibleTransactions.isEmpty {
                V15EmptyState(title: "这里还没有账目", explanation: "可以更换月份或账户范围。")
                    .padding(20)
            } else {
                ForEach(visibleTransactions, id: \.id) { transaction in transactionRow(transaction) }
            }
        }
    }

    private var visibleTransactions: [V15Transaction] {
        ledger.items
    }

    private func transactionRow(_ transaction: V15Transaction) -> some View {
        let selected = selectedID == transaction.id
        let batchSelected = selectedIDs.contains(transaction.id)
        let presentation = ledger.transactionPresentation(transaction)
        return HStack(spacing: 0) {
            Button { toggleBatchSelection(transaction.id) } label: {
                Image(systemName: transaction.voidedAt != nil ? "archivebox" : (batchSelected ? "checkmark.square.fill" : "square"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(batchSelected ? V15Palette.teal.color : V15Palette.ink.color.opacity(0.42))
                    .frame(width: 34, height: Self.transactionRowHeight)
            }
            .buttonStyle(.plain)
            .disabled(transaction.voidedAt != nil)
            .accessibilityLabel(transaction.voidedAt != nil ? "归档账目只读" : "选择账目")
            Button {
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { toggleBatchSelection(transaction.id) }
                else { selectTransaction(transaction) }
            } label: {
                HStack(spacing: 12) {
                    Rectangle().fill(transaction.categoryID == nil ? V15Palette.warning.color : Color.clear).frame(width: 3, height: 30)
                    Text(shortDate(transaction.businessDate))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(V15Palette.ink.color.opacity(0.62))
                        .frame(width: 54, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(transaction.title)
                            .font(.system(size: 14, weight: .semibold))
                            .strikethrough(transaction.voidedAt != nil)
                            .lineLimit(1)
                        Text("\(ledger.categoryName(transaction.categoryID)) · \(presentation.accountPath)\(presentation.accountEffect.map { " · \($0)" } ?? "")\(transaction.voidedAt == nil ? "" : " · 归档 · 只读")")
                            .font(.system(size: 13))
                            .foregroundStyle(V15Palette.ink.color.opacity(0.62))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    V15MoneyText(minorUnits: presentation.amountMinor, direction: presentation.direction, includeCurrency: false, font: .system(size: 14, weight: .semibold, design: .monospaced))
                        .frame(width: 128, alignment: .trailing)
                        .minimumScaleFactor(0.78)
                }
                .padding(.trailing, 18).frame(minHeight: 54).contentShape(Rectangle())
            .background((selected || batchSelected) ? V15Palette.selected.color : Color.clear)
            .background { if transaction.voidedAt != nil { V15ArchiveHatch() } }
            .overlay(alignment: .leading) { if selected { Rectangle().fill(V15Palette.teal.color).frame(width: 1) } }
            .overlay { if selected { Rectangle().stroke(V15Palette.teal.color, lineWidth: 1) } }
            .opacity(transaction.voidedAt == nil ? 1 : 0.72)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("v151.mac.transaction.\(transaction.id)")
        }
        .overlay(alignment: .bottom) { Rectangle().fill(V15Palette.hairline.color).frame(height: 1) }
    }

    private var loadMoreRow: some View {
        Button { Task { await ledger.loadNext() } } label: {
            Text(ledger.isLoadingNext ? "正在读取下一页" : "读取下一页").font(.system(size: 13, weight: .semibold)).foregroundStyle(V15Palette.teal.color).frame(maxWidth: .infinity).frame(height: 38)
        }.buttonStyle(.plain).disabled(ledger.isLoadingNext)
    }

    private var spineFooter: some View {
        HStack(spacing: 18) {
            Text("j · k 移动")
            Text("空格 预览")
            Text("⇧ / 复选框 多选")
            Text("⌘↩ 提交")
            Spacer()
            Text("\(spineItemCount) 项")
        }
        .font(.system(size: 11)).foregroundStyle(V15Palette.ink.color.opacity(0.54)).padding(.horizontal, 18).frame(height: 31)
    }

    private var inspectorPane: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if selectedIDs.isEmpty {
                        if let batchResult { batchOutcomeInspector(batchResult) }
                        else { inspectorContent }
                    } else { batchInspector }
                }
                .padding(18)
            }
            if selectedIDs.isEmpty, selectedAccountID == nil, selectedTransaction != nil { inspectorActions }
        }
        .background(V15Palette.card.color)
        .accessibilityIdentifier("v151.mac.inspector")
    }

    private var timelineInspectorVisible: Bool {
        !selectedIDs.isEmpty || selectedAccountID != nil || selectedTransaction != nil || batchResult != nil
    }

    private var batchInspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("批量设置分类").font(.system(size: 20, weight: .bold))
            Text("已选 \(selectedIDs.count) 笔 · 合计 \(V15MoneyPresentation(minorUnits: batchAmount, direction: .neutral).text)")
                .font(.system(size: 13)).foregroundStyle(V15Palette.ink.color.opacity(0.62))
            Picker("目标分类", selection: $batchCategoryID) {
                Text("请选择").tag(Optional<UUID>.none)
                ForEach(ledger.categories) { category in Text(category.name).tag(Optional(category.id)) }
            }
            .pickerStyle(.menu)
            .onChange(of: batchCategoryID) { _, _ in batchPreviewed = false; batchResult = nil; ledger.clearCategoryPreview() }
            if batchPreviewed, let preview = ledger.categoryChangePreview {
                V15ServerFactState(title: "将要修改", detail: preview.items.map { "\($0.title)：\($0.previousCategoryName ?? "未分类") → \($0.proposedCategoryName)" }.joined(separator: "\n"))
            }
            if let result = batchResult {
                batchResultState(result)
            }
            if batchPreviewed {
                V15ActionButton(batchWorking ? "正在提交" : "确认批量设置   ⌘↩", disabledReason: batchWorking ? .init(code: "batch_working", message: "正在提交，请稍候。", fieldPath: nil) : nil) { submitBatchCategory() }
            } else {
                V15ActionButton("查看提交范围", disabledReason: batchCategoryID == nil ? .init(code: "category_required", message: "请先选择目标分类。", fieldPath: nil) : nil) { previewBatchCategory() }
            }
            if let failure = ledger.categoryChangeFailure {
                if V15StateVisualSpec.resolve(failure).semantic == .outcomeUnknown {
                    V15OutcomeUnknownState(message: failure.message, actionTitle: "重新读取账目") { previewBatchCategory() }
                } else {
                    V15ServiceErrorState(message: failure.message) { previewBatchCategory() }
                }
            }
            V15ActionButton("清除选择", kind: .secondary) { selectedIDs.removeAll(); batchResult = nil; batchPreviewed = false }
        }
    }

    private func batchOutcomeInspector(_ result: V15LedgerModel.BatchCategoryResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("批量设置分类").font(.system(size: 20, weight: .bold))
            batchResultState(result)
            V15ActionButton("完成", kind: .secondary) { batchResult = nil }
        }
    }

    private func batchResultState(_ result: V15LedgerModel.BatchCategoryResult) -> some View {
        let retryable = result.failures.filter { !result.committedIDs.contains($0.id) }
        return V15PartialProgressState(
            succeeded: result.queued ? "\(result.committedIDs.count) 笔已加入待同步" : "\(result.committedIDs.count) 笔已完成",
            currentState: result.failures.isEmpty ? "最新账目已刷新" : result.failures.map { "\($0.title)：\($0.message)" }.joined(separator: "\n"),
            remaining: retryable.isEmpty ? "无需重复提交" : "\(retryable.count) 笔尚未提交，可修正后重试"
        )
    }

    @ViewBuilder private var inspectorContent: some View {
        if selectedAccountID != nil {
            accountInspectorContent
        } else {
            switch ledger.detailPhase {
            case .loading: V15LoadingSkeleton(layout: .inspector)
            case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await ledger.retryDetail() } }
            default:
                if let transaction = selectedTransaction { inspector(transaction) }
                else {
                    VStack(spacing: 13) {
                        Spacer(minLength: 100)
                        Image(systemName: "archivebox").font(.system(size: 30, weight: .light)).foregroundStyle(V15Palette.ink.color.opacity(0.50))
                        Text("选择一笔账目或账户").font(.system(size: 24, weight: .bold))
                        Text("这里显示账户余额、账目和历史记录。").font(.system(size: 14)).foregroundStyle(V15Palette.ink.color.opacity(0.58)).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder private var accountInspectorContent: some View {
        switch accountDetail.phase {
        case .idle, .loading:
            V15LoadingSkeleton(layout: .inspector)
        case .failed(let failure):
            V15ServiceErrorState(message: failure.message) {
                if let id = selectedAccountID { Task { await loadAccount(id) } }
            }
        case .loaded:
            if let account = accountDetail.account {
                accountInspector(account)
            } else {
                V15EmptyState(title: "无法显示账户", explanation: "暂时没有取得这个账户的数据。")
            }
        }
    }

    private func accountInspector(_ account: V15AccountResponse) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(account.name).font(.system(size: 18, weight: .semibold))
                    Spacer()
                    if account.archivedAt != nil {
                        Text("归档 · 只读").font(.system(size: 11, weight: .semibold)).foregroundStyle(V15Palette.ink.color.opacity(0.58))
                    }
                }
                V15MoneyText(
                    minorUnits: account.currentBalanceMinor,
                    direction: V151MacAccountBalanceSemantics.direction(account.kind, minorUnits: account.currentBalanceMinor),
                    font: .system(size: 26, weight: .bold, design: .monospaced)
                )
                Text(V151MacAccountBalanceSemantics.amountLabel(account.kind, minorUnits: account.currentBalanceMinor)).font(.system(size: 12)).foregroundStyle(V15Palette.ink.color.opacity(0.58))
            }
            VStack(spacing: 0) {
                fieldRow("类型", value: accountKindLabel(account.kind), emphasized: false)
                fieldRow("机构", value: account.institution ?? "未设置", emphasized: false)
                fieldRow("尾号", value: account.lastFour.map { "•••• \($0)" } ?? "未设置", emphasized: false)
                fieldRow("期初余额", value: V15MoneyPresentation(minorUnits: account.openingBalanceMinor, direction: .neutral).text, emphasized: false)
                if let date = account.openingBalanceAsOfDate { fieldRow("期初日期", value: date, emphasized: false) }
                fieldRow("关联使用", value: "\(account.usageCount) 项", emphasized: false, last: account.kind != .credit)
                if account.kind == .credit {
                    fieldRow("信用额度", value: account.creditLimitMinor.map { V15MoneyPresentation(minorUnits: $0, direction: .neutral).text } ?? (account.cycleMode == "on_demand" ? "不设额度" : "未设置"), emphasized: false)
                    fieldRow("账单日", value: account.statementDay.map { "每月 \($0) 日" } ?? (account.cycleMode == "on_demand" ? "无固定账单日" : "未设置"), emphasized: false)
                    fieldRow("还款日", value: account.dueDay.map { "每月 \($0) 日" } ?? (account.cycleMode == "on_demand" ? "无固定还款日" : "未设置"), emphasized: false, last: true)
                }
            }
            .background(V15Palette.paper.color, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).stroke(V15Palette.hairline.color) }
            if account.archivedAt != nil {
                V15ArchiveReadOnlyState {
                    Text("该账户已归档，只能查看。恢复或编辑请进入设置。")
                        .font(V15Typography.secondary)
                }
            }
            inspectorSection("快捷入口") {
                VStack(spacing: 8) {
                    V15ActionButton("查看账户账目", kind: .secondary) {
                        clearAccountDetailSelection()
                    }
                    if account.kind == .credit {
                        V15ActionButton(account.cycleMode == "on_demand" ? "借入、还款与全额结清" : "进入信用账期", kind: .secondary) { openCredit(accountID: account.id, from: .timeline) }
                            .accessibilityIdentifier("v151.mac.account.open-credit.\(account.id)")
                        if account.cycleMode != "on_demand" { V15ActionButton("查看分期", kind: .secondary) { openInstallments(accountID: account.id, from: .timeline) }
                            .accessibilityIdentifier("v151.mac.account.open-installments.\(account.id)") }
                    }
                    V15ActionButton("打开设置", kind: .secondary) { destination = .settings }
                }
            }
        }
        .accessibilityIdentifier("v151.mac.account.inspector")
    }

    private func inspector(_ transaction: V15Transaction) -> some View {
        let presentation = ledger.transactionPresentation(transaction)
        return VStack(alignment: .leading, spacing: 17) {
            VStack(alignment: .leading, spacing: 6) {
                Text(transaction.title).font(.system(size: 18, weight: .semibold))
                    .accessibilityIdentifier("v220.mac.detail.title.\(transaction.id)")
                V15MoneyText(minorUnits: presentation.amountMinor, direction: presentation.direction, font: .system(size: 28, weight: .bold, design: .monospaced))
                if transaction.categoryID == nil {
                    HStack(spacing: 7) { Rectangle().fill(V15Palette.teal.color).frame(width: 7, height: 7); Text("未分类 · 需要你决定") }
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(V15Palette.teal.color)
                }
                if transaction.voidedAt != nil {
                    Text("归档 · 只读 · 可从底部操作区恢复")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(V15Palette.ink.color.opacity(0.58))
                }
            }
            fieldCard(transaction, presentation: presentation)
            inspectorSection("来源链") {
                HStack(spacing: 8) {
                    Text(sourceLabel(transaction.source)).font(.system(size: 12, weight: .semibold)).foregroundStyle(V15Palette.teal.color).padding(.horizontal, 9).padding(.vertical, 5).background(V15Palette.selected.color, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            specialistRelations(transaction)
            inspectorSection("账本影响") {
                VStack(spacing: 0) {
                    ForEach(transaction.postings, id: \.id) { posting in
                        HStack { Text(ledger.accountName(posting.accountID)); Spacer(); V15MoneyText(minorUnits: posting.amountMinor, direction: posting.amountMinor < 0 ? .outflow : .inflow, includeCurrency: false, font: .system(size: 12, weight: .semibold, design: .monospaced)) }
                            .font(.system(size: 12)).padding(.horizontal, 10).frame(height: 32)
                        Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
                    }
                }.background(V15Palette.paper.color, in: RoundedRectangle(cornerRadius: 7)).overlay { RoundedRectangle(cornerRadius: 7).stroke(V15Palette.hairline.color) }
            }
            inspectorSection("修改历史") {
                if ledger.revisions.isEmpty { Text("暂无可查看的修改历史。") }
                else { ForEach(ledger.revisions.prefix(4)) { revision in Text("\(revision.displayEvent) · \(timeLabel(revision.createdAt))").font(.system(size: 11)).foregroundStyle(V15Palette.ink.color.opacity(0.62)) } }
            }
            mutationState
        }
    }

    private func fieldCard(_ transaction: V15Transaction, presentation: V15AccountTransactionPresentation) -> some View {
        VStack(spacing: 0) {
            fieldRow("类型", value: transactionKindLabel(transaction.kind), emphasized: false)
            fieldRow("账户", value: presentation.accountPath, emphasized: false)
            if let effect = presentation.accountEffect { fieldRow("当前账户影响", value: effect, emphasized: true) }
            fieldRow("分类", value: ledger.categoryName(transaction.categoryID), emphasized: transaction.categoryID == nil)
            fieldRow("业务日期", value: transaction.businessDate, emphasized: false)
            fieldRow("发生时刻", value: timeLabel(transaction.occurredAt), emphasized: false, last: true)
        }
        .background(V15Palette.paper.color, in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).stroke(V15Palette.hairline.color) }
    }

    private func fieldRow(_ title: String, value: String, emphasized: Bool, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack { Text(title).foregroundStyle(V15Palette.ink.color.opacity(0.50)); Spacer(); Text(value).foregroundStyle(emphasized ? V15Palette.teal.color : V15Palette.ink.color).fontWeight(emphasized ? .semibold : .regular) }
                .font(.system(size: 12)).padding(.horizontal, 10).frame(height: 33)
            if !last { Rectangle().fill(V15Palette.hairline.color).frame(height: 1) }
        }
    }

    private func inspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(V15Palette.ink.color.opacity(0.52))
            content()
        }
    }

    private var inspectorActions: some View {
        VStack(spacing: 9) {
            Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
            if selectedTransaction?.categoryID == nil {
                V15ActionButton("设置分类   ⌘↩") {
                    categoryID = nil
                    categoryPresented = true
                }
            }
            if let transaction = selectedTransaction {
                HStack(spacing: 8) {
                    if transaction.reimbursementRelations.isEmpty {
                        V15ActionButton("加入报销", kind: .secondary, disabledReason: reimbursementReason(transaction)) {
                            openReimbursements(transactionID: transaction.id, from: .timeline)
                        }
                        .accessibilityIdentifier("v151.mac.transaction.reimbursement.create.\(transaction.id)")
                    }
                    V15ActionButton(transaction.voidedAt == nil ? "作废" : "恢复", kind: transaction.voidedAt == nil ? .destructive : .secondary, disabledReason: ledger.disabledReason(for: transaction.voidedAt == nil ? .void : .restore, transaction: transaction)) {
                        Task { if transaction.voidedAt == nil { await ledger.voidSelected() } else { await ledger.restoreSelected() } }
                    }
                }
                if let planID = transaction.installmentPlanID ?? transaction.installmentRelation?.planID {
                    V15ActionButton("查看分期", kind: .secondary) {
                        openInstallments(accountID: transaction.accountID, planID: planID, from: .timeline)
                    }
                    .accessibilityIdentifier("v151.mac.transaction.installment.\(planID)")
                } else {
                    V15ActionButton("改为分期", kind: .secondary, disabledReason: installmentReason(transaction)) {
                        openInstallments(accountID: transaction.accountID, purchaseTransactionID: transaction.id, from: .timeline)
                    }
                    .accessibilityIdentifier("v151.mac.transaction.installment.create.\(transaction.id)")
                }
            }
        }
        .padding(14).background(V15Palette.card.color)
    }

    @ViewBuilder private func specialistRelations(_ transaction: V15Transaction) -> some View {
        if transaction.installmentPlanID != nil || transaction.installmentRelation != nil || !transaction.reimbursementRelations.isEmpty {
            inspectorSection("专项关联") {
                VStack(alignment: .leading, spacing: 8) {
                    if let plan = transaction.installmentRelation {
                        V15ActionButton("分期 · \(plan.planTitle)", kind: .secondary) {
                            openInstallments(accountID: transaction.accountID, planID: plan.planID, from: .timeline)
                        }
                        .accessibilityIdentifier("v151.mac.transaction.installment.\(plan.planID)")
                    } else if let planID = transaction.installmentPlanID {
                        V15ActionButton("查看关联分期", kind: .secondary) {
                            openInstallments(accountID: transaction.accountID, planID: planID, from: .timeline)
                        }
                        .accessibilityIdentifier("v151.mac.transaction.installment.\(planID)")
                    }
                    ForEach(Array(transaction.reimbursementRelations.enumerated()), id: \.offset) { _, relation in
                        V15ActionButton("报销 · \(relation.claimTitle)\(relation.partyName.map { " · \($0)" } ?? "")", kind: .secondary) {
                            openReimbursements(claimID: relation.claimID, partyID: relation.partyID, from: .timeline)
                        }
                        .accessibilityIdentifier("v151.mac.transaction.reimbursement.\(relation.claimID).\(relation.partyID?.uuidString ?? "claim")")
                    }
                }
            }
        }
    }

    @ViewBuilder private var mutationState: some View {
        switch ledger.mutation {
        case .idle: EmptyView()
        case .working: V15LoadingSkeleton()
        case .reconciled(let message): V15ServerFactState(title: "待同步状态", detail: message)
        case .conflict(let conflict): V15ConflictState(conflict: conflict, changes: ledger.mutationConflictChanges) { Task { await ledger.retryDetail() } }
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await ledger.retryLastMutation() } }
        }
    }

    private var searchPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("搜索账目").font(.system(size: 14, weight: .semibold))
            HStack(spacing: V15Spacing.xs) {
                Image(systemName: V15Symbol.search).accessibilityHidden(true)
                TextField("搜索账目", text: $searchDraft)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { commitSearch() }
                    .accessibilityIdentifier("v151.mac.ledger.search.draft")
            }
            .padding(V15Spacing.sm)
            .background(V15Palette.paper.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
            .overlay { RoundedRectangle(cornerRadius: V15Radius.control).stroke(V15Palette.hairline.color) }
            HStack {
                V15ActionButton("取消", kind: .secondary) { searchPresented = false }
                Spacer()
                V15ActionButton("搜索") { commitSearch() }
                    .accessibilityIdentifier("v151.mac.ledger.search.apply")
            }
        }
        .padding(16).frame(width: 360)
        .onAppear { searchFocused = true }
        .onExitCommand { searchPresented = false }
    }

    private var categorySheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置分类").font(.system(size: 22, weight: .bold))
            Text(selectedTransaction?.title ?? "账目").font(.system(size: 14)).foregroundStyle(V15Palette.ink.color.opacity(0.60))
            if let categoryCommitNotice {
                V15ServerFactState(title: "分类已保存", detail: categoryCommitNotice)
                V15ActionButton("完成", kind: .secondary) { categoryPresented = false; self.categoryCommitNotice = nil }
            } else {
                Picker("分类", selection: $categoryID) {
                    Text("未分类").tag(Optional<UUID>.none)
                    ForEach(ledger.categories) { category in Text(category.name).tag(Optional(category.id)) }
                }.pickerStyle(.menu).disabled(ledger.categoryChangeIsCommitting).onChange(of: categoryID) { _, _ in categoryPreviewed = false; ledger.clearCategoryPreview() }
                if categoryPreviewed, let preview = ledger.categoryChangePreview {
                    V15ServerFactState(detail: preview.items.map { "\($0.previousCategoryName ?? "未分类") → \($0.proposedCategoryName)" }.joined(separator: "\n"))
                }
                HStack {
                    V15ActionButton(
                        "取消",
                        kind: .secondary,
                        disabledReason: ledger.categoryChangeIsCommitting
                            ? .init(code: "category_commit_in_flight", message: "正在提交分类，请稍候。", fieldPath: nil)
                            : nil
                    ) { categoryPresented = false }
                    if categoryPreviewed {
                        V15ActionButton(
                            ledger.categoryChangeIsCommitting ? "正在提交" : "确认分类   ⌘↩",
                            disabledReason: ledger.categoryChangeIsCommitting
                                ? .init(code: "category_commit_in_flight", message: "正在提交分类，请稍候。", fieldPath: nil)
                                : nil
                        ) { commitCategory() }
                    } else {
                        V15ActionButton("查看分类影响", disabledReason: categoryID == nil ? .init(code: "category_required", message: "请先选择分类。", fieldPath: nil) : (ledger.isOffline ? .init(code: "category_read_requires_network", message: "需要联网取得最新账目。", fieldPath: nil) : nil)) { readCategoryCurrentFact() }
                    }
                }
                if let failure = ledger.categoryChangeFailure {
                    if V15StateVisualSpec.resolve(failure).semantic == .outcomeUnknown {
                        V15OutcomeUnknownState(message: failure.message, actionTitle: "重新读取账目") { readCategoryCurrentFact() }
                    } else {
                        V15ServiceErrorState(message: failure.message) { readCategoryCurrentFact() }
                    }
                }
            }
        }
        .padding(24).frame(width: 420)
    }

    private var modulePane: some View {
        VStack(spacing: 0) {
            if showsModuleHeader {
                moduleHeader
                Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
            }
            moduleContent
        }
    }

    private var showsModuleHeader: Bool {
        switch destination {
        case .overview, .timeline, .accounts, .reports, .settings: false
        default: true
        }
    }

    @ViewBuilder private var moduleHeader: some View {
        switch destination {
        case .overview, .timeline, .accounts: EmptyView()
        case .future:
            secondaryModuleHeader("有来源未来", parent: futureOverviewOrigin)
        case .pendingSync:
            secondaryModuleHeader("待同步", parent: .settings)
        case .reports, .settings: EmptyView()
        case .record: secondaryModuleHeader("记一笔", parent: recordOrigin)
        case .credit: secondaryModuleHeader("信用账期", parent: contextualOrigin.destination)
        case .installments: secondaryModuleHeader("分期", parent: contextualOrigin.destination)
        case .reimbursements: secondaryModuleHeader("报销", parent: contextualOrigin.destination)
        case .cashFlow: secondaryModuleHeader("现金流计划", parent: contextualOrigin.destination)
        }
    }

    private func primaryModuleHeader<Actions: View>(_ title: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold))
                .accessibilityLabel(title)
                .accessibilityIdentifier("v151.mac.module.title")
            Spacer()
            actions()
        }
        .padding(.horizontal, 18).frame(height: 48).background(V15Palette.card.color)
    }

    private func secondaryModuleHeader(_ title: String, parent: Destination) -> some View {
        HStack(spacing: 12) {
            Button {
                returnFromSecondary(to: parent)
            } label: {
                Label("返回\(parent.title)", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("v151.mac.module.back")
            Text(title).font(.system(size: 14, weight: .semibold))
                .accessibilityLabel(title)
                .accessibilityIdentifier("v151.mac.module.title")
            Spacer()
        }
        .padding(.horizontal, 18).frame(height: 48).background(V15Palette.card.color)
    }

    @ViewBuilder private var moduleContent: some View {
        switch destination {
        case .overview: V152MacOverview(
            services: services,
            facts: facts,
            ledger: overviewLedger,
            futureOpenPhase: knownFutureOpenPhase,
            openLedger: { navigateRoot(to: .timeline) },
            openTransaction: openOverviewTransaction,
            openPendingSync: openPendingSync,
            openAllFuture: openFutureOverview,
            openRecord: { openRecord() },
            openReports: { navigateRoot(to: .reports) },
            openFuture: { event in openKnownFuture(event, from: .overview) }
        )
        case .timeline: EmptyView()
        case .accounts: V152MacAccountsHub(ledger: ledger, selectAccount: { id in
            navigateRoot(to: .timeline)
            selectAccount(id)
        }, openSettings: { navigateRoot(to: .settings) }, retry: { Task { await refreshLedgerReferencesAndReconcileSelectedAccount() } })
        case .record: V15RecordView(services: services, onCommitted: recordCommitted)
        case .future:
            V15FutureTimelineMacView(model: futureTimeline, selectedID: $futureTimelineSelectedID) { target in
                openVerifiedFutureTarget(target, from: .future)
            }
        case .credit:
            if case .creditCycle(let cycle) = futureTarget { V15CreditMacView(services: services, initialCycle: cycle) }
            else { V15CreditMacView(services: services, initialAccountID: initialCreditAccountID) }
        case .installments:
            V15InstallmentMacView(
                services: services,
                initialAccountID: initialInstallmentAccountID,
                initialPlanID: initialInstallmentPlanID,
                initialPurchaseTransactionID: initialInstallmentPurchaseTransactionID
            )
        case .reimbursements:
            if case .reimbursementParty(let claim, let partyID) = futureTarget { V15ReimbursementMacView(services: services, initialClaim: claim, initialPartyID: partyID) }
            else {
                V15ReimbursementMacView(
                    services: services,
                    initialClaimID: initialReimbursementClaimID,
                    initialPartyID: initialReimbursementPartyID,
                    initialTransactionID: initialReimbursementTransactionID
                )
            }
        case .cashFlow:
            if case .cashFlowItem(let item) = futureTarget { V15CashFlowMacView(services: services, initialItem: item) }
            else { V15CashFlowMacView(services: services) }
        case .reports: V15ReportingMacView(services: services)
        case .pendingSync: V151MacPendingSyncHub(services: services)
        case .settings:
            V15SettingsView(services: services, onOpenPendingSync: { openPendingSync() })
        }
    }

    private func openVerifiedFutureTarget(_ target: V15FutureOpenTarget, from origin: ContextualOrigin) {
        invalidateKnownFutureOpen()
        clearSpecialistInitialTargets()
        contextualOrigin = origin
        futureTarget = target
        switch target {
        case .creditCycle: destination = .credit
        case .reimbursementParty: destination = .reimbursements
        case .cashFlowItem: destination = .cashFlow
        }
    }

    private func navigateRoot(to value: Destination) {
        let leaving = destination
        invalidateKnownFutureOpen()
        futureTarget = nil
        clearSpecialistInitialTargets()
        destination = value
        if leaving != value, [.overview, .timeline, .accounts].contains(value) || isMutableSpecialist(leaving) {
            Task { await refreshAfterRootNavigation() }
        }
    }

    private func openRecord() {
        recordOrigin = destination
        invalidateKnownFutureOpen()
        futureTarget = nil
        clearSpecialistInitialTargets()
        destination = .record
    }

    private func openFutureOverview() {
        futureOverviewOrigin = destination
        invalidateKnownFutureOpen()
        futureTarget = nil
        clearSpecialistInitialTargets()
        destination = .future
    }

    private func openCredit(accountID: UUID, from origin: ContextualOrigin) {
        invalidateKnownFutureOpen()
        futureTarget = nil
        clearSpecialistInitialTargets()
        contextualOrigin = origin
        initialCreditAccountID = accountID
        destination = .credit
    }

    private func openInstallments(accountID: UUID? = nil, planID: UUID? = nil, purchaseTransactionID: UUID? = nil, from origin: ContextualOrigin) {
        invalidateKnownFutureOpen()
        futureTarget = nil
        clearSpecialistInitialTargets()
        contextualOrigin = origin
        initialInstallmentAccountID = accountID
        initialInstallmentPlanID = planID
        initialInstallmentPurchaseTransactionID = purchaseTransactionID
        destination = .installments
    }

    private func openReimbursements(claimID: UUID? = nil, partyID: UUID? = nil, transactionID: UUID? = nil, from origin: ContextualOrigin) {
        invalidateKnownFutureOpen()
        futureTarget = nil
        clearSpecialistInitialTargets()
        contextualOrigin = origin
        initialReimbursementClaimID = claimID
        initialReimbursementPartyID = partyID
        initialReimbursementTransactionID = transactionID
        destination = .reimbursements
    }

    private func openCashFlow(from origin: ContextualOrigin) {
        invalidateKnownFutureOpen()
        futureTarget = nil
        clearSpecialistInitialTargets()
        contextualOrigin = origin
        destination = .cashFlow
    }

    private func openPendingSync() {
        invalidateKnownFutureOpen()
        futureTarget = nil
        clearSpecialistInitialTargets()
        destination = .pendingSync
    }

    private func returnFromSecondary(to parent: Destination) {
        let leaving = destination
        invalidateKnownFutureOpen()
        futureTarget = nil
        clearSpecialistInitialTargets()
        destination = parent
        if parent == .timeline || ((parent == .overview || parent == .accounts) && isMutableSpecialist(leaving)) {
            Task { await refreshAfterRootNavigation() }
        } else if parent == .future, isMutableSpecialist(leaving) {
            Task {
                async let root: Void = refreshAfterRootNavigation()
                async let future: Void = futureTimeline.reload()
                _ = await (root, future)
            }
        }
    }

    private func isMutableSpecialist(_ value: Destination) -> Bool {
        switch value {
        case .credit, .installments, .reimbursements, .cashFlow, .settings, .pendingSync, .record:
            true
        default:
            false
        }
    }

    private func clearSpecialistInitialTargets() {
        initialCreditAccountID = nil
        initialInstallmentAccountID = nil
        initialInstallmentPlanID = nil
        initialInstallmentPurchaseTransactionID = nil
        initialReimbursementClaimID = nil
        initialReimbursementPartyID = nil
        initialReimbursementTransactionID = nil
    }

    private func invalidateKnownFutureOpen() {
        knownFutureOpenGeneration &+= 1
        knownFutureOpenPhase = .idle
    }

    private func reloadKnownFuture() {
        invalidateKnownFutureOpen()
        Task { await knownFuture.reload() }
    }

    private var selectedTransaction: V15Transaction? {
        ledger.selected ?? selectedID.flatMap { id in ledger.items.first(where: { $0.id == id }) }
    }

    private var accountFilterID: UUID? { accountContext.filterID }
    private var selectedAccountID: UUID? { accountContext.detailID }

    private var filteredAccount: V15AccountResponse? {
        accountFilterID.flatMap { id in ledger.accounts.first(where: { $0.id == id }) }
    }

    private func loadInitialFacts() async {
        invalidateKnownFutureOpen()
        applyLedgerMonthRange(selectedMonth)
        accountContext.clearAllAccounts()
        ledger.setAccount(nil)
        ledger.setIncludeVoided(false)
        ledger.setClassification("all")
        async let references: Void = refreshLedgerReferencesAndReconcileSelectedAccount()
        async let list: Void = ledger.load()
        async let recent: Void = refreshOverviewTransactions()
        async let current: Void = facts.refresh()
        async let future: Void = knownFuture.reload()
        _ = await (references, list, recent, current, future)
    }

    private func recordCommitted(_ outcome: V15RecordModel.CommitOutcome) {
        guard case .confirmed = outcome else { return }
        Task { await refreshAfterConfirmedRecord() }
    }

    @MainActor private func refreshAfterConfirmedRecord() async {
        async let list: Void = ledger.load()
        async let recent: Void = refreshOverviewTransactions()
        async let current: Void = facts.refresh()
        async let future: Void = knownFuture.reload()
        await refreshLedgerReferencesAndReconcileSelectedAccount()
        await refreshSelectedAccountAfterConfirmedRecord()
        _ = await (list, recent, current, future)
    }

    /// Specialist views currently expose no write-confirmation callback.  On a
    /// deliberate return we only re-read server facts; this never presents a
    /// success receipt for a failed or cancelled specialist operation.
    @MainActor private func refreshAfterRootNavigation() async {
        async let list: Void = ledger.load()
        async let recent: Void = refreshOverviewTransactions()
        async let current: Void = facts.refresh()
        async let future: Void = knownFuture.reload()
        await refreshLedgerReferencesAndReconcileSelectedAccount()
        await refreshSelectedAccountAfterConfirmedRecord()
        _ = await (list, recent, current, future)
    }

    @MainActor private func refreshSelectedAccountAfterConfirmedRecord() async {
        guard let id = selectedAccountID else { return }
        await loadAccount(id)
    }

    @MainActor private func refreshLedgerReferencesAndReconcileSelectedAccount() async {
        await ledger.loadReferences()
        guard ledger.referencePhase == .loaded || ledger.referencePhase == .empty else { return }
        let detailWasFilteredAccount = selectedAccountID == accountFilterID
        guard accountContext.clearMissingFilter(availableAccounts: ledger.accounts) != nil
        else { return }
        selectedID = nil
        selectedIDs.removeAll()
        ledger.clearSelection()
        if detailWasFilteredAccount { clearAccountDetailSelection() }
        ledger.setAccount(nil)
        await ledger.load()
    }

    @MainActor private func refreshOverviewTransactions() async {
        // This query belongs to the global overview, never to the workbench's
        // account, month, category or text filters.
        overviewLedger.setClassification("all")
        overviewLedger.setIncludeVoided(false)
        async let references: Void = overviewLedger.loadReferences()
        async let transactions: Void = overviewLedger.load()
        _ = await (references, transactions)
    }

    private func openOverviewTransaction(_ transaction: V15Transaction) {
        selectAllAccounts()
        selectTransaction(transaction)
    }

    private func applyMonth(_ label: String) {
        guard let date = monthParser.date(from: label) else { return }
        selectedID = nil
        selectedIDs.removeAll()
        ledger.clearSelection()
        batchCategoryID = nil
        batchPreviewed = false
        batchWorking = false
        batchResult = nil
        selectedMonth = date
        allLedgerTime = false
        ledger.setIncludeVoided(false)
        ledger.setClassification("all")
        applyLedgerMonthRange(date)
        Task { await ledger.load() }
    }

    private func applyLedgerMonthRange(_ date: Date) {
        guard !allLedgerTime else { return }
        guard let range = V151MacBusinessDateRange.monthDateRange(containing: date) else { return }
        ledger.setDateFrom(range.from)
        ledger.setDateTo(range.to)
    }

    private func selectTransaction(_ transaction: V15Transaction) {
        clearAccountDetailSelection()
        selectedID = transaction.id
        Task { await ledger.select(transaction) }
    }

    private func selectAccount(_ id: UUID) {
        invalidateKnownFutureOpen()
        destination = .timeline
        selectedID = nil
        selectedIDs.removeAll()
        ledger.clearSelection()
        accountContext.selectAccount(id)
        selectedAccount = nil
        accountDetailPhase = .loading
        ledger.setAccount(id)
        Task {
            async let list: Void = ledger.load()
            async let detail: Void = loadAccount(id)
            async let future: Void = knownFuture.setAccount(id)
            _ = await (list, detail, future)
        }
    }

    private func selectAllAccounts() {
        invalidateKnownFutureOpen()
        destination = .timeline
        selectedID = nil
        selectedIDs.removeAll()
        ledger.clearSelection()
        accountContext.clearAllAccounts()
        selectedAccount = nil
        accountDetailPhase = .idle
        accountDetail.clear()
        ledger.setAccount(nil)
        Task {
            async let list: Void = ledger.load()
            async let future: Void = knownFuture.setAccount(nil)
            _ = await (list, future)
        }
    }

    @MainActor private func loadAccount(_ id: UUID) async {
        accountContext.selectDetailAccount(id)
        await accountDetail.load(accountID: id, fresh: true)
        selectedAccount = accountDetail.account
        switch accountDetail.phase { case .idle: accountDetailPhase = .idle; case .loading: accountDetailPhase = .loading; case .loaded: accountDetailPhase = .loaded; case .failed(let failure): accountDetailPhase = .failed(failure) }
    }

    private func clearAccountDetailSelection() {
        accountContext.selectTransaction()
        selectedAccount = nil
        accountDetailPhase = .idle
        accountDetail.clear()
    }

    private func commitSearch() {
        ledger.setQuery(V151MacLedgerSearch.committedQuery(from: searchDraft) ?? "")
        searchPresented = false
        Task { await ledger.load() }
    }

    private func clearSearch() {
        searchDraft = ""
        ledger.setQuery("")
        Task { await ledger.load() }
    }

    private func toggleBatchSelection(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
        batchPreviewed = false
        batchResult = nil
    }

    private func moveSelection(_ offset: Int) {
        guard !ledger.items.isEmpty else { return }
        let current = selectedID.flatMap { id in ledger.items.firstIndex(where: { $0.id == id }) } ?? (offset > 0 ? -1 : ledger.items.count)
        let target = min(max(current + offset, 0), ledger.items.count - 1)
        selectTransaction(ledger.items[target])
    }

    private func previewSelected() {
        guard let transaction = selectedTransaction else { return }
        categoryID = transaction.categoryID
        categoryPreviewed = false
        categoryCommitNotice = nil
        categoryPresented = true
    }

    private func commitCategory() {
        Task {
            let result = await ledger.commitPreviewedCategories()
            if let id = selectedTransaction?.id, result.committedIDs.contains(id) {
                categoryPreviewed = false
                if let warning = result.failures.first(where: { $0.id == id }) {
                    categoryCommitNotice = warning.message
                } else {
                    categoryPresented = false
                }
                await refreshAfterRootNavigation()
            }
        }
    }

    private func readCategoryCurrentFact() {
        guard let id = selectedTransaction?.id, let categoryID else { return }
        Task {
            await ledger.loadDetail(transactionID: id)
            guard case .loaded = ledger.detailPhase else { return }
            await ledger.previewCategories([id], categoryID: categoryID)
            categoryPreviewed = ledger.categoryChangePreview != nil
        }
    }

    private func previewBatchCategory() {
        guard let categoryID = batchCategoryID else { return }
        Task {
            await ledger.previewCategories(selectedIDs, categoryID: categoryID)
            batchPreviewed = ledger.categoryChangePreview != nil
        }
    }

    private func submitBatchCategory() {
        guard batchCategoryID != nil, !batchWorking else { return }
        batchWorking = true
        Task {
            let result = await ledger.commitPreviewedCategories()
            batchResult = result
            selectedIDs.subtract(result.committedIDs)
            batchWorking = false
            batchPreviewed = !selectedIDs.isEmpty && ledger.categoryChangePreview != nil
            if !result.committedIDs.isEmpty {
                await refreshAfterRootNavigation()
            }
        }
    }

    private var batchAmount: Int64 {
        ledger.items.filter { selectedIDs.contains($0.id) }.reduce(0) { $0 + $1.amountMinor }
    }

    private var spineItemCount: Int { visibleTransactions.count }

    private func reimbursementReason(_ transaction: V15Transaction) -> V15DisabledReason? {
        if transaction.voidedAt != nil { return .init(code: "transaction_voided", message: "已作废账目不能加入报销。", fieldPath: nil) }
        if !["expense", "credit_purchase"].contains(transaction.kind) { return .init(code: "not_reimbursable", message: "只有支出或信用消费可加入报销。", fieldPath: nil) }
        if !transaction.reimbursementRelations.isEmpty { return .init(code: "reimbursement_exists", message: "这笔账目已有报销关系。", fieldPath: nil) }
        return nil
    }

    private func installmentReason(_ transaction: V15Transaction) -> V15DisabledReason? {
        if transaction.voidedAt != nil { return .init(code: "transaction_voided", message: "已作废账目不能改为分期。", fieldPath: nil) }
        if transaction.kind != "credit_purchase" { return .init(code: "not_credit_purchase", message: "只有信用消费可改为分期。", fieldPath: nil) }
        if transaction.installmentPlanID != nil || transaction.installmentRelation != nil { return .init(code: "installment_exists", message: "这笔消费已经关联分期。", fieldPath: nil) }
        return nil
    }

    private var keyboardCommands: some View {
        VStack {
            Button("下一笔") {
                guard destination == .timeline else { return }
                moveSelection(1)
            }.keyboardShortcut("j", modifiers: [])
            Button("上一笔") {
                guard destination == .timeline else { return }
                moveSelection(-1)
            }.keyboardShortcut("k", modifiers: [])
            Button("预览") {
                guard destination == .timeline else { return }
                previewSelected()
            }.keyboardShortcut(.space, modifiers: [])
            Button("提交") {
                guard destination == .timeline else { return }
                if categoryPresented, categoryPreviewed { commitCategory() }
                else if batchPreviewed { submitBatchCategory() }
            }.keyboardShortcut(.return, modifiers: .command)
        }
        .frame(width: 1, height: 1)
        .opacity(0.001)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func shiftLedgerMonth(_ offset: Int) {
        guard let date = shanghaiCalendar.date(byAdding: .month, value: offset, to: selectedMonth) else { return }
        applyMonth(monthParser.string(from: date))
    }
    private func applyAllLedgerTime() {
        selectedID = nil; selectedIDs.removeAll(); ledger.clearSelection()
        batchCategoryID = nil; batchPreviewed = false; batchWorking = false; batchResult = nil
        allLedgerTime = true
        ledger.setDateFrom(""); ledger.setDateTo("")
        Task { await ledger.load() }
    }

    private var shanghaiCalendar: Calendar { var value = Calendar(identifier: .gregorian); value.locale = Locale(identifier: "zh_Hans_CN"); value.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return value }
    private var shanghaiBusinessDate: String { let value = DateFormatter(); value.locale = Locale(identifier: "zh_Hans_CN"); value.timeZone = TimeZone(identifier: "Asia/Shanghai"); value.dateFormat = "yyyy-MM-dd"; return value.string(from: Date()) }
    private var monthParser: DateFormatter { let value = DateFormatter(); value.locale = Locale(identifier: "zh_Hans_CN"); value.timeZone = TimeZone(identifier: "Asia/Shanghai"); value.dateFormat = "yyyy 年 M 月"; return value }
    private func shortDate(_ value: String) -> String { value.count >= 5 ? String(value.suffix(5)) : value }
    private func timeLabel(_ value: Date) -> String { let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_Hans_CN"); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "MM-dd HH:mm"; return formatter.string(from: value) }
    private func sourceLabel(_ value: String) -> String { switch value { case "manual": "手工录入"; case "system": "系统生成"; case "ai_text": "AI 文本"; case "ocr": "OCR"; case "legacy_import": "历史导入"; case "cash_flow": "现金流"; case "statement_import": "账单导入"; default: "未知来源" } }
    private func transactionKindLabel(_ value: String) -> String { V15LedgerReadKind(rawValue: value)?.displayName ?? "账目" }
    private func accountKindLabel(_ value: V15AccountKind) -> String { switch value { case .cash: "现金"; case .debit: "储蓄账户"; case .credit: "信用账户"; case .unknown: "未知类型" } }
}

/// V2.2's desktop overview is a reading surface, not a second ledger. Facts
/// remain from one server snapshot and the monthly report keeps its own route,
/// so no unrelated revisions are silently combined here.
private struct V22MacWorkspaceButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule(style: .continuous)
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(primary ? V15Palette.brandInk.color : V15Palette.ink.color)
            .padding(.horizontal, 16)
            .frame(minHeight: 38)
            .background(primary ? V15Palette.yellow.color : V15Palette.card.color, in: shape)
            .overlay {
                shape.fill(V15Palette.teal.color.opacity(isEnabled && (hovered || configuration.isPressed) ? 0.08 : 0))
                    .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(primary ? Color.clear : V15Palette.hairline.color, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct V152MacOverview: View {
    let services: V15Services
    let facts: V15TodayReadModel
    let ledger: V15LedgerModel
    let futureOpenPhase: V151MacWorkspace.KnownFutureOpenPhase
    let openLedger: () -> Void
    let openTransaction: (V15Transaction) -> Void
    let openPendingSync: () -> Void
    let openAllFuture: () -> Void
    let openRecord: () -> Void
    let openReports: () -> Void
    let openFuture: (V15FutureEvent) -> Void
    @State private var report: V15ReportingModel

    init(services: V15Services, facts: V15TodayReadModel, ledger: V15LedgerModel, futureOpenPhase: V151MacWorkspace.KnownFutureOpenPhase, openLedger: @escaping () -> Void, openTransaction: @escaping (V15Transaction) -> Void, openPendingSync: @escaping () -> Void, openAllFuture: @escaping () -> Void, openRecord: @escaping () -> Void, openReports: @escaping () -> Void, openFuture: @escaping (V15FutureEvent) -> Void) {
        self.services = services
        self.facts = facts
        self.ledger = ledger
        self.futureOpenPhase = futureOpenPhase
        self.openTransaction = openTransaction
        self.openPendingSync = openPendingSync
        self.openAllFuture = openAllFuture
        self.openLedger = openLedger
        self.openRecord = openRecord
        self.openReports = openReports
        self.openFuture = openFuture
        _report = State(initialValue: V15ReportingModel(services: services, initialPeriod: V22ReportCalendar.currentMonth(), offlineSnapshotAt: services.offlineSnapshotAt))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let at = facts.offlineSnapshotAt {
                    V15OfflineReadOnlyBanner(snapshotAt: facts.offlineAsOf ?? at, pendingCount: services.pendingWrites.count)
                        .accessibilityIdentifier("v220.mac.overview.offline")
                }
                if services.pendingWrites.count > 0 {
                    HStack {
                        Text("有 \(services.pendingWrites.count) 项更改等待同步；当前金额不包含这些变更。")
                            .font(V15Typography.secondary)
                        Spacer()
                        Button("核验", action: openPendingSync).buttonStyle(.borderless)
                    }
                    .padding(12).background(V15Palette.warningSurface.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
                    .accessibilityIdentifier("v220.mac.overview.pending")
                }
                phaseSurface
            }
            .padding(24)
            .frame(maxWidth: 1_380, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(V15Palette.canvas.color.ignoresSafeArea())
        .task(id: facts.facts?.meta.dataRevision) { await refreshMonthlyReport() }
        .accessibilityIdentifier("v152.mac.overview")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 7) {
                Text("总览")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("把账户、欠款和下一件要处理的事放在同一处。")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.62))
            }
            Spacer(minLength: 20)
            HStack(spacing: 10) {
                Button(action: openReports) { Label("财务分析", systemImage: "chart.line.uptrend.xyaxis") }
                    .buttonStyle(V22MacWorkspaceButtonStyle())
                    .accessibilityIdentifier("v221.mac.overview.analysis")
                Button(action: openRecord) { Label("记一笔", systemImage: "plus") }
                    .buttonStyle(V22MacWorkspaceButtonStyle(primary: true))
                    .keyboardShortcut("n", modifiers: .command)
                    .accessibilityIdentifier("v220.mac.overview.record")
            }
        }
    }

    @ViewBuilder private var phaseSurface: some View {
        switch facts.factsPhase {
        case .idle, .loading:
            V15LoadingSkeleton(layout: .list(rows: 5))
        case .failed(let failure):
            V15ServiceErrorState(message: failure.message) { Task { await facts.refresh() } }
        case .requiresReload(let failure):
            V15ConflictState(conflict: failure.conflict ?? .init(reloadPath: nil, latestRevision: nil, message: failure.message)) {
                Task { await facts.refresh() }
            }
        case .loaded:
            if let snapshot = facts.facts { content(snapshot) }
        }
    }

    private func content(_ snapshot: V15Facts) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            V23DisposableCard(model: facts, dark: true)
            HStack(alignment: .top, spacing: 24) {
                creditMetric(snapshot.credit.currentDebtMinor)
                miniMetric("待收报销总额", snapshot.reimbursements.outstandingMinor, .balance)
                if case .amount(let value) = net(cash: snapshot.cash.currentBalanceMinor, debt: snapshot.credit.currentDebtMinor) {
                    miniMetric("账户净额", value, .balance)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("账户净额")
                        .accessibilityValue(V15MoneyPresentation(minorUnits: value, direction: .balance).text)
                        .accessibilityIdentifier("v220.mac.overview.net")
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    monthlyFlow(snapshot).frame(minWidth: 420, maxWidth: .infinity)
                    upcoming(snapshot).frame(minWidth: 340, maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 18) {
                    upcoming(snapshot)
                    monthlyFlow(snapshot)
                }
            }
            recentTransactions
            dataCare(snapshot)
            Text("更新于 \(V15TodayReadModel.shanghaiDateLabel(snapshot.meta.asOf)) · 上海业务日")
                .font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.52))
        }
    }

    @ViewBuilder private func monthlyFlow(_ snapshot: V15Facts) -> some View {
        if let monthly = report.report, V15OverviewAmountGate.canCombine(factsRevision: snapshot.meta.dataRevision, reportRevision: monthly.meta.dataRevision) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("本月流动").font(V15Typography.cardTitle)
                        Text("\(monthly.meta.dateFrom) 至 \(monthly.meta.dateTo)")
                            .font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.54))
                    }
                    Spacer()
                    Button("完整分析", action: openReports).buttonStyle(.plain).foregroundStyle(V15Palette.teal.color)
                }
                HStack(spacing: 14) {
                    V22Metric("收入", minorUnits: monthly.summary.incomeMinor, direction: .inflow)
                    V22Metric("实际支出", minorUnits: monthly.summary.personalRealizedMinor, direction: .outflow)
                    V22Metric("净收支", minorUnits: monthly.summary.netIncomeExpenseMinor, direction: .balance)
                }
                V22SpendingTrend(points: monthly.daily?.map { .init(date: $0.date, amountMinor: $0.personalRealizedMinor) } ?? [], height: 120)
            }
            .padding(18)
            .v22FormSurface()
        } else if case .failed(let failure) = report.phase {
            reportStatus("本月收支暂时无法读取：\(failure.message)")
        } else if case .requiresReload(let failure) = report.phase {
            reportStatus("本月收支已更新，请刷新后再查看。\(failure.message)")
        } else {
            reportStatus("本月收支正在同步到当前账户快照。")
        }
    }

    @MainActor private func refreshMonthlyReport() async {
        let period = V22ReportCalendar.currentMonth()
        if report.selectedPeriod != period { await report.selectPeriod(period) }
        else { await report.load() }
    }

    private func miniMetric(_ title: String, _ amount: Int64, _ direction: V15MoneyDirection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.55))
            V15MoneyText(minorUnits: amount, direction: direction, font: .system(size: 19, weight: .semibold, design: .monospaced))
        }
    }

    private func creditMetric(_ amount: Int64) -> some View {
        let overpaid = amount < 0
        return miniMetric(overpaid ? "信用溢缴" : "当前信用欠款", amount, overpaid ? .neutral : .outflow)
    }

    private var recentTransactions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("最近交易").font(V15Typography.cardTitle)
                Spacer()
                Button("查看全部", action: openLedger).buttonStyle(.plain).foregroundStyle(V15Palette.teal.color)
            }
            switch ledger.phase {
            case .idle, .loading:
                V15LoadingSkeleton(layout: .compact)
            case .failed(let failure):
                V15ServiceErrorState(message: failure.message) { Task { await ledger.load() } }
            case .empty:
                Text("还没有已发生的交易。")
                    .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.58))
                    .padding(.vertical, 10)
            case .loaded:
                ForEach(ledger.items.prefix(3), id: \.id) { transaction in
                    Button { openTransaction(transaction) } label: {
                        HStack(spacing: 12) {
                            Text(transaction.businessDate).font(.system(size: 12, design: .monospaced)).foregroundStyle(V15Palette.ink.color.opacity(0.56))
                            Text(transaction.title).font(V15Typography.body.weight(.semibold)).lineLimit(1)
                            Spacer(minLength: 10)
                            V15MoneyText(minorUnits: transaction.amountMinor, direction: transactionDirection(transaction), includeCurrency: false, font: V15Typography.money)
                        }
                        .padding(.vertical, 9).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("v220.mac.recent.transaction.\(transaction.id)")
                    .overlay(alignment: .bottom) { Rectangle().fill(V15Palette.hairline.color.opacity(0.65)).frame(height: 1) }
                }
            }
        }
        .padding(18)
        .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.card, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: V15Radius.card, style: .continuous).stroke(V15Palette.hairline.color.opacity(0.8), lineWidth: 1) }
    }

    private func reportStatus(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(V15Palette.warning.color)
            Text(message).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
            Spacer()
            Button("刷新") { Task { await facts.refresh(); await refreshMonthlyReport() } }.buttonStyle(.borderless)
        }
        .padding(18)
        .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.card, style: .continuous))
    }

    private func upcoming(_ snapshot: V15Facts) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("接下来要处理") .font(V15Typography.cardTitle)
                Spacer()
                Button("查看全部", action: openAllFuture).buttonStyle(.plain).foregroundStyle(V15Palette.teal.color)
                    .accessibilityIdentifier("v220.mac.overview.future.all")
            }
            if snapshot.knownFutureEvents.isEmpty {
                Text("当前没有已核验的未来事项。")
                    .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.58))
                    .padding(.vertical, 18)
            } else {
                ForEach(snapshot.knownFutureEvents.prefix(4)) { event in
                    Button { openFuture(event) } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.title).font(V15Typography.body.weight(.semibold)).lineLimit(2)
                            Text(event.date).font(.system(size: 13, design: .monospaced)).foregroundStyle(V15Palette.ink.color.opacity(0.56))
                        }
                        Spacer(minLength: 10)
                        V15MoneyText(minorUnits: event.amountMinor, direction: event.direction == .inflow ? .inflow : .outflow, includeCurrency: false, font: V15Typography.money)
                    }
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) { Rectangle().fill(V15Palette.hairline.color.opacity(0.65)).frame(height: 1) }
                    .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isOpeningFuture)
                    .accessibilityIdentifier("v220.mac.overview.future.\(event.id)")
                    switch futureOpenPhase {
                    case .loading(let id) where id == event.id:
                        ProgressView("正在核验所属记录…")
                    case .failed(let id, let message) where id == event.id:
                        V15ServiceErrorState(message: message, retryIdentifier: "v220.mac.overview.future.retry") { openFuture(event) }
                            .accessibilityIdentifier("v220.mac.overview.future.error.\(event.id)")
                    default: EmptyView()
                    }
                }
            }
        }
        .padding(18)
        .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.card, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: V15Radius.card, style: .continuous).stroke(V15Palette.hairline.color.opacity(0.8), lineWidth: 1) }
    }

    private var isOpeningFuture: Bool {
        if case .loading = futureOpenPhase { return true }
        return false
    }

    private func dataCare(_ snapshot: V15Facts) -> some View {
        HStack(spacing: 24) {
            Text("需要留意").font(V15Typography.label)
            careRow("未分类交易", count: snapshot.completeness.uncategorizedTransactionCount)
            careRow("待处理导入", count: snapshot.completeness.unresolvedImportCount)
            careRow("导入失败", count: snapshot.completeness.failedImportCount)
        }
        .foregroundStyle(V15Palette.ink.color.opacity(0.65))
    }

    private func careRow(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(V15Typography.secondary)
            Text("\(count)").font(V15Typography.money).foregroundStyle(count == 0 ? V15Palette.positive.color : V15Palette.warning.color)
        }
    }

    private func net(cash: Int64, debt: Int64) -> V15OverviewAmountGate.Result { V15OverviewAmountGate.net(cash: cash, debt: debt) }

    private func transactionDirection(_ transaction: V15Transaction) -> V15MoneyDirection {
        switch transaction.kind {
        case "income", "reimbursement_receipt", "borrowing": .inflow
        case "transfer", "credit_principal_waiver", "credit_fee_refund": .neutral
        default: .outflow
        }
    }
}


private struct V152MacAccountsHub: View {
    let ledger: V15LedgerModel
    let selectAccount: (UUID) -> Void
    let openSettings: () -> Void
    let retry: () -> Void
    @State private var query = ""

    private var accounts: [V15AccountResponse] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? ledger.accounts : ledger.accounts.filter { $0.name.localizedCaseInsensitiveContains(term) || ($0.institution?.localizedCaseInsensitiveContains(term) ?? false) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("账户") .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("完整账户列表与余额；信用账户可继续进入账期。") .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.60))
                }
                Spacer()
                Button(action: openSettings) { Label("设置与数据", systemImage: "slider.horizontal.3") }
                    .buttonStyle(V22MacWorkspaceButtonStyle())
                    .accessibilityIdentifier("v221.mac.accounts.settings")
            }
            .padding(28)
            V15SearchField(text: $query, prompt: "搜索账户").padding(.horizontal, 28).padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let at = ledger.offlineSnapshotAt {
                        V15OfflineReadOnlyBanner(snapshotAt: at, pendingCount: 0)
                    }
                    switch ledger.referencePhase {
                    case .idle, .loading:
                        V15LoadingSkeleton(layout: .list(rows: 3))
                    case .failed(let failure):
                        V15ServiceErrorState(message: failure.message, retryIdentifier: "v220.mac.accounts.retry", retry: retry)
                            .accessibilityIdentifier("v220.mac.accounts.error")
                    case .empty:
                        V15EmptyState(title: "还没有账户", explanation: "添加现金、储蓄或信用账户，开始整理账目。")
                            .accessibilityIdentifier("v220.mac.accounts.empty")
                        Button(action: openSettings) { Label("添加账户", systemImage: "plus") }
                            .buttonStyle(V22MacWorkspaceButtonStyle(primary: true))
                    case .loaded:
                        section("现金与储蓄", values: accounts.filter { $0.kind != .credit })
                        section("信用账户", values: accounts.filter { $0.kind == .credit })
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 28)
            }
        }
        .background(V15Palette.canvas.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v152.mac.accounts")
    }

    private func section(_ title: String, values: [V15AccountResponse]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(V15Typography.cardTitle)
            if values.isEmpty {
                Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "还没有这类账户。" : "没有符合当前搜索条件的账户。") .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.56))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(values.enumerated()), id: \.element.id) { index, account in
                        Button { selectAccount(account.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: account.kind == .credit ? "creditcard" : "building.columns")
                                    .foregroundStyle(account.kind == .credit ? V15Palette.outflow.color : V15Palette.teal.color)
                                    .frame(width: 26)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(account.name).font(V15Typography.body.weight(.semibold))
                                    Text(account.institution ?? kind(account.kind)).font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.56))
                                }
                                Spacer()
                                V15MoneyText(minorUnits: account.currentBalanceMinor, direction: V151MacAccountBalanceSemantics.direction(account.kind, minorUnits: account.currentBalanceMinor), font: V15Typography.money)
                                    .frame(minWidth: 112, alignment: .trailing)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(V15Palette.ink.color.opacity(0.38))
                            }
                            .padding(.horizontal, 16).padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < values.count - 1 {
                            Rectangle().fill(V15Palette.hairline.color.opacity(0.8)).frame(height: 1).padding(.leading, 54)
                        }
                    }
                }
                .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.card, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: V15Radius.card, style: .continuous).stroke(V15Palette.hairline.color.opacity(0.8), lineWidth: 1) }
            }
        }
    }

    private func kind(_ value: V15AccountKind) -> String {
        switch value { case .cash: "现金"; case .debit: "储蓄"; case .credit: "信用"; case .unknown: "其他" }
    }
}

private struct V151MacPendingSyncHub: View {
    let services: V15Services
    @State private var payoffAccountID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: V15Spacing.lg) {
                header
                if queuedCount > 0 {
                    V15ActionButton("同步全部（\(queuedCount)）", kind: .secondary, disabledReason: replayDisabledReason) {
                        Task { await services.pendingWrites.replay(using: services) }
                    }
                    .accessibilityIdentifier("v151.mac.pending-sync.replay-all")
                }
                if let failure = services.pendingWrites.storageFailure { Text(failure.message).foregroundStyle(V15Palette.outflow.color) }
                if services.pendingWrites.items.isEmpty {
                    V15EmptyState(title: "没有待同步项目", explanation: "离线记账和离线分类决定会出现在这里。")
                        .v15MacPanel()
                } else {
                    ForEach(services.pendingWrites.items) { item in
                        pendingCard(item)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .v15MacWorkspaceCanvas()
        .sheet(isPresented: Binding(get: { payoffAccountID != nil }, set: { if !$0 { payoffAccountID = nil } })) {
            if let payoffAccountID { V15CreditPayoffView(services: services, accountID: payoffAccountID, accountName: "恢复原账户结清") }
        }
        .accessibilityIdentifier("v151.mac.pending-sync")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("待同步").font(V15Typography.surfaceTitle)
            Text("这里收纳离线记账、离线分类和结果不明的更改。")
                .font(V15Typography.secondary)
                .foregroundStyle(V15Palette.ink.color.opacity(0.64))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .v15MacPanel()
    }

    private var queuedCount: Int {
        services.pendingWrites.items.filter { $0.status == .queued }.count
    }

    private var replayDisabledReason: V15DisabledReason? {
        guard services.offlineSnapshotAt != nil else { return nil }
        return .init(code: "offline_read_only", message: "离线时不能同步；联网后可继续重试。", fieldPath: nil)
    }

    private func pendingCard(_ item: V15PendingWriteStore.Item) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(pendingMarker(item.status)).frame(width: 3, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.headline).lineLimit(2)
                    Text("\(kindLabel(item.kind)) · \(statusLabel(item))")
                        .font(.caption)
                        .foregroundStyle(V15Palette.ink.color.opacity(0.60))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let amount = item.amountMinor {
                    V15MoneyText(minorUnits: amount, direction: .neutral, includeCurrency: false, font: .subheadline.weight(.semibold).monospacedDigit())
                }
            }
            if item.status == .requiresDecision || item.status == .outcomeUnknown {
                Text("原请求已保留。请读取回执核对；未确认结果前不要另建相同账目。")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            V15AdaptiveStack(spacing: 8) {
                if item.status == .queued || item.status == .failed {
                    V15ActionButton(item.status == .queued ? "同步" : "重试同步", kind: .secondary, disabledReason: replayDisabledReason) {
                        services.pendingWrites.retry(item.id)
                        Task { await services.pendingWrites.replay(using: services) }
                    }
                    .accessibilityIdentifier(item.status == .queued ? "v151.mac.pending-sync.sync.\(item.id)" : "v151.mac.pending-sync.retry.\(item.id)")
                }
                if (item.kind == .creditPayoff || item.kind == .creditPayoffReverse), let accountID = item.resourceID {
                    V15ActionButton("打开账户结清恢复", symbol: "arrow.clockwise", kind: .secondary) { payoffAccountID = accountID }
                } else if item.status == .outcomeUnknown {
                    V15ActionButton("读取原操作回执", kind: .secondary) { Task { _ = await services.pendingWrites.recover(item.id, using: services) } }
                    if item.kind == .transactionCreate || item.kind == .repayment {
                        V15ActionButton("按原请求安全重试", kind: .secondary) { Task { _ = await services.pendingWrites.replayUnknown(item.id, using: services) } }
                    }
                }
                if item.status != .outcomeUnknown && item.status != .syncing {
                    V15ActionButton("移除", kind: .secondary) { services.pendingWrites.remove(item.id) }
                }
            }
        }
        .padding(14)
        .v15MacPanel()
    }

    private func pendingMarker(_ status: V15PendingWriteStore.Status) -> Color {
        switch status {
        case .queued, .syncing: V15Palette.provisionalMarker.color
        case .requiresDecision: V15Palette.warning.color
        case .outcomeUnknown: V15Palette.unknown.color
        case .failed: V15Palette.danger.color
        }
    }

    private func kindLabel(_ value: V15PendingWriteStore.Kind) -> String { switch value { case .transactionCreate: "新建账目"; case .categoryReplace: "分类决定"; case .repayment: "还款"; case .creditPayoff: "全额结清"; case .creditPayoffReverse: "撤销整组结清"; case .statementProviderAttempt: "账单解析"; case .statementConfirmation: "账单确认" } }
    private func statusLabel(_ item: V15PendingWriteStore.Item) -> String {
        let value: String
        switch item.status { case .queued: value = "排队中"; case .syncing: value = "同步中"; case .requiresDecision: value = "需要重新决定"; case .outcomeUnknown: value = "结果不明"; case .failed: value = "同步失败" }
        return item.message.map { "\(value) · \($0)" } ?? value
    }
}

#endif
