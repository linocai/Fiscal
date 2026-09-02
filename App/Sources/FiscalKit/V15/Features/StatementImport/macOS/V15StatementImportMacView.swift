import SwiftUI
import UniformTypeIdentifiers

/// The desktop import surface is deliberately spatial: page evidence, rows,
/// and the selected row's disposition remain visible together. None of these
/// surfaces imply a ledger write until the separate confirmation preview.
public struct V15StatementImportMacView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: V15StatementImportModel
    @State private var importer = false
    @State private var selectedID: UUID?
    @State private var confirmation = false
    private let initialGalleryScenario: String?

    public init(services: V15Services, offlineSnapshotAt: Date? = nil, initialGalleryScenario: String? = nil) {
        _model = State(initialValue: V15StatementImportModel(services: services, offlineSnapshotAt: offlineSnapshotAt))
        self.initialGalleryScenario = initialGalleryScenario
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
            HStack(spacing: 0) {
                evidencePane.frame(minWidth: V15MacLayout.compactStatementImportWidths.evidence, idealWidth: 260, maxWidth: 300)
                Divider()
                rowPane.frame(minWidth: V15MacLayout.compactStatementImportWidths.rows, maxWidth: .infinity)
                Divider()
                inspector.frame(minWidth: V15MacLayout.compactStatementImportWidths.inspector, idealWidth: 340, maxWidth: 390)
            }
        }
        .v15MacWorkspaceCanvas()
        .accessibilityElement(children: .contain)
        .fileImporter(isPresented: $importer, allowedContentTypes: [.pdf], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { model.selectFile(url: url) }
        }
        .sheet(isPresented: $confirmation, onDismiss: { model.dismissPreview() }) {
            confirmationSheet.frame(minWidth: 560, minHeight: 500)
        }
        .task {
            if model.batch == nil, let initialGalleryScenario {
                await model.prepareSyntheticGallery(initialGalleryScenario)
                selectedID = model.workbench?.rows.first?.id
                if ["statement-import-preview", "statement-import-preview-error", "statement-import-preview-conflict"].contains(initialGalleryScenario) { confirmation = true }
            }
        }
        .onChange(of: model.workbench?.rows.map(\.id)) { _, ids in
            guard let ids else { selectedID = nil; return }
            if selectedID.map({ !ids.contains($0) }) != false { selectedID = ids.first }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active, initialGalleryScenario == nil { model.sceneDidLeaveActive() } }
        .onDisappear { model.sceneDidLeaveActive() }
        .accessibilityIdentifier("v15.f3g.statement-import.macos")
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("账单导入").font(V15Typography.cardTitle)
            if let batch = model.batch {
                Text(batch.displayName).font(V15Typography.secondary)
                Text(batch.status.displayName)
                    .font(V15Typography.label)
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(V15Palette.card.color, in: Capsule())
            }
            Spacer(minLength: 12)
            Button("选择 PDF") { importer = true }
                .disabled(!model.writeReasons.isEmpty)
                .accessibilityIdentifier("v15.f3g.mac.pick-file")
            Button("刷新") { model.requestReloadWorkbench() }
                .disabled(model.workbench == nil)
                .accessibilityIdentifier("v15.f3g.mac.reload")
            V15ActionButton(model.preview.map { "确认已选 \($0.counts.selected) 行" } ?? "确认已选行", disabledReasons: model.previewReasons, showsDisabledReasons: false, accessibilityIdentifier: "v15.f3g.mac.preview") { model.requestPreview(); confirmation = true }
        }
        .padding(.horizontal, 18)
        .frame(height: 50)
        .background(V15Palette.card.color)
    }

    private var evidencePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneHeader("页面证据", detail: "只保留脱敏内容")
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.md) {
                    intakeStatus
                    if let snapshot = model.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: snapshot) }
                    if let board = model.workbench {
                        let pages = Array(Set(board.rows.compactMap(\.pageNumber))).sorted()
                        if pages.isEmpty {
                            V15EmptyState(title: "没有页面引用", explanation: "当前复核行没有可查看的页码。")
                        } else {
                            ForEach(pages, id: \.self) { page in
                                pageButton(page, rows: board.rows.filter { $0.pageNumber == page })
                            }
                        }
                        if board.sourceUnavailableCount > 0 {
                            Label("\(board.sourceUnavailableCount) 页识别内容不可用", systemImage: "exclamationmark.triangle")
                                .font(V15Typography.secondary.weight(.semibold))
                                .padding(V15Spacing.sm)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(V15Palette.provisional.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
                                .accessibilityIdentifier("v15.f3g.mac.source-unavailable")
                        }
                    }
                    if model.isLoadingPage { V15LoadingSkeleton().accessibilityIdentifier("v15.f3g.mac.page-loading") }
                    if let page = model.page { pageEvidence(page) }
                    if let failure = model.pageFailure {
                        V15ServiceErrorState(message: failure.message, retryIdentifier: "v15.f3g.mac.page-retry", retry: { model.requestPage(model.page?.pageNumber ?? 1) })
                            .accessibilityIdentifier("v15.f3g.mac.page-error")
                    }
                    privacyNote
                }
                .padding(V15Spacing.md)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f3g.mac.intake")
    }

    @ViewBuilder private var intakeStatus: some View {
        switch model.phase {
        case .localProcessing, .registering, .extracting, .parsing:
            V15LoadingSkeleton()
        case .awaitingProviderConsent:
            VStack(alignment: .leading, spacing: V15Spacing.sm) {
                Toggle("仅发送脱敏内容", isOn: $model.providerAuthorized)
                    .accessibilityIdentifier("v15.f3g.mac.provider-consent")
                Text("execution_scope = request_bound").font(V15Typography.secondary.monospacedDigit())
                Button("开始解析") { model.requestProviderAttempt() }
                    .disabled(!model.providerAuthorized || !model.writeReasons.isEmpty)
            }
        case .providerResponseUnknown:
            VStack(alignment: .leading, spacing: V15Spacing.sm) {
                Text("解析结果未知；不会创建一份新授权重试。 ").font(V15Typography.secondary)
                V15ActionButton("继续恢复解析", disabledReason: providerRecoveryDisabledReason, accessibilityIdentifier: "v15.f3g.mac.provider-recover") { model.requestProviderRecovery() }
            }
        case .reviewing:
            Button("校验账单") { model.requestValidation() }
                .accessibilityIdentifier("v15.f3g.mac.validation")
                .disabled(!model.writeReasons.isEmpty)
        default:
            if let batch = model.batch {
                Label(batch.status.displayName, systemImage: "doc.text")
                    .font(V15Typography.body.weight(.semibold))
                    .accessibilityIdentifier("v15.f3g.mac.status")
            } else {
                Text("选择 PDF 后，原始文件只在本机提取。 ").font(V15Typography.secondary)
            }
        }
    }

    private var providerRecoveryDisabledReason: V15DisabledReason? {
        if model.isOffline { return .init(code: "offline_read_only", message: "离线时不能恢复解析。", fieldPath: nil) }
        if model.writeReasons.contains(where: { $0.code == "unknown_import_status" }) {
            return .init(code: "unknown_import_status", message: "暂时无法识别账单状态；当前只供查看，不能恢复解析。", fieldPath: nil)
        }
        return nil
    }

    private func pageButton(_ page: Int, rows: [V15StatementWorkbenchRow]) -> some View {
        let unavailable = rows.allSatisfy { $0.evidenceTextMasked == nil }
        return Button { model.requestPage(page) } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(unavailable ? V15Palette.provisional.color : V15Palette.card.color)
                    .frame(width: 42, height: 56)
                    .overlay { Text(String(page)).font(V15Typography.cardTitle.monospacedDigit()) }
                    .overlay { RoundedRectangle(cornerRadius: 4).stroke(V15Palette.hairline.color) }
                VStack(alignment: .leading, spacing: 4) {
                    Text("第 \(page) 页").font(V15Typography.body.weight(.semibold))
                    Text(unavailable ? "仅结构化引用" : "脱敏文本 · \(rows.count) 行")
                        .font(V15Typography.secondary)
                        .foregroundStyle(V15Palette.ink.color.opacity(0.62))
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(model.page?.pageNumber == page ? V15Palette.teal.color.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: V15Radius.control))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("v15.f3g.mac.page.\(page)")
    }

    private func pageEvidence(_ page: V15StatementWorkbenchPage) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("第 \(page.pageNumber) 页 · \(page.sourceAvailable ? "脱敏内容" : "内容不可用")")
                .font(V15Typography.label)
            Text(page.evidenceTextMasked ?? "图像与文本不可用；保留页码、位置框和结构化候选。")
                .font(V15Typography.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("v15.f3g.mac.masked-page")
        }
        .padding(V15Spacing.sm)
        .background(page.sourceAvailable ? V15Palette.card.color : V15Palette.provisional.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
        .overlay { RoundedRectangle(cornerRadius: V15Radius.control).stroke(V15Palette.hairline.color, style: StrokeStyle(lineWidth: 1, dash: page.sourceAvailable ? [] : [5, 4])) }
    }

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("保存什么").font(V15Typography.label)
            Text("保留页码、脱敏内容、识别结果、你的修正和来源记录。原始 PDF 与完整文本不会长期保存。")
                .font(V15Typography.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, V15Spacing.sm)
    }

    private var rowPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("行").font(V15Typography.surfaceTitle)
                    if let board = model.workbench {
                        let resolved = board.rows.filter { $0.draft?.resolution.isExecutable == true }.count
                        Text("\(board.rows.count) 行 · 已处置 \(resolved) · 待定 \(board.rows.count - resolved)")
                            .font(V15Typography.secondary.monospacedDigit())
                    }
                }
                Spacer()
                Picker("识别内容", selection: Binding(get: { model.workbenchFilter.evidenceState ?? "all" }, set: { model.requestWorkbenchEvidenceFilter($0 == "all" ? nil : $0) })) {
                    Text("全部").tag("all"); Text("可用").tag("available"); Text("缺失").tag("unavailable")
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .accessibilityIdentifier("v15.f3g.mac.filter")
            }
            .padding(V15Spacing.md)
            validationStrip
            Divider()
            Group {
                if let board = model.workbench {
                    if board.rows.isEmpty {
                        V15EmptyState(title: "没有可复核行", explanation: "暂时没有读取到账单明细。")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                rowHeader
                                ForEach(board.rows) { row in rowButton(row) }
                                if board.nextCursor != nil {
                                    Button(model.isLoadingMore ? "正在加载…" : "加载更多行") { model.requestNextWorkbench() }
                                        .padding(V15Spacing.md)
                                        .disabled(model.isLoadingMore)
                                        .accessibilityIdentifier("v15.f3g.mac.load-next")
                                }
                                if let failure = model.workbenchFailure {
                                    V15ServiceErrorState(message: failure.message, retry: { model.requestReloadWorkbench() })
                                        .padding(V15Spacing.md)
                                        .accessibilityIdentifier("v15.f3g.mac.workbench-error")
                                }
                            }
                        }
                        .accessibilityIdentifier("v15.f3g.mac.rows")
                    }
                } else {
                    VStack { Spacer(); phaseFallback; Spacer() }
                }
            }
            footerHints
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f3g.mac.workbench")
    }

    @ViewBuilder private var validationStrip: some View {
        if let board = model.workbench {
            let failures = board.checks.filter { $0.status != "passed" }
            if !failures.isEmpty {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("对账校验仍未通过").font(V15Typography.body.weight(.semibold))
                        Text("确认时会再次原样呈现；不会创建任何自动平衡交易。")
                            .font(V15Typography.secondary)
                    }
                    Spacer()
                    Text(failures.map { $0.checkKind }.joined(separator: " · ")).font(V15Typography.secondary)
                }
                .padding(.horizontal, V15Spacing.md).padding(.bottom, V15Spacing.sm)
                .accessibilityIdentifier("v15.f3g.mac.validation-warning")
            }
        }
    }

    private var rowHeader: some View {
        HStack(spacing: 10) {
            Text("").frame(width: 20)
            Text("行").frame(width: 34, alignment: .leading)
            Text("证据").frame(maxWidth: .infinity, alignment: .leading)
            Text("页").frame(width: 36, alignment: .trailing)
            Text("处置").frame(width: 116, alignment: .trailing)
        }
        .font(V15Typography.label)
        .foregroundStyle(V15Palette.ink.color.opacity(0.58))
        .padding(.horizontal, 18).frame(height: 34)
        .background(V15Palette.card.color)
    }

    private func rowButton(_ row: V15StatementWorkbenchRow) -> some View {
        Button { selectedID = row.id } label: {
            HStack(spacing: 10) {
                Image(systemName: model.selectedRowIDs.contains(row.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.selectedRowIDs.contains(row.id) ? V15Palette.teal.color : V15Palette.ink.color.opacity(0.35))
                    .frame(width: 20)
                Text(String(row.rowNumber)).font(V15Typography.secondary.monospacedDigit()).frame(width: 34, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.evidenceTextMasked ?? "证据缺失 · 仅结构化候选")
                        .font(V15Typography.body)
                        .lineLimit(2)
                    if let candidate = row.candidates.first {
                        HStack(spacing: 8) {
                            Text("可能匹配").font(V15Typography.label)
                            if let date = candidate.transactionDate { Text(date).font(V15Typography.secondary.monospacedDigit()) }
                            if let amount = candidate.amountMinor { V15MoneyText(minorUnits: amount, direction: .neutral, font: V15Typography.secondary.monospacedDigit()) }
                        }
                        .foregroundStyle(V15Palette.ink.color.opacity(0.58))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(row.pageNumber.map(String.init) ?? "—").font(V15Typography.secondary.monospacedDigit()).frame(width: 36, alignment: .trailing)
                Text(row.draft?.resolution.displayName ?? "未处理").font(V15Typography.secondary.weight(.semibold)).frame(width: 116, alignment: .trailing)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(selectedID == row.id ? V15Palette.teal.color.opacity(0.10) : (row.evidenceTextMasked == nil ? V15Palette.provisional.color.opacity(0.55) : Color.clear))
            .overlay(alignment: .bottom) { Rectangle().fill(V15Palette.hairline.color).frame(height: 1) }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(model.selectedRowIDs.contains(row.id) ? "移出本次确认" : "加入本次确认") { model.toggleRow(row.id) }
                .disabled(!model.writeReasons.isEmpty)
        }
        .accessibilityIdentifier("v15.f3g.mac.row.\(row.id)")
    }

    @ViewBuilder private var phaseFallback: some View {
        if case .failed(let failure) = model.phase {
            if V15StateVisualSpec.resolve(failure).semantic == .outcomeUnknown {
                V15OutcomeUnknownState(
                    message: failure.message,
                    actionTitle: "检查最新状态",
                    action: { model.retryFromFailure() }
                )
            } else {
                V15ServiceErrorState(message: failure.message, retry: { model.retryFromFailure() })
            }
        } else if model.batch == nil {
            emptyIntake
        } else {
            V15LoadingSkeleton()
        }
    }

    private var emptyIntake: some View {
        VStack(spacing: V15Spacing.lg) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(V15Palette.teal.color)
            VStack(spacing: V15Spacing.xs) {
                Text("选择一份 PDF 开始").font(V15Typography.cardTitle)
                Text("原始文件仅在本机提取；确认前不会创建或关联账目。")
                    .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    .multilineTextAlignment(.center)
            }
            Button { importer = true } label: {
                Label("选择 PDF 文件", systemImage: "plus")
                    .frame(minWidth: 176, minHeight: 42)
            }
            .buttonStyle(.borderedProminent)
            .tint(V15Palette.teal.color)
            .accessibilityIdentifier("v15.f3g.mac.empty.pick-file")
            HStack(spacing: 5) {
                ForEach(["选择文件", "本机提取", "解析", "逐行处置", "预览", "确认"], id: \.self) { phase in
                    Text(phase).font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.62))
                    if phase != "确认" { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(V15Palette.ink.color.opacity(0.36)) }
                }
            }
            .accessibilityLabel("导入阶段：选择文件、本机提取、解析、逐行处置、预览、确认")
        }
        .padding(36)
        .frame(maxWidth: 580)
        .v15MacPanel()
        .accessibilityIdentifier("v15.f3g.mac.empty-intake")
    }

    private var footerHints: some View {
        HStack(spacing: 18) {
            Text("选择行后在右侧处置")
            Text("保存处理方式不会改动账目")
            Spacer()
            if let count = model.workbench?.rows.count { Text("已载入 \(count) 行") }
        }
        .font(V15Typography.secondary)
        .foregroundStyle(V15Palette.ink.color.opacity(0.58))
        .padding(.horizontal, 18).frame(height: 36)
        .background(V15Palette.card.color)
    }

    @ViewBuilder private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneHeader("处置", detail: selectedRow.map { "第 \($0.rowNumber) 行" } ?? "选择一行")
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.md) {
                    if let message = model.resolutionReadbackMessage {
                        Text(message).font(V15Typography.secondary).accessibilityIdentifier("v15.f3g.mac.resolution-readback-status")
                    }
                    if model.isResolutionReadbackInFlight {
                        V15LoadingSkeleton(layout: .decisionCard).accessibilityIdentifier("v15.f3g.mac.resolution-readback-loading")
                    }
                    if case .failed(let failure) = model.phase, failure.code == "resolution_response_unknown" {
                        V15OutcomeUnknownState(
                            title: "行处理结果暂时不明",
                            message: failure.message,
                            actionTitle: "读取完整复核行",
                            actionIdentifier: "v15.f3g.mac.resolution-readback-retry",
                            action: { model.retryFromFailure() }
                        )
                        .accessibilityIdentifier("v15.f3g.mac.resolution-readback-unknown")
                    }
                    if let row = selectedRow { inspectorRow(row) }
                    else { Text("选择一行以查看脱敏信息、匹配候选和可用操作。").font(V15Typography.secondary) }
                    Divider()
                    V15ActionButton("确认预览", disabledReasons: model.previewReasons, disabledReasonAccessibilityIdentifier: "v15.f3g.mac.preview-inspector.reason", accessibilityIdentifier: "v15.f3g.mac.preview-inspector") { model.requestPreview(); confirmation = true }
                    receiptSurface
                }
                .padding(V15Spacing.md)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f3g.mac.inspector")
    }

    private var selectedRow: V15StatementWorkbenchRow? {
        model.workbench?.rows.first { $0.id == selectedID }
    }

    private func inspectorRow(_ row: V15StatementWorkbenchRow) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text("脱敏内容").font(V15Typography.label); Spacer(); if row.evidenceTextMasked == nil { Text("内容不可用").font(V15Typography.label) } }
                Text(row.evidenceTextMasked ?? "页面图像不可用；这里只保留识别出的候选信息。")
                    .font(V15Typography.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(V15Spacing.sm)
            .background(row.evidenceTextMasked == nil ? V15Palette.provisional.color : V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
            if !row.candidates.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("可能匹配 · 不能证明重复").font(V15Typography.label)
                    ForEach(row.candidates) { candidate in
                        HStack {
                            Text(candidate.transactionDate ?? "日期未知").font(V15Typography.secondary)
                            Spacer()
                            if let amount = candidate.amountMinor { V15MoneyText(minorUnits: amount, direction: .neutral) }
                        }
                    }
                }
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
            Button(model.selectedRowIDs.contains(row.id) ? "移出本次确认" : "加入本次确认") { model.toggleRow(row.id) }
                .disabled(row.draft?.resolution.isExecutable != true || !model.writeReasons.isEmpty)
                .accessibilityIdentifier("v15.f3g.mac.select.\(row.id)")
        }
    }

    private func resolutionButton(_ title: String, resolution: V15StatementResolution, row: V15StatementWorkbenchRow, disabled: Bool = false) -> some View {
        let selected = row.draft?.resolution == resolution
        return Button { model.requestResolution(row: row, as: resolution) } label: {
            HStack(spacing: 9) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                Text(title).font(V15Typography.body)
                Spacer()
            }
            .padding(.horizontal, 12).frame(minHeight: 40)
            .background(selected ? V15Palette.teal.color.opacity(0.10) : V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
            .overlay { RoundedRectangle(cornerRadius: V15Radius.control).stroke(selected ? V15Palette.teal.color : V15Palette.hairline.color) }
        }
        .buttonStyle(.plain)
        .disabled(disabled || !model.writeReasons.isEmpty)
        .accessibilityIdentifier("v15.f3g.mac.resolve-\(resolution.rawValue).\(row.id)")
    }

    @ViewBuilder private var receiptSurface: some View {
        if let receipt = model.receipt {
            VStack(alignment: .leading, spacing: 7) {
                Label("已确认 \(receipt.confirmedRowIDs.count) 行", systemImage: "checkmark.circle.fill")
                    .font(V15Typography.cardTitle).foregroundStyle(V15Palette.teal.color)
                Text("新建 \(receipt.createdCount) · 匹配 \(receipt.matchedCount) · 跳过 \(receipt.skippedCount)")
                if let board = model.workbench {
                    Text(board.status == .partiallyConfirmed ? "部分确认 · 继续审阅剩余行" : board.status.displayName)
                        .font(V15Typography.secondary)
                }
            }
            .padding(V15Spacing.sm)
            .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
            .accessibilityIdentifier("v15.f3g.mac.receipt")
        }
        if case .responseUnknown = model.phase {
            Text("确认结果未知；不会重发。 ").font(V15Typography.secondary)
            Button("检查确认结果") { model.requestReceiptReadback() }.accessibilityIdentifier("v15.f3g.mac.readback")
        }
    }

    private var confirmationSheet: some View {
        VStack(alignment: .leading, spacing: V15Spacing.lg) {
            Text("确认预览").font(V15Typography.surfaceTitle)
            confirmationContent
            Spacer(minLength: 0)
        }
        .padding(V15Spacing.lg)
        .background(V15Palette.paper.color)
        .accessibilityIdentifier("v15.f3g.mac.confirmation")
    }

    @ViewBuilder private var confirmationContent: some View {
        if model.isPreviewLoading {
            V15LoadingSkeleton()
            Text("正在准备确认预览…").accessibilityIdentifier("v15.f3g.mac.preview-loading")
            Text("尚未创建流水。 ").font(V15Typography.secondary)
        } else if let failure = model.previewFailure {
            Text(failure.kind == .conflict ? "确认预览已过期" : "确认预览暂不可用")
                .font(V15Typography.cardTitle)
                .accessibilityIdentifier("v15.f3g.mac.preview-failure")
            Text(failure.message)
            Button("重试获取预览") { model.requestPreview() }.accessibilityIdentifier("v15.f3g.mac.preview-retry")
        } else if model.isConfirmationInFlight {
            V15LoadingSkeleton(layout: .decisionCard).accessibilityIdentifier("v15.f3g.mac.confirming")
            Text("正在确认，请勿重复操作。").font(V15Typography.secondary)
        } else if let receipt = model.receipt {
            Label("确认完成", systemImage: "checkmark.circle.fill").font(V15Typography.surfaceTitle).foregroundStyle(V15Palette.teal.color)
            Text("\(receipt.status) · 新建 \(receipt.createdCount) · 匹配 \(receipt.matchedCount) · 跳过 \(receipt.skippedCount)")
                .accessibilityIdentifier("v15.f3g.mac.sheet-receipt")
        } else if case .responseUnknown = model.phase {
            Text("确认结果未知").font(V15Typography.cardTitle).accessibilityIdentifier("v15.f3g.mac.sheet-response-unknown")
            Text("检查确认结果不会重复导入。")
        } else if let preview = model.preview {
            Text("确认 \(preview.counts.selected) 行").font(V15Typography.cardTitle)
            HStack(spacing: 12) {
                metric("新建", preview.counts.createNew)
                metric("匹配", preview.counts.matchExisting)
                metric("跳过", preview.counts.ignoreNonTransaction + preview.counts.ignoreIntentional)
                metric("批次待定", preview.counts.batchUnresolved)
            }
            V15Section("已知金额合计") {
                V15MoneyText(minorUnits: preview.amounts.knownTotalMinor, direction: .neutral, font: V15Typography.moneyLarge)
                Text("未知来源 \(preview.amounts.unknownSelectedCount) 行不参与相加。 ").font(V15Typography.secondary)
            }
            if !preview.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("对账校验仍为失败").font(V15Typography.body.weight(.semibold))
                    ForEach(preview.warnings, id: \.self) { Text($0).font(V15Typography.secondary) }
                    Text("确认这些行不会创建任何自动平衡交易。 ").font(V15Typography.secondary.weight(.semibold))
                }
                .padding(V15Spacing.sm)
                .background(V15Palette.provisional.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
            }
            Text("所选行会一起确认；如果其中一行失败，本次不会导入任何一行。")
                .font(V15Typography.secondary)
            HStack {
                V15ActionButton("返回", kind: .secondary, disabledReason: model.isConfirmationInFlight ? .init(code: "confirmation_in_flight", message: "正在确认，请稍候。", fieldPath: nil) : nil) { confirmation = false }
                Spacer()
                V15ActionButton("确认 \(preview.counts.selected) 行", disabledReasons: model.confirmReasons, accessibilityIdentifier: "v15.f3g.mac.confirm") { model.requestConfirm() }
            }
        }
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(V15Typography.secondary)
            Text(String(value)).font(V15Typography.cardTitle.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(V15Spacing.sm)
        .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
    }

    private func paneHeader(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(V15Typography.cardTitle)
            Text(detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.58))
        }
        .padding(.horizontal, V15Spacing.md)
        .frame(height: 58, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(V15Palette.card.color)
    }
}
