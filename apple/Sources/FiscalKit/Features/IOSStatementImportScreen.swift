import SwiftUI
import UniformTypeIdentifiers

public struct IOSStatementImportScreen: View {
  @Bindable private var intake: StatementImportIntakeModel
  private let review: StatementImportReviewWorkbenchModel
  @State private var importer = false
  public init(intake: StatementImportIntakeModel, review: StatementImportReviewWorkbenchModel) { self.intake = intake; self.review = review }
  public var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("账单导入").font(.title2.bold())
      Button("从文件选择 PDF") { importer = true }.accessibilityHint("文件仅在本机临时读取；发送前需要再次确认")
      if let metadata = intake.metadata { Text("\(metadata.sourceFilename) · \(metadata.pageCount) 页 · \(metadata.documentSHA256)").font(.caption).textSelection(.enabled) }
      switch intake.phase {
      case .awaitingConsent:
        Text("确认后仅发送固定名称、大小、页数、哈希与脱敏 JSON；不会上传 PDF、图像、路径或原文。")
        Button("同意并开始") { intake.beginConsentAndUpload() }.buttonStyle(.borderedProminent)
      case .reviewRequired(let batch): IOSStatementReviewScreen(model: review, batchID: batch.id)
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
      .onDisappear { intake.cleanup(); review.clear() }
  }
}

private struct IOSStatementReviewScreen: View {
  @Bindable var model: StatementImportReviewWorkbenchModel; let batchID: UUID
  var body: some View { Group { if let workbench = model.workbench { Text(workbench.reviewAvailable ? "审核" : "仅有已存脱敏证据；结构化审核不可用"); List(workbench.rows) { row in VStack(alignment: .leading) { Text("第 \(row.rowNumber) 行"); Text(row.evidenceTextMasked ?? "原件未保留，脱敏来源不可用").font(.caption) }.onTapGesture { Task { await model.select(row) } } } } else { ProgressView() } }.task { await model.reload(batchID: batchID) } }
}
