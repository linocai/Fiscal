import SwiftUI

public struct AccountsManagementScreen: View {
    @Bindable var model: AccountsModel
    @State private var editing: AccountDTO?
    @State private var showForm = false
    @State private var pendingDelete: AccountDTO?
    @State private var pendingArchive: AccountDTO?

    public init(model: AccountsModel) { self.model = model }

    public var body: some View {
        stateContent
            .navigationTitle("账户")
            .toolbar {
                ToolbarItem {
                    Menu {
                        Toggle("包含已归档", isOn: $model.includeArchived)
                    } label: {
                        Label("筛选", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .onChange(of: model.includeArchived) { _, _ in Task { await model.load() } }
                }
                ToolbarItem { Button { editing = nil; showForm = true } label: { Label("新建账户", systemImage: "plus") } }
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
        case .unauthorized: retryState("设备密钥无效", symbol: "key")
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
                } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
            }
        }
    }

    private func retryState(_ title: String, symbol: String) -> some View {
        ContentUnavailableView { Label(title, systemImage: symbol) } description: { Text(model.message ?? "资料不会使用预览数据替代。") } actions: { Button("重试") { Task { await model.load() } } }
    }
}

private struct AccountEditor: View {
    @Environment(\.dismiss) private var dismiss
    let model: AccountsModel
    let account: AccountDTO?
    @State private var draft: AccountDraft
    @State private var opening: String
    @State private var limit: String
    @State private var validation: String?

    init(model: AccountsModel, account: AccountDTO?) {
        self.model = model; self.account = account
        let draft = account.map(AccountDraft.init(account:)) ?? AccountDraft()
        _draft = State(initialValue: draft); _opening = State(initialValue: Self.major(draft.openingBalanceMinor)); _limit = State(initialValue: draft.creditLimitMinor.map(Self.major) ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("账户名称", text: $draft.name)
                    Picker("类型", selection: $draft.kind) { ForEach(AccountKind.allCases) { Text($0.title).tag($0) } }
                    TextField("机构（可选）", text: $draft.institution)
                    TextField("尾号 4 位（可选）", text: $draft.lastFour)
                    TextField(draft.kind == .credit ? "期初欠款" : "期初余额", text: $opening)
                }
                if draft.kind == .credit {
                    Section("信用配置") {
                        TextField("信用额度", text: $limit)
                        Stepper("账单日：\(draft.statementDay ?? 1)", value: Binding(get: { draft.statementDay ?? 1 }, set: { draft.statementDay = $0 }), in: 1...28)
                        Stepper("还款日：\(draft.dueDay ?? 1)", value: Binding(get: { draft.dueDay ?? 1 }, set: { draft.dueDay = $0 }), in: 1...28)
                    }
                }
                if let validation { Section { Text(validation).foregroundStyle(FiscalColor.expense) } }
            }
            .navigationTitle(account == nil ? "新建账户" : "编辑账户")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(model.isMutating) } }
        }.fiscalEditorFrame(width: 380, height: 520)
    }
    private func save() {
        guard let openingMinor = CNYAmountParser.minorUnits(opening) else { validation = "期初金额格式无效。"; return }
        draft.openingBalanceMinor = openingMinor
        if draft.kind == .credit { guard let value = CNYAmountParser.minorUnits(limit) else { validation = "信用额度格式无效。"; return }; draft.creditLimitMinor = value }
        else { draft.creditLimitMinor = nil; draft.statementDay = nil; draft.dueDay = nil }
        validation = AccountsModel.validate(draft)
        guard validation == nil else { return }
        Task { if await model.save(draft: draft, editing: account) { dismiss() } else { validation = model.message } }
    }
    private static func major(_ minor: Int64) -> String { NSDecimalNumber(decimal: Decimal(minor) / 100).stringValue }
}

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
        case .unauthorized: retry("设备密钥无效", "key")
        case .offline: retry("无法连接个人 VPS", "wifi.slash")
        case .failed: retry(model.message ?? "加载失败", "exclamationmark.triangle")
        case .loaded:
            ScrollView { LazyVStack(spacing: MasterDataLayout.spacing) { ForEach(model.categories) { root in categoryCard(root, depth: 0); ForEach(root.children) { categoryCard($0, depth: 1) } } }.padding(MasterDataLayout.padding).padding(.bottom, MasterDataLayout.bottomPadding) }.background(MasterDataLayout.background)
        }
    }

    private func categoryCard(_ item: CategoryDTO, depth: Int) -> some View {
        FiscalCard(radius: 14) {
            HStack(spacing: 12) {
                if depth == 1 { Image(systemName: "arrow.turn.down.right").foregroundStyle(FiscalColor.tertiary).frame(width: 18) }
                FiscalIconTile(item.icon, color: Color(fiscalHex: item.colorHex))
                VStack(alignment: .leading, spacing: 3) {
                    HStack { Text(item.name).font(.headline); Text(item.direction.title).font(.caption2).padding(.horizontal, 6).padding(.vertical, 3).background(FiscalColor.accent.opacity(0.1), in: .capsule); if item.archivedAt != nil { Text("已归档").font(.caption2) } }
                    Text("别名 \(item.aliases.count) · 示例 \(item.examples.count) · 使用 \(item.usageCount)").font(.caption).foregroundStyle(FiscalColor.tertiary)
                    if !item.aliases.isEmpty { Text(item.aliases.joined(separator: "、")).font(.caption).foregroundStyle(FiscalColor.secondary).lineLimit(1) }
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
    @Environment(\.dismiss) private var dismiss
    let model: CategoriesModel; let category: CategoryDTO?; let roots: [CategoryDTO]
    @State private var draft: CategoryDraft; @State private var aliases: String; @State private var examples: String; @State private var validation: String?
    init(model: CategoriesModel, category: CategoryDTO?, roots: [CategoryDTO]) {
        self.model = model; self.category = category; self.roots = roots
        let d = category.map(CategoryDraft.init(category:)) ?? CategoryDraft(); _draft = State(initialValue: d); _aliases = State(initialValue: d.aliases.joined(separator: "，")); _examples = State(initialValue: d.examples.joined(separator: "，"))
    }
    var body: some View {
        NavigationStack { Form {
            Section("基本信息") {
                TextField("分类名称", text: $draft.name)
                Picker("方向", selection: $draft.direction) { ForEach(CategoryDirection.allCases) { Text($0.title).tag($0) } }
                    .disabled(hierarchyLocked)
                    .onChange(of: draft.direction) { _, direction in
                        if let parentID = draft.parentID,
                           roots.first(where: { $0.id == parentID })?.direction != direction { draft.parentID = nil }
                    }
                Picker("父分类", selection: $draft.parentID) { Text("根分类").tag(Optional<UUID>.none); ForEach(eligibleRoots) { Text($0.name).tag(Optional($0.id)) } }
                    .disabled(hierarchyLocked)
                if hierarchyLocked { Text("含子分类的根分类不能改变方向或父级。").font(.caption).foregroundStyle(FiscalColor.tertiary) }
                TextField("SF Symbol", text: $draft.icon)
                TextField("颜色 #RRGGBB", text: $draft.colorHex)
            }
            Section("AI 识别资料") { TextField("别名，以逗号分隔", text: $aliases); TextField("识别示例，以逗号分隔", text: $examples); Text("每组最多 20 条，每条不超过 40 个字符。").font(.caption).foregroundStyle(FiscalColor.tertiary) }
            if let validation { Section { Text(validation).foregroundStyle(FiscalColor.expense) } }
        }.navigationTitle(category == nil ? "新建分类" : "编辑分类").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } } } }.fiscalEditorFrame(width: 400, height: 540)
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
    var body: some View { NavigationStack { Form { Text("“\(source.name)”将归档；冲突外的子分类会移动到目标分类。"); Picker("目标分类", selection: $targetID) { Text("请选择").tag(Optional<UUID>.none); ForEach(targets) { Text($0.name).tag(Optional($0.id)) } } }.navigationTitle("合并分类").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("合并") { if let target = targets.first(where: { $0.id == targetID }) { Task { if await model.merge(source: source, target: target) { dismiss() } } } }.disabled(targetID == nil) } } }.fiscalEditorFrame(width: 380, height: 260) }
}

private struct SplitCategorySheet: View {
    @Environment(\.dismiss) private var dismiss; let model: CategoriesModel; let root: CategoryDTO; @State private var first = ""; @State private var second = ""
    var body: some View { NavigationStack { Form { Text("在“\(root.name)”下原子创建至少两个子分类，不移动任何流水。"); TextField("子分类一", text: $first); TextField("子分类二", text: $second) }.navigationTitle("拆分辅助").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("创建") { Task { if await model.split(root: root, children: [draft(first), draft(second)]) { dismiss() } } }.disabled(first.trimmingCharacters(in: .whitespaces).isEmpty || second.trimmingCharacters(in: .whitespaces).isEmpty) } } }.fiscalEditorFrame(width: 400, height: 300) }
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
    static let bottomPadding: CGFloat = 100
    static let background = FiscalColor.iOSBackground
    #endif
}
