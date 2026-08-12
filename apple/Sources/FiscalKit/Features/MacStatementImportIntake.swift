#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

/// P28-A's deliberately narrow macOS entry. It ends at redacted evidence reaching
/// `review_required`; review tables, parsing, matching, confirmation and any ledger UI remain
/// outside this view.
public struct MacStatementImportIntake: View {
  @Bindable private var model: StatementImportIntakeModel
  @State private var importerPresented = false
  @FocusState private var importFocused: Bool

  public init(model: StatementImportIntakeModel) { self.model = model }

  public var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      header
      dropZone
      if let metadata = model.metadata { localMetadata(metadata) }
      phaseContent
      Spacer(minLength: 0)
    }
    .padding(28)
    .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
    .fileImporter(isPresented: $importerPresented, allowedContentTypes: [.pdf]) { result in
      guard case .success(let url) = result else { return }
      Task { await model.select(url: url) }
    }
    .onDisappear { model.cleanup() }
    .accessibilityIdentifier("mac.statementImport.intake")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 7) {
      Label("账单导入", systemImage: "doc.text.viewfinder")
        .font(.title2.bold())
      Text("先在这台 Mac 本地读取 PDF。原 PDF、页面图像、路径和原始文本不会上传或保存。")
        .foregroundStyle(.secondary)
    }
  }

  private var dropZone: some View {
    Button {
      importerPresented = true
    } label: {
      VStack(spacing: 10) {
        Image(systemName: "arrow.down.doc").font(.system(size: 30, weight: .medium))
        Text("选择或拖放 PDF") .font(.headline)
        Text("仅接受 PDF；处理大文件时界面仍可响应。")
          .font(.caption).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, minHeight: 170)
      .background(.quaternary, in: .rect(cornerRadius: 16))
      .overlay { RoundedRectangle(cornerRadius: 16).stroke(.separator, style: .init(dash: [6])) }
    }
    .buttonStyle(.plain)
    .focused($importFocused)
    .onDrop(of: [.pdf], isTargeted: nil) { providers in
      guard let provider = providers.first else { return false }
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        guard let url else { return }
        Task { await model.select(url: url) }
      }
      return true
    }
    .accessibilityLabel("选择或拖放 PDF 账单")
    .accessibilityHint("文件会先在本机读取，尚未发送任何数据")
  }

  private func localMetadata(_ metadata: StatementImportLocalMetadata) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("本地预览（尚未查询服务器）").font(.headline)
      Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
        GridRow { Text("文件").foregroundStyle(.secondary); Text(metadata.sourceFilename) }
        GridRow { Text("页数").foregroundStyle(.secondary); Text("\(metadata.pageCount) 页") }
        GridRow { Text("大小").foregroundStyle(.secondary); Text(ByteCountFormatter.string(fromByteCount: Int64(metadata.byteSize), countStyle: .file)) }
        GridRow { Text("SHA-256").foregroundStyle(.secondary); Text(metadata.documentSHA256).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
      }
      .accessibilityElement(children: .combine)
    }
    .padding(16)
    .background(.quaternary, in: .rect(cornerRadius: 12))
  }

  @ViewBuilder private var phaseContent: some View {
    switch model.phase {
    case .idle: EmptyView()
    case .inspecting: ProgressView("正在本地读取文件…")
    case .awaitingConsent:
      VStack(alignment: .leading, spacing: 10) {
        Text("发送前确认").font(.headline)
        Text("确认后只发送 SHA-256、大小、页数和固定名称 `statement.pdf`。重复文件只显示现有批次，不会开始提取或上传证据。唯一的后续上传是本地确定性脱敏后的 JSON 页/行证据；不会发送 PDF、图像、路径、书签、原文件名或原始文本。")
          .font(.callout).foregroundStyle(.secondary)
        HStack {
          Button("取消") { Task { await model.cancel() } }
          Button("同意并开始本地提取") { model.beginConsentAndUpload() }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("同意并开始本地提取，仅发送脱敏 JSON")
        }
      }
    case .registering: ProgressView("正在登记安全元数据…")
    case .duplicate(let batch):
      Label("发现重复文件：已有批次 \(batch.id.uuidString)。未开始提取，也未上传证据。", systemImage: "doc.on.doc")
        .foregroundStyle(.secondary).textSelection(.enabled)
    case .extracting: ProgressView("正在本地提取与脱敏…")
    case .uploading: ProgressView("正在上传脱敏 JSON 证据…")
    case .reviewRequired(let batch):
      Label("脱敏证据已保存，批次已进入待审核状态（\(batch.id.uuidString)）。P28-A 不会解析、匹配或确认账本。", systemImage: "checkmark.shield")
        .foregroundStyle(.green).textSelection(.enabled)
    case .localFailure(let message): failure(message, retry: false)
    case .remoteFailure(let message): failure(message, retry: false)
    case .remoteUnknown:
      VStack(alignment: .leading, spacing: 10) {
        Text("服务器响应未确认").font(.headline)
        Text("不会自动重发或重新读取原文件。你可以显式查询批次状态，或重发同一份内存中的脱敏 JSON。")
          .foregroundStyle(.secondary)
        HStack {
          Button("查询批次状态") { Task { await model.queryRemoteStatus() } }
          Button("重发同一脱敏证据") { Task { await model.retryEvidence() } }
            .buttonStyle(.borderedProminent)
          Button("取消") { Task { await model.cancel() } }
        }
      }
    case .cancelled: Label("已取消；本地临时文件已清理。", systemImage: "xmark.circle")
    }
  }

  private func failure(_ message: String, retry _: Bool) -> some View {
    Label(message, systemImage: "exclamationmark.triangle")
      .foregroundStyle(.orange)
      .accessibilityLabel("账单导入失败：\(message)")
  }
}
#endif
