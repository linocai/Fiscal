#if os(macOS)
import SwiftUI
public struct MacStatementImportWorkspaceHost: View {
  @Bindable private var model: StatementImportReviewWorkbenchModel; private let batchID: UUID
  public init(model: StatementImportReviewWorkbenchModel, batchID: UUID) { self.model = model; self.batchID = batchID }
  public var body: some View { HStack(spacing: 0) {
    VStack(alignment: .leading) { Text("审核摘要").font(.headline); Text(model.workbench?.reviewAvailable == true ? "结构化审核可用" : "仅脱敏证据；结构化审核不可用"); Button("刷新") { Task { await model.reload(batchID: batchID) } } }.frame(width: 230).padding()
    VStack(alignment: .leading) { Text("已存脱敏证据").font(.headline); Text(model.page?.evidenceTextMasked ?? "原件未保留，脱敏来源不可用").textSelection(.enabled) }.frame(maxWidth: .infinity).padding()
    List(model.workbench?.rows ?? []) { row in Button("#\(row.rowNumber) \(row.evidenceTextMasked ?? "来源不可用")") { Task { await model.select(row) } } }.frame(width: 360)
  }.task { await model.reload(batchID: batchID) }.onDisappear { model.clear() }.accessibilityIdentifier("mac.statementImport.workbench") }
}
#endif
