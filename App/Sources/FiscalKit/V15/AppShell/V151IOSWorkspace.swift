import Foundation
import SwiftUI

#if os(iOS)

/// The formal iPhone root from the approved prototype: Today, a central
/// record action, and the searchable ledger. Domain-heavy work opens as a
/// full-screen workspace instead of becoming a fourth generic tab.
public struct V151IOSWorkspace: View {
    fileprivate enum Destination: Identifiable {
        case futureTarget(V15FutureOpenTarget)
        case credit(accountID: UUID?)
        case installments(accountID: UUID?, planID: UUID?, purchaseTransactionID: UUID?)
        case reimbursements(transactionID: UUID?)
        case reimbursementClaim(claimID: UUID, partyID: UUID?)
        case cashFlow
        case reports, settings, pendingSync
        var id: String {
            switch self {
            case .futureTarget(let target): "futureTarget:\(String(describing: target))"
            case .credit(let accountID): "credit:\(accountID?.uuidString ?? "all")"
            case .installments(let accountID, let planID, let purchaseTransactionID):
                "installments:\(accountID?.uuidString ?? "all"):\(planID?.uuidString ?? "new"):\(purchaseTransactionID?.uuidString ?? "none")"
            case .reimbursements(let transactionID): "reimbursements:\(transactionID?.uuidString ?? "all")"
            case .reimbursementClaim(let claimID, let partyID): "reimbursementClaim:\(claimID.uuidString):\(partyID?.uuidString ?? "claim")"
            case .cashFlow: "cashFlow"
            case .reports: "reports"
            case .settings: "settings"
            case .pendingSync: "pendingSync"
            }
        }
        var title: String {
            switch self {
            case .futureTarget: "已知未来"
            case .credit: "信用账期"
            case .installments: "分期"
            case .reimbursements, .reimbursementClaim: "报销"
            case .cashFlow: "现金流计划"
            case .reports: "报表"
            case .settings: "设置与治理"
            case .pendingSync: "待同步"
            }
        }
    }

    private enum Tab { case today, ledger }
    private let services: V15Services
    @State private var tab: Tab = .today
    @State private var recordPresented = false
    @State private var destination: Destination?
    @State private var ledgerFocusID: UUID?
    @State private var recordFactsRevision: UInt64 = 0

    public init(services: V15Services) { self.services = services }

    public var body: some View {
        Group {
            switch tab {
            case .today:
                V151IOSTodayDashboard(
                    services: services,
                    recordFactsRevision: recordFactsRevision,
                    openLedger: { id in ledgerFocusID = id; tab = .ledger },
                    openDestination: { destination = $0 }
                )
            case .ledger:
                V151IOSLedger(
                    services: services,
                    focusID: ledgerFocusID,
                    recordFactsRevision: recordFactsRevision,
                    openDestination: { destination = $0 },
                    refreshRootFacts: refreshRootFacts
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar.padding(.top, V15IOSLayout.floatingActionContentClearance)
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topLeading) {
            Text("V151 iOS workspace")
                .font(.caption2)
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("v151.ios.workspace-marker")
                .accessibilityLabel("V151 iOS workspace")
        }
        .background(V15Palette.canvas.color.ignoresSafeArea())
        .tint(V15Palette.teal.color)
        .fullScreenCover(isPresented: $recordPresented) {
            V15RecordView(services: services, presentsEditorDirectly: true, onCommitted: recordCommitted)
        }
        .fullScreenCover(item: $destination) { value in
            V151IOSDestinationHost(services: services, destination: value, onDismiss: refreshRootFacts)
        }
    }

    private func recordCommitted(_ outcome: V15RecordModel.CommitOutcome) {
        guard case .confirmed = outcome else { return }
        refreshRootFacts()
    }

    /// Domain views do not yet expose a confirmed-write callback. Reloading
    /// after their explicit close is conservative: it never claims success,
    /// while ensuring a completed write is not left stale at the root.
    private func refreshRootFacts() { recordFactsRevision &+= 1 }

    private var bottomBar: some View {
        HStack(alignment: .bottom) {
            bottomButton("今日", kind: .today, selected: tab == .today, badge: 0) { tab = .today }
            Spacer()
            bottomButton("账目", kind: .ledger, selected: tab == .ledger, badge: 0) { tab = .ledger }
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .frame(minHeight: V15IOSLayout.bottomBarMinimumHeight)
        .dynamicTypeSize(.large ... .accessibility1)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Rectangle().fill(V15Palette.hairline.color.opacity(0.72)).frame(height: 1) }
        .overlay {
            Button { recordPresented = true } label: {
                Image(systemName: "plus").font(.title3.weight(.bold)).foregroundStyle(Color.white)
                    .frame(width: V15IOSLayout.floatingActionDiameter, height: V15IOSLayout.floatingActionDiameter)
                    .background(V15Palette.teal.color, in: Circle())
                    .overlay { Circle().stroke(Color.white.opacity(0.2), lineWidth: 1) }
                    .shadow(color: Color.black.opacity(0.16), radius: 12, y: 6)
            }
            .buttonStyle(.plain).offset(y: -19).accessibilityLabel("记一笔").accessibilityHint("打开新建账目").accessibilityIdentifier("v151.ios.record")
        }
    }

    private enum BottomKind: String, Equatable { case today, ledger }

    private func bottomButton(_ title: String, kind: BottomKind, selected: Bool, badge: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: kind == .today ? (selected ? "house.fill" : "house") : (selected ? "list.bullet.rectangle.fill" : "list.bullet.rectangle"))
                        .font(.system(size: 19, weight: .semibold))
                        .frame(width: 26, height: 22)
                    if badge > 0 {
                        Text(badge > 9 ? "9+" : "\(badge)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, badge > 9 ? 3 : 4)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(V15Palette.teal.color, in: Capsule())
                            .offset(x: 9, y: -7)
                            .accessibilityLabel("\(badge) 项待决定")
                    }
                }
                Text(title)
                    .font(.caption2.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(selected ? V15Palette.teal.color : V15Palette.ink.color.opacity(0.58))
            .frame(minWidth: 74, minHeight: V15Accessibility.minimumTouchTarget)
            .background(selected ? V15Palette.selected.color : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("v151.ios.bottom.\(kind.rawValue)")
    }

}

private struct V151IOSTodayDashboard: View {
    let services: V15Services
    let recordFactsRevision: UInt64
    let openLedger: (UUID?) -> Void
    let openDestination: (V151IOSWorkspace.Destination) -> Void
    @State private var model: V15TodayReadModel
    @State private var futureOpenGeneration: UInt64 = 0
    @State private var futureOpenFailure: String?

    init(services: V15Services, recordFactsRevision: UInt64, openLedger: @escaping (UUID?) -> Void, openDestination: @escaping (V151IOSWorkspace.Destination) -> Void) {
        self.services = services
        self.recordFactsRevision = recordFactsRevision
        self.openLedger = openLedger
        self.openDestination = openDestination
        _model = State(initialValue: V15TodayReadModel(services: services, offlineSnapshotProvider: { services.offlineSnapshotAt }))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: V15Spacing.md) {
                header
                if let offline = model.offlineSnapshotAt { offlineBanner(offline) }
                factsSurface
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .v15IOSScreenCanvas()
        .refreshable { await refresh() }
        .task(id: recordFactsRevision) { await refresh() }
        .onDisappear { invalidateFutureOpen() }
        .accessibilityIdentifier("v151.ios.today")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("今日").font(V15Typography.surfaceTitle)
                    Text("\(todayLabel) · 更新于 \(updateTime)").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.58))
                }
                Spacer()
                Button { openTodayDestination(.settings) } label: {
                    Label("设置与治理", systemImage: "gearshape")
                        .font(V15Typography.secondary.weight(.semibold))
                }
                .buttonStyle(.plain)
                .v15PlatformHitArea()
                .accessibilityIdentifier("v151.ios.today.settings")
            }
            Text("账户价值").font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.52))
            if let facts = model.facts {
                scrollingMoney(
                    minorUnits: facts.cash.currentBalanceMinor,
                    direction: .balance,
                    font: V15Typography.moneyLarge,
                    accessibilityIdentifier: "v151.ios.today.account-value",
                    accessibilityLabel: "账户价值 \(V15MoneyPresentation(minorUnits: facts.cash.currentBalanceMinor, direction: .balance).text)"
                )
                V15AdaptiveStack(spacing: 12) {
                    metric("信用欠款", facts.credit.currentDebtMinor, .outflow)
                    metric("未收报销", facts.reimbursements.outstandingMinor, .balance)
                }
                Button { openTodayDestination(.reports) } label: {
                    Label("财务分析", systemImage: "chart.bar.xaxis")
                        .font(V15Typography.secondary.weight(.semibold))
                }
                .buttonStyle(.plain)
                .v15PlatformHitArea()
                .accessibilityIdentifier("v151.ios.today.reports")
            } else {
                Text("正在读取账目").font(V15Typography.cardTitle)
            }
        }
        .padding(V15IOSLayout.contentPadding)
        .v15IOSCard()
        .padding(.horizontal, V15IOSLayout.contentPadding)
        .padding(.top, V15Spacing.sm)
    }

    private func metric(_ title: String, _ amount: Int64, _ direction: V15MoneyDirection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.54)).lineLimit(1)
            scrollingMoney(minorUnits: amount, direction: direction, includeCurrency: false, font: V15Typography.money)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Amounts remain complete at AX5 and for long server values without
    /// allowing their intrinsic width to push the formal root off-screen.
    private func scrollingMoney(minorUnits: Int64, direction: V15MoneyDirection, includeCurrency: Bool = true, font: Font, accessibilityIdentifier: String? = nil, accessibilityLabel: String? = nil) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            V15MoneyText(minorUnits: minorUnits, direction: direction, includeCurrency: includeCurrency, font: font)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
        .accessibilityLabel(accessibilityLabel ?? V15MoneyPresentation(minorUnits: minorUnits, direction: direction, includeCurrency: includeCurrency).text)
    }

    @ViewBuilder private var factsSurface: some View {
        switch model.factsPhase {
        case .idle, .loading: V15LoadingSkeleton().padding(20)
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await refresh() } }.padding(20)
        case .requiresReload(let failure): V15ConflictState(conflict: failure.conflict ?? .init(reloadPath: nil, latestRevision: nil, message: failure.message)) { Task { await refresh() } }.padding(20)
        case .loaded:
            let events = model.facts?.knownFutureEvents ?? []
            let nearTermDue = events.filter { $0.certainty == .exactDue }
            let future = events.filter { $0.certainty != .exactDue }
            VStack(alignment: .leading, spacing: 14) {
                recentChangesLink
                if !nearTermDue.isEmpty { nearTermDueEvents(nearTermDue) }
                if !future.isEmpty { knownFuture(future) }
                if let futureOpenFailure {
                    V15ErrorMessageState(title: "暂时无法打开所属记录", message: futureOpenFailure)
                }
                pendingSyncNotice
                if nearTermDue.isEmpty && future.isEmpty && services.pendingWrites.items.isEmpty {
                    calmState
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 18)
        }
    }

    @ViewBuilder private var pendingSyncNotice: some View {
        if !services.pendingWrites.items.isEmpty {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(V15Palette.ink.color.opacity(0.58))
                Text("有 \(services.pendingWrites.count) 项更改等待同步；当前金额不包含这些变更。")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("核验") { openTodayDestination(.settings) }
                    .font(V15Typography.secondary.weight(.semibold))
                    .buttonStyle(.plain)
                    .v15PlatformHitArea()
            }
            .padding(.vertical, 6)
        }
    }

    private var recentChangesLink: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("最近变化").font(V15Typography.cardTitle)
                Text("按上海业务日查看已发生账目。")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.58))
            }
            Spacer()
            Button("查看账目") { openTodayLedger(nil) }
                .font(V15Typography.secondary.weight(.semibold))
                .buttonStyle(.plain)
                .v15PlatformHitArea()
        }
        .padding(.vertical, 4)
    }

    private func nearTermDueEvents(_ events: [V15FutureEvent]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("近期确定事项").font(V15Typography.label).foregroundStyle(V15Palette.teal.color)
            ForEach(Array(events.prefix(2).enumerated()), id: \.element.id) { indexed in
                let event = indexed.element
                Button { Task { await openVerifiedFutureEvent(event) } } label: {
                    V15AdaptiveStack(spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "calendar").foregroundStyle(V15Palette.teal.color)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.title).font(V15Typography.body.weight(.semibold))
                                Text("到期日 \(event.date)").font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.58))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        V15MoneyText(minorUnits: event.amountMinor, direction: event.direction == .inflow ? .inflow : .outflow, includeCurrency: false, font: V15Typography.label.monospacedDigit())
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("v151.ios.today.near-term.item.\(indexed.offset)")
            }
        }
        .padding(15)
        .background(V15Palette.provisional.color, in: RoundedRectangle(cornerRadius: V15IOSLayout.cardCornerRadius, style: .continuous))
    }

    private var calmState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("今天没有需要你处理的事项").font(V15Typography.cardTitle)
            Text("当前金额、最近账目和未来安排都在各自的清楚位置。")
                .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.58))
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).v15IOSCard()
    }

    private func knownFuture(_ events: [V15FutureEvent]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("已知未来").font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.58)).padding(.bottom, 8)
            ForEach(Array(events.prefix(3).enumerated()), id: \.element.id) { indexed in
                let event = indexed.element
                Button { Task { await openVerifiedFutureEvent(event) } } label: {
                    V15AdaptiveStack(spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            Rectangle().fill(V15Palette.yellow.color).frame(width: 3, height: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.title).font(V15Typography.body.weight(.medium))
                                Text(event.date).font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.54))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        V15MoneyText(minorUnits: event.amountMinor, direction: .neutral, includeCurrency: false, font: V15Typography.label.monospacedDigit())
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("v151.ios.today.known-future.item.\(indexed.offset)")
                Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
            }
        }
        .padding(15).background(V15Palette.provisional.color, in: RoundedRectangle(cornerRadius: V15IOSLayout.cardCornerRadius, style: .continuous))
    }

    private func offlineBanner(_ at: Date) -> some View {
        HStack(spacing: 12) {
            Rectangle().fill(V15Palette.yellow.color).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) { Text("离线 · 仅可查看").font(V15Typography.secondary.weight(.semibold)); Text("数据保存于 \(V15TodayReadModel.shanghaiDateLabel(model.offlineAsOf ?? at))").font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.58)) }
            Spacer(); V15ActionButton("查看", kind: .secondary) { openTodayLedger(nil) }
        }
        .padding(.horizontal, 16).frame(minHeight: 62).background(V15Palette.provisional.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v151.ios.offline")
    }

    @MainActor private func refresh() async {
        invalidateFutureOpen()
        await model.refresh()
    }

    @MainActor private func invalidateFutureOpen() {
        futureOpenGeneration &+= 1
        futureOpenFailure = nil
    }

    private func openTodayDestination(_ destination: V151IOSWorkspace.Destination) {
        invalidateFutureOpen()
        openDestination(destination)
    }

    private func openTodayLedger(_ id: UUID?) {
        invalidateFutureOpen()
        openLedger(id)
    }

    /// A future event is an invitation to inspect one verified source object,
    /// never a shortcut to a generic module with its original context lost.
    @MainActor private func openVerifiedFutureEvent(_ event: V15FutureEvent) async {
        futureOpenGeneration &+= 1
        let current = futureOpenGeneration
        futureOpenFailure = nil
        do {
            let target: V15FutureOpenTarget
            switch event.sourceType {
            case .creditCycle:
                let cycle = try await services.credit.cycle(id: event.sourceID, readCachePolicy: .reloadIgnoringCache)
                guard cycle.id == event.sourceID, cycle.id == event.cycleID,
                      event.accountID == nil || cycle.accountID == event.accountID else {
                    throw V15Failure(kind: .conflict, code: "future_owner_changed", message: "这项信用账期的归属已经变化，请刷新后再打开。")
                }
                target = .creditCycle(cycle)
            case .reimbursementParty:
                guard let claimID = event.claimID, let partyID = event.partyID else {
                    throw V15Failure(kind: .decoding, code: "future_owner_missing", message: "这项报销记录缺少归属信息。")
                }
                let claim = try await services.reimbursements.claim(id: claimID, readCachePolicy: .reloadIgnoringCache)
                guard claim.id == claimID, partyID == event.sourceID,
                      claim.parties.contains(where: { $0.id == partyID }) else {
                    throw V15Failure(kind: .conflict, code: "future_owner_changed", message: "这项报销记录的归属已经变化，请刷新后再打开。")
                }
                target = .reimbursementParty(claim: claim, partyID: partyID)
            case .cashFlowItem:
                let item = try await services.cashFlow.item(id: event.sourceID, readCachePolicy: .reloadIgnoringCache)
                let accountMatches = event.accountID == nil || event.accountID == item.accountID || event.accountID == item.destinationAccountID
                guard item.manualItemID == event.sourceID, accountMatches else {
                    throw V15Failure(kind: .conflict, code: "future_owner_changed", message: "这项现金流记录的归属已经变化，请刷新后再打开。")
                }
                target = .cashFlowItem(item)
            }
            guard current == futureOpenGeneration else { return }
            openTodayDestination(.futureTarget(target))
        } catch is CancellationError {
            guard current == futureOpenGeneration else { return }
        } catch let failure as V15Failure {
            guard current == futureOpenGeneration else { return }
            futureOpenFailure = failure.message
        } catch {
            guard current == futureOpenGeneration else { return }
            futureOpenFailure = "暂时无法核验这项未来事项，请稍后重试。"
        }
    }

    private var todayLabel: String { let f = DateFormatter(); f.locale = Locale(identifier: "zh_Hans_CN"); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "M月d日 EEEE"; return f.string(from: Date()) }
    private var updateTime: String { guard let value = model.facts?.meta.asOf else { return "读取中" }; let f = DateFormatter(); f.locale = Locale(identifier: "zh_Hans_CN"); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "HH:mm"; return f.string(from: value) }
}

private struct V151IOSCategoryInlineDecision: View {
    let services: V15Services
    let transactionID: UUID
    let onResolved: () -> Void
    @State private var model: V15LedgerModel
    @State private var categoryID: UUID?
    @State private var previewed = false
    @State private var receipt: String?

    init(services: V15Services, transactionID: UUID, onResolved: @escaping () -> Void) {
        self.services = services
        self.transactionID = transactionID
        self.onResolved = onResolved
        _model = State(initialValue: V15LedgerModel(services: services))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
            switch model.detailPhase {
            case .idle, .loading:
                V15LoadingSkeleton(layout: .decisionCard)
            case .failed(let failure):
                V15ServiceErrorState(message: failure.message) { Task { await load() } }
            case .loaded:
                if let receipt {
                    V15SuccessReceiptState(title: "分类已确认", detail: receipt)
                    V15ActionButton("完成") { onResolved() }
                } else {
                    Picker("目标分类", selection: $categoryID) {
                        Text("未分类").tag(Optional<UUID>.none)
                        ForEach(model.categories) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .pickerStyle(.menu)
                    .disabled(model.categoryChangeIsCommitting)
                    .onChange(of: categoryID) { _, _ in previewed = false; model.clearCategoryPreview() }
                    if previewed, let preview = model.categoryChangePreview {
                        V15ServerFactState(detail: preview.items.map { "\($0.title)：\($0.previousCategoryName ?? "未分类") → \($0.proposedCategoryName)" }.joined(separator: "\n"))
                        V15ActionButton(
                            model.categoryChangeIsCommitting ? "正在提交" : "确认分类",
                            disabledReason: model.categoryChangeIsCommitting
                                ? .init(code: "category_commit_in_flight", message: "正在提交分类，请稍候。", fieldPath: nil)
                                : nil
                        ) { Task { await commit() } }
                    } else {
                        V15ActionButton("取最新账目", disabledReason: categoryID == nil ? .init(code: "category_required", message: "请先选择分类。", fieldPath: nil) : (model.isOffline ? .init(code: "category_read_requires_network", message: "需要联网取得最新账目。", fieldPath: nil) : nil)) { Task { await readCurrentFact() } }
                    }
                    mutationState
                    if let failure = model.categoryChangeFailure { V15ServiceErrorState(message: failure.message) { Task { await readCurrentFact() } } }
                }
            }
        }
        .task(id: transactionID) { await load() }
    }

    @ViewBuilder private var mutationState: some View {
        switch model.mutation {
        case .idle: EmptyView()
        case .working: V15LoadingSkeleton(layout: .decisionCard)
        case .reconciled(let message): V15ServerFactState(title: "数据更新中", detail: message)
        case .conflict(let conflict):
            V15ConflictState(conflict: conflict, changes: model.mutationConflictChanges) { Task { await load() } }
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await commit() } }
        }
    }

    @MainActor private func load() async {
        previewed = false
        receipt = nil
        async let references: Void = model.loadReferences()
        async let detail: Void = model.loadDetail(transactionID: transactionID)
        _ = await (references, detail)
        categoryID = model.selected?.categoryID
    }

    @MainActor private func commit() async {
        let result = await model.commitPreviewedCategories()
        if result.committedIDs.contains(transactionID) {
            receipt = result.failures.first(where: { $0.id == transactionID })?.message
                ?? "分类已保存；现在显示最新账目。"
        }
    }
    @MainActor private func readCurrentFact() async {
        guard let categoryID else { return }
        await model.loadDetail(transactionID: transactionID)
        guard case .loaded = model.detailPhase else { return }
        await model.previewCategories([transactionID], categoryID: categoryID)
        previewed = model.categoryChangePreview != nil
    }
}

private struct V151IOSRepaymentInlineDecision: View {
    let services: V15Services
    let cycleID: UUID
    let destinationAccountID: UUID?
    let amountMinor: Int64?
    let onResolved: () -> Void
    @State private var model: V15RecordModel
    @State private var previewed = false
    @State private var conflictChanges: [V15ConflictChange] = []
    @State private var conflictExplanation: String?

    init(services: V15Services, cycleID: UUID, destinationAccountID: UUID?, amountMinor: Int64?, onResolved: @escaping () -> Void) {
        self.services = services
        self.cycleID = cycleID
        self.destinationAccountID = destinationAccountID
        self.amountMinor = amountMinor
        self.onResolved = onResolved
        let value = V15RecordModel(services: services)
        value.kind = .repayment
        value.title = "信用账期还款"
        value.amountText = amountMinor.map { String(format: "%.2f", Double(abs($0)) / 100) } ?? ""
        value.destinationAccountID = destinationAccountID
        value.creditCycleID = cycleID
        _model = State(initialValue: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
            Text("记录还款").font(.title3.weight(.semibold))
            V15Field("还款金额（元）", text: $model.amountText, prompt: "0.00", issues: model.allIssues, keyboard: .decimal)
                .onChange(of: model.amountText) { _, _ in previewed = false }
            Picker("还款来源", selection: $model.accountID) {
                Text("请选择").tag(Optional<UUID>.none)
                ForEach(model.accounts.filter { $0.kind == .cash || $0.kind == .debit }) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.menu)
            .onChange(of: model.accountID) { _, _ in previewed = false }
            Picker("信用账户", selection: $model.destinationAccountID) {
                Text("请选择").tag(Optional<UUID>.none)
                ForEach(model.accounts.filter { $0.kind == .credit }) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.menu)
            .onChange(of: model.destinationAccountID) { _, _ in
                previewed = false
                Task { await reloadTargetCycles() }
            }
            if let target = model.accounts.first(where: { $0.id == model.destinationAccountID }) {
                Text("目标：\(target.name) · 账期 \(cycleLabel)").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.62))
            }
            if previewed {
                V15PreviewState {
                    if case .ready(let preview) = model.repaymentPreviewPhase {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(preview.paymentAccountName)：\(money(preview.paymentBalanceBeforeMinor)) → \(money(preview.paymentBalanceAfterMinor))")
                            Text("\(preview.creditAccountName) 欠款：\(money(preview.creditDebtBeforeMinor)) → \(money(preview.creditDebtAfterMinor))")
                            Text("所选账期待还：\(money(preview.cycleRemainingBeforeMinor)) → \(money(preview.cycleRemainingAfterMinor))")
                        }.font(V15Typography.secondary)
                    }
                }
                V15ActionButton("确认还款", disabledReasons: model.allIssues.map { .init(code: $0.code, message: $0.message, fieldPath: $0.fieldPath) }) { Task { await submit() } }
            } else {
                V15ActionButton("更新账期", disabledReason: model.isOffline ? .init(code: "preview_requires_network", message: "需要联网取得最新账期。", fieldPath: nil) : nil) { Task { await refreshPreview() } }
            }
            submissionState
        }
        .task(id: cycleID) { await load() }
    }

    private var cycleLabel: String {
        model.creditCycles.first(where: { $0.id == model.creditCycleID }).map { "\($0.periodStart) 至 \($0.periodEnd)" } ?? "待读取"
    }

    @ViewBuilder private var submissionState: some View {
        switch model.submission {
        case .idle: EmptyView()
        case .submitting: V15LoadingSkeleton(layout: .decisionCard)
        case .queued: V15ServiceErrorState(message: "还款需要联网确认当前账期，不能离线排队。") { Task { await refreshPreview() } }
        case .success(let transaction):
            V15SuccessReceiptState(title: "还款已记录", detail: transaction.businessDate)
            V15ActionButton("完成") { onResolved() }
        case .conflict(let conflict):
            V15ConflictState(conflict: conflict, changes: conflictChanges, explanation: conflictExplanation) { Task {
                conflictChanges = []; conflictExplanation = nil
                await model.reloadAfterConflict(); await refreshPreview()
            } }
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.submit() } }
        }
    }

    @MainActor private func load() async {
        await model.loadReferences()
        if model.destinationAccountID == nil { model.destinationAccountID = destinationAccountID }
        if model.accountID == nil { model.accountID = model.accounts.first(where: { $0.kind == .cash || $0.kind == .debit })?.id }
        await model.loadCreditCycles()
        if model.creditCycles.contains(where: { $0.id == cycleID }) { model.creditCycleID = cycleID }
    }

    @MainActor private func refreshPreview() async {
        await model.loadCreditCycles()
        if model.creditCycles.contains(where: { $0.id == cycleID }) { model.creditCycleID = cycleID }
        await model.previewRepayment()
        if case .ready = model.repaymentPreviewPhase { previewed = true } else { previewed = false }
    }

    private func money(_ value: Int64) -> String { V15MoneyPresentation(minorUnits: value, direction: .neutral).text }

    @MainActor private func submit() async {
        let before = model.creditCycles.first(where: { $0.id == model.creditCycleID })
        _ = await model.submit()
        guard case .conflict = model.submission else { return }
        await readConflictFacts(before: before)
    }

    @MainActor private func readConflictFacts(before: V15CreditCycle?) async {
        guard let accountID = model.destinationAccountID, let cycleID = model.creditCycleID else {
            conflictExplanation = "账期已经变化，请取最新数据后重新确认。"
            return
        }
        do {
            let fresh = try await services.creditCycles.list(accountID: accountID, readCachePolicy: .reloadIgnoringCache)
                .items.first(where: { $0.id == cycleID })
            guard let fresh else {
                conflictExplanation = "原账期已不存在，请重新选择。"
                return
            }
            conflictExplanation = "已取得最新账期。"
            guard let before else {
                conflictChanges = []
                conflictExplanation = "已取得最新账期，请重新核对后确认。"
                return
            }
            conflictChanges = [
                .init(field: "待还金额", previousValue: V15MoneyPresentation(minorUnits: before.remainingMinor, direction: .outflow).text, currentValue: V15MoneyPresentation(minorUnits: fresh.remainingMinor, direction: .outflow).text),
                .init(field: "账单日 / 还款日", previousValue: "\(before.statementDate) / \(before.dueDate)", currentValue: "\(fresh.statementDate) / \(fresh.dueDate)")
            ]
        } catch {
            conflictExplanation = "暂时无法取得最新账期，请稍后再试。"
        }
    }

    @MainActor private func reloadTargetCycles() async {
        await model.loadCreditCycles()
        model.creditCycleID = model.creditCycles.contains(where: { $0.id == cycleID }) ? cycleID : nil
    }
}

private struct V151IOSReimbursementInlineDecision: View {
    let services: V15Services
    let claimID: UUID
    let onResolved: () -> Void
    @State private var model: V15ReimbursementModel
    @State private var conflictChanges: [V15ConflictChange] = []
    @State private var conflictExplanation: String?

    init(services: V15Services, claimID: UUID, onResolved: @escaping () -> Void) {
        self.services = services
        self.claimID = claimID
        self.onResolved = onResolved
        _model = State(initialValue: V15ReimbursementModel(services: services))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
            switch model.phase {
            case .idle, .loading: V15LoadingSkeleton(layout: .decisionCard)
            case .empty: V15EmptyState(title: "无法显示报销单", explanation: "暂时没有取得这张报销单的数据。")
            case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await load() } }
            case .loaded: receiptEditor
            }
        }
        .task(id: claimID) { await load() }
    }

    @ViewBuilder private var receiptEditor: some View {
        if let claim = model.selectedClaim {
            Text("登记收款").font(.title3.weight(.semibold))
            Text("\(claim.title) · 待收 \(V15MoneyPresentation(minorUnits: claim.outstandingMinor, direction: .neutral).text)")
                .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.62))
            Picker("付款方", selection: Binding(get: { model.selectedPartyID }, set: { id in if let id { model.chooseParty(id) } })) {
                ForEach(claim.parties.filter { $0.outstandingMinor > 0 }, id: \.id) { Text($0.name).tag(Optional($0.id)) }
            }.pickerStyle(.menu)
            Picker("入账账户", selection: Binding(get: { model.selectedReceiptAccount?.id }, set: { id in if let account = model.receiptAccounts.first(where: { $0.id == id }) { model.chooseReceiptAccount(account) } })) {
                ForEach(model.receiptAccounts) { Text($0.name).tag(Optional($0.id)) }
            }.pickerStyle(.menu)
            V15Field("实收金额（元）", text: $model.receiptAmountText, prompt: "0.00", issues: model.receiptIssues + model.receiptServerIssues, keyboard: .decimal)
            V15Field("收款日期", text: $model.receiptDateText, prompt: "YYYY-MM-DD", issues: model.receiptIssues + model.receiptServerIssues)
            receiptPhase
        }
    }

    @ViewBuilder private var receiptPhase: some View {
        switch model.receiptPhase {
        case .idle, .loading, .ready:
            V15ActionButton("预览收款", disabledReasons: model.receiptPreviewDisabledReasons) { Task { await model.previewReceipt() } }
        case .previewing, .committing:
            V15LoadingSkeleton(layout: .decisionCard)
        case .previewed:
            if let preview = model.receiptPreview {
                V15PreviewState {
                    Text("实收 \(V15MoneyPresentation(minorUnits: preview.amountMinor, direction: .neutral).text)\n已收 \(V15MoneyPresentation(minorUnits: preview.claimReceivedBeforeMinor, direction: .neutral).text) → \(V15MoneyPresentation(minorUnits: preview.claimReceivedAfterMinor, direction: .neutral).text)\n确认后将记录这笔报销收款。")
                        .font(V15Typography.secondary)
                }
            }
            V15ActionButton("确认收款", disabledReasons: model.receiptCommitDisabledReasons) { Task { await commitReceipt() } }
        case .succeeded:
            if let result = model.receiptResult {
                V15SuccessReceiptState(title: "收款已登记", detail: V15MoneyPresentation(minorUnits: result.amountMinor, direction: .neutral).text)
            }
            V15ActionButton("完成") { onResolved() }
        case .unknown:
            V15ServiceErrorState(message: "这笔收款可能已经保存。请检查最新状态，系统不会重复登记。") { Task { await model.retryUnknownReceipt() } }
        case .conflict(let conflict):
            V15ConflictState(conflict: conflict, changes: conflictChanges, explanation: conflictExplanation) { Task {
                conflictChanges = []; conflictExplanation = nil
                await load(policy: .reloadIgnoringCache)
            } }
        case .failed(let failure):
            V15ServiceErrorState(message: failure.message) { Task { await model.previewReceipt() } }
        }
    }

    @MainActor private func load(policy: V15ReadCachePolicy = .standard) async {
        await model.openClaim(id: claimID, readCachePolicy: policy)
        if model.selectedClaim != nil { await model.openReceipt() }
    }

    @MainActor private func commitReceipt() async {
        let before = model.selectedClaim
        await model.commitReceipt()
        guard case .conflict = model.receiptPhase else { return }
        await readConflictFacts(before: before)
    }

    @MainActor private func readConflictFacts(before: V15ReimbursementClaim?) async {
        do {
            let fresh = try await services.reimbursements.claim(id: claimID, readCachePolicy: .reloadIgnoringCache)
            conflictExplanation = "已取得最新报销信息。"
            guard let before else {
                conflictChanges = []
                conflictExplanation = "已取得最新报销信息，请重新核对后确认。"
                return
            }
            conflictChanges = [
                .init(field: "已收金额", previousValue: V15MoneyPresentation(minorUnits: before.receivedMinor, direction: .inflow).text, currentValue: V15MoneyPresentation(minorUnits: fresh.receivedMinor, direction: .inflow).text),
                .init(field: "待收金额", previousValue: V15MoneyPresentation(minorUnits: before.outstandingMinor, direction: .neutral).text, currentValue: V15MoneyPresentation(minorUnits: fresh.outstandingMinor, direction: .neutral).text),
                .init(field: "到账笔数", previousValue: "\(before.receiptCount)", currentValue: "\(fresh.receiptCount)")
            ]
        } catch {
            conflictExplanation = "暂时无法取得最新报销信息，请稍后再试。"
        }
    }
}

private struct V151IOSCashFlowInlineDecision: View {
    private enum Phase { case loading, ready, previewed, committing, succeeded(V15CashFlowItem), conflict(V15Conflict), failed(V15Failure) }
    let services: V15Services
    let itemID: UUID
    let onResolved: () -> Void
    @State private var item: V15CashFlowItem?
    @State private var preview: V15CashFlowConfirmPreview?
    @State private var phase: Phase = .loading
    @State private var conflictChanges: [V15ConflictChange] = []
    @State private var conflictExplanation: String?
    @State private var confirmGate = V15SingleFlightAttemptGate()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
            switch phase {
            case .loading, .committing: V15LoadingSkeleton(layout: .decisionCard)
            case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await load(fresh: true) } }
            case .conflict(let conflict):
                V15ConflictState(conflict: conflict, changes: conflictChanges, explanation: conflictExplanation) { Task {
                    conflictChanges = []; conflictExplanation = nil
                    await load(fresh: true)
                } }
            case .succeeded(let value):
                V15SuccessReceiptState(title: "现金流已确认", detail: "\(value.title) · \(value.status.displayName)")
                V15ActionButton("完成") { onResolved() }
            case .ready, .previewed:
                if let item {
                    Text("确认现金流").font(.title3.weight(.semibold))
                    HStack { Text(item.title); Spacer(); V15MoneyText(minorUnits: item.plannedAmountMinor, direction: .neutral, font: V15Typography.money) }
                    Text("预期 \(item.expectedDate) · \(item.status.displayName)").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.62))
                    if case .previewed = phase {
                        V15PreviewState { Text("\(preview?.itemBefore.status.displayName ?? item.status.displayName) → 已确认。确认只改变这一次事项，不会创建入账交易。").font(V15Typography.secondary) }
                        V15ActionButton("确认本次", disabledReason: confirmReason(item)) { Task { await confirm(item) } }
                    } else {
                        V15ActionButton("读取影响", disabledReason: confirmReason(item)) { Task { await load(fresh: true, preview: true) } }
                    }
                }
            }
        }
        .task(id: itemID) { await load() }
    }

    private func confirmReason(_ item: V15CashFlowItem) -> V15DisabledReason? {
        if confirmGate.isActive { return .init(code: "confirm_commit_in_flight", message: "正在确认这项现金流，请稍候。", fieldPath: nil) }
        if services.offlineSnapshotAt != nil { return .init(code: "offline_read_only", message: "离线时只可查看。", fieldPath: nil) }
        guard item.manualItemID != nil else { return .init(code: "system_projection", message: "系统投影必须在对应业务流程处理。", fieldPath: nil) }
        guard item.allows(.confirm) else { return .init(code: "confirm_unavailable", message: "当前状态不能确认这项现金流。", fieldPath: nil) }
        return nil
    }

    @MainActor private func load(fresh: Bool = false, preview: Bool = false) async {
        guard !confirmGate.isActive else { return }
        phase = .loading
        do {
            let value = try await services.cashFlow.item(id: itemID, readCachePolicy: fresh ? .reloadIgnoringCache : .standard)
            item = value
            if preview, let id = value.manualItemID {
                self.preview = try await services.actions.cashFlowConfirmPreview(itemID: id, expectedVersion: value.version)
                phase = .previewed
            } else { self.preview = nil; phase = .ready }
        } catch let failure as V15Failure { phase = .failed(failure) }
        catch { phase = .failed(.init(kind: .transport, message: "暂时无法取得现金流信息。")) }
    }

    @MainActor private func confirm(_ value: V15CashFlowItem) async {
        guard let id = value.manualItemID, let preview, preview.itemBefore.id == value.id, confirmReason(value) == nil,
              let key = confirmGate.begin() else { return }
        defer { confirmGate.finish(key) }
        phase = .committing
        do {
            _ = try await services.actions.commitCashFlow(itemID: id, previewToken: preview.meta.previewToken, idempotencyKey: key)
            let result = try await services.cashFlow.item(id: id, readCachePolicy: .reloadIgnoringCache)
            item = result
            phase = .succeeded(result)
        } catch let failure as V15Failure {
            if failure.kind == .conflict, let conflict = failure.conflict {
                phase = .conflict(conflict)
                await readConflictFacts(before: value)
            }
            else if V15LedgerCreateService.outcomeMayBeUnknown(failure) { await reconcileReceipt(key: key, itemID: id) }
            else { phase = .failed(failure) }
        } catch {
            await reconcileReceipt(key: key, itemID: id)
        }
    }

    @MainActor private func reconcileReceipt(key: UUID, itemID: UUID) async {
        if let receipt = try? await services.actions.receipt(idempotencyKey: key), receipt.action == .cashFlowConfirm,
           let result = try? await services.cashFlow.item(id: itemID, readCachePolicy: .reloadIgnoringCache) {
            item = result; preview = nil; phase = .succeeded(result)
        } else {
            preview = nil
            phase = .failed(.init(kind: .responseUnknown, message: "确认结果不明，请打开现金流详情核对；不会自动重复确认。"))
        }
    }

    @MainActor private func readConflictFacts(before: V15CashFlowItem) async {
        do {
            let fresh = try await services.cashFlow.item(id: itemID, readCachePolicy: .reloadIgnoringCache)
            item = fresh
            conflictExplanation = "已取得最新现金流信息。"
            conflictChanges = [
                .init(field: "状态", previousValue: before.status.displayName, currentValue: fresh.status.displayName),
                .init(field: "计划金额", previousValue: V15MoneyPresentation(minorUnits: before.plannedAmountMinor, direction: .neutral).text, currentValue: V15MoneyPresentation(minorUnits: fresh.plannedAmountMinor, direction: .neutral).text),
                .init(field: "预计日期", previousValue: before.expectedDate, currentValue: fresh.expectedDate)
            ]
        } catch {
            conflictExplanation = "暂时无法取得最新现金流信息，请稍后再试。"
        }
    }
}

private struct V151IOSLedger: View {
    let services: V15Services
    let focusID: UUID?
    let recordFactsRevision: UInt64
    let openDestination: (V151IOSWorkspace.Destination) -> Void
    let refreshRootFacts: () -> Void
    @State private var model: V15LedgerModel
    @State private var selectedID: UUID?
    @State private var filtersPresented = false
    @State private var futurePresented = false
    @State private var futureDestination: V151IOSWorkspace.Destination?
    @State private var accountDetailID: UUID?
    @State private var transactionContextDestination: V151IOSWorkspace.Destination?
    @State private var hasLoadedInitialContent = false
    @State private var categoryID: UUID?
    @State private var categoryPreviewed = false
    @State private var categoryEditing = false
    @State private var categoryCommitNotice: String?

    init(
        services: V15Services,
        focusID: UUID?,
        recordFactsRevision: UInt64,
        openDestination: @escaping (V151IOSWorkspace.Destination) -> Void,
        refreshRootFacts: @escaping () -> Void
    ) {
        self.services = services
        self.focusID = focusID
        self.recordFactsRevision = recordFactsRevision
        self.openDestination = openDestination
        self.refreshRootFacts = refreshRootFacts
        _model = State(initialValue: V15LedgerModel(services: services))
    }

    var body: some View {
        VStack(spacing: 0) {
            ledgerHeader
            ledgerList
        }
        .v15IOSScreenCanvas()
        .task(id: LedgerRefreshOwner(focusID: focusID, revision: recordFactsRevision)) {
            if hasLoadedInitialContent { await refreshPreservingContext() }
            else { hasLoadedInitialContent = true; await loadInitialContent() }
        }
        .sheet(item: Binding(
            get: { selectedID.map(SelectedTransactionID.init) },
            set: { value in
                selectedID = value?.id
                if value == nil { resetCategoryEditor() }
            }
        )) { _ in detailSheet }
        .sheet(item: Binding(
            get: { accountDetailID.map(SelectedAccountID.init) },
            set: { accountDetailID = $0?.id }
        )) { selection in
            V151IOSAccountDetail(
                services: services,
                accountID: selection.id,
                recordFactsRevision: recordFactsRevision,
                refreshRootFacts: refreshRootFacts
            )
        }
        .sheet(isPresented: $filtersPresented) { filterSheet }
        .sheet(isPresented: $futurePresented) {
            V15FutureTimelineView(services: services, refreshToken: recordFactsRevision, onOpen: { target in
                futureDestination = .futureTarget(target)
            })
                .safeAreaInset(edge: .top, spacing: 0) {
                    HStack {
                        Button("关闭") { futurePresented = false }
                            .font(V15Typography.secondary.weight(.semibold))
                            .v15PlatformHitArea()
                            .accessibilityIdentifier("v151.ios.ledger.future.close")
                        Spacer()
                        Button("现金流计划") {
                            futureDestination = .cashFlow
                        }
                        .font(V15Typography.secondary.weight(.semibold))
                        .v15PlatformHitArea()
                        .accessibilityIdentifier("v151.ios.ledger.future.cash-flow")
                    }
                    .padding(.horizontal, V15Spacing.md)
                    .padding(.vertical, V15Spacing.sm)
                    .background(.regularMaterial)
                }
                .fullScreenCover(item: $futureDestination) { value in
                    V151IOSDestinationHost(services: services, destination: value, onDismiss: refreshRootFacts)
                }
        }
        .overlay(alignment: .topLeading) {
            Text("V151 iOS ledger")
                .font(.caption2)
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("v151.ios.ledger")
                .accessibilityLabel("V151 iOS ledger")
        }
    }

    private var ledgerHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("账目").font(V15Typography.surfaceTitle)
                Spacer()
                Text("按上海业务日").font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.54))
            }
            V15AdaptiveStack(spacing: 8) {
                Button { moveToPast() } label: { Label("过去", systemImage: "chevron.left") }
                    .buttonStyle(.plain).v15PlatformHitArea().accessibilityIdentifier("v151.ios.ledger.time.past")
                Button { returnToToday() } label: { Label("回到今天", systemImage: "calendar") }
                    .buttonStyle(.plain).v15PlatformHitArea().accessibilityIdentifier("v151.ios.ledger.time.today")
                Button { futurePresented = true } label: { Label("未来", systemImage: "chevron.right") }
                    .buttonStyle(.plain).v15PlatformHitArea().accessibilityIdentifier("v151.ios.ledger.time.future")
            }
            Menu {
                Button("全部账户") { selectAccount(nil) }
                ForEach(model.accounts) { account in
                    Button(account.name) { selectAccount(account.id) }
                }
            } label: {
                Label(accountScopeTitle, systemImage: "rectangle.3.group")
                    .font(V15Typography.secondary.weight(.semibold))
            }
            .accessibilityIdentifier("v151.ios.ledger.account-scope")
            if let accountID = model.filter.accountID {
                Button { accountDetailID = accountID } label: {
                    Label("查看 \(accountScopeTitle) 详情", systemImage: "info.circle")
                        .font(V15Typography.secondary.weight(.semibold))
                }
                .buttonStyle(.plain)
                .v15PlatformHitArea()
                .accessibilityIdentifier("v151.ios.ledger.account-detail")
            }
            HStack(spacing: 9) {
                V15SearchField(text: Binding(get: { model.filter.query ?? "" }, set: { model.setQuery($0) }))
                Button { filtersPresented = true } label: { Image(systemName: "line.3.horizontal.decrease").font(V15Typography.body.weight(.semibold)).frame(width: V15Accessibility.minimumTouchTarget, height: V15Accessibility.minimumTouchTarget).background(V15Palette.surfaceRaised.color, in: RoundedRectangle(cornerRadius: V15Radius.control, style: .continuous)).overlay { RoundedRectangle(cornerRadius: V15Radius.control).stroke(V15Palette.hairline.color) } }.buttonStyle(.plain).accessibilityLabel("筛选账目")
                Button { Task { await model.load() } } label: { Image(systemName: "magnifyingglass").font(V15Typography.body.weight(.semibold)).frame(width: V15Accessibility.minimumTouchTarget, height: V15Accessibility.minimumTouchTarget).background(V15Palette.teal.color, in: RoundedRectangle(cornerRadius: V15Radius.control)).foregroundStyle(Color.white) }.buttonStyle(.plain)
            }
        }
        .padding(V15IOSLayout.contentPadding)
        .v15IOSCard()
        .padding(.horizontal, V15IOSLayout.contentPadding)
        .padding(.top, V15Spacing.sm)
    }

    private var ledgerList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let offline = model.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: offline).padding(16) }
                switch model.phase {
                case .idle, .loading: V15LoadingSkeleton(layout: .list(rows: 7)).padding(18)
                case .empty: V15EmptyState(title: "没有符合条件的账目", explanation: "更改搜索或筛选后重新读取。", actionTitle: "重新读取") { Task { await model.load() } }.padding(18)
                case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.load() } }.padding(18)
                case .loaded:
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, transaction in
                        row(transaction)
                        if index < model.items.count - 1 {
                            Divider().padding(.leading, 14)
                        }
                    }
                    if model.nextCursor != nil {
                        V15ActionButton(
                            model.isLoadingNext ? "正在读取" : "读取下一页",
                            kind: .quiet,
                            disabledReason: model.isLoadingNext ? .init(code: "page_loading", message: "正在读取下一页。", fieldPath: nil) : nil,
                            accessibilityIdentifier: "v151.ios.ledger.next"
                        ) { Task { await model.loadNext() } }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, V15Spacing.xs)
                    }
                }
            }
            .padding(V15IOSLayout.contentPadding)
        }.refreshable { await model.load() }
    }

    private func row(_ transaction: V15Transaction) -> some View {
        let presentation = model.transactionPresentation(transaction)
        return Button {
            resetCategoryEditor()
            selectedID = transaction.id
            Task { await model.select(transaction) }
        } label: {
            HStack(alignment: .top, spacing: 11) {
                Rectangle().fill(transaction.categoryID == nil ? V15Palette.teal.color : Color.clear).frame(width: 3, height: 36)
                VStack(alignment: .leading, spacing: 5) {
                    Text(transaction.title).font(V15Typography.body.weight(.medium)).strikethrough(transaction.voidedAt != nil).foregroundStyle(V15Palette.ink.color).lineLimit(1)
                    Text("\(shortDate(transaction.businessDate)) · \(model.categoryName(transaction.categoryID)) · \(presentation.accountPath)\(presentation.accountEffect.map { " · \($0)" } ?? "")\(transaction.voidedAt == nil ? "" : " · 归档 · 只读")").font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.58)).lineLimit(2)
                }
                Spacer(minLength: 8)
                V15MoneyText(minorUnits: presentation.amountMinor, direction: presentation.direction, includeCurrency: false, font: V15Typography.money)
            }
            .padding(14).contentShape(Rectangle())
            .background {
                if transaction.voidedAt != nil { V15ArchiveHatch() }
                else if selectedID == transaction.id { V15Palette.surfaceRaised.color }
            }
            .opacity(transaction.voidedAt == nil ? 1 : 0.72)
        }.buttonStyle(.plain)
    }

    private var detailSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch model.detailPhase {
                    case .idle, .loading: V15LoadingSkeleton(layout: .inspector)
                    case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.retryDetail() } }
                    case .loaded:
                        if categoryEditing { categoryEditor }
                        else if let transaction = model.selected { detail(transaction) }
                    }
                }.padding(V15IOSLayout.contentPadding)
            }
            .v15IOSScreenCanvas()
            .navigationTitle(categoryEditing ? "修改分类" : "账目详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if categoryEditing {
                        Button("返回") { resetCategoryEditor() }.disabled(model.categoryChangeIsCommitting)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { selectedID = nil }.disabled(model.categoryChangeIsCommitting)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .fullScreenCover(item: $transactionContextDestination) { value in
            V151IOSDestinationHost(services: services, destination: value, onDismiss: refreshRootFacts)
        }
    }

    private func detail(_ transaction: V15Transaction) -> some View {
        let presentation = model.transactionPresentation(transaction)
        return VStack(alignment: .leading, spacing: 17) {
            Text(transaction.title).font(V15Typography.cardTitle)
            V15MoneyText(minorUnits: presentation.amountMinor, direction: presentation.direction, font: V15Typography.moneyLarge)
            if transaction.voidedAt != nil {
                V15ArchiveReadOnlyState {
                    Text("归档 · 只读。可使用下方的恢复入口。").font(V15Typography.secondary)
                }
            }
            V15Section("账目详情") {
                detailRow("类型", transactionKindLabel(transaction.kind))
                detailRow("账户", presentation.accountPath)
                if let effect = presentation.accountEffect { detailRow("当前账户影响", effect) }
                detailRow("分类", model.categoryName(transaction.categoryID))
                detailRow("业务日期", transaction.businessDate)
                detailRow("来源", sourceLabel(transaction.source))
            }
            if let categoryCommitNotice {
                V15ServerFactState(title: "分类已保存", detail: categoryCommitNotice)
            }
            if transaction.categoryID == nil {
                V15ActionButton("设置分类") {
                    categoryID = transaction.categoryID
                    categoryPreviewed = false
                    categoryCommitNotice = nil
                    categoryEditing = true
                }
            }
            V15AdaptiveStack {
                if transaction.reimbursementRelations.isEmpty {
                    V15ActionButton("加入报销", kind: .secondary, disabledReason: reimbursementReason(transaction)) {
                        transactionContextDestination = .reimbursements(transactionID: transaction.id)
                    }
                }
                V15ActionButton(transaction.voidedAt == nil ? "作废" : "恢复", kind: transaction.voidedAt == nil ? .destructive : .secondary, disabledReason: model.disabledReason(for: transaction.voidedAt == nil ? .void : .restore, transaction: transaction)) {
                    Task { if transaction.voidedAt == nil { await model.voidSelected() } else { await model.restoreSelected() } }
                }
            }
            if let planID = transaction.installmentPlanID ?? transaction.installmentRelation?.planID {
                V15ActionButton("查看分期计划", kind: .secondary) {
                    transactionContextDestination = .installments(accountID: transaction.accountID, planID: planID, purchaseTransactionID: nil)
                }
            } else {
                V15ActionButton("改为分期", kind: .secondary, disabledReason: installmentReason(transaction)) {
                    transactionContextDestination = .installments(accountID: transaction.accountID, planID: nil, purchaseTransactionID: transaction.id)
                }
            }
            if !transaction.reimbursementRelations.isEmpty {
                V15Section("关联报销") {
                    ForEach(Array(transaction.reimbursementRelations.enumerated()), id: \.offset) { indexed in
                        let relation = indexed.element
                        V15ActionButton("查看报销单 · \(relation.claimTitle)", kind: .secondary) {
                            transactionContextDestination = .reimbursementClaim(claimID: relation.claimID, partyID: relation.partyID)
                        }
                    }
                }
            }
            mutationState
            V15Section("修改历史") { ForEach(model.revisions) { revision in Text(revision.displayEvent).font(V15Typography.secondary) } }
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View { HStack { Text(title).foregroundStyle(V15Palette.ink.color.opacity(0.55)); Spacer(); Text(value) }.font(V15Typography.secondary).padding(.vertical, 5) }

    @ViewBuilder private var mutationState: some View {
        switch model.mutation {
        case .idle: EmptyView()
        case .working: V15LoadingSkeleton()
        case .reconciled(let message): V15ServerFactState(title: "待同步状态", detail: message)
        case .conflict(let conflict): V15ConflictState(conflict: conflict, changes: model.mutationConflictChanges) { Task { await model.retryDetail() } }
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.retryLastMutation() } }
        }
    }

    private var filterSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.md) {
                Picker("类型", selection: Binding(get: { model.filter.kind }, set: { model.setKind($0) })) { Text("全部").tag(Optional<String>.none); ForEach(V15LedgerReadKind.allCases) { Text($0.displayName).tag(Optional($0.rawValue)) } }
                Picker("账户", selection: Binding(get: { model.filter.accountID }, set: { model.setAccount($0) })) { Text("全部账户").tag(Optional<UUID>.none); ForEach(model.accounts) { Text($0.name).tag(Optional($0.id)) } }
                Picker("分类状态", selection: Binding(get: { model.filter.classification }, set: { model.setClassification($0) })) { Text("全部").tag("all"); Text("已分类").tag("categorized"); Text("未分类").tag("uncategorized") }
                Toggle("包含已作废", isOn: Binding(get: { model.filter.includeVoided }, set: { model.setIncludeVoided($0) }))
                }
                .padding(V15Spacing.md)
            }
            .v15IOSScreenCanvas()
            .navigationTitle("筛选")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("应用") { filtersPresented = false; Task { await model.load() } } } }
        }
    }

    private var categoryEditor: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("确认前会取得这笔账目的最新内容。")
                .font(V15Typography.secondary)
                .foregroundStyle(V15Palette.ink.color.opacity(0.58))
            V15Section("目标分类") {
                Picker("分类", selection: $categoryID) {
                    Text("未分类").tag(Optional<UUID>.none)
                    ForEach(model.categories) { Text($0.name).tag(Optional($0.id)) }
                }
                .disabled(model.categoryChangeIsCommitting)
                .onChange(of: categoryID) { _, _ in categoryPreviewed = false; model.clearCategoryPreview() }
            }
            if categoryPreviewed, let preview = model.categoryChangePreview {
                V15ServerFactState(detail: preview.items.map { "\($0.title)：\($0.previousCategoryName ?? "未分类") → \($0.proposedCategoryName)" }.joined(separator: "\n"))
            }
            if categoryPreviewed {
                V15ActionButton(
                    model.categoryChangeIsCommitting ? "正在提交" : "确认分类",
                    disabledReason: model.categoryChangeIsCommitting
                        ? .init(code: "category_commit_in_flight", message: "正在提交分类，请稍候。", fieldPath: nil)
                        : nil
                ) { Task { await commitDetailCategory() } }
            } else {
                V15ActionButton("查看分类影响", disabledReason: categoryID == nil ? .init(code: "category_required", message: "请先选择分类。", fieldPath: nil) : (model.isOffline ? .init(code: "category_read_requires_network", message: "需要联网取得最新账目。", fieldPath: nil) : nil)) { Task { await readCategoryCurrentFact() } }
            }
            if let failure = model.categoryChangeFailure { V15ServiceErrorState(message: failure.message) { Task { await readCategoryCurrentFact() } } }
        }
    }

    @MainActor private func readCategoryCurrentFact() async {
        guard let id = model.selected?.id, let categoryID else { return }
        await model.loadDetail(transactionID: id)
        guard case .loaded = model.detailPhase else { return }
        await model.previewCategories([id], categoryID: categoryID)
        categoryPreviewed = model.categoryChangePreview != nil
    }

    @MainActor private func commitDetailCategory() async {
        guard let id = model.selected?.id else { return }
        let result = await model.commitPreviewedCategories()
        if result.committedIDs.contains(id) {
            categoryCommitNotice = result.failures.first(where: { $0.id == id })?.message
                ?? "分类已保存；现在显示最新账目。"
            categoryEditing = false
            categoryPreviewed = false
            refreshRootFacts()
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
            returnToToday(loadImmediately: false)
            await model.load()
        }
        _ = await references
    }

    /// A root-fact revision must not reset the user's ledger range, account,
    /// search, or selected detail back to the initial "today" defaults.
    private func refreshPreservingContext() async {
        async let references: Void = model.loadReferences()
        await model.load()
        if let selectedID { await model.loadDetail(transactionID: selectedID) }
        _ = await references
    }

    private func selectAccount(_ id: UUID?) {
        model.setAccount(id)
        Task { await model.load() }
    }

    private func moveToPast() {
        model.setDateFrom("")
        model.setDateTo(shanghaiBusinessDate(daysFromToday: -1))
        Task { await model.load() }
    }

    private func returnToToday(loadImmediately: Bool = true) {
        model.setDateFrom("")
        model.setDateTo(shanghaiBusinessDate(daysFromToday: 0))
        if loadImmediately { Task { await model.load() } }
    }

    private var accountScopeTitle: String {
        guard let id = model.filter.accountID,
              let account = model.accounts.first(where: { $0.id == id }) else { return "全部账户" }
        return account.name
    }

    private func shanghaiBusinessDate(daysFromToday: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let date = calendar.date(byAdding: .day, value: daysFromToday, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func resetCategoryEditor() {
        model.clearCategoryPreview()
        categoryEditing = false
        categoryPreviewed = false
        categoryCommitNotice = nil
        categoryID = nil
    }

    private func reimbursementReason(_ transaction: V15Transaction) -> V15DisabledReason? {
        if transaction.voidedAt != nil { return .init(code: "transaction_voided", message: "已作废账目不能加入报销。", fieldPath: nil) }
        if !["expense", "credit_purchase"].contains(transaction.kind) { return .init(code: "not_reimbursable", message: "只有支出或信用消费可加入报销。", fieldPath: nil) }
        return nil
    }

    private func installmentReason(_ transaction: V15Transaction) -> V15DisabledReason? {
        if transaction.voidedAt != nil { return .init(code: "transaction_voided", message: "已作废账目不能改为分期。", fieldPath: nil) }
        if transaction.kind != "credit_purchase" { return .init(code: "not_credit_purchase", message: "只有信用消费可改为分期。", fieldPath: nil) }
        if transaction.accountID == nil { return .init(code: "credit_account_missing", message: "缺少信用账户，无法安全建立分期。", fieldPath: nil) }
        return nil
    }

    private struct SelectedTransactionID: Identifiable { let id: UUID }
    private struct SelectedAccountID: Identifiable { let id: UUID }
    private struct LedgerRefreshOwner: Hashable { let focusID: UUID?; let revision: UInt64 }
    private func shortDate(_ value: String) -> String { value.count >= 5 ? String(value.suffix(5)) : value }
    private func direction(_ transaction: V15Transaction) -> V15MoneyDirection { switch transaction.kind { case "income", "reimbursement_receipt": .inflow; case "transfer": .neutral; default: .outflow } }
    private func transactionKindLabel(_ value: String) -> String { V15LedgerReadKind(rawValue: value)?.displayName ?? "账目" }
    private func sourceLabel(_ value: String) -> String { V15LedgerReadSource(rawValue: value)?.displayName ?? "其他来源" }
}

private struct V151IOSAccountDetail: View {
    let services: V15Services
    let accountID: UUID
    let recordFactsRevision: UInt64
    let refreshRootFacts: () -> Void
    @State private var model: V15AccountDetailModel
    @State private var contextDestination: V151IOSWorkspace.Destination?
    @Environment(\.dismiss) private var dismiss

    init(services: V15Services, accountID: UUID, recordFactsRevision: UInt64, refreshRootFacts: @escaping () -> Void) {
        self.services = services; self.accountID = accountID; self.recordFactsRevision = recordFactsRevision; self.refreshRootFacts = refreshRootFacts
        _model = State(initialValue: V15AccountDetailModel(services: services))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch model.phase {
                    case .idle, .loading: V15LoadingSkeleton(layout: .inspector)
                    case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await load() } }
                    case .loaded:
                        if let account = model.account { accountContent(account) }
                    }
                }
                .padding(V15IOSLayout.contentPadding)
            }
            .v15IOSScreenCanvas()
            .navigationTitle("账户详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("v151.ios.account-detail.close")
                }
            }
        }
        .task(id: recordFactsRevision) { await load() }
        .fullScreenCover(item: $contextDestination) { value in
            V151IOSDestinationHost(services: services, destination: value, onDismiss: refreshRootFacts)
        }
        .accessibilityIdentifier("v151.ios.account-detail")
    }

    private func accountContent(_ account: V15AccountResponse) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(account.name).font(.title2.weight(.bold))
                    Text(account.kind == .credit ? "当前信用欠款" : "当前可用余额").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.60))
                }
                Spacer()
                if account.archivedAt != nil { Text("归档 · 只读").font(.caption.weight(.semibold)).foregroundStyle(V15Palette.ink.color.opacity(0.58)) }
            }
            V15MoneyText(minorUnits: account.currentBalanceMinor, direction: account.kind == .credit ? .outflow : .balance, font: .largeTitle.bold().monospacedDigit())
            if account.archivedAt != nil {
                V15ArchiveReadOnlyState { Text("归档账户不能在详情层编辑；恢复入口位于账户与分类设置。").font(V15Typography.secondary) }
            }
            V15Section("账户详情", detail: "\(account.usageCount) 项关联") {
                accountRow("类型", accountKind(account.kind))
                accountRow("机构", account.institution ?? "未设置")
                accountRow("尾号", account.lastFour.map { "•••• \($0)" } ?? "未设置")
                accountRow("期初余额", V15MoneyPresentation(minorUnits: account.openingBalanceMinor, direction: .neutral).text)
                if let date = account.openingBalanceAsOfDate { accountRow("期初日期", date) }
            }
            if account.kind == .credit {
                V15Section("信用约束") {
                    accountRow("信用额度", account.creditLimitMinor.map { V15MoneyPresentation(minorUnits: $0, direction: .neutral).text } ?? "未设置")
                    accountRow("账单日", account.statementDay.map { "每月 \($0) 日" } ?? "未设置")
                    accountRow("还款日", account.dueDay.map { "每月 \($0) 日" } ?? "未设置")
                }
                V15AdaptiveStack {
                    V15ActionButton("查看信用账期", kind: .secondary) { contextDestination = .credit(accountID: account.id) }
                    V15ActionButton("分期计划", kind: .secondary) { contextDestination = .installments(accountID: account.id, planID: nil, purchaseTransactionID: nil) }
                }
            }
            V15ActionButton("账户与分类设置", kind: .secondary) { contextDestination = .settings }
        }
    }

    private func accountRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(title).foregroundStyle(V15Palette.ink.color.opacity(0.55)); Spacer(minLength: 16); Text(value).multilineTextAlignment(.trailing) }
            .font(.subheadline).padding(.vertical, 4)
    }
    private func accountKind(_ value: V15AccountKind) -> String { switch value { case .cash: "现金"; case .debit: "储蓄账户"; case .credit: "信用账户"; case .unknown: "未知类型" } }

    @MainActor private func load() async {
        await model.load(accountID: accountID, fresh: true)
    }
}

private struct V151IOSPendingSyncQueue: View {
    let services: V15Services

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("待同步 · \(services.pendingWrites.count)").font(.title2.weight(.bold))
                    Text("这些更改暂未计入汇总；同步成功后会自动更新。")
                        .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.62))
                }
                if let receipt = services.pendingWrites.lastSyncReceipt {
                    V15SuccessReceiptState(title: "同步已完成", detail: receipt)
                    V15ActionButton("收起结果", kind: .secondary) { services.pendingWrites.dismissReceipt() }
                }
                if services.pendingWrites.items.isEmpty {
                    V15EmptyState(title: "没有待同步项目", explanation: "离线记账和离线分类决定会出现在这里。")
                } else {
                    V15ActionButton("同步全部", disabledReason: services.offlineSnapshotAt != nil ? .init(code: "offline", message: "当前仍处于离线状态。", fieldPath: nil) : nil) {
                        Task { await services.pendingWrites.replay(using: services) }
                    }
                    ForEach(services.pendingWrites.items) { item in pendingCard(item) }
                }
            }
            .padding(20)
        }
        .v15IOSScreenCanvas()
        .navigationTitle("待同步")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("v151.ios.pending-sync")
    }

    private func pendingCard(_ item: V15PendingWriteStore.Item) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(V15Palette.yellow.color).frame(width: 3, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.headline).lineLimit(2)
                    Text("\(kindLabel(item.kind)) · \(statusLabel(item))").font(.caption).foregroundStyle(V15Palette.ink.color.opacity(0.60)).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let amount = item.amountMinor { V15MoneyText(minorUnits: amount, direction: .neutral, includeCurrency: false, font: .subheadline.weight(.semibold).monospacedDigit()) }
            }
            if item.status == .requiresDecision || item.status == .outcomeUnknown {
                Text("这项更改不会自动重试。请移除后回到原记录重新操作，或在账目中检查最新状态。")
                    .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.62))
            }
            V15AdaptiveStack(spacing: 8) {
                if item.status == .failed {
                    V15ActionButton("重试", kind: .secondary) {
                        services.pendingWrites.retry(item.id)
                        Task { await services.pendingWrites.replay(using: services) }
                    }
                }
                V15ActionButton("移除", kind: .secondary) { services.pendingWrites.remove(item.id) }
            }
        }
        .padding(14)
        .background(V15Palette.provisional.color, in: RoundedRectangle(cornerRadius: V15IOSLayout.cardCornerRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: V15IOSLayout.cardCornerRadius, style: .continuous).stroke(V15Palette.yellow.color.opacity(0.42)) }
    }

    private func kindLabel(_ value: V15PendingWriteStore.Kind) -> String { value == .transactionCreate ? "新建账目" : "分类决定" }
    private func statusLabel(_ item: V15PendingWriteStore.Item) -> String {
        let value: String
        switch item.status { case .queued: value = "排队中"; case .syncing: value = "同步中"; case .requiresDecision: value = "需要重新决定"; case .outcomeUnknown: value = "结果不明"; case .failed: value = "同步失败" }
        return item.message.map { "\(value) · \($0)" } ?? value
    }
}

private struct V151IOSDestinationHost: View {
    let services: V15Services
    let destination: V151IOSWorkspace.Destination
    let onDismiss: () -> Void
    @State private var governanceTarget: V151IOSWorkspace.Destination?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if governanceTarget != nil { Button("返回设置与治理") { governanceTarget = nil } }
                        else { Button("关闭") { onDismiss(); dismiss() } }
                    }
                }
        }
        .tint(V15Palette.teal.color)
        .background(V15Palette.canvas.color.ignoresSafeArea())
    }
    @ViewBuilder private var content: some View {
        if let governanceTarget {
            destinationContent(governanceTarget)
        } else {
            destinationContent(destination)
        }
    }

    @ViewBuilder private func destinationContent(_ value: V151IOSWorkspace.Destination) -> some View {
        switch value {
        case .futureTarget(let target): futureTargetContent(target)
        case .credit(let accountID): V15CreditView(services: services, initialAccountID: accountID)
        case .installments(let accountID, let planID, let purchaseTransactionID):
            V15InstallmentView(
                services: services,
                initialAccountID: accountID,
                initialPlanID: planID,
                initialPurchaseTransactionID: purchaseTransactionID
            )
        case .reimbursements(let transactionID): V15ReimbursementView(services: services, initialTransactionID: transactionID)
        case .reimbursementClaim(let claimID, let partyID):
            V15ReimbursementView(services: services, initialClaimID: claimID, initialPartyID: partyID)
        case .cashFlow: V15CashFlowView(services: services)
        case .reports: V15ReportingView(services: services)
        case .settings:
            V15SettingsView(
                services: services,
                onOpenPendingSync: { governanceTarget = .pendingSync }
            )
        case .pendingSync: V151IOSPendingSyncQueue(services: services)
        }
    }

    @ViewBuilder private func futureTargetContent(_ target: V15FutureOpenTarget) -> some View {
        switch target {
        case .creditCycle(let cycle):
            V15CreditView(services: services, initialCycle: cycle)
        case .reimbursementParty(let claim, let partyID):
            V15ReimbursementView(services: services, initialClaim: claim, initialPartyID: partyID)
        case .cashFlowItem(let item):
            V15CashFlowView(services: services, initialItem: item)
        }
    }

}

#endif
