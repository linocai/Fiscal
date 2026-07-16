import SwiftUI

public struct IOSAIProposalSheet: View {
  @Bindable var model: AIProposalModel
  let accounts: AccountsModel
  let categories: CategoriesModel
  let credit: CreditModel?
  @Environment(\.dismiss) private var dismiss
  @State private var editing: AIProposalDTO?
  @State private var showTextEntry = false

  public init(model: AIProposalModel, accounts: AccountsModel, categories: CategoriesModel, credit: CreditModel? = nil) {
    self.model = model; self.accounts = accounts; self.categories = categories; self.credit = credit
  }
  public var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(spacing: 12) {
          statusPicker
          notice
          if model.phase == .loading && model.proposals.isEmpty {
            ProgressView("正在读取待确认提案…").padding(60)
          } else if model.proposals.isEmpty {
            ContentUnavailableView(emptyTitle, systemImage: "sparkles", description: Text(emptyDescription))
              .padding(.top, 70)
          } else {
            ForEach(model.proposals) { proposal in
              IOSAIProposalRow(
                proposal: proposal, accountName: accountName(proposal.accountID),
                categoryName: categoryName(proposal.categoryID),
                edit: { editing = proposal }, execute: { Task { await model.execute(proposal) } },
                ignore: { Task { await model.ignore(proposal) } },
                retry: { Task { await model.retry(proposal) } },
                undo: { Task { await model.undo(proposal) } })
                .task { if proposal.id == model.proposals.last?.id { await model.loadMore() } }
            }
          }
        }.padding(16).padding(.bottom, 24)
      }
      .background(FiscalColor.iOSBackground)
      .navigationTitle("AI 待确认")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.buttonStyle(.plain) }
        ToolbarItem(placement: .primaryAction) {
          Button { showTextEntry = true } label: { Label("文本记账", systemImage: "plus") }
            .buttonStyle(.plain).foregroundStyle(FiscalColor.accent)
        }
      }
      .refreshable { await model.load() }
      .task {
        async let proposalLoad: Void = model.phase == .idle ? model.load() : ()
        async let accountLoad: Void = accounts.accounts.isEmpty ? accounts.load() : ()
        async let categoryLoad: Void = categories.categories.isEmpty ? categories.load() : ()
        _ = await (proposalLoad, accountLoad, categoryLoad)
      }
      .sheet(item: $editing) { proposal in
        AIProposalEditorScreen(model: model, proposal: proposal, accounts: accounts, categories: categories, credit: credit)
      }
      .sheet(isPresented: $showTextEntry) { AITextEntrySheet(model: model) }
    }
    .presentationDetents([.large])
  }
  private var statusPicker: some View {
    Picker("提案状态", selection: Binding(
      get: { model.statusFilter ?? .pending },
      set: { status in Task { await model.selectStatus(status) } }
    )) {
      Text("待确认").tag(AIProposalStatus.pending)
      Text("失败").tag(AIProposalStatus.failed)
    }
    .pickerStyle(.segmented)
    .accessibilityIdentifier("ai.statusFilter")
  }
  private var emptyTitle: String { model.statusFilter == .failed ? "没有失败提案" : "没有待确认提案" }
  private var emptyDescription: String {
    model.statusFilter == .failed ? "解析失败的文本会保留在这里，可随时重试。" : "AI 无法安全自动记账的内容会出现在这里。"
  }
  @ViewBuilder private var notice: some View {
    if let text = model.refreshMessage ?? model.message {
      Label(text, systemImage: "exclamationmark.triangle.fill").font(.caption)
        .foregroundStyle(FiscalColor.expense).frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(FiscalColor.expense.opacity(0.08), in: .rect(cornerRadius: 12))
    }
  }
  private func accountName(_ id: UUID?) -> String {
    guard let id else { return "未匹配账户" }
    return accounts.accounts.first { $0.id == id }?.name ?? "账户 \(id.uuidString.prefix(6))"
  }
  private func categoryName(_ id: UUID?) -> String {
    guard let id else { return "未匹配分类" }
    return categories.flattened.first { $0.id == id }?.name ?? "分类 \(id.uuidString.prefix(6))"
  }
}

private struct IOSAIProposalRow: View {
  let proposal: AIProposalDTO
  let accountName: String
  let categoryName: String
  let edit: () -> Void
  let execute: () -> Void
  let ignore: () -> Void
  let retry: () -> Void
  let undo: () -> Void
  var body: some View {
    FiscalCard(radius: 19) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
          Text("文本").font(.caption2.bold()).foregroundStyle(FiscalColor.accent)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(FiscalColor.accent.opacity(0.09), in: .capsule)
          Text("置信度 \(proposal.confidenceTitle)").font(.caption).foregroundStyle(FiscalColor.secondary)
          Spacer(); Text(proposal.status.title).font(.caption.weight(.semibold)).foregroundStyle(statusColor)
        }
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 4) {
            Text(proposal.title ?? "等待补全标题").font(.headline).lineLimit(2)
            Text("\(proposal.kind?.title ?? "类型待确认") · \(categoryName) · \(accountName)")
              .font(.caption).foregroundStyle(FiscalColor.tertiary).lineLimit(2)
          }
          Spacer()
          Text(proposal.amountMinor.map { Money(minorUnits: $0).formatted() } ?? "金额待确认")
            .font(.headline.monospacedDigit()).foregroundStyle(FiscalColor.text)
        }
        if !proposal.reviewWarnings.isEmpty {
          Label("需要检查：\(proposal.reviewWarnings.joined(separator: "、"))", systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(FiscalColor.debt).fixedSize(horizontal: false, vertical: true)
        } else if let explanation = proposal.explanation, !explanation.isEmpty {
          Text(explanation).font(.caption).foregroundStyle(FiscalColor.secondary)
        }
        if proposal.canReview {
          HStack(spacing: 8) {
            Button("确认记账", action: execute).buttonStyle(FiscalActionButtonStyle())
            Button("编辑", action: edit).buttonStyle(FiscalActionButtonStyle(.secondary))
            Button("忽略", action: ignore).buttonStyle(.plain).font(.subheadline.weight(.semibold)).foregroundStyle(FiscalColor.tertiary).frame(minHeight: 42)
          }.disabled(proposal.status != .pending)
        } else if proposal.status == .failed {
          Button("重新识别", action: retry).buttonStyle(FiscalActionButtonStyle(.secondary))
        } else if proposal.status == .executed {
          Button("撤销这笔 AI 记账", action: undo).buttonStyle(FiscalActionButtonStyle(.secondary))
        }
      }
    }.accessibilityIdentifier("ai.proposal.\(proposal.id.uuidString)")
  }
  private var statusColor: Color {
    switch proposal.status { case .pending, .processing: FiscalColor.debt; case .failed: FiscalColor.expense; case .executed: FiscalColor.income; default: FiscalColor.tertiary }
  }
}

public struct AIProposalEditorScreen: View {
  @Bindable var model: AIProposalModel
  let proposal: AIProposalDTO
  let accounts: AccountsModel
  let categories: CategoriesModel
  let credit: CreditModel?
  @Environment(\.dismiss) private var dismiss
  @State private var draft: TransactionDraft
  @State private var amountText: String
  @State private var cycleOptions: [CreditCycleDTO] = []
  @State private var cycleError: String?
  @State private var cycleGeneration = 0

  public init(model: AIProposalModel, proposal: AIProposalDTO, accounts: AccountsModel, categories: CategoriesModel, credit: CreditModel? = nil) {
    self.model = model; self.proposal = proposal; self.accounts = accounts; self.categories = categories; self.credit = credit
    _draft = State(initialValue: proposal.draft)
    _amountText = State(initialValue: proposal.amountMinor.map { NSDecimalNumber(decimal: Decimal($0) / 100).stringValue } ?? "")
  }
  public var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 12) {
          FiscalCard(radius: 18) {
            VStack(spacing: 14) {
              Picker("类型", selection: kindBinding) { ForEach(TransactionKind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) } }
                .pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
              TextField("标题", text: $draft.title).textFieldStyle(.plain).padding(12).background(FiscalColor.iOSBackground, in: .rect(cornerRadius: 10))
              TextField("金额（元）", text: $amountText).textFieldStyle(.plain).padding(12).background(FiscalColor.iOSBackground, in: .rect(cornerRadius: 10))
              DatePicker("发生时间", selection: $draft.occurredAt)
              accountFields
              TextField("备注", text: $draft.note, axis: .vertical).textFieldStyle(.plain).padding(12).background(FiscalColor.iOSBackground, in: .rect(cornerRadius: 10))
              if let cycleError { Label(cycleError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(FiscalColor.expense) }
            }
          }
          if let message = model.message { Text(message).font(.caption).foregroundStyle(FiscalColor.expense).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(16)
      }.background(FiscalColor.iOSBackground).navigationTitle("编辑 AI 提案")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.buttonStyle(.plain) }
          ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.buttonStyle(.plain).fontWeight(.semibold).disabled(model.isMutating) }
        }
    }.task { if draft.kind == .repayment, let id = draft.destinationAccountID { await loadCycles(id) } }
  }
  private var kindBinding: Binding<TransactionKind> { Binding(get: { draft.kind }, set: { kind in
    draft.kind = kind; draft.categoryID = nil; draft.destinationAccountID = nil; draft.creditCycleID = nil; cycleOptions = []; cycleError = nil
  }) }
  private var activeAccounts: [AccountDTO] { accounts.accounts.filter { $0.archivedAt == nil && $0.kind != .credit } }
  private var creditAccounts: [AccountDTO] { accounts.accounts.filter { $0.archivedAt == nil && $0.kind == .credit } }
  private var expenseCategories: [CategoryDTO] { categories.flattened.filter { $0.archivedAt == nil && $0.direction == .expense } }
  private var directionalCategories: [CategoryDTO] { categories.flattened.filter { $0.archivedAt == nil && $0.direction.rawValue == draft.kind.rawValue } }
  @ViewBuilder private var accountFields: some View {
    switch draft.kind {
    case .expense, .income:
      accountPicker("账户", selection: $draft.accountID, values: activeAccounts)
      categoryPicker("分类", values: directionalCategories)
    case .transfer:
      accountPicker("转出账户", selection: $draft.accountID, values: activeAccounts)
      accountPicker("转入账户", selection: $draft.destinationAccountID, values: activeAccounts)
    case .creditPurchase:
      accountPicker("信用账户", selection: $draft.accountID, values: creditAccounts)
      categoryPicker("支出分类", values: expenseCategories)
      Text("账期由服务器按发生时间确定。").font(.caption).foregroundStyle(FiscalColor.tertiary)
    case .repayment:
      accountPicker("付款账户", selection: $draft.accountID, values: activeAccounts)
      accountPicker("信用账户", selection: Binding(get: { draft.destinationAccountID }, set: { id in
        draft.destinationAccountID = id; draft.creditCycleID = nil; cycleOptions = []; if let id { Task { await loadCycles(id) } }
      }), values: creditAccounts)
      Picker("目标账期", selection: $draft.creditCycleID) { Text("请选择").tag(Optional<UUID>.none); ForEach(cycleOptions) { Text("\($0.periodStart)–\($0.periodEnd) · 可还 \(Money(minorUnits: $0.remainingMinor).formatted())").tag(Optional($0.id)) } }
      Text("一笔还款只对应一个账期。").font(.caption).foregroundStyle(FiscalColor.tertiary)
    case .installmentFee, .installmentRefund, .reimbursementReceipt: EmptyView()
    }
  }
  private func accountPicker(_ title: String, selection: Binding<UUID?>, values: [AccountDTO]) -> some View {
    Picker(title, selection: selection) { Text("请选择").tag(Optional<UUID>.none); ForEach(values) { Text($0.name).tag(Optional($0.id)) } }
  }
  private func categoryPicker(_ title: String, values: [CategoryDTO]) -> some View {
    Picker(title, selection: $draft.categoryID) { Text("请选择").tag(Optional<UUID>.none); ForEach(values) { Text($0.name).tag(Optional($0.id)) } }
  }
  private func loadCycles(_ accountID: UUID) async {
    guard let credit else { cycleError = "信用账期服务未配置。"; return }
    cycleGeneration += 1; let current = cycleGeneration; cycleError = nil
    do {
      let values = try await credit.cyclesForRepayment(accountID: accountID, retaining: draft.creditCycleID)
      guard current == cycleGeneration, draft.destinationAccountID == accountID else { return }; cycleOptions = values
    } catch { guard current == cycleGeneration else { return }; cycleError = (error as? FiscalAPIError)?.displayMessage ?? error.localizedDescription }
  }
  private func save() {
    guard let amount = CNYAmountParser.minorUnits(amountText), amount > 0 else { return }
    draft.amountMinor = amount
    Task { if await model.update(proposal, draft: draft) { dismiss() } }
  }
}

private struct AITextEntrySheet: View {
  @Bindable var model: AIProposalModel
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @State private var idempotencyKey = UUID()
  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 14) {
        Text("用一句话描述收入或支出，AI 只会生成待校验的结构化提案。")
          .font(.subheadline).foregroundStyle(FiscalColor.secondary)
        TextEditor(text: $text).font(.body).padding(10).frame(minHeight: 150)
          .background(.white, in: .rect(cornerRadius: 14))
        if let message = model.message { Text(message).font(.caption).foregroundStyle(FiscalColor.expense) }
        Spacer()
        Button("生成提案") {
          Task {
            let success = await model.create(text: text, idempotencyKey: idempotencyKey)
            if model.shouldRotateCreateKeyAfterFailure { idempotencyKey = UUID() }
            if success { dismiss() }
          }
        }.buttonStyle(FiscalActionButtonStyle()).frame(maxWidth: .infinity).disabled(model.isMutating)
      }.padding(18).background(FiscalColor.iOSBackground).navigationTitle("文本记账")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.buttonStyle(.plain) } }
    }.presentationDetents([.medium, .large])
  }
}

#if os(macOS)
public struct MacAIProposalScreen: View {
  @Bindable var model: AIProposalModel
  let accounts: AccountsModel?
  let categories: CategoriesModel?
  let credit: CreditModel?
  @State private var editing: AIProposalDTO?
  public init(model: AIProposalModel, accounts: AccountsModel? = nil, categories: CategoriesModel? = nil, credit: CreditModel? = nil) {
    self.model = model; self.accounts = accounts; self.categories = categories; self.credit = credit
  }
  public var body: some View {
    VStack(spacing: 0) {
      HStack { Text("AI 待确认").font(.system(size: 23, weight: .bold)); Text("\(model.pendingCount)").font(.caption.bold()).foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 4).background(FiscalColor.expense, in: .capsule); Picker("提案状态", selection: Binding(get: { model.statusFilter ?? .pending }, set: { status in Task { await model.selectStatus(status) } })) { Text("待确认").tag(AIProposalStatus.pending); Text("失败").tag(AIProposalStatus.failed) }.pickerStyle(.segmented).frame(width: 170); Spacer(); Button("刷新") { Task { await model.load() } }.buttonStyle(.plain).foregroundStyle(FiscalColor.accent) }
        .padding(.horizontal, 20).frame(height: 58).background(.white)
      HStack(spacing: 0) {
        ScrollView {
          LazyVStack(spacing: 8) {
            ForEach(model.proposals) { proposal in
              Button { model.selectedID = proposal.id } label: {
                HStack(spacing: 10) {
                  FiscalIconTile("sparkles", color: FiscalColor.accent)
                  VStack(alignment: .leading, spacing: 3) { Text(proposal.title ?? "待补全提案").font(.subheadline.weight(.semibold)); Text("文本 · \(proposal.confidenceTitle) · \(proposal.status.title)").font(.caption).foregroundStyle(FiscalColor.tertiary) }
                  Spacer(); Text(proposal.amountMinor.map { Money(minorUnits: $0).formatted() } ?? "—").font(.subheadline.monospacedDigit())
                }.padding(12).background(model.selectedID == proposal.id ? FiscalColor.accent.opacity(0.09) : .white, in: .rect(cornerRadius: 12))
              }.buttonStyle(.plain).task { if proposal.id == model.proposals.last?.id { await model.loadMore() } }
            }
          }.padding(14)
        }.frame(minWidth: 350)
        Divider()
        inspector.frame(width: 310)
      }
    }.background(FiscalColor.macBackground).task { if model.phase == .idle { await model.load() } }
      .sheet(item: $editing) { proposal in
        if let accounts, let categories { AIProposalEditorScreen(model: model, proposal: proposal, accounts: accounts, categories: categories, credit: credit).frame(minWidth: 520, minHeight: 580) }
      }
  }
  @ViewBuilder private var inspector: some View {
    if let proposal = model.selected {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          Text(proposal.title ?? "待补全标题").font(.title2.bold())
          Text(proposal.amountMinor.map { Money(minorUnits: $0).formatted() } ?? "金额待确认").font(.system(size: 28, weight: .bold)).monospacedDigit()
          detail("状态", proposal.status.title); detail("置信度", proposal.confidenceTitle); detail("来源", "文本")
          if let explanation = proposal.explanation { Text(explanation).font(.caption).foregroundStyle(FiscalColor.secondary) }
          if proposal.canReview { Button("确认记账") { Task { await model.execute(proposal) } }.buttonStyle(FiscalActionButtonStyle()); if accounts != nil && categories != nil { Button("编辑") { editing = proposal }.buttonStyle(FiscalActionButtonStyle(.secondary)) }; Button("忽略") { Task { await model.ignore(proposal) } }.buttonStyle(.plain).foregroundStyle(FiscalColor.tertiary) }
          else if proposal.status == .failed { Button("重新识别") { Task { await model.retry(proposal) } }.buttonStyle(FiscalActionButtonStyle(.secondary)) }
          else if proposal.status == .executed { Button("撤销这笔 AI 记账") { Task { await model.undo(proposal) } }.buttonStyle(FiscalActionButtonStyle(.secondary)) }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
      }.background(.white)
    } else { ContentUnavailableView("选择一条提案", systemImage: "sparkles") }
  }
  private func detail(_ label: String, _ value: String) -> some View { HStack { Text(label).foregroundStyle(FiscalColor.tertiary); Spacer(); Text(value) }.font(.subheadline) }
}
#endif
