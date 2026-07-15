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
        .searchable(
            text: $model.search,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "搜索标题或备注"
        )
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
        Button { editing = item } label: { HStack(spacing: 12) { FiscalIconTile(item.kind.symbol, color: item.kind.color); VStack(alignment: .leading, spacing: 3) { Text(item.title).font(.headline).foregroundStyle(FiscalColor.text); Text(detail(item)).font(.caption).foregroundStyle(FiscalColor.tertiary).lineLimit(1) }; Spacer(); TransactionAmount(transaction: item); Menu { Button("编辑", systemImage: "pencil") { editing = item }; Button("作废", systemImage: "trash", role: .destructive) { pendingVoid = item } } label: { Image(systemName: "ellipsis").frame(width: 32, height: 44) }.buttonStyle(.plain).accessibilityIdentifier("transaction.rowMenu") }.contentShape(.rect).padding(.vertical, 6) }.buttonStyle(.plain).task { await model.loadMoreIfNeeded(after: item) }
    }
    private func detail(_ item: TransactionDTO) -> String { item.note.map { "\(item.kind.title) · \($0)" } ?? item.kind.title }
    private func retry(_ title: String, _ symbol: String) -> some View { ContentUnavailableView { Label(title, systemImage: symbol) } description: { Text(model.message ?? "不会使用预览数据替代。") } actions: { Button("重试") { Task { await model.load() } } } }
    private func bannerView(_ text: String) -> some View { Label(text, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(FiscalColor.expense).padding(8).frame(maxWidth: .infinity).background(FiscalColor.expense.opacity(0.08)) }
    private var undoBar: some View {
        HStack {
            Text("流水已作废")
            Spacer()
            Button("撤销") { Task { _ = await model.undoVoid() } }
            Button { model.clearUndo() } label: { Image(systemName: "xmark") }
        }
        .padding()
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .padding(.horizontal)
        .padding(.bottom, 82)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transaction.undoBar")
    }
}
#endif

#if os(macOS)
public struct MacTransactionsScreen: View {
    @Bindable var model: TransactionsModel
    let accounts: AccountsModel
    let categories: CategoriesModel
    @State private var showCreate = false
    @State private var editing: TransactionDTO?
    @State private var pendingVoid: TransactionDTO?
    @State private var accountNames: [UUID: String] = [:]
    @State private var categoryNames: [UUID: String] = [:]
    @State private var masterNamesError: String?

    public init(model: TransactionsModel, accounts: AccountsModel, categories: CategoriesModel) {
        self.model = model; self.accounts = accounts; self.categories = categories
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            if let message = model.refreshMessage { errorBanner(message) }
            if let masterNamesError {
                HStack {
                    Label(masterNamesError, systemImage: "wifi.exclamationmark")
                    Spacer()
                    Button("重试") { Task { await loadMasterNames() } }.buttonStyle(.plain).fontWeight(.semibold)
                }
                .font(.caption).foregroundStyle(FiscalColor.expense)
                .padding(.horizontal, 20).frame(height: 34)
                .background(FiscalColor.expense.opacity(0.08))
            }
            HStack(spacing: 0) {
                VStack(spacing: 0) { filterBar; columnHeader; transactionContent }
                    .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
                Divider().opacity(0.55)
                inspector.frame(width: 256).frame(maxHeight: .infinity).background(.white)
            }
        }
        .background(FiscalColor.macBackground)
        .task {
            async let transactionLoad: Void = model.phase == .idle ? model.load() : ()
            async let masterLoad: Void = loadMasterNames()
            _ = await (transactionLoad, masterLoad)
        }
        .sheet(isPresented: $showCreate) { TransactionEditorSheet(transactions: model, accounts: accounts, categories: categories) }
        .sheet(item: $editing) { TransactionEditorSheet(transactions: model, accounts: accounts, categories: categories, editing: $0) }
        .alert("作废这笔流水？", isPresented: Binding(get: { pendingVoid != nil }, set: { if !$0 { pendingVoid = nil } })) {
            Button("取消", role: .cancel) {}
            Button("作废", role: .destructive) { if let item = pendingVoid { Task { _ = await model.void(item); pendingVoid = nil } } }
        }
        .alert("数据已变化", isPresented: Binding(get: { model.conflictDetected }, set: { if !$0 { model.clearConflict() } })) {
            Button("重新加载") { Task { await model.load() } }; Button("取消", role: .cancel) {}
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Text("流水").font(.system(size: 22, weight: .bold)).foregroundStyle(FiscalColor.text)
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(FiscalColor.tertiary)
                TextField("搜索流水…", text: $model.search).textFieldStyle(.plain).font(.system(size: 13)).onSubmit { Task { await model.load() } }
            }
            .padding(.horizontal, 11).frame(width: 220, height: 32)
            .background(.white, in: .rect(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).stroke(.black.opacity(0.09), lineWidth: 0.5) }
        }
        .padding(.horizontal, 20).frame(height: 54).background(.white)
        .overlay(alignment: .bottom) { Divider().opacity(0.45) }
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            filterChip("全部", kind: nil)
            ForEach(TransactionKind.allCases) { filterChip($0.title, kind: $0) }
            Spacer(minLength: 8)
            Text("共 \(model.transactions.count) 笔").font(.system(size: 12)).foregroundStyle(FiscalColor.tertiary).monospacedDigit()
            if model.undoTransaction != nil {
                Button("撤销") { Task { _ = await model.undoVoid() } }.buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(FiscalColor.accent).keyboardShortcut("z", modifiers: .command)
            }
            Button { showCreate = true } label: {
                Label("记一笔", systemImage: "plus").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 30).background(FiscalColor.accent, in: .rect(cornerRadius: 9))
            }.buttonStyle(.plain).keyboardShortcut("n", modifiers: .command)
        }
        .padding(.horizontal, 20).frame(height: 54)
        .overlay(alignment: .bottom) { Divider().opacity(0.45) }
    }

    private func filterChip(_ title: String, kind: TransactionKind?) -> some View {
        Button { model.kind = kind; Task { await model.load() } } label: {
            Text(title).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(model.kind == kind ? .white : FiscalColor.secondary)
                .padding(.horizontal, 10).frame(height: 27)
                .background(model.kind == kind ? FiscalColor.accent : .white, in: .rect(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(model.kind == kind ? Color.clear : Color.black.opacity(0.08), lineWidth: 0.5) }
        }.buttonStyle(.plain)
    }

    private var columnHeader: some View {
        HStack(spacing: 10) {
            header("日期").frame(width: 50, alignment: .leading)
            header("摘要").frame(maxWidth: .infinity, alignment: .leading)
            header("分类").frame(width: 64, alignment: .leading)
            header("账户").frame(width: 86, alignment: .leading)
            header("金额").frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 20).frame(height: 35).background(FiscalColor.macBackground)
        .overlay(alignment: .bottom) { Divider().opacity(0.42) }
    }
    private func header(_ value: String) -> some View { Text(value).font(.system(size: 11, weight: .semibold)).foregroundStyle(FiscalColor.tertiary) }

    @ViewBuilder private var transactionContent: some View {
        switch model.phase {
        case .idle, .loading: ProgressView("正在读取流水…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty: ContentUnavailableView("还没有流水", systemImage: "list.bullet.rectangle", description: Text("按 ⌘N 记录第一笔。"))
        case .unauthorized, .offline, .failed:
            ContentUnavailableView { Label(model.message ?? "读取失败", systemImage: "exclamationmark.triangle") } actions: { Button("重试") { Task { await model.load() } } }
        case .loaded:
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.transactions) { item in transactionRow(item).task { await model.loadMoreIfNeeded(after: item) } }
                    if model.isLoadingMore { ProgressView().controlSize(.small).padding(12) }
                }
            }.background(FiscalColor.macBackground)
        }
    }

    private func transactionRow(_ item: TransactionDTO) -> some View {
        Button { model.selectedID = item.id } label: {
            HStack(spacing: 10) {
                Text(shortDate(item.businessDate)).font(.system(size: 12)).foregroundStyle(FiscalColor.tertiary).monospacedDigit().frame(width: 50, alignment: .leading)
                HStack(spacing: 9) {
                    Image(systemName: item.kind.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(item.kind.color)
                        .frame(width: 26, height: 26).background(item.kind.color.opacity(0.12), in: .rect(cornerRadius: 7))
                    Text(item.title).font(.system(size: 13)).foregroundStyle(FiscalColor.text).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(categoryName(item)).font(.system(size: 12.5)).foregroundStyle(FiscalColor.secondary).lineLimit(1).frame(width: 64, alignment: .leading)
                Text(accountName(item)).font(.system(size: 12.5)).foregroundStyle(FiscalColor.secondary).lineLimit(1).frame(width: 86, alignment: .leading)
                amountText(item).font(.system(size: 13, weight: .semibold)).foregroundStyle(item.kind.color).monospacedDigit().frame(width: 92, alignment: .trailing)
            }
            .padding(.horizontal, 20).frame(height: 45)
            .background(model.selectedID == item.id ? FiscalColor.accent.opacity(0.10) : Color.clear).contentShape(.rect)
        }
        .buttonStyle(.plain).overlay(alignment: .bottom) { Divider().opacity(0.35).padding(.leading, 20) }
    }

    @ViewBuilder private var inspector: some View {
        if let item = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: item.kind.symbol).font(.system(size: 19, weight: .semibold)).foregroundStyle(item.kind.color)
                            .frame(width: 44, height: 44).background(item.kind.color.opacity(0.12), in: .rect(cornerRadius: 12))
                        VStack(alignment: .leading) {
                            Text(item.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(FiscalColor.text).lineLimit(1)
                            Text(sourceName(item.source)).font(.system(size: 12)).foregroundStyle(FiscalColor.tertiary).padding(.top, 1)
                        }
                    }
                    amountText(item).font(.system(size: 30, weight: .bold)).tracking(-0.8).foregroundStyle(item.kind.color).monospacedDigit().padding(.top, 16).padding(.bottom, 12)
                    Divider().opacity(0.6)
                    detailRow("类型", item.kind.title)
                    detailRow("分类", categoryName(item))
                    detailRow("账户", accountName(item))
                    detailRow("日期", item.businessDate)
                    if let note = item.note { detailRow("备注", note) }
                    Text("账户影响").font(.system(size: 12, weight: .semibold)).foregroundStyle(FiscalColor.tertiary).padding(.top, 16).padding(.bottom, 7)
                    ForEach(item.postings) { posting in
                        HStack {
                            Text(accountNames[posting.accountID] ?? "账户").lineLimit(1); Spacer()
                            Text(Money(minorUnits: posting.amountMinor).formatted(showPositiveSign: true)).monospacedDigit()
                        }.font(.system(size: 12.5)).foregroundStyle(FiscalColor.secondary).padding(.vertical, 5)
                    }
                    HStack(spacing: 8) {
                        Button { editing = item } label: { Text("编辑").frame(maxWidth: .infinity, minHeight: 38).background(FiscalColor.accent, in: .rect(cornerRadius: 10)).foregroundStyle(.white) }
                        Button { pendingVoid = item } label: { Text("删除").padding(.horizontal, 15).frame(minHeight: 38).background(Color.black.opacity(0.06), in: .rect(cornerRadius: 10)).foregroundStyle(FiscalColor.secondary) }
                    }.font(.system(size: 13, weight: .semibold)).buttonStyle(.plain).padding(.top, 18)
                }.padding(.horizontal, 20).padding(.vertical, 22)
            }.background(.white)
        } else {
            ContentUnavailableView("选择一笔流水", systemImage: "sidebar.right", description: Text("右侧将显示详情。"))
                .background(.white)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(FiscalColor.tertiary); Spacer(minLength: 8)
            Text(value).foregroundStyle(FiscalColor.text).fontWeight(.medium).lineLimit(2).multilineTextAlignment(.trailing)
        }.font(.system(size: 13)).padding(.vertical, 11).overlay(alignment: .bottom) { Divider().opacity(0.35) }
    }
    private func categoryName(_ item: TransactionDTO) -> String { item.categoryID.flatMap { categoryNames[$0] } ?? (item.kind == .transfer ? "—" : "未分类") }
    private func accountName(_ item: TransactionDTO) -> String {
        let source = item.accountID.flatMap { accountNames[$0] } ?? "账户"
        if item.kind == .transfer, let destination = item.destinationAccountID.flatMap({ accountNames[$0] }) { return "\(source) → \(destination)" }
        return source
    }
    private func amountText(_ item: TransactionDTO) -> Text {
        let prefix = item.kind == .income ? "+" : item.kind == .expense ? "-" : ""
        return Text(prefix + Money(minorUnits: item.amountMinor).formatted())
    }
    private func shortDate(_ value: String) -> String { String(value.suffix(5)).replacingOccurrences(of: "-", with: "/") }
    private func sourceName(_ source: String) -> String { switch source { case "manual": "手动录入"; case "ocr": "截图识别"; case "ai": "AI 录入"; default: source } }
    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(FiscalColor.expense)
            .padding(7).frame(maxWidth: .infinity).background(FiscalColor.expense.opacity(0.08))
    }
    private func loadMasterNames() async {
        masterNamesError = nil
        do {
            async let loadedAccounts = accounts.transactionOptions()
            async let loadedCategories = categories.transactionOptions()
            accountNames = Dictionary(uniqueKeysWithValues: try await loadedAccounts.map { ($0.id, $0.name) })
            categoryNames = Dictionary(uniqueKeysWithValues: try await loadedCategories.map { ($0.id, $0.name) })
        } catch is CancellationError {
            return
        } catch {
            masterNamesError = (error as? FiscalAPIError)?.displayMessage ?? "账户与分类名称读取失败"
        }
    }
}
#endif
