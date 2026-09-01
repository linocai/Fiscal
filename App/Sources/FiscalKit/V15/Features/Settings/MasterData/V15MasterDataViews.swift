import SwiftUI

public struct V15MasterDataView: View {
    @State private var model: V15MasterDataModel
    @State private var editor = false
    @State private var mergeSheet = false
    @State private var splitSheet = false
    public init(services: V15Services, offlineSnapshotAt: Date? = nil) { _model = State(initialValue: .init(services: services, offlineSnapshotAt: offlineSnapshotAt)) }
    public var body: some View {
#if os(iOS)
        NavigationStack { content.navigationTitle("设置")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { prepareNew(); editor = true } label: { Label("新建", systemImage: "plus") }.disabled(model.writeDisabledReason != nil).accessibilityHint(model.writeDisabledReason?.message ?? "").accessibilityIdentifier("v15.f1c.add") } }
            .sheet(isPresented: $editor, onDismiss: { model.invalidatePreview() }) { NavigationStack { editorContent.toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { editor = false } }; ToolbarItem(placement: .confirmationAction) { Button("保存") { Task { await save() } }.disabled(model.saveDisabledReason != nil).accessibilityHint(model.saveDisabledReason?.message ?? "") } }.navigationTitle(model.selectedSection.rawValue) }.accessibilityIdentifier("v15.f1c.editor") }
            .sheet(isPresented: $mergeSheet, onDismiss: { model.invalidatePreview() }) { mergeContent }
            .sheet(isPresented: $splitSheet, onDismiss: { model.invalidatePreview() }) { splitContent }
        }.accessibilityIdentifier("v15.f1c.master.ios").task { await model.load() }
#else
        HStack(spacing: 0) { list.frame(minWidth: 320, idealWidth: 420); Divider(); inspector.frame(width: 390) }.background(V15Palette.paper.color).accessibilityIdentifier("v15.f1c.master.macos").task { await model.load() }.sheet(isPresented: $mergeSheet, onDismiss: { model.invalidatePreview() }) { mergeContent }.sheet(isPresented: $splitSheet, onDismiss: { model.invalidatePreview() }) { splitContent }
#endif
    }
    @ViewBuilder private var content: some View { VStack(spacing: 0) { Picker("主数据", selection: $model.selectedSection) { ForEach(V15MasterDataModel.Section.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).padding(V15Spacing.md); list } }
    @ViewBuilder private var list: some View {
        ScrollView { VStack(alignment: .leading, spacing: 0) {
            if let snapshot = model.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: snapshot).padding(V15Spacing.md).accessibilityIdentifier("v15.f1c.offline") }
            switch model.phase { case .idle, .loading: V15LoadingSkeleton().padding(V15Spacing.md); case .failed(let failure): V15ServiceErrorState(message: failure.message, retry: { Task { await model.load() } }).padding(V15Spacing.md); case .loaded: rows }
        } }
    }
    @ViewBuilder private var rows: some View {
        switch model.selectedSection {
        case .accounts:
            ForEach(model.visibleAccounts) { account in row(title: model.accountLabel(account), detail: "\(accountKindLabel(account.kind))\(account.archivedAt == nil ? "" : " · 已归档")", selected: model.selectedAccountID == account.id) { model.selectAccount(account); editor = true }.accessibilityIdentifier("v15.f1c.account.\(account.id)") }
        case .categories:
            ForEach(model.visibleCategories) { category in row(title: "\(category.icon)  \(category.name)", detail: "\(categoryDirectionLabel(category.direction))\(category.archivedAt == nil ? "" : " · 已归档")", selected: model.selectedCategoryID == category.id) { model.selectCategory(category); editor = true }.accessibilityIdentifier("v15.f1c.category.\(category.id)") }
        case .merchants:
            VStack(alignment: .leading, spacing: V15Spacing.sm) { V15SearchField(text: $model.merchantSearch).onSubmit { Task { await model.submitMerchantSearch() } }.accessibilityIdentifier("v15.f1c.merchant.search"); ForEach(model.merchants) { merchant in row(title: merchant.name, detail: merchant.aliases.isEmpty ? "暂无别名" : merchant.aliases.joined(separator: " · "), selected: model.selectedMerchantID == merchant.id) { model.selectMerchant(merchant); editor = true }.accessibilityIdentifier("v15.f1c.merchant.\(merchant.id)") }; if let failure = model.merchantPageError { V15ServiceErrorState(message: failure.message, retry: { Task { await model.loadNextMerchants() } }) }; if model.merchantCursor != nil { V15ActionButton(model.isLoadingMerchants ? "正在读取下一页" : "读取下一页", symbol: "chevron.down", disabledReason: model.isLoadingMerchants ? .init(code: "page_loading", message: "正在读取下一页。", fieldPath: nil) : model.merchantSearch != model.committedMerchantSearch ? .init(code: "search_not_submitted", message: "请先提交新的搜索条件。", fieldPath: nil) : nil, action: { Task { await model.loadNextMerchants() } }) } }.padding(V15Spacing.md)
        }
    }
    private func row(title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View { Button(action: action) { HStack { VStack(alignment: .leading, spacing: 3) { Text(title).font(V15Typography.body.weight(.medium)).fixedSize(horizontal: false, vertical: true); Text(detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.65)) }; Spacer(); Image(systemName: "chevron.right").foregroundStyle(V15Palette.ink.color.opacity(0.45)) }.padding(V15Spacing.md).background(selected ? V15Palette.teal.color.opacity(0.10) : .clear) }.buttonStyle(.plain).v15PlatformHitArea() }
    @ViewBuilder private var inspector: some View { VStack(alignment: .leading, spacing: V15Spacing.md) { HStack { Text("详情").font(V15Typography.surfaceTitle); Spacer(); Button { prepareNew() } label: { Image(systemName: "plus") }.disabled(model.writeDisabledReason != nil).accessibilityHint(model.writeDisabledReason?.message ?? "").v15PlatformHitArea() }; editorContent; V15ActionButton("保存", symbol: "checkmark", disabledReason: model.saveDisabledReason, action: { Task { await save() } }).accessibilityIdentifier("v15.f1c.save.macos"); Spacer() }.padding(V15Spacing.md) }
    @ViewBuilder private var editorContent: some View { ScrollView { VStack(alignment: .leading, spacing: V15Spacing.md) { if let text = model.receipt { V15SuccessReceiptState(title: "已保存", detail: text) }; if let reason = model.unknownCreateReloadReason { V15ActionButton("重新读取后再确认", symbol: "arrow.clockwise", kind: .quiet, disabledReason: model.isOffline ? model.writeDisabledReason : nil, action: { Task { await model.reloadAfterUnknownCreate() } }).accessibilityIdentifier("v15.f1c.create-unknown.reload"); Text(reason.message).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }; if let conflict = model.conflict { V15ConflictState(conflict: conflict, changes: model.conflictChanges, reload: { Task { await model.resolveConflictByReload() } }) }
        switch model.selectedSection { case .accounts: accountEditor; case .categories: categoryEditor; case .merchants: merchantEditor }
    }.padding(V15Spacing.md) } }
    private var accountEditor: some View { Group { let archived = model.selectedAccount?.archivedAt != nil; let existing = model.selectedAccount != nil; V15Section("账户") { V15Field("账户昵称", text: $model.accountName, prompt: "例如 日常现金", issues: model.fieldIssues).disabled(archived).accessibilityIdentifier("v15.f1c.account.name"); Picker("账户类型", selection: $model.accountKind) { Text("现金").tag(V15AccountKind.cash); Text("借记").tag(V15AccountKind.debit); Text("信用").tag(V15AccountKind.credit) }.pickerStyle(.menu).disabled(archived || existing).onChange(of: model.accountKind) { _, _ in model.clearCreditFieldsIfNeeded() }; if existing { Text("账户类型创建后不可在此修改。") .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.65)) }; V15Field("期初余额（元）", text: $model.openingBalance, prompt: "0.00", issues: model.fieldIssues).disabled(archived); if model.accountKind == .credit { V15Field("信用额度（元）", text: $model.creditLimit, prompt: "10000.00", issues: model.fieldIssues).disabled(archived); V15Field("账单日", text: $model.statementDay, prompt: "1–28", issues: model.fieldIssues).disabled(archived); V15Field("还款日", text: $model.dueDay, prompt: "1–28", issues: model.fieldIssues).disabled(archived); Picker("账期方式", selection: $model.cycleMode) { Text("账单日截点").tag("statement_day_cutoff"); Text("上个自然月").tag("previous_calendar_month") }.pickerStyle(.menu).disabled(archived); if CNYAmountParser.minorUnits(model.openingBalance) ?? 0 > 0 { V15Field("期初余额日期", text: $model.openingBalanceAsOfDate, prompt: "YYYY-MM-DD", issues: model.fieldIssues).disabled(archived); V15Field("期初到期日期", text: $model.openingDueDate, prompt: "YYYY-MM-DD", issues: model.fieldIssues).disabled(archived) } } }; archiveAction(title: archived ? "恢复账户" : "归档账户", action: { Task { await model.archiveOrRestoreAccount() } }); if !archived, model.selectedAccount != nil { HStack { Button("上移") { Task { await model.reorderAccounts(moving: model.selectedAccountID!, after: accountAfter(model.selectedAccountID!, down: false)) } }.disabled(!accountCanMove(model.selectedAccountID!, down: false)).accessibilityHint(V15MasterDataModel.reorderHint(canMove: accountCanMove(model.selectedAccountID!, down: false), down: false)).keyboardShortcut(.upArrow, modifiers: [.command, .option]); Button("下移") { Task { await model.reorderAccounts(moving: model.selectedAccountID!, after: accountAfter(model.selectedAccountID!, down: true)) } }.disabled(!accountCanMove(model.selectedAccountID!, down: true)).accessibilityHint(V15MasterDataModel.reorderHint(canMove: accountCanMove(model.selectedAccountID!, down: true), down: true)).keyboardShortcut(.downArrow, modifiers: [.command, .option]) }.accessibilityIdentifier("v15.f1c.account.reorder") } } }
    private var categoryEditor: some View { Group { let archived = model.selectedCategory?.archivedAt != nil; V15Section("分类") { V15Field("分类名称", text: $model.categoryName, prompt: "例如 餐饮", issues: model.fieldIssues).disabled(archived).onChange(of: model.categoryName) { _, _ in model.invalidatePreview() }.accessibilityIdentifier("v15.f1c.category.name"); Picker("方向", selection: $model.categoryDirection) { Text("支出").tag(V15CategoryDirection.expense); Text("收入").tag(V15CategoryDirection.income) }.pickerStyle(.menu).disabled(archived).onChange(of: model.categoryDirection) { _, _ in model.invalidatePreview() }; V15Field("图标", text: $model.categoryIcon, prompt: "tag", issues: []).disabled(archived); V15Field("颜色", text: $model.categoryColor, prompt: "#008C8A", issues: model.fieldIssues).disabled(archived) }; archiveAction(title: archived ? "恢复分类" : "归档分类", action: { Task { await model.archiveOrRestoreCategory() } }); if !archived, let source = model.selectedCategory { Menu("合并到…") { ForEach(model.visibleCategories.filter { $0.id != source.id && $0.direction == source.direction && $0.archivedAt == nil }) { target in Button(target.name) { Task { await model.previewMerge(targetID: target.id); if model.transformPreview != nil || model.transformFailure != nil { mergeSheet = true } } } } }.accessibilityIdentifier("v15.f1c.category.merge"); Button("拆分分类…") { model.beginTransformFlow(); splitSheet = true }.accessibilityIdentifier("v15.f1c.category.split"); HStack { Button("上移") { Task { await model.reorderCategories(moving: source.id, after: categoryAfter(source.id, down: false)) } }.disabled(!categoryCanMove(source.id, down: false)).accessibilityHint(V15MasterDataModel.reorderHint(canMove: categoryCanMove(source.id, down: false), down: false)).keyboardShortcut(.upArrow, modifiers: [.command, .option]); Button("下移") { Task { await model.reorderCategories(moving: source.id, after: categoryAfter(source.id, down: true)) } }.disabled(!categoryCanMove(source.id, down: true)).accessibilityHint(V15MasterDataModel.reorderHint(canMove: categoryCanMove(source.id, down: true), down: true)).keyboardShortcut(.downArrow, modifiers: [.command, .option]) }.accessibilityIdentifier("v15.f1c.category.reorder") } } }
    private var merchantEditor: some View { Group { V15Section("商户") { V15Field("商户名称", text: $model.merchantName, prompt: "例如 咖啡店", issues: model.fieldIssues).accessibilityIdentifier("v15.f1c.merchant.name"); V15Field("别名（用、分隔）", text: $model.merchantAliases, prompt: "Coffee", issues: []) } } }
    private func archiveAction(title: String, action: @escaping () -> Void) -> some View { V15InspectorAction(title, detail: "归档不会删除历史记录。", disabledReason: model.writeDisabledReason, action: action) }
    private var mergeContent: some View { NavigationStack { ScrollView { VStack(alignment: .leading, spacing: V15Spacing.md) { Text("合并预览").font(V15Typography.surfaceTitle); transformStatus; if let preview = model.transformPreview { Text("将重新归类 \(preview.source.transactionCount) 笔账目。") .font(V15Typography.secondary); ForEach(preview.childMappingRequirements, id: \.sourceChildID) { item in VStack(alignment: .leading) { Text("子分类：\(item.sourceChildName)").font(V15Typography.secondary); if let selected = model.childMappings[item.sourceChildID] { Picker("归位到", selection: Binding(get: { model.childMappings[item.sourceChildID] ?? selected }, set: { model.childMappings[item.sourceChildID] = $0 })) { ForEach(item.targetChildIDs, id: \.self) { id in Text(model.visibleCategories.first(where: { $0.id == id })?.name ?? "可用分类").tag(id) } }.pickerStyle(.menu) } else { Text("这个子分类没有可用的归位目标。") .font(V15Typography.secondary).foregroundStyle(.red) } } }; let noTarget = preview.childMappingRequirements.contains { $0.targetChildIDs.isEmpty }; V15ActionButton("确认合并", symbol: "arrow.triangle.merge", disabledReasons: (model.writeDisabledReason.map { [$0] } ?? []) + (noTarget ? [.init(code: "merge_target_missing", message: "请先为所有子分类选择归位目标。", fieldPath: nil)] : []), action: { Task { if await model.commitMerge() { mergeSheet = false; model.invalidatePreview() } } }).accessibilityIdentifier("v15.f1c.merge.commit") } else { V15ServiceErrorState(message: model.transformMessage ?? "无法读取合并预览。", retry: { Task { await model.retryTransformPreview() } }) } }.padding(V15Spacing.md) }.toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { mergeSheet = false; model.invalidatePreview() } } } } }
    @ViewBuilder private var transformStatus: some View { if let text = model.transformMessage { Text(text).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.72)) }; if let conflict = model.transformFailure?.conflict { V15ConflictState(conflict: conflict, reload: { Task { await model.reloadAfterTransformConflict() } }) }; ForEach(model.transformFieldIssues, id: \.code) { Text($0.message).font(V15Typography.secondary).foregroundStyle(.red) } }
    private var splitContent: some View { NavigationStack { ScrollView { VStack(alignment: .leading, spacing: V15Spacing.md) { Text("拆分预览").font(V15Typography.surfaceTitle); transformStatus; V15Field("新子分类一", text: Binding(get: { model.splitChildNames[0] }, set: { model.splitChildNames[0] = $0; model.invalidatePreview() }), issues: model.transformFieldIssues); V15Field("新子分类二", text: Binding(get: { model.splitChildNames[1] }, set: { model.splitChildNames[1] = $0; model.invalidatePreview() }), issues: model.transformFieldIssues); if let preview = model.splitPreview { Text("将重新归类 \(preview.root.transactionCount) 笔账目。") .font(V15Typography.secondary); ForEach(preview.requiredTransactionIDs, id: \.self) { id in Picker("账目归位", selection: Binding(get: { model.splitAssignments[id] ?? preview.childNames[0] }, set: { model.splitAssignments[id] = $0 })) { ForEach(preview.childNames, id: \.self) { Text($0).tag($0) } }.pickerStyle(.menu) }; V15ActionButton("确认拆分", symbol: "arrow.triangle.branch", disabledReason: model.writeDisabledReason, action: { Task { if await model.commitSplit() { splitSheet = false; model.invalidatePreview() } } }).accessibilityIdentifier("v15.f1c.split.commit") } else { V15ActionButton("取预览", symbol: "eye", disabledReason: model.writeDisabledReason, action: { Task { await model.previewSplit() } }).accessibilityIdentifier("v15.f1c.split.preview") } }.padding(V15Spacing.md) }.toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { splitSheet = false; model.invalidatePreview() } } } } }
    private func accountCanMove(_ id: UUID, down: Bool) -> Bool { let ids = model.visibleAccounts.filter { $0.archivedAt == nil }.map(\.id); guard let index = ids.firstIndex(of: id) else { return false }; return down ? index + 1 < ids.count : index > 0 }
    private func accountAfter(_ id: UUID, down: Bool) -> UUID? { let ids = model.visibleAccounts.filter { $0.archivedAt == nil }.map(\.id); guard let index = ids.firstIndex(of: id) else { return nil }; return down ? ids[index + 1] : (index > 1 ? ids[index - 2] : nil) }
    private func categoryCanMove(_ id: UUID, down: Bool) -> Bool { let ids = categorySiblingIDs(id); guard let index = ids.firstIndex(of: id) else { return false }; return down ? index + 1 < ids.count : index > 0 }
    private func categoryAfter(_ id: UUID, down: Bool) -> UUID? { let ids = categorySiblingIDs(id); guard let index = ids.firstIndex(of: id) else { return nil }; return down ? ids[index + 1] : (index > 1 ? ids[index - 2] : nil) }
    private func categorySiblingIDs(_ id: UUID) -> [UUID] { guard let source = model.visibleCategories.first(where: { $0.id == id }) else { return [] }; return model.visibleCategories.filter { $0.archivedAt == nil && $0.direction == source.direction && $0.parentID == source.parentID }.map(\.id) }
    private func prepareNew() { switch model.selectedSection { case .accounts: model.selectedAccountID = nil; model.accountName = ""; model.accountKind = .cash; model.openingBalance = "0"; model.creditLimit = ""; model.statementDay = ""; model.dueDay = ""; model.cycleMode = "statement_day_cutoff"; model.openingBalanceAsOfDate = ""; model.openingDueDate = ""; case .categories: model.selectedCategoryID = nil; model.categoryName = ""; model.categoryDirection = .expense; case .merchants: model.selectedMerchantID = nil; model.merchantName = ""; model.merchantAliases = "" } }
    private func save() async { switch model.selectedSection { case .accounts: await model.saveAccount(); case .categories: await model.saveCategory(); case .merchants: await model.saveMerchant() } }
    private func accountKindLabel(_ value: V15AccountKind) -> String { switch value { case .cash: "现金"; case .debit: "借记"; case .credit: "信用"; case .unknown: "其他类型" } }
    private func categoryDirectionLabel(_ value: String) -> String { value == "income" ? "收入" : value == "expense" ? "支出" : "其他" }
}

public struct V15SettingsView: View {
    private enum Pane: String, CaseIterable, Identifiable {
        case masterData, archive, ai, security
        var id: String { rawValue }
        var title: String {
            switch self {
            case .masterData: "主数据"
            case .archive: "归档区"
            case .ai: "AI 与识别"
            case .security: "系统与数据"
            }
        }
        var symbol: String {
            switch self {
            case .masterData: "tray.full"
            case .archive: "archivebox"
            case .ai: "sparkles"
            case .security: "lock.shield"
            }
        }
    }

    private let services: V15Services
    private let offlineSnapshotAt: Date?
    @State private var model: V15SettingsOverviewModel
    @State private var presentedPane: Pane?
    @State private var selectedPane: Pane = .masterData

    public init(services: V15Services, offlineSnapshotAt: Date? = nil) {
        self.services = services
        self.offlineSnapshotAt = offlineSnapshotAt
        _model = State(initialValue: .init(services: services, offlineSnapshotAt: offlineSnapshotAt))
    }

    public var body: some View {
        Group {
#if os(iOS)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.lg) {
                    phaseSurface
                    masterDataOverview
                    archiveDirectory
                    aiOverview
                    navigationCard("系统与数据", detail: "运行状态、加密归档、恢复边界与个人口令", symbol: "lock.shield") { presentedPane = .security }
                }
                .padding(V15Spacing.md)
            }
            .background(V15Palette.paper.color)
            .navigationTitle("设置")
        }
        .sheet(item: $presentedPane) { pane in
            switch pane {
            case .masterData: V15MasterDataView(services: services, offlineSnapshotAt: model.offlineSnapshotAt)
            case .archive: NavigationStack { ScrollView { archiveDirectory.padding(V15Spacing.md) }.navigationTitle("归档区") }
            case .ai: NavigationStack { ScrollView { aiDetail.padding(V15Spacing.md) }.navigationTitle("AI 与识别") }
            case .security: V15DataSecurityView(services: services, offlineSnapshotAt: model.offlineSnapshotAt)
            }
        }
#else
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                Text("设置").font(V15Typography.surfaceTitle).padding(.horizontal, V15Spacing.md).padding(.vertical, V15Spacing.sm)
                ForEach(macPanes) { pane in
                    Button { selectedPane = pane } label: {
                        HStack(spacing: V15Spacing.sm) {
                            Image(systemName: pane.symbol).frame(width: 18)
                            Text(pane.title)
                            Spacer()
                        }
                        .font(V15Typography.body.weight(selectedPane == pane ? .semibold : .regular))
                        .padding(.horizontal, V15Spacing.md).frame(height: 42)
                        .background(selectedPane == pane ? V15Palette.selected.color : .clear, in: RoundedRectangle(cornerRadius: V15Radius.control))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("v15.settings.pane.\(pane.rawValue)")
                }
                Spacer()
            }
            .padding(V15Spacing.sm).frame(width: 230).background(V15Palette.card.color)
            Divider()
            macDetail
        }
#endif
        }
        .task { await model.load() }
        .onDisappear { model.invalidate() }
        .accessibilityIdentifier("v15.settings")
    }

    @ViewBuilder private var phaseSurface: some View {
        switch model.phase {
        case .idle, .loading:
            V15LoadingSkeleton()
        case .offline(let at):
            V15OfflineReadOnlyBanner(snapshotAt: at)
        case .failed(let failure):
            V15ServiceErrorState(message: failure.message, retry: { Task { await model.load() } })
        case .loaded:
            EmptyView()
        }
        if let failure = model.restoreFailure {
            if let conflict = failure.conflict {
                V15ConflictState(conflict: conflict, reload: { Task { await model.load() } })
            } else {
                V15ServiceErrorState(message: failure.message, retry: { Task { await model.load() } })
            }
        }
    }

    private var masterDataOverview: some View {
        V15Section("主数据") {
            VStack(spacing: 0) {
                overviewRow("账户", value: "\(model.activeAccountCount) 个", detail: "按账簿顺序排列", symbol: "creditcard") { presentedPane = .masterData }
                Divider()
                overviewRow("分类", value: "\(model.activeCategoryCount) 个", detail: "支持排序、合并与拆分", symbol: "tag") { presentedPane = .masterData }
                Divider()
                overviewRow("归档区", value: model.archiveCountLabel, detail: "历史仍保留，只读项目可恢复", symbol: "archivebox") { presentedPane = .archive }
            }
        }
    }

    private var archiveDirectory: some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                Text("归档区").font(V15Typography.cardTitle)
                Text("归档不会删除历史记录。灰色斜纹项目只供查看；恢复后可以继续编辑。")
                    .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
            }
            archiveFailures
            if model.archiveItemCount == 0 && !model.hasArchiveReadFailure {
                V15EmptyState(title: "归档区为空", explanation: "已归档的账户、分类、报销单和已作废账目会出现在这里。")
            }
            ForEach(model.archivedAccounts) { item in
                archiveRow(title: item.name, detail: "账户 · \(accountKind(item.kind)) · \(item.usageCount) 项关联", id: item.id) { await model.restoreAccount(item) }
            }
            ForEach(model.archivedCategories) { item in
                archiveRow(title: "\(item.icon)  \(item.name)", detail: "分类 · \(directionLabel(item.direction)) · \(item.usageCount) 笔历史使用", id: item.id) { await model.restoreCategory(item) }
            }
            ForEach(model.archivedClaims, id: \.id) { item in
                archiveRow(title: item.title, detail: "报销单 · \(item.status.displayName) · \(money(item.totalClaimedMinor))", id: item.id) { await model.unarchiveClaim(item) }
            }
            ForEach(model.voidedClaims, id: \.id) { item in
                archiveRow(title: item.title, detail: "已作废报销单 · \(money(item.totalClaimedMinor))", id: item.id) { await model.restoreClaim(item) }
            }
            ForEach(model.voidedTransactions, id: \.id) { item in
                archiveRow(title: item.title, detail: "已作废账目 · \(item.businessDate) · \(money(item.amountMinor))", id: item.id) { await model.restoreTransaction(item) }
            }
            if model.claimsIncomplete || model.transactionsIncomplete {
                Text("当前只显示前 100 项；可以在对应页面查看完整记录。")
                    .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
            }
        }
        .accessibilityIdentifier("v15.settings.archive")
    }

    private var aiOverview: some View {
        navigationCard(
            "AI 与识别",
            detail: aiSummary,
            symbol: "sparkles"
        ) { presentedPane = .ai }
    }

    private var aiDetail: some View {
        VStack(alignment: .leading, spacing: V15Spacing.lg) {
            V15Section("智能解析") {
                factRow("配置状态", model.providerSettings?.apiKeyConfigured == true ? "已配置" : (model.failures["provider"] == nil ? "未配置" : "读取失败"))
                factRow("AI 自动记账", model.aiSettings == nil ? "未提供" : "关闭（每笔都由你确认）")
                factRow("OCR 来源", enabledLabel(model.aiSettings?.ocrSourceEnabled))
                factRow("快捷指令文本", enabledLabel(model.aiSettings?.shortcutTextSourceEnabled))
            }
            if let failure = model.failures["provider"] ?? model.failures["ai_settings"] {
                V15ServiceErrorState(message: failure.message, retry: { Task { await model.load() } })
            }
        }
        .accessibilityIdentifier("v15.settings.ai")
    }

#if os(macOS)
    private var macPanes: [Pane] { [.masterData, .archive, .ai] }

    @ViewBuilder private var macDetail: some View {
        switch selectedPane {
        case .masterData:
            V15MasterDataView(services: services, offlineSnapshotAt: model.offlineSnapshotAt)
        case .archive:
            ScrollView { VStack(alignment: .leading, spacing: V15Spacing.lg) { phaseSurface; archiveDirectory }.padding(V15Spacing.xl).frame(maxWidth: 860, alignment: .leading) }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(V15Palette.paper.color)
        case .ai:
            ScrollView { VStack(alignment: .leading, spacing: V15Spacing.lg) { phaseSurface; aiDetail }.padding(V15Spacing.xl).frame(maxWidth: 860, alignment: .leading) }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(V15Palette.paper.color)
        case .security:
            V15DataSecurityMacView(services: services, offlineSnapshotAt: model.offlineSnapshotAt)
        }
    }
#endif

    @ViewBuilder private var archiveFailures: some View {
        ForEach(["accounts", "categories", "claims", "transactions"], id: \.self) { key in
            if let failure = model.failures[key] {
                V15ServiceErrorState(message: failure.message, retry: { Task { await model.load() } })
            }
        }
    }

    private func archiveRow(title: String, detail: String, id: UUID, restore: @escaping @MainActor () async -> Void) -> some View {
        V15ArchiveReadOnlyState(restoreTitle: model.restoringID == id ? "正在恢复…" : "恢复") {
            Task { await restore() }
        } content: {
            VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                Text(title).font(V15Typography.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("v15.settings.archive.\(id)")
    }

    private func navigationCard(_ title: String, detail: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: V15Spacing.md) {
                Image(systemName: symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(V15Palette.teal.color).frame(width: 28)
                VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                    Text(title).font(V15Typography.cardTitle)
                    Text(detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(V15Palette.ink.color.opacity(0.40))
            }
            .padding(V15Spacing.md).frame(maxWidth: .infinity, alignment: .leading)
            .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.decisionCard))
            .overlay { RoundedRectangle(cornerRadius: V15Radius.decisionCard).stroke(V15Palette.hairline.color) }
        }
        .buttonStyle(.plain).v15PlatformHitArea()
    }

    private func overviewRow(_ title: String, value: String, detail: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: V15Spacing.sm) {
                Image(systemName: symbol).foregroundStyle(V15Palette.teal.color).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack { Text(title).font(V15Typography.body.weight(.semibold)); Spacer(); Text(value).font(V15Typography.body.monospaced()) }
                    Text(detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.62))
                }
                Image(systemName: "chevron.right").foregroundStyle(V15Palette.ink.color.opacity(0.36))
            }
            .padding(.vertical, V15Spacing.sm)
        }
        .buttonStyle(.plain).v15PlatformHitArea()
    }

    private func factRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(V15Typography.secondary)
            Spacer()
            Text(value).font(V15Typography.body.monospaced()).multilineTextAlignment(.trailing)
        }
    }
    private var aiSummary: String {
        if let failure = model.failures["provider"] ?? model.failures["ai_settings"] { return "智能解析设置读取失败 · \(failure.message)" }
        let configured = model.providerSettings?.apiKeyConfigured == true ? "智能解析已配置" : "智能解析未配置"
        return "\(configured) · 每笔都由你确认"
    }
    private func accountKind(_ value: V15AccountKind) -> String { switch value { case .cash: "现金"; case .debit: "借记"; case .credit: "信用"; case .unknown: "未知类型" } }
    private func directionLabel(_ value: String) -> String { value == "income" ? "收入" : value == "expense" ? "支出" : value }
    private func money(_ value: Int64) -> String { V15MoneyPresentation(minorUnits: value, direction: .neutral).text }
    private func enabledLabel(_ value: Bool?) -> String { value.map { $0 ? "已启用" : "已停用" } ?? "未提供" }
}

private extension V15SettingsOverviewModel {
    var hasArchiveReadFailure: Bool { ["accounts", "categories", "claims", "transactions"].contains { failures[$0] != nil } }
    var archiveCountLabel: String { (claimsIncomplete || transactionsIncomplete) ? "至少 \(archiveItemCount) 项" : "\(archiveItemCount) 项" }
}
