import SwiftUI

public struct AccountsManagementScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AccountsModel
    private let showsCloseButton: Bool
    @State private var editing: AccountDTO?
    @State private var showForm = false
    @State private var pendingDelete: AccountDTO?
    @State private var pendingArchive: AccountDTO?

    public init(model: AccountsModel, showsCloseButton: Bool = false) {
        self.model = model
        self.showsCloseButton = showsCloseButton
    }

    public var body: some View {
        stateContent
            .navigationTitle("账户")
            .toolbar {
                if showsCloseButton {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .frame(width: 30, height: 30)
                                .background(FiscalColor.tertiary.opacity(0.12), in: .circle)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .help("关闭")
                        .accessibilityLabel("关闭账户管理")
                        .accessibilityIdentifier("mac.accounts.close")
                    }
                }
                ToolbarItem {
                    Menu {
                        Toggle("包含已归档", isOn: $model.includeArchived)
                    } label: {
                        Label("筛选", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(FiscalActionButtonStyle(.secondary))
                    .onChange(of: model.includeArchived) { _, _ in Task { await model.load() } }
                }
                ToolbarItem {
                    Button { editing = nil; showForm = true } label: {
                        Label("新建账户", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(FiscalActionButtonStyle(.secondary))
                }
            }
        .task { if model.phase == .idle { await model.load() } }
        .sheet(isPresented: $showForm) { AccountEditor(model: model, account: editing) }
        .alert(pendingArchive?.archivedAt == nil ? "归档账户？" : "恢复账户？", isPresented: Binding(get: { pendingArchive != nil }, set: { if !$0 { pendingArchive = nil } })) {
            Button("取消", role: .cancel) { pendingArchive = nil }
            Button(pendingArchive?.archivedAt == nil ? "归档" : "恢复") { if let item = pendingArchive { Task { await model.archiveOrRestore(item); pendingArchive = nil } } }
        } message: { Text(pendingArchive?.archivedAt == nil ? "归档后不会出现在默认列表，但会保留历史与配置。" : "恢复时会重新检查活动账户名称是否冲突。") }
        .alert("永久删除账户？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("永久删除", role: .destructive) { if let item = pendingDelete { Task { await model.delete(item); pendingDelete = nil } } }
        } message: { Text("只有使用次数为 0 且没有依赖资料时才能删除。已使用账户应归档保留。") }
        .alert("数据已变化", isPresented: Binding(get: { model.conflictDetected }, set: { if !$0 { model.clearConflict() } })) {
            Button("重新加载") { Task { await model.load() } }
        } message: { Text("服务器上的版本比当前页面更新，请重新加载后再编辑。") }
    }

    @ViewBuilder private var stateContent: some View {
        switch model.phase {
        case .idle, .loading: ProgressView("正在读取账户…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty: ContentUnavailableView("还没有账户", systemImage: "wallet.bifold", description: Text("新建现金、储蓄卡或信用卡账户。"))
        case .unauthorized: retryState("访问口令无效", symbol: "key")
        case .offline: retryState("无法连接个人 VPS", symbol: "wifi.slash")
        case .failed: retryState(model.message ?? "加载失败", symbol: "exclamationmark.triangle")
        case .loaded:
            ScrollView { LazyVStack(spacing: MasterDataLayout.spacing) { ForEach(model.accounts) { accountCard($0) } }.padding(MasterDataLayout.padding).padding(.bottom, MasterDataLayout.bottomPadding) }.background(MasterDataLayout.background)
        }
    }

    private func accountCard(_ account: AccountDTO) -> some View {
        FiscalCard {
            HStack(spacing: 13) {
                FiscalIconTile(account.kind.symbol, color: account.kind == .credit ? FiscalColor.debt : FiscalColor.accent)
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(account.name).font(.headline); if account.archivedAt != nil { Text("已归档").font(.caption2).padding(4).background(.gray.opacity(0.12), in: .capsule) } }
                    Text([account.institution, account.lastFour.map { "尾号 \($0)" }].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(FiscalColor.tertiary)
                    Text(account.kind == .credit ? "期初欠款 \(Money(minorUnits: account.openingBalanceMinor).formatted()) · 额度 \(Money(minorUnits: account.creditLimitMinor ?? 0).formatted())" : "期初余额 \(Money(minorUnits: account.openingBalanceMinor).formatted())")
                        .font(.caption).foregroundStyle(FiscalColor.secondary)
                }
                Spacer()
                Menu {
                    Button("编辑", systemImage: "pencil") { editing = account; showForm = true }
                    if account.archivedAt == nil {
                        Button("上移", systemImage: "arrow.up") { Task { await model.move(account, by: -1) } }
                        Button("下移", systemImage: "arrow.down") { Task { await model.move(account, by: 1) } }
                    }
                    Button(account.archivedAt == nil ? "归档" : "恢复", systemImage: account.archivedAt == nil ? "archivebox" : "arrow.uturn.backward") { pendingArchive = account }
                    if account.usageCount == 0 { Button("永久删除", systemImage: "trash", role: .destructive) { pendingDelete = account } }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(FiscalColor.accent)
                        .frame(width: 38, height: 34)
                        .background(FiscalColor.accent.opacity(0.08), in: .rect(cornerRadius: 10))
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
            }
        }
    }

    private func retryState(_ title: String, symbol: String) -> some View {
        ContentUnavailableView { Label(title, systemImage: symbol) } description: { Text(model.message ?? "资料不会使用预览数据替代。") } actions: { Button("重试") { Task { await model.load() } } }
    }
}

private struct AccountEditor: View {
    private enum Field: Hashable { case name, institution, lastFour, opening, limit, openingAsOf, openingDue }
    @Environment(\.dismiss) private var dismiss
    let model: AccountsModel
    let account: AccountDTO?
    @State private var draft: AccountDraft
    @State private var opening: String
    @State private var limit: String
    @State private var openingAsOf: String
    @State private var openingDue: String
    @State private var validation: String?
    @State private var schedulePreview: CreditScheduleChangeResult?
    @FocusState private var focusedField: Field?

    init(model: AccountsModel, account: AccountDTO?) {
        self.model = model; self.account = account
        let draft = account.map(AccountDraft.init(account:)) ?? AccountDraft()
        _draft = State(initialValue: draft); _opening = State(initialValue: Self.major(draft.openingBalanceMinor)); _limit = State(initialValue: draft.creditLimitMinor.map(Self.major) ?? "")
        _openingAsOf = State(initialValue: draft.openingBalanceAsOfDate ?? ""); _openingDue = State(initialValue: draft.openingDueDate ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    editorSection("基本信息") {
                        VStack(spacing: 13) {
                            TextField("账户名称", text: $draft.name).focused($focusedField, equals: .name)
                            Divider().opacity(0.35)
                            Picker("类型", selection: $draft.kind) { ForEach(AccountKind.allCases) { Text($0.title).tag($0) } }
                            Divider().opacity(0.35)
                            TextField("机构（可选）", text: $draft.institution).focused($focusedField, equals: .institution)
                            Divider().opacity(0.35)
                            TextField("尾号 4 位（可选）", text: $draft.lastFour).focused($focusedField, equals: .lastFour)
                            Divider().opacity(0.35)
                            TextField(draft.kind == .credit ? "期初欠款" : "期初余额", text: $opening)
                                .focused($focusedField, equals: .opening)
#if os(iOS)
                                .keyboardType(.decimalPad)
#endif
                        }.textFieldStyle(.plain)
                    }
                    if draft.kind == .credit {
                        editorSection("信用配置") {
                            VStack(alignment: .leading, spacing: 13) {
                                TextField("信用额度", text: $limit).focused($focusedField, equals: .limit)
#if os(iOS)
                                    .keyboardType(.decimalPad)
#endif
                                if CNYAmountParser.minorUnits(opening) ?? 0 > 0 {
                                    Divider().opacity(0.35)
                                    TextField("期初余额日期 YYYY-MM-DD", text: $openingAsOf).focused($focusedField, equals: .openingAsOf)
                                    Divider().opacity(0.35)
                                    TextField("期初到期日 YYYY-MM-DD", text: $openingDue).focused($focusedField, equals: .openingDue)
                                    Text("用于真实表达导入欠款是否已到期，不会自动猜测。").font(.caption).foregroundStyle(FiscalColor.tertiary)
                                }
                                Divider().opacity(0.35)
                                Picker("账期模式", selection: $draft.cycleMode) {
                                    ForEach(CreditCycleMode.allCases) { Text($0.title).tag($0) }
                                }
                                Text(draft.cycleMode == .previousCalendarMonth
                                     ? "每个账单统计上一个完整自然月。"
                                     : "账单日同时作为本期消费的截止日。")
                                    .font(.caption).foregroundStyle(FiscalColor.tertiary)
                                Divider().opacity(0.35)
                                Stepper("账单日：\(draft.statementDay ?? 1)", value: Binding(get: { draft.statementDay ?? 1 }, set: { draft.statementDay = $0 }), in: 1...28)
                                Divider().opacity(0.35)
                                Stepper("还款日：\(draft.dueDay ?? 1)", value: Binding(get: { draft.dueDay ?? 1 }, set: { draft.dueDay = $0 }), in: 1...28)
                            }.textFieldStyle(.plain)
                        }
                    }
                    if let validation { validationBanner(validation) }
                }
                .padding(16)
            }.background(MasterDataLayout.background).scrollDismissesKeyboard(.interactively)
            .navigationTitle(account == nil ? "新建账户" : "编辑账户")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
#if os(iOS)
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { focusedField = nil } }
#endif
            }
            .safeAreaInset(edge: .bottom) { primaryBar(model.isMutating ? "保存中…" : "保存账户", disabled: model.isMutating) { focusedField = nil; save() } }
        }.fiscalEditorFrame(width: 380, height: 520)
        .alert("应用账期规则变更？", isPresented: Binding(
            get: { schedulePreview != nil }, set: { if !$0 { schedulePreview = nil } })) {
            Button("取消", role: .cancel) { schedulePreview = nil }
            Button("应用并重算") { applyScheduleChange() }
                .disabled(schedulePreview?.conflicts.isEmpty == false)
        } message: {
            if let preview = schedulePreview {
                if preview.conflicts.isEmpty {
                    Text("将重算 \(preview.affectedCycleCount) 个未结清账期、\(preview.purchaseCount) 笔消费、\(preview.repaymentCount) 笔还款和 \(preview.installmentPeriodCount) 个分期期次；已结清历史保持不变。")
                } else {
                    Text("发现冲突：\(preview.conflicts.joined(separator: "、"))。没有写入任何变更。")
                }
            }
        }
    }
    private func editorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.headline).padding(.horizontal, 3); FiscalCard(radius: 18) { content() } }
    }
    private func validationBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(FiscalColor.expense).padding(13).frame(maxWidth: .infinity, alignment: .leading).background(FiscalColor.expense.opacity(0.09), in: .rect(cornerRadius: 14))
    }
    private func primaryBar(_ title: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity) }.buttonStyle(FiscalActionButtonStyle()).disabled(disabled).padding(.horizontal, 16).padding(.vertical, 10).background(.regularMaterial)
    }
    private func save() {
        guard let openingMinor = CNYAmountParser.minorUnits(opening) else { validation = "期初金额格式无效。"; return }
        draft.openingBalanceMinor = openingMinor
        if draft.kind == .credit { guard let value = CNYAmountParser.minorUnits(limit) else { validation = "信用额度格式无效。"; return }; draft.creditLimitMinor = value; draft.openingBalanceAsOfDate = openingMinor > 0 ? openingAsOf.nilIfBlank : nil; draft.openingDueDate = openingMinor > 0 ? openingDue.nilIfBlank : nil
            // The Steppers show a fallback of 1 via `?? 1`; persist it so an untouched Stepper
            // matches the display instead of failing validation with a nil day (M10).
            if draft.statementDay == nil { draft.statementDay = 1 }
            if draft.dueDay == nil { draft.dueDay = 1 }
        }
        else { draft.creditLimitMinor = nil; draft.statementDay = nil; draft.dueDay = nil; draft.openingBalanceAsOfDate = nil; draft.openingDueDate = nil }
        validation = AccountsModel.validate(draft)
        guard validation == nil else { return }
        if let account, scheduleChanged(from: account) {
            Task {
                schedulePreview = await model.previewScheduleChange(draft: draft, account: account)
                if schedulePreview == nil { validation = model.message }
            }
        } else {
            Task { if await model.save(draft: draft, editing: account) { dismiss() } else { validation = model.message } }
        }
    }
    private func scheduleChanged(from account: AccountDTO) -> Bool {
        account.kind == .credit && (
            draft.cycleMode != (account.cycleMode ?? .statementDayCutoff)
            || draft.statementDay != account.statementDay || draft.dueDay != account.dueDay)
    }
    private func applyScheduleChange() {
        guard let account else { return }
        schedulePreview = nil
        Task {
            if await model.applyScheduleChange(draft: draft, account: account) { dismiss() }
            else { validation = model.message }
        }
    }
    private static func major(_ minor: Int64) -> String { NSDecimalNumber(decimal: Decimal(minor) / 100).stringValue }
}

private extension String { var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : trimmingCharacters(in: .whitespacesAndNewlines) } }

public struct CategoriesManagementScreen: View {
    @Bindable var model: CategoriesModel
    @State private var editing: CategoryDTO?
    @State private var showForm = false
    @State private var pendingDelete: CategoryDTO?
    @State private var pendingArchive: CategoryDTO?
    @State private var mergeSource: CategoryDTO?
    @State private var splitRoot: CategoryDTO?

    public init(model: CategoriesModel) { self.model = model }
    public var body: some View {
        stateContent.navigationTitle("分类")
            .toolbar {
                ToolbarItem {
                    Menu {
                        Picker("方向", selection: $model.direction) { Text("全部").tag(Optional<CategoryDirection>.none); ForEach(CategoryDirection.allCases) { Text($0.title).tag(Optional($0)) } }
                        Toggle("包含已归档", isOn: $model.includeArchived)
                    } label: {
                        Label("筛选", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .onChange(of: model.direction) { _, _ in Task { await model.load() } }
                    .onChange(of: model.includeArchived) { _, _ in Task { await model.load() } }
                }
                ToolbarItem { Button { editing = nil; showForm = true } label: { Label("新建分类", systemImage: "plus") } }
            }
        .task { if model.phase == .idle { await model.load() } }
        .sheet(isPresented: $showForm) { CategoryEditor(model: model, category: editing, roots: model.categories) }
        .sheet(item: $mergeSource) { MergeCategorySheet(model: model, source: $0) }
        .sheet(item: $splitRoot) { SplitCategorySheet(model: model, root: $0) }
        .alert(pendingArchive?.archivedAt == nil ? "归档分类？" : "恢复分类？", isPresented: Binding(get: { pendingArchive != nil }, set: { if !$0 { pendingArchive = nil } })) {
            Button("取消", role: .cancel) { pendingArchive = nil }
            Button(pendingArchive?.archivedAt == nil ? "归档" : "恢复") { if let item = pendingArchive { Task { await model.archiveOrRestore(item); pendingArchive = nil } } }
        } message: { Text(pendingArchive?.archivedAt == nil ? "归档会保留使用记录；有活动子分类的根分类不能归档。" : "恢复时会重新检查同级名称是否冲突。") }
        .alert("永久删除分类？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("取消", role: .cancel) { pendingDelete = nil }; Button("永久删除", role: .destructive) { if let item = pendingDelete { Task { await model.delete(item); pendingDelete = nil } } }
        } message: { Text("仅未使用且没有子分类的分类可删除。否则请归档以保留历史语义。") }
        .alert("数据已变化", isPresented: Binding(get: { model.conflictDetected }, set: { if !$0 { model.clearConflict() } })) {
            Button("重新加载") { Task { await model.load() } }
        } message: { Text("服务器上的版本比当前页面更新，请重新加载后再编辑。") }
    }

    @ViewBuilder private var stateContent: some View {
        switch model.phase {
        case .idle, .loading: ProgressView("正在读取分类…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty: ContentUnavailableView("还没有分类", systemImage: "tag", description: Text("建立收入或支出分类，最多两级。"))
        case .unauthorized: retry("访问口令无效", "key")
        case .offline: retry("无法连接个人 VPS", "wifi.slash")
        case .failed: retry(model.message ?? "加载失败", "exclamationmark.triangle")
        case .loaded:
            ScrollView { LazyVStack(spacing: MasterDataLayout.spacing) { ForEach(model.categories) { root in categoryCard(root, depth: 0); ForEach(root.children) { categoryCard($0, depth: 1) } } }.padding(MasterDataLayout.padding).padding(.bottom, MasterDataLayout.bottomPadding) }.background(MasterDataLayout.background)
        }
    }

    private func categoryCard(_ item: CategoryDTO, depth: Int) -> some View {
        FiscalCard(radius: 14) {
            HStack(spacing: 12) {
                if depth == 1 { Image(systemName: "arrow.turn.down.right").foregroundStyle(FiscalColor.tertiary).frame(width: 18).accessibilityHidden(true) }
                FiscalIconTile(item.icon, color: Color(fiscalHex: item.colorHex))
                VStack(alignment: .leading, spacing: 3) {
                    HStack { Text(item.name).font(.headline); Text(item.direction.title).font(.caption2).padding(.horizontal, 6).padding(.vertical, 3).background(FiscalColor.accent.opacity(0.1), in: .capsule); if item.archivedAt != nil { Text("已归档").font(.caption2) } }
                    Text("别名 \(item.aliases.count) · 示例 \(item.examples.count) · 使用 \(item.usageCount)").font(.caption).foregroundStyle(FiscalColor.tertiary)
                    if !item.aliases.isEmpty { Text(item.aliases.joined(separator: "、")).font(.caption).foregroundStyle(FiscalColor.secondary).lineLimit(2) }
                }
                Spacer()
                Menu {
                    Button("编辑", systemImage: "pencil") { editing = item; showForm = true }
                    if item.archivedAt == nil {
                        Button("上移", systemImage: "arrow.up") { Task { await model.move(item, by: -1) } }
                        Button("下移", systemImage: "arrow.down") { Task { await model.move(item, by: 1) } }
                    }
                    Button(item.archivedAt == nil ? "归档" : "恢复", systemImage: "archivebox") { pendingArchive = item }
                        .disabled(item.archivedAt == nil && item.children.contains(where: { $0.archivedAt == nil }))
                    if canMerge(item) { Button("合并到…", systemImage: "arrow.triangle.merge") { mergeSource = item } }
                    if item.parentID == nil && item.archivedAt == nil { Button("拆分辅助", systemImage: "arrow.branch") { splitRoot = item } }
                    if item.usageCount == 0 && item.children.isEmpty { Button("永久删除", systemImage: "trash", role: .destructive) { pendingDelete = item } }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
            }
        }
    }
    private func canMerge(_ item: CategoryDTO) -> Bool {
        item.archivedAt == nil && model.flattened.contains {
            $0.id != item.id && $0.direction == item.direction && $0.archivedAt == nil && (($0.parentID == nil) == (item.parentID == nil))
        }
    }
    private func retry(_ title: String, _ symbol: String) -> some View { ContentUnavailableView { Label(title, systemImage: symbol) } description: { Text(model.message ?? "资料不会使用预览数据替代。") } actions: { Button("重试") { Task { await model.load() } } } }
}

private struct CategoryEditor: View {
    private enum Field: Hashable { case name, icon, color, aliases, examples }
    @Environment(\.dismiss) private var dismiss
    let model: CategoriesModel; let category: CategoryDTO?; let roots: [CategoryDTO]
    @State private var draft: CategoryDraft; @State private var aliases: String; @State private var examples: String; @State private var validation: String?
    @FocusState private var focusedField: Field?
    init(model: CategoriesModel, category: CategoryDTO?, roots: [CategoryDTO]) {
        self.model = model; self.category = category; self.roots = roots
        let d = category.map(CategoryDraft.init(category:)) ?? CategoryDraft(); _draft = State(initialValue: d); _aliases = State(initialValue: d.aliases.joined(separator: "，")); _examples = State(initialValue: d.examples.joined(separator: "，"))
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    categorySection("基本信息") {
                        VStack(alignment: .leading, spacing: 13) {
                            TextField("分类名称", text: $draft.name).focused($focusedField, equals: .name)
                            Divider().opacity(0.35)
                            Picker("方向", selection: $draft.direction) { ForEach(CategoryDirection.allCases) { Text($0.title).tag($0) } }
                                .disabled(hierarchyLocked)
                                .onChange(of: draft.direction) { _, direction in
                                    if let parentID = draft.parentID, roots.first(where: { $0.id == parentID })?.direction != direction { draft.parentID = nil }
                                }
                            Divider().opacity(0.35)
                            Picker("父分类", selection: $draft.parentID) { Text("根分类").tag(Optional<UUID>.none); ForEach(eligibleRoots) { Text($0.name).tag(Optional($0.id)) } }
                                .disabled(hierarchyLocked)
                            if hierarchyLocked { Label("含子分类的根分类不能改变方向或父级。", systemImage: "lock.fill").font(.caption).foregroundStyle(FiscalColor.tertiary) }
                            Divider().opacity(0.35)
                            TextField("SF Symbol", text: $draft.icon).focused($focusedField, equals: .icon)
                            Divider().opacity(0.35)
                            TextField("颜色 #RRGGBB", text: $draft.colorHex).focused($focusedField, equals: .color)
                        }.textFieldStyle(.plain)
                    }
                    categorySection("AI 识别资料") {
                        VStack(alignment: .leading, spacing: 13) {
                            TextField("别名，以逗号分隔", text: $aliases).focused($focusedField, equals: .aliases)
                            Divider().opacity(0.35)
                            TextField("识别示例，以逗号分隔", text: $examples).focused($focusedField, equals: .examples)
                            Text("每组最多 20 条，每条不超过 40 个字符。").font(.caption).foregroundStyle(FiscalColor.tertiary)
                        }.textFieldStyle(.plain)
                    }
                    if let validation {
                        Label(validation, systemImage: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(FiscalColor.expense).padding(13).frame(maxWidth: .infinity, alignment: .leading).background(FiscalColor.expense.opacity(0.09), in: .rect(cornerRadius: 14))
                    }
                }.padding(16)
            }.background(MasterDataLayout.background).scrollDismissesKeyboard(.interactively)
                .navigationTitle(category == nil ? "新建分类" : "编辑分类")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
#if os(iOS)
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { focusedField = nil } }
#endif
                }
                .safeAreaInset(edge: .bottom) {
                    Button { focusedField = nil; save() } label: { Text("保存分类").frame(maxWidth: .infinity) }
                        .buttonStyle(FiscalActionButtonStyle()).disabled(model.isMutating)
                        .padding(.horizontal, 16).padding(.vertical, 10).background(.regularMaterial)
                }
        }.fiscalEditorFrame(width: 400, height: 540)
    }
    private func categorySection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.headline).padding(.horizontal, 3); FiscalCard(radius: 18) { content() } }
    }
    private var hierarchyLocked: Bool { category?.children.isEmpty == false }
    private var eligibleRoots: [CategoryDTO] { roots.filter { $0.parentID == nil && $0.id != category?.id && $0.direction == draft.direction && $0.archivedAt == nil } }
    private func save() {
        draft.aliases = parse(aliases); draft.examples = parse(examples)
        validation = CategoriesModel.validate(draft)
        if let parentID = draft.parentID, !eligibleRoots.contains(where: { $0.id == parentID }) { validation = "父分类必须是同方向的活动根分类。" }
        guard validation == nil else { return }
        Task { if await model.save(draft: draft, editing: category) { dismiss() } else { validation = model.message } }
    }
    private func parse(_ text: String) -> [String] { text.split(whereSeparator: { $0 == "," || $0 == "，" }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
}

private struct MergeCategorySheet: View {
    @Environment(\.dismiss) private var dismiss; let model: CategoriesModel; let source: CategoryDTO; @State private var targetID: UUID?
    var targets: [CategoryDTO] {
        model.flattened.filter {
            $0.id != source.id && $0.direction == source.direction && $0.archivedAt == nil && (($0.parentID == nil) == (source.parentID == nil))
        }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label("合并会保留历史语义", systemImage: "arrow.triangle.merge").font(.headline)
                    FiscalCard(radius: 18) {
                        VStack(alignment: .leading, spacing: 13) {
                            Text("“\(source.name)”将归档；冲突外的子分类会移动到目标分类。").font(.subheadline).foregroundStyle(FiscalColor.secondary)
                            Divider().opacity(0.35)
                            Picker("目标分类", selection: $targetID) { Text("请选择").tag(Optional<UUID>.none); ForEach(targets) { Text($0.name).tag(Optional($0.id)) } }
                        }
                    }
                }.padding(16)
            }.background(MasterDataLayout.background).navigationTitle("合并分类")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                .safeAreaInset(edge: .bottom) {
                    Button {
                        if let target = targets.first(where: { $0.id == targetID }) { Task { if await model.merge(source: source, target: target) { dismiss() } } }
                    } label: { Text(model.isMutating ? "合并中…" : "确认合并").frame(maxWidth: .infinity) }
                    .buttonStyle(FiscalActionButtonStyle(.destructive)).disabled(targetID == nil || model.isMutating)
                    .padding(.horizontal, 16).padding(.vertical, 10).background(.regularMaterial)
                }
        }.fiscalEditorFrame(width: 380, height: 300)
    }
}

private struct SplitCategorySheet: View {
    private enum Field: Hashable { case first, second }
    @Environment(\.dismiss) private var dismiss; let model: CategoriesModel; let root: CategoryDTO; @State private var first = ""; @State private var second = ""
    @FocusState private var focusedField: Field?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("子分类").font(.headline).padding(.horizontal, 3)
                    FiscalCard(radius: 18) {
                        VStack(alignment: .leading, spacing: 13) {
                            Text("在“\(root.name)”下原子创建至少两个子分类，不移动任何流水。").font(.subheadline).foregroundStyle(FiscalColor.secondary)
                            Divider().opacity(0.35)
                            TextField("子分类一", text: $first).focused($focusedField, equals: .first)
                            Divider().opacity(0.35)
                            TextField("子分类二", text: $second).focused($focusedField, equals: .second)
                        }.textFieldStyle(.plain)
                    }
                }.padding(16)
            }.background(MasterDataLayout.background).scrollDismissesKeyboard(.interactively).navigationTitle("拆分辅助")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
#if os(iOS)
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { focusedField = nil } }
#endif
                }
                .safeAreaInset(edge: .bottom) {
                    Button {
                        focusedField = nil
                        Task { if await model.split(root: root, children: [draft(first), draft(second)]) { dismiss() } }
                    } label: { Text(model.isMutating ? "创建中…" : "创建子分类").frame(maxWidth: .infinity) }
                    .buttonStyle(FiscalActionButtonStyle()).disabled(model.isMutating || first.trimmingCharacters(in: .whitespaces).isEmpty || second.trimmingCharacters(in: .whitespaces).isEmpty)
                    .padding(.horizontal, 16).padding(.vertical, 10).background(.regularMaterial)
                }
        }.fiscalEditorFrame(width: 400, height: 340)
    }
    private func draft(_ name: String) -> CategoryDraft { var d = CategoryDraft(); d.name = name; d.direction = root.direction; d.parentID = root.id; d.icon = root.icon; d.colorHex = root.colorHex; return d }
}

private extension Color {
    init(fiscalHex: String) { self.init(hex: UInt(fiscalHex.dropFirst(), radix: 16) ?? 0x2E68D6) }
}

private extension View {
    @ViewBuilder func fiscalEditorFrame(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
        frame(minWidth: width, minHeight: height)
        #else
        self
        #endif
    }
}

private enum MasterDataLayout {
    #if os(macOS)
    static let spacing: CGFloat = 8
    static let padding: CGFloat = 12
    static let bottomPadding: CGFloat = 12
    static let background = FiscalColor.macBackground
    #else
    static let spacing: CGFloat = 10
    static let padding: CGFloat = 16
    static let bottomPadding: CGFloat = 0
    static let background = FiscalColor.iOSBackground
    #endif
}
