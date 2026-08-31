import SwiftUI

#if os(macOS)
public struct V15FutureTimelineMacView: View {
    @State private var model: V15FutureTimelineModel
    @State private var selectedID: String?
    private let initialAutoLoadNext: Bool
    private let onOpen: @MainActor (V15FutureOpenTarget) -> Void
    public init(services: V15Services, offlineSnapshotAt: Date? = nil, initialAutoLoadNext: Bool = false, onOpen: @escaping @MainActor (V15FutureOpenTarget) -> Void = { _ in }) { _model = State(initialValue: .init(services: services, offlineSnapshotProvider: { offlineSnapshotAt })); self.initialAutoLoadNext = initialAutoLoadNext; self.onOpen = onOpen }
    public var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 190, idealWidth: 220, maxWidth: 280)
            spine.frame(minWidth: 390, idealWidth: 520)
            inspector.frame(minWidth: 280, idealWidth: 350)
        }.background(V15Palette.paper.color).task { async let timeline: Void = model.reload(); async let accounts: Void = model.loadAccountOptions(); _ = await (timeline, accounts); if initialAutoLoadNext { await model.loadNextPage() } }.accessibilityElement(children: .contain).accessibilityIdentifier("v15.f3a.timeline.macos")
    }
    private var sidebar: some View { VStack(alignment: .leading, spacing: V15Spacing.md) {
        Text("已知未来").font(V15Typography.surfaceTitle)
        Text("只读时间线").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
        ForEach([7, 30, 60, 90], id: \.self) { days in Button("未来 \(days) 天") { Task { await model.setWindowDays(days) } }.buttonStyle(.plain).padding(V15Spacing.sm).frame(maxWidth: .infinity, alignment: .leading).background(model.selectedWindowDays == days ? V15Palette.selected.color : .clear, in: RoundedRectangle(cornerRadius: V15Radius.control)).accessibilityIdentifier("v15.f3a.window.\(days)") }
        Divider(); Menu { Button("全部账户") { Task { await model.setAccount(nil) } }.accessibilityIdentifier("v15.f3a.account.all"); ForEach(model.accountOptions) { account in Button(accountLabel(account)) { Task { await model.setAccount(account.id) } }.accessibilityIdentifier("v15.f3a.account.\(account.id)") } } label: { Label(model.selectedAccountDisplayName ?? (model.selectedAccountID == nil ? "全部账户" : "已筛选账户"), systemImage: "line.3.horizontal.decrease.circle") }.disabled(model.isLoadingAccountOptions).accessibilityIdentifier("v15.f3a.account-filter")
        Text(model.selectedAccountDisplayName ?? (model.selectedAccountID == nil ? "全部账户" : "已保留筛选账户")).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).accessibilityIdentifier("v15.f3a.account.selection")
        accountOptionsNotice
        Spacer(); if let at = model.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: at).accessibilityIdentifier("v15.f3a.offline") }
    }.padding(V15Spacing.md) }
    @ViewBuilder private var accountOptionsNotice: some View { switch model.accountOptionsPhase { case .idle: EmptyView(); case .loading: Text("正在读取可筛选账户，筛选暂不可用。 ").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).accessibilityIdentifier("v15.f3a.account-filter-reason"); case .loaded: EmptyView(); case .empty: Text("没有可筛选账户；可继续查看全部账户。 ").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).accessibilityIdentifier("v15.f3a.account-empty"); case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.retryAccountOptions() } }.accessibilityIdentifier("v15.f3a.account-error") } }
    private func accountLabel(_ account: V15AccountResponse) -> String { "\(account.name) · \(accountKindLabel(account.kind))" }
    private func accountKindLabel(_ kind: V15AccountKind) -> String {
        switch kind {
        case .cash: "现金账户"
        case .debit: "借记账户"
        case .credit: "信用账户"
        case .unknown: "未知账户"
        }
    }
    @ViewBuilder private var spine: some View { ScrollView { VStack(alignment: .leading, spacing: V15Spacing.md) {
        HStack { VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text("未来日程").font(V15Typography.cardTitle); Text(model.meta.map { "更新于 \(V15TodayReadModel.shanghaiDateLabel($0.asOf))" } ?? "正在读取未来事项").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }; Spacer(); Button { Task { await model.reload() } } label: { Image(systemName: V15Symbol.retry) }.accessibilityIdentifier("v15.f3a.reload") }
        switch model.phase {
        case .idle, .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f3a.loading")
        case .failed(let f): V15ServiceErrorState(message: f.message) { Task { await model.reload() } }.accessibilityIdentifier("v15.f3a.error")
        case .requiresReload(let f): V15Section("未来事项已更新") { Text(f.message); V15ActionButton("取最新数据重新决定") { Task { await model.reload() } }.accessibilityIdentifier("v15.f3a.conflict.reload") }.accessibilityIdentifier("v15.f3a.conflict")
        case .empty: V15EmptyState(title: "当前窗口没有已知未来事项", explanation: "这不代表未来没有变化。").accessibilityIdentifier("v15.f3a.empty")
        case .loaded: rows
        }
    }.padding(V15Spacing.md) } }
    private var rows: some View { VStack(alignment: .leading, spacing: V15Spacing.xs) { ForEach(model.events) { event in Button { selectedID = event.id; model.openInspector(event) } label: { V15FutureEventRow(event: event).overlay(alignment: .leading) { Rectangle().fill(V15Palette.teal.color).frame(width: 3).opacity(selectedID == event.id ? 1 : 0) } }.buttonStyle(.plain).v15PlatformHitArea().accessibilityIdentifier("v15.f3a.event.\(event.id)") }
        if model.hasNextPage { V15ActionButton("读取下一页", kind: .secondary, disabledReason: model.isLoadingNextPage ? .init(code: "loading_next_page", message: "正在读取下一页。", fieldPath: nil) : nil) { Task { await model.loadNextPage() } }.keyboardShortcut(.downArrow, modifiers: [.command, .option]).accessibilityIdentifier("v15.f3a.next") }
        if let f = model.pageFailure { V15ServiceErrorState(message: f.message) { Task { await model.retryNextPage() } }.accessibilityIdentifier("v15.f3a.page-error") }
    } }
    @ViewBuilder private var inspector: some View { ScrollView { VStack(alignment: .leading, spacing: V15Spacing.md) { HStack { Text("详情").font(V15Typography.cardTitle); Spacer(); Button("关闭") { selectedID = nil; model.closeInspector() }.buttonStyle(.borderless).accessibilityIdentifier("v15.f3a.inspector.close") }
        switch model.inspectorPhase { case .idle: V15EmptyState(title: "选择一个未来事项", explanation: "此处只显示本地只读事件说明。")
        case .unavailable(let message): V15EmptyState(title: "暂不可打开", explanation: message).accessibilityIdentifier("v15.f3a.inspector.unavailable")
        case .showing(let event): V15Section("未来事项") {
            V15FutureEventRow(event: event)
            Text("打开前会重新核验这项记录的最新归属，不会提交任何更改。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
            switch model.openPhase {
            case .idle:
                V15ActionButton("打开所属记录", symbol: "arrow.up.right.square") { Task { if let target = await model.resolveOpenTarget(event) { onOpen(target) } } }.accessibilityIdentifier("v15.f3a.inspector.open")
            case .loading:
                V15LoadingSkeleton(layout: .compact)
            case .failed(let message):
                V15ServiceErrorState(message: message) { Task { if let target = await model.resolveOpenTarget(event) { onOpen(target) } } }
            }
        }.accessibilityIdentifier("v15.f3a.inspector") }
    }.padding(V15Spacing.md) } }
}

private struct V15FutureEventRow: View {
    let event: V15FutureEvent
    var body: some View { HStack(alignment: .top, spacing: V15Spacing.sm) { VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text(event.date).font(V15Typography.label).foregroundStyle(V15Palette.teal.color); Text(event.title).font(V15Typography.body.weight(.semibold)).foregroundStyle(V15Palette.ink.color).fixedSize(horizontal: false, vertical: true); Text("\(certainty) · \(source)").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }; Spacer(minLength: V15Spacing.xs); V15MoneyText(minorUnits: event.amountMinor, direction: event.direction == .inflow ? .inflow : .outflow, font: V15Typography.secondary).lineLimit(1).minimumScaleFactor(0.72) }.padding(V15Spacing.md).frame(maxWidth: .infinity, alignment: .leading).background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.card)).overlay { RoundedRectangle(cornerRadius: V15Radius.card).stroke(V15Palette.hairline.color, lineWidth: 1) } }
    private var certainty: String { switch event.certainty { case .exactDue: "到期日已确认"; case .confirmed: "已确认"; case .expected: "预计"; case .scheduled: "已排期" } }
    private var source: String { switch event.sourceType { case .creditCycle: "信用账期"; case .reimbursementParty: "报销对象"; case .cashFlowItem: "现金流事项" } }
}

/// Gallery-only deterministic evidence for the real model's local page-error
/// state.  The production route reaches the same state through `loadNextPage`;
/// this variant lets the snapshot renderer capture it without racing its
/// short off-screen RunLoop.
struct V15FutureTimelineMacPageErrorEvidence: View {
    private let event = V15FutureEvent(sourceType: .creditCycle, sourceID: V15F3AFixtures.creditID, date: "2026-08-20", direction: .outflow, amountMinor: 922_337_203_685_477_580, certainty: .exactDue, title: "超长中文信用账期到期事项，用于确认无截断展示", deepLink: "fiscal://credit/cycles/\(V15F3AFixtures.creditID.uuidString)", accountID: V15F3AFixtures.accountID, claimID: nil, partyID: nil, cycleID: V15F3AFixtures.creditID)
    var body: some View { HSplitView { VStack(alignment: .leading, spacing: V15Spacing.md) { Text("已知未来").font(V15Typography.surfaceTitle); Text("只读时间线").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)); ForEach([7,30,60,90], id: \.self) { Text("未来 \($0) 天").padding(V15Spacing.sm).frame(maxWidth: .infinity, alignment: .leading).background($0 == 30 ? V15Palette.selected.color : .clear, in: RoundedRectangle(cornerRadius: V15Radius.control)) }; Spacer() }.padding(V15Spacing.md).frame(minWidth: 190)
        ScrollView { VStack(alignment: .leading, spacing: V15Spacing.md) { Text("未来日程").font(V15Typography.cardTitle); Text("上海业务日").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)); V15FutureEventRow(event: event); V15ActionButton("读取下一页", kind: .secondary) {}.accessibilityIdentifier("v15.f3a.next"); V15ServiceErrorState(message: "暂时无法读取更多未来事项。") {}.accessibilityIdentifier("v15.f3a.page-error") }.padding(V15Spacing.md) }.frame(minWidth: 390)
        VStack(alignment: .leading, spacing: V15Spacing.md) { Text("详情").font(V15Typography.cardTitle); Spacer(); V15EmptyState(title: "选择一个未来事项", explanation: "这里显示只读详情。"); Spacer() }.padding(V15Spacing.md).frame(minWidth: 280) }.background(V15Palette.paper.color).accessibilityIdentifier("v15.f3a.timeline.macos") }
}
#endif
