import SwiftUI

#if os(iOS)
public struct IOSFutureCashFlowScreen: View {
  @Bindable var model: FutureCashFlowModel
  let accounts: AccountsModel
  let categories: CategoriesModel
  let confirmRepayment: (FutureCashFlowItem) -> Void
  let markReceived: (FutureCashFlowItem) -> Void
  @State private var editor: CashFlowEditorTarget?
  @State private var settling: FutureCashFlowItem?

  public init(
    model: FutureCashFlowModel, accounts: AccountsModel, categories: CategoriesModel,
    confirmRepayment: @escaping (FutureCashFlowItem) -> Void,
    markReceived: @escaping (FutureCashFlowItem) -> Void
  ) {
    self.model = model; self.accounts = accounts; self.categories = categories
    self.confirmRepayment = confirmRepayment; self.markReceived = markReceived
  }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if model.showingHistory { historyBody } else { activeBody }
      }.padding(16).padding(.bottom, 32)
    }
    .background(FiscalColor.iOSBackground.ignoresSafeArea())
    .navigationTitle(model.showingHistory ? "现金流历史" : "现金流")
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button(model.showingHistory ? "待处理" : "历史") {
          model.showingHistory.toggle()
          if model.showingHistory { Task { await model.loadHistory() } }
        }
      }
      if !model.showingHistory {
        ToolbarItem(placement: .topBarTrailing) {
          Button { editor = .new } label: { Label("新建计划", systemImage: "plus") }
        }
      }
    }
    .refreshable { if model.showingHistory { await model.loadHistory() } else { await model.load() } }
    .task { await model.load() }
    .sheet(item: $editor) { target in
      editorSheet(target)
    }
    .sheet(item: $settling) { item in
      CashFlowSettlementSheet(model: model, accounts: accounts, categories: categories, item: item)
    }
  }

  @ViewBuilder private func editorSheet(_ target: CashFlowEditorTarget) -> some View {
    if let item = target.systemItem {
      CashFlowSystemEditorSheet(model: model, item: item)
    } else {
      CashFlowEditorSheet(
        model: model, accounts: accounts, categories: categories,
        item: target.manualItem)
    }
  }

  @ViewBuilder private var activeBody: some View {
    if let value = model.active {
      summary(value.summary)
      Text("全部待处理").font(.headline)
      if value.items.isEmpty {
        ContentUnavailableView(
          "没有待处理事项", systemImage: "calendar.badge.checkmark",
          description: Text("新建未来收入、支出或转账计划。"))
      } else {
        FiscalCard(radius: 20) { rows(value.items) }
      }
    } else if model.phase == .loading { ProgressView().frame(maxWidth: .infinity).padding(80) }
    else { ContentUnavailableView("现金流暂不可用", systemImage: "arrow.up.arrow.down") }
    if let message = model.message { Text(message).font(.caption).foregroundStyle(FiscalColor.expense) }
  }

  @ViewBuilder private var historyBody: some View {
    HStack {
      Button { Task { await model.moveHistoryMonth(-1) } } label: { Image(systemName: "chevron.left") }
      Spacer(); Text(model.historyMonth).font(.headline).fontDesign(.rounded); Spacer()
      Button { Task { await model.moveHistoryMonth(1) } } label: { Image(systemName: "chevron.right") }
    }.padding(.horizontal, 4)
    if let history = model.history, !history.items.isEmpty {
      FiscalCard(radius: 20) { rows(history.items) }
    } else {
      ContentUnavailableView("本月没有历史记录", systemImage: "clock.arrow.circlepath")
    }
  }

  private func summary(_ value: FutureCashFlowSummary) -> some View {
    HStack(spacing: 10) {
      summaryCell("预计流入", value.inflowMinor, FiscalColor.income)
      summaryCell("预计流出", value.outflowMinor, FiscalColor.expense)
      summaryCell("净额", value.netMinor, value.netMinor >= 0 ? FiscalColor.income : FiscalColor.expense)
    }
  }

  private func summaryCell(_ title: String, _ amount: Int64, _ color: Color) -> some View {
    FiscalCard(radius: 16) {
      VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.caption).foregroundStyle(FiscalColor.tertiary)
        Text(Money(minorUnits: amount).formatted()).font(.subheadline.bold()).fontDesign(.rounded)
          .foregroundStyle(color).minimumScaleFactor(0.7).lineLimit(1)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func rows(_ items: [FutureCashFlowItem]) -> some View {
    VStack(spacing: 0) {
      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        if index > 0 { Divider().padding(.leading, 48).opacity(0.4) }
        CashFlowItemRow(
          item: item, edit: { editor = item.systemKind == nil ? .manual(item) : .system(item) }, settle: { settling = item },
          confirm: { Task { await model.confirm(item) } },
          cancel: { Task { await model.cancel(item, scope: .occurrence) } },
          confirmRepayment: { confirmRepayment(item) }, markReceived: { markReceived(item) })
      }
    }
  }
}
#endif

#if os(macOS)
public struct MacFutureCashFlowScreen: View {
  @Bindable var model: FutureCashFlowModel
  let accounts: AccountsModel
  let categories: CategoriesModel
  let confirmRepayment: (FutureCashFlowItem) -> Void
  let markReceived: (FutureCashFlowItem) -> Void
  @State private var editor: CashFlowEditorTarget?
  @State private var settling: FutureCashFlowItem?

  public init(
    model: FutureCashFlowModel, accounts: AccountsModel, categories: CategoriesModel,
    confirmRepayment: @escaping (FutureCashFlowItem) -> Void,
    markReceived: @escaping (FutureCashFlowItem) -> Void
  ) {
    self.model = model; self.accounts = accounts; self.categories = categories
    self.confirmRepayment = confirmRepayment; self.markReceived = markReceived
  }

  public var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(model.showingHistory ? "现金流历史" : "现金流").font(.system(size: 22, weight: .bold))
          Text(model.showingHistory ? "已入账与已取消" : "未来会发生并等待入账的事项")
            .font(.caption).foregroundStyle(FiscalColor.tertiary)
        }
        Spacer()
        Button(model.showingHistory ? "返回待处理" : "历史") {
          model.showingHistory.toggle()
          if model.showingHistory { Task { await model.loadHistory() } }
        }
        if !model.showingHistory {
          Button { editor = .new } label: { Label("新建计划", systemImage: "plus") }
            .buttonStyle(.borderedProminent)
        }
      }.padding(.horizontal, 20).frame(height: 64).background(FiscalColor.surface)
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if model.showingHistory { historyBody } else { activeBody }
        }.padding(18).frame(maxWidth: 1_240)
      }
    }.background(FiscalColor.macBackground)
      .task { await model.load() }
      .sheet(item: $editor) { target in
        editorSheet(target)
      }
      .sheet(item: $settling) { item in
        CashFlowSettlementSheet(model: model, accounts: accounts, categories: categories, item: item)
          .frame(width: 520, height: 520)
      }
  }

  @ViewBuilder private func editorSheet(_ target: CashFlowEditorTarget) -> some View {
    if let item = target.systemItem {
      CashFlowSystemEditorSheet(model: model, item: item)
        .frame(width: 520, height: 430)
    } else {
      CashFlowEditorSheet(
        model: model, accounts: accounts, categories: categories,
        item: target.manualItem)
        .frame(width: 560, height: 650)
    }
  }

  @ViewBuilder private var activeBody: some View {
    if let value = model.active {
      HStack(spacing: 14) {
        metric("未来 30 天预计流入", value.summary.inflowMinor, FiscalColor.income)
        metric("未来 30 天预计流出", value.summary.outflowMinor, FiscalColor.expense)
        metric("未来 30 天净额", value.summary.netMinor, value.summary.netMinor >= 0 ? FiscalColor.income : FiscalColor.expense)
      }
      Text("全部待处理").font(.headline)
      FiscalCard(radius: 15) {
        if value.items.isEmpty { ContentUnavailableView("没有待处理事项", systemImage: "calendar.badge.checkmark") }
        else { rows(value.items) }
      }
    } else { ProgressView().frame(maxWidth: .infinity).padding(120) }
    if let message = model.message { Text(message).foregroundStyle(FiscalColor.expense) }
  }

  @ViewBuilder private var historyBody: some View {
    HStack {
      Button { Task { await model.moveHistoryMonth(-1) } } label: { Image(systemName: "chevron.left") }
      Text(model.historyMonth).font(.headline).fontDesign(.rounded)
      Button { Task { await model.moveHistoryMonth(1) } } label: { Image(systemName: "chevron.right") }
    }
    FiscalCard(radius: 15) {
      if let history = model.history, !history.items.isEmpty { rows(history.items) }
      else { ContentUnavailableView("本月没有历史记录", systemImage: "clock.arrow.circlepath") }
    }
  }

  private func metric(_ title: String, _ amount: Int64, _ color: Color) -> some View {
    FiscalCard(radius: 15) {
      VStack(alignment: .leading, spacing: 7) {
        Text(title).font(.caption).foregroundStyle(FiscalColor.tertiary)
        Text(Money(minorUnits: amount).formatted()).font(.title2.bold()).fontDesign(.rounded).foregroundStyle(color)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func rows(_ items: [FutureCashFlowItem]) -> some View {
    VStack(spacing: 0) {
      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        if index > 0 { Divider().padding(.leading, 50).opacity(0.4) }
        CashFlowItemRow(
          item: item, edit: { editor = item.systemKind == nil ? .manual(item) : .system(item) }, settle: { settling = item },
          confirm: { Task { await model.confirm(item) } },
          cancel: { Task { await model.cancel(item, scope: .occurrence) } },
          confirmRepayment: { confirmRepayment(item) }, markReceived: { markReceived(item) })
      }
    }
  }
}
#endif

private struct CashFlowItemRow: View {
  let item: FutureCashFlowItem
  let edit: () -> Void
  let settle: () -> Void
  let confirm: () -> Void
  let cancel: () -> Void
  let confirmRepayment: () -> Void
  let markReceived: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        FiscalIconTile(item.direction.symbol, color: color)
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            if item.isOverdue { Text("逾期").font(.caption2.bold()).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2).background(FiscalColor.expense, in: .capsule) }
          }
          Text("\(item.expectedDate) · \(item.status.title)").font(.caption).foregroundStyle(FiscalColor.tertiary)
        }
        Spacer()
        Text(Money(minorUnits: item.plannedAmountMinor).formatted(showPositiveSign: item.direction == .inflow))
          .font(.subheadline.bold()).fontDesign(.rounded).foregroundStyle(color)
      }
      HStack { Spacer(); actions }
    }.padding(.vertical, 10).contentShape(.rect)
  }

  @ViewBuilder private var actions: some View {
    HStack(spacing: 8) {
      if item.actions.contains(.confirm) { Button("确认", action: confirm) }
      if item.actions.contains(.settle) { Button("入账", action: settle).buttonStyle(.borderedProminent) }
      if item.actions.contains(.confirmRepayment) { Button("确认还款", action: confirmRepayment).buttonStyle(.borderedProminent) }
      if item.actions.contains(.markReceived) { Button("标记到账", action: markReceived).buttonStyle(.borderedProminent) }
      if item.actions.contains(.edit) { Button("编辑", action: edit).buttonStyle(.bordered) }
      if item.actions.contains(.cancel) {
        Menu {
          Button("取消事项", role: .destructive, action: cancel)
        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton)
      }
      if let transactionID = item.linkedTransactionID {
        Text("流水 \(transactionID.uuidString.prefix(6))").font(.caption2).foregroundStyle(FiscalColor.tertiary)
      }
    }.controlSize(.small)
  }
  private var color: Color { item.direction == .inflow ? FiscalColor.income : item.direction == .outflow ? FiscalColor.expense : FiscalColor.accent }
}

private enum CashFlowEditorTarget: Identifiable {
  case new, manual(FutureCashFlowItem), system(FutureCashFlowItem)
  var id: String { switch self { case .new: "new"; case .manual(let item), .system(let item): item.id } }
  var manualItem: FutureCashFlowItem? { if case .manual(let item) = self { item } else { nil } }
  var systemItem: FutureCashFlowItem? { if case .system(let item) = self { item } else { nil } }
}

private struct CashFlowSystemEditorSheet: View {
  @Environment(\.dismiss) private var dismiss
  let model: FutureCashFlowModel
  let item: FutureCashFlowItem
  @State private var title: String
  @State private var note: String
  @State private var amount: String
  @State private var expectedDate: Date
  @State private var status: FutureCashFlowStatus
  @State private var validation: String?

  init(model: FutureCashFlowModel, item: FutureCashFlowItem) {
    self.model = model; self.item = item
    _title = State(initialValue: item.title)
    _note = State(initialValue: item.note ?? "")
    _amount = State(initialValue: String(format: "%.2f", Double(item.plannedAmountMinor) / 100))
    _expectedDate = State(initialValue: FutureCashFlowModel.date(item.expectedDate) ?? Date())
    _status = State(initialValue: item.status == .completed ? .completed : .confirmed)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("事项") {
          TextField("名称", text: $title)
          TextField("预计金额", text: $amount)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
          DatePicker("预计日期", selection: $expectedDate, displayedComponents: .date)
          TextField("备注（可选）", text: $note, axis: .vertical).lineLimit(2...4)
        }
        Section("状态") {
          Picker("处理状态", selection: $status) {
            Text("待处理").tag(FutureCashFlowStatus.confirmed)
            Text("已完成").tag(FutureCashFlowStatus.completed)
          }.pickerStyle(.segmented)
          Text(status == .completed ? "移入历史，不生成流水，也不改变账户余额。" : "重新显示在待处理列表中。")
            .font(.caption).foregroundStyle(FiscalColor.tertiary)
        }
        if let validation { Text(validation).foregroundStyle(FiscalColor.expense) }
      }
      .navigationTitle("编辑现金流")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("保存") { Task { await save() } }.disabled(model.isMutating)
        }
      }
    }
  }

  private func save() async {
    let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty, let minor = CNYAmountParser.minorUnits(amount), minor > 0 else {
      validation = "请填写名称和正确金额。"; return
    }
    let success = await model.updateSystem(
      item, title: cleaned,
      note: note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note,
      amountMinor: minor, expectedDate: FutureCashFlowModel.dayString(expectedDate),
      status: status)
    if success { dismiss() } else { validation = model.message }
  }
}

private struct CashFlowEditorSheet: View {
  @Environment(\.dismiss) private var dismiss
  let model: FutureCashFlowModel
  let accounts: AccountsModel
  let categories: CategoriesModel
  let item: FutureCashFlowItem?
  @State private var title = ""
  @State private var amount = ""
  @State private var direction: FutureCashFlowDirection = .inflow
  @State private var expectedDate = Date()
  @State private var accountID: UUID?
  @State private var destinationID: UUID?
  @State private var categoryID: UUID?
  @State private var monthly = false
  @State private var endDate = Date()
  @State private var scope: FutureCashFlowMutationScope = .occurrence
  @State private var accountOptions: [AccountDTO] = []
  @State private var categoryOptions: [CategoryDTO] = []
  @State private var validation: String?

  var body: some View {
    NavigationStack {
      Form {
        Section("事项") {
          TextField("名称", text: $title)
          Picker("方向", selection: $direction) { ForEach(FutureCashFlowDirection.allCases) { Text($0.title).tag($0) } }
            .onChange(of: direction) { _, value in
              if value == .transfer {
                categoryID = nil
              } else {
                destinationID = nil
                if !matchingCategories.contains(where: { $0.id == categoryID }) {
                  categoryID = nil
                }
              }
            }
          TextField("预计金额", text: $amount)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
          DatePicker("预计日期", selection: $expectedDate, displayedComponents: .date)
        }
        Section("归属") {
          Picker("账户", selection: $accountID) { Text("稍后填写").tag(UUID?.none); ForEach(cashAccounts) { Text($0.name).tag(Optional($0.id)) } }
          if direction == .transfer { Picker("转入账户", selection: $destinationID) { Text("请选择").tag(UUID?.none); ForEach(cashAccounts) { Text($0.name).tag(Optional($0.id)) } } }
          else { Picker("分类", selection: $categoryID) { Text("稍后填写").tag(UUID?.none); ForEach(matchingCategories) { Text($0.name).tag(Optional($0.id)) } } }
        }
        if item == nil {
          Section("计划") { Toggle("每月重复", isOn: $monthly); if monthly { DatePicker("结束日期", selection: $endDate, displayedComponents: .date) } }
        } else if item?.seriesID != nil && item?.status != .settled && item?.status != .cancelled {
          Section("修改范围") {
            Picker("范围", selection: $scope) {
              Text("仅本次").tag(FutureCashFlowMutationScope.occurrence)
              Text("本次及以后").tag(FutureCashFlowMutationScope.thisAndFuture)
            }
            if scope == .thisAndFuture {
              Text("方向、金额等会应用到后续期次；日期按原来的每月间隔顺延，不会复制成同一天。")
                .font(.caption).foregroundStyle(FiscalColor.tertiary)
            }
          }
        }
        if let validation { Text(validation).foregroundStyle(FiscalColor.expense) }
      }
      .navigationTitle(item == nil ? "新建现金流" : "编辑现金流")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("保存") { Task { await save() } }.disabled(model.isMutating) }
      }
      .task { await loadOptions(); seed() }
    }
  }

  private var cashAccounts: [AccountDTO] { accountOptions.filter { $0.archivedAt == nil && $0.kind != .credit } }
  private var matchingCategories: [CategoryDTO] { categoryOptions.filter { $0.archivedAt == nil && $0.direction.rawValue == direction.rawValue } }
  private func seed() {
    guard let item else { endDate = Calendar.current.date(byAdding: .month, value: 6, to: expectedDate) ?? expectedDate; return }
    title = item.title; amount = String(format: "%.2f", Double(item.plannedAmountMinor) / 100)
    direction = item.direction; expectedDate = FutureCashFlowModel.date(item.expectedDate) ?? Date()
    accountID = item.accountID; destinationID = item.destinationAccountID; categoryID = item.categoryID
  }
  private func loadOptions() async {
    accountOptions = (try? await accounts.transactionOptions()) ?? []
    categoryOptions = (try? await categories.transactionOptions()) ?? []
  }
  private func save() async {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let minor = CNYAmountParser.minorUnits(amount), minor > 0
    else { validation = "请填写名称和正确金额。"; return }
    if direction == .transfer && (accountID == nil || destinationID == nil || accountID == destinationID) { validation = "转账需要两个不同账户。"; return }
    let draft = FutureCashFlowDraft(
      title: title, direction: direction, plannedAmountMinor: minor,
      expectedDate: FutureCashFlowModel.dayString(expectedDate), accountID: accountID,
      destinationAccountID: direction == .transfer ? destinationID : nil,
      categoryID: direction == .transfer ? nil : categoryID,
      recurrence: monthly ? .monthly : nil,
      recurrenceEndDate: monthly ? FutureCashFlowModel.dayString(endDate) : nil)
    let success = if let item { await model.update(item, draft: draft, scope: scope) } else { await model.create(draft) }
    if success { dismiss() } else { validation = model.message }
  }
}

private struct CashFlowSettlementSheet: View {
  @Environment(\.dismiss) private var dismiss
  let model: FutureCashFlowModel
  let accounts: AccountsModel
  let categories: CategoriesModel
  let item: FutureCashFlowItem
  @State private var amount = ""
  @State private var date = Date()
  @State private var accountID: UUID?
  @State private var destinationID: UUID?
  @State private var categoryID: UUID?
  @State private var accountOptions: [AccountDTO] = []
  @State private var categoryOptions: [CategoryDTO] = []
  @State private var validation: String?

  var body: some View {
    NavigationStack {
      Form {
        Section("实际入账") {
          TextField("实际金额", text: $amount)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
          DatePicker("实际日期", selection: $date, displayedComponents: [.date, .hourAndMinute])
          Picker("账户", selection: $accountID) { Text("请选择").tag(UUID?.none); ForEach(cashAccounts) { Text($0.name).tag(Optional($0.id)) } }
          if item.direction == .transfer { Picker("转入账户", selection: $destinationID) { Text("请选择").tag(UUID?.none); ForEach(cashAccounts) { Text($0.name).tag(Optional($0.id)) } } }
          else { Picker("分类", selection: $categoryID) { Text("请选择").tag(UUID?.none); ForEach(matchingCategories) { Text($0.name).tag(Optional($0.id)) } } }
        }
        Text("预计值会保留；确认后仅生成一条正式流水。")
          .font(.caption).foregroundStyle(FiscalColor.tertiary)
        if let validation { Text(validation).foregroundStyle(FiscalColor.expense) }
      }.navigationTitle("完成入账")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("入账") { Task { await save() } }.disabled(model.isMutating) }
      }
      .task { await loadOptions() }
    }
  }
  private var cashAccounts: [AccountDTO] { accountOptions.filter { $0.archivedAt == nil && $0.kind != .credit } }
  private var matchingCategories: [CategoryDTO] { categoryOptions.filter { $0.archivedAt == nil && $0.direction.rawValue == (item.direction == .inflow ? "income" : "expense") } }
  private func loadOptions() async {
    accountOptions = (try? await accounts.transactionOptions()) ?? []
    categoryOptions = (try? await categories.transactionOptions()) ?? []
    amount = String(format: "%.2f", Double(item.plannedAmountMinor) / 100)
    accountID = item.accountID ?? cashAccounts.first?.id; destinationID = item.destinationAccountID
    categoryID = item.categoryID ?? matchingCategories.first?.id
  }
  private func save() async {
    guard let minor = CNYAmountParser.minorUnits(amount), minor > 0, let accountID else { validation = "请填写金额和账户。"; return }
    if item.direction != .transfer && categoryID == nil { validation = "请选择分类。"; return }
    let success = await model.settle(item, amountMinor: minor, occurredAt: date, accountID: accountID, destinationAccountID: item.direction == .transfer ? destinationID : nil, categoryID: item.direction == .transfer ? nil : categoryID)
    if success { dismiss() } else { validation = model.message }
  }
}
