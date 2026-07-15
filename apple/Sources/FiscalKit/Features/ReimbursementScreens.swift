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
        .monospacedDigit()
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
            }.padding(16).padding(.bottom, 100)
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
        model.statusFilter == status ? FiscalColor.accent : Color(hex: 0xDDE2EA)
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
          .monospacedDigit()
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
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(FiscalColor.tertiary)
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
            }.padding(16).padding(.bottom, 100)
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
                  .monospacedDigit()
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
              ).monospacedDigit()
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
        Text(Money(minorUnits: amount).formatted()).font(.caption.bold()).monospacedDigit()
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
      Form {
        Section("到账信息") {
          Picker("付款主体", selection: $partyID) {
            Text("请选择").tag(Optional<UUID>.none)
            ForEach(claim.parties.filter { $0.outstandingMinor > 0 || $0.id == editing?.partyID }) {
              Text("\($0.name) · 待回 \(Money(minorUnits: $0.outstandingMinor).formatted())").tag(
                Optional($0.id))
            }
          }
          Picker("到账账户", selection: $accountID) {
            Text("请选择").tag(Optional<UUID>.none)
            ForEach(
              options.filter {
                $0.kind == .cash || $0.kind == .debit || $0.id == editing?.destinationAccountID
              }
            ) { Text($0.name).tag(Optional($0.id)) }
          }
          TextField("金额（分）", text: $amount)
            .focused($focusedField, equals: .amount)
            #if os(iOS)
              .keyboardType(.numberPad)
            #endif
          DatePicker("到账时间", selection: $receivedAt, in: ...Date())
          TextField("标题", text: $title).focused($focusedField, equals: .title)
          TextField("备注", text: $note).focused($focusedField, equals: .note)
        }
        if let preview = model.receiptPreview {
          Section("服务器确认") {
            LabeledContent(
              "主体到账前", value: Money(minorUnits: preview.partyReceivedBeforeMinor).formatted())
            LabeledContent(
              "主体到账后", value: Money(minorUnits: preview.partyReceivedAfterMinor).formatted())
            LabeledContent(
              "本单到账前", value: Money(minorUnits: preview.claimReceivedBeforeMinor).formatted())
            LabeledContent(
              "本单到账后", value: Money(minorUnits: preview.claimReceivedAfterMinor).formatted())
            Text("将按服务器稳定顺序分配到 \(preview.persistedAllocations.count) 个主体 × 支出矩阵行。")
          }
        }
        if let message = model.message {
          Section {
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(
              FiscalColor.expense)
          }
        }
      }.navigationTitle(editing == nil ? "登记到账" : "编辑到账").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          if model.receiptPreview == nil {
            Button("预览影响") { preview() }.disabled(request == nil)
          } else {
            Button(editing == nil ? "确认到账" : "确认保存") { commit() }.disabled(model.isMutating)
          }
        }
        #if os(iOS)
          ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("完成") { focusedField = nil }
          }
        #endif
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
  public init(model: ReimbursementModel, editing: ReimbursementClaimDTO?) {
    self.model = model
    self.editing = editing
    _title = State(initialValue: editing?.title ?? "")
    _note = State(initialValue: editing?.note ?? "")
    _parties = State(
      initialValue: editing?.parties.map {
        .init(
          id: $0.id, name: $0.name, expectedDate: $0.expectedDate, note: $0.note,
          allocations: $0.allocations.map {
            .init(id: $0.id, transactionID: $0.transactionID, amountMinor: $0.amountMinor)
          })
      } ?? [.init(id: nil, name: "", expectedDate: nil, note: nil, allocations: [])])
  }
  public var body: some View {
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
                      Text(Money(minorUnits: allocation.amountMinor).formatted()).monospacedDigit()
                    }
                  } else if isLockedAllocation(allocation.serverID) {
                    HStack {
                      Label(
                        existingExpenseTitle(allocation.transactionID), systemImage: "lock.fill"
                      )
                      .foregroundStyle(FiscalColor.secondary)
                      Spacer()
                      TextField(
                        "金额（分）",
                        value: lockedAmountBinding($allocation), format: .number
                      )
                      .frame(width: 120)
                      Text("最低 \(lockedReceivedMinor(allocation.serverID)) 分")
                        .font(.caption)
                        .foregroundStyle(FiscalColor.tertiary)
                    }
                  } else {
                    HStack {
                      Picker("关联垫付", selection: $allocation.transactionID) {
                        if !model.expenseOptions.contains(where: {
                          $0.transactionID == allocation.transactionID
                        }) {
                          Text(existingExpenseTitle(allocation.transactionID)).tag(
                            allocation.transactionID)
                        }
                        ForEach(model.expenseOptions) {
                          Text(
                            "\($0.title) · 可用 \(Money(minorUnits: $0.availableMinor).formatted())"
                          )
                          .tag($0.transactionID)
                        }
                      }
                      TextField("金额（分）", value: $allocation.amountMinor, format: .number).frame(
                        width: 120)
                    }
                  }
                }
                if !matrixFrozen {
                  Button("添加垫付") {
                    if let option = model.expenseOptions.first {
                      party.allocations.append(
                        .init(
                          id: nil, transactionID: option.transactionID,
                          amountMinor: option.availableMinor))
                    }
                  }.disabled(model.expenseOptions.isEmpty)
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
  private var valid: Bool {
    !title.trimmingCharacters(in: .whitespaces).isEmpty && !parties.isEmpty
      && parties.allSatisfy {
        !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && !$0.allocations.isEmpty
          && $0.allocations.allSatisfy {
            $0.amountMinor > 0 && $0.amountMinor >= lockedReceivedMinor($0.serverID)
          }
      }
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
  private func lockedAmountBinding(_ allocation: Binding<ReimbursementAllocationDraft>) -> Binding<
    Int64
  > {
    return Binding(
      get: { allocation.wrappedValue.amountMinor },
      set: {
        allocation.wrappedValue.amountMinor = Self.clampedAllocationAmount(
          $0, allocationID: allocation.wrappedValue.serverID, editing: editing)
      })
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
        }.padding(.horizontal, 20).frame(height: 54).background(.white)
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
                selectedID == claim.id ? FiscalColor.accent.opacity(0.10) : .white,
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
