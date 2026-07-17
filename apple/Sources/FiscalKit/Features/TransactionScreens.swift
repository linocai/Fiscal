import SwiftUI

private extension TransactionKind {
    var color: Color { switch self { case .expense: FiscalColor.expense; case .income, .installmentRefund, .reimbursementReceipt: FiscalColor.income; case .transfer: FiscalColor.accent; case .creditPurchase, .repayment, .installmentFee: FiscalColor.debt } }
}

private struct TransactionAmount: View {
    let transaction: TransactionDTO
    var body: some View {
        Text(prefix + Money(minorUnits: transaction.amountMinor).formatted())
            .font(.body.weight(.semibold)).foregroundStyle(transaction.kind.color)
    }
    private var prefix: String { switch transaction.kind { case .expense, .creditPurchase, .installmentFee: "-"; case .income, .installmentRefund, .reimbursementReceipt: "+"; case .transfer, .repayment: "" } }
}

public struct TransactionEditorSheet: View {
    private enum FocusedField: Hashable { case amount, title, note }
    @Environment(\.dismiss) private var dismiss
    let transactions: TransactionsModel
    let accounts: AccountsModel
    let categories: CategoriesModel
    let credit: CreditModel?
    let preferences: RecordingPreferences?
    let appliesPreferences: Bool
    @State private var editor: TransactionEditorModel
    @State private var accountOptions: [AccountDTO] = []
    @State private var categoryOptions: [CategoryDTO] = []
    @State private var optionsError: String?
    @State private var loadingOptions = true
    @State private var cycleOptions: [CreditCycleDTO] = []
    @State private var cycleLoadGeneration = 0
    @State private var confirmCycleRecalculation = false
    @State private var savedCycleDescription: String?
    @State private var repaymentValidation: String?
    @State private var referenceValidation: String?
    @FocusState private var focusedField: FocusedField?
    @State private var didApplyPreferences = false

    public init(transactions: TransactionsModel, accounts: AccountsModel, categories: CategoriesModel, credit: CreditModel? = nil, editing: TransactionDTO? = nil, initialKind: TransactionKind? = nil, creditAccountID: UUID? = nil, cycleID: UUID? = nil, amountMinor: Int64? = nil, preferences: RecordingPreferences? = nil) {
        self.transactions = transactions; self.accounts = accounts; self.categories = categories; self.credit = credit; self.preferences = preferences
        appliesPreferences = editing == nil && initialKind == nil && preferences != nil
        let model = TransactionEditorModel(editing: editing)
        if let initialKind { model.changeKind(initialKind) }
        if initialKind == .repayment { model.draft.destinationAccountID = creditAccountID; model.draft.creditCycleID = cycleID }
        if let amountMinor { model.amountText = NSDecimalNumber(decimal: Decimal(amountMinor) / 100).stringValue }
        _editor = State(initialValue: model)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("类型")
                    kindPicker
                    sectionCard("交易") {
                        VStack(spacing: 12) {
                            editorField("金额", symbol: "yensign", prompt: "例如 38.50") {
                                TextField("金额，例如 38.50", text: $editor.amountText)
                                    .focused($focusedField, equals: .amount)
#if os(iOS)
                                    .keyboardType(.decimalPad)
#endif
                            }
                            Divider().opacity(0.35)
                            editorField("标题", symbol: "text.alignleft", prompt: "这笔钱用于什么") {
                                TextField("标题", text: $editor.draft.title)
                                    .focused($focusedField, equals: .title)
                                    .submitLabel(.next)
                                    .onSubmit { focusedField = .note }
                            }
                            Divider().opacity(0.35)
                            editorField("备注", symbol: "note.text", prompt: "可选") {
                                TextField("备注（可选）", text: $editor.draft.note, axis: .vertical)
                                    .lineLimit(2...5).focused($focusedField, equals: .note)
                            }
                            Divider().opacity(0.35)
                            DatePicker("发生时间", selection: $editor.draft.occurredAt)
                        }
                    }
                    classificationSection
                    statusContent
                }
                .padding(16)
            }
            .background(editorBackground)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(editor.editing == nil ? "记一笔" : "编辑流水")
            .accessibilityIdentifier("transaction.editor")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
#if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil }
                }
#endif
            }
            .safeAreaInset(edge: .bottom) { saveBar }
            .task { await loadOptions() }
        }
        .frame(minWidth: 380, idealWidth: 440, minHeight: 520, idealHeight: 620)
        .interactiveDismissDisabled(transactions.isMutating)
        .alert("账期将重新计算", isPresented: $confirmCycleRecalculation) {
            Button("取消", role: .cancel) {}
            Button("继续保存") { performSave() }
        } message: {
            Text("信用账户或发生时间已变化。服务器会重新归属账期，客户端不会自行推算。")
        }
        .alert("信用消费已保存", isPresented: Binding(get: { savedCycleDescription != nil }, set: { if !$0 { savedCycleDescription = nil } })) {
            Button(shouldStayAfterSave ? "继续记账" : "完成") { completeSuccessfulSave() }
        } message: {
            Text("服务器确认的新账期：\(savedCycleDescription ?? "")")
        }
    }

    private var kindPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(editableKinds) { kind in
                    Button {
                        kindBinding.wrappedValue = kind
                    } label: {
                        Label(kind.title, systemImage: kind.symbol)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 13).frame(minHeight: 42)
                            .foregroundStyle(editor.draft.kind == kind ? Color.white : FiscalColor.secondary)
                            .background(editor.draft.kind == kind ? kind.color : FiscalColor.surface, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(editor.draft.kind == kind ? .isSelected : [])
                }
            }
        }.scrollIndicators(.hidden)
    }
    private var editableKinds: [TransactionKind] { [.expense, .income, .transfer, .creditPurchase, .repayment] }
    @ViewBuilder private var classificationSection: some View {
        switch editor.draft.kind {
        case .transfer: transferSection
        case .repayment: repaymentSection
        case .creditPurchase: creditPurchaseSection
        case .expense, .income: incomeExpenseSection
        case .installmentFee, .installmentRefund, .reimbursementReceipt: EmptyView()
        }
    }
    @ViewBuilder private var statusContent: some View {
        if loadingOptions {
            FiscalCard(radius: 16) { ProgressView("正在读取账户与分类…").frame(maxWidth: .infinity) }
        }
        if let optionsError {
            FiscalCard(radius: 16) {
                HStack { Label(optionsError, systemImage: "wifi.exclamationmark").foregroundStyle(FiscalColor.expense); Spacer(); Button("重试") { Task { await loadOptions() } }.buttonStyle(FiscalActionButtonStyle(.secondary)) }
            }
        }
        if let message = referenceValidation ?? repaymentValidation ?? editor.validationMessage ?? transactions.message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline).foregroundStyle(FiscalColor.expense).padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(FiscalColor.expense.opacity(0.09), in: .rect(cornerRadius: 14))
        }
    }
    private var saveBar: some View {
        Button {
            focusedField = nil; requestSave()
        } label: {
            Text(transactions.isMutating ? "保存中…" : (editor.editing == nil ? "保存这笔流水" : "保存修改"))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(FiscalActionButtonStyle())
        .disabled(transactions.isMutating || loadingOptions || optionsError != nil)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial)
        .accessibilityIdentifier("transaction.save")
    }
    private var editorBackground: Color {
#if os(iOS)
        FiscalColor.iOSBackground
#else
        FiscalColor.macBackground
#endif
    }
    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.headline).padding(.horizontal, 3)
    }
    private func sectionCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { sectionTitle(title); FiscalCard(radius: 18) { content() } }
    }
    private func editorField<Content: View>(_ title: String, symbol: String, prompt: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(FiscalColor.accent).frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(FiscalColor.tertiary)
                content().textFieldStyle(.plain)
            }
        }.accessibilityElement(children: .contain)
    }
    private var kindBinding: Binding<TransactionKind> { Binding(get: { editor.draft.kind }, set: { editor.changeKind($0); cycleOptions = []; referenceValidation = nil; repaymentValidation = nil; if $0 == .repayment, let id = editor.draft.destinationAccountID { Task { await loadCycles(id) } } }) }
    private var activeAccounts: [AccountDTO] {
        accountOptions.filter { ($0.archivedAt == nil || linkedAccountIDs.contains($0.id)) && $0.kind != .credit }
    }
    private var linkedAccountIDs: Set<UUID> { Set([editor.editing?.accountID, editor.editing?.destinationAccountID].compactMap { $0 }) }
    private var creditAccounts: [AccountDTO] { accountOptions.filter { ($0.archivedAt == nil || linkedAccountIDs.contains($0.id)) && $0.kind == .credit } }
    private var eligibleCategories: [CategoryDTO] {
        let direction: CategoryDirection = editor.draft.kind == .income ? .income : .expense
        return categoryOptions.filter { $0.direction == direction && ($0.archivedAt == nil || $0.id == editor.editing?.categoryID) }
    }
    private var incomeExpenseSection: some View {
        sectionCard("归类") {
            VStack(spacing: 14) {
            Picker("账户", selection: $editor.draft.accountID) { Text("请选择").tag(Optional<UUID>.none); ForEach(activeAccounts) { Text($0.name).tag(Optional($0.id)) } }
            Divider().opacity(0.35)
            Picker("分类", selection: $editor.draft.categoryID) { Text("请选择").tag(Optional<UUID>.none); ForEach(eligibleCategories) { Text($0.name).tag(Optional($0.id)) } }
            }
        }
    }
    private var transferSection: some View {
        sectionCard("转账账户") {
            VStack(spacing: 14) {
            Picker("转出", selection: $editor.draft.accountID) { Text("请选择").tag(Optional<UUID>.none); ForEach(activeAccounts) { Text($0.name).tag(Optional($0.id)) } }
            Divider().opacity(0.35)
            Picker("转入", selection: $editor.draft.destinationAccountID) { Text("请选择").tag(Optional<UUID>.none); ForEach(activeAccounts) { Text($0.name).tag(Optional($0.id)) } }
            }
        }
    }
    private var creditPurchaseSection: some View {
        sectionCard("信用消费") {
            VStack(alignment: .leading, spacing: 14) {
            Picker("信用账户", selection: $editor.draft.accountID) { Text("请选择").tag(Optional<UUID>.none); ForEach(creditAccounts) { Text($0.name).tag(Optional($0.id)) } }
            Divider().opacity(0.35)
            Picker("支出分类", selection: $editor.draft.categoryID) { Text("请选择").tag(Optional<UUID>.none); ForEach(eligibleCategories) { Text($0.name).tag(Optional($0.id)) } }
            Text("账期由服务器根据发生日期自动归属。若编辑后账期变化，保存结果会显示新的账期。").font(.caption).foregroundStyle(FiscalColor.tertiary)
            }
        }
    }
    private var repaymentSection: some View {
        sectionCard("还款") {
            VStack(alignment: .leading, spacing: 14) {
            Picker("付款账户", selection: $editor.draft.accountID) { Text("请选择").tag(Optional<UUID>.none); ForEach(activeAccounts) { Text($0.name).tag(Optional($0.id)) } }
            Divider().opacity(0.35)
            Picker("信用账户", selection: $editor.draft.destinationAccountID) { Text("请选择").tag(Optional<UUID>.none); ForEach(creditAccounts) { Text($0.name).tag(Optional($0.id)) } }
                .onChange(of: editor.draft.destinationAccountID) { _, id in
                    cycleLoadGeneration += 1; editor.draft.creditCycleID = nil; cycleOptions = []
                    if let id { Task { await loadCycles(id) } }
                }
            VStack(alignment: .leading, spacing: 8) {
                Text("目标账期")
                    .font(.subheadline)
                Menu {
                    Button("请选择") { editor.draft.creditCycleID = nil }
                    ForEach(cycleOptions) { cycle in
                        Button(cycleMenuLabel(cycle)) { editor.draft.creditCycleID = cycle.id }
                    }
                } label: {
                    HStack(spacing: 12) {
                        if let cycle = selectedRepaymentCycle {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(cyclePrimaryLabel(cycle))
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text("到期 \(cycle.dueDate) · 可还 \(Money(minorUnits: editableCapacity(cycle)).formatted())")
                                    .font(.caption)
                                    .foregroundStyle(FiscalColor.secondary)
                            }
                        } else {
                            Text("请选择")
                                .foregroundStyle(FiscalColor.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FiscalColor.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("目标账期")
                .accessibilityValue(selectedRepaymentCycle.map(cycleMenuLabel) ?? "请选择")
            }
            Text("一笔还款只偿还一个账期，不会自动跨账期分配。").font(.caption).foregroundStyle(FiscalColor.tertiary)
            }
        }
    }
    private func requestSave() {
        guard editor.prepare() else { referenceValidation = nil; return }
        if let referenceError = TransactionEditorModel.validateReferences(
            editor.draft, accounts: accountOptions, categories: categoryOptions) {
            referenceValidation = referenceError
            return
        }
        referenceValidation = nil
        if let editing = editor.editing,
           editing.kind == .creditPurchase,
           editor.draft.kind == .creditPurchase,
           (editing.accountID != editor.draft.accountID || editing.occurredAt != editor.draft.occurredAt) {
            confirmCycleRecalculation = true
            return
        }
        performSave()
    }
    private func performSave() {
        if editor.draft.kind == .repayment, let cycleID = editor.draft.creditCycleID {
            // The over-limit check must never be skipped just because the chosen cycle isn't in the
            // loaded options (e.g. a pre-selected settled cycle on the new-repayment path).
            guard let cycle = cycleOptions.first(where: { $0.id == cycleID }) else {
                repaymentValidation = "所选账期当前不可用，请重新选择目标账期。"
                return
            }
            if editor.draft.amountMinor > editableCapacity(cycle) {
                repaymentValidation = "还款金额不能超过本次可编辑额度 \(Money(minorUnits: editableCapacity(cycle)).formatted())。"
                return
            }
        }
        repaymentValidation = nil
        Task {
            let succeeded = await transactions.save(draft: editor.draft, editing: editor.editing, idempotencyKey: editor.idempotencyKey)
            if succeeded, editor.draft.kind == .creditPurchase,
               let cycleID = transactions.lastSavedTransaction?.creditCycleID {
                if let cycle = try? await credit?.cycleSummary(id: cycleID) {
                    savedCycleDescription = "\(cycle.periodStart)–\(cycle.periodEnd)（账单日 \(cycle.statementDate)）"
                } else {
                    savedCycleDescription = cycleID.uuidString
                }
            } else if succeeded { completeSuccessfulSave() }
            else if transactions.shouldRotateCreateKeyAfterFailure { editor.rotateCreateKey() }
        }
    }
    private func loadOptions() async {
        loadingOptions = true; optionsError = nil
        defer { loadingOptions = false }
        // Preferences seed the draft only on the first load attempt. Marking this before the fetch
        // means a later "重试" (after a failed first load) can no longer overwrite a kind/account the
        // user picked in the meantime.
        let shouldApplyPreferences = appliesPreferences && !didApplyPreferences
        didApplyPreferences = true
        do {
            async let loadedAccounts = accounts.transactionOptions()
            async let loadedCategories = categories.transactionOptions()
            accountOptions = try await loadedAccounts; categoryOptions = try await loadedCategories
            if shouldApplyPreferences, let preferences {
                editor.apply(preferences: preferences, accounts: accountOptions)
            }
            if editor.draft.kind == .repayment, let id = editor.draft.destinationAccountID { await loadCycles(id) }
        } catch is CancellationError {
            optionsError = "读取已取消，请重试"
            return
        }
        catch { optionsError = (error as? FiscalAPIError)?.displayMessage ?? error.localizedDescription }
    }
    private func loadCycles(_ accountID: UUID) async {
        guard let credit else { optionsError = "信用账期服务未配置。"; return }
        cycleLoadGeneration += 1; let requestGeneration = cycleLoadGeneration
        let retainedCycle = editor.editing?.kind == .repayment && editor.editing?.destinationAccountID == accountID ? editor.editing?.creditCycleID : nil
        optionsError = nil
        do {
            let loaded = try await credit.cyclesForRepayment(accountID: accountID, retaining: retainedCycle)
            guard requestGeneration == cycleLoadGeneration, editor.draft.destinationAccountID == accountID, !Task.isCancelled else { return }
            cycleOptions = loaded
        }
        catch is CancellationError {} catch {
            guard requestGeneration == cycleLoadGeneration, editor.draft.destinationAccountID == accountID else { return }
            optionsError = (error as? FiscalAPIError)?.displayMessage ?? error.localizedDescription
        }
    }
    private func editableCapacity(_ cycle: CreditCycleDTO) -> Int64 {
        guard let editing = editor.editing, editing.kind == .repayment, editing.creditCycleID == cycle.id else { return cycle.remainingMinor }
        let (capacity, overflow) = cycle.remainingMinor.addingReportingOverflow(editing.amountMinor)
        return overflow ? Int64.max : capacity
    }
    private var selectedRepaymentCycle: CreditCycleDTO? {
        guard let id = editor.draft.creditCycleID else { return nil }
        return cycleOptions.first { $0.id == id }
    }
    private func cyclePrimaryLabel(_ cycle: CreditCycleDTO) -> String {
        cycle.isOpeningCycle ? "期初欠款 · 余额日期 \(cycle.statementDate)" : "\(cycle.periodStart)–\(cycle.periodEnd)"
    }
    private func cycleMenuLabel(_ cycle: CreditCycleDTO) -> String {
        "\(cyclePrimaryLabel(cycle))，到期 \(cycle.dueDate)，可还 \(Money(minorUnits: editableCapacity(cycle)).formatted())"
    }
    private var shouldStayAfterSave: Bool { editor.editing == nil && preferences?.stayAfterSave == true }
    private func completeSuccessfulSave() {
        savedCycleDescription = nil
        guard shouldStayAfterSave else { dismiss(); return }
        editor.resetForNextEntry(validAccounts: accountOptions)
        cycleOptions = []
        repaymentValidation = nil
        referenceValidation = nil
        transactions.clearMessage()
        focusedField = .amount
    }
}

#if os(iOS)
public struct IOSTransactionsScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable var model: TransactionsModel
    let accounts: AccountsModel
    let categories: CategoriesModel
    let credit: CreditModel?
    let installments: InstallmentModel?
    @State private var editing: TransactionDTO?
    @State private var pendingVoid: TransactionDTO?
    @State private var installmentPurchase: TransactionDTO?
    @State private var showAdvancedFilters = false
    @State private var isSelecting = false
    @State private var selectedIDs = Set<UUID>()
    @State private var showBatchClassification = false
    @State private var batchCategoryID: UUID?
    @State private var accountOptions: [AccountDTO] = []
    @State private var categoryOptions: [CategoryDTO] = []
    @State private var filterOptionsMessage: String?
    @State private var amountMinimumText = ""
    @State private var amountMaximumText = ""
    @State private var filterDraft = TransactionsModel.FilterDraft()

    public init(model: TransactionsModel, accounts: AccountsModel, categories: CategoriesModel, credit: CreditModel? = nil, installments: InstallmentModel? = nil) { self.model = model; self.accounts = accounts; self.categories = categories; self.credit = credit; self.installments = installments }
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
            prompt: "搜索标题、备注、账户或分类"
        )
        .onChange(of: model.search) { _, _ in model.scheduleLoad() }
        .onChange(of: model.transactions.map(\.id)) { _, _ in
            // Converge the batch selection onto rows that are still visible and classifiable, so the
            // "已选 N 笔" count can't stay inflated after a refresh (matching the mac workbench).
            selectedIDs.formIntersection(Set(model.transactions.filter(isBatchClassifiable).map(\.id)))
        }
        .task {
            if model.phase == .idle { await model.load() }
            await loadFilterOptions()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.classification == .uncategorized && model.phase == .loaded {
                    Button(isSelecting ? "完成" : "选择") {
                        isSelecting.toggle()
                        if !isSelecting { selectedIDs.removeAll() }
                    }
                }
                Button { prepareAdvancedFilters(); showAdvancedFilters = true } label: {
                    Label("高级筛选", systemImage: hasAdvancedSheetFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
            }
        }
        .sheet(item: $editing) { TransactionEditorSheet(transactions: model, accounts: accounts, categories: categories, credit: credit, editing: $0) }
        .sheet(item: $installmentPurchase) { if let installments { InstallmentCreateSheet(installments: installments, purchase: $0, categories: categories) } }
        .sheet(isPresented: $showAdvancedFilters) { advancedFilterSheet }
        .sheet(isPresented: $showBatchClassification) { batchClassificationSheet }
        .alert("作废这笔流水？", isPresented: Binding(get: { pendingVoid != nil }, set: { if !$0 { pendingVoid = nil } })) {
            Button("取消", role: .cancel) { pendingVoid = nil }
            Button("作废", role: .destructive) { if let item = pendingVoid { Task { _ = await model.void(item); pendingVoid = nil } } }
        } message: { Text("作废后余额会立即重算，可通过页面底部的撤销恢复。") }
        .alert("数据已变化", isPresented: Binding(get: { model.conflictDetected }, set: { if !$0 { model.clearConflict() } })) {
            Button("重新加载") { Task { await model.load() } }; Button("取消", role: .cancel) { model.clearConflict() }
        } message: { Text("服务器上的版本更高，请重新加载后再编辑。") }
        .safeAreaInset(edge: .bottom) {
            if isSelecting && !selectedIDs.isEmpty { selectionBar }
            else if model.undoTransaction != nil { undoBar }
        }
    }
    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack {
                chip("全部", nil)
                classificationChip
                ForEach(TransactionKind.allCases) { chip($0.title, $0) }
            }.padding(.horizontal, 16).padding(.vertical, 8)
        }.scrollIndicators(.hidden)
    }
    private var classificationChip: some View {
        Button {
            model.classification = model.classification == .uncategorized ? .all : .uncategorized
            isSelecting = false; selectedIDs.removeAll()
            Task { await model.load() }
        } label: {
            Label("待归类", systemImage: "questionmark.circle")
                .font(.subheadline.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 8)
                .background(model.classification == .uncategorized ? FiscalColor.debt : FiscalColor.surface, in: .capsule)
                .foregroundStyle(model.classification == .uncategorized ? .white : FiscalColor.secondary)
        }.buttonStyle(.plain).accessibilityAddTraits(model.classification == .uncategorized ? .isSelected : [])
    }
    private func chip(_ title: String, _ kind: TransactionKind?) -> some View {
        Button { model.kind = kind; Task { await model.load() } } label: { Text(title).font(.subheadline.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 8).background(model.kind == kind ? FiscalColor.accent : FiscalColor.surface, in: .capsule).foregroundStyle(model.kind == kind ? .white : FiscalColor.secondary) }.buttonStyle(.plain)
            .accessibilityAddTraits(model.kind == kind ? .isSelected : [])
    }
    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .loading: ProgressView("正在读取流水…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty: ContentUnavailableView(model.search.isEmpty && model.kind == nil ? "还没有流水" : "没有匹配的流水", systemImage: "list.bullet.rectangle", description: Text("使用底部中央按钮记录收入、支出、转账或信用交易。"))
        case .unauthorized: retry("设备密钥无效", "key")
        case .offline: retry("无法连接个人 VPS", "wifi.slash")
        case .failed: retry(model.message ?? "读取失败", "exclamationmark.triangle")
        case .loaded:
            ScrollView { LazyVStack(alignment: .leading, spacing: 12) { ForEach(model.groups) { group in Text(group.title).font(.headline).padding(.horizontal, 4); FiscalCard(radius: 18) { VStack(spacing: 0) { ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in if index > 0 { Divider() }; row(item) } } } } }.padding(16) }.refreshable { await model.load() }
        }
    }
    private func row(_ item: TransactionDTO) -> some View {
        Button {
            if isSelecting {
                if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
                else if isBatchClassifiable(item) { selectedIDs.insert(item.id) }
            } else if isRowEditable(item) { editing = item }
        } label: { transactionRowContent(item).contentShape(.rect).padding(.vertical, 6) }
            .buttonStyle(.plain)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(item.title)，\(item.kind.title)")
            .accessibilityValue("\(Money(minorUnits: item.amountMinor).formatted())，\(detail(item))")
            .accessibilityHint(isSelecting ? (isBatchClassifiable(item) ? "轻点选择或取消选择" : "该流水不可批量分类") : (isRowEditable(item) ? "轻点编辑；更多操作可作废" : "只读流水"))
            .accessibilityIdentifier(isBatchClassifiable(item) ? "transaction.classifiableRow" : "transaction.row")
            .task { await model.loadMoreIfNeeded(after: item) }
    }
    @ViewBuilder private func transactionRowContent(_ item: TransactionDTO) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            HStack(alignment: .top, spacing: 12) {
                selectionIndicator(item)
                FiscalIconTile(item.kind.symbol, color: item.kind.color).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.headline).foregroundStyle(FiscalColor.text)
                    Text(detail(item)).font(.caption).foregroundStyle(FiscalColor.tertiary)
                    HStack {
                        TransactionAmount(transaction: item).fixedSize()
                        Spacer()
                        rowMenu(item)
                    }
                }
            }
        } else {
            HStack(spacing: 12) {
                selectionIndicator(item)
                FiscalIconTile(item.kind.symbol, color: item.kind.color).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.headline).foregroundStyle(FiscalColor.text)
                    Text(detail(item)).font(.caption).foregroundStyle(FiscalColor.tertiary).lineLimit(1)
                }
                Spacer()
                TransactionAmount(transaction: item)
                rowMenu(item)
            }
        }
    }
    @ViewBuilder private func selectionIndicator(_ item: TransactionDTO) -> some View {
        if isSelecting {
            Image(systemName: selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selectedIDs.contains(item.id) ? FiscalColor.accent : FiscalColor.tertiary)
                .font(.title3).accessibilityHidden(true)
        }
    }
    @ViewBuilder private func rowMenu(_ item: TransactionDTO) -> some View {
        if !isSelecting {
            Menu {
                if item.kind == .creditPurchase && item.installmentPlanID == nil && item.voidedAt == nil {
                    Button("创建分期计划", systemImage: "calendar.badge.plus") { installmentPurchase = item }
                }
                if isRowEditable(item) {
                    Button("编辑", systemImage: "pencil") { editing = item }
                    Button("作废", systemImage: "trash", role: .destructive) { pendingVoid = item }
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 32, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("transaction.rowMenu")
        }
    }
    private func detail(_ item: TransactionDTO) -> String { [item.kind.title, item.installmentRelation.map { "分期 · \($0.planTitle)" }, item.note].compactMap { $0 }.joined(separator: " · ") }
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transaction.undoBar")
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("已选择 \(selectedIDs.count) 笔").font(.subheadline.weight(.semibold))
            Spacer()
            Button("取消") { selectedIDs.removeAll(); isSelecting = false }
            Button("重新分类") { showBatchClassification = true }
                .buttonStyle(FiscalActionButtonStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 10).background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transactions.batchBar")
    }

    private var advancedFilterSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sectionCard("归类与来源") {
                        VStack(spacing: 13) {
                            Picker("归类状态", selection: $filterDraft.classification) {
                                ForEach(TransactionClassificationFilter.allCases) { Text($0.title).tag($0) }
                            }
                            Divider().opacity(0.35)
                            Picker("来源", selection: $filterDraft.source) {
                                Text("全部").tag(Optional<String>.none)
                                Text("手动录入").tag(Optional("manual"))
                                Text("AI 文本").tag(Optional("ai_text"))
                                Text("截图 OCR").tag(Optional("ocr"))
                                Text("系统").tag(Optional("system"))
                            }
                        }
                    }
                    sectionCard("账户与分类") {
                        VStack(spacing: 13) {
                            Picker("账户", selection: $filterDraft.accountID) {
                                Text("全部").tag(Optional<UUID>.none)
                                ForEach(accountOptions) { Text($0.name).tag(Optional($0.id)) }
                            }
                            Divider().opacity(0.35)
                            Picker("分类", selection: $filterDraft.categoryID) {
                                Text("全部").tag(Optional<UUID>.none)
                                ForEach(categoryOptions) { Text($0.name).tag(Optional($0.id)) }
                            }
                        }
                    }
                    sectionCard("金额范围") {
                        VStack(spacing: 13) {
                            HStack {
                                Text("最低金额")
                                Spacer()
                                TextField("不限", text: $amountMinimumText)
                                    .multilineTextAlignment(.trailing)
                                    .keyboardType(.decimalPad)
                            }
                            Divider().opacity(0.35)
                            HStack {
                                Text("最高金额")
                                Spacer()
                                TextField("不限", text: $amountMaximumText)
                                    .multilineTextAlignment(.trailing)
                                    .keyboardType(.decimalPad)
                            }
                            Text("按人民币金额筛选，最多两位小数。")
                                .font(.caption).foregroundStyle(FiscalColor.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    sectionCard("日期与状态") {
                        VStack(spacing: 13) {
                            Toggle("限制开始日期", isOn: draftDateToggle(\.dateFrom))
                            if filterDraft.dateFrom != nil { DatePicker("开始日期", selection: draftRequiredDate(\.dateFrom), displayedComponents: .date) }
                            Divider().opacity(0.35)
                            Toggle("限制结束日期", isOn: draftDateToggle(\.dateTo))
                            if filterDraft.dateTo != nil { DatePicker("结束日期", selection: draftRequiredDate(\.dateTo), displayedComponents: .date) }
                            Divider().opacity(0.35)
                            Toggle("包含已作废", isOn: $filterDraft.includeVoided)
                        }
                    }
                    if let filterOptionsMessage {
                        Label(filterOptionsMessage, systemImage: "wifi.exclamationmark")
                            .font(.caption).foregroundStyle(FiscalColor.expense)
                    }
                }.padding(16)
            }.background(FiscalColor.iOSBackground).navigationTitle("高级筛选")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("清除") { clearAdvancedFilters() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("应用") { applyAdvancedFilters() }
                    }
                }
        }
    }

    private var batchClassificationSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    FiscalCard(radius: 18) {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("原子批量操作", systemImage: "checkmark.shield")
                                .font(.headline).foregroundStyle(FiscalColor.accent)
                            Text("\(selectedIDs.count) 笔流水会一次提交；任意一笔版本变化时，整批都不会写入。")
                                .font(.subheadline).foregroundStyle(FiscalColor.secondary)
                        }
                    }
                    sectionCard("目标分类") {
                        Picker("目标分类", selection: $batchCategoryID) {
                            Text("请选择").tag(Optional<UUID>.none)
                            ForEach(batchCategoryOptions) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    if batchDirection == nil {
                        Label("收入和支出不能在同一批次归入一个分类。", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(FiscalColor.expense)
                    }
                    if let message = model.message {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline).foregroundStyle(FiscalColor.expense).padding(13)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(FiscalColor.expense.opacity(0.09), in: .rect(cornerRadius: 14))
                    }
                }.padding(16)
            }.background(FiscalColor.iOSBackground).navigationTitle("批量重新分类")
                .safeAreaInset(edge: .bottom) {
                    Button(model.isMutating ? "提交中…" : "确认重新分类") { performBatchClassification() }
                        .buttonStyle(FiscalActionButtonStyle()).disabled(batchCategoryID == nil || batchDirection == nil || model.isMutating)
                        .frame(maxWidth: .infinity).padding(16).background(.regularMaterial)
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { showBatchClassification = false } } }
        }
    }

    private func sectionCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.headline).padding(.horizontal, 3); FiscalCard(radius: 18) { content() } }
    }
    /// The advanced-filter toolbar icon reflects only the fields the sheet controls; kind lives in
    /// the top chips, so it must not light the advanced indicator (L11).
    private var hasAdvancedSheetFilters: Bool {
        model.accountID != nil || model.categoryID != nil || model.classification != .all
            || model.source != nil || model.includeVoided
            || model.dateFrom != nil || model.dateTo != nil
            || model.amountMinMinor != nil || model.amountMaxMinor != nil
    }
    private func draftDateToggle(_ keyPath: WritableKeyPath<TransactionsModel.FilterDraft, Date?>) -> Binding<Bool> {
        Binding(get: { filterDraft[keyPath: keyPath] != nil }, set: { filterDraft[keyPath: keyPath] = $0 ? .now : nil })
    }
    private func draftRequiredDate(_ keyPath: WritableKeyPath<TransactionsModel.FilterDraft, Date?>) -> Binding<Date> {
        Binding(get: { filterDraft[keyPath: keyPath] ?? .now }, set: { filterDraft[keyPath: keyPath] = $0 })
    }
    private func clearAdvancedFilters() {
        // Clearing resets every filter (including the kind chip) and reloads, rather than leaving a
        // half-cleared, un-applied state (L11).
        filterDraft = TransactionsModel.FilterDraft()
        amountMinimumText = ""; amountMaximumText = ""; filterOptionsMessage = nil
        showAdvancedFilters = false
        Task { await model.applyFilters(filterDraft) }
    }
    private func prepareAdvancedFilters() {
        filterDraft = model.currentFilterDraft()
        amountMinimumText = model.amountMinMinor.map(Self.majorAmount) ?? ""
        amountMaximumText = model.amountMaxMinor.map(Self.majorAmount) ?? ""
        filterOptionsMessage = nil
    }
    private func applyAdvancedFilters() {
        let minimum = parsedFilterAmount(amountMinimumText)
        let maximum = parsedFilterAmount(amountMaximumText)
        if (!amountMinimumText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && minimum == nil)
            || (!amountMaximumText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && maximum == nil) {
            filterOptionsMessage = "金额必须大于 0，且最多包含两位小数。"
            return
        }
        if let minimum, let maximum, minimum > maximum {
            filterOptionsMessage = "最低金额不能高于最高金额。"
            return
        }
        // kind is not part of this sheet; currentFilterDraft() seeded it, so it is preserved.
        filterDraft.amountMinMinor = minimum; filterDraft.amountMaxMinor = maximum
        filterOptionsMessage = nil; showAdvancedFilters = false
        Task { await model.applyFilters(filterDraft) }
    }
    private func parsedFilterAmount(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = CNYAmountParser.minorUnits(trimmed), value > 0 else { return nil }
        return value
    }
    private static func majorAmount(_ minor: Int64) -> String {
        NSDecimalNumber(decimal: Decimal(minor) / 100).stringValue
    }
    private func loadFilterOptions() async {
        do {
            async let loadedAccounts = accounts.transactionOptions()
            async let loadedCategories = categories.transactionOptions()
            accountOptions = try await loadedAccounts
            categoryOptions = try await loadedCategories
        } catch is CancellationError { return }
        catch { filterOptionsMessage = (error as? FiscalAPIError)?.displayMessage ?? error.localizedDescription }
    }
    private func isBatchClassifiable(_ item: TransactionDTO) -> Bool {
        item.voidedAt == nil && item.categoryID == nil && item.source != "system"
            && item.installmentPlanID == nil && item.reimbursementRelations.isEmpty
            && [.expense, .income, .creditPurchase].contains(item.kind)
    }
    /// A voided row can only be restored through undo, so it is not editable here — matching the
    /// mac workbench, which already guards voidedAt.
    private func isRowEditable(_ item: TransactionDTO) -> Bool {
        item.isUserEditable && item.installmentPlanID == nil && item.voidedAt == nil
    }
    private var selectedTransactions: [TransactionDTO] { model.transactions.filter { selectedIDs.contains($0.id) } }
    private var batchDirection: CategoryDirection? {
        let kinds = Set(selectedTransactions.map(\.kind))
        if kinds == [.income] { return .income }
        if kinds.isSubset(of: [.expense, .creditPurchase]) { return .expense }
        return nil
    }
    private var batchCategoryOptions: [CategoryDTO] {
        guard let batchDirection else { return [] }
        return categoryOptions.filter { $0.archivedAt == nil && $0.direction == batchDirection && $0.children.isEmpty }
    }
    private func performBatchClassification() {
        guard let batchCategoryID else { return }
        let items = selectedTransactions.map { TransactionBatchClassificationItem(transactionID: $0.id, expectedVersion: $0.version) }
        Task {
            if await model.batchClassify(items: items, categoryID: batchCategoryID) {
                selectedIDs.removeAll(); isSelecting = false; self.batchCategoryID = nil
                showBatchClassification = false
            }
        }
    }
}
#endif
