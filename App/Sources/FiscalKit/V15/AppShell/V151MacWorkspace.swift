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

enum V151MacLedgerSearch {
    static func committedQuery(from draft: String) -> String? {
        draft.isEmpty ? nil : draft
    }
}

/// v1.5.2 keeps the user-approved macOS prototype as the formal live root.
/// It keeps the V15 services and models, but owns every visible navigation and
/// layout decision instead of inheriting the system split-view appearance.
public struct V151MacWorkspace: View {
    private enum Destination: String, Identifiable {
        case ledger, record, future, credit, installments, reimbursements, cashFlow
        case proposals, statementImport, reports, archive, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ledger: "账目"
            case .record: "记一笔"
            case .future: "未来现金流"
            case .credit: "信用账期"
            case .installments: "分期"
            case .reimbursements: "报销"
            case .cashFlow: "现金流"
            case .proposals: "AI 待确认"
            case .statementImport: "账单导入"
            case .reports: "报表"
            case .archive: "系统与数据"
            case .settings: "设置"
            }
        }
    }

    private enum AccountDetailPhase: Equatable {
        case idle, loading, loaded, failed(V15Failure)
    }

    private static let transactionRowHeight: CGFloat = 39

    private let services: V15Services
    @State private var ledger: V15LedgerModel
    @State private var facts: V15TodayReadModel
    @State private var destination: Destination = .ledger
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
    /// The only owner of the ledger's account filter.  It intentionally remains
    /// active while a transaction is selected or the account inspector closes.
    @State private var accountContext = V151MacLedgerAccountContext()
    @State private var selectedAccount: V15AccountResponse?
    @State private var accountDetailPhase: AccountDetailPhase = .idle
    @State private var accountDetail: V15AccountDetailModel
    @State private var searchDraft = ""
    @State private var futureTarget: V15FutureOpenTarget?
    @Environment(\.colorScheme) private var colorScheme

    public init(services: V15Services) {
        self.services = services
        _ledger = State(initialValue: V15LedgerModel(services: services))
        _accountDetail = State(initialValue: V15AccountDetailModel(services: services))
        _facts = State(initialValue: V15TodayReadModel(services: services, offlineSnapshotProvider: { services.offlineSnapshotAt }))
    }

    public var body: some View {
        workspace
        .frame(minWidth: 1_000, minHeight: 680)
        .background(V15Palette.paper.color)
        .tint(V15Palette.teal.color)
        .task { await loadInitialFacts() }
        .popover(isPresented: $searchPresented, arrowEdge: .top) { searchPopover }
        .sheet(isPresented: $categoryPresented) { categorySheet }
        .overlay {
            if destination == .ledger {
                keyboardCommands
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v151.mac.workspace")
    }

    private var workspace: some View {
        GeometryReader { proxy in
            let narrow = proxy.size.width < 1_180
            HStack(spacing: 0) {
                indexPane.frame(width: narrow ? 184 : 208)
                Rectangle().fill(V15Palette.hairline.color).frame(width: 1)
                if destination == .ledger {
                    spinePane.frame(minWidth: narrow ? 420 : 500, maxWidth: .infinity)
                    Rectangle().fill(V15Palette.hairline.color).frame(width: 1)
                    inspectorPane.frame(width: narrow ? 280 : 320)
                } else {
                    modulePane.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var indexPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                moduleNavigation("流水", symbol: "list.bullet", destination: .ledger)
                moduleNavigation("未来现金流", symbol: "calendar", destination: .future)
                moduleNavigation("报表", symbol: "chart.bar", destination: .reports)
                moduleNavigation("系统与数据", symbol: "tray.full", destination: .archive)
                moduleNavigation("设置", symbol: "gearshape", destination: .settings)
            }
            .padding(12)
            Spacer()
        }
        .background(V15Palette.card.color)
    }

    private func moduleNavigation(_ title: String, symbol: String, destination value: Destination) -> some View {
        Button { futureTarget = nil; destination = value } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: destination == value ? .semibold : .regular))
                .foregroundStyle(destination == value ? Color.white : V15Palette.ink.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).frame(height: 34)
                .background(destination == value ? V15Palette.teal.color : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("v151.mac.module.\(value.rawValue)")
    }

    private var spinePane: some View {
        VStack(spacing: 0) {
            spineSummary
            Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    if let snapshotAt = ledger.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: snapshotAt, pendingCount: services.pendingWrites.count).padding(12) }
                    transactionRows
                    if ledger.nextCursor != nil { loadMoreRow }
                }
            }
            Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
            spineFooter
        }
        .background(V15Palette.paper.color)
    }

    private var spineSummary: some View {
        HStack(spacing: 10) {
            Text("流水").font(.system(size: 15, weight: .semibold))
                .accessibilityIdentifier("v151.mac.ledger.title")
            Menu(periodLabel) {
                ForEach(monthChoices, id: \.self) { month in
                    Button(month) { applyMonth(month) }
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .menuStyle(.borderlessButton)
            Menu {
                Button("全部账户") { selectAllAccounts() }
                Divider()
                ForEach(ledger.accounts) { account in
                    Button(account.name) { selectAccount(account.id) }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(filteredAccount?.name ?? "全部账户").lineLimit(1)
                    if let account = filteredAccount {
                        V15MoneyText(minorUnits: account.currentBalanceMinor, direction: account.kind == .credit ? .outflow : .balance, includeCurrency: false, font: .system(size: 11, weight: .semibold, design: .monospaced))
                    } else if let value = facts.facts?.cash.currentBalanceMinor {
                        V15MoneyText(minorUnits: value, direction: .balance, includeCurrency: false, font: .system(size: 11, weight: .semibold, design: .monospaced))
                    }
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .menuStyle(.borderlessButton)
            Spacer(minLength: 8)
            if let query = ledger.filter.query {
                Text("搜索：\(query)")
                    .font(.system(size: 11, weight: .medium))
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
            }
            V15ActionButton("记一笔") { destination = .record }
                .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.horizontal, 18).frame(minHeight: 48)
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
                Rectangle().fill(transaction.categoryID == nil ? V15Palette.teal.color : Color.clear).frame(width: 3, height: 24)
                Text(shortDate(transaction.businessDate)).font(.system(size: 11, design: .monospaced)).foregroundStyle(V15Palette.ink.color.opacity(0.56)).frame(width: 46, alignment: .leading)
                Text(transaction.title).font(.system(size: 13, weight: .medium)).strikethrough(transaction.voidedAt != nil).lineLimit(1)
                Text("· \(ledger.categoryName(transaction.categoryID)) · \(presentation.accountPath)\(presentation.accountEffect.map { " · \($0)" } ?? "")\(transaction.voidedAt == nil ? "" : " · 归档 · 只读")")
                    .font(.system(size: 12)).foregroundStyle(V15Palette.ink.color.opacity(0.70)).lineLimit(1)
                Spacer(minLength: 8)
                V15MoneyText(minorUnits: presentation.amountMinor, direction: presentation.direction, includeCurrency: false, font: .system(size: 12, weight: .semibold, design: .monospaced))
            }
            .padding(.trailing, 18).frame(height: Self.transactionRowHeight).contentShape(Rectangle())
            .background((selected || batchSelected) ? V15Palette.selected.color : Color.clear)
            .background { if transaction.voidedAt != nil { V15ArchiveHatch() } }
            .overlay(alignment: .leading) { if selected { Rectangle().fill(V15Palette.teal.color).frame(width: 1) } }
            .overlay { if selected { Rectangle().stroke(V15Palette.teal.color, lineWidth: 1) } }
            .opacity(transaction.voidedAt == nil ? 1 : 0.72)
            }
            .buttonStyle(.plain)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(V15Palette.hairline.color).frame(height: 1) }
    }

    private var loadMoreRow: some View {
        Button { Task { await ledger.loadNext() } } label: {
            Text(ledger.isLoadingNext ? "正在读取下一页" : "读取下一页").font(.system(size: 12, weight: .semibold)).foregroundStyle(V15Palette.teal.color).frame(maxWidth: .infinity).frame(height: 38)
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
        .font(.system(size: 10)).foregroundStyle(V15Palette.ink.color.opacity(0.54)).padding(.horizontal, 18).frame(height: 31)
    }

    private var inspectorPane: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("详情").font(.system(size: 10, weight: .medium)).foregroundStyle(V15Palette.ink.color.opacity(0.52))
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
    }

    private var batchInspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("批量设置分类").font(.system(size: 20, weight: .bold))
            Text("已选 \(selectedIDs.count) 笔 · 合计 \(V15MoneyPresentation(minorUnits: batchAmount, direction: .neutral).text)")
                .font(.system(size: 12)).foregroundStyle(V15Palette.ink.color.opacity(0.62))
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
            if let failure = ledger.categoryChangeFailure { V15ServiceErrorState(message: failure.message) { previewBatchCategory() } }
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
                        Text("归档 · 只读").font(.system(size: 10, weight: .semibold)).foregroundStyle(V15Palette.ink.color.opacity(0.58))
                    }
                }
                V15MoneyText(minorUnits: account.currentBalanceMinor, direction: account.kind == .credit ? .outflow : .balance, font: .system(size: 26, weight: .bold, design: .monospaced))
                Text("当前余额").font(.system(size: 11)).foregroundStyle(V15Palette.ink.color.opacity(0.58))
            }
            VStack(spacing: 0) {
                fieldRow("类型", value: accountKindLabel(account.kind), emphasized: false)
                fieldRow("机构", value: account.institution ?? "未设置", emphasized: false)
                fieldRow("尾号", value: account.lastFour.map { "•••• \($0)" } ?? "未设置", emphasized: false)
                fieldRow("期初余额", value: V15MoneyPresentation(minorUnits: account.openingBalanceMinor, direction: .neutral).text, emphasized: false)
                if let date = account.openingBalanceAsOfDate { fieldRow("期初日期", value: date, emphasized: false) }
                fieldRow("关联使用", value: "\(account.usageCount) 项", emphasized: false, last: account.kind != .credit)
                if account.kind == .credit {
                    fieldRow("信用额度", value: account.creditLimitMinor.map { V15MoneyPresentation(minorUnits: $0, direction: .neutral).text } ?? "未设置", emphasized: false)
                    fieldRow("账单日", value: account.statementDay.map { "每月 \($0) 日" } ?? "未设置", emphasized: false)
                    fieldRow("还款日", value: account.dueDay.map { "每月 \($0) 日" } ?? "未设置", emphasized: false, last: true)
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
                        V15ActionButton("进入信用账期", kind: .secondary) { destination = .credit }
                    }
                    V15ActionButton("打开设置", kind: .secondary) { destination = .settings }
                }
            }
        }
    }

    private func inspector(_ transaction: V15Transaction) -> some View {
        let presentation = ledger.transactionPresentation(transaction)
        return VStack(alignment: .leading, spacing: 17) {
            VStack(alignment: .leading, spacing: 6) {
                Text(transaction.title).font(.system(size: 18, weight: .semibold))
                V15MoneyText(minorUnits: presentation.amountMinor, direction: presentation.direction, font: .system(size: 28, weight: .bold, design: .monospaced))
                if transaction.categoryID == nil {
                    HStack(spacing: 7) { Rectangle().fill(V15Palette.teal.color).frame(width: 7, height: 7); Text("未分类 · 需要你决定") }
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(V15Palette.teal.color)
                }
                if transaction.voidedAt != nil {
                    Text("归档 · 只读 · 可从底部操作区恢复")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(V15Palette.ink.color.opacity(0.58))
                }
            }
            fieldCard(transaction, presentation: presentation)
            inspectorSection("来源链") {
                HStack(spacing: 8) {
                    Text(sourceLabel(transaction.source)).font(.system(size: 11, weight: .semibold)).foregroundStyle(V15Palette.teal.color).padding(.horizontal, 9).padding(.vertical, 5).background(V15Palette.selected.color, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            inspectorSection("账本影响") {
                VStack(spacing: 0) {
                    ForEach(transaction.postings, id: \.id) { posting in
                        HStack { Text(ledger.accountName(posting.accountID)); Spacer(); V15MoneyText(minorUnits: posting.amountMinor, direction: posting.amountMinor < 0 ? .outflow : .inflow, includeCurrency: false, font: .system(size: 11, weight: .semibold, design: .monospaced)) }
                            .font(.system(size: 11)).padding(.horizontal, 10).frame(height: 32)
                        Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
                    }
                }.background(V15Palette.paper.color, in: RoundedRectangle(cornerRadius: 7)).overlay { RoundedRectangle(cornerRadius: 7).stroke(V15Palette.hairline.color) }
            }
            inspectorSection("修改历史") {
                if ledger.revisions.isEmpty { Text("暂无可查看的修改历史。") }
                else { ForEach(ledger.revisions.prefix(4)) { revision in Text("\(revision.displayEvent) · \(timeLabel(revision.createdAt))").font(.system(size: 10)).foregroundStyle(V15Palette.ink.color.opacity(0.62)) } }
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
                .font(.system(size: 11)).padding(.horizontal, 10).frame(height: 33)
            if !last { Rectangle().fill(V15Palette.hairline.color).frame(height: 1) }
        }
    }

    private func inspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(V15Palette.ink.color.opacity(0.52))
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
                    V15ActionButton("加入报销", kind: .secondary, disabledReason: reimbursementReason(transaction)) { destination = .reimbursements }
                    V15ActionButton(transaction.voidedAt == nil ? "作废" : "恢复", kind: .secondary, disabledReason: ledger.disabledReason(for: transaction.voidedAt == nil ? .void : .restore, transaction: transaction)) {
                        Task { if transaction.voidedAt == nil { await ledger.voidSelected() } else { await ledger.restoreSelected() } }
                    }
                }
                V15ActionButton("改为分期", kind: .secondary, disabledReason: installmentReason(transaction)) { destination = .installments }
            }
        }
        .padding(14).background(V15Palette.card.color)
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
            V15SearchField(text: $searchDraft)
                .accessibilityIdentifier("v151.mac.ledger.search.draft")
            HStack {
                V15ActionButton("取消", kind: .secondary) { searchPresented = false }
                Spacer()
                V15ActionButton("搜索") { commitSearch() }
                    .accessibilityIdentifier("v151.mac.ledger.search.apply")
            }
        }
        .padding(16).frame(width: 360)
    }

    private var categorySheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置分类").font(.system(size: 22, weight: .bold))
            Text(selectedTransaction?.title ?? "账目").font(.system(size: 13)).foregroundStyle(V15Palette.ink.color.opacity(0.60))
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
                if let failure = ledger.categoryChangeFailure { V15ServiceErrorState(message: failure.message) { readCategoryCurrentFact() } }
            }
        }
        .padding(24).frame(width: 420)
    }

    private var modulePane: some View {
        VStack(spacing: 0) {
            moduleHeader
            Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
            moduleContent
        }
    }

    @ViewBuilder private var moduleHeader: some View {
        switch destination {
        case .ledger: EmptyView()
        case .future:
            primaryModuleHeader("未来现金流") {
                V15ActionButton("现金流计划", kind: .secondary) { destination = .cashFlow }
                V15ActionButton("信用账期", kind: .secondary) { destination = .credit }
                V15ActionButton("分期", kind: .secondary) { destination = .installments }
                    .accessibilityIdentifier("v151.mac.future.installments")
                V15ActionButton("报销", kind: .secondary) { destination = .reimbursements }
            }
        case .reports: primaryModuleHeader("报表") { EmptyView() }
        case .archive:
            primaryModuleHeader("系统与数据") {
                V15ActionButton("AI 待确认", kind: .secondary) { destination = .proposals }
                    .accessibilityIdentifier("v151.mac.system.ai-proposals")
                V15ActionButton("账单导入", kind: .secondary) { destination = .statementImport }
                    .accessibilityIdentifier("v151.mac.system.statement-import")
            }
        case .settings: primaryModuleHeader("设置") { EmptyView() }
        case .record: secondaryModuleHeader("记一笔", parent: .ledger)
        case .credit: secondaryModuleHeader("信用账期", parent: .future)
        case .installments: secondaryModuleHeader("分期", parent: .future)
        case .reimbursements: secondaryModuleHeader("报销", parent: .future)
        case .cashFlow: secondaryModuleHeader("现金流计划", parent: .future)
        case .proposals: secondaryModuleHeader("AI 待确认", parent: .archive)
        case .statementImport: secondaryModuleHeader("账单导入", parent: .archive)
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
                futureTarget = nil
                destination = parent
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
        case .ledger: EmptyView()
        case .record: V15RecordView(services: services, onCommitted: recordCommitted)
        case .future:
            V15FutureTimelineMacView(services: services, onOpen: openVerifiedFutureTarget)
        case .credit:
            if case .creditCycle(let cycle) = futureTarget { V15CreditMacView(services: services, initialCycle: cycle) }
            else { V15CreditMacView(services: services) }
        case .installments: V15InstallmentMacView(services: services)
        case .reimbursements:
            if case .reimbursementParty(let claim, let partyID) = futureTarget { V15ReimbursementMacView(services: services, initialClaim: claim, initialPartyID: partyID) }
            else { V15ReimbursementMacView(services: services) }
        case .cashFlow:
            if case .cashFlowItem(let item) = futureTarget { V15CashFlowMacView(services: services, initialItem: item) }
            else { V15CashFlowMacView(services: services) }
        case .proposals: V15AIProposalMacView(services: services)
        case .statementImport: V15StatementImportMacView(services: services)
        case .reports: V15ReportingMacView(services: services)
        case .archive: V15DataSecurityMacView(services: services)
        case .settings: V15SettingsView(services: services)
        }
    }

    private func openVerifiedFutureTarget(_ target: V15FutureOpenTarget) {
        futureTarget = target
        switch target {
        case .creditCycle: destination = .credit
        case .reimbursementParty: destination = .reimbursements
        case .cashFlowItem: destination = .cashFlow
        }
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
        applyLedgerMonthRange(selectedMonth)
        accountContext.clearAllAccounts()
        ledger.setAccount(nil)
        ledger.setIncludeVoided(false)
        ledger.setClassification("all")
        async let references: Void = refreshLedgerReferencesAndReconcileSelectedAccount()
        async let list: Void = ledger.load()
        async let current: Void = facts.refresh()
        _ = await (references, list, current)
    }

    private func recordCommitted(_ outcome: V15RecordModel.CommitOutcome) {
        guard case .confirmed = outcome else { return }
        Task { await refreshAfterConfirmedRecord() }
    }

    @MainActor private func refreshAfterConfirmedRecord() async {
        async let list: Void = ledger.load()
        async let current: Void = facts.refresh()
        await refreshLedgerReferencesAndReconcileSelectedAccount()
        await refreshSelectedAccountAfterConfirmedRecord()
        _ = await (list, current)
    }

    @MainActor private func refreshSelectedAccountAfterConfirmedRecord() async {
        guard let id = selectedAccountID else { return }
        await loadAccount(id)
    }

    @MainActor private func refreshLedgerReferencesAndReconcileSelectedAccount() async {
        await ledger.loadReferences()
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
        ledger.setIncludeVoided(false)
        ledger.setClassification("all")
        applyLedgerMonthRange(date)
        Task { await ledger.load() }
    }

    private func applyLedgerMonthRange(_ date: Date) {
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
        destination = .ledger
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
            _ = await (list, detail)
        }
    }

    private func selectAllAccounts() {
        selectedID = nil
        selectedIDs.removeAll()
        ledger.clearSelection()
        accountContext.clearAllAccounts()
        selectedAccount = nil
        accountDetailPhase = .idle
        accountDetail.clear()
        ledger.setAccount(nil)
        Task { await ledger.load() }
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
                guard destination == .ledger else { return }
                moveSelection(1)
            }.keyboardShortcut("j", modifiers: [])
            Button("上一笔") {
                guard destination == .ledger else { return }
                moveSelection(-1)
            }.keyboardShortcut("k", modifiers: [])
            Button("预览") {
                guard destination == .ledger else { return }
                previewSelected()
            }.keyboardShortcut(.space, modifiers: [])
            Button("提交") {
                guard destination == .ledger else { return }
                if categoryPresented, categoryPreviewed { commitCategory() }
                else if batchPreviewed { submitBatchCategory() }
            }.keyboardShortcut(.return, modifiers: .command)
        }
        .frame(width: 1, height: 1)
        .opacity(0.001)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private var periodLabel: String { monthParser.string(from: selectedMonth) }
    private var monthChoices: [String] { (0..<4).compactMap { offset in shanghaiCalendar.date(byAdding: .month, value: -offset, to: Date()).map { monthParser.string(from: $0) } } }

    private var shanghaiCalendar: Calendar { var value = Calendar(identifier: .gregorian); value.locale = Locale(identifier: "zh_Hans_CN"); value.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return value }
    private var monthParser: DateFormatter { let value = DateFormatter(); value.locale = Locale(identifier: "zh_Hans_CN"); value.timeZone = TimeZone(identifier: "Asia/Shanghai"); value.dateFormat = "yyyy 年 M 月"; return value }
    private func shortDate(_ value: String) -> String { value.count >= 5 ? String(value.suffix(5)) : value }
    private func timeLabel(_ value: Date) -> String { let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_Hans_CN"); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "MM-dd HH:mm"; return formatter.string(from: value) }
    private func sourceLabel(_ value: String) -> String { switch value { case "manual": "手工录入"; case "system": "系统生成"; case "ai_text": "AI 文本"; case "ocr": "OCR"; case "legacy_import": "历史导入"; case "cash_flow": "现金流"; case "statement_import": "账单导入"; default: "未知来源" } }
    private func transactionKindLabel(_ value: String) -> String { V15LedgerReadKind(rawValue: value)?.displayName ?? "账目" }
    private func accountKindLabel(_ value: V15AccountKind) -> String { switch value { case .cash: "现金"; case .debit: "储蓄账户"; case .credit: "信用账户"; case .unknown: "未知类型" } }
}

#endif
