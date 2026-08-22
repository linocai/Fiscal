import SwiftUI

#if os(iOS)
public struct V15FutureTimelineView: View {
    @State private var model: V15FutureTimelineModel
    @State private var inspectorShown = false
    private let initialAutoLoadNext: Bool
    public init(services: V15Services, offlineSnapshotAt: Date? = nil, initialAutoLoadNext: Bool = false) {
        _model = State(initialValue: .init(services: services, offlineSnapshotProvider: { offlineSnapshotAt }))
        self.initialAutoLoadNext = initialAutoLoadNext
    }
    public var body: some View {
        NavigationStack {
            ScrollView { VStack(alignment: .leading, spacing: V15Spacing.section) {
                header
                if let at = model.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: at).accessibilityIdentifier("v15.f3a.offline") }
                windowPicker
                accountPicker
                surface
            }.padding(V15Spacing.md).frame(maxWidth: 680, alignment: .leading) }
            .background(V15Palette.paper.color).navigationTitle("已知未来")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { Task { await model.reload() } } label: { Label("重新读取", systemImage: V15Symbol.retry) }.accessibilityIdentifier("v15.f3a.reload") } }
        }
        .sheet(isPresented: $inspectorShown, onDismiss: { model.closeInspector() }) { inspector.presentationDetents([.medium, .large]) }
        .task { async let timeline: Void = model.reload(); async let accounts: Void = model.loadAccountOptions(); _ = await (timeline, accounts); if initialAutoLoadNext { await model.loadNextPage() } }
        .accessibilityIdentifier("v15.f3a.timeline.ios")
    }
    private var header: some View { VStack(alignment: .leading, spacing: V15Spacing.xs) {
        Text("未来时间线").font(V15Typography.surfaceTitle).foregroundStyle(V15Palette.ink.color)
        Text(model.meta.map { "服务器截至 \(V15TodayReadModel.shanghaiDateLabel($0.asOf)) · 数据版本 \($0.dataRevision)" } ?? "仅展示服务器已经确认的未来事项，不计算预测。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
    }.accessibilityIdentifier("v15.f3a.header") }
    private var windowPicker: some View { Picker("时间窗口", selection: Binding(get: { model.selectedWindowDays }, set: { value in Task { await model.setWindowDays(value) } })) {
        Text("7天").tag(7); Text("30天").tag(30); Text("60天").tag(60); Text("90天").tag(90)
    }.pickerStyle(.segmented).accessibilityIdentifier("v15.f3a.window") }
    private var accountPicker: some View {
        VStack(alignment: .leading, spacing: V15Spacing.xxs) {
            Menu {
                Button("全部账户") { Task { await model.setAccount(nil) } }.accessibilityIdentifier("v15.f3a.account.all")
                ForEach(model.accountOptions) { account in
                    Button(accountLabel(account)) { Task { await model.setAccount(account.id) } }.accessibilityIdentifier("v15.f3a.account.\(account.id)")
                }
            } label: { Label(model.selectedAccountDisplayName ?? (model.selectedAccountID == nil ? "全部账户" : "已筛选账户"), systemImage: "line.3.horizontal.decrease.circle") }
                .disabled(model.isLoadingAccountOptions)
                .accessibilityIdentifier("v15.f3a.account-filter")
            Text(model.selectedAccountDisplayName ?? (model.selectedAccountID == nil ? "全部账户" : "已保留筛选账户"))
                .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).accessibilityIdentifier("v15.f3a.account.selection")
            accountOptionsNotice
        }
    }
    @ViewBuilder private var accountOptionsNotice: some View {
        switch model.accountOptionsPhase {
        case .idle: EmptyView()
        case .loading: Text("正在读取可筛选账户，筛选暂不可用。 ").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).accessibilityIdentifier("v15.f3a.account-filter-reason")
        case .loaded: EmptyView()
        case .empty: Text("没有可筛选账户；可继续查看全部账户。 ").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).accessibilityIdentifier("v15.f3a.account-empty")
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.retryAccountOptions() } }.accessibilityIdentifier("v15.f3a.account-error")
        }
    }
    private func accountLabel(_ account: V15AccountResponse) -> String { "\(account.name) · \(accountKindLabel(account.kind))" }
    private func accountKindLabel(_ kind: V15AccountKind) -> String {
        switch kind {
        case .cash: "现金账户"
        case .debit: "借记账户"
        case .credit: "信用账户"
        case .unknown: "未知账户"
        }
    }
    @ViewBuilder private var surface: some View {
        switch model.phase {
        case .idle, .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f3a.loading")
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.reload() } }.accessibilityIdentifier("v15.f3a.error")
        case .requiresReload(let failure): V15Section("未来事项版本已变化") { Text(failure.message).font(V15Typography.body); V15ActionButton("取最新数据重新决定", symbol: V15Symbol.conflict) { Task { await model.reload() } }.accessibilityIdentifier("v15.f3a.conflict.reload") }.accessibilityIdentifier("v15.f3a.conflict")
        case .empty: V15EmptyState(title: "当前窗口没有已知未来事项", explanation: "这只表示服务器在此窗口没有返回已知事项，不代表未来没有变化。").accessibilityIdentifier("v15.f3a.empty")
        case .loaded: timeline
        }
    }
    private var timeline: some View { VStack(alignment: .leading, spacing: V15Spacing.sm) {
        if let window = model.serverWindow { Text("上海业务日：\(window.dateFrom) 至 \(window.dateTo)").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }
        ForEach(model.events) { event in Button { model.openInspector(event); inspectorShown = true } label: { V15FutureEventRow(event: event) }.buttonStyle(.plain).v15PlatformHitArea().accessibilityIdentifier("v15.f3a.event.\(event.id)") }
        if model.hasNextPage { V15ActionButton("读取下一页", kind: .secondary, disabledReason: model.isLoadingNextPage ? .init(code: "loading_next_page", message: "正在读取下一页。", fieldPath: nil) : nil) { Task { await model.loadNextPage() } }.accessibilityIdentifier("v15.f3a.next") }
        if let failure = model.pageFailure { V15ServiceErrorState(message: failure.message) { Task { await model.retryNextPage() } }.accessibilityIdentifier("v15.f3a.page-error") }
    }.accessibilityElement(children: .contain).accessibilityIdentifier("v15.f3a.events") }
    @ViewBuilder private var inspector: some View { switch model.inspectorPhase {
        case .idle: V15EmptyState(title: "选择一个未来事项", explanation: "这里只显示当前条目的本地只读说明。")
        case .unavailable(let message): V15EmptyState(title: "暂不可打开", explanation: message).accessibilityIdentifier("v15.f3a.inspector.unavailable")
        case .showing(let item): ScrollView { VStack(alignment: .leading, spacing: V15Spacing.md) { HStack { Text("未来事项检查器").font(V15Typography.cardTitle); Spacer(); Button("关闭") { inspectorShown = false }.accessibilityIdentifier("v15.f3a.inspector.close") }; V15FutureEventRow(event: item); V15Section("只读说明") { Text("当前阶段只展示该事项，不会打开后续领域页面，也不会提交任何变更。") .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) } }.padding(V15Spacing.md) }.accessibilityIdentifier("v15.f3a.inspector")
        } }
}

struct V15FutureEventRow: View {
    let event: V15FutureEvent
    var body: some View { HStack(alignment: .top, spacing: V15Spacing.sm) { VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text(event.date).font(V15Typography.label).foregroundStyle(V15Palette.teal.color); Text(event.title).font(V15Typography.body.weight(.semibold)).foregroundStyle(V15Palette.ink.color).fixedSize(horizontal: false, vertical: true); Text("\(label(event.certainty)) · \(sourceLabel(event.sourceType))").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }; Spacer(minLength: V15Spacing.xs); V15MoneyText(minorUnits: event.amountMinor, direction: event.direction == .inflow ? .inflow : .outflow, font: V15Typography.secondary).lineLimit(1).minimumScaleFactor(0.72) }.padding(V15Spacing.md).frame(maxWidth: .infinity, alignment: .leading).background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.card)).overlay { RoundedRectangle(cornerRadius: V15Radius.card).stroke(V15Palette.hairline.color, lineWidth: 1) }.accessibilityElement(children: .combine) }
    private func label(_ certainty: V15FutureEventCertainty) -> String { switch certainty { case .exactDue: "到期日已确认"; case .confirmed: "已确认"; case .expected: "预计"; case .scheduled: "已排期" } }
    private func sourceLabel(_ source: V15FutureEventSource) -> String { switch source { case .creditCycle: "信用账期"; case .reimbursementParty: "报销对象"; case .cashFlowItem: "现金流事项" } }
}
#endif
