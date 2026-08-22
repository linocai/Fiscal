import SwiftUI
import UniformTypeIdentifiers

/// iPhone deliberately keeps statement import as a short sequence rather than
/// squeezing a desktop workbench into a narrow scrolling table.
public struct V15StatementImportView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: V15StatementImportModel
    @State private var importing = false
    @State private var showingConfirmation = false
    private let initialGalleryScenario: String?
    public init(services: V15Services, offlineSnapshotAt: Date? = nil, initialGalleryScenario: String? = nil) { _model = State(initialValue: V15StatementImportModel(services: services, offlineSnapshotAt: offlineSnapshotAt)); self.initialGalleryScenario = initialGalleryScenario }
    public var body: some View {
        NavigationStack { ScrollView { VStack(alignment: .leading, spacing: V15Spacing.section) {
            header; intake; progress; review; result; error
        }.padding(V15Spacing.md) }
        .background(V15Palette.paper.color).navigationTitle("账单导入")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf], allowsMultipleSelection: false) { outcome in if case .success(let urls) = outcome, let url = urls.first { model.selectFile(url: url) } }
        .sheet(isPresented: $showingConfirmation, onDismiss: { model.dismissPreview() }) { confirmationSheet }
        .task { if let initialGalleryScenario { await model.prepareSyntheticGallery(initialGalleryScenario); if ["statement-import-preview", "statement-import-preview-error", "statement-import-preview-conflict"].contains(initialGalleryScenario) { showingConfirmation = true } } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.sceneDidLeaveActive() } }
        .onDisappear { model.sceneDidLeaveActive() }
        .accessibilityIdentifier("v15.f3g.statement-import.ios") }
    }
    private var header: some View { VStack(alignment: .leading, spacing: V15Spacing.xs) { Text("本地脱敏，人工确认入账").font(V15Typography.surfaceTitle); Text("PDF 仅在当前设备提取；服务器只接收文档元数据与脱敏证据。确认前每一行都可复核。 ").font(V15Typography.body).foregroundStyle(V15Palette.ink.color.opacity(0.68)); if let snapshot = model.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: snapshot).accessibilityIdentifier("v15.f3g.offline") } } }
    private var intake: some View { V15Section("1. 选择账单") { VStack(alignment: .leading, spacing: V15Spacing.sm) { Button("选择 PDF") { importing = true }.accessibilityIdentifier("v15.f3g.pick-file").disabled(!model.writeReasons.isEmpty); if let batch = model.batch { Text("\(batch.displayName) · \(batch.status.displayName)").font(V15Typography.secondary).accessibilityIdentifier("v15.f3g.batch-status") }; disabledReasons(model.writeReasons) } } }
    @ViewBuilder private var progress: some View { switch model.phase {
    case .localProcessing, .registering, .extracting: V15LoadingSkeleton().accessibilityIdentifier("v15.f3g.local-processing")
    case .awaitingProviderConsent: V15Section("2. 解析授权") { Button { model.providerAuthorized.toggle() } label: { Label(model.providerAuthorized ? "已确认仅发送脱敏证据" : "确认仅发送脱敏文本与标准化位置框", systemImage: model.providerAuthorized ? "checkmark.shield.fill" : "shield") }.accessibilityIdentifier("v15.f3g.provider-consent"); Text("本次解析范围：execution_scope=request_bound。离开页面、断线或取消不会在后台继续。 ").font(V15Typography.secondary); Button("在本次请求内解析") { model.requestProviderAttempt() }.accessibilityIdentifier("v15.f3g.provider-start").disabled(!model.providerAuthorized || !model.writeReasons.isEmpty) }
    case .providerResponseUnknown: V15Section("解析结果待确认") { Text("请求结果未知。恢复只会复用同一授权、证据摘要和请求凭证。 ").font(V15Typography.body); Button("使用同一凭证恢复") { model.requestProviderRecovery() }.accessibilityIdentifier("v15.f3g.provider-recover").disabled(model.isOffline || model.writeReasons.contains(where: { $0.code == "unknown_import_status" })) }
    case .reviewing: V15Section("3. 校验") { Button("运行服务器校验") { model.requestValidation() }.accessibilityIdentifier("v15.f3g.validation-run").disabled(!model.writeReasons.isEmpty) }
    default: EmptyView() }
    }
    @ViewBuilder private var review: some View {
        if let board = model.workbench {
            V15Section("4. 逐行复核") {
                VStack(alignment: .leading, spacing: V15Spacing.sm) {
                    Text("\(board.status.displayName) · 不可用来源 \(board.sourceUnavailableCount) 页").font(V15Typography.secondary)
                    if board.rows.isEmpty { V15EmptyState(title: "没有可复核行", explanation: "服务器尚未返回账单行。") }
                    else { ForEach(board.rows) { row in rowSurface(row) } }
                    Picker("来源", selection: Binding(get: { model.workbenchFilter.evidenceState ?? "all" }, set: { model.requestWorkbenchEvidenceFilter($0 == "all" ? nil : $0) })) { Text("全部").tag("all"); Text("仅可用").tag("available"); Text("仅不可用").tag("unavailable") }.accessibilityIdentifier("v15.f3g.filter")
                    Button("刷新复核") { model.requestReloadWorkbench() }.accessibilityIdentifier("v15.f3g.reload-workbench")
                    Button(model.isLoadingPage ? "正在读取脱敏页面…" : "查看脱敏页面") { model.requestPage(1) }.accessibilityIdentifier("v15.f3g.page-load").disabled(model.isLoadingPage)
                    if model.isLoadingPage { ProgressView("正在读取脱敏页面…").accessibilityIdentifier("v15.f3g.page-loading") }
                    if let page = model.page { Text(page.sourceAvailable ? (page.evidenceTextMasked ?? "仅位置框") : "该来源不可用").font(V15Typography.secondary).accessibilityIdentifier("v15.f3g.masked-page") }
                    if let failure = model.pageFailure { V15ServiceErrorState(message: failure.message, retryIdentifier: "v15.f3g.page-retry", retry: { model.requestPage(1) }).accessibilityIdentifier("v15.f3g.page-error") }
                    if model.workbench?.nextCursor != nil { Button(model.isLoadingMore ? "正在加载…" : "加载更多") { model.requestNextWorkbench() }.accessibilityIdentifier("v15.f3g.load-next").disabled(model.isLoadingMore) }
                    if let failure = model.workbenchFailure { V15ServiceErrorState(message: failure.message, retry: { model.requestReloadWorkbench() }).accessibilityIdentifier("v15.f3g.workbench-error") }
                    Button("获取服务器确认预览") { model.requestPreview(); showingConfirmation = true }.accessibilityIdentifier("v15.f3g.preview").disabled(!model.previewReasons.isEmpty)
                    disabledReasons(model.previewReasons)
                }
            }
        }
    }
    private func rowSurface(_ row: V15StatementWorkbenchRow) -> some View { VStack(alignment: .leading, spacing: V15Spacing.xs) { HStack { Button { model.toggleRow(row.id) } label: { Image(systemName: model.selectedRowIDs.contains(row.id) ? "checkmark.circle.fill" : "circle") }.accessibilityIdentifier("v15.f3g.select.\(row.id)").disabled(!model.writeReasons.isEmpty); Text("第 \(row.rowNumber) 行 · \(row.draft?.resolution.displayName ?? "未处理")").font(V15Typography.cardTitle) }; Text(row.evidenceTextMasked ?? "来源不可用").font(V15Typography.secondary); if let draft = row.draft, !draft.resolution.isExecutable { HStack { Button("新建流水") { model.requestResolution(row: row, as: .createNew) }.accessibilityIdentifier("v15.f3g.resolve-create.\(row.id)").disabled(!model.writeReasons.isEmpty); Button("忽略") { model.requestResolution(row: row, as: .ignoreIntentional) }.accessibilityIdentifier("v15.f3g.resolve-ignore.\(row.id)").disabled(!model.writeReasons.isEmpty) } } }.padding(V15Spacing.sm).background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.decisionCard)) }
    @ViewBuilder private var result: some View { if let receipt = model.receipt { V15Section("确认收据") { Text("\(receipt.status) · 新建 \(receipt.createdCount) · 匹配 \(receipt.matchedCount) · 跳过 \(receipt.skippedCount)").accessibilityIdentifier("v15.f3g.receipt"); ForEach(receipt.rowResults, id: \.rowID) { Text("\($0.rowID.uuidString.prefix(8)) · \($0.outcome)").font(V15Typography.secondary) } } }; if case .responseUnknown = model.phase { V15Section("确认结果未知") { Text("不会盲目重发确认；仅以相同请求凭证读取收据。 ").font(V15Typography.body); Button("读取确认收据") { model.requestReceiptReadback() }.accessibilityIdentifier("v15.f3g.receipt-readback") } } }
    @ViewBuilder private var error: some View {
        if let message = model.resolutionReadbackMessage {
            Text(message).font(V15Typography.secondary).accessibilityIdentifier("v15.f3g.resolution-readback-status")
        }
        if model.isResolutionReadbackInFlight {
            ProgressView("正在读取完整复核行…").accessibilityIdentifier("v15.f3g.resolution-readback-loading")
        }
        if case .failed(let failure) = model.phase {
            V15ServiceErrorState(message: failure.message, retryIdentifier: failure.code == "resolution_response_unknown" ? "v15.f3g.resolution-readback-retry" : nil, retry: { model.retryFromFailure() }).accessibilityIdentifier("v15.f3g.error")
        }
    }
    private var confirmationSheet: some View { NavigationStack { ScrollView { VStack(alignment: .leading, spacing: V15Spacing.md) {
        if model.isPreviewLoading {
            ProgressView("正在获取服务器确认预览…")
            Text("正在获取服务器确认预览…").accessibilityIdentifier("v15.f3g.preview-loading")
            Text("请保持当前页面；尚未创建流水。 ").font(V15Typography.secondary)
        } else if let failure = model.previewFailure {
            Text(failure.kind == .conflict ? "确认预览已过期" : "确认预览暂不可用").font(V15Typography.surfaceTitle).accessibilityIdentifier("v15.f3g.preview-failure")
            Text(failure.message).font(V15Typography.body)
            Button("重试获取预览") { model.requestPreview() }.accessibilityIdentifier("v15.f3g.preview-retry")
        } else if model.isConfirmationInFlight {
            ProgressView("正在创建流水…").accessibilityIdentifier("v15.f3g.confirming")
            Text("请求已经提交；请勿重复确认。 ").font(V15Typography.secondary)
        } else if let receipt = model.receipt {
            Text("确认收据").font(V15Typography.surfaceTitle)
            Text("\(receipt.status) · 新建 \(receipt.createdCount) · 匹配 \(receipt.matchedCount) · 跳过 \(receipt.skippedCount)").accessibilityIdentifier("v15.f3g.sheet-receipt")
        } else if case .responseUnknown = model.phase {
            Text("确认结果未知").font(V15Typography.surfaceTitle).accessibilityIdentifier("v15.f3g.sheet-response-unknown")
            Text("不会盲目重发确认；关闭后仅可使用相同请求凭证读取收据。 ").font(V15Typography.body)
        } else if let preview = model.preview {
            Text("确认预览").font(V15Typography.surfaceTitle); Text("服务器已锁定 \(preview.counts.selected) 行；已知金额 ¥\(preview.amounts.knownTotalMinor / 100)，未知来源 \(preview.amounts.unknownSelectedCount) 行不参与相加。 ").font(V15Typography.body); Text("只会原样提交服务器返回的行与版本。 ").font(V15Typography.secondary); Button("确认创建") { model.requestConfirm() }.accessibilityIdentifier("v15.f3g.confirm").disabled(!model.confirmReasons.isEmpty); disabledReasons(model.confirmReasons)
        }
    }.padding(V15Spacing.md) }.navigationTitle("确认前检查").toolbar { Button("关闭") { showingConfirmation = false }.accessibilityIdentifier("v15.f3g.preview-dismiss").disabled(model.isConfirmationInFlight) } }.interactiveDismissDisabled(model.isConfirmationInFlight).accessibilityIdentifier("v15.f3g.confirmation-sheet") }
    @ViewBuilder private func disabledReasons(_ reasons: [V15DisabledReason]) -> some View { ForEach(reasons, id: \.code) { Text($0.message).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.7)) } }
}
