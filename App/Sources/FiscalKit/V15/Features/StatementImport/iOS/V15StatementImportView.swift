import SwiftUI
import UniformTypeIdentifiers

/// iPhone presents one statement row at a time. Batch confirmation remains a
/// separate, revision-bound step so saving a disposition never looks like a
/// ledger write.
public struct V15StatementImportView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model: V15StatementImportModel
    @State private var importing = false
    @State private var showingConfirmation = false
    @State private var reviewIndex = 0
    private let initialGalleryScenario: String?

    public init(services: V15Services, offlineSnapshotAt: Date? = nil, initialGalleryScenario: String? = nil) {
        _model = State(initialValue: V15StatementImportModel(services: services, offlineSnapshotAt: offlineSnapshotAt))
        self.initialGalleryScenario = initialGalleryScenario
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.section) {
                    header
                    intake
                    progress
                    review
                    result
                    error
                }
                .padding(V15Spacing.md)
                .frame(maxWidth: 680, alignment: .leading)
            }
            .background(V15Palette.paper.color)
            .navigationTitle("账单导入")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf], allowsMultipleSelection: false) { outcome in
            if case .success(let urls) = outcome, let url = urls.first { model.selectFile(url: url) }
        }
        .sheet(isPresented: $showingConfirmation, onDismiss: { model.dismissPreview() }) { confirmationSheet }
        .task {
            if let initialGalleryScenario {
                await model.prepareSyntheticGallery(initialGalleryScenario)
                if let rows = model.workbench?.rows,
                   let unresolvedIndex = rows.firstIndex(where: { $0.draft?.resolution == .unresolved }) {
                    reviewIndex = unresolvedIndex
                }
                if ["statement-import-preview", "statement-import-preview-error", "statement-import-preview-conflict"].contains(initialGalleryScenario) {
                    showingConfirmation = true
                }
            }
        }
        .onChange(of: model.workbench?.rows.map(\.id)) { _, ids in
            reviewIndex = min(reviewIndex, max((ids?.count ?? 1) - 1, 0))
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.sceneDidLeaveActive() } }
        .onDisappear { model.sceneDidLeaveActive() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f3g.statement-import.ios")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: V15Spacing.xs) {
            Text("本地脱敏，人工确认入账").font(V15Typography.surfaceTitle)
            Text("原始 PDF 不会长期保存；确认前不会把内容记到账目。")
                .font(V15Typography.body)
                .foregroundStyle(V15Palette.ink.color.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
            if let snapshot = model.offlineSnapshotAt {
                V15OfflineReadOnlyBanner(snapshotAt: snapshot).accessibilityIdentifier("v15.f3g.offline")
            }
        }
    }

    private var intake: some View {
        V15Section("1 · 授权与提取") {
            VStack(alignment: .leading, spacing: V15Spacing.sm) {
                Button("选择本地 PDF") { importing = true }
                    .accessibilityIdentifier("v15.f3g.pick-file")
                    .disabled(!model.writeReasons.isEmpty)
                Label("本机提取文本与位置框", systemImage: "checkmark.shield")
                    .font(V15Typography.secondary)
                Label("智能解析需另行授权，默认不会发送账单", systemImage: "shield")
                    .font(V15Typography.secondary)
                if let batch = model.batch {
                    HStack {
                        Text(batch.displayName).font(V15Typography.body.weight(.semibold))
                        Spacer()
                        Text(batch.status.displayName).font(V15Typography.secondary)
                    }
                    .accessibilityIdentifier("v15.f3g.batch-status")
                }
                disabledReasons(model.writeReasons)
            }
        }
    }

    @ViewBuilder private var progress: some View {
        switch model.phase {
        case .localProcessing, .registering, .extracting:
            V15Section("2 · 提取进度") {
                V15LoadingSkeleton().accessibilityIdentifier("v15.f3g.local-processing")
                Text("可以离开；当前设备上的原始文件和临时提取会丢弃，导入进度仍可继续。")
                    .font(V15Typography.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .awaitingProviderConsent:
            V15Section("2 · 解析授权") {
                VStack(alignment: .leading, spacing: V15Spacing.sm) {
                    Button { model.providerAuthorized.toggle() } label: {
                        Label(model.providerAuthorized ? "已确认仅发送脱敏内容" : "确认仅发送脱敏文字和页面位置", systemImage: model.providerAuthorized ? "checkmark.shield.fill" : "shield")
                    }
                    .accessibilityIdentifier("v15.f3g.provider-consent")
                    Text("本次范围 request_bound；离开、断线或取消不会在后台继续。")
                        .font(V15Typography.secondary)
                    V15ActionButton("开始解析", disabledReason: (!model.providerAuthorized ? .init(code: "consent_required", message: "请先确认本次脱敏信息授权。", fieldPath: nil) : model.writeReasons.first), accessibilityIdentifier: "v15.f3g.provider-start") {
                        model.requestProviderAttempt()
                    }
                }
            }
        case .providerResponseUnknown:
            V15Section("解析结果待确认") {
                Text("如果解析结果暂时不明，可以安全恢复，不会重复处理。")
                    .font(V15Typography.body)
                Button("继续恢复解析") { model.requestProviderRecovery() }
                    .accessibilityIdentifier("v15.f3g.provider-recover")
                    .disabled(model.isOffline || model.writeReasons.contains { $0.code == "unknown_import_status" })
            }
        case .reviewing:
            V15Section("3 · 校验账单") {
                V15ActionButton("校验账单", symbol: "checkmark.shield", disabledReason: model.writeReasons.first, accessibilityIdentifier: "v15.f3g.validation-run") { model.requestValidation() }
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var review: some View {
        if let board = model.workbench {
            V15Section("4 · 逐行审阅") {
                VStack(alignment: .leading, spacing: V15Spacing.md) {
                    batchProgress(board)
                    checkSummary(board)
                    if board.rows.isEmpty {
                        V15EmptyState(title: "没有可复核行", explanation: "暂时没有读取到账单明细。")
                    } else {
                        let index = min(reviewIndex, board.rows.count - 1)
                        rowStep(board.rows[index], index: index, total: board.rows.count)
                    }
                    rowReadControls(board)
                    adaptiveActions {
                        Button("上一行") { reviewIndex = max(reviewIndex - 1, 0) }
                            .disabled(reviewIndex == 0)
                            .frame(maxWidth: .infinity)
                        Button("跳过") { reviewIndex = min(reviewIndex + 1, max(board.rows.count - 1, 0)) }
                            .disabled(reviewIndex >= board.rows.count - 1)
                            .frame(maxWidth: .infinity)
                    }
                    auxiliaryReads(board)
                    V15ActionButton("查看确认预览", symbol: "eye", disabledReason: model.previewReasons.first, accessibilityIdentifier: "v15.f3g.preview") {
                        model.requestPreview(); showingConfirmation = true
                    }
                    disabledReasons(model.previewReasons)
                }
            }
        }
    }

    private func batchProgress(_ board: V15StatementWorkbench) -> some View {
        let resolved = board.rows.filter { $0.draft?.resolution.isExecutable == true }.count
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(board.status.displayName).font(V15Typography.body.weight(.semibold))
                Spacer()
                Text("已处置 \(resolved) / \(board.rows.count)").font(V15Typography.secondary.monospacedDigit())
            }
            GeometryReader { proxy in
                Capsule().fill(V15Palette.hairline.color).overlay(alignment: .leading) {
                    Capsule().fill(V15Palette.teal.color).frame(width: proxy.size.width * CGFloat(Double(resolved) / Double(max(board.rows.count, 1))))
                }
            }
            .frame(height: 6)
            if board.sourceUnavailableCount > 0 {
                Label("\(board.sourceUnavailableCount) 页识别内容不可用", systemImage: "exclamationmark.triangle")
                    .font(V15Typography.secondary.weight(.semibold))
                    .padding(9)
                    .background(V15Palette.provisional.color, in: RoundedRectangle(cornerRadius: V15Radius.tag))
                    .accessibilityIdentifier("v15.f3g.source-unavailable")
            }
        }
    }

    @ViewBuilder private func checkSummary(_ board: V15StatementWorkbench) -> some View {
        let failures = board.checks.filter { $0.status != "passed" }
        if !failures.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("对账校验仍未通过").font(V15Typography.body.weight(.semibold))
                ForEach(Array(failures.enumerated()), id: \.offset) { item in
                    Text("\(item.element.checkKind) · \(item.element.status)").font(V15Typography.secondary)
                }
                Text("校验失败不会自动生成平衡交易；确认预览会再次原样说明。")
                    .font(V15Typography.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(V15Spacing.sm)
            .background(V15Palette.provisional.color, in: RoundedRectangle(cornerRadius: V15Radius.decisionCard))
            .accessibilityIdentifier("v15.f3g.validation-warning")
        }
    }

    private func rowStep(_ row: V15StatementWorkbenchRow, index: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            HStack {
                Text("第 \(row.rowNumber) 行 / \(total)").font(V15Typography.cardTitle)
                Spacer()
                Text("第 \(row.rowNumber) 行").font(V15Typography.secondary.monospacedDigit())
            }
            evidenceCard(row)
            if !row.candidates.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("可能匹配 · 只是线索").font(V15Typography.label)
                    ForEach(row.candidates) { candidate in
                        HStack {
                            Text(candidate.transactionDate ?? "日期未知").font(V15Typography.secondary)
                            Spacer()
                            if let amount = candidate.amountMinor { V15MoneyText(minorUnits: amount, direction: .neutral) }
                        }
                    }
                    Text("同日同额只能提示匹配，不能证明是同一笔。")
                        .font(V15Typography.secondary)
                }
                .padding(V15Spacing.sm)
                .overlay { RoundedRectangle(cornerRadius: V15Radius.decisionCard).stroke(V15Palette.hairline.color) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("这一行是什么").font(V15Typography.label)
                resolutionButton("新建交易", resolution: .createNew, row: row)
                resolutionButton("匹配已有", resolution: .matchExisting, row: row, disabled: row.candidates.allSatisfy { $0.transactionID == nil })
                resolutionButton("非交易行", resolution: .ignoreNonTransaction, row: row)
                resolutionButton("有意忽略", resolution: .ignoreIntentional, row: row)
                resolutionButton("待定", resolution: .unresolved, row: row)
            }
            Text("保存处理方式不会改动账目。只有“确认已选行”才会创建或关联交易。")
                .font(V15Typography.secondary)
                .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)
            Button(model.selectedRowIDs.contains(row.id) ? "已加入本次确认" : "加入本次确认") { model.toggleRow(row.id) }
                .buttonStyle(.plain)
                .font(V15Typography.body.weight(.semibold))
                .foregroundStyle(V15Palette.teal.color)
                .accessibilityIdentifier("v15.f3g.select.\(row.id)")
                .disabled(!model.writeReasons.isEmpty)
        }
        .padding(V15Spacing.md)
        .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.decisionCard))
        .overlay { RoundedRectangle(cornerRadius: V15Radius.decisionCard).stroke(V15Palette.hairline.color) }
    }

    private func evidenceCard(_ row: V15StatementWorkbenchRow) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("第 \(row.pageNumber.map(String.init) ?? "—") 页 · 脱敏内容").font(V15Typography.label)
                Spacer()
                if row.evidenceTextMasked == nil { Text("内容不可用").font(V15Typography.label) }
            }
            Text(row.evidenceTextMasked ?? "页面图像与文本均不可用；只保留行号、页码与结构化候选。")
                .font(V15Typography.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(V15Spacing.md)
        .background(row.evidenceTextMasked == nil ? V15Palette.provisional.color : V15Palette.paper.color, in: RoundedRectangle(cornerRadius: V15Radius.decisionCard))
        .overlay { RoundedRectangle(cornerRadius: V15Radius.decisionCard).stroke(V15Palette.hairline.color, style: StrokeStyle(lineWidth: 1, dash: row.evidenceTextMasked == nil ? [5, 4] : [])) }
    }

    private func resolutionButton(_ title: String, resolution: V15StatementResolution, row: V15StatementWorkbenchRow, disabled: Bool = false) -> some View {
        let selected = row.draft?.resolution == resolution
        return Button {
            model.requestResolution(row: row, as: resolution)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                Text(title).font(V15Typography.body.weight(.medium))
                Spacer()
            }
            .padding(.horizontal, 13)
            .frame(minHeight: 48)
            .background(selected ? V15Palette.teal.color.opacity(0.10) : V15Palette.paper.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
            .overlay { RoundedRectangle(cornerRadius: V15Radius.control).stroke(selected ? V15Palette.teal.color : V15Palette.hairline.color) }
        }
        .buttonStyle(.plain)
        .disabled(disabled || !model.writeReasons.isEmpty)
        .accessibilityIdentifier("v15.f3g.resolve-\(resolutionIdentifier(resolution)).\(row.id)")
    }

    @ViewBuilder private func auxiliaryReads(_ board: V15StatementWorkbench) -> some View {
        DisclosureGroup("批次筛选") {
            VStack(alignment: .leading, spacing: V15Spacing.sm) {
                Picker("识别内容", selection: Binding(get: { model.workbenchFilter.evidenceState ?? "all" }, set: { model.requestWorkbenchEvidenceFilter($0 == "all" ? nil : $0) })) {
                    Text("全部").tag("all"); Text("仅可用").tag("available"); Text("仅不可用").tag("unavailable")
                }
                .accessibilityIdentifier("v15.f3g.filter")
            }
            .padding(.top, V15Spacing.sm)
        }
    }

    @ViewBuilder private func rowReadControls(_ board: V15StatementWorkbench) -> some View {
        adaptiveActions {
            Button(model.isLoadingPage ? "正在读取脱敏页面…" : "查看脱敏页面") {
                model.requestPage(board.rows[safe: reviewIndex]?.pageNumber ?? 1)
            }
            .accessibilityIdentifier("v15.f3g.page-load")
            .disabled(model.isLoadingPage)
            Button("刷新复核") { model.requestReloadWorkbench() }
                .accessibilityIdentifier("v15.f3g.reload-workbench")
        }
        if model.isLoadingPage { V15LoadingSkeleton(layout: .compact).accessibilityIdentifier("v15.f3g.page-loading") }
        if let page = model.page {
            Text(page.sourceAvailable ? (page.evidenceTextMasked ?? "仅位置框") : "该来源不可用")
                .font(V15Typography.secondary)
                .accessibilityIdentifier("v15.f3g.masked-page")
        }
        if let failure = model.pageFailure {
            V15ServiceErrorState(message: failure.message, retryIdentifier: "v15.f3g.page-retry", retry: { model.requestPage(board.rows[safe: reviewIndex]?.pageNumber ?? 1) })
                .accessibilityIdentifier("v15.f3g.page-error")
        }
        if board.nextCursor != nil {
            Button(model.isLoadingMore ? "正在加载…" : "加载更多复核行") { model.requestNextWorkbench() }
                .accessibilityIdentifier("v15.f3g.load-next")
                .disabled(model.isLoadingMore)
        }
        if let failure = model.workbenchFailure {
            V15ServiceErrorState(message: failure.message, retry: { model.requestReloadWorkbench() })
                .accessibilityIdentifier("v15.f3g.workbench-error")
        }
    }

    @ViewBuilder private var result: some View {
        if let receipt = model.receipt {
            let remaining = model.workbench?.rows.filter { !$0.isConfirmed }.count ?? 0
            V15Section("确认结果") {
                VStack(alignment: .leading, spacing: V15Spacing.sm) {
                    Label("已确认 \(receipt.confirmedRowIDs.count) 行", systemImage: "checkmark.circle.fill")
                        .font(V15Typography.surfaceTitle)
                        .foregroundStyle(V15Palette.teal.color)
                    Text("新建 \(receipt.createdCount) · 关联 \(receipt.matchedCount) · 跳过 \(receipt.skippedCount)")
                        .font(V15Typography.body.monospacedDigit())
                    Text(remaining > 0 ? "批次状态：部分确认 · 当前已载入范围剩余 \(remaining) 行" : "当前已载入范围已经处理完毕")
                        .font(V15Typography.secondary)
                    Text("新建交易会标记为账单导入；如有校验差异，仍需回到账单明细修正。")
                        .font(V15Typography.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("v15.f3g.receipt")
            }
        }
        if case .responseUnknown = model.phase {
            V15Section("确认结果未知") {
                Text("检查确认结果不会重复导入。")
                Button("检查确认结果") { model.requestReceiptReadback() }.accessibilityIdentifier("v15.f3g.receipt-readback")
            }
        }
    }

    @ViewBuilder private var error: some View {
        if let message = model.resolutionReadbackMessage {
            Text(message).font(V15Typography.secondary).accessibilityIdentifier("v15.f3g.resolution-readback-status")
        }
        if model.isResolutionReadbackInFlight {
            V15LoadingSkeleton(layout: .compact).accessibilityIdentifier("v15.f3g.resolution-readback-loading")
        }
        if case .failed(let failure) = model.phase {
            V15ServiceErrorState(message: failure.message, retryIdentifier: failure.code == "resolution_response_unknown" ? "v15.f3g.resolution-readback-retry" : nil, retry: { model.retryFromFailure() })
                .accessibilityIdentifier("v15.f3g.error")
        }
    }

    private var confirmationSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.lg) {
                    confirmationContent
                }
                .padding(V15Spacing.md)
            }
            .background(V15Palette.paper.color)
            .navigationTitle("确认前检查")
            .toolbar {
                Button("关闭") { showingConfirmation = false }
                    .accessibilityIdentifier("v15.f3g.preview-dismiss")
                    .disabled(model.isConfirmationInFlight)
            }
        }
        .interactiveDismissDisabled(model.isConfirmationInFlight)
        .accessibilityIdentifier("v15.f3g.confirmation-sheet")
    }

    @ViewBuilder private var confirmationContent: some View {
        if model.isPreviewLoading {
            V15LoadingSkeleton()
            Text("正在准备确认预览…").accessibilityIdentifier("v15.f3g.preview-loading")
            Text("尚未创建或关联任何流水。请保持当前页面。 ").font(V15Typography.secondary)
        } else if let failure = model.previewFailure {
            Text(failure.kind == .conflict ? "确认预览已过期" : "确认预览暂不可用")
                .font(V15Typography.surfaceTitle)
                .accessibilityIdentifier("v15.f3g.preview-failure")
            Text(failure.message).font(V15Typography.body)
            Button("重试获取预览") { model.requestPreview() }.accessibilityIdentifier("v15.f3g.preview-retry")
        } else if model.isConfirmationInFlight {
            V15LoadingSkeleton(layout: .decisionCard).accessibilityIdentifier("v15.f3g.confirming")
            Text("正在确认，请勿重复操作。").font(V15Typography.secondary)
        } else if let receipt = model.receipt {
            Label("确认完成", systemImage: "checkmark.circle.fill").font(V15Typography.surfaceTitle).foregroundStyle(V15Palette.teal.color)
            Text("\(receipt.status) · 新建 \(receipt.createdCount) · 匹配 \(receipt.matchedCount) · 跳过 \(receipt.skippedCount)")
                .accessibilityIdentifier("v15.f3g.sheet-receipt")
        } else if case .responseUnknown = model.phase {
            Text("确认结果未知").font(V15Typography.surfaceTitle).accessibilityIdentifier("v15.f3g.sheet-response-unknown")
            Text("检查确认结果不会重复导入。")
        } else if let preview = model.preview {
            Text("确认 \(preview.counts.selected) 行").font(V15Typography.surfaceTitle)
            Text("预览 · 尚未提交").font(V15Typography.label)
            adaptiveActions {
                previewMetric("新建", preview.counts.createNew)
                previewMetric("匹配", preview.counts.matchExisting)
                previewMetric("跳过", preview.counts.ignoreNonTransaction + preview.counts.ignoreIntentional)
            }
            V15Section("已知金额合计") {
                V15MoneyText(minorUnits: preview.amounts.knownTotalMinor, direction: .neutral, font: V15Typography.moneyLarge)
                Text("未知金额 \(preview.amounts.unknownSelectedCount) 行不参与相加。")
                    .font(V15Typography.secondary)
            }
            if !preview.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("对账校验仍为失败").font(V15Typography.body.weight(.semibold))
                    ForEach(preview.warnings, id: \.self) { Text($0).font(V15Typography.secondary) }
                    Text("确认不会创建任何自动平衡交易。")
                        .font(V15Typography.secondary.weight(.semibold))
                }
                .padding(V15Spacing.md)
                .background(V15Palette.provisional.color, in: RoundedRectangle(cornerRadius: V15Radius.decisionCard))
            }
            Text("所选行会一起确认；如果其中一行失败，本次不会导入任何一行。仍有 \(preview.counts.batchUnresolved) 行待处理。")
                .font(V15Typography.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("将按上方预览确认所选行。")
                .font(V15Typography.secondary)
            V15ActionButton("确认 \(preview.counts.selected) 行", symbol: "checkmark", disabledReason: model.confirmReasons.first, accessibilityIdentifier: "v15.f3g.confirm") { model.requestConfirm() }
            disabledReasons(model.confirmReasons)
        }
    }

    private func previewMetric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(V15Typography.secondary)
            Text(String(value)).font(V15Typography.cardTitle.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(V15Spacing.sm)
        .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
    }

    private func adaptiveActions<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: V15Spacing.sm))
            : AnyLayout(HStackLayout(alignment: .center, spacing: V15Spacing.sm))
        return layout { content() }
    }

    private func resolutionIdentifier(_ resolution: V15StatementResolution) -> String {
        switch resolution {
        case .createNew: "create"
        case .ignoreIntentional: "ignore"
        default: resolution.rawValue
        }
    }

    @ViewBuilder private func disabledReasons(_ reasons: [V15DisabledReason]) -> some View {
        ForEach(reasons, id: \.code) {
            Text($0.message).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.70))
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
