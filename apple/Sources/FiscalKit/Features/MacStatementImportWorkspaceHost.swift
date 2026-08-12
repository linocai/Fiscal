#if os(macOS)
import SwiftUI

/// macOS-only P28-B review surface.  Every value here is an in-memory user choice; only the
/// dedicated P27 repositories can write it, and this screen has no confirmation affordance.
public struct MacStatementImportWorkspaceHost: View {
  @Bindable private var model: StatementImportReviewWorkbenchModel
  private let batchID: UUID
  private let accounts: [AccountDTO]
  private let categories: [CategoryDTO]
  @State private var resolution: StatementImportDraftResolutionKind = .unresolved
  @State private var matchedTransactionID: UUID?
  @State private var ignoredReason = ""
  @State private var create = CreateForm()

  public init(
    model: StatementImportReviewWorkbenchModel, batchID: UUID,
    accounts: [AccountDTO] = [], categories: [CategoryDTO] = []
  ) {
    self.model = model; self.batchID = batchID; self.accounts = accounts; self.categories = categories
  }

  public var body: some View {
    HStack(spacing: 0) {
      summaryColumn
      Divider()
      evidenceColumn
      Divider()
      reviewColumn
    }
    .task { await model.reload(batchID: batchID) }
    .onDisappear { resetLocalForms(); model.clear() }
    .accessibilityIdentifier("mac.statementImport.workbench")
    .accessibilityLabel("账单审核工作台，三栏布局；只显示已存脱敏证据")
  }

  private var summaryColumn: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("审核摘要").font(.headline)
      Text(model.workbench?.reviewAvailable == true ? "结构化审核可用" : "仅脱敏证据；结构化审核不可用")
        .foregroundStyle(.secondary)
      if let workbench = model.workbench {
        Text("批次版本 \(workbench.batchVersion)").font(.caption).foregroundStyle(.secondary)
        Text("共 \(workbench.rows.count) 行").font(.caption).foregroundStyle(.secondary)
      }
      Button("刷新") { Task { await model.reload(batchID: batchID) } }
        .keyboardShortcut("r", modifiers: [.command])
        .accessibilityHint("重新读取服务器中的脱敏审核数据")
      if let error = model.error { Text(error).foregroundStyle(.orange).font(.caption) }
      Spacer()
    }
    .frame(width: 230, alignment: .topLeading).padding()
    .accessibilityElement(children: .contain)
    .accessibilityLabel("左侧批次、检查和筛选摘要")
  }

  private var evidenceColumn: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("已存脱敏证据").font(.headline)
      if let page = model.page, page.sourceAvailable, let text = page.evidenceTextMasked {
        Text(text).textSelection(.enabled)
          .accessibilityLabel("中间栏已存脱敏来源")
      } else {
        Text("原件未保留，脱敏来源不可用").foregroundStyle(.secondary)
          .accessibilityLabel("中间栏：原件未保留，脱敏来源不可用")
      }
      Spacer()
    }
    .frame(minWidth: 280, maxWidth: .infinity, alignment: .topLeading).padding()
  }

  private var reviewColumn: some View {
    VStack(spacing: 0) {
      List(model.workbench?.rows ?? []) { row in
        Button {
          resetLocalForms(for: row)
          Task { await model.select(row) }
        } label: {
          VStack(alignment: .leading, spacing: 3) {
            Text("#\(row.rowNumber) \(row.evidenceTextMasked ?? "来源不可用")").lineLimit(1)
            Text(row.draft?.resolution ?? "unresolved").font(.caption).foregroundStyle(.secondary)
          }
        }
        .buttonStyle(.plain).focusable()
        .accessibilityLabel("第 \(row.rowNumber) 行，\(row.evidenceTextMasked ?? "脱敏来源不可用")")
      }
      .frame(minHeight: 160)
      Divider()
      if let row = selectedRow { inspector(row) }
      else { Text("选择一行以审核。所有选择均需显式保存。").foregroundStyle(.secondary).padding() }
    }
    .frame(width: 390, alignment: .topLeading)
    .accessibilityLabel("右侧虚拟化审核行表和编辑器")
  }

  private var selectedRow: StatementImportWorkbench.Row? {
    guard let id = model.selectedRowID else { return nil }
    return model.workbench?.rows.first(where: { $0.id == id })
  }

  @ViewBuilder private func inspector(_ row: StatementImportWorkbench.Row) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        Text("行 #\(row.rowNumber) 审核").font(.headline)
        if model.workbench?.reviewAvailable != true {
          Text("结构化审核不可用；此批次只能查看脱敏证据。")
            .foregroundStyle(.secondary)
        } else {
          Picker("处理方式", selection: $resolution) {
            ForEach(StatementImportDraftResolutionKind.allCases) { Text($0.rawValue).tag($0) }
          }
          .accessibilityLabel("处理方式；必须由用户明确选择")
          switch resolution {
          case .matchExisting: matchEditor(row)
          case .ignoreIntentional:
            TextField("忽略原因（必填）", text: $ignoredReason)
          case .createNew: createEditor
          case .unresolved, .ignoreNonTransaction: EmptyView()
          }
          Button(resolution == .createNew ? "保存新建草稿" : "保存审核选择") {
            Task { await save(row) }
          }
          .buttonStyle(.borderedProminent)
          .disabled(!canSave(row))
          .accessibilityHint("保存前会重新读取版本；冲突后不会自动重发")
        }
      }.padding()
    }
  }

  @ViewBuilder private func matchEditor(_ row: StatementImportWorkbench.Row) -> some View {
    let candidates = row.candidates.filter { $0.candidateKind == "existing_transaction" && $0.transactionID != nil }
    if candidates.isEmpty { Text("当前候选中没有可匹配的既有流水。") .foregroundStyle(.secondary) }
    else {
      Picker("当前候选", selection: $matchedTransactionID) {
        Text("请选择当前候选").tag(UUID?.none)
        ForEach(candidates) { candidate in
          Text(candidate.transactionID!.uuidString).tag(Optional(candidate.transactionID!))
        }
      }
      Text("只能从当前服务器候选中显式选择；不会按日期或金额自动匹配。")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private var createEditor: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker("类型（必选）", selection: $create.kind) {
        Text("请选择类型").tag(TransactionKind?.none)
        ForEach(TransactionKind.allCases) { Text($0.title).tag(Optional($0)) }
      }
      TextField("发生时间（ISO 8601，必填）", text: $create.occurredAt)
      TextField("金额（CNY，必填）", text: $create.amount)
      TextField("标题（必填）", text: $create.title)
      TextField("备注", text: $create.note)
      masterPickers
      TextField("信用账期 ID（如适用）", text: $create.creditCycleID)
      Text("所有字段均从空值开始；候选不会自动填充类型、账户、分类、金额或日期。")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private var masterPickers: some View {
    Group {
      Picker("账户", selection: $create.accountID) {
        Text("请选择账户").tag(UUID?.none)
        ForEach(activeAccounts) { Text($0.name).tag(Optional($0.id)) }
      }
      Picker("目标账户", selection: $create.destinationAccountID) {
        Text("请选择目标账户").tag(UUID?.none)
        ForEach(activeAccounts) { Text($0.name).tag(Optional($0.id)) }
      }
      Picker("分类", selection: $create.categoryID) {
        Text("请选择分类").tag(UUID?.none)
        ForEach(activeCategories) { Text($0.name).tag(Optional($0.id)) }
      }
    }
  }

  private var activeAccounts: [AccountDTO] { accounts.filter { $0.archivedAt == nil } }
  private var activeCategories: [CategoryDTO] { categories.filter { $0.archivedAt == nil } }

  private func canSave(_ row: StatementImportWorkbench.Row) -> Bool {
    switch resolution {
    case .matchExisting: return row.candidates.contains { $0.transactionID == matchedTransactionID && $0.candidateKind == "existing_transaction" }
    case .ignoreIntentional: return !ignoredReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .createNew: return create.transaction != nil
    case .unresolved, .ignoreNonTransaction: return true
    }
  }

  private func save(_ row: StatementImportWorkbench.Row) async {
    if resolution == .createNew {
      guard let transaction = create.transaction else { return }
      guard await model.saveResolution(rowID: row.id, resolution: .createNew) else { return }
      await model.saveFinalCreateDraft(rowID: row.id, transaction: transaction)
    } else {
      await model.saveResolution(
        rowID: row.id, resolution: resolution, matchedTransactionID: matchedTransactionID,
        ignoredReason: resolution == .ignoreIntentional ? ignoredReason : nil)
    }
  }

  private func resetLocalForms(for row: StatementImportWorkbench.Row? = nil) {
    resolution = row.flatMap { StatementImportDraftResolutionKind(rawValue: $0.draft?.resolution ?? "") } ?? .unresolved
    matchedTransactionID = nil; ignoredReason = ""; create = CreateForm()
  }

  private struct CreateForm {
    var kind: TransactionKind?
    var occurredAt = ""
    var amount = ""
    var title = ""
    var note = ""
    var accountID: UUID?
    var destinationAccountID: UUID?
    var categoryID: UUID?
    var creditCycleID = ""

    var transaction: TransactionDraft? {
      guard let kind, let date = ISO8601DateFormatter().date(from: occurredAt),
        let amountMinor = CNYAmountParser.minorUnits(amount), amountMinor > 0,
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return nil }
      var draft = TransactionDraft()
      draft.kind = kind; draft.occurredAt = date; draft.amountMinor = amountMinor
      draft.title = title; draft.note = note; draft.accountID = accountID
      draft.destinationAccountID = destinationAccountID; draft.categoryID = categoryID
      draft.creditCycleID = UUID(uuidString: creditCycleID.trimmingCharacters(in: .whitespacesAndNewlines))
      return draft
    }
  }
}
#endif
