#if os(macOS)
import SwiftUI

public struct MacTransactionWorkbench: View {
  @Bindable private var model: TransactionsModel
  private let accounts: AccountsModel
  private let categories: CategoriesModel
  private let credit: CreditModel?
  private let installments: InstallmentModel?

  @State private var selection = Set<UUID>()
  @State private var editing: TransactionDTO?
  @State private var pendingVoid: TransactionDTO?
  @State private var installmentPurchase: TransactionDTO?
  @State private var showFilters = false
  @State private var showInspectorInCompactWidth = false
  @State private var accountNames = [UUID: String]()
  @State private var categoryNames = [UUID: String]()
  @State private var accountOptions = [AccountDTO]()
  @State private var categoryOptions = [CategoryDTO]()
  @State private var optionsError: String?
  @State private var batchCategoryID: UUID?
  @State private var confirmBatch = false
  @State private var filterDraft = TransactionsModel.FilterDraft()
  @FocusState private var searchFocused: Bool

  public init(
    model: TransactionsModel,
    accounts: AccountsModel,
    categories: CategoriesModel,
    credit: CreditModel? = nil,
    installments: InstallmentModel? = nil,
    preferences: RecordingPreferences? = nil
  ) {
    self.model = model
    self.accounts = accounts
    self.categories = categories
    self.credit = credit
    self.installments = installments
    let initialAccounts = accounts.accounts
    let initialCategories = categories.categories.flatMap { [$0] + $0.children }
    _accountOptions = State(initialValue: initialAccounts)
    _categoryOptions = State(initialValue: initialCategories)
    _accountNames = State(
      initialValue: Dictionary(uniqueKeysWithValues: initialAccounts.map { ($0.id, $0.name) }))
    _categoryNames = State(
      initialValue: Dictionary(uniqueKeysWithValues: initialCategories.map { ($0.id, $0.name) }))
  }

  public var body: some View {
    GeometryReader { proxy in
      let showsInspector = proxy.size.width >= 900 || showInspectorInCompactWidth
      VStack(spacing: 0) {
        topBar(showsInspector: showsInspector, compact: proxy.size.width < 900)
        if let message = model.refreshMessage { statusBanner(message) }
        if let optionsError { statusBanner(optionsError) }
        if selection.count > 1 { batchBar }
        HStack(spacing: 0) {
          tableArea
            .frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
          if showsInspector {
            Divider()
            inspector
              .frame(minWidth: 240, idealWidth: 280, maxWidth: 340, maxHeight: .infinity)
              .transition(.opacity)
          }
        }
      }
      .onChange(of: proxy.size.width) { _, width in
        if width >= 900 { showInspectorInCompactWidth = false }
      }
    }
    .background(FiscalColor.macBackground)
    .task {
      async let transactionLoad: Void = model.phase == .idle ? model.load() : ()
      async let optionLoad: Void = loadOptions()
      _ = await (transactionLoad, optionLoad)
      if selection.isEmpty, let first = model.transactions.first { selection = [first.id] }
    }
    .onChange(of: model.search) { _, _ in model.scheduleLoad() }
    .onChange(of: model.transactions.map(\.id)) { _, visible in
      selection.formIntersection(Set(visible))
    }
    .sheet(item: $editing) {
      TransactionEditorSheet(
        transactions: model, accounts: accounts, categories: categories, credit: credit,
        installments: installments, editing: $0)
    }
    .sheet(item: $installmentPurchase) {
      if let installments {
        InstallmentCreateSheet(installments: installments, purchase: $0, categories: categories)
      }
    }
    .alert("作废这笔流水？", isPresented: voidAlert) {
      Button("取消", role: .cancel) { pendingVoid = nil }
      Button("作废", role: .destructive) {
        guard let pendingVoid else { return }
        Task {
          _ = await model.void(pendingVoid)
          self.pendingVoid = nil
        }
      }
    } message: {
      Text("作废后余额和相关报表会立即重算，可使用 ⌘Z 撤销。")
    }
    .alert("批量重新分类？", isPresented: $confirmBatch) {
      Button("取消", role: .cancel) {}
      Button("确认分类") { performBatchClassification() }
    } message: {
      Text(batchConfirmationText)
    }
    .alert("数据已变化", isPresented: conflictAlert) {
      Button("重新加载") { Task { await model.load() } }
      Button("取消", role: .cancel) { model.clearConflict() }
    } message: {
      Text("服务器上的版本更高，批量操作没有写入任何流水。")
    }
    .overlay { keyboardActions }
    .accessibilityIdentifier("mac.transactions.workbench")
  }

  private func topBar(showsInspector: Bool, compact: Bool) -> some View {
    HStack(spacing: 12) {
      Text("流水").font(.title2.bold())
      Text("已载入 \(model.totalCount) 笔")
        .font(.caption).foregroundStyle(FiscalColor.tertiary)
      Spacer(minLength: 12)
      Button { if !showFilters { filterDraft = model.currentFilterDraft() }; showFilters.toggle() } label: {
        Label("筛选", systemImage: model.hasAdvancedFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
      }
      .buttonStyle(.borderless)
      .popover(isPresented: $showFilters, arrowEdge: .top) { advancedFilters }
      HStack(spacing: 7) {
        Image(systemName: "magnifyingglass").accessibilityHidden(true)
        TextField("搜索全部流水…", text: $model.search)
          .textFieldStyle(.plain).focused($searchFocused)
          .accessibilityLabel("搜索全部流水")
        if !model.search.isEmpty {
          Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.plain).accessibilityLabel("清除搜索")
        }
      }
      .font(.subheadline).padding(.horizontal, 10).frame(width: compact ? 190 : 240, height: 32)
      .background(.background, in: .rect(cornerRadius: 9))
      .overlay { RoundedRectangle(cornerRadius: 9).stroke(.separator.opacity(0.5)) }
      if compact {
        Button { showInspectorInCompactWidth.toggle() } label: {
          Image(systemName: showsInspector ? "arrow.right.to.line" : "sidebar.right")
        }
        .help(showsInspector ? "隐藏检查器" : "显示检查器")
        .accessibilityLabel(showsInspector ? "隐藏检查器" : "显示检查器")
      }
    }
    .padding(.horizontal, 18).frame(height: 54).background(.background)
    .overlay(alignment: .bottom) { Divider() }
  }

  private var tableArea: some View {
    ZStack {
      switch model.phase {
      case .idle, .loading:
        ProgressView("正在读取流水…")
      case .empty:
        ContentUnavailableView(
          model.hasFilters ? "没有匹配的流水" : "还没有流水",
          systemImage: model.hasFilters ? "line.3.horizontal.decrease.circle" : "list.bullet.rectangle",
          description: Text(model.hasFilters ? "调整搜索或筛选条件后重试。" : "按 ⌘N 记录第一笔。"))
      case .unauthorized:
        retryState("访问口令无效", symbol: "key")
      case .offline:
        retryState("无法连接个人 VPS", symbol: "wifi.slash")
      case .failed:
        retryState(model.message ?? "读取失败", symbol: "exclamationmark.triangle")
      case .loaded:
        transactionTable
      }
    }
    .background(FiscalColor.macBackground)
  }

  private var transactionTable: some View {
    Table(model.transactions, selection: $selection) {
      TableColumn("日期") { item in
        Text(shortDate(item.businessDate)).foregroundStyle(FiscalColor.tertiary)
      }.width(min: 54, ideal: 64, max: 72)
      TableColumn("摘要") { item in
        HStack(spacing: 7) {
          Image(systemName: item.kind.symbol).foregroundStyle(kindColor(item.kind)).accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text(item.title).lineLimit(1)
            if item.isUncategorizedInboxItem {
              Text("待归类").font(.caption2.bold()).foregroundStyle(FiscalColor.debt)
            }
          }
        }
        .task { await model.loadMoreIfNeeded(after: item) }
        .accessibilityElement(children: .combine)
      }.width(min: 135, ideal: 190)
      TableColumn("类型") { Text($0.kind.title).foregroundStyle(FiscalColor.secondary) }
        .width(min: 52, ideal: 62, max: 72)
      TableColumn("分类") { item in
        Text(categoryName(item)).foregroundStyle(item.categoryID == nil ? FiscalColor.debt : FiscalColor.secondary)
      }.width(min: 58, ideal: 76, max: 92)
      TableColumn("账户") { Text(accountName($0)).foregroundStyle(FiscalColor.secondary).lineLimit(1) }
        .width(min: 78, ideal: 104, max: 126)
      TableColumn("来源") { Text(sourceName($0.source)).foregroundStyle(FiscalColor.tertiary) }
        .width(min: 52, ideal: 62, max: 72)
      TableColumn("金额") { item in
        amountText(item).fontWeight(.semibold).foregroundStyle(kindColor(item.kind))
      }.width(min: 88, ideal: 100, max: 116)
    }
    .tableStyle(.inset(alternatesRowBackgrounds: false))
    .accessibilityLabel("流水表，共 \(model.totalCount) 笔")
    .overlay(alignment: .bottom) {
      if model.isLoadingMore { ProgressView().controlSize(.small).padding(8) }
    }
  }

  private var inspector: some View {
    Group {
      if selection.count > 1 {
        batchInspector
      } else if let item = selectedTransaction {
        transactionInspector(item)
      } else {
        ContentUnavailableView(
          "选择一笔流水", systemImage: "sidebar.right", description: Text("右侧将显示详情。"))
      }
    }
    .background(.background)
  }

  private func transactionInspector(_ item: TransactionDTO) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 12) {
          FiscalIconTile(item.kind.symbol, color: kindColor(item.kind)).accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 3) {
            Text(item.title).font(.headline).fixedSize(horizontal: false, vertical: true)
            Text(sourceName(item.source)).font(.caption).foregroundStyle(FiscalColor.tertiary)
          }
        }
        amountText(item).font(.largeTitle.bold()).foregroundStyle(kindColor(item.kind))
          .padding(.vertical, 14)
        Divider()
        detail("类型", item.kind.title)
        detail("分类", categoryName(item))
        detail("账户", accountName(item))
        detail("日期", item.businessDate)
        if let note = item.note { detail("备注", note) }
        if item.voidedAt != nil { detail("状态", "已作废") }
        if let relation = item.installmentRelation {
          detail("分期", "\(relation.planTitle) · \(relation.planStatus.title)")
        }
        ForEach(Array(item.reimbursementRelations.enumerated()), id: \.offset) { _, relation in
          detail("报销", "\(relation.claimTitle) · \(relation.claimStatus.title)")
        }
        if item.kind == .creditPurchase && item.installmentPlanID == nil && item.voidedAt == nil {
          Button("创建分期计划") { installmentPurchase = item }
            .buttonStyle(.bordered).padding(.top, 14)
        }
        if item.isUserEditable && item.installmentPlanID == nil && item.voidedAt == nil {
          HStack {
            Button("编辑") { editing = item }.buttonStyle(.borderedProminent)
            Button("作废", role: .destructive) { pendingVoid = item }.buttonStyle(.bordered)
          }
          .disabled(model.isMutating).padding(.top, 14)
        } else {
          Text(inspectorReadOnlyReason(item)).font(.caption).foregroundStyle(FiscalColor.tertiary)
            .padding(.top, 14)
        }
      }
      .padding(18)
    }
    .accessibilityElement(children: .contain)
  }

  private var batchInspector: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        Label("已选择 \(selection.count) 笔", systemImage: "checkmark.circle.fill").font(.title3.bold())
        Text("批量重新分类会作为一次原子操作提交；任何流水已变化时，整批都不会写入。")
          .font(.caption).foregroundStyle(FiscalColor.secondary)
        if !selectedTransactions.allSatisfy(\.isUncategorizedInboxItem) {
          Label("选择中包含不可批量分类的流水", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(FiscalColor.expense)
        }
        batchCategoryPicker
        Button("批量重新分类") { confirmBatch = true }
          .buttonStyle(.borderedProminent)
          .disabled(!canBatchClassify || model.isMutating)
      }
      .padding(18)
    }
  }

  private var batchBar: some View {
    HStack(spacing: 12) {
      Text("已选择 \(selection.count) 笔").fontWeight(.semibold)
      batchCategoryPicker.frame(maxWidth: 260)
      Button("重新分类") { confirmBatch = true }.buttonStyle(.borderedProminent)
        .disabled(!canBatchClassify || model.isMutating)
      Spacer()
      Button("取消选择") { selection.removeAll() }.buttonStyle(.plain)
    }
    .padding(.horizontal, 18).frame(height: 48).background(FiscalColor.accent.opacity(0.08))
  }

  private var batchCategoryPicker: some View {
    Picker("目标分类", selection: $batchCategoryID) {
      Text("请选择分类").tag(Optional<UUID>.none)
      ForEach(batchCategoryOptions) { Text($0.name).tag(Optional($0.id)) }
    }
  }

  private var advancedFilters: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack { Text("高级筛选").font(.headline); Spacer(); Button("清除") { clearFilters() }.buttonStyle(.plain) }
      Picker("类型", selection: $filterDraft.kind) {
        Text("全部").tag(Optional<TransactionKind>.none)
        ForEach(TransactionKind.allCases) { Text($0.title).tag(Optional($0)) }
      }
      Picker("账户", selection: $filterDraft.accountID) {
        Text("全部").tag(Optional<UUID>.none)
        ForEach(accountOptions) { Text($0.name).tag(Optional($0.id)) }
      }
      Picker("分类", selection: $filterDraft.categoryID) {
        Text("全部").tag(Optional<UUID>.none)
        ForEach(categoryOptions) { Text($0.name).tag(Optional($0.id)) }
      }
      Picker("归类状态", selection: $filterDraft.classification) {
        ForEach(TransactionClassificationFilter.allCases) { Text($0.title).tag($0) }
      }
      Picker("来源", selection: $filterDraft.source) {
        Text("全部").tag(Optional<String>.none)
        Text("手动录入").tag(Optional("manual"))
        Text("AI 文本").tag(Optional("ai_text"))
        Text("截图 OCR").tag(Optional("ocr"))
        Text("系统").tag(Optional("system"))
      }
      Toggle("限制开始日期", isOn: optionalDateEnabled($filterDraft.dateFrom))
      if filterDraft.dateFrom != nil {
        DatePicker("开始日期", selection: optionalDateValue($filterDraft.dateFrom), displayedComponents: .date)
      }
      Toggle("限制结束日期", isOn: optionalDateEnabled($filterDraft.dateTo))
      if filterDraft.dateTo != nil {
        DatePicker("结束日期", selection: optionalDateValue($filterDraft.dateTo), displayedComponents: .date)
      }
      Toggle("包含已作废", isOn: $filterDraft.includeVoided)
      HStack {
        Spacer()
        Button("应用筛选") { showFilters = false; Task { await model.applyFilters(filterDraft) } }
          .buttonStyle(.borderedProminent)
      }
    }
    .padding(18).frame(width: 340)
  }

  private var keyboardActions: some View {
    Group {
      Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
      Button("") { if let item = editableSelectedTransaction { editing = item } }
        .keyboardShortcut("e", modifiers: .command)
      Button("") { Task { _ = await model.undoVoid() } }.keyboardShortcut("z", modifiers: .command)
    }
    .labelsHidden().frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
  }

  private var selectedTransactions: [TransactionDTO] {
    model.transactions.filter { selection.contains($0.id) }
  }
  private var selectedTransaction: TransactionDTO? {
    guard selection.count == 1, let id = selection.first else { return nil }
    return model.transactions.first { $0.id == id }
  }
  private var editableSelectedTransaction: TransactionDTO? {
    guard let item = selectedTransaction, item.isUserEditable, item.installmentPlanID == nil,
          item.voidedAt == nil else { return nil }
    return item
  }
  private var selectedDirection: TransactionKind? {
    let kinds = Set(selectedTransactions.map(\.kind))
    if kinds.isSubset(of: [.expense, .creditPurchase]) { return .expense }
    if kinds == [.income] { return .income }
    return nil
  }
  private var batchCategoryOptions: [CategoryDTO] {
    guard let direction = selectedDirection else { return [] }
    return categoryOptions.filter { $0.archivedAt == nil && $0.direction.rawValue == direction.rawValue && $0.children.isEmpty }
  }
  private var canBatchClassify: Bool {
    !selection.isEmpty && selectedTransactions.count == selection.count
      && selectedTransactions.allSatisfy(\.isUncategorizedInboxItem)
      && batchCategoryID != nil && selectedDirection != nil
  }
  private var batchConfirmationText: String {
    let category = categoryOptions.first { $0.id == batchCategoryID }?.name ?? "所选分类"
    return "将 \(selection.count) 笔待归类流水设为“\(category)”。"
  }
  private var voidAlert: Binding<Bool> {
    Binding(get: { pendingVoid != nil }, set: { if !$0 { pendingVoid = nil } })
  }
  private var conflictAlert: Binding<Bool> {
    Binding(get: { model.conflictDetected }, set: { if !$0 { model.clearConflict() } })
  }

  private func performBatchClassification() {
    guard let categoryID = batchCategoryID, canBatchClassify else { return }
    let items = selectedTransactions.map {
      TransactionBatchClassificationItem(transactionID: $0.id, expectedVersion: $0.version)
    }
    Task {
      if await model.batchClassify(items: items, categoryID: categoryID) {
        selection.removeAll(); batchCategoryID = nil
      }
    }
  }
  private func clearFilters() {
    filterDraft = TransactionsModel.FilterDraft()
    showFilters = false
    Task { await model.applyFilters(filterDraft) }
  }
  private func loadOptions() async {
    optionsError = nil
    do {
      async let loadedAccounts = accounts.transactionOptions()
      async let loadedCategories = categories.transactionOptions()
      accountOptions = try await loadedAccounts
      categoryOptions = try await loadedCategories
      accountNames = Dictionary(uniqueKeysWithValues: accountOptions.map { ($0.id, $0.name) })
      categoryNames = Dictionary(uniqueKeysWithValues: categoryOptions.map { ($0.id, $0.name) })
    } catch is CancellationError {
      return
    } catch {
      optionsError = (error as? FiscalAPIError)?.displayMessage ?? "账户与分类读取失败"
    }
  }
  private func retryState(_ title: String, symbol: String) -> some View {
    ContentUnavailableView { Label(title, systemImage: symbol) } actions: {
      Button("重试") { Task { await model.load() } }
    }
  }
  private func statusBanner(_ message: String) -> some View {
    Label(message, systemImage: "exclamationmark.triangle")
      .font(.caption).foregroundStyle(FiscalColor.expense).padding(7)
      .frame(maxWidth: .infinity).background(FiscalColor.expense.opacity(0.08))
  }
  private func detail(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label).foregroundStyle(FiscalColor.tertiary)
      Spacer(minLength: 8)
      Text(value).fontWeight(.medium).multilineTextAlignment(.trailing)
    }
    .font(.subheadline).padding(.vertical, 9).overlay(alignment: .bottom) { Divider() }
  }
  private func categoryName(_ item: TransactionDTO) -> String {
    item.categoryID.flatMap { categoryNames[$0] } ?? (item.isUncategorizedInboxItem ? "待归类" : "—")
  }
  private func accountName(_ item: TransactionDTO) -> String {
    let source = item.accountID.flatMap { accountNames[$0] } ?? "账户"
    guard item.kind == .transfer,
          let destination = item.destinationAccountID.flatMap({ accountNames[$0] }) else { return source }
    return "\(source) → \(destination)"
  }
  private func amountText(_ item: TransactionDTO) -> Text {
    let prefix = switch item.kind {
    case .income, .installmentRefund, .reimbursementReceipt: "+"
    case .expense, .creditPurchase, .installmentFee: "-"
    case .transfer, .repayment: ""
    }
    return Text(prefix + Money(minorUnits: item.amountMinor).formatted())
  }
  private func sourceName(_ source: String) -> String {
    switch source { case "manual": "手动"; case "ai_text": "AI 文本"; case "ocr": "截图 OCR"; case "system": "系统"; default: source }
  }
  private func kindColor(_ kind: TransactionKind) -> Color {
    switch kind {
    case .expense: FiscalColor.expense
    case .income, .installmentRefund, .reimbursementReceipt: FiscalColor.income
    case .transfer: FiscalColor.accent
    case .creditPurchase, .repayment, .installmentFee: FiscalColor.debt
    }
  }
  private func shortDate(_ value: String) -> String {
    String(value.suffix(5)).replacingOccurrences(of: "-", with: "/")
  }
  private func inspectorReadOnlyReason(_ item: TransactionDTO) -> String {
    if item.voidedAt != nil { return "已作废流水只能通过撤销恢复。" }
    if item.installmentPlanID != nil { return "该流水由分期计划管理。" }
    if !item.isUserEditable { return "系统流水需从对应业务对象中修改。" }
    return "当前流水不可编辑。"
  }
  private func optionalDateEnabled(_ date: Binding<Date?>) -> Binding<Bool> {
    Binding(
      get: { date.wrappedValue != nil },
      set: { enabled in date.wrappedValue = enabled ? (date.wrappedValue ?? Date()) : nil })
  }
  private func optionalDateValue(_ date: Binding<Date?>) -> Binding<Date> {
    Binding(get: { date.wrappedValue ?? Date() }, set: { date.wrappedValue = $0 })
  }
}

private extension TransactionDTO {
  var isUncategorizedInboxItem: Bool {
    voidedAt == nil && categoryID == nil && source != "system" && installmentPlanID == nil
      && reimbursementRelations.isEmpty && [.expense, .income, .creditPurchase].contains(kind)
  }
}
#endif
