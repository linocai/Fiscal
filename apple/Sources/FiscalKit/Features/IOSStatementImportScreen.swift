import SwiftUI
import UniformTypeIdentifiers

public struct IOSStatementImportScreen: View {
  @Environment(\.scenePhase) private var scenePhase
  @Bindable private var intake: StatementImportIntakeModel
  private let review: StatementImportReviewWorkbenchModel
  private let accounts: [AccountDTO]; private let categories: [CategoryDTO]
  @State private var importer = false
  public init(intake: StatementImportIntakeModel, review: StatementImportReviewWorkbenchModel, accounts: [AccountDTO], categories: [CategoryDTO]) { self.intake = intake; self.review = review; self.accounts = accounts; self.categories = categories }
  public var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("账单导入").font(.title2.bold())
      Button("从文件选择 PDF") { importer = true }.accessibilityHint("文件仅在本机临时读取；发送前需要再次确认")
      if let metadata = intake.metadata { Text("\(metadata.sourceFilename) · \(metadata.pageCount) 页 · \(metadata.documentSHA256)").font(.caption).textSelection(.enabled) }
      switch intake.phase {
      case .awaitingConsent:
        Text("确认后仅发送固定名称、大小、页数、哈希与脱敏 JSON；不会上传 PDF、图像、路径或原文。")
        Button("同意并开始") { intake.beginConsentAndUpload() }.buttonStyle(.borderedProminent)
      case .reviewRequired(let batch): IOSStatementReviewScreen(model: review, batchID: batch.id, accounts: accounts, categories: categories)
      case .remoteUnknown:
        Text("服务器响应未确认；不会自动重发。")
        Button("查询批次状态") { Task { await intake.queryRemoteStatus() } }
        Button("重发同一脱敏证据") { Task { await intake.retryEvidence() } }
      case .localFailure(let message), .remoteFailure(let message): Text(message).foregroundStyle(.orange)
      case .inspecting, .registering, .extracting, .uploading: ProgressView()
      default: EmptyView()
      }
      Spacer()
    }.padding().navigationTitle("账单导入")
      .fileImporter(isPresented: $importer, allowedContentTypes: [.pdf]) { result in if case .success(let url) = result { Task { await intake.select(url: url) } } }
      .onDisappear { intake.discardForSceneInterruption(); review.clear() }
      .onChange(of: scenePhase) { _, phase in if phase == .background { intake.discardForSceneInterruption(); review.clear() } }
  }
}

private struct IOSStatementReviewScreen: View {
  @Bindable var model: StatementImportReviewWorkbenchModel; let batchID: UUID; let accounts: [AccountDTO]; let categories: [CategoryDTO]
  @State private var selected = Set<UUID>(); @State private var intentionalReason = ""; @State private var previewPresented = false
  @State private var createRow: UUID?
  var body: some View {
    Group {
      if let workbench = model.workbench {
        Text(workbench.reviewAvailable ? "审核：逐行选择" : "仅有已存脱敏证据；结构化审核不可用")
        List(workbench.rows) { row in
          VStack(alignment: .leading, spacing: 7) {
            HStack { Text("第 \(row.rowNumber) 行"); Spacer(); if row.isConfirmed { Text("已冻结").foregroundStyle(.secondary) } else if workbench.reviewAvailable { Toggle("确认", isOn: binding(row.id)).labelsHidden() } }
            Text(row.evidenceTextMasked ?? "原件未保留，脱敏来源不可用").font(.caption)
            if workbench.reviewAvailable && !row.isConfirmed { actions(row) }
          }.contentShape(.rect).onTapGesture { Task { await model.select(row) } }
        }
        if workbench.nextCursor != nil { Button("加载更多审核行") { Task { await model.loadMore() } } }
        if workbench.reviewAvailable { Button("准备确认") { Task { if await model.prepareConfirmation(batchID: batchID, rowIDs: selected) { previewPresented = true } } }.disabled(selected.isEmpty) }
        if let error = model.error { Text(error).foregroundStyle(.orange); Button("重新加载") { Task { await model.reload(batchID: batchID) } } }
        if let receipt = model.confirmationReceipt { Text("确认收据：\(receipt.confirmedRowIDs.count) 行，\(receipt.status)") }
        if model.responseUnknownConfirmationKey != nil { Button("查询确认收据") { Task { _ = await model.lookupConfirmationReceipt() } } }
      } else { ProgressView() }
    }.task { await model.reload(batchID: batchID) }
      .sheet(isPresented: $previewPresented) { confirmationSheet }
      .sheet(isPresented: Binding(get: { createRow != nil }, set: { if !$0 { createRow = nil } })) { if let rowID = createRow { CreateDraftSheet(model: model, rowID: rowID, accounts: accounts.filter { $0.archivedAt == nil }, categories: categories.filter { $0.archivedAt == nil }) } }
  }
  private func binding(_ id: UUID) -> Binding<Bool> {
    .init(get: { selected.contains(id) }, set: { enabled in
      if enabled { selected.insert(id) } else { selected.remove(id) }
    })
  }
  @ViewBuilder private func actions(_ row: StatementImportWorkbench.Row) -> some View {
    HStack {
      Button("新建") { Task { if await model.saveResolution(rowID: row.id, resolution: .createNew) { createRow = row.id } } }
      Button("非交易") { Task { _ = await model.saveResolution(rowID: row.id, resolution: .ignoreNonTransaction) } }
      Menu("匹配") { ForEach(row.candidates.filter { $0.candidateKind == "existing_transaction" && $0.transactionID != nil }) { candidate in Button(candidate.transactionID!.uuidString) { Task { _ = await model.saveResolution(rowID: row.id, resolution: .matchExisting, matchedTransactionID: candidate.transactionID) } } } }
    }
    HStack { TextField("有意忽略原因", text: $intentionalReason); Button("有意忽略") { Task { guard !intentionalReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }; _ = await model.saveResolution(rowID: row.id, resolution: .ignoreIntentional, ignoredReason: intentionalReason) } }.disabled(intentionalReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
  }
  private var confirmationSheet: some View { VStack(alignment: .leading, spacing: 16) { Text("确认预览").font(.title3.bold()); if let preview = model.confirmationPreview { Text("选择 \(preview.counts.selected) 行；确认后将正式写入。"); Button("最终确认") { Task { _ = await model.confirmPrepared(); previewPresented = model.confirmationPreview != nil } }.buttonStyle(.borderedProminent) } else { Text("预览已失效，请重新加载。") }; Button("取消", role: .cancel) { previewPresented = false } }.padding() }
}

private struct CreateDraftSheet: View {
  @Environment(\.dismiss) private var dismiss
  let model: StatementImportReviewWorkbenchModel; let rowID: UUID; let accounts: [AccountDTO]; let categories: [CategoryDTO]
  @State private var kind: TransactionKind?; @State private var title = ""; @State private var amount = ""; @State private var accountID: UUID?; @State private var categoryID: UUID?; @State private var occurredAt: Date?
  var body: some View { NavigationStack { Form { Section("必须明确填写") { Picker("类型", selection: $kind) { Text("请选择").tag(TransactionKind?.none); ForEach([TransactionKind.expense, .income, .creditPurchase]) { Text($0.title).tag(Optional($0)) }; }; TextField("标题", text: $title); TextField("金额（分）", text: $amount).keyboardType(.numberPad); DatePicker("发生时间", selection: dateBinding, displayedComponents: [.date, .hourAndMinute]); Picker("账户", selection: $accountID) { Text("请选择").tag(UUID?.none); ForEach(accounts) { Text($0.name).tag(Optional($0.id)) } }; Picker("分类", selection: $categoryID) { Text("请选择").tag(UUID?.none); ForEach(categories) { Text($0.name).tag(Optional($0.id)) } } }; Text("没有默认账户、分类、金额、日期或类型；已归档项目不显示。").font(.caption) }.navigationTitle("新建最终草稿").toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存") { Task { guard let kind, let accountID, let categoryID, let occurredAt, let minor = Int64(amount), minor > 0, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }; var draft = TransactionDraft(); draft.kind = kind; draft.title = title; draft.amountMinor = minor; draft.accountID = accountID; draft.categoryID = categoryID; draft.occurredAt = occurredAt; await model.saveFinalCreateDraft(rowID: rowID, transaction: draft); dismiss() } }.disabled(kind == nil || accountID == nil || categoryID == nil || occurredAt == nil || Int64(amount) == nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } } } }
  private var dateBinding: Binding<Date> { .init(get: { occurredAt ?? .now }, set: { occurredAt = $0 }) }
}
