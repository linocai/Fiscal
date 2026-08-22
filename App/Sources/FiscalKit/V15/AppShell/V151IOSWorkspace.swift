import Foundation
import SwiftUI

#if os(iOS)

/// The formal iPhone root from the approved prototype: Today, a central
/// record action, and the searchable ledger. Domain-heavy work opens as a
/// full-screen workspace instead of becoming a fourth generic tab.
public struct V151IOSWorkspace: View {
    fileprivate enum Destination: String, Identifiable {
        case future, credit, installments, reimbursements, cashFlow
        case reconciliation, proposals, statementImport, reports, archive, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .future: "未来时间线"
            case .credit: "信用账期"
            case .installments: "分期"
            case .reimbursements: "报销"
            case .cashFlow: "现金流"
            case .reconciliation: "核对"
            case .proposals: "AI 待确认"
            case .statementImport: "账单导入"
            case .reports: "报表"
            case .archive: "数据与安全"
            case .settings: "账户与分类"
            }
        }
    }

    private enum Tab { case today, ledger }
    private let services: V15Services
    @State private var tab: Tab = .today
    @State private var recordPresented = false
    @State private var destination: Destination?
    @State private var ledgerFocusID: UUID?

    public init(services: V15Services) { self.services = services }

    public var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case .today:
                    V151IOSTodayDashboard(services: services, openLedger: { id in ledgerFocusID = id; tab = .ledger }, openDestination: { destination = $0 })
                case .ledger:
                    V151IOSLedger(services: services, focusID: ledgerFocusID, openDestination: { destination = $0 })
                }
            }
            .padding(.bottom, 66)
            bottomBar
        }
        .background(V15Palette.paper.color.ignoresSafeArea())
        .tint(V15Palette.teal.color)
        .fullScreenCover(isPresented: $recordPresented) {
            V15RecordView(services: services, presentsEditorDirectly: true)
        }
        .fullScreenCover(item: $destination) { value in
            V151IOSDestinationHost(services: services, destination: value)
        }
        .accessibilityIdentifier("v151.ios.workspace")
    }

    private var bottomBar: some View {
        HStack {
            bottomButton("今日", symbol: "square", selected: tab == .today) { tab = .today }
            Spacer()
            Button { recordPresented = true } label: {
                Image(systemName: "plus").font(.system(size: 24, weight: .light)).foregroundStyle(Color.white)
                    .frame(width: 56, height: 56).background(V15Palette.teal.color, in: Circle())
                    .shadow(color: Color.black.opacity(0.18), radius: 8, y: 4)
            }
            .buttonStyle(.plain).offset(y: -16).accessibilityLabel("记一笔")
            Spacer()
            bottomButton("账目", symbol: "square", selected: tab == .ledger) { tab = .ledger }
        }
        .padding(.horizontal, 42).frame(height: 66)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(V15Palette.hairline.color).frame(height: 1) }
    }

    private func bottomButton(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 4).stroke(selected ? V15Palette.teal.color : V15Palette.ink.color.opacity(0.38), lineWidth: selected ? 2 : 1.5).frame(width: 22, height: 22)
                Text(title).font(.system(size: 10, weight: selected ? .semibold : .regular))
            }.foregroundStyle(selected ? V15Palette.teal.color : V15Palette.ink.color.opacity(0.62)).frame(width: 62)
        }.buttonStyle(.plain)
    }
}

private struct V151IOSTodayDashboard: View {
    private enum ReportPhase { case idle, loading, loaded, failed }
    let services: V15Services
    let openLedger: (UUID?) -> Void
    let openDestination: (V151IOSWorkspace.Destination) -> Void
    @State private var model: V15TodayReadModel
    @State private var monthReport: V15PeriodReport?
    @State private var reportPhase: ReportPhase = .idle
    @State private var postponedIDs: Set<String> = []

    init(services: V15Services, openLedger: @escaping (UUID?) -> Void, openDestination: @escaping (V151IOSWorkspace.Destination) -> Void) {
        self.services = services
        self.openLedger = openLedger
        self.openDestination = openDestination
        _model = State(initialValue: V15TodayReadModel(services: services, offlineSnapshotProvider: { services.offlineSnapshotAt }))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let offline = model.offlineSnapshotAt { offlineBanner(offline) }
                Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
                factsSurface
            }
        }
        .background(V15Palette.paper.color)
        .refreshable { await refresh() }
        .task { await refresh() }
        .accessibilityIdentifier("v151.ios.today")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("今日").font(.system(size: 34, weight: .bold))
                    Text("\(todayLabel) · 更新于 \(updateTime)").font(.system(size: 13)).foregroundStyle(V15Palette.ink.color.opacity(0.58))
                }
                Spacer()
                Menu {
                    Button("报表") { openDestination(.reports) }
                    Button("账单导入") { openDestination(.statementImport) }
                    Button("核对") { openDestination(.reconciliation) }
                    Button("现金流") { openDestination(.cashFlow) }
                    Button("账户与分类") { openDestination(.settings) }
                    Button("数据与安全") { openDestination(.archive) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
                }
            }
            Text("账户价值").font(.system(size: 13)).foregroundStyle(V15Palette.ink.color.opacity(0.52))
            if let facts = model.facts {
                V15MoneyText(minorUnits: facts.cash.currentBalanceMinor, direction: .balance, font: .system(size: 34, weight: .bold, design: .monospaced))
                HStack(alignment: .top, spacing: 22) {
                    metric("信用欠款", facts.credit.currentDebtMinor, .outflow)
                    reportMetric
                    metric("未收报销", facts.reimbursements.outstandingMinor, .balance)
                }
                if let difference = expectedDifference, difference != 0 {
                    Text("支出口径：个人实际承担 · 另有 \(V15MoneyPresentation(minorUnits: difference, direction: .neutral).text) 预计可报销尚未收到")
                        .font(.system(size: 12)).foregroundStyle(V15Palette.ink.color.opacity(0.58)).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("支出口径：个人实际承担").font(.system(size: 12)).foregroundStyle(V15Palette.ink.color.opacity(0.58))
                }
            } else {
                Text("正在读取账簿事实").font(.system(size: 24, weight: .bold))
            }
        }
        .padding(.horizontal, 20).padding(.top, 15).padding(.bottom, 18)
    }

    private func metric(_ title: String, _ amount: Int64, _ direction: V15MoneyDirection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12)).foregroundStyle(V15Palette.ink.color.opacity(0.54)).lineLimit(1)
            V15MoneyText(minorUnits: amount, direction: direction, includeCurrency: false, font: .system(size: 15, weight: .bold, design: .monospaced))
        }
    }

    private var reportMetric: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("本月支出").font(.system(size: 12)).foregroundStyle(V15Palette.ink.color.opacity(0.54)).lineLimit(1)
            if reportPhase == .loaded, let value = monthReport?.summary.personalRealizedMinor {
                V15MoneyText(minorUnits: value, direction: .outflow, includeCurrency: false, font: .system(size: 15, weight: .bold, design: .monospaced))
            } else {
                Text(reportPhase == .failed ? "暂不可用" : "—").font(.system(size: 13, weight: .semibold)).foregroundStyle(V15Palette.ink.color.opacity(0.52))
            }
        }
    }

    @ViewBuilder private var factsSurface: some View {
        switch model.factsPhase {
        case .idle, .loading: V15LoadingSkeleton().padding(20)
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await refresh() } }.padding(20)
        case .requiresReload(let failure): V15ConflictState(conflict: failure.conflict ?? .init(reloadPath: nil, latestRevision: nil, message: failure.message)) { Task { await refresh() } }.padding(20)
        case .loaded:
            VStack(alignment: .leading, spacing: 14) {
                pendingSyncGroup
                HStack {
                    Text("需要你决定 · \(visibleAttention.count)").font(.system(size: 12, weight: .semibold)).foregroundStyle(V15Palette.teal.color)
                    Spacer()
                }
                attentionContent
                if let debt = model.facts?.credit.currentDebtMinor, debt != 0 { creditDecision(debt) }
                if visibleAttention.isEmpty && (model.facts?.credit.currentDebtMinor ?? 0) == 0 {
                    calmState
                }
                if let events = model.facts?.knownFutureEvents, !events.isEmpty { knownFuture(events) }
            }
            .padding(.horizontal, 16).padding(.vertical, 18)
        }
    }

    @ViewBuilder private var attentionContent: some View {
        switch model.attentionPhase {
        case .idle, .loading: V15LoadingSkeleton()
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.refreshAttention() } }
        case .loaded:
            ForEach(visibleAttention) { item in attentionCard(item) }
        }
    }

    @ViewBuilder private var pendingSyncGroup: some View {
        if !services.pendingWrites.items.isEmpty || services.pendingWrites.lastSyncReceipt != nil {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("待同步 · \(services.pendingWrites.count)").font(.system(size: 12, weight: .semibold)).foregroundStyle(V15Palette.teal.color)
                    Spacer()
                    if services.offlineSnapshotAt == nil, services.pendingWrites.count > 0 {
                        Button("立即同步") { Task { await services.pendingWrites.replay(using: services) } }.buttonStyle(.borderless)
                    }
                }
                if let receipt = services.pendingWrites.lastSyncReceipt {
                    V15ArchiveReadOnlyState { Text(receipt).font(V15Typography.secondary) }
                }
                ForEach(services.pendingWrites.items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Rectangle().fill(V15Palette.yellow.color).frame(width: 3, height: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                            Text(pendingStatus(item)).font(.system(size: 11)).foregroundStyle(V15Palette.ink.color.opacity(0.58)).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if item.status == .failed {
                            Button("重试") {
                                Task {
                                    services.pendingWrites.retry(item.id)
                                    await services.pendingWrites.replay(using: services)
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                        Button { services.pendingWrites.remove(item.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("移除待同步项目")
                    }
                    .padding(12).background(V15Palette.provisional.color, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func attentionCard(_ item: V15AttentionItem) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Rectangle().fill(V15Palette.teal.color).frame(width: 8, height: 8)
                Text(attentionTitle(item)).font(.system(size: 13, weight: .semibold)).foregroundStyle(V15Palette.teal.color)
                Spacer()
            }
            if let amount = item.amountMinor { V15MoneyText(minorUnits: amount, direction: attentionDirection(item), font: .system(size: 27, weight: .bold, design: .monospaced)) }
            Text(item.explanation).font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
            Text(item.suggestedAction).font(.system(size: 13)).foregroundStyle(V15Palette.ink.color.opacity(0.58)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                V15ActionButton(item.sourceType == "uncategorized_transaction" ? "选择分类" : "查看") {
                    if item.sourceType == "uncategorized_transaction" { openLedger(item.sourceID) }
                    else { openDestination(destination(for: item)) }
                }
                V15ActionButton("稍后", kind: .secondary) { postponedIDs.insert(item.id) }
            }
        }
        .padding(16)
        .background(V15Palette.paper.color, in: RoundedRectangle(cornerRadius: 15))
        .overlay { RoundedRectangle(cornerRadius: 15).stroke(V15Palette.hairline.color) }
    }

    private func creditDecision(_ amount: Int64) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) { Circle().stroke(V15Palette.teal.color, lineWidth: 2).frame(width: 11, height: 11); Text("信用账单待处理").font(.system(size: 13, weight: .semibold)).foregroundStyle(V15Palette.teal.color) }
            V15MoneyText(minorUnits: amount, direction: .outflow, font: .system(size: 27, weight: .bold, design: .monospaced))
            Text("查看服务器确认的账期、到期日与可用操作。").font(.system(size: 13)).foregroundStyle(V15Palette.ink.color.opacity(0.58))
            V15ActionButton("查看账期") { openDestination(.credit) }
        }
        .padding(16).background(V15Palette.paper.color, in: RoundedRectangle(cornerRadius: 15)).overlay { RoundedRectangle(cornerRadius: 15).stroke(V15Palette.hairline.color) }
    }

    private var calmState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("今天没有需要你决定的事项").font(.system(size: 19, weight: .semibold))
            Text("账簿事实仍然保留在“账目”中；这里只表示决策队列为空。").font(.system(size: 14)).foregroundStyle(V15Palette.ink.color.opacity(0.58))
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: 15))
    }

    private func knownFuture(_ events: [V15FutureEvent]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("已知未来").font(.system(size: 12, weight: .semibold)).foregroundStyle(V15Palette.ink.color.opacity(0.58)).padding(.bottom, 8)
            ForEach(events.prefix(3)) { event in
                Button { openDestination(event.sourceType == .creditCycle ? .credit : event.sourceType == .reimbursementParty ? .reimbursements : .cashFlow) } label: {
                    HStack(spacing: 10) {
                        Rectangle().fill(V15Palette.yellow.color).frame(width: 3, height: 28)
                        VStack(alignment: .leading, spacing: 3) { Text(event.title).font(.system(size: 14, weight: .medium)); Text(event.date).font(.system(size: 11)).foregroundStyle(V15Palette.ink.color.opacity(0.54)) }
                        Spacer()
                        V15MoneyText(minorUnits: event.amountMinor, direction: event.direction == .inflow ? .inflow : .outflow, includeCurrency: false, font: .system(size: 13, weight: .semibold, design: .monospaced))
                    }.padding(.vertical, 10)
                }.buttonStyle(.plain)
                Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
            }
        }
        .padding(15).background(V15Palette.provisional.color, in: RoundedRectangle(cornerRadius: 14))
    }

    private func offlineBanner(_ at: Date) -> some View {
        HStack(spacing: 12) {
            Rectangle().fill(V15Palette.yellow.color).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) { Text("离线 · 只读快照").font(.system(size: 13, weight: .semibold)); Text("显示 \(V15TodayReadModel.shanghaiDateLabel(model.offlineAsOf ?? at)) 的事实").font(.system(size: 11)).foregroundStyle(V15Palette.ink.color.opacity(0.58)) }
            Spacer(); Button("查看") { openLedger(nil) }.buttonStyle(.bordered)
        }.padding(.horizontal, 16).frame(minHeight: 62).background(V15Palette.provisional.color)
    }

    private func refresh() async {
        async let facts: Void = model.refresh()
        async let report: Void = loadReport()
        _ = await (facts, report)
        await services.pendingWrites.replay(using: services)
    }

    @MainActor private func loadReport() async {
        guard let period = V15ReportMonth(monthRaw) else { reportPhase = .failed; return }
        reportPhase = .loading
        do {
            monthReport = try await services.reports.monthly(period)
            reportPhase = .loaded
        } catch {
            monthReport = nil
            reportPhase = .failed
        }
    }

    private var expectedDifference: Int64? { monthReport.map { $0.summary.personalRealizedMinor - $0.summary.personalExpectedMinor } }
    private var visibleAttention: [V15AttentionItem] { model.attention.filter { !postponedIDs.contains($0.id) } }
    private var todayLabel: String { let f = DateFormatter(); f.locale = Locale(identifier: "zh_Hans_CN"); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "M月d日 EEEE"; return f.string(from: Date()) }
    private var updateTime: String { guard let value = model.facts?.meta.asOf else { return "读取中" }; let f = DateFormatter(); f.locale = Locale(identifier: "zh_Hans_CN"); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "HH:mm"; return f.string(from: value) }
    private var monthRaw: String { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "yyyy-MM"; return f.string(from: Date()) }
    private func attentionTitle(_ item: V15AttentionItem) -> String {
        switch item.sourceType {
        case "uncategorized_transaction": "未分类支出"
        case "credit_cycle_overdue": "信用账期逾期"
        case "reimbursement_overdue": "报销回款逾期"
        case "reconciliation_checkpoint", "reconciliation_missing", "reconciliation_difference": "核对待处理"
        case "statement_import_failed", "statement_import_review": "账单导入待处理"
        case "cash_flow_overdue": "现金流逾期"
        case "ai_proposal": "AI 提议待确认"
        case "operation_exception": "系统运行异常"
        default: "无法定位的待处理事项"
        }
    }

    private func destination(for item: V15AttentionItem) -> V151IOSWorkspace.Destination {
        switch item.sourceType {
        case "credit_cycle_overdue": .credit
        case "reimbursement_overdue", "reimbursement": .reimbursements
        case "reconciliation_checkpoint", "reconciliation_missing", "reconciliation_difference": .reconciliation
        case "statement_import_failed", "statement_import_review": .statementImport
        case "cash_flow_overdue": .cashFlow
        case "ai_proposal": .proposals
        case "operation_exception": .archive
        default: .archive
        }
    }
    private func attentionDirection(_ item: V15AttentionItem) -> V15MoneyDirection { if item.sourceType.contains("reimbursement") { return .inflow }; if item.sourceType.contains("uncategorized") || item.sourceType.contains("credit") { return .outflow }; return .neutral }
    private func pendingStatus(_ item: V15PendingWriteStore.Item) -> String {
        let status: String
        switch item.status { case .queued: status = "等待联网后同步"; case .syncing: status = "正在同步"; case .requiresDecision: status = "服务器事实已变化，需要重新决定"; case .outcomeUnknown: status = "结果不明，需要人工核对"; case .failed: status = "同步失败" }
        return item.message.map { "\(status) · \($0)" } ?? status
    }
}

private struct V151IOSLedger: View {
    let services: V15Services
    let focusID: UUID?
    let openDestination: (V151IOSWorkspace.Destination) -> Void
    @State private var model: V15LedgerModel
    @State private var selectedID: UUID?
    @State private var filtersPresented = false
    @State private var categoryID: UUID?
    @State private var categoryPreviewed = false
    @State private var categoryEditing = false

    init(services: V15Services, focusID: UUID?, openDestination: @escaping (V151IOSWorkspace.Destination) -> Void) {
        self.services = services
        self.focusID = focusID
        self.openDestination = openDestination
        _model = State(initialValue: V15LedgerModel(services: services))
    }

    var body: some View {
        VStack(spacing: 0) {
            ledgerHeader
            Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
            ledgerList
        }
        .background(V15Palette.paper.color)
        .task(id: focusID) { await loadInitialContent() }
        .sheet(item: Binding(
            get: { selectedID.map(SelectedTransactionID.init) },
            set: { value in
                selectedID = value?.id
                if value == nil { resetCategoryEditor() }
            }
        )) { _ in detailSheet }
        .sheet(isPresented: $filtersPresented) { filterSheet }
        .accessibilityIdentifier("v151.ios.ledger")
    }

    private var ledgerHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("账目").font(.system(size: 34, weight: .bold))
                Spacer()
                Menu {
                    Button("未来时间线") { openDestination(.future) }
                    Button("报表") { openDestination(.reports) }
                    Button("账单导入") { openDestination(.statementImport) }
                    Button("报销") { openDestination(.reimbursements) }
                    Button("分期") { openDestination(.installments) }
                    Button("设置") { openDestination(.settings) }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
            }
            HStack(spacing: 9) {
                V15SearchField(text: Binding(get: { model.filter.query ?? "" }, set: { model.setQuery($0) }))
                Button { filtersPresented = true } label: { Image(systemName: "line.3.horizontal.decrease").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44).overlay { RoundedRectangle(cornerRadius: 10).stroke(V15Palette.hairline.color) } }.buttonStyle(.plain)
                Button { Task { await model.load() } } label: { Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44).background(V15Palette.teal.color, in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(Color.white) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 13)
    }

    private var ledgerList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let offline = model.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: offline).padding(16) }
                switch model.phase {
                case .idle, .loading: V15LoadingSkeleton().padding(18)
                case .empty: V15EmptyState(title: "没有符合条件的账目", explanation: "更改搜索或筛选后重新读取。", actionTitle: "重新读取") { Task { await model.load() } }.padding(18)
                case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.load() } }.padding(18)
                case .loaded:
                    ForEach(model.items, id: \.id) { transaction in row(transaction) }
                    if model.nextCursor != nil { Button(model.isLoadingNext ? "正在读取" : "读取下一页") { Task { await model.loadNext() } }.buttonStyle(.plain).foregroundStyle(V15Palette.teal.color).font(.system(size: 14, weight: .semibold)).frame(height: 48) }
                }
            }
        }.refreshable { await model.load() }
    }

    private func row(_ transaction: V15Transaction) -> some View {
        Button {
            resetCategoryEditor()
            selectedID = transaction.id
            Task { await model.select(transaction) }
        } label: {
            HStack(alignment: .top, spacing: 11) {
                Rectangle().fill(transaction.categoryID == nil ? V15Palette.teal.color : Color.clear).frame(width: 3, height: 36)
                VStack(alignment: .leading, spacing: 5) {
                    Text(transaction.title).font(.system(size: 16, weight: .medium)).foregroundStyle(V15Palette.ink.color).lineLimit(1)
                    Text("\(shortDate(transaction.businessDate)) · \(model.categoryName(transaction.categoryID)) · \(model.accountName(transaction.accountID))").font(.system(size: 12)).foregroundStyle(V15Palette.ink.color.opacity(0.58)).lineLimit(1)
                }
                Spacer(minLength: 8)
                V15MoneyText(minorUnits: transaction.amountMinor, direction: direction(transaction), includeCurrency: false, font: .system(size: 15, weight: .bold, design: .monospaced))
            }
            .padding(.horizontal, 16).padding(.vertical, 13).contentShape(Rectangle())
        }.buttonStyle(.plain).overlay(alignment: .bottom) { Rectangle().fill(V15Palette.hairline.color).frame(height: 1) }
    }

    private var detailSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch model.detailPhase {
                    case .idle, .loading: V15LoadingSkeleton()
                    case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.retryDetail() } }
                    case .loaded:
                        if categoryEditing { categoryEditor }
                        else if let transaction = model.selected { detail(transaction) }
                    }
                }.padding(20)
            }
            .navigationTitle(categoryEditing ? "设置分类" : "账目详情").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if categoryEditing {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("返回") { categoryEditing = false }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(categoryEditing ? "取消" : "完成") {
                        if categoryEditing { categoryEditing = false }
                        else { selectedID = nil }
                    }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func detail(_ transaction: V15Transaction) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            Text(transaction.title).font(.system(size: 24, weight: .bold))
            V15MoneyText(minorUnits: transaction.amountMinor, direction: direction(transaction), font: .system(size: 31, weight: .bold, design: .monospaced))
            V15Section("服务器事实", detail: "v\(transaction.version)") {
                detailRow("类型", transactionKindLabel(transaction.kind))
                detailRow("账户", model.accountName(transaction.accountID))
                detailRow("分类", model.categoryName(transaction.categoryID))
                detailRow("业务日期", transaction.businessDate)
                detailRow("来源", sourceLabel(transaction.source))
            }
            if transaction.categoryID == nil {
                V15ActionButton("设置分类") {
                    categoryID = transaction.categoryID
                    categoryPreviewed = false
                    categoryEditing = true
                }
            }
            HStack {
                V15ActionButton("加入报销", kind: .secondary, disabledReason: reimbursementReason(transaction)) { openDestination(.reimbursements) }
                V15ActionButton(transaction.voidedAt == nil ? "作废" : "恢复", kind: .secondary, disabledReason: model.disabledReason(for: transaction.voidedAt == nil ? .void : .restore, transaction: transaction)) {
                    Task { if transaction.voidedAt == nil { await model.voidSelected() } else { await model.restoreSelected() } }
                }
            }
            V15ActionButton("改为分期", kind: .secondary, disabledReason: installmentReason(transaction)) { openDestination(.installments) }
            mutationState
            V15Section("修订历史") { ForEach(model.revisions) { revision in Text("v\(revision.version) · \(revision.event)").font(.system(size: 13, design: .monospaced)) } }
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View { HStack { Text(title).foregroundStyle(V15Palette.ink.color.opacity(0.55)); Spacer(); Text(value) }.font(.system(size: 14)).padding(.vertical, 5) }

    @ViewBuilder private var mutationState: some View {
        switch model.mutation {
        case .idle: EmptyView()
        case .working: V15LoadingSkeleton()
        case .reconciled(let message): V15ArchiveReadOnlyState { Text(message) }
        case .conflict(let conflict): V15ConflictState(conflict: conflict) { Task { await model.retryDetail() } }
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.retryLastMutation() } }
        }
    }

    private var filterSheet: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: Binding(get: { model.filter.kind }, set: { model.setKind($0) })) { Text("全部").tag(Optional<String>.none); ForEach(V15LedgerReadKind.allCases) { Text($0.displayName).tag(Optional($0.rawValue)) } }
                Picker("账户", selection: Binding(get: { model.filter.accountID }, set: { model.setAccount($0) })) { Text("全部账户").tag(Optional<UUID>.none); ForEach(model.accounts) { Text($0.name).tag(Optional($0.id)) } }
                Picker("分类状态", selection: Binding(get: { model.filter.classification }, set: { model.setClassification($0) })) { Text("全部").tag("all"); Text("已分类").tag("categorized"); Text("未分类").tag("uncategorized") }
                Toggle("包含已作废", isOn: Binding(get: { model.filter.includeVoided }, set: { model.setIncludeVoided($0) }))
            }
            .navigationTitle("筛选")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("应用") { filtersPresented = false; Task { await model.load() } } } }
        }
    }

    private var categoryEditor: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("选择分类后先查看变更预览；确认前不会修改服务器事实。")
                .font(.system(size: 14))
                .foregroundStyle(V15Palette.ink.color.opacity(0.58))
            V15Section("目标分类") {
                Picker("分类", selection: $categoryID) {
                    Text("未分类").tag(Optional<UUID>.none)
                    ForEach(model.categories) { Text($0.name).tag(Optional($0.id)) }
                }
                .onChange(of: categoryID) { _, _ in categoryPreviewed = false }
            }
            if categoryPreviewed {
                V15PreviewState {
                    Text("分类：\(model.categoryName(model.selected?.categoryID)) → \(model.categoryName(categoryID))\n账户、金额与账本分录不变。")
                        .font(V15Typography.secondary)
                }
            }
            if categoryPreviewed {
                V15ActionButton("确认分类") {
                    categoryEditing = false
                    Task { await model.replaceSelectedCategory(categoryID) }
                }
            } else {
                V15ActionButton("预览分类") { categoryPreviewed = true }
            }
        }
    }

    private func loadInitialContent() async {
        async let references: Void = model.loadReferences()
        if let focusID {
            model.setClassification("all")
            await model.load()
            selectedID = focusID
            await model.loadDetail(transactionID: focusID)
        } else {
            await model.load()
        }
        _ = await references
    }

    private func resetCategoryEditor() {
        categoryEditing = false
        categoryPreviewed = false
        categoryID = nil
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

    private struct SelectedTransactionID: Identifiable { let id: UUID }
    private func shortDate(_ value: String) -> String { value.count >= 5 ? String(value.suffix(5)) : value }
    private func direction(_ transaction: V15Transaction) -> V15MoneyDirection { switch transaction.kind { case "income", "reimbursement_receipt": .inflow; case "transfer": .neutral; default: .outflow } }
    private func transactionKindLabel(_ value: String) -> String { V15LedgerReadKind(rawValue: value)?.displayName ?? value }
    private func sourceLabel(_ value: String) -> String { V15LedgerReadSource(rawValue: value)?.displayName ?? value }
}

private struct V151IOSDestinationHost: View {
    let services: V15Services
    let destination: V151IOSWorkspace.Destination
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            content
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .tint(V15Palette.teal.color)
    }
    @ViewBuilder private var content: some View {
        switch destination {
        case .future: V15FutureTimelineView(services: services)
        case .credit: V15CreditView(services: services)
        case .installments: V15InstallmentView(services: services)
        case .reimbursements: V15ReimbursementView(services: services)
        case .cashFlow: V15CashFlowView(services: services)
        case .reconciliation: V15ReconciliationView(services: services)
        case .proposals: V15AIProposalView(services: services)
        case .statementImport: V15StatementImportView(services: services)
        case .reports: V15ReportingView(services: services)
        case .archive: V15DataSecurityView(services: services)
        case .settings: V15MasterDataView(services: services)
        }
    }
}

#endif
