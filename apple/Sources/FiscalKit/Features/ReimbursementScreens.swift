import SwiftUI

extension ReimbursementClaimStatus {
  fileprivate var color: Color {
    switch self {
    case .draft: FiscalColor.tertiary
    case .pending, .partialReceived: FiscalColor.debt
    case .received: FiscalColor.income
    case .cancelled: FiscalColor.tertiary
    case .partiallyReceivedCancelled: FiscalColor.reimbursement
    }
  }
}

private struct ReimbursementStatusPill: View {
  let status: ReimbursementClaimStatus
  var body: some View {
    Text(status.title).font(.caption.weight(.semibold)).foregroundStyle(status.color).padding(
      .horizontal, 9
    ).padding(.vertical, 5).background(status.color.opacity(0.12), in: .rect(cornerRadius: 8))
  }
}

private struct ReimbursementTotals: View {
  let claim: ReimbursementClaimDTO
  var body: some View {
    VStack(spacing: 12) {
      HStack {
        metric("应报销", claim.totalClaimedMinor, FiscalColor.text)
        metric("已回款", claim.receivedMinor, FiscalColor.income)
        metric("待回款", claim.outstandingMinor, FiscalColor.reimbursement)
      }
      ProgressView(
        value: Double(claim.receivedMinor), total: Double(max(1, claim.totalClaimedMinor))
      ).tint(FiscalColor.income)
    }
  }
  private func metric(_ label: String, _ amount: Int64, _ color: Color) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(label).font(.caption).foregroundStyle(FiscalColor.tertiary)
      Text(Money(minorUnits: amount).formatted()).font(.headline).foregroundStyle(color)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

#if os(iOS)
  public struct IOSReimbursementsScreen: View {
    @Bindable var model: ReimbursementModel
    let accounts: AccountsModel
    @State private var showCreate = false
    public init(model: ReimbursementModel, accounts: AccountsModel) {
      self.model = model
      self.accounts = accounts
    }
    public var body: some View {
      Group {
        if model.phase == .loading && model.claims.isEmpty {
          ProgressView("正在读取报销单…")
        } else if model.claims.isEmpty {
          ContentUnavailableView {
            Label("暂无报销单", systemImage: "doc.text")
          } description: {
            Text(model.message ?? "新建报销单后，可按付款主体登记分次到账。")
          } actions: {
            Button("新建报销单") { showCreate = true }
          }
        } else {
          ScrollView {
            LazyVStack(spacing: 14) {
              if let summary = model.summary { summaryCard(summary) }
              filterChips
              ForEach(model.claims) { claim in
                NavigationLink {
                  IOSReimbursementDetailScreen(model: model, accounts: accounts, claimID: claim.id)
                } label: {
                  claimCard(claim)
                }.buttonStyle(.plain).task {
                  if claim.id == model.claims.last?.id { await model.loadMore() }
                }
              }
              if let message = model.refreshMessage {
                Label(message, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(
                  FiscalColor.expense)
              }
            }.padding(16)
          }
        }
      }
      .background(FiscalColor.iOSBackground.ignoresSafeArea()).navigationTitle("报销")
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button("新建", systemImage: "plus") { showCreate = true }
        }
      }
      .refreshable { await model.load() }.task { if model.claims.isEmpty { await model.load() } }
      .onChange(of: model.includeArchived) { _, _ in Task { await model.load() } }
      .sheet(isPresented: $showCreate) { ReimbursementClaimEditor(model: model, editing: nil) }
    }
    private var filterChips: some View {
      ScrollView(.horizontal) {
        HStack {
          filter("全部", nil)
          ForEach(ReimbursementClaimStatus.allCases, id: \.self) { filter($0.title, $0) }
          Toggle("含归档", isOn: $model.includeArchived).toggleStyle(.button)
        }.padding(.horizontal, 1)
      }.scrollIndicators(.hidden)
    }
    private func filter(_ title: String, _ status: ReimbursementClaimStatus?) -> some View {
      Button(title) {
        model.statusFilter = status
        Task { await model.load() }
      }.buttonStyle(.borderedProminent).tint(
        model.statusFilter == status ? FiscalColor.accent : FiscalColor.surface
      ).foregroundStyle(model.statusFilter == status ? .white : FiscalColor.secondary)
    }
    private func summaryCard(_ value: ReimbursementSummary) -> some View {
      FiscalCard(radius: 20) {
        VStack(alignment: .leading, spacing: 12) {
          Text("报销概览").font(.headline)
          HStack {
            mini("预计报销", value.expectedReimbursementMinor, FiscalColor.text)
            mini("实际到账", value.receivedReimbursementMinor, FiscalColor.income)
            mini("待回款", value.outstandingMinor, FiscalColor.reimbursement)
          }
          Text("实际到账是现金流入，但不重复计为普通收入。").font(.caption).foregroundStyle(FiscalColor.tertiary)
        }
      }
    }
    private func mini(_ title: String, _ value: Int64, _ color: Color) -> some View {
      VStack(alignment: .leading) {
        Text(title).font(.caption2).foregroundStyle(FiscalColor.tertiary)
        Text(Money(minorUnits: value).formatted()).font(.subheadline.bold()).foregroundStyle(color)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func claimCard(_ claim: ReimbursementClaimDTO) -> some View {
      FiscalCard(radius: 20) {
        VStack(alignment: .leading, spacing: 13) {
          HStack(spacing: 11) {
            FiscalIconTile("doc.text", color: FiscalColor.reimbursement)
            VStack(alignment: .leading) {
              Text(claim.title).font(.headline)
              Text("\(claim.expenseCount) 笔垫付 · \(claim.partyCount) 个付款主体").font(.caption)
                .foregroundStyle(FiscalColor.tertiary)
            }
            Spacer()
            ReimbursementStatusPill(status: claim.status)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(FiscalColor.tertiary).accessibilityHidden(true)
          }
          ReimbursementTotals(claim: claim)
          if claim.archivedAt != nil {
            Label("已归档 · 只读", systemImage: "archivebox").font(.caption).foregroundStyle(
              FiscalColor.tertiary)
          }
        }
      }
    }
  }

  public struct IOSReimbursementDetailScreen: View {
    @Bindable var model: ReimbursementModel
    let accounts: AccountsModel
    let claimID: UUID
    @State private var showEdit = false
    @State private var showReceipt = false
    @State private var showCancelConfirmation = false
    @State private var editingReceipt: ReimbursementReceiptDTO?
    public init(model: ReimbursementModel, accounts: AccountsModel, claimID: UUID) {
      self.model = model
      self.accounts = accounts
      self.claimID = claimID
    }
    public var body: some View {
      Group {
        if let claim = model.selectedClaim, claim.id == claimID {
          ScrollView {
            VStack(spacing: 14) {
              header(claim)
              parties(claim)
              expenses(claim)
              receiptHistory(claim)
              scope(claim)
            }.padding(16)
          }
          .toolbar {
            ToolbarItem(placement: .primaryAction) {
              Menu {
                if claim.archivedAt != nil {
                  Button("取消归档") { Task { _ = await model.lifecycle("unarchive") } }
                } else if claim.voidedAt != nil {
                  Button("恢复报销单") { Task { _ = await model.lifecycle("restore") } }
                } else {
                  Button("编辑报销单", systemImage: "pencil") { showEdit = true }
                  if claim.outstandingMinor > 0 && claim.cancelledAt == nil && claim.voidedAt == nil
                  {
                    Button("登记到账", systemImage: "plus.circle") { showReceipt = true }
                  }
                  lifecycleButtons(claim)
                }
              } label: {
                Image(systemName: "ellipsis.circle")
              }
            }
          }
        } else {
          ContentUnavailableView(
            "正在读取报销单", systemImage: "doc.text", description: Text(model.message ?? "请稍候。"))
        }
      }
      .background(FiscalColor.iOSBackground.ignoresSafeArea()).navigationTitle("报销详情")
      .task { await model.loadClaim(claimID) }
      .sheet(isPresented: $showEdit) {
        if let claim = model.selectedClaim {
          ReimbursementClaimEditor(model: model, editing: claim)
        }
      }
      .sheet(isPresented: $showReceipt) {
        if let claim = model.selectedClaim {
          ReimbursementReceiptEditor(model: model, accounts: accounts, claim: claim)
        }
      }
      .sheet(item: $editingReceipt) { receipt in
        if let claim = model.selectedClaim {
          ReimbursementReceiptEditor(
            model: model, accounts: accounts, claim: claim, editing: receipt)
        }
      }
      .confirmationDialog(
        "确认取消未回款？", isPresented: $showCancelConfirmation, titleVisibility: .visible
      ) {
        Button("确认取消", role: .destructive) {
          Task { _ = await model.confirmCancel() }
        }
        Button("返回", role: .cancel) {}
      } message: {
        if let preview = model.cancelPreview {
          Text(
            "将释放 \(Money(minorUnits: preview.releasedMinor).formatted()) 未回款额度；保留已到账 \(Money(minorUnits: preview.retainedReceivedMinor).formatted())。状态将变为“\(preview.proposedStatus.title)”。"
          )
        }
      }
    }
    private func header(_ claim: ReimbursementClaimDTO) -> some View {
      FiscalCard(radius: 20) {
        VStack(alignment: .leading, spacing: 14) {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(claim.title).font(.title2.bold())
              Text("\(claim.expenseCount) 笔垫付 · \(claim.partyCount) 个付款主体").font(.caption)
                .foregroundStyle(FiscalColor.tertiary)
            }
            Spacer()
            ReimbursementStatusPill(status: claim.status)
          }
          ReimbursementTotals(claim: claim)
          if claim.archivedAt != nil {
            Label("已归档 · 只读", systemImage: "archivebox").foregroundStyle(FiscalColor.tertiary)
          } else if claim.voidedAt != nil {
            Label("已作废 · 只读", systemImage: "nosign").foregroundStyle(FiscalColor.tertiary)
          } else if claim.outstandingMinor > 0 && claim.cancelledAt == nil {
            Button("登记到账") { showReceipt = true }.buttonStyle(.borderedProminent).tint(
              FiscalColor.reimbursement)
          }
        }
      }
    }
    private func parties(_ claim: ReimbursementClaimDTO) -> some View {
      FiscalCard(radius: 18) {
        VStack(alignment: .leading, spacing: 0) {
          Text("付款主体").font(.headline).padding(.bottom, 8)
          ForEach(claim.parties) { party in
            VStack(alignment: .leading, spacing: 7) {
              HStack {
                Text(party.name).fontWeight(.semibold)
                Spacer()
                Text(party.statusTitle).font(.caption).foregroundStyle(FiscalColor.tertiary)
              }
              HStack {
                value("应付", party.claimedMinor)
                value("已到账", party.receivedMinor)
                value("待回", party.outstandingMinor)
              }
              if let date = party.expectedDate {
                Text("预计到账 \(date)").font(.caption).foregroundStyle(FiscalColor.tertiary)
              }
            }.padding(.vertical, 10)
            Divider()
          }
        }
      }
    }
    private func expenses(_ claim: ReimbursementClaimDTO) -> some View {
      FiscalCard(radius: 18) {
        VStack(alignment: .leading, spacing: 0) {
          Text("关联垫付 · 主体 × 支出").font(.headline).padding(.bottom, 8)
          ForEach(claim.parties) { party in
            ForEach(party.allocations) { allocation in
              HStack {
                VStack(alignment: .leading) {
                  Text(allocation.expenseTitle)
                  Text(party.name + (allocation.locked ? " · 已锁定" : "")).font(.caption)
                    .foregroundStyle(FiscalColor.tertiary)
                }
                Spacer()
                Text(Money(minorUnits: allocation.amountMinor).formatted()).fontWeight(.semibold)
              }.padding(.vertical, 9)
            }
          }
        }
      }
    }
    private func receiptHistory(_ claim: ReimbursementClaimDTO) -> some View {
      FiscalCard(radius: 18) {
        VStack(alignment: .leading, spacing: 0) {
          HStack {
            Text("回款记录").font(.headline)
            Spacer()
            Text("共 \(claim.receiptCount) 笔").font(.caption).foregroundStyle(FiscalColor.tertiary)
          }
          if model.receiptHistory.isEmpty {
            Text("尚未到账").foregroundStyle(FiscalColor.tertiary).padding(.vertical)
          }
          ForEach(model.receiptHistory) { receipt in
            HStack {
              Image(
                systemName: receipt.voidedAt == nil ? "arrow.uturn.backward.circle.fill" : "nosign"
              ).foregroundStyle(receipt.voidedAt == nil ? FiscalColor.income : FiscalColor.tertiary)
              VStack(alignment: .leading) {
                Text(receipt.title)
                Text(
                  receipt.receivedAt.formatted(date: .abbreviated, time: .shortened)
                    + (receipt.voidedAt == nil ? "" : " · 已作废")
                ).font(.caption).foregroundStyle(FiscalColor.tertiary)
              }
              Spacer()
              Text("+" + Money(minorUnits: receipt.amountMinor).formatted()).foregroundStyle(
                receipt.voidedAt == nil ? FiscalColor.income : FiscalColor.tertiary
              )
              if claim.archivedAt == nil {
                Menu {
                  if receipt.voidedAt == nil {
                    Button("编辑") { editingReceipt = receipt }
                    Button("作废回款", role: .destructive) {
                      Task { _ = await model.receiptLifecycle(receipt, action: "void") }
                    }
                  } else if claim.cancelledAt == nil {
                    Button("恢复回款") {
                      Task { _ = await model.receiptLifecycle(receipt, action: "restore") }
                    }
                  }
                } label: {
                  Image(systemName: "ellipsis.circle")
                }
              }
            }.padding(.vertical, 9).task {
              if receipt.id == model.receiptHistory.last?.id {
                await model.loadMoreReceipts(claimID: claim.id)
              }
            }
          }
        }
      }
    }
    private func scope(_ claim: ReimbursementClaimDTO) -> some View {
      FiscalCard(radius: 18) {
        VStack(alignment: .leading, spacing: 8) {
          Text("支出口径").font(.headline)
          LabeledContent("本单预计报销", value: Money(minorUnits: claim.totalClaimedMinor).formatted())
          LabeledContent("本单实际到账", value: Money(minorUnits: claim.receivedMinor).formatted())
          Text("个人预计承担按原始消费、商家本金退款与有效报销分配计算；个人已实现承担只扣真实到账。预计报销不会生成未来现金流；真实到账是现金流入，但不计普通收入。").font(
            .caption
          ).foregroundStyle(FiscalColor.tertiary)
        }
      }
    }
    @ViewBuilder private func lifecycleButtons(_ claim: ReimbursementClaimDTO) -> some View {
      if claim.status == .draft {
        Button("提交") { Task { _ = await model.lifecycle("submit") } }
        if claim.receiptCount == 0 {
          Button("作废", role: .destructive) { Task { _ = await model.lifecycle("void") } }
        }
      }
      if claim.status == .pending {
        Button("撤回提交") { Task { _ = await model.lifecycle("retract-submission") } }
      }
      if claim.status == .pending || claim.status == .partialReceived {
        Button("取消未回款", role: .destructive) {
          Task {
            if await model.previewCancellation() { showCancelConfirmation = true }
          }
        }
      }
      if claim.status == .cancelled || claim.status == .partiallyReceivedCancelled {
        Button("重新开启") { Task { _ = await model.lifecycle("reopen") } }
      }
      if claim.status.isTerminal { Button("归档") { Task { _ = await model.lifecycle("archive") } } }
    }
    private func value(_ title: String, _ amount: Int64) -> some View {
      VStack(alignment: .leading) {
        Text(title).font(.caption2).foregroundStyle(FiscalColor.tertiary)
        Text(Money(minorUnits: amount).formatted()).font(.caption.bold())
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
#endif

public struct ReimbursementReceiptEditor: View {
  private enum FocusedField: Hashable { case amount, title, note }

  @Environment(\.dismiss) private var dismiss
  @Bindable var model: ReimbursementModel
  @Bindable var accounts: AccountsModel
  let claim: ReimbursementClaimDTO
  let editing: ReimbursementReceiptDTO?
  @State private var partyID: UUID?
  @State private var accountID: UUID?
  @State private var amount = ""
  @State private var receivedAt = Date()
  @State private var title = "报销到账"
  @State private var note = ""
  @State private var options: [AccountDTO] = []
  @FocusState private var focusedField: FocusedField?
  public init(
    model: ReimbursementModel, accounts: AccountsModel, claim: ReimbursementClaimDTO,
    editing: ReimbursementReceiptDTO? = nil
  ) {
    self.model = model
    self.accounts = accounts
    self.claim = claim
    self.editing = editing
    _partyID = State(
      initialValue: editing?.partyID ?? claim.parties.first(where: { $0.outstandingMinor > 0 })?.id)
    _accountID = State(initialValue: editing?.destinationAccountID)
    _amount = State(initialValue: editing.map { String($0.amountMinor) } ?? "")
    _receivedAt = State(initialValue: editing?.receivedAt ?? Date())
    _title = State(initialValue: editing?.title ?? "报销到账")
    _note = State(initialValue: editing?.note ?? "")
  }
  public var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          receiptSection("到账信息") {
            VStack(alignment: .leading, spacing: 13) {
              Picker("付款主体", selection: $partyID) {
                Text("请选择").tag(Optional<UUID>.none)
                ForEach(claim.parties.filter { $0.outstandingMinor > 0 || $0.id == editing?.partyID }) {
                  Text("\($0.name) · 待回 \(Money(minorUnits: $0.outstandingMinor).formatted())").tag(Optional($0.id))
                }
              }
              Divider().opacity(0.35)
              Picker("到账账户", selection: $accountID) {
                Text("请选择").tag(Optional<UUID>.none)
                ForEach(options.filter { $0.kind == .cash || $0.kind == .debit || $0.id == editing?.destinationAccountID }) {
                  Text($0.name).tag(Optional($0.id))
                }
              }
              Divider().opacity(0.35)
              TextField("金额（分）", text: $amount).focused($focusedField, equals: .amount)
#if os(iOS)
                .keyboardType(.numberPad)
#endif
              Divider().opacity(0.35)
              DatePicker("到账时间", selection: $receivedAt, in: ...Date())
              Divider().opacity(0.35)
              TextField("标题", text: $title).focused($focusedField, equals: .title)
              Divider().opacity(0.35)
              TextField("备注", text: $note, axis: .vertical).lineLimit(2...5).focused($focusedField, equals: .note)
            }.textFieldStyle(.plain)
          }
          if let preview = model.receiptPreview {
            receiptSection("服务器影响预览") {
              VStack(alignment: .leading, spacing: 11) {
                receiptValue("主体到账前", preview.partyReceivedBeforeMinor)
                Divider().opacity(0.35)
                receiptValue("主体到账后", preview.partyReceivedAfterMinor)
                Divider().opacity(0.35)
                receiptValue("本单到账前", preview.claimReceivedBeforeMinor)
                Divider().opacity(0.35)
                receiptValue("本单到账后", preview.claimReceivedAfterMinor)
                Text("将按服务器稳定顺序分配到 \(preview.persistedAllocations.count) 个主体 × 支出矩阵行。")
                  .font(.caption).foregroundStyle(FiscalColor.tertiary)
              }
            }
          }
          if let message = model.message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
              .font(.subheadline).foregroundStyle(FiscalColor.expense).padding(13)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(FiscalColor.expense.opacity(0.09), in: .rect(cornerRadius: 14))
          }
        }.padding(16)
      }.background(receiptBackground).scrollDismissesKeyboard(.interactively)
      .navigationTitle(editing == nil ? "登记到账" : "编辑到账").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
#if os(iOS)
        ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { focusedField = nil } }
#endif
      }.safeAreaInset(edge: .bottom) {
        Button {
          focusedField = nil
          if model.receiptPreview == nil { preview() } else { commit() }
        } label: {
          Text(receiptActionTitle).frame(maxWidth: .infinity)
        }.buttonStyle(FiscalActionButtonStyle())
          .disabled(model.receiptPreview == nil ? request == nil : model.isMutating)
          .padding(.horizontal, 16).padding(.vertical, 10).background(.regularMaterial)
      }.task {
        options = (try? await accounts.transactionOptions()) ?? []
        if accountID == nil {
          accountID = options.first(where: { $0.kind == .debit || $0.kind == .cash })?.id
        }
      }.onChange(of: partyID) { _, _ in model.invalidateReceiptPreview() }.onChange(of: accountID) {
        _, _ in model.invalidateReceiptPreview()
      }.onChange(of: amount) { _, _ in model.invalidateReceiptPreview() }.onChange(of: receivedAt) {
        _, _ in model.invalidateReceiptPreview()
      }.onChange(of: title) { _, _ in model.invalidateReceiptPreview() }.onChange(of: note) {
        _, _ in model.invalidateReceiptPreview()
      }
    }.reimbursementEditorFrame(width: 520, height: 600)
    .onDisappear { model.invalidateReceiptPreview() }
  }
  private var receiptActionTitle: String {
    if model.isMutating { return "保存中…" }
    if model.receiptPreview == nil { return "预览影响" }
    return editing == nil ? "确认到账" : "确认保存"
  }
  private var receiptBackground: Color {
#if os(iOS)
    FiscalColor.iOSBackground
#else
    FiscalColor.macBackground
#endif
  }
  private func receiptSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.headline).padding(.horizontal, 3)
      FiscalCard(radius: 18) { content() }
    }
  }
  private func receiptValue(_ title: String, _ amount: Int64) -> some View {
    HStack { Text(title).foregroundStyle(FiscalColor.secondary); Spacer(); Text(Money(minorUnits: amount).formatted()).fontWeight(.semibold) }.font(.subheadline)
  }
  private var request: ReimbursementReceiptRequest? {
    guard let partyID, let accountID, let amountMinor = Int64(amount), amountMinor > 0,
      !title.trimmingCharacters(in: .whitespaces).isEmpty
    else { return nil }
    return .init(
      expectedClaimVersion: model.selectedClaim?.version ?? claim.version, partyID: partyID,
      amountMinor: amountMinor, receivedAt: receivedAt, destinationAccountID: accountID,
      title: title, note: note.isEmpty ? nil : note)
  }
  private var replacement: ReimbursementReceiptReplacementRequest? {
    guard let editing, let request else { return nil }
    return .init(
      expectedClaimVersion: request.expectedClaimVersion, expectedReceiptVersion: editing.version,
      partyID: request.partyID, amountMinor: request.amountMinor, receivedAt: request.receivedAt,
      destinationAccountID: request.destinationAccountID, title: request.title, note: request.note)
  }
  private func preview() {
    guard let request else { return }
    Task {
      if let editing, let replacement {
        _ = await model.previewReceiptReplacement(editing, request: replacement)
      } else {
        _ = await model.previewReceipt(request)
      }
    }
  }
  private func commit() {
    guard let request else { return }
    Task {
      let success: Bool
      if let editing, let replacement {
        success = await model.updateReceipt(editing, request: replacement)
      } else {
        success = await model.createReceipt(request)
      }
      if success { dismiss() }
    }
  }
}

public struct ReimbursementClaimEditor: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: ReimbursementModel
  let editing: ReimbursementClaimDTO?
  @State private var title: String
  @State private var note: String
  @State private var parties: [ReimbursementPartyDraft]
  @State private var amountTexts: [UUID: String]
  public init(model: ReimbursementModel, editing: ReimbursementClaimDTO?) {
    self.model = model
    self.editing = editing
    _title = State(initialValue: editing?.title ?? "")
    _note = State(initialValue: editing?.note ?? "")
    let initialParties: [ReimbursementPartyDraft] = editing?.parties.map {
        ReimbursementPartyDraft(
          id: $0.id, name: $0.name, expectedDate: $0.expectedDate, note: $0.note,
          allocations: $0.allocations.map {
            ReimbursementAllocationDraft(
              id: $0.id, transactionID: $0.transactionID, amountMinor: $0.amountMinor)
          })
      } ?? [
        ReimbursementPartyDraft(
          id: nil, name: "", expectedDate: nil, note: nil, allocations: [])
      ]
    _parties = State(initialValue: initialParties)
    _amountTexts = State(
      initialValue: Dictionary(
        uniqueKeysWithValues: initialParties.flatMap(\.allocations).map {
          ($0.id, Self.yuanText(minorUnits: $0.amountMinor))
        }))
  }
  public var body: some View {
    // Clearing the shared claim preview on dismiss stops a cancelled edit from leaking its
    // preview (and the "确认保存" button state) into the next claim's editor session.
    editorBody.onDisappear { model.invalidateClaimPreview() }
  }

  @ViewBuilder private var editorBody: some View {
    #if os(macOS)
      macEditor
    #else
      compactEditor
    #endif
  }

  private var compactEditor: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          FiscalCard(radius: 16) {
            VStack(alignment: .leading, spacing: 12) {
              Text("基本信息").font(.headline)
              TextField("报销单标题", text: $title)
              TextField("备注", text: $note)
            }
          }
          ForEach($parties) { $party in
            FiscalCard(radius: 16) {
              VStack(alignment: .leading, spacing: 12) {
                HStack {
                  Text("付款主体").font(.headline)
                  Spacer()
                  if parties.count > 1 && canRemoveParty(party.serverID) {
                    Button("移除", role: .destructive) {
                      let id = party.id
                      parties.removeAll { $0.id == id }
                    }
                  }
                }
                TextField("主体名称", text: $party.name)
                TextField(
                  "预计到账日期 yyyy-MM-dd",
                  text: Binding(
                    get: { party.expectedDate ?? "" },
                    set: { party.expectedDate = $0.isEmpty ? nil : $0 }
                  )
                )
                TextField(
                  "主体备注",
                  text: Binding(
                    get: { party.note ?? "" },
                    set: { party.note = $0.isEmpty ? nil : $0 }
                  )
                )
                ForEach($party.allocations) { $allocation in
                  if matrixFrozen {
                    HStack {
                      Label(
                        existingExpenseTitle(allocation.transactionID), systemImage: "nosign"
                      )
                      .foregroundStyle(FiscalColor.secondary)
                      Spacer()
                      Text(Money(minorUnits: allocation.amountMinor).formatted())
                    }
                  } else if isLockedAllocation(allocation.serverID) {
                    HStack {
                      Label(
                        existingExpenseTitle(allocation.transactionID), systemImage: "lock.fill"
                      )
                      .foregroundStyle(FiscalColor.secondary)
                      Spacer()
                      TextField(
                        "金额（元）",
                        text: amountTextBinding(
                          $allocation, minimum: lockedReceivedMinor(allocation.serverID))
                      )
                      .frame(width: 120)
                      Text(
                        "最低 \(Money(minorUnits: lockedReceivedMinor(allocation.serverID)).formatted())"
                      )
                        .font(.caption)
                        .foregroundStyle(FiscalColor.tertiary)
                    }
                  } else {
                    HStack {
                      Picker("关联垫付", selection: $allocation.transactionID) {
                        ForEach(
                          selectableExpenseOptions(
                            for: party, current: allocation.transactionID)
                        ) {
                          Text(
                            "\($0.title) · 可用 \(Money(minorUnits: $0.availableMinor).formatted())"
                          )
                          .tag($0.transactionID)
                        }
                      }
                      TextField(
                        "金额（元）", text: amountTextBinding($allocation, minimum: 0)
                      ).frame(width: 120)
                    }
                  }
                }
                if !matrixFrozen {
                  Button("添加垫付") {
                    appendAllocation(to: $party)
                  }.disabled(nextExpenseOption(for: $party) == nil)
                }
              }
            }
          }
          if !matrixFrozen {
            Button("添加付款主体") {
              parties.append(
                .init(id: nil, name: "", expectedDate: nil, note: nil, allocations: []))
            }.buttonStyle(.bordered)
          }
          if let preview = model.claimPreview {
            FiscalCard(radius: 16) {
              VStack(alignment: .leading) {
                Text("服务器预览").font(.headline)
                ReimbursementTotals(claim: preview.proposed)
                Text(
                  "释放 \(Money(minorUnits: preview.releasedMinor).formatted()) · 新增 \(Money(minorUnits: preview.newlyClaimedMinor).formatted())"
                ).font(.caption).foregroundStyle(FiscalColor.tertiary)
                ForEach(preview.warnings, id: \.self) {
                  Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(
                    FiscalColor.debt)
                }
              }
            }
          }
          if let message = model.message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
              .font(.subheadline).foregroundStyle(FiscalColor.expense).padding(13)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(FiscalColor.expense.opacity(0.09), in: .rect(cornerRadius: 14))
          }
        }.padding(20)
      }.background(FiscalColor.macBackground).navigationTitle(editing == nil ? "新建报销单" : "编辑报销单")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            if editing == nil {
              Button("创建") { create() }.disabled(!valid)
            } else if model.claimPreview == nil {
              Button("预览") { preview() }.disabled(!valid)
            } else {
              Button("确认保存") { update() }.disabled(model.isMutating)
            }
          }
        }.task { await model.loadExpenseOptions() }.onChange(of: title) { _, _ in
          model.invalidateClaimPreview()
        }.onChange(of: note) { _, _ in model.invalidateClaimPreview() }.onChange(of: parties) {
          _, _ in model.invalidateClaimPreview()
        }
    }.reimbursementEditorFrame(width: 760, height: 650)
  }

  #if os(macOS)
    private var macEditor: some View {
      VStack(spacing: 0) {
        macHeader
        Divider().opacity(0.45)
        HStack(alignment: .top, spacing: 16) {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
              macIdentityCard
              ForEach($parties) { party in
                macPartyCard(
                  party,
                  index: parties.firstIndex(where: { $0.id == party.wrappedValue.id }) ?? 0)
              }
              if !matrixFrozen { macAddPartyButton }
            }.padding(.bottom, 4)
          }.scrollIndicators(.hidden)
          ScrollView {
            VStack(spacing: 14) {
              macDraftSummary
              if let message = model.message { macMessageBanner(message) }
            }
          }.scrollIndicators(.hidden).frame(width: 248)
        }.padding(18).frame(maxHeight: .infinity)
        Divider().opacity(0.45)
        macActionBar
      }
      .background(FiscalColor.macBackground)
      .frame(width: 840, height: 680)
      .task { await model.loadExpenseOptions() }
      .onChange(of: title) { _, _ in model.invalidateClaimPreview() }
      .onChange(of: note) { _, _ in model.invalidateClaimPreview() }
      .onChange(of: parties) { _, _ in model.invalidateClaimPreview() }
    }

    private var macHeader: some View {
      HStack(spacing: 12) {
        FiscalIconTile("doc.text.fill", color: FiscalColor.reimbursement)
        VStack(alignment: .leading, spacing: 2) {
          Text(editing == nil ? "新建报销单" : "编辑报销单")
            .font(.system(size: 19, weight: .bold))
          Text("拆分付款主体与垫付金额，保存前由服务器校验影响")
            .font(.caption).foregroundStyle(FiscalColor.tertiary)
        }
        Spacer()
        if let editing {
          Text("版本 \(model.selectedClaim?.version ?? editing.version)")
            .font(.caption.weight(.semibold)).foregroundStyle(FiscalColor.tertiary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(FiscalColor.separator.opacity(0.72), in: .capsule)
        }
        Button { dismiss() } label: {
          Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
            .frame(width: 32, height: 32)
            .background(FiscalColor.separator.opacity(0.72), in: .circle)
        }
        .buttonStyle(.plain).foregroundStyle(FiscalColor.secondary)
        .keyboardShortcut(.cancelAction).accessibilityLabel("取消编辑")
      }.padding(.horizontal, 20).frame(height: 62).background(FiscalColor.surface)
    }

    private var macIdentityCard: some View {
      FiscalCard(radius: 16) {
        VStack(alignment: .leading, spacing: 13) {
          macSectionHeader(
            title: "报销信息", subtitle: "给这张报销单一个便于检索的名称", symbol: "text.document")
          macTextField(
            label: "报销单标题", prompt: "例如：7 月上海差旅", text: $title,
            symbol: "textformat")
          macTextField(
            label: "备注", prompt: "可选，记录项目或结算说明", text: $note,
            symbol: "note.text")
        }
      }
    }

    private func macPartyCard(
      _ party: Binding<ReimbursementPartyDraft>, index: Int
    ) -> some View {
      FiscalCard(radius: 16) {
        VStack(alignment: .leading, spacing: 13) {
          HStack(spacing: 10) {
            Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.white)
              .frame(width: 25, height: 25)
              .background(FiscalColor.reimbursement, in: .circle)
            VStack(alignment: .leading, spacing: 1) {
              Text("付款主体").font(.headline)
              Text(partyStatusSubtitle(party.wrappedValue.serverID))
                .font(.caption).foregroundStyle(FiscalColor.tertiary)
            }
            Spacer()
            if parties.count > 1 && canRemoveParty(party.wrappedValue.serverID) {
              Button {
                let id = party.wrappedValue.id
                parties.removeAll { $0.id == id }
              } label: {
                Label("移除主体", systemImage: "trash")
                  .font(.caption.weight(.semibold)).foregroundStyle(FiscalColor.expense)
                  .padding(.horizontal, 9).padding(.vertical, 6)
                  .background(FiscalColor.expense.opacity(0.08), in: .rect(cornerRadius: 8))
              }.buttonStyle(.plain)
            }
          }
          HStack(alignment: .top, spacing: 10) {
            macTextField(
              label: "主体名称", prompt: "公司或项目组", text: party.name,
              symbol: "building.2")
            macTextField(
              label: "预计到账", prompt: "yyyy-MM-dd",
              text: optionalStringBinding(party.expectedDate), symbol: "calendar")
          }
          macTextField(
            label: "主体备注", prompt: "可选，记录结算批次或联系人",
            text: optionalStringBinding(party.note), symbol: "person.text.rectangle")
          macAllocationMatrix(party)
        }
      }
    }

    private var macAddPartyButton: some View {
      Button {
        parties.append(.init(id: nil, name: "", expectedDate: nil, note: nil, allocations: []))
      } label: {
        HStack(spacing: 10) {
          Image(systemName: "plus").font(.system(size: 13, weight: .bold))
            .frame(width: 30, height: 30)
            .background(FiscalColor.accent.opacity(0.12), in: .rect(cornerRadius: 9))
          VStack(alignment: .leading, spacing: 2) {
            Text("添加付款主体").fontWeight(.semibold)
            Text("为另一家公司或项目组拆分应付金额").font(.caption)
              .foregroundStyle(FiscalColor.tertiary)
          }
          Spacer()
          Image(systemName: "chevron.right").font(.caption.weight(.semibold))
        }
        .foregroundStyle(FiscalColor.accent).padding(13)
        .background(FiscalColor.accent.opacity(0.065), in: .rect(cornerRadius: 14))
        .overlay {
          RoundedRectangle(cornerRadius: 14).stroke(
            FiscalColor.accent.opacity(0.20), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
      }.buttonStyle(.plain)
    }

    private var macActionBar: some View {
      HStack(spacing: 10) {
        Text(valid ? "输入完整" : "请补全标题、主体与垫付金额")
          .font(.caption).foregroundStyle(valid ? FiscalColor.income : FiscalColor.tertiary)
        Spacer()
        Button("取消") { dismiss() }
          .buttonStyle(.plain).font(.system(size: 13, weight: .semibold))
          .foregroundStyle(FiscalColor.secondary).padding(.horizontal, 18).frame(height: 38)
          .background(FiscalColor.separator.opacity(0.72), in: .rect(cornerRadius: 10))
        Button { macPrimaryAction() } label: {
          HStack(spacing: 7) {
            if model.isMutating { ProgressView().controlSize(.small).tint(.white) }
            Image(systemName: macPrimarySymbol)
            Text(macPrimaryTitle)
          }
          .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
          .padding(.horizontal, 18).frame(minWidth: 126, minHeight: 38)
          .background(
            LinearGradient(
              colors: [FiscalColor.accent, FiscalColor.accentDark],
              startPoint: .topLeading, endPoint: .bottomTrailing),
            in: .rect(cornerRadius: 10))
          .shadow(color: FiscalColor.accent.opacity(0.20), radius: 7, y: 3)
        }
        .buttonStyle(.plain).disabled(!valid || model.isMutating)
        .opacity(!valid || model.isMutating ? 0.48 : 1)
        .keyboardShortcut(.defaultAction)
      }.padding(.horizontal, 20).frame(height: 58).background(FiscalColor.surface)
    }

    private var macPrimaryTitle: String {
      if editing == nil { return "创建报销单" }
      return model.claimPreview == nil ? "预览影响" : "确认保存"
    }

    private var macPrimarySymbol: String {
      if editing == nil { return "plus" }
      return model.claimPreview == nil ? "arrow.right.circle" : "checkmark"
    }

    private func macPrimaryAction() {
      if editing == nil { create() }
      else if model.claimPreview == nil { preview() }
      else { update() }
    }

    private func macAllocationMatrix(_ party: Binding<ReimbursementPartyDraft>) -> some View {
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Text("关联垫付").frame(maxWidth: .infinity, alignment: .leading)
          Text("已到账").frame(width: 82, alignment: .trailing)
          Text("分配金额").frame(width: 116, alignment: .trailing)
          Text("状态").frame(width: 68, alignment: .trailing)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(FiscalColor.tertiary)
        .padding(.horizontal, 12).padding(.bottom, 7)

        VStack(spacing: 0) {
          ForEach(party.allocations) { allocation in
            macAllocationRow(allocation, party: party)
            if allocation.wrappedValue.id != party.wrappedValue.allocations.last?.id {
              Divider().opacity(0.45).padding(.leading, 42)
            }
          }
          if !matrixFrozen {
            Button { appendAllocation(to: party) } label: {
              HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                Text("添加垫付").fontWeight(.semibold)
                Spacer()
                Text(nextExpenseHint(for: party)).font(.caption)
                  .foregroundStyle(FiscalColor.tertiary)
              }
              .foregroundStyle(FiscalColor.accent).padding(.horizontal, 12).frame(height: 42)
              .contentShape(.rect)
            }
            .buttonStyle(.plain).disabled(nextExpenseOption(for: party) == nil)
            .opacity(nextExpenseOption(for: party) == nil ? 0.45 : 1)
          }
        }
        .background(FiscalColor.macBackground, in: .rect(cornerRadius: 11))
        .overlay {
          RoundedRectangle(cornerRadius: 11).stroke(FiscalColor.separator, lineWidth: 0.5)
        }
      }
    }

    private func macAllocationRow(
      _ allocation: Binding<ReimbursementAllocationDraft>,
      party: Binding<ReimbursementPartyDraft>
    ) -> some View {
      let locked = isLockedAllocation(allocation.wrappedValue.serverID)
      let frozen = matrixFrozen
      return HStack(spacing: 10) {
        Image(systemName: locked ? "lock.fill" : "doc.text")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(locked ? FiscalColor.reimbursement : FiscalColor.accent)
          .frame(width: 28, height: 28)
          .background(
            (locked ? FiscalColor.reimbursement : FiscalColor.accent).opacity(0.10),
            in: .rect(cornerRadius: 8))
          .accessibilityHidden(true)
        if frozen || locked {
          Text(existingExpenseTitle(allocation.wrappedValue.transactionID))
            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        } else {
          Picker("垫付事项", selection: allocation.transactionID) {
            ForEach(
              selectableExpenseOptions(
                for: party.wrappedValue, current: allocation.wrappedValue.transactionID)
            ) {
              Text("\($0.title) · 可用 \(Money(minorUnits: $0.availableMinor).formatted())")
                .tag($0.transactionID)
            }
          }.labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
        }
        Text(Money(minorUnits: allocationReceivedMinor(allocation.wrappedValue.serverID)).formatted())
          .font(.caption).foregroundStyle(FiscalColor.secondary)
          .frame(width: 82, alignment: .trailing)
        if frozen {
          Text(Money(minorUnits: allocation.wrappedValue.amountMinor).formatted())
            .frame(width: 116, alignment: .trailing)
        } else {
          HStack(spacing: 3) {
            Text("¥").foregroundStyle(FiscalColor.tertiary)
            TextField(
              "0.00",
              text: amountTextBinding(
                allocation, minimum: lockedReceivedMinor(allocation.wrappedValue.serverID)))
              .textFieldStyle(.plain).multilineTextAlignment(.trailing)
          }
          .padding(.horizontal, 8).frame(width: 116, height: 32)
          .background(FiscalColor.surface, in: .rect(cornerRadius: 8))
          .overlay {
            RoundedRectangle(cornerRadius: 8).stroke(
              amountIsValid(allocation.wrappedValue)
                ? FiscalColor.separator : FiscalColor.expense.opacity(0.75),
              lineWidth: amountIsValid(allocation.wrappedValue) ? 0.5 : 1)
          }
        }
        HStack(spacing: 5) {
          Text(
            frozen ? "冻结" : locked ? "锁定"
              : amountIsValid(allocation.wrappedValue) ? "可编辑" : "金额错误")
          if !frozen && !locked {
            Button {
              let id = allocation.wrappedValue.id
              party.wrappedValue.allocations.removeAll { $0.id == id }
            } label: { Image(systemName: "xmark.circle.fill") }
              .buttonStyle(.plain).foregroundStyle(FiscalColor.tertiary)
              .accessibilityLabel("移除垫付")
          }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(
          !frozen && !locked && !amountIsValid(allocation.wrappedValue)
            ? FiscalColor.expense : locked ? FiscalColor.reimbursement : FiscalColor.tertiary)
        .frame(width: 68, alignment: .trailing)
      }
      .padding(.horizontal, 10).frame(minHeight: 46)
      .background(locked ? FiscalColor.reimbursement.opacity(0.035) : .clear)
    }

    private var macDraftSummary: some View {
      FiscalCard(radius: 16) {
        VStack(alignment: .leading, spacing: 13) {
          macSectionHeader(
            title: model.claimPreview == nil ? "保存前摘要" : "服务器影响",
            subtitle: model.claimPreview == nil ? "预计口径" : "已按当前输入校验",
            symbol: model.claimPreview == nil ? "sum" : "checkmark.shield.fill")
          let claim = model.claimPreview?.proposed
          macSummaryValue(
            "拟议报销", claim?.totalClaimedMinor ?? draftTotalMinor, color: FiscalColor.text)
          macSummaryValue(
            "已到账", claim?.receivedMinor ?? editing?.receivedMinor ?? 0,
            color: FiscalColor.income)
          macSummaryValue(
            "保存后待回",
            claim?.outstandingMinor ?? max(0, draftTotalMinor - (editing?.receivedMinor ?? 0)),
            color: FiscalColor.reimbursement)
          if let preview = model.claimPreview {
            Divider().opacity(0.45)
            HStack {
              Text("释放").foregroundStyle(FiscalColor.tertiary)
              Spacer()
              Text(Money(minorUnits: preview.releasedMinor).formatted())
            }
            HStack {
              Text("新增").foregroundStyle(FiscalColor.tertiary)
              Spacer()
              Text(Money(minorUnits: preview.newlyClaimedMinor).formatted())
            }
            ForEach(preview.warnings, id: \.self) {
              Label($0, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(FiscalColor.debt)
            }
          } else {
            Text("预览不会写入账本；确认保存后才会替换当前矩阵。")
              .font(.caption).foregroundStyle(FiscalColor.tertiary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }

    private func macMessageBanner(_ message: String) -> some View {
      HStack(alignment: .top, spacing: 9) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(FiscalColor.expense).accessibilityHidden(true)
        Text(message).font(.caption).foregroundStyle(FiscalColor.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(FiscalColor.expense.opacity(0.07), in: .rect(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12).stroke(
          FiscalColor.expense.opacity(0.16), lineWidth: 0.5)
      }
    }

    private func macSectionHeader(
      title: String, subtitle: String, symbol: String
    ) -> some View {
      HStack(spacing: 10) {
        Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
          .foregroundStyle(FiscalColor.reimbursement)
          .frame(width: 30, height: 30)
          .background(FiscalColor.reimbursement.opacity(0.10), in: .rect(cornerRadius: 9))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text(title).font(.headline)
          Text(subtitle).font(.caption).foregroundStyle(FiscalColor.tertiary)
        }
      }
    }

    private func macTextField(
      label: String, prompt: String, text: Binding<String>, symbol: String
    ) -> some View {
      VStack(alignment: .leading, spacing: 6) {
        Text(label).font(.caption.weight(.semibold)).foregroundStyle(FiscalColor.secondary)
        HStack(spacing: 8) {
          Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            .foregroundStyle(FiscalColor.tertiary).frame(width: 16).accessibilityHidden(true)
          TextField(prompt, text: text).textFieldStyle(.plain)
        }
        .padding(.horizontal, 11).frame(height: 40)
        .background(FiscalColor.macBackground, in: .rect(cornerRadius: 10))
        .overlay {
          RoundedRectangle(cornerRadius: 10).stroke(FiscalColor.separator, lineWidth: 0.5)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func macSummaryValue(_ label: String, _ amountMinor: Int64, color: Color) -> some View {
      HStack(alignment: .firstTextBaseline) {
        Text(label).font(.caption).foregroundStyle(FiscalColor.tertiary)
        Spacer()
        Text(Money(minorUnits: amountMinor).formatted())
          .font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
      }
    }

    private func optionalStringBinding(_ value: Binding<String?>) -> Binding<String> {
      Binding(
        get: { value.wrappedValue ?? "" },
        set: { value.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private var draftTotalMinor: Int64 {
      parties.flatMap(\.allocations).reduce(0) { total, allocation in
        let (sum, overflow) = total.addingReportingOverflow(allocation.amountMinor)
        return overflow ? Int64.max : sum
      }
    }

    private func partyStatusSubtitle(_ partyID: UUID?) -> String {
      guard let partyID,
        let party = editing?.parties.first(where: { $0.id == partyID })
      else { return "新主体 · 尚未到账" }
      return "\(party.statusTitle) · 已到账 \(Money(minorUnits: party.receivedMinor).formatted())"
    }

    private func allocationReceivedMinor(_ allocationID: UUID?) -> Int64 {
      guard let allocationID else { return 0 }
      return editing?.parties.flatMap(\.allocations)
        .first(where: { $0.id == allocationID })?.receivedMinor ?? 0
    }

    private func nextExpenseHint(for party: Binding<ReimbursementPartyDraft>) -> String {
      guard let option = nextExpenseOption(for: party) else { return "没有更多可分配垫付" }
      return "可用 \(Money(minorUnits: option.availableMinor).formatted())"
    }
  #endif

  private struct EditorExpenseOption: Identifiable {
    var id: UUID { transactionID }
    let transactionID: UUID
    let title: String
    let availableMinor: Int64
  }

  private var editorExpenseOptions: [EditorExpenseOption] {
    let originalAllocations = editing?.parties.flatMap(\.allocations) ?? []
    let originalTotals = Dictionary(grouping: originalAllocations, by: \.transactionID)
      .mapValues { rows in rows.reduce(0) { $0 + $1.amountMinor } }
    var values = model.expenseOptions.map { option in
      EditorExpenseOption(
        transactionID: option.transactionID, title: option.title,
        availableMinor: option.availableMinor + (originalTotals[option.transactionID] ?? 0))
    }
    let known = Set(values.map(\.transactionID))
    for (transactionID, rows) in originalTotals where !known.contains(transactionID) {
      values.append(
        .init(
          transactionID: transactionID,
          title: originalAllocations.first(where: { $0.transactionID == transactionID })?
            .expenseTitle ?? "历史垫付",
          availableMinor: rows))
    }
    return values
  }

  private func selectableExpenseOptions(
    for party: ReimbursementPartyDraft, current: UUID
  ) -> [EditorExpenseOption] {
    let used = Set(
      party.allocations.lazy.filter { $0.transactionID != current }.map(\.transactionID))
    return editorExpenseOptions.filter { !used.contains($0.transactionID) }
  }

  private func nextExpenseOption(
    for party: Binding<ReimbursementPartyDraft>
  ) -> EditorExpenseOption? {
    let used = Set(party.wrappedValue.allocations.map(\.transactionID))
    return editorExpenseOptions.first { !used.contains($0.transactionID) }
  }

  private func appendAllocation(to party: Binding<ReimbursementPartyDraft>) {
    guard let option = nextExpenseOption(for: party) else { return }
    let allocation = ReimbursementAllocationDraft(
      id: nil, transactionID: option.transactionID, amountMinor: option.availableMinor)
    party.wrappedValue.allocations.append(allocation)
    amountTexts[allocation.id] = Self.yuanText(minorUnits: allocation.amountMinor)
  }

  private func amountTextBinding(
    _ allocation: Binding<ReimbursementAllocationDraft>, minimum: Int64
  ) -> Binding<String> {
    Binding(
      get: {
        amountTexts[allocation.wrappedValue.id]
          ?? Self.yuanText(minorUnits: allocation.wrappedValue.amountMinor)
      },
      set: { text in
        amountTexts[allocation.wrappedValue.id] = text
        if let value = Self.validatedAmount(text: text, minimum: minimum) {
          allocation.wrappedValue.amountMinor = value
        }
      })
  }

  private func amountIsValid(_ allocation: ReimbursementAllocationDraft) -> Bool {
    let text = amountTexts[allocation.id] ?? Self.yuanText(minorUnits: allocation.amountMinor)
    return Self.validatedAmount(
      text: text, minimum: lockedReceivedMinor(allocation.serverID)) != nil
  }

  static func validatedAmount(text: String, minimum: Int64) -> Int64? {
    guard let value = CNYAmountParser.minorUnits(text), value > 0, value >= minimum else {
      return nil
    }
    return value
  }

  static func yuanText(minorUnits: Int64) -> String {
    NSDecimalNumber(decimal: Decimal(minorUnits) / 100).stringValue
  }

  private var valid: Bool {
    !title.trimmingCharacters(in: .whitespaces).isEmpty && !parties.isEmpty
      && parties.allSatisfy {
        !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && !$0.allocations.isEmpty
          && ($0.expectedDate == nil || Self.isValidISODate($0.expectedDate!))
          && Set($0.allocations.map(\.transactionID)).count == $0.allocations.count
          && $0.allocations.allSatisfy(amountIsValid)
      }
  }

  static func isValidISODate(_ text: String) -> Bool {
    guard text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil
    else { return false }
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    guard let date = formatter.date(from: text) else { return false }
    return formatter.string(from: date) == text
  }
  private var createRequest: ReimbursementClaimCreateRequest {
    .init(title: title, note: note.isEmpty ? nil : note, parties: parties)
  }
  private var replacement: ReimbursementClaimReplacementRequest? {
    editing.map {
      .init(
        expectedVersion: model.selectedClaim?.version ?? $0.version, title: title,
        note: note.isEmpty ? nil : note, parties: parties)
    }
  }
  private func existingExpenseTitle(_ transactionID: UUID) -> String {
    editing?.parties.flatMap(\.allocations).first(where: { $0.transactionID == transactionID })?
      .expenseTitle ?? "历史垫付"
  }
  private func canRemoveParty(_ partyID: UUID?) -> Bool {
    guard !matrixFrozen else { return false }
    guard let partyID else { return true }
    return editing?.parties.first(where: { $0.id == partyID })?.receivedMinor == 0
  }
  private var matrixFrozen: Bool { editing?.cancelledAt != nil }
  private func isLockedAllocation(_ allocationID: UUID?) -> Bool {
    guard let allocationID else { return false }
    return editing?.parties.flatMap(\.allocations).first(where: { $0.id == allocationID })?.locked
      == true
  }
  private func lockedReceivedMinor(_ allocationID: UUID?) -> Int64 {
    Self.minimumAllocationAmount(allocationID: allocationID, editing: editing)
  }
  static func minimumAllocationAmount(
    allocationID: UUID?, editing: ReimbursementClaimDTO?
  ) -> Int64 {
    guard let allocationID else { return 0 }
    return editing?.parties.flatMap(\.allocations).first(where: { $0.id == allocationID })?
      .receivedMinor ?? 0
  }
  static func clampedAllocationAmount(
    _ proposed: Int64, allocationID: UUID?, editing: ReimbursementClaimDTO?
  ) -> Int64 {
    max(minimumAllocationAmount(allocationID: allocationID, editing: editing), proposed)
  }
  private func create() { Task { if await model.create(createRequest) != nil { dismiss() } } }
  private func preview() {
    guard let replacement else { return }
    Task { _ = await model.preview(replacement) }
  }
  private func update() {
    guard let replacement else { return }
    Task { if await model.update(replacement) { dismiss() } }
  }
}

#if os(macOS)
  public struct MacReimbursementsScreen: View {
    @Bindable var model: ReimbursementModel
    let accounts: AccountsModel
    @State private var selectedID: UUID?
    @State private var showCreate = false
    @State private var showEdit = false
    @State private var showReceipt = false
    @State private var showCancelConfirmation = false
    public init(model: ReimbursementModel, accounts: AccountsModel) {
      self.model = model
      self.accounts = accounts
    }
    public var body: some View {
      VStack(spacing: 0) {
        HStack {
          Text("报销").font(.system(size: 22, weight: .bold))
          Spacer()
          Picker("状态", selection: $model.statusFilter) {
            Text("全部状态").tag(Optional<ReimbursementClaimStatus>.none)
            ForEach(ReimbursementClaimStatus.allCases, id: \.self) {
              Text($0.title).tag(Optional($0))
            }
          }.frame(width: 150)
          Button("新建报销单", systemImage: "plus") { showCreate = true }.buttonStyle(.borderedProminent)
        }.padding(.horizontal, 20).frame(height: 54).background(FiscalColor.surface)
        HStack(spacing: 0) {
          claimList.frame(width: 285)
          Divider()
          detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }.background(FiscalColor.macBackground).task { await model.load() }.onChange(
        of: model.statusFilter
      ) { _, _ in Task { await model.load() } }.sheet(isPresented: $showCreate) {
        ReimbursementClaimEditor(model: model, editing: nil)
      }.sheet(isPresented: $showEdit) {
        if let claim = model.selectedClaim {
          ReimbursementClaimEditor(model: model, editing: claim)
        }
      }.sheet(isPresented: $showReceipt) {
        if let claim = model.selectedClaim {
          ReimbursementReceiptEditor(model: model, accounts: accounts, claim: claim)
        }
      }.confirmationDialog(
        "确认取消未回款？", isPresented: $showCancelConfirmation, titleVisibility: .visible
      ) {
        Button("确认取消", role: .destructive) {
          Task { _ = await model.confirmCancel() }
        }
        Button("返回", role: .cancel) {}
      } message: {
        if let preview = model.cancelPreview {
          Text(
            "释放 \(Money(minorUnits: preview.releasedMinor).formatted())；保留已到账 \(Money(minorUnits: preview.retainedReceivedMinor).formatted())。"
          )
        }
      }
    }
    private var claimList: some View {
      ScrollView {
        LazyVStack(spacing: 10) {
          ForEach(model.claims) { claim in
            Button {
              selectedID = claim.id
              Task { await model.loadClaim(claim.id) }
            } label: {
              VStack(alignment: .leading, spacing: 9) {
                HStack {
                  Text(claim.title).font(.headline)
                  Spacer()
                  ReimbursementStatusPill(status: claim.status)
                }
                Text("\(claim.expenseCount) 笔垫付 · \(claim.partyCount) 个主体").font(.caption)
                  .foregroundStyle(FiscalColor.tertiary)
                HStack {
                  Text("待回款")
                  Spacer()
                  Text(Money(minorUnits: claim.outstandingMinor).formatted()).fontWeight(.semibold)
                    .foregroundStyle(FiscalColor.reimbursement)
                }.font(.caption)
              }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(
                selectedID == claim.id ? FiscalColor.accent.opacity(0.10) : FiscalColor.surface,
                in: .rect(cornerRadius: 13))
            }.buttonStyle(.plain).task {
              if claim.id == model.claims.last?.id { await model.loadMore() }
            }
          }
        }.padding(14)
      }.background(FiscalColor.macBackground)
    }
    @ViewBuilder private var detail: some View {
      if let claim = model.selectedClaim, claim.id == selectedID {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            HStack {
              VStack(alignment: .leading) {
                Text(claim.title).font(.title2.bold())
                Text("主体 × 垫付矩阵").font(.caption).foregroundStyle(FiscalColor.tertiary)
              }
              Spacer()
              if claim.archivedAt == nil && claim.voidedAt == nil {
                Button("编辑") { showEdit = true }.buttonStyle(.bordered)
              }
              lifecycleMenu(claim)
              if claim.outstandingMinor > 0 && claim.cancelledAt == nil && claim.archivedAt == nil
                && claim.voidedAt == nil
              {
                Button("登记到账") { showReceipt = true }.buttonStyle(.borderedProminent).tint(
                  FiscalColor.reimbursement)
              }
            }
            FiscalCard(radius: 16) { ReimbursementTotals(claim: claim) }
            if claim.archivedAt != nil {
              Label("已归档 · 只读", systemImage: "archivebox").foregroundStyle(FiscalColor.tertiary)
            }
            if claim.voidedAt != nil {
              Label("已作废 · 只读", systemImage: "nosign").foregroundStyle(FiscalColor.tertiary)
            }
            matrix(claim)
            HStack(alignment: .top, spacing: 16) {
              receipts(claim)
              scope(claim)
            }
          }.padding(20)
        }
      } else {
        ContentUnavailableView(
          "选择报销单", systemImage: "doc.text", description: Text("查看付款主体、垫付矩阵和真实回款。"))
      }
    }
    private func matrix(_ claim: ReimbursementClaimDTO) -> some View {
      FiscalCard(radius: 16) {
        VStack(alignment: .leading, spacing: 0) {
          Text("付款主体与关联垫付").font(.headline).padding(.bottom, 10)
          HStack {
            Text("主体 / 垫付").frame(maxWidth: .infinity, alignment: .leading)
            Text("应付").frame(width: 100, alignment: .trailing)
            Text("已到账").frame(width: 100, alignment: .trailing)
            Text("待回").frame(width: 100, alignment: .trailing)
          }.font(.caption.bold()).foregroundStyle(FiscalColor.tertiary)
          ForEach(claim.parties) { party in
            VStack(spacing: 0) {
              HStack {
                Text(party.name).fontWeight(.semibold).frame(
                  maxWidth: .infinity, alignment: .leading)
                Text(Money(minorUnits: party.claimedMinor).formatted()).frame(
                  width: 100, alignment: .trailing)
                Text(Money(minorUnits: party.receivedMinor).formatted()).foregroundStyle(
                  FiscalColor.income
                ).frame(width: 100, alignment: .trailing)
                Text(Money(minorUnits: party.outstandingMinor).formatted()).foregroundStyle(
                  FiscalColor.reimbursement
                ).frame(width: 100, alignment: .trailing)
              }.padding(.vertical, 9)
              ForEach(party.allocations) { allocation in
                HStack {
                  Text("↳ " + allocation.expenseTitle + (allocation.locked ? "  🔒" : ""))
                    .foregroundStyle(FiscalColor.secondary).frame(
                      maxWidth: .infinity, alignment: .leading)
                  Text(Money(minorUnits: allocation.amountMinor).formatted()).frame(
                    width: 100, alignment: .trailing)
                  Text(Money(minorUnits: allocation.receivedMinor).formatted()).frame(
                    width: 100, alignment: .trailing)
                  Text(Money(minorUnits: allocation.outstandingMinor).formatted()).frame(
                    width: 100, alignment: .trailing)
                }.font(.caption).padding(.vertical, 6)
              }
              Divider()
            }
          }
        }
      }
    }
    private func receipts(_ claim: ReimbursementClaimDTO) -> some View {
      FiscalCard(radius: 16) {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Text("回款记录").font(.headline)
            Spacer()
            Text("\(claim.receiptCount) 笔").font(.caption).foregroundStyle(FiscalColor.tertiary)
          }
          ForEach(model.receiptHistory) { receipt in
            HStack {
              VStack(alignment: .leading) {
                Text(receipt.title)
                Text(receipt.receivedAt.formatted(date: .abbreviated, time: .omitted)).font(
                  .caption
                ).foregroundStyle(FiscalColor.tertiary)
              }
              Spacer()
              Text("+" + Money(minorUnits: receipt.amountMinor).formatted()).foregroundStyle(
                receipt.voidedAt == nil ? FiscalColor.income : FiscalColor.tertiary)
            }.task {
              if receipt.id == model.receiptHistory.last?.id {
                await model.loadMoreReceipts(claimID: claim.id)
              }
            }
          }
        }
      }.frame(maxWidth: .infinity, alignment: .top)
    }
    private func scope(_ claim: ReimbursementClaimDTO) -> some View {
      FiscalCard(radius: 16) {
        VStack(alignment: .leading, spacing: 10) {
          Text("支出口径").font(.headline)
          Text("预计与实际个人承担分别按有效分配和真实到账计算。").font(.caption).foregroundStyle(FiscalColor.secondary)
          Text("到账进入现金流，不重复计普通收入。").font(.caption).foregroundStyle(FiscalColor.reimbursement)
        }
      }.frame(width: 230, alignment: .top)
    }
    private func lifecycleMenu(_ claim: ReimbursementClaimDTO) -> some View {
      Menu {
        if claim.archivedAt != nil {
          Button("取消归档") { Task { _ = await model.lifecycle("unarchive") } }
        } else if claim.voidedAt != nil {
          Button("恢复报销单") { Task { _ = await model.lifecycle("restore") } }
        } else {
          if claim.status == .draft {
            Button("提交") { Task { _ = await model.lifecycle("submit") } }
            if claim.receiptCount == 0 {
              Button("作废", role: .destructive) { Task { _ = await model.lifecycle("void") } }
            }
          }
          if claim.status == .pending {
            Button("撤回提交") { Task { _ = await model.lifecycle("retract-submission") } }
          }
          if claim.status == .pending || claim.status == .partialReceived {
            Button("取消未回款", role: .destructive) {
              Task { if await model.previewCancellation() { showCancelConfirmation = true } }
            }
          }
          if claim.status == .cancelled || claim.status == .partiallyReceivedCancelled {
            Button("重新开启") { Task { _ = await model.lifecycle("reopen") } }
          }
          if claim.status.isTerminal {
            Button("归档") { Task { _ = await model.lifecycle("archive") } }
          }
        }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
    }
  }
#endif

extension View {
  @ViewBuilder fileprivate func reimbursementEditorFrame(width: CGFloat, height: CGFloat)
    -> some View
  {
    #if os(macOS)
      frame(width: width, height: height)
    #else
      self
    #endif
  }
}
