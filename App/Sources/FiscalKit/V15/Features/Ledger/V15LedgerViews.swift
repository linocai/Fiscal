import SwiftUI

public struct V15LedgerLibraryView: View {
    @State private var model: V15LedgerModel
    @State private var detailPresented = false
    @State private var filtersPresented = false
    @State private var filterTask: Task<Void, Never>?
    private let initialDetailID: UUID?
    public init(services: V15Services, offlineSnapshotAt: Date? = nil, initialDetailID: UUID? = nil) { _model = State(initialValue: V15LedgerModel(services: services, offlineSnapshotAt: offlineSnapshotAt)); self.initialDetailID = initialDetailID }
    public var body: some View {
#if os(iOS)
        NavigationStack {
            VStack(spacing: 0) { V15LedgerSearchBar(model: model, showFilters: { filtersPresented = true }); Divider(); V15LedgerList(model: model, open: open) }
                .background(V15Palette.paper.color).navigationTitle("账目")
        }
        .sheet(isPresented: $detailPresented) { V15LedgerDetail(model: model).presentationDetents([.large]).accessibilityIdentifier("v15.f1b.detail.sheet") }
        .sheet(isPresented: $filtersPresented) { NavigationStack { V15LedgerFilters(model: model).navigationTitle("筛选账目").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { filtersPresented = false } } } }.accessibilityIdentifier("v15.f1b.filters.sheet") }
        .accessibilityIdentifier("v15.f1b.ledger.ios")
        .task { async let references: Void = model.loadReferences(); await model.load(); _ = await references; if let initialDetailID { detailPresented = true; await model.loadDetail(transactionID: initialDetailID) } }
        .onChange(of: model.filter) { _, _ in scheduleFilterLoad() }
#else
        HStack(spacing: 0) {
            VStack(spacing: 0) { V15LedgerSearchBar(model: model, showFilters: { filtersPresented.toggle() }); if filtersPresented { V15LedgerFilters(model: model).padding(.horizontal, V15Spacing.md) }; Divider(); V15LedgerList(model: model, open: open) }.frame(minWidth: 410, idealWidth: 540, maxWidth: .infinity)
            Divider(); V15LedgerDetail(model: model).frame(width: 370)
        }.background(V15Palette.paper.color).accessibilityIdentifier("v15.f1b.ledger.macos")
        .task { async let references: Void = model.loadReferences(); await model.load(); _ = await references; if let initialDetailID { await model.loadDetail(transactionID: initialDetailID) } }
        .onChange(of: model.filter) { _, _ in scheduleFilterLoad() }
#endif
    }
    private func open(_ transaction: V15Transaction) { detailPresented = true; Task { await model.select(transaction) } }
    private func scheduleFilterLoad() {
        filterTask?.cancel()
        filterTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300)); guard !Task.isCancelled else { return }
            await model.load()
        }
    }
}

private struct V15LedgerSearchBar: View {
    @Bindable var model: V15LedgerModel
    let showFilters: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.sm) {
            V15SearchField(text: Binding(get: { model.filter.query ?? "" }, set: { model.setQuery($0) })).accessibilityIdentifier("v15.f1b.search")
            HStack(spacing: V15Spacing.sm) {
                Button(action: showFilters) { Label("筛选", systemImage: "line.3.horizontal.decrease.circle") }.buttonStyle(.plain).v15PlatformHitArea().accessibilityIdentifier("v15.f1b.filters")
                if !model.filterIssues.isEmpty { Label("筛选项需修改", systemImage: V15Symbol.warning).font(V15Typography.secondary).foregroundStyle(V15Palette.teal.color) }
                Spacer(minLength: 0)
                Button { Task { await model.load() } } label: { Label("刷新", systemImage: V15Symbol.retry) }.buttonStyle(.plain).v15PlatformHitArea().accessibilityIdentifier("v15.f1b.refresh")
            }
        }.padding(V15Spacing.md).accessibilityElement(children: .contain).accessibilityLabel("搜索与筛选账目")
    }
}

private struct V15LedgerFilters: View {
    @Bindable var model: V15LedgerModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: V15Spacing.md) {
                V15Section("范围") {
                    Menu { Button("全部类型") { model.setKind(nil) }.accessibilityIdentifier("v15.f1b.filter.kind.all"); ForEach(V15LedgerReadKind.allCases) { kind in Button(kind.displayName) { model.setKind(kind.rawValue) }.accessibilityIdentifier("v15.f1b.filter.kind.\(kind.rawValue)") } } label: { filterMenuLabel("交易类型", value: V15LedgerReadKind(rawValue: model.filter.kind ?? "")?.displayName ?? "全部类型") }.accessibilityIdentifier("v15.f1b.filter.kind")
                    Picker("账户", selection: Binding(get: { model.filter.accountID }, set: { model.setAccount($0) })) { Text("全部账户").tag(UUID?.none); ForEach(model.accounts) { Text($0.name).tag(Optional($0.id)) } }.pickerStyle(.menu).accessibilityIdentifier("v15.f1b.filter.account")
                    Picker("分类", selection: Binding(get: { model.filter.categoryID }, set: { model.setCategory($0) })) { Text("全部分类").tag(UUID?.none); ForEach(model.categories) { Text($0.name).tag(Optional($0.id)) } }.pickerStyle(.menu).accessibilityIdentifier("v15.f1b.filter.category")
                    Picker("归类", selection: Binding(get: { model.filter.classification }, set: { model.setClassification($0) })) { Text("全部").tag("all"); Text("已分类").tag("categorized"); Text("未分类").tag("uncategorized") }.pickerStyle(.menu).accessibilityIdentifier("v15.f1b.filter.classification")
                    Menu { Button("全部来源") { model.setSource(nil) }.accessibilityIdentifier("v15.f1b.filter.source.all"); ForEach(V15LedgerReadSource.allCases) { source in Button(source.displayName) { model.setSource(source.rawValue) }.accessibilityIdentifier("v15.f1b.filter.source.\(source.rawValue)") } } label: { filterMenuLabel("来源", value: V15LedgerReadSource(rawValue: model.filter.source ?? "")?.displayName ?? "全部来源") }.accessibilityIdentifier("v15.f1b.filter.source")
                    Toggle("包含已作废账目", isOn: Binding(get: { model.filter.includeVoided }, set: { model.setIncludeVoided($0) })).accessibilityIdentifier("v15.f1b.include-voided")
                }
                V15Section("业务日期（上海）") {
                    V15Field("开始日期", text: Binding(get: { model.dateFromText }, set: { model.setDateFrom($0) }), prompt: "YYYY-MM-DD", issues: model.filterIssues.filter { $0.fieldPath == "date_from" }).accessibilityIdentifier("v15.f1b.filter.date-from")
                    V15Field("结束日期", text: Binding(get: { model.dateToText }, set: { model.setDateTo($0) }), prompt: "YYYY-MM-DD", issues: model.filterIssues.filter { $0.fieldPath == "date_to" }).accessibilityIdentifier("v15.f1b.filter.date-to")
                }
                V15Section("金额（元）") {
                    V15Field("最低金额", text: Binding(get: { model.amountMinText }, set: { model.setAmountMin($0) }), prompt: "例如 12.50", issues: model.filterIssues.filter { $0.fieldPath == "amount_min" }).accessibilityIdentifier("v15.f1b.filter.min")
                    V15Field("最高金额", text: Binding(get: { model.amountMaxText }, set: { model.setAmountMax($0) }), prompt: "例如 100.00", issues: model.filterIssues.filter { $0.fieldPath == "amount_max" }).accessibilityIdentifier("v15.f1b.filter.max")
                }
            }.padding(.vertical, V15Spacing.md)
        }.accessibilityIdentifier("v15.f1b.filters.content")
    }
    private func filterMenuLabel(_ title: String, value: String) -> some View { HStack { Text(title); Spacer(); Text(value).foregroundStyle(V15Palette.ink.color.opacity(0.66)); Image(systemName: "chevron.up.chevron.down").accessibilityHidden(true) }.font(V15Typography.body) }
}

private struct V15LedgerList: View {
    let model: V15LedgerModel; let open: (V15Transaction) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let snapshotAt = model.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: snapshotAt).padding(V15Spacing.md).accessibilityIdentifier("v15.f1b.offline") }
                switch model.phase {
                case .idle, .loading: V15LoadingSkeleton().padding(V15Spacing.md)
                case .empty: V15EmptyState(title: "没有符合条件的账目", explanation: "更改搜索或筛选条件后可以重新读取。", actionTitle: "重新读取", action: { Task { await model.load() } }).padding(V15Spacing.md)
                case .failed(let failure): V15ServiceErrorState(message: failure.message, retry: { Task { await model.load() } }).padding(V15Spacing.md)
                case .loaded:
                    ForEach(model.items, id: \.id) { transaction in
                        V15LedgerRow(title: transaction.title, detail: transactionDetail(transaction), amountMinor: transaction.amountMinor, direction: direction(transaction), marker: transaction.voidedAt == nil ? .ordinary : .archive, action: { open(transaction) }).accessibilityIdentifier("v15.f1b.row.\(transaction.id.uuidString)")
                        Divider().padding(.leading, V15Spacing.md)
                    }
                    nextPage
                }
            }
        }.refreshable { await model.load() }.accessibilityIdentifier("v15.f1b.list")
    }
    @ViewBuilder private var nextPage: some View {
        if let failure = model.nextPageFailure { V15ServiceErrorState(message: failure.message, retry: { Task { await model.loadNext() } }).padding(V15Spacing.md).accessibilityIdentifier("v15.f1b.next-page.error") }
        if model.nextCursor != nil { V15ActionButton(model.isLoadingNext ? "正在读取下一页" : "读取下一页", symbol: "chevron.down", disabledReasons: model.isLoadingNext ? [.init(code: "page_loading", message: "正在读取下一页。", fieldPath: nil)] : [], action: { Task { await model.loadNext() } }).padding(V15Spacing.md).accessibilityIdentifier("v15.f1b.next-page") }
    }
}

private struct V15LedgerDetail: View {
    let model: V15LedgerModel
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: V15Spacing.md) {
            switch model.detailPhase {
            case .idle: V15EmptyState(title: "选择一笔账目", explanation: "这里显示服务器确认的分录、版本与历史。")
            case .loading: V15LoadingSkeleton()
            case .failed(let failure): V15ServiceErrorState(message: failure.message, retry: { Task { await model.retryDetail() } })
            case .loaded: if let selected = model.selected { detail(selected) }
            }
            if let error = model.deepLinkError { V15ServiceErrorState(message: error, retry: { Task { await model.retryDetail() } }) }
        }.padding(V15Spacing.md) }.background(V15Palette.paper.color).accessibilityIdentifier("v15.f1b.detail")
    }
    @ViewBuilder private func detail(_ transaction: V15Transaction) -> some View {
        V15Section("可用操作") { actions(transaction) }
        V15Section("服务器事实", detail: "v\(transaction.version)") {
            Text(transaction.title).font(V15Typography.surfaceTitle).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("v15.f1b.detail.title")
            V15MoneyText(minorUnits: transaction.amountMinor, direction: direction(transaction), font: V15Typography.money)
            Text("业务日（上海）：\(transaction.businessDate) · 来源：\(transaction.source)").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
            Text("账户：\(model.accountName(transaction.accountID))").font(V15Typography.secondary)
            if transaction.destinationAccountID != nil { Text("目标账户：\(model.accountName(transaction.destinationAccountID))").font(V15Typography.secondary) }
            Text("分类：\(model.categoryName(transaction.categoryID))").font(V15Typography.secondary)
            if let cycle = model.selectedCycle { Text("信用账期：\(cycle.periodStart) 至 \(cycle.periodEnd) · 还款日 \(cycle.dueDate)").font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true) }
            if let cycleReadError = model.cycleReadError { Text(cycleReadError).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }
            if transaction.voidedAt != nil { V15ArchiveReadOnlyState { Text("该账目已作废；当前服务器没有提供恢复授权。").font(V15Typography.secondary) } }
        }
        V15Section("分录") { ForEach(transaction.postings, id: \.id) { posting in HStack { Text(postingRole(posting.role) + " · " + model.accountName(posting.accountID)).font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true); Spacer(); V15MoneyText(minorUnits: posting.amountMinor, direction: posting.amountMinor < 0 ? .outflow : .inflow, font: V15Typography.secondary) } } }
        V15Section("版本历史") { if model.revisions.isEmpty { Text("服务器没有返回可读版本历史。").font(V15Typography.secondary) } else { ForEach(model.revisions) { revision in Text("v\(revision.version) · \(revision.event)").font(V15Typography.secondary).accessibilityIdentifier("v15.f1b.revision.\(revision.version)") } } }
        V15Section("来源与关联") { provenance }; mutationState
    }
    @ViewBuilder private func actions(_ transaction: V15Transaction) -> some View {
        let void = transaction.availableActions.first(where: { $0.action == "void" })
        if let void {
            let capability = model.isOffline ? V15Capability.disabled(action: "void", reason: .init(code: "offline_read_only", message: "离线快照仅可查看，无法提交更改。", fieldPath: nil)) : void.capability(knownActions: ["void"])
            switch capability { case .enabled: V15InspectorAction("作废账目", detail: "此操作以服务器版本 v\(transaction.version) 为准。", action: { Task { await model.voidSelected() } }).accessibilityIdentifier("v15.f1b.void"); case .disabled(_, let reason): V15InspectorAction("作废账目", detail: "服务器未授权作废。", disabledReason: reason, action: {}).accessibilityIdentifier("v15.f1b.void.disabled") }
        } else { Text(V15DisabledReason.unknownCapability.message).font(V15Typography.secondary).accessibilityIdentifier("v15.f1b.no-action") }
    }
    @ViewBuilder private var provenance: some View { if let provenance = model.provenance { Text("来源：\(provenance.source)").font(V15Typography.secondary); ForEach(provenance.links) { link in VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text("\(link.sourceType) → \(link.targetType)").font(V15Typography.secondary.weight(.medium)); if safeReadOnlyDestination(link) != nil { Text("关联事实：\(link.targetType)").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) } } } } else { Text("正在读取服务器来源关系。").font(V15Typography.secondary) } }
    @ViewBuilder private var mutationState: some View { switch model.mutation { case .idle: EmptyView(); case .working: V15LoadingSkeleton(); case .reconciled(let message): V15ServerFactState(title: "服务器读回", detail: message); case .conflict(let conflict): V15ConflictState(conflict: conflict, changes: model.mutationConflictChanges, reload: { Task { await model.retryDetail() } }); case .failed(let failure): V15ServiceErrorState(message: failure.message, retry: { Task { await model.retryLastMutation() } }) } }
    private func safeReadOnlyDestination(_ link: V15TransactionProvenanceLink) -> String? { guard let deepLink = link.deepLink, URL(string: deepLink)?.scheme == "fiscal" else { return nil }; return link.targetType }
}

private func postingRole(_ role: String) -> String { switch role { case "debit": "借方"; case "credit": "贷方"; default: "分录" } }
private func direction(_ transaction: V15Transaction) -> V15MoneyDirection { switch transaction.kind { case "income", "reimbursement_receipt": .inflow; case "transfer": .neutral; default: .outflow } }
private func transactionDetail(_ transaction: V15Transaction) -> String { "\(transaction.businessDate) · \(transaction.source)\(transaction.voidedAt == nil ? "" : " · 已作废")" }
