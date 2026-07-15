import SwiftUI

private extension TransactionKind {
    var color: Color { switch self { case .expense: FiscalColor.expense; case .income: FiscalColor.income; case .transfer: FiscalColor.accent } }
}

private struct TransactionAmount: View {
    let transaction: TransactionDTO
    var body: some View {
        Text(prefix + Money(minorUnits: transaction.amountMinor).formatted())
            .font(.body.weight(.semibold)).foregroundStyle(transaction.kind.color).monospacedDigit()
    }
    private var prefix: String { switch transaction.kind { case .expense: "−"; case .income: "+"; case .transfer: "" } }
}

public struct TransactionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let transactions: TransactionsModel
    let accounts: AccountsModel
    let categories: CategoriesModel
    @State private var editor: TransactionEditorModel
    @State private var accountOptions: [AccountDTO] = []
    @State private var categoryOptions: [CategoryDTO] = []
    @State private var optionsError: String?
    @State private var loadingOptions = true

    public init(transactions: TransactionsModel, accounts: AccountsModel, categories: CategoriesModel, editing: TransactionDTO? = nil) {
        self.transactions = transactions; self.accounts = accounts; self.categories = categories
        _editor = State(initialValue: TransactionEditorModel(editing: editing))
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("类型", selection: kindBinding) { ForEach(TransactionKind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) } }
                        .pickerStyle(.segmented)
                    TextField("金额，例如 38.50", text: $editor.amountText)
#if os(iOS)
                        .keyboardType(.decimalPad)
#endif
                    TextField("标题", text: $editor.draft.title)
                    TextField("备注（可选）", text: $editor.draft.note, axis: .vertical).lineLimit(2...5)
                    DatePicker("发生时间", selection: $editor.draft.occurredAt)
                } header: { Text("交易") }
                if editor.draft.kind == .transfer { transferSection } else { incomeExpenseSection }
                if loadingOptions { Section { ProgressView("正在读取账户与分类…") } }
                if let optionsError { Section { Label(optionsError, systemImage: "wifi.exclamationmark").foregroundStyle(FiscalColor.expense); Button("重试") { Task { await loadOptions() } } } }
                if let message = editor.validationMessage ?? transactions.message {
                    Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(FiscalColor.expense) }
                }
            }
            .navigationTitle(editor.editing == nil ? "记一笔" : "编辑流水")
            .accessibilityIdentifier("transaction.editor")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(transactions.isMutating || loadingOptions) }
            }
            .task { await loadOptions() }
        }
        .frame(minWidth: 380, idealWidth: 440, minHeight: 520, idealHeight: 620)
        .interactiveDismissDisabled(transactions.isMutating)
    }

    private var kindBinding: Binding<TransactionKind> { Binding(get: { editor.draft.kind }, set: { editor.changeKind($0) }) }
    private var activeAccounts: [AccountDTO] {
        accountOptions.filter { ($0.archivedAt == nil || linkedAccountIDs.contains($0.id)) && $0.kind != .credit }
    }
    private var linkedAccountIDs: Set<UUID> { Set([editor.editing?.accountID, editor.editing?.destinationAccountID].compactMap { $0 }) }
    private var eligibleCategories: [CategoryDTO] {
        let direction: CategoryDirection = editor.draft.kind == .income ? .income : .expense
        return categoryOptions.filter { $0.direction == direction && ($0.archivedAt == nil || $0.id == editor.editing?.categoryID) }
    }
    private var incomeExpenseSection: some View {
        Section("归类") {
            Picker("账户", selection: $editor.draft.accountID) { Text("请选择").tag(Optional<UUID>.none); ForEach(activeAccounts) { Text($0.name).tag(Optional($0.id)) } }
            Picker("分类", selection: $editor.draft.categoryID) { Text("请选择").tag(Optional<UUID>.none); ForEach(eligibleCategories) { Text($0.name).tag(Optional($0.id)) } }
        }
    }
    private var transferSection: some View {
        Section("转账账户") {
            Picker("转出", selection: $editor.draft.accountID) { Text("请选择").tag(Optional<UUID>.none); ForEach(activeAccounts) { Text($0.name).tag(Optional($0.id)) } }
            Picker("转入", selection: $editor.draft.destinationAccountID) { Text("请选择").tag(Optional<UUID>.none); ForEach(activeAccounts) { Text($0.name).tag(Optional($0.id)) } }
        }
    }
    private func save() {
        guard editor.prepare() else { return }
        Task {
            let succeeded = await transactions.save(draft: editor.draft, editing: editor.editing, idempotencyKey: editor.idempotencyKey)
            if succeeded { dismiss() }
            else if transactions.shouldRotateCreateKeyAfterFailure { editor.rotateCreateKey() }
        }
    }
    private func loadOptions() async {
        loadingOptions = true; optionsError = nil
        defer { loadingOptions = false }
        do {
            async let loadedAccounts = accounts.transactionOptions()
            async let loadedCategories = categories.transactionOptions()
            accountOptions = try await loadedAccounts; categoryOptions = try await loadedCategories
        } catch is CancellationError {
            optionsError = "读取已取消，请重试"
            return
        }
        catch { optionsError = (error as? FiscalAPIError)?.displayMessage ?? error.localizedDescription }
    }
}

#if os(iOS)
public struct IOSTransactionsScreen: View {
    @Bindable var model: TransactionsModel
    let accounts: AccountsModel
    let categories: CategoriesModel
    @State private var editing: TransactionDTO?
    @State private var pendingVoid: TransactionDTO?

    public init(model: TransactionsModel, accounts: AccountsModel, categories: CategoriesModel) { self.model = model; self.accounts = accounts; self.categories = categories }
    public var body: some View {
        VStack(spacing: 0) {
            filterBar
            if let banner = model.refreshMessage { bannerView(banner) }
            content
        }
        .background(FiscalColor.iOSBackground).navigationTitle("流水")
        .accessibilityIdentifier("transactions.screen")
        .searchable(text: $model.search, prompt: "搜索标题或备注")
        .onChange(of: model.search) { _, _ in model.scheduleLoad() }
        .task { if model.phase == .idle { await model.load() } }
        .sheet(item: $editing) { TransactionEditorSheet(transactions: model, accounts: accounts, categories: categories, editing: $0) }
        .alert("作废这笔流水？", isPresented: Binding(get: { pendingVoid != nil }, set: { if !$0 { pendingVoid = nil } })) {
            Button("取消", role: .cancel) { pendingVoid = nil }
            Button("作废", role: .destructive) { if let item = pendingVoid { Task { _ = await model.void(item); pendingVoid = nil } } }
        } message: { Text("作废后余额会立即重算，可通过页面底部的撤销恢复。") }
        .alert("数据已变化", isPresented: Binding(get: { model.conflictDetected }, set: { if !$0 { model.clearConflict() } })) {
            Button("重新加载") { Task { await model.load() } }; Button("取消", role: .cancel) { model.clearConflict() }
        } message: { Text("服务器上的版本更高，请重新加载后再编辑。") }
        .safeAreaInset(edge: .bottom) { if model.undoTransaction != nil { undoBar } }
    }
    private var filterBar: some View {
        ScrollView(.horizontal) { HStack { chip("全部", nil); ForEach(TransactionKind.allCases) { chip($0.title, $0) } }.padding(.horizontal, 16).padding(.vertical, 8) }.scrollIndicators(.hidden)
    }
    private func chip(_ title: String, _ kind: TransactionKind?) -> some View {
        Button { model.kind = kind; Task { await model.load() } } label: { Text(title).font(.subheadline.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 8).background(model.kind == kind ? FiscalColor.accent : .white, in: .capsule).foregroundStyle(model.kind == kind ? .white : FiscalColor.secondary) }.buttonStyle(.plain)
    }
    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .loading: ProgressView("正在读取流水…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty: ContentUnavailableView(model.search.isEmpty && model.kind == nil ? "还没有流水" : "没有匹配的流水", systemImage: "list.bullet.rectangle", description: Text("使用底部中央按钮记录收入、支出或转账。"))
        case .unauthorized: retry("设备密钥无效", "key")
        case .offline: retry("无法连接个人 VPS", "wifi.slash")
        case .failed: retry(model.message ?? "读取失败", "exclamationmark.triangle")
        case .loaded:
            ScrollView { LazyVStack(alignment: .leading, spacing: 12) { ForEach(model.groups) { group in Text(group.title).font(.headline).padding(.horizontal, 4); FiscalCard(radius: 18) { VStack(spacing: 0) { ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in if index > 0 { Divider() }; row(item) } } } } }.padding(16).padding(.bottom, 88) }.refreshable { await model.load() }
        }
    }
    private func row(_ item: TransactionDTO) -> some View {
        Button { editing = item } label: { HStack(spacing: 12) { FiscalIconTile(item.kind.symbol, color: item.kind.color); VStack(alignment: .leading, spacing: 3) { Text(item.title).font(.headline).foregroundStyle(FiscalColor.text); Text(detail(item)).font(.caption).foregroundStyle(FiscalColor.tertiary).lineLimit(1) }; Spacer(); TransactionAmount(transaction: item); Menu { Button("编辑", systemImage: "pencil") { editing = item }; Button("作废", systemImage: "trash", role: .destructive) { pendingVoid = item } } label: { Image(systemName: "ellipsis").frame(width: 32, height: 44) }.buttonStyle(.plain) }.contentShape(.rect).padding(.vertical, 6) }.buttonStyle(.plain).task { await model.loadMoreIfNeeded(after: item) }
    }
    private func detail(_ item: TransactionDTO) -> String { item.note.map { "\(item.kind.title) · \($0)" } ?? item.kind.title }
    private func retry(_ title: String, _ symbol: String) -> some View { ContentUnavailableView { Label(title, systemImage: symbol) } description: { Text(model.message ?? "不会使用预览数据替代。") } actions: { Button("重试") { Task { await model.load() } } } }
    private func bannerView(_ text: String) -> some View { Label(text, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(FiscalColor.expense).padding(8).frame(maxWidth: .infinity).background(FiscalColor.expense.opacity(0.08)) }
    private var undoBar: some View { HStack { Text("流水已作废"); Spacer(); Button("撤销") { Task { _ = await model.undoVoid() } }; Button { model.clearUndo() } label: { Image(systemName: "xmark") } }.padding().background(.regularMaterial, in: .rect(cornerRadius: 14)).padding(.horizontal) }
}
#endif

#if os(macOS)
public struct MacTransactionsScreen: View {
    @Bindable var model: TransactionsModel
    let accounts: AccountsModel; let categories: CategoriesModel
    @State private var showCreate = false; @State private var editing: TransactionDTO?; @State private var pendingVoid: TransactionDTO?
    @State private var accountNames: [UUID: String] = [:]
    @State private var accountNamesError: String?
    public init(model: TransactionsModel, accounts: AccountsModel, categories: CategoriesModel) { self.model = model; self.accounts = accounts; self.categories = categories }
    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let message = model.refreshMessage { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(FiscalColor.expense).padding(7).frame(maxWidth: .infinity).background(FiscalColor.expense.opacity(0.08)) }
            if let accountNamesError {
                HStack {
                    Label(accountNamesError, systemImage: "wifi.exclamationmark")
                    Spacer()
                    Button("重试") { Task { await loadMasterNames() } }
                }
                .font(.caption)
                .foregroundStyle(FiscalColor.expense)
                .padding(7)
                .background(FiscalColor.expense.opacity(0.08))
            }
            HSplitView {
                table.frame(minWidth: 520).layoutPriority(1)
                inspector.frame(minWidth: 256, idealWidth: 256, maxWidth: 256)
            }
        }
        .task {
            async let transactionLoad: Void = model.phase == .idle ? model.load() : ()
            async let masterLoad: Void = loadMasterNames()
            _ = await (transactionLoad, masterLoad)
        }
        .sheet(isPresented: $showCreate) { TransactionEditorSheet(transactions: model, accounts: accounts, categories: categories) }
        .sheet(item: $editing) { TransactionEditorSheet(transactions: model, accounts: accounts, categories: categories, editing: $0) }
        .alert("作废这笔流水？", isPresented: Binding(get: { pendingVoid != nil }, set: { if !$0 { pendingVoid = nil } })) { Button("取消", role: .cancel) {}; Button("作废", role: .destructive) { if let value = pendingVoid { Task { _ = await model.void(value); pendingVoid = nil } } } }
        .alert("数据已变化", isPresented: Binding(get: { model.conflictDetected }, set: { if !$0 { model.clearConflict() } })) { Button("重新加载") { Task { await model.load() } }; Button("取消", role: .cancel) {} }
    }
    private var toolbar: some View { HStack(spacing: 12) { Text("流水").font(.title2.bold()); Picker("类型", selection: $model.kind) { Text("全部").tag(Optional<TransactionKind>.none); ForEach(TransactionKind.allCases) { Text($0.title).tag(Optional($0)) } }.frame(width: 150).onChange(of: model.kind) { _, _ in Task { await model.load() } }; TextField("搜索标题或备注", text: $model.search).textFieldStyle(.roundedBorder).frame(maxWidth: 260).onSubmit { Task { await model.load() } }; Spacer(); if model.undoTransaction != nil { Button("撤销作废") { Task { _ = await model.undoVoid() } }.keyboardShortcut("z", modifiers: .command) }; Button { showCreate = true } label: { Label("记一笔", systemImage: "plus") }.keyboardShortcut("n", modifiers: .command) }.padding(16).background(.white) }
    @ViewBuilder private var table: some View {
        switch model.phase {
        case .idle, .loading: ProgressView("正在读取流水…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty: ContentUnavailableView("还没有流水", systemImage: "list.bullet.rectangle", description: Text("按 ⌘N 记录第一笔。"))
        case .unauthorized, .offline, .failed: ContentUnavailableView { Label(model.message ?? "读取失败", systemImage: "exclamationmark.triangle") } actions: { Button("重试") { Task { await model.load() } } }
        case .loaded:
            Table(model.transactions, selection: $model.selectedID) {
                TableColumn("日期") { item in Text(item.businessDate).foregroundStyle(FiscalColor.secondary).task { await model.loadMoreIfNeeded(after: item) } }.width(min: 90, ideal: 100)
                TableColumn("摘要") { Text($0.title).fontWeight(.medium) }.width(min: 150, ideal: 220)
                TableColumn("类型") { Text($0.kind.title) }.width(64)
                TableColumn("金额") { TransactionAmount(transaction: $0) }.width(min: 100, ideal: 120)
            }
        }
    }
    @ViewBuilder private var inspector: some View {
        if let item = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        FiscalIconTile(item.kind.symbol, color: item.kind.color)
                        VStack(alignment: .leading) {
                            Text(item.title).font(.title3.bold())
                            Text(item.kind.title).foregroundStyle(FiscalColor.secondary)
                        }
                    }
                    TransactionAmount(transaction: item).font(.title2)
                    Divider()
                    field("发生时间", item.occurredAt.formatted(date: .long, time: .shortened))
                    field("业务日期", item.businessDate)
                    if let note = item.note { field("备注", note) }
                    Text("账户影响").font(.headline)
                    ForEach(item.postings) { posting in
                        HStack {
                            Text(accountNames[posting.accountID] ?? "账户")
                            Spacer()
                            Text(Money(minorUnits: posting.amountMinor).formatted(showPositiveSign: true)).monospacedDigit()
                        }
                    }
                    Divider()
                    HStack { Button("编辑") { editing = item }; Button("作废", role: .destructive) { pendingVoid = item } }
                }.padding(18)
            }
        } else {
            ContentUnavailableView("选择一笔流水", systemImage: "sidebar.right", description: Text("右侧将显示语义字段和只读账户影响。"))
        }
    }
    private func field(_ label: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 3) { Text(label).font(.caption).foregroundStyle(FiscalColor.tertiary); Text(value).textSelection(.enabled) } }
    private func loadMasterNames() async {
        accountNamesError = nil
        do { accountNames = Dictionary(uniqueKeysWithValues: try await accounts.transactionOptions().map { ($0.id, $0.name) }) }
        catch is CancellationError { return }
        catch { accountNamesError = (error as? FiscalAPIError)?.displayMessage ?? "账户名称读取失败" }
    }
}
#endif
