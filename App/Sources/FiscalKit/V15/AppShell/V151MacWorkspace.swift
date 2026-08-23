import Foundation
import SwiftUI

#if os(macOS)
import AppKit

/// v1.5.2 keeps the user-approved macOS prototype as the formal live root.
/// It keeps the V15 services and models, but owns every visible navigation and
/// layout decision instead of inheriting the system split-view appearance.
public struct V151MacWorkspace: View {
    private enum Destination: String, Identifiable {
        case ledger, record, future, credit, installments, reimbursements, cashFlow
        case reconciliation, proposals, statementImport, reports, archive, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ledger: "账目"
            case .record: "记一笔"
            case .future: "未来时间线"
            case .credit: "信用账期"
            case .installments: "分期"
            case .reimbursements: "报销"
            case .cashFlow: "现金流"
            case .reconciliation: "核对"
            case .proposals: "AI 待确认"
            case .statementImport: "账单导入"
            case .reports: "报表与钻取"
            case .archive: "系统与数据"
            case .settings: "设置"
            }
        }
    }

    private enum Lens: String, CaseIterable, Identifiable {
        case uncategorized, decisions, pendingSync, credit, reimbursements, imports, archive
        var id: String { rawValue }
        var title: String {
            switch self {
            case .uncategorized: "未分类"
            case .decisions: "需要决定"
            case .pendingSync: "待同步"
            case .credit: "本月信用"
            case .reimbursements: "待收报销"
            case .imports: "导入批次"
            case .archive: "归档"
            }
        }
    }

    private enum AccountDetailPhase: Equatable {
        case idle, loading, loaded, failed(V15Failure)
    }

    private enum Density: String, CaseIterable, Identifiable {
        case compact, comfortable
        var id: String { rawValue }
        var title: String { self == .compact ? "紧凑" : "舒适" }
        var rowHeight: CGFloat { self == .compact ? 39 : 49 }
    }

    private let services: V15Services
    @State private var ledger: V15LedgerModel
    @State private var facts: V15TodayReadModel
    @State private var destination: Destination = .ledger
    @State private var lens: Lens = .uncategorized
    @State private var density: Density = .compact
    @State private var selectedID: UUID?
    @State private var selectedIDs: Set<UUID> = []
    @State private var searchPresented = false
    @State private var categoryPresented = false
    @State private var categoryID: UUID?
    @State private var categoryPreviewed = false
    @State private var batchCategoryID: UUID?
    @State private var batchPreviewed = false
    @State private var batchWorking = false
    @State private var batchResult: V15LedgerModel.BatchCategoryResult?
    @State private var selectedMonth = Date()
    @State private var monthReport: V15PeriodReport?
    @State private var monthReportGeneration: UInt64 = 0
    @State private var selectedAccountID: UUID?
    @State private var selectedAccount: V15AccountResponse?
    @State private var accountDetailPhase: AccountDetailPhase = .idle
    @State private var accountGeneration: UInt64 = 0
    @Environment(\.colorScheme) private var colorScheme

    public init(services: V15Services) {
        self.services = services
        _ledger = State(initialValue: V15LedgerModel(services: services))
        _facts = State(initialValue: V15TodayReadModel(services: services, offlineSnapshotProvider: { services.offlineSnapshotAt }))
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
            if destination == .ledger { ledgerWorkspace }
            else { takeover }
        }
        .frame(minWidth: 1_000, minHeight: 680)
        .background(V15Palette.paper.color)
        .tint(V15Palette.teal.color)
        .task { await loadInitialFacts() }
        .popover(isPresented: $searchPresented, arrowEdge: .top) { searchPopover }
        .sheet(isPresented: $categoryPresented) { categorySheet }
        .overlay { keyboardCommands }
        .accessibilityIdentifier("v151.mac.workspace")
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Text("Fiscal").font(.system(size: 14, weight: .semibold))
            Text(periodLabel).font(.system(size: 13)).foregroundStyle(V15Palette.ink.color.opacity(0.58))
            Text("· \(spineItemCount) 项").font(.system(size: 13)).foregroundStyle(V15Palette.ink.color.opacity(0.58))
            Spacer(minLength: 24)
            Menu {
                ForEach(Density.allCases) { value in Button(value.title) { density = value } }
            } label: {
                HStack(spacing: 6) {
                    Text("密度 \(density.title)")
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 11).frame(height: 30)
                .background(V15Palette.paper.color, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(V15Palette.hairline.color) }
            }
            .menuStyle(.borderlessButton)
            Button { searchPresented = true } label: {
                Label("搜索 ⌘F", systemImage: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 11).frame(height: 30)
                    .background(V15Palette.paper.color, in: RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).stroke(V15Palette.hairline.color) }
            }
            .buttonStyle(.plain).keyboardShortcut("f", modifiers: .command)
        }
        .padding(.leading, 86).padding(.trailing, 14).frame(height: 48)
        .background(V15Palette.card.color)
    }

    private var ledgerWorkspace: some View {
        GeometryReader { proxy in
            let narrow = proxy.size.width < 1_180
            HStack(spacing: 0) {
                indexPane.frame(width: narrow ? 220 : 256)
                Rectangle().fill(V15Palette.hairline.color).frame(width: 1)
                spinePane.frame(minWidth: narrow ? 420 : 500, maxWidth: .infinity)
                Rectangle().fill(V15Palette.hairline.color).frame(width: 1)
                inspectorPane.frame(width: narrow ? 280 : 320)
            }
        }
    }

    private var indexPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { destination = .record } label: {
                Label("记一笔", systemImage: "plus.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).frame(height: 34)
                    .foregroundStyle(Color.white)
                    .background(V15Palette.teal.color, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain).keyboardShortcut("n", modifiers: .command)
            .padding(.horizontal, 12).padding(.top, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    indexSection("筛选") {
                        ForEach(Lens.allCases) { value in lensRow(value) }
                    }
                    indexDivider
                    indexSection("时间") {
                        ForEach(monthChoices, id: \.self) { month in
                            indexRow(month == periodLabel ? month : month, count: nil, selected: month == periodLabel) {
                                destination = .ledger
                                applyMonth(month)
                            }
                        }
                    }
                    indexDivider
                    indexSection("账户") {
                        ForEach(ledger.accounts) { account in
                            indexMoneyRow(account.name, amount: account.currentBalanceMinor, isDebt: account.kind == .credit) {
                                selectAccount(account.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 16)
            }
            Spacer(minLength: 4)
            VStack(alignment: .leading, spacing: 2) {
                indexNavigation("报表", destination: .reports)
                indexNavigation("系统与数据", destination: .archive)
                indexNavigation("设置", destination: .settings)
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
        .background(V15Palette.card.color)
    }

    private func indexSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(V15Palette.ink.color.opacity(0.52)).padding(.horizontal, 8)
            content()
        }
    }

    private var indexDivider: some View { Rectangle().fill(V15Palette.hairline.color).frame(height: 1).padding(.horizontal, 8) }

    private func lensRow(_ value: Lens) -> some View {
        indexRow(value.title, count: lensCount(value), selected: lens == value && destination == .ledger) {
            chooseLens(value)
        }
    }

    private func indexRow(_ title: String, count: Int?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 8)
                if let count { Text("\(count)").monospacedDigit().foregroundStyle(selected ? Color.white : V15Palette.ink.color.opacity(0.60)) }
            }
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.white : V15Palette.ink.color)
            .padding(.horizontal, 10).frame(height: 31)
            .background(selected ? V15Palette.teal.color : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func indexMoneyRow(_ title: String, amount: Int64, isDebt: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).lineLimit(1)
                Spacer(minLength: 6)
                V15MoneyText(minorUnits: amount, direction: isDebt ? .outflow : .balance, includeCurrency: false, font: .system(size: 11, weight: .medium, design: .monospaced))
            }
            .font(.system(size: 12)).padding(.horizontal, 10).frame(height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func indexNavigation(_ title: String, destination value: Destination) -> some View {
        Button { destination = value } label: {
            Text(title).font(.system(size: 12)).foregroundStyle(V15Palette.ink.color.opacity(0.62)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 28)
        }.buttonStyle(.plain)
    }

    private var spinePane: some View {
        VStack(spacing: 0) {
            spineSummary
            Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    if let snapshotAt = ledger.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: snapshotAt, pendingCount: services.pendingWrites.count).padding(12) }
                    switch lens {
                    case .decisions: decisionRows
                    case .pendingSync: pendingRows
                    case .credit: creditRows
                    case .reimbursements: reimbursementRows
                    case .imports: importRows
                    case .uncategorized, .archive:
                        if lens == .uncategorized { futureRows; todayDivider }
                        transactionRows
                    }
                    if ledger.nextCursor != nil, lens == .uncategorized || lens == .archive { loadMoreRow }
                }
            }
            Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
            spineFooter
        }
        .background(V15Palette.paper.color)
    }

    private var spineSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text(lens.title).font(.system(size: 15, weight: .semibold))
                if let value = facts.facts?.cash.currentBalanceMinor {
                    Text("账户价值").foregroundStyle(V15Palette.ink.color.opacity(0.55))
                    V15MoneyText(minorUnits: value, direction: .balance, font: .system(size: 12, weight: .semibold, design: .monospaced))
                }
                if let value = monthReport?.summary.personalRealizedMinor {
                    Text("本月支出 · 个人实际承担").foregroundStyle(V15Palette.ink.color.opacity(0.55))
                    V15MoneyText(minorUnits: value, direction: .outflow, font: .system(size: 12, weight: .semibold, design: .monospaced))
                }
                Spacer(minLength: 8)
                if let expected = expectedReimbursementDifference, expected != 0 {
                    Text("另有 \(V15MoneyPresentation(minorUnits: expected, direction: .neutral).text) 预计可报销尚未收到")
                        .foregroundStyle(V15Palette.ink.color.opacity(0.50)).lineLimit(1)
                }
            }
            if services.pendingWrites.count > 0 {
                Text("\(services.pendingWrites.count) 项更改待同步，暂未计入汇总")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(V15Palette.ink.color.opacity(0.58))
            }
        }
        .font(.system(size: 12)).padding(.horizontal, 18).frame(minHeight: 45)
    }

    @ViewBuilder private var futureRows: some View {
        if let events = facts.facts?.knownFutureEvents, !events.isEmpty {
            HStack {
                Text("未来 · 尚未发生").font(.system(size: 11, weight: .semibold)).foregroundStyle(V15Palette.ink.color.opacity(0.58))
                Spacer()
            }
            .padding(.horizontal, 18).frame(height: 27).background(V15Palette.provisional.color)
            ForEach(events.prefix(4)) { event in
                Button { openFuture(event) } label: {
                    HStack(spacing: 14) {
                        Rectangle().fill(V15Palette.yellow.color).frame(width: 3, height: 25)
                        Text(shortDate(event.date)).font(.system(size: 11, design: .monospaced)).foregroundStyle(V15Palette.ink.color.opacity(0.58)).frame(width: 45, alignment: .leading)
                        Text(event.title).font(.system(size: 13)).lineLimit(1)
                        Text("· \(certainty(event.certainty))").font(.system(size: 12)).foregroundStyle(V15Palette.ink.color.opacity(0.52)).lineLimit(1)
                        Spacer(minLength: 8)
                        V15MoneyText(minorUnits: event.amountMinor, direction: .neutral, includeCurrency: false, font: .system(size: 12, weight: .semibold, design: .monospaced))
                    }
                    .padding(.horizontal, 18).frame(height: density.rowHeight).contentShape(Rectangle())
                    .background(V15Palette.provisional.color.opacity(0.78))
                }.buttonStyle(.plain)
                Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
            }
        }
    }

    private var todayDivider: some View {
        HStack(spacing: 12) {
            Text("今天 · \(todayLabel)").font(.system(size: 11, weight: .semibold))
            Rectangle().fill(Color.white.opacity(0.42)).frame(height: 1)
            Text("Asia/Shanghai").font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(Color.white).padding(.horizontal, 18).frame(height: 34).background(V15Palette.teal.color)
    }

    @ViewBuilder private var transactionRows: some View {
        switch ledger.phase {
        case .idle, .loading: V15LoadingSkeleton(layout: .list(rows: 6)).padding(18)
        case .empty: V15EmptyState(title: "这里还没有账目", explanation: "可以更换筛选条件或时间范围。").padding(20)
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await ledger.load() } }.padding(20)
        case .loaded:
            if visibleTransactions.isEmpty {
                V15EmptyState(
                    title: lens == .archive ? "归档里没有账目" : "这里还没有账目",
                    explanation: lens == .archive ? "作废账目会保留在这里，并提供明确的恢复入口。" : "可以更换筛选条件或时间范围。"
                )
                .padding(20)
            } else {
                ForEach(visibleTransactions, id: \.id) { transaction in transactionRow(transaction) }
            }
        }
    }

    private var visibleTransactions: [V15Transaction] {
        lens == .archive ? ledger.items.filter { $0.voidedAt != nil } : ledger.items
    }

    private func transactionRow(_ transaction: V15Transaction) -> some View {
        let selected = selectedID == transaction.id
        let batchSelected = selectedIDs.contains(transaction.id)
        return HStack(spacing: 0) {
            Button { toggleBatchSelection(transaction.id) } label: {
                Image(systemName: transaction.voidedAt != nil ? "archivebox" : (batchSelected ? "checkmark.square.fill" : "square"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(batchSelected ? V15Palette.teal.color : V15Palette.ink.color.opacity(0.42))
                    .frame(width: 34, height: density.rowHeight)
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
                Text("· \(ledger.categoryName(transaction.categoryID)) · \(ledger.accountName(transaction.accountID))\(transaction.voidedAt == nil ? "" : " · 归档 · 只读")")
                    .font(.system(size: 12)).foregroundStyle(V15Palette.ink.color.opacity(0.70)).lineLimit(1)
                Spacer(minLength: 8)
                V15MoneyText(minorUnits: transaction.amountMinor, direction: moneyDirection(transaction), includeCurrency: false, font: .system(size: 12, weight: .semibold, design: .monospaced))
            }
            .padding(.trailing, 18).frame(height: density.rowHeight).contentShape(Rectangle())
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

    @ViewBuilder private var pendingRows: some View {
        if services.pendingWrites.items.isEmpty {
            V15EmptyState(title: "没有待同步项目", explanation: "离线录入和离线分类决定会明确列在这里。").padding(20)
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("当前汇总暂不包含这些更改").font(.system(size: 12, weight: .semibold))
                    Text("点击同步后再更新到账簿。").font(.system(size: 10)).foregroundStyle(V15Palette.ink.color.opacity(0.58))
                }
                Spacer()
                Button("同步全部") { Task { await services.pendingWrites.replay(using: services) } }
                    .buttonStyle(.plain)
                    .disabled(services.offlineSnapshotAt != nil)
            }
            .padding(.horizontal, 18).frame(minHeight: 50).background(V15Palette.provisional.color)
            Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
            ForEach(services.pendingWrites.items) { item in
                HStack(spacing: 12) {
                    Rectangle().fill(V15Palette.yellow.color).frame(width: 3, height: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(pendingStatus(item)).font(.system(size: 11)).foregroundStyle(V15Palette.ink.color.opacity(0.58)).lineLimit(2)
                    }
                    Spacer()
                    if let amount = item.amountMinor { V15MoneyText(minorUnits: amount, direction: .neutral, includeCurrency: false, font: .system(size: 12, weight: .semibold, design: .monospaced)) }
                    if item.status == .failed {
                        Button("重试") { services.pendingWrites.retry(item.id); Task { await services.pendingWrites.replay(using: services) } }.buttonStyle(.borderless)
                    }
                    Button { services.pendingWrites.remove(item.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("移除待同步项目")
                }
                .padding(.horizontal, 18).frame(minHeight: density.rowHeight)
                Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
            }
        }
    }

    @ViewBuilder private var decisionRows: some View {
        switch facts.attentionPhase {
        case .idle, .loading: V15LoadingSkeleton().padding(18)
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await facts.refreshAttention() } }.padding(18)
        case .loaded:
            if facts.attention.isEmpty { V15EmptyState(title: "目前没有需要处理的事项", explanation: "全部账目仍可在账目列表中查看。").padding(20) }
            else {
                ForEach(facts.attention) { item in
                    Button {
                        openAttention(item)
                    } label: {
                        HStack(spacing: 12) {
                            Rectangle().fill(V15Palette.teal.color).frame(width: 3, height: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.explanation).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(item.suggestedAction).font(.system(size: 11)).foregroundStyle(V15Palette.ink.color.opacity(0.58)).lineLimit(1)
                            }
                            Spacer()
                            if let amount = item.amountMinor { V15MoneyText(minorUnits: amount, direction: .neutral, includeCurrency: false, font: .system(size: 12, weight: .semibold, design: .monospaced)) }
                        }
                        .padding(.horizontal, 18).frame(height: max(48, density.rowHeight)).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
                }
            }
        }
    }

    @ViewBuilder private var creditRows: some View {
        switch facts.factsPhase {
        case .idle, .loading:
            V15LoadingSkeleton(layout: .list(rows: 4)).padding(18)
        case .failed(let failure), .requiresReload(let failure):
            V15ServiceErrorState(message: failure.message) { Task { await facts.refresh() } }.padding(18)
        case .loaded:
            if let value = facts.facts?.credit.currentDebtMinor {
                lensMetricRow(
                    title: "当前信用欠款",
                    detail: "查看当前账期和还款记录。",
                    amount: value,
                    direction: .outflow,
                    action: { destination = .credit }
                )
            }
            ForEach(facts.attention.filter { $0.sourceType.contains("credit") }) { item in
                attentionLensRow(item)
            }
            ForEach((facts.facts?.knownFutureEvents ?? []).filter { $0.sourceType == .creditCycle }) { event in
                futureLensRow(event)
            }
        }
    }

    @ViewBuilder private var reimbursementRows: some View {
        switch facts.factsPhase {
        case .idle, .loading:
            V15LoadingSkeleton(layout: .list(rows: 4)).padding(18)
        case .failed(let failure), .requiresReload(let failure):
            V15ServiceErrorState(message: failure.message) { Task { await facts.refresh() } }.padding(18)
        case .loaded:
            if let value = facts.facts?.reimbursements.outstandingMinor {
                lensMetricRow(
                    title: "待收报销",
                    detail: "预计回款不会提前计入账户余额。",
                    amount: value,
                    direction: .neutral,
                    action: { destination = .reimbursements }
                )
            }
            ForEach(facts.attention.filter { $0.sourceType.contains("reimbursement") }) { item in
                attentionLensRow(item)
            }
            ForEach((facts.facts?.knownFutureEvents ?? []).filter { $0.sourceType == .reimbursementParty }) { event in
                futureLensRow(event)
            }
        }
    }

    @ViewBuilder private var importRows: some View {
        switch facts.factsPhase {
        case .idle, .loading:
            V15LoadingSkeleton(layout: .list(rows: 3)).padding(18)
        case .failed(let failure), .requiresReload(let failure):
            V15ServiceErrorState(message: failure.message) { Task { await facts.refresh() } }.padding(18)
        case .loaded:
            if let completeness = facts.facts?.completeness {
                lensCountRow(
                    title: "待核对导入",
                    detail: "尚未完成确认的账单行",
                    count: completeness.unresolvedImportCount,
                    action: { destination = .statementImport }
                )
                lensCountRow(
                    title: "导入失败",
                    detail: "需要修正或重新导入的批次",
                    count: completeness.failedImportCount,
                    action: { destination = .statementImport }
                )
            }
            ForEach(facts.attention.filter { $0.sourceType.contains("statement_import") }) { item in
                attentionLensRow(item)
            }
        }
    }

    private func lensMetricRow(title: String, detail: String, amount: Int64, direction: V15MoneyDirection, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Rectangle().fill(V15Palette.teal.color).frame(width: 3, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(V15Palette.ink.color.opacity(0.58)).lineLimit(2)
                }
                Spacer(minLength: 8)
                V15MoneyText(minorUnits: amount, direction: direction, includeCurrency: false, font: .system(size: 13, weight: .semibold, design: .monospaced))
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(V15Palette.ink.color.opacity(0.42))
            }
            .padding(.horizontal, 18).frame(minHeight: max(54, density.rowHeight)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Rectangle().fill(V15Palette.hairline.color).frame(height: 1) }
    }

    private func lensCountRow(title: String, detail: String, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Rectangle().fill(count > 0 ? V15Palette.yellow.color : V15Palette.teal.color).frame(width: 3, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(V15Palette.ink.color.opacity(0.58))
                }
                Spacer()
                Text("\(count) 项").font(.system(size: 12, weight: .semibold, design: .monospaced))
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(V15Palette.ink.color.opacity(0.42))
            }
            .padding(.horizontal, 18).frame(minHeight: max(50, density.rowHeight)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Rectangle().fill(V15Palette.hairline.color).frame(height: 1) }
    }

    private func attentionLensRow(_ item: V15AttentionItem) -> some View {
        Button { openAttention(item) } label: {
            HStack(spacing: 12) {
                Rectangle().fill(V15Palette.yellow.color).frame(width: 3, height: 25)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.explanation).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(item.suggestedAction).font(.system(size: 10)).foregroundStyle(V15Palette.ink.color.opacity(0.56)).lineLimit(1)
                }
                Spacer()
                if let amount = item.amountMinor { V15MoneyText(minorUnits: amount, direction: .neutral, includeCurrency: false, font: .system(size: 11, weight: .semibold, design: .monospaced)) }
            }
            .padding(.horizontal, 18).frame(minHeight: density.rowHeight).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Rectangle().fill(V15Palette.hairline.color).frame(height: 1) }
    }

    private func futureLensRow(_ event: V15FutureEvent) -> some View {
        Button { openFuture(event) } label: {
            HStack(spacing: 12) {
                Rectangle().fill(V15Palette.yellow.color).frame(width: 3, height: 25)
                Text(shortDate(event.date)).font(.system(size: 10, design: .monospaced)).foregroundStyle(V15Palette.ink.color.opacity(0.56))
                Text(event.title).font(.system(size: 12)).lineLimit(1)
                Text("\(certainty(event.certainty)) · 尚未发生").font(.system(size: 10)).foregroundStyle(V15Palette.ink.color.opacity(0.54))
                Spacer()
                V15MoneyText(minorUnits: event.amountMinor, direction: .neutral, includeCurrency: false, font: .system(size: 11, weight: .semibold, design: .monospaced))
            }
            .padding(.horizontal, 18).frame(minHeight: density.rowHeight).contentShape(Rectangle()).background(V15Palette.provisional.color.opacity(0.72))
        }
        .buttonStyle(.plain)
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
                    if selectedIDs.isEmpty { inspectorContent }
                    else { batchInspector }
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
            .onChange(of: batchCategoryID) { _, _ in batchPreviewed = false; batchResult = nil }
            if batchPreviewed, let categoryID = batchCategoryID {
                V15ServerFactState(title: "将要修改", detail: "已选择 \(selectedIDs.count) 笔账目，目标分类为“\(ledger.categoryName(categoryID))”。确认后会逐笔处理并显示结果。")
            }
            if let result = batchResult {
                V15PartialProgressState(
                    succeeded: result.queued ? "\(result.succeededIDs.count) 笔已加入待同步" : "\(result.succeededIDs.count) 笔已完成",
                    currentState: result.failures.isEmpty ? "没有失败项" : result.failures.map { "\($0.title)：\($0.message)" }.joined(separator: "\n"),
                    remaining: result.failures.isEmpty ? "无" : "\(result.failures.count) 笔仍保留选中，可修正后重试"
                )
            }
            if batchPreviewed {
                V15ActionButton(batchWorking ? "正在提交" : "确认批量设置   ⌘↩", disabledReason: batchWorking ? .init(code: "batch_working", message: "正在提交，请稍候。", fieldPath: nil) : nil) { submitBatchCategory() }
            } else {
                V15ActionButton("查看提交范围", disabledReason: batchCategoryID == nil ? .init(code: "category_required", message: "请先选择目标分类。", fieldPath: nil) : nil) { batchPreviewed = true }
            }
            V15ActionButton("清除选择", kind: .secondary) { selectedIDs.removeAll(); batchResult = nil; batchPreviewed = false }
        }
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
        switch accountDetailPhase {
        case .idle, .loading:
            V15LoadingSkeleton(layout: .inspector)
        case .failed(let failure):
            V15ServiceErrorState(message: failure.message) {
                if let id = selectedAccountID { Task { await loadAccount(id) } }
            }
        case .loaded:
            if let account = selectedAccount {
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
                        selectedAccountID = nil
                        selectedAccount = nil
                        accountDetailPhase = .idle
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
        VStack(alignment: .leading, spacing: 17) {
            VStack(alignment: .leading, spacing: 6) {
                Text(transaction.title).font(.system(size: 18, weight: .semibold))
                V15MoneyText(minorUnits: transaction.amountMinor, direction: moneyDirection(transaction), font: .system(size: 28, weight: .bold, design: .monospaced))
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
            fieldCard(transaction)
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

    private func fieldCard(_ transaction: V15Transaction) -> some View {
        VStack(spacing: 0) {
            fieldRow("类型", value: transactionKindLabel(transaction.kind), emphasized: false)
            fieldRow("账户", value: ledger.accountName(transaction.accountID), emphasized: false)
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
            V15SearchField(text: Binding(get: { ledger.filter.query ?? "" }, set: { ledger.setQuery($0) }))
            HStack { Spacer(); V15ActionButton("搜索") { searchPresented = false; Task { await ledger.load() } } }
        }
        .padding(16).frame(width: 360)
    }

    private var categorySheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置分类").font(.system(size: 22, weight: .bold))
            Text(selectedTransaction?.title ?? "账目").font(.system(size: 13)).foregroundStyle(V15Palette.ink.color.opacity(0.60))
            Picker("分类", selection: $categoryID) {
                Text("未分类").tag(Optional<UUID>.none)
                ForEach(ledger.categories) { category in Text(category.name).tag(Optional(category.id)) }
            }.pickerStyle(.menu).onChange(of: categoryID) { _, _ in categoryPreviewed = false }
            if categoryPreviewed {
                V15ServerFactState(detail: "已取得这笔账目的最新内容。确认后会直接修改分类。")
            }
            HStack {
                V15ActionButton("取消", kind: .secondary) { categoryPresented = false }
                if categoryPreviewed {
                    V15ActionButton("确认分类   ⌘↩") { commitCategory() }
                } else {
                    V15ActionButton("取最新账目", disabledReason: ledger.isOffline ? .init(code: "category_read_requires_network", message: "需要联网取得最新账目。", fieldPath: nil) : nil) { readCategoryCurrentFact() }
                }
            }
        }
        .padding(24).frame(width: 420)
    }

    private var takeover: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { destination = .ledger } label: { Label("返回账目", systemImage: "chevron.left") }.buttonStyle(.plain)
                Text("Fiscal / \(destination.title)").font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 18).frame(height: 45).background(V15Palette.card.color)
            Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
            takeoverContent
        }
    }

    @ViewBuilder private var takeoverContent: some View {
        switch destination {
        case .ledger: EmptyView()
        case .record: V15RecordView(services: services)
        case .future: V15FutureTimelineMacView(services: services)
        case .credit: V15CreditMacView(services: services)
        case .installments: V15InstallmentMacView(services: services)
        case .reimbursements: V15ReimbursementMacView(services: services)
        case .cashFlow: V15CashFlowMacView(services: services)
        case .reconciliation: V15ReconciliationMacView(services: services)
        case .proposals: V15AIProposalMacView(services: services)
        case .statementImport: V15StatementImportMacView(services: services)
        case .reports: V15ReportingMacView(services: services)
        case .archive: V15DataSecurityMacView(services: services)
        case .settings: V15SettingsView(services: services)
        }
    }

    private var selectedTransaction: V15Transaction? {
        ledger.selected ?? selectedID.flatMap { id in ledger.items.first(where: { $0.id == id }) }
    }

    private func loadInitialFacts() async {
        ledger.setClassification("uncategorized")
        async let references: Void = ledger.loadReferences()
        async let list: Void = ledger.load()
        async let current: Void = facts.refresh()
        async let report: Void = loadMonthReport()
        _ = await (references, list, current, report)
    }

    @MainActor private func loadMonthReport() async {
        guard let period = V15ReportMonth(currentMonthRaw) else { return }
        monthReportGeneration &+= 1
        let current = monthReportGeneration
        monthReport = nil
        let result = try? await services.reports.monthly(period)
        guard current == monthReportGeneration else { return }
        monthReport = result
    }

    private func chooseLens(_ value: Lens) {
        lens = value
        destination = .ledger
        selectedID = nil
        selectedIDs.removeAll()
        clearAccountSelection()
        ledger.clearSelection()
        ledger.setAccount(nil)
        switch value {
        case .uncategorized:
            ledger.setIncludeVoided(false)
            ledger.setClassification("uncategorized")
            Task { await ledger.load() }
        case .archive:
            ledger.setIncludeVoided(true)
            ledger.setClassification("all")
            Task { await ledger.load() }
        case .decisions, .pendingSync, .credit, .reimbursements, .imports:
            ledger.setIncludeVoided(false)
            ledger.setClassification("all")
        }
    }

    private func lensCount(_ value: Lens) -> Int {
        switch value {
        case .uncategorized: facts.facts?.completeness.uncategorizedTransactionCount ?? ledger.items.filter { $0.categoryID == nil }.count
        case .decisions: facts.attention.count
        case .pendingSync: services.pendingWrites.count
        case .credit: (facts.facts?.credit.currentDebtMinor ?? 0) == 0 ? 0 : 1
        case .reimbursements: (facts.facts?.reimbursements.outstandingMinor ?? 0) == 0 ? 0 : 1
        case .imports: (facts.facts?.completeness.unresolvedImportCount ?? 0) + (facts.facts?.completeness.failedImportCount ?? 0)
        case .archive: ledger.items.filter { $0.voidedAt != nil }.count
        }
    }

    private func applyMonth(_ label: String) {
        guard let date = monthParser.date(from: label) else { return }
        selectedID = nil
        selectedIDs.removeAll()
        clearAccountSelection()
        ledger.clearSelection()
        selectedMonth = date
        let calendar = shanghaiCalendar
        guard let interval = calendar.dateInterval(of: .month, for: date) else { return }
        ledger.setDateFrom(dayFormatter.string(from: interval.start))
        ledger.setDateTo(dayFormatter.string(from: calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end))
        Task { async let list: Void = ledger.load(); async let report: Void = loadMonthReport(); _ = await (list, report) }
    }

    private func openFuture(_ event: V15FutureEvent) {
        switch event.sourceType {
        case .creditCycle: destination = .credit
        case .reimbursementParty: destination = .reimbursements
        case .cashFlowItem: destination = .cashFlow
        }
    }

    private func openAttention(_ item: V15AttentionItem) {
        clearAccountSelection()
        switch item.sourceType {
        case "uncategorized_transaction":
            destination = .ledger
            selectedID = item.sourceID
            Task { await ledger.loadDetail(transactionID: item.sourceID) }
        case "credit_cycle_overdue":
            destination = .credit
        case "reimbursement_overdue", "reimbursement":
            destination = .reimbursements
        case "reconciliation_checkpoint", "reconciliation_missing", "reconciliation_difference":
            destination = .reconciliation
        case "statement_import_failed", "statement_import_review":
            destination = .statementImport
        case "cash_flow_overdue":
            destination = .cashFlow
        case "ai_proposal":
            destination = .proposals
        case "operation_exception":
            destination = .archive
        default:
            // Unknown server types must not be misrepresented as a report.
            destination = .archive
        }
    }

    private func selectTransaction(_ transaction: V15Transaction) {
        clearAccountSelection()
        selectedID = transaction.id
        Task { await ledger.select(transaction) }
    }

    private func selectAccount(_ id: UUID) {
        destination = .ledger
        selectedID = nil
        selectedIDs.removeAll()
        ledger.clearSelection()
        selectedAccountID = id
        selectedAccount = nil
        accountDetailPhase = .loading
        ledger.setAccount(id)
        Task {
            async let list: Void = ledger.load()
            async let detail: Void = loadAccount(id)
            _ = await (list, detail)
        }
    }

    @MainActor private func loadAccount(_ id: UUID) async {
        accountGeneration &+= 1
        let current = accountGeneration
        selectedAccountID = id
        selectedAccount = nil
        accountDetailPhase = .loading
        do {
            let account = try await services.masterData.account(id: id)
            guard current == accountGeneration, selectedAccountID == id else { return }
            selectedAccount = account
            accountDetailPhase = .loaded
        } catch let failure as V15Failure {
            guard current == accountGeneration, selectedAccountID == id else { return }
            accountDetailPhase = failure.kind == .cancelled ? .idle : .failed(failure)
        } catch is CancellationError {
            guard current == accountGeneration, selectedAccountID == id else { return }
            accountDetailPhase = .idle
        } catch {
            guard current == accountGeneration, selectedAccountID == id else { return }
            accountDetailPhase = .failed(.init(kind: .transport, message: "暂时无法取得账户信息。"))
        }
    }

    private func clearAccountSelection() {
        accountGeneration &+= 1
        selectedAccountID = nil
        selectedAccount = nil
        accountDetailPhase = .idle
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
        categoryPresented = true
    }

    private func commitCategory() {
        categoryPresented = false
        categoryPreviewed = false
        Task { await ledger.replaceSelectedCategory(categoryID) }
    }

    private func readCategoryCurrentFact() {
        guard let id = selectedTransaction?.id else { return }
        Task {
            await ledger.loadDetail(transactionID: id)
            guard case .loaded = ledger.detailPhase else { return }
            categoryPreviewed = true
        }
    }

    private func submitBatchCategory() {
        guard let categoryID = batchCategoryID, !batchWorking else { return }
        batchWorking = true
        Task {
            let result = await ledger.replaceCategories(selectedIDs, categoryID: categoryID)
            batchResult = result
            selectedIDs.subtract(result.succeededIDs)
            batchWorking = false
            batchPreviewed = !selectedIDs.isEmpty
        }
    }

    private var batchAmount: Int64 {
        ledger.items.filter { selectedIDs.contains($0.id) }.reduce(0) { $0 + $1.amountMinor }
    }

    private var spineItemCount: Int {
        switch lens {
        case .uncategorized: visibleTransactions.count
        case .decisions: facts.attention.count
        case .pendingSync: services.pendingWrites.count
        case .credit, .reimbursements, .imports: lensCount(lens)
        case .archive: visibleTransactions.count
        }
    }

    private func pendingStatus(_ item: V15PendingWriteStore.Item) -> String {
        let status: String
        switch item.status {
        case .queued: status = "等待联网后同步"
        case .syncing: status = "正在同步"
        case .requiresDecision: status = "数据已变化，需要重新决定"
        case .outcomeUnknown: status = "结果不明，需要核对"
        case .failed: status = "同步失败"
        }
        return item.message.map { "\(status) · \($0)" } ?? status
    }

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
            Button("下一笔") { moveSelection(1) }.keyboardShortcut("j", modifiers: [])
            Button("上一笔") { moveSelection(-1) }.keyboardShortcut("k", modifiers: [])
            Button("预览") { previewSelected() }.keyboardShortcut(.space, modifiers: [])
            Button("提交") {
                if categoryPresented, categoryPreviewed { commitCategory() }
                else if batchPreviewed { submitBatchCategory() }
            }.keyboardShortcut(.return, modifiers: .command)
        }
        .frame(width: 1, height: 1).opacity(0.001)
    }

    private var expectedReimbursementDifference: Int64? {
        guard let summary = monthReport?.summary else { return nil }
        return summary.personalRealizedMinor - summary.personalExpectedMinor
    }

    private var currentMonthRaw: String { monthRawFormatter.string(from: selectedMonth) }
    private var periodLabel: String { monthParser.string(from: selectedMonth) }
    private var monthChoices: [String] { (0..<4).compactMap { offset in shanghaiCalendar.date(byAdding: .month, value: -offset, to: Date()).map { monthParser.string(from: $0) } } }
    private var todayLabel: String { weekdayFormatter.string(from: Date()) }

    private var shanghaiCalendar: Calendar { var value = Calendar(identifier: .gregorian); value.locale = Locale(identifier: "zh_Hans_CN"); value.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return value }
    private var monthParser: DateFormatter { let value = DateFormatter(); value.locale = Locale(identifier: "zh_Hans_CN"); value.timeZone = TimeZone(identifier: "Asia/Shanghai"); value.dateFormat = "yyyy 年 M 月"; return value }
    private var monthRawFormatter: DateFormatter { let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX"); value.timeZone = TimeZone(identifier: "Asia/Shanghai"); value.dateFormat = "yyyy-MM"; return value }
    private var dayFormatter: DateFormatter { let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX"); value.timeZone = TimeZone(identifier: "Asia/Shanghai"); value.dateFormat = "yyyy-MM-dd"; return value }
    private var weekdayFormatter: DateFormatter { let value = DateFormatter(); value.locale = Locale(identifier: "zh_Hans_CN"); value.timeZone = TimeZone(identifier: "Asia/Shanghai"); value.dateFormat = "M月d日 EEEE"; return value }
    private func shortDate(_ value: String) -> String { value.count >= 5 ? String(value.suffix(5)) : value }
    private func timeLabel(_ value: Date) -> String { let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_Hans_CN"); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "MM-dd HH:mm"; return formatter.string(from: value) }
    private func certainty(_ value: V15FutureEventCertainty) -> String { switch value { case .exactDue: "确切到期"; case .confirmed: "已确认"; case .expected: "预计"; case .scheduled: "已排期" } }
    private func sourceLabel(_ value: String) -> String { switch value { case "manual": "手工录入"; case "system": "系统生成"; case "ai_text": "AI 文本"; case "ocr": "OCR"; case "legacy_import": "历史导入"; case "cash_flow": "现金流"; case "statement_import": "账单导入"; default: "未知来源" } }
    private func transactionKindLabel(_ value: String) -> String { V15LedgerReadKind(rawValue: value)?.displayName ?? "账目" }
    private func accountKindLabel(_ value: V15AccountKind) -> String { switch value { case .cash: "现金"; case .debit: "储蓄账户"; case .credit: "信用账户"; case .unknown: "未知类型" } }
    private func moneyDirection(_ transaction: V15Transaction) -> V15MoneyDirection { switch transaction.kind { case "income", "reimbursement_receipt": .inflow; case "transfer": .neutral; default: .outflow } }
}

#endif
