import SwiftUI

#if os(iOS)
public struct V15ReimbursementView: View {
    @State private var model: V15ReimbursementModel
    @State private var operationSheet: OperationSheet?

    private enum OperationSheet: Identifiable {
        case claimReplacement, cancellation, claimActions, receiptReplacement(UUID), receiptActions(UUID)
        var id: String {
            switch self {
            case .claimReplacement: "claim-replacement"
            case .cancellation: "cancellation"
            case .claimActions: "claim-actions"
            case .receiptReplacement(let id): "receipt-replacement-\(id)"
            case .receiptActions(let id): "receipt-actions-\(id)"
            }
        }
    }

    public init(services: V15Services, offlineSnapshotAt: Date? = nil) {
        _model = State(initialValue: V15ReimbursementModel(services: services, offlineSnapshotAt: offlineSnapshotAt))
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.lg) {
                    header
                    if let snapshot = model.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: snapshot).accessibilityIdentifier("v15.f3c.offline") }
                    listSurface
                    if let claim = model.selectedClaim { claimDetail(claim) }
                }
                .padding(V15Spacing.md)
                .frame(maxWidth: 720, alignment: .leading)
            }
            .background(V15Palette.paper.color)
            .navigationTitle("报销")
            .toolbar { ToolbarItem(placement: .primaryAction) { Button { Task { await model.refresh() } } label: { Image(systemName: V15Symbol.retry) }.accessibilityLabel("刷新报销事实").accessibilityIdentifier("v15.f3c.refresh") } }
        }
        .task { if model.phase == .idle { await model.load() } }
        .sheet(isPresented: Binding(get: { model.newClaimSheetVisible }, set: { if !$0 { model.dismissNewClaim() } })) { newClaimSheet }
        .sheet(isPresented: Binding(get: { model.receiptSheetVisible }, set: { if !$0 { model.dismissReceipt() } })) { receiptSheet }
        .sheet(item: $operationSheet) { sheet in operationSheetView(sheet) }
        .accessibilityIdentifier("v15.f3c.reimbursements.ios")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: V15Spacing.sm) {
            Text("从垫付到到账，逐笔可追溯").font(V15Typography.surfaceTitle).foregroundStyle(V15Palette.ink.color)
            Text("金额、状态与到账分配都来自服务端；预览不是已提交事实。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
            V15ActionButton("新建报销单", symbol: "plus", disabledReason: model.isOffline ? .init(code: "offline_read_only", message: "离线快照仅可查看，无法新建报销单。", fieldPath: nil) : nil) { Task { await model.openNewClaim() } }
                .accessibilityIdentifier("v15.f3c.claim.new.open")
        }
    }

    @ViewBuilder private var listSurface: some View {
        switch model.phase {
        case .idle, .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f3c.claims.loading")
        case .empty: V15EmptyState(title: "还没有报销单", explanation: "先从一笔合格垫付开始新建。", actionTitle: "新建报销单") { Task { await model.openNewClaim() } }.accessibilityIdentifier("v15.f3c.claims.empty")
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.load() } }.accessibilityIdentifier("v15.f3c.claims.error")
        case .loaded:
            V15Section("报销单", detail: "\(model.claims.count) 笔") {
                VStack(spacing: 0) {
                    ForEach(model.claims, id: \.id) { claim in
                        V15LedgerRow(title: claim.title, detail: "\(claim.status.displayName) · v\(claim.version) · \(claim.partyCount) 位当事人", amountMinor: claim.outstandingMinor, direction: .inflow, marker: claim.status.isKnown ? .decision : .provisional) { Task { await model.selectClaim(claim) } }
                            .accessibilityIdentifier("v15.f3c.claim.\(claim.id)")
                        Divider()
                    }
                    if model.nextClaimCursor != nil {
                        V15ActionButton("加载更多报销单", kind: .quiet, disabledReason: model.claimPagePhase == .loading ? .init(code: "page_loading", message: "下一页正在读取。", fieldPath: nil) : nil) { Task { await model.loadNextClaims() } }.accessibilityIdentifier("v15.f3c.claims.next")
                    }
                    if case .failed(let failure) = model.claimPagePhase { V15ServiceErrorState(message: failure.message) { Task { await model.loadNextClaims() } }.accessibilityIdentifier("v15.f3c.claims.page.error") }
                }
            }
        }
    }

    private func claimDetail(_ claim: V15ReimbursementClaim) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                    Text(claim.title).font(V15Typography.cardTitle).foregroundStyle(V15Palette.ink.color).accessibilityIdentifier("v15.f3c.claim.detail")
                    Text("\(claim.status.displayName) · 报销单 v\(claim.version)").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
                }
                Spacer()
                Text(V15MoneyPresentation(minorUnits: claim.outstandingMinor, direction: .inflow, includeCurrency: true).text).font(V15Typography.money).foregroundStyle(V15Palette.teal.color).monospacedDigit()
            }
            V15Section("报销金额矩阵") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), spacing: V15Spacing.sm)], alignment: .leading, spacing: V15Spacing.sm) {
                    claimAmountFact("已申报", claim.totalClaimedMinor)
                    claimAmountFact("已到账", claim.receivedMinor)
                    claimAmountFact("未到账", claim.outstandingMinor, emphasized: true)
                }
                Text("留存与释放不是当前余额字段，只在取消未到账的服务端预览中出现；五个概念不会互相替代。")
                    .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
            }.accessibilityIdentifier("v15.f3c.amount-matrix")
            if !claim.status.isKnown { V15EmptyState(title: "未知报销状态", explanation: "服务器返回 \(claim.status.rawValue)；当前版本只展示，不允许操作。").accessibilityIdentifier("v15.f3c.claim.unknown-state") }
            else {
                if claim.archivedAt != nil { V15ArchiveReadOnlyState { Text("历史与到账记录已保留；恢复后才可继续操作。").font(V15Typography.secondary) } }
                ForEach(claim.parties, id: \.id) { party in
                    V15PartialProgressState(succeeded: "\(party.name) 已到账 \(money(party.receivedMinor))", currentState: party.status, remaining: money(party.outstandingMinor))
                        .accessibilityIdentifier("v15.f3c.party.\(party.id)")
                }
                V15ActionButton("登记到账", symbol: "arrow.down.circle", disabledReasons: model.receiptOpenReasons(for: claim)) { Task { await model.openReceipt() } }
                    .accessibilityIdentifier("v15.f3c.receipt.open")
                if model.isClaimActionApplicable(.replace, to: claim) { V15ActionButton("修改报销单", kind: .secondary, disabledReasons: model.claimActionReasons(for: claim, action: .replace)) { model.openClaimReplacement(); operationSheet = .claimReplacement }.accessibilityIdentifier("v15.f3c.replace.open") }
                if model.isClaimActionApplicable(.cancelOutstanding, to: claim) { V15ActionButton("取消未到账", kind: .secondary, disabledReasons: model.cancelReasons(for: claim)) { operationSheet = .cancellation }.accessibilityIdentifier("v15.f3c.cancel.open") }
                if V15ReimbursementModel.DirectClaimAction.allCases.contains(where: { model.isClaimActionApplicable(model.typedClaimAction(for: $0), to: claim) }) {
                    V15ActionButton("报销单状态操作", kind: .quiet, disabledReasons: claimOperationOpenReasons(claim)) { operationSheet = .claimActions }.accessibilityIdentifier("v15.f3c.direct.open")
                }
                if operationSheet == nil {
                    secondarySurface
                    directSurface
                    if !model.receiptSheetVisible { factRefreshSurface }
                }
            }
            V15Section("到账记录", detail: "\(model.receipts.count) 笔") {
                if model.receiptPagePhase == .loading { V15LoadingSkeleton() }
                else if model.receipts.isEmpty { Text("暂无到账记录").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }
                ForEach(model.receipts, id: \.id) { receipt in
                    VStack(alignment: .leading, spacing: V15Spacing.xs) {
                        V15LedgerRow(title: receipt.title, detail: "到账记录 v\(receipt.version)\(receipt.voidedAt == nil ? "" : " · 已作废")", amountMinor: receipt.amountMinor, direction: .inflow, marker: receipt.voidedAt == nil ? .ordinary : .archive)
                            .accessibilityIdentifier("v15.f3c.receipt.\(receipt.id)")
                        V15ActionButton("管理此到账记录", kind: .quiet, disabledReasons: receiptOperationOpenReasons(receipt, claim: claim)) { operationSheet = .receiptActions(receipt.id) }.accessibilityIdentifier("v15.f3c.receipt.actions.\(receipt.id)")
                    }
                }
            }
        }
        .padding(V15Spacing.md)
        .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.decisionCard))
        .overlay { RoundedRectangle(cornerRadius: V15Radius.decisionCard).stroke(V15Palette.hairline.color, lineWidth: 1) }
    }

    @ViewBuilder private var secondarySurface: some View {
        switch model.secondaryMutationPhase {
        case .previewed:
            if let preview = model.cancellationPreview {
                V15PreviewState(version: "claim v\(preview.claimVersion)") {
                    VStack(alignment: .leading, spacing: V15Spacing.sm) {
                        Text("取消未到账后的五项事实").font(V15Typography.body.weight(.semibold))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: V15Spacing.sm)], alignment: .leading, spacing: V15Spacing.sm) {
                            claimAmountFact("已申报", preview.current.totalClaimedMinor)
                            claimAmountFact("已到账", preview.current.receivedMinor)
                            claimAmountFact("取消前未到账", preview.current.outstandingMinor)
                            claimAmountFact("留存", preview.retainedReceivedMinor)
                            claimAmountFact("释放", preview.releasedMinor, emphasized: true)
                        }
                        Text("状态 \(preview.current.status.displayName) → \(preview.proposedStatus)").font(V15Typography.secondary)
                    }
                }.accessibilityIdentifier("v15.f3c.cancel.preview.result")
                V15ActionButton("确认取消未到账", kind: .destructive, disabledReasons: model.selectedClaim.map { model.cancellationCommitReasons(for: $0) } ?? []) { Task { await model.commitCancellation() } }.accessibilityIdentifier("v15.f3c.cancel.commit")
            } else if let preview = model.claimReplacePreview {
                V15PreviewState(version: "claim v\(preview.claimVersion)") { Text("标题将更新为“\(preview.proposed.title)”；金额矩阵仍以服务端提议为准。") }.accessibilityIdentifier("v15.f3c.replace.preview.result")
                V15ActionButton("确认修改报销单", kind: .destructive, disabledReasons: model.selectedClaim.map { model.claimReplacementCommitReasons(for: $0) } ?? []) { Task { await model.commitCurrentClaimReplacement() } }.accessibilityIdentifier("v15.f3c.replace.commit")
            } else if let preview = model.replacementReceiptPreview, let receipt = model.selectedReplacementReceipt, let claim = model.selectedClaim {
                V15PreviewState(version: "claim v\(preview.claimVersion) · receipt v\(preview.receiptVersion ?? receipt.version)") { Text("到账后金额 \(money(preview.amountMinor))；报销单已到账将更新为 \(money(preview.claimReceivedAfterMinor))。") }.accessibilityIdentifier("v15.f3c.receipt.replace.preview.result")
                V15ActionButton("确认修改到账", kind: .destructive, disabledReasons: model.receiptReplacementCommitReasons(for: receipt, claim: claim)) { Task { await model.commitReceiptReplacement(receipt) } }.accessibilityIdentifier("v15.f3c.receipt.replace.commit")
            }
        case .unknown:
            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                unknownState("取消/替换请求结果未知。只能用同一请求键恢复。", retry: { Task { await model.retryUnknownSecondary() } })
                V15ActionButton("放弃本次恢复", kind: .quiet) { model.abandonUnknownSecondary() }.accessibilityIdentifier("v15.f3c.secondary.abandon")
            }.accessibilityIdentifier("v15.f3c.secondary.unknown")
        case .conflict(let conflict): V15ConflictState(conflict: conflict) { Task { await model.refresh() } }.accessibilityIdentifier("v15.f3c.secondary.conflict")
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.refresh() } }
        case .succeeded: V15SuccessReceiptState(title: "报销事实已更新", detail: "服务端已返回新的版本事实。").accessibilityIdentifier("v15.f3c.secondary.success")
        default: EmptyView()
        }
    }

    @ViewBuilder private var factRefreshSurface: some View {
        if model.hasPendingFactRefresh {
            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                Label(model.isFactRefreshInFlight ? "事实刷新中" : "到账事实尚未收敛", systemImage: model.isFactRefreshInFlight ? "arrow.triangle.2.circlepath" : V15Symbol.warning)
                    .font(V15Typography.cardTitle)
                    .foregroundStyle(V15Palette.teal.color)
                    .accessibilityIdentifier("v15.f3c.fact-refresh.required")
                Text(model.factRefreshMessage ?? "到账写入已被接受，但最新报销事实尚未收敛。")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                Text("最新 claim 与 receipts 同时读取成功前，当前展示无法归因到最终版本。重试只执行 fresh GET，不会再次发送 POST 或 PUT。")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)
                V15ActionButton("仅重试读取最新事实", kind: .secondary, disabledReasons: model.factRefreshRetryReasons) { Task { await model.retryFactRefresh() } }
                    .accessibilityIdentifier("v15.f3c.fact-refresh.retry")
            }
            .padding(V15Spacing.md)
            .background(V15Palette.selected.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
            .overlay { RoundedRectangle(cornerRadius: V15Radius.control).stroke(V15Palette.teal.color.opacity(0.55), lineWidth: 1) }
        }
    }

    @ViewBuilder private func operationSheetView(_ sheet: OperationSheet) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.md) {
                    factRefreshSurface
                    secondarySurface
                    directSurface
                    switch sheet {
                    case .claimReplacement: claimReplacementEditor
                    case .cancellation: cancellationEditor
                    case .claimActions: claimActionsEditor
                    case .receiptReplacement(let id): receiptReplacementEditor(id: id)
                    case .receiptActions(let id): receiptActionsEditor(id: id)
                    }
                }.padding(V15Spacing.md)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(V15Palette.paper.color)
            .navigationTitle(operationTitle(sheet))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { operationSheet = nil } }
                if case .receiptReplacement(let id) = sheet,
                   let claim = model.selectedClaim,
                   let receipt = model.receipts.first(where: { $0.id == id }) {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("预览") { Task { await model.previewReceiptReplacement(receipt) } }
                            .disabled(!model.receiptReplacementPreviewReasons(for: receipt, claim: claim).isEmpty)
                            .accessibilityIdentifier("v15.f3c.receipt.replace.preview")
                    }
                }
            }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("v15.f3c.sheet.operation")
    }

    @ViewBuilder private var claimReplacementEditor: some View {
        if let claim = model.selectedClaim {
            Text("先编辑，再由服务端预览完整报销矩阵；预览后输入变化会立即失效。")
                .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
            V15Field("报销标题", text: Binding(get: { model.claimReplacementTitle }, set: { model.claimReplacementTitle = $0 }), issues: issues(model.secondaryIssues, prefix: "title"))
                .accessibilityIdentifier("v15.f3c.replace.title")
            V15Field("备注", text: Binding(get: { model.claimReplacementNote }, set: { model.claimReplacementNote = $0 }))
                .accessibilityIdentifier("v15.f3c.replace.note")
            V15ActionButton("预览报销单修改", kind: .secondary, disabledReasons: model.claimReplacementPreviewReasons(for: claim)) { Task { await model.previewCurrentClaimReplacement() } }
                .accessibilityIdentifier("v15.f3c.replace.preview")
        }
    }

    @ViewBuilder private var cancellationEditor: some View {
        if let claim = model.selectedClaim {
            Text("取消只影响尚未到账金额；已到账事实会保留。")
                .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
            V15ActionButton("预览取消未到账", kind: .secondary, disabledReasons: model.cancelReasons(for: claim)) { Task { await model.previewCancellation() } }
                .accessibilityIdentifier("v15.f3c.cancel.preview")
        }
    }

    @ViewBuilder private var claimActionsEditor: some View {
        if let claim = model.selectedClaim {
            Text("只显示后端当前事实允许的状态动作；读取或写入未收敛时会逐项说明原因。")
                .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
            ForEach(V15ReimbursementModel.DirectClaimAction.allCases, id: \.rawValue) { action in
                if model.isClaimActionApplicable(model.typedClaimAction(for: action), to: claim) {
                    V15ActionButton(claimActionTitle(action), kind: claimActionKind(action), disabledReasons: model.directClaimReasons(for: claim, action: action)) { Task { await model.performDirectClaim(action) } }
                        .accessibilityIdentifier("v15.f3c.direct.\(action.rawValue)")
                }
            }
        }
    }

    @ViewBuilder private func receiptActionsEditor(id: UUID) -> some View {
        if let claim = model.selectedClaim, let receipt = model.receipts.first(where: { $0.id == id }) {
            V15LedgerRow(title: receipt.title, detail: "receipt v\(receipt.version)", amountMinor: receipt.amountMinor, direction: .inflow, marker: receipt.voidedAt == nil ? .ordinary : .archive)
            if model.isReceiptActionApplicable(.replace, to: receipt, claim: claim) {
                V15ActionButton("修改到账记录", kind: .secondary, disabledReasons: model.receiptActionReasons(for: receipt, claim: claim, action: .replace)) { model.openReceiptReplacement(receipt); operationSheet = .receiptReplacement(receipt.id) }
                    .accessibilityIdentifier("v15.f3c.receipt.replace.open")
            }
            ForEach(V15ReimbursementModel.DirectReceiptAction.allCases, id: \.rawValue) { action in
                let typed: V15ReimbursementModel.ReceiptAction = action == .void ? .void : .restore
                if model.isReceiptActionApplicable(typed, to: receipt, claim: claim) {
                    V15ActionButton(action == .void ? "作废到账记录" : "恢复到账记录", kind: action == .void ? .destructive : .secondary, disabledReasons: model.directReceiptReasons(for: receipt, claim: claim, action: action)) { Task { await model.performDirectReceipt(receipt, action: action) } }
                        .accessibilityIdentifier("v15.f3c.receipt.direct.\(action.rawValue)")
                }
            }
        }
    }

    @ViewBuilder private func receiptReplacementEditor(id: UUID) -> some View {
        if let claim = model.selectedClaim, let receipt = model.receipts.first(where: { $0.id == id }) {
            Text("当事人和收款账户沿用原记录；金额、日期和标题由服务端重新预览分配。")
                .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
            Text("收款账户 \(receipt.destinationAccountID.uuidString)").font(V15Typography.secondary).textSelection(.enabled)
            V15Field("到账标题", text: Binding(get: { model.receiptReplacementTitle }, set: { model.receiptReplacementTitle = $0 }), issues: issues(model.secondaryIssues, prefix: "title"))
                .accessibilityIdentifier("v15.f3c.receipt.replace.title")
            V15Field("到账日期", text: Binding(get: { model.receiptReplacementDateText }, set: { model.receiptReplacementDateText = $0 }), prompt: "YYYY-MM-DD", issues: issues(model.secondaryIssues, prefix: "received_at"))
                .accessibilityIdentifier("v15.f3c.receipt.replace.date")
            V15Field("到账金额（元）", text: Binding(get: { model.receiptReplacementAmountText }, set: { model.receiptReplacementAmountText = $0 }), issues: issues(model.secondaryIssues, prefix: "amount_minor"))
                .accessibilityIdentifier("v15.f3c.receipt.replace.amount")
            V15FieldIssues(issues: model.receiptReplacementPreviewReasons(for: receipt, claim: claim).map {
                .init(code: $0.code, message: $0.message, fieldPath: $0.fieldPath)
            })
        }
    }

    private func claimOperationOpenReasons(_ claim: V15ReimbursementClaim) -> [V15DisabledReason] {
        guard let action = V15ReimbursementModel.DirectClaimAction.allCases.first(where: { model.isClaimActionApplicable(model.typedClaimAction(for: $0), to: claim) }) else { return [] }
        return model.directClaimReasons(for: claim, action: action)
    }
    private func receiptOperationOpenReasons(_ receipt: V15ReimbursementReceipt, claim: V15ReimbursementClaim) -> [V15DisabledReason] {
        if model.isReceiptActionApplicable(.replace, to: receipt, claim: claim) { return model.receiptActionReasons(for: receipt, claim: claim, action: .replace) }
        if model.isReceiptActionApplicable(.void, to: receipt, claim: claim) { return model.receiptActionReasons(for: receipt, claim: claim, action: .void) }
        if model.isReceiptActionApplicable(.restore, to: receipt, claim: claim) { return model.receiptActionReasons(for: receipt, claim: claim, action: .restore) }
        return [.init(code: "no_receipt_action", message: "当前到账事实没有可用操作。", fieldPath: "status")]
    }
    private func claimActionTitle(_ action: V15ReimbursementModel.DirectClaimAction) -> String {
        switch action { case .submit: "提交报销单"; case .retractSubmission: "撤回提交"; case .reopen: "重新打开"; case .void: "作废报销单"; case .restore: "恢复报销单"; case .archive: "归档报销单"; case .unarchive: "取消归档" }
    }
    private func claimActionKind(_ action: V15ReimbursementModel.DirectClaimAction) -> V15ButtonKind { [.void, .archive].contains(action) ? .destructive : .secondary }
    private func operationTitle(_ sheet: OperationSheet) -> String {
        switch sheet { case .claimReplacement: "修改报销单"; case .cancellation: "取消未到账"; case .claimActions: "报销单状态操作"; case .receiptReplacement: "修改到账记录"; case .receiptActions: "到账记录操作" }
    }

    @ViewBuilder private var directSurface: some View {
        switch model.directMutationPhase {
        case .unknown, .loading:
            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                Text("直接命令待核对")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    .accessibilityIdentifier("v15.f3c.direct.unknown")
                unknownState(model.directReadbackMessage ?? "直接命令结果未知；禁止再次发送，只能读取最新事实核对。", retry: { Task { await model.readBackUnknownDirect() } })
                V15ActionButton("按最新事实解除写入锁", kind: .quiet, disabledReason: model.canAbandonUnknownDirect ? nil : .init(code: "fresh_readback_required", message: "请先读取最新服务端事实，再明确解除本地写入锁。", fieldPath: nil)) { model.abandonUnknownDirect() }.accessibilityIdentifier("v15.f3c.direct.abandon")
            }
        case .conflict(let conflict): V15ConflictState(conflict: conflict) { Task { await model.refresh() } }
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.refresh() } }
        default: EmptyView()
        }
    }

    private var newClaimSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.md) {
                    sheetBanner(model.newClaimPhase, serverIssues: model.newClaimServerIssues)
                    V15Field("报销标题", text: Binding(get: { model.claimTitle }, set: { model.claimTitle = $0 }), prompt: "例如：八月差旅报销", issues: issues(model.newClaimIssues, prefix: "title"))
                        .accessibilityIdentifier("v15.f3c.claim.title")
                    V15Field("当事人", text: Binding(get: { model.partyName }, set: { model.partyName = $0 }), prompt: "例如：公司", issues: issues(model.newClaimIssues, prefix: "parties[0].name"))
                        .accessibilityIdentifier("v15.f3c.claim.party")
                    V15Field("预计日期", text: Binding(get: { model.expectedDateText }, set: { model.expectedDateText = $0 }), prompt: "YYYY-MM-DD", issues: issues(model.newClaimIssues, prefix: "parties[0].expected_date"))
                        .accessibilityIdentifier("v15.f3c.claim.date")
                    candidateSurface
                    V15Field("分摊金额（元）", text: Binding(get: { model.allocationAmountText }, set: { model.allocationAmountText = $0 }), prompt: "0.00", issues: issues(model.newClaimIssues, prefix: "parties[0].allocations[0].amount_minor"))
                        .accessibilityIdentifier("v15.f3c.claim.amount")
                    V15ActionButton("创建报销单", symbol: "checkmark", disabledReasons: model.createClaimDisabledReasons) { Task { await model.createClaim() } }
                        .accessibilityIdentifier("v15.f3c.claim.create")
                    if model.hasRecoverableCreateAttempt && model.newClaimPhase == .unknown {
                        HStack(alignment: .top) {
                            V15ActionButton("同一请求键重试", kind: .secondary, disabledReason: model.isOffline ? .init(code: "offline_read_only", message: "离线时不能重试写入。", fieldPath: nil) : nil) { Task { await model.retryUnknownCreateClaim() } }.accessibilityIdentifier("v15.f3c.claim.retry-same-key")
                            V15ActionButton("放弃恢复", kind: .quiet) { model.abandonUnknownCreateClaim() }.accessibilityIdentifier("v15.f3c.claim.abandon")
                        }
                    }
                }.padding(V15Spacing.md)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(V15Palette.paper.color).navigationTitle("新建报销单").toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { model.dismissNewClaim() } } }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("v15.f3c.sheet.claim")
    }

    @ViewBuilder private var candidateSurface: some View {
        V15Section("选择垫付") {
            V15SearchField(text: Binding(get: { model.candidateQuery }, set: { model.candidateQuery = $0 })).accessibilityIdentifier("v15.f3c.candidates.query")
            V15ActionButton("按条件读取候选", kind: .secondary) { Task { await model.retryCandidates() } }.accessibilityIdentifier("v15.f3c.candidates.load")
            switch model.candidatesPhase {
            case .idle, .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f3c.candidates.loading")
            case .empty: V15EmptyState(title: "没有垫付候选", explanation: "调整搜索或日期后重试。", actionTitle: "重试") { Task { await model.retryCandidates() } }.accessibilityIdentifier("v15.f3c.candidates.empty")
            case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.retryCandidates() } }.accessibilityIdentifier("v15.f3c.candidates.error")
            case .loaded:
                ForEach(model.candidates, id: \.transactionID) { candidate in
                    Button { model.chooseCandidate(candidate) } label: {
                        VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                            HStack { Text(candidate.title).font(V15Typography.body); Spacer(); Text(money(candidate.availableMinor)).font(V15Typography.money).monospacedDigit() }
                            Text("\(candidate.businessDate) · \(candidate.categoryID == nil ? "未分类（允许）" : "已分类")").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
                            ForEach(candidate.eligibility.reasonDetails, id: \.code) { reason in Text("\(reason.fieldPath.map { "\($0)：" } ?? "")\(reason.message)").font(V15Typography.secondary).foregroundStyle(V15Palette.teal.color) }
                        }.padding(V15Spacing.sm).background(model.selectedCandidate?.transactionID == candidate.transactionID ? V15Palette.selected.color : V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
                    }.buttonStyle(.plain).disabled(!candidate.eligibility.eligible).accessibilityIdentifier("v15.f3c.candidate.\(candidate.transactionID)")
                }
            }
        }
    }

    private var receiptSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.md) {
                    factRefreshSurface
                    sheetBanner(model.receiptPhase, serverIssues: model.receiptServerIssues)
                    if let claim = model.selectedClaim {
                        V15Section("到账当事人") {
                            ForEach(claim.parties, id: \.id) { party in Button { model.chooseParty(party.id) } label: { HStack { Text(party.name); Spacer(); Text("未到账 \(money(party.outstandingMinor))") }.padding(V15Spacing.sm).background(model.selectedPartyID == party.id ? V15Palette.selected.color : V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control)) }.buttonStyle(.plain).disabled(party.outstandingMinor <= 0).accessibilityIdentifier("v15.f3c.receipt.party.\(party.id)") }
                        }
                    }
                    V15Field("到账标题", text: Binding(get: { model.receiptTitle }, set: { model.receiptTitle = $0 }), prompt: "例如：公司回款", issues: issues(model.receiptIssues, prefix: "title")).accessibilityIdentifier("v15.f3c.receipt.title")
                    V15Field("到账日期", text: Binding(get: { model.receiptDateText }, set: { model.receiptDateText = $0 }), prompt: "YYYY-MM-DD", issues: issues(model.receiptIssues, prefix: "received_at")).accessibilityIdentifier("v15.f3c.receipt.date")
                    V15Field("到账金额（元）", text: Binding(get: { model.receiptAmountText }, set: { model.receiptAmountText = $0 }), prompt: "0.00", issues: issues(model.receiptIssues, prefix: "amount_minor")).accessibilityIdentifier("v15.f3c.receipt.amount")
                    receiptAccountSurface
                    V15ActionButton("预览到账影响", kind: .secondary, disabledReasons: model.receiptPreviewDisabledReasons) { Task { await model.previewReceipt() } }.accessibilityIdentifier("v15.f3c.receipt.preview")
                    if let preview = model.receiptPreview {
                        V15PreviewState(version: "claim v\(preview.claimVersion)") { Text("报销单已到账将从 \(money(preview.claimReceivedBeforeMinor)) 变为 \(money(preview.claimReceivedAfterMinor))；服务端会保存 \(preview.persistedAllocations.count) 条分配。").font(V15Typography.secondary) }.accessibilityIdentifier("v15.f3c.receipt.preview.result")
                    }
                    V15ActionButton("确认登记到账", disabledReasons: model.receiptCommitDisabledReasons) { Task { await model.commitReceipt() } }.accessibilityIdentifier("v15.f3c.receipt.commit")
                    if model.hasRecoverableReceiptAttempt && model.receiptPhase == .unknown {
                        HStack(alignment: .top) {
                            V15ActionButton("同一请求键重试", kind: .secondary, disabledReason: model.isOffline ? .init(code: "offline_read_only", message: "离线时不能重试写入。", fieldPath: nil) : nil) { Task { await model.retryUnknownReceipt() } }.accessibilityIdentifier("v15.f3c.receipt.retry-same-key")
                            V15ActionButton("放弃恢复", kind: .quiet) { model.abandonUnknownReceipt() }.accessibilityIdentifier("v15.f3c.receipt.abandon")
                        }
                    }
                }.padding(V15Spacing.md)
            }
            .id(model.receiptPhase == .succeeded)
            .scrollDismissesKeyboard(.immediately)
            .background(V15Palette.paper.color).navigationTitle("登记到账").toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { model.dismissReceipt() }.accessibilityIdentifier("v15.f3c.receipt.close") } }
        }.presentationDetents([.large]).accessibilityIdentifier("v15.f3c.sheet.receipt")
    }

    @ViewBuilder private var receiptAccountSurface: some View {
        V15Section("收款账户") {
            switch model.receiptAccountsPhase {
            case .idle, .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f3c.receipt.accounts.loading")
            case .empty: V15EmptyState(title: "没有可用收款账户", explanation: "需要一个启用的现金或借记账户。", actionTitle: "重试") { Task { await model.retryReceiptAccounts() } }.accessibilityIdentifier("v15.f3c.receipt.accounts.empty")
            case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.retryReceiptAccounts() } }.accessibilityIdentifier("v15.f3c.receipt.accounts.error")
            case .loaded:
                ForEach(model.receiptAccounts) { account in Button { model.chooseReceiptAccount(account) } label: { HStack { Text(account.name); Spacer(); Text(account.kind == "cash" ? "现金" : "借记") }.padding(V15Spacing.sm).background(model.selectedReceiptAccount?.id == account.id ? V15Palette.selected.color : V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control)) }.buttonStyle(.plain).accessibilityIdentifier("v15.f3c.receipt.account.\(account.id)") }
            }
        }
    }

    @ViewBuilder private func sheetBanner(_ phase: V15ReimbursementModel.EditorPhase, serverIssues: [V15FieldIssue]) -> some View {
        switch phase {
        case .failed(let failure): nonRetryableMessage(title: "操作未完成", message: failure.message).accessibilityIdentifier("v15.f3c.sheet.error")
        case .conflict(let conflict): V15ConflictState(conflict: conflict) { Task { await model.refresh() } }.accessibilityIdentifier("v15.f3c.sheet.conflict")
        case .unknown: nonRetryableMessage(title: "请求结果未知", message: "服务器可能已经完成请求；保留原请求体与同一请求键。请使用下方同一请求键恢复操作，或明确放弃恢复。").accessibilityIdentifier("v15.f3c.sheet.unknown")
        case .succeeded: V15SuccessReceiptState(title: "服务端已确认", detail: "新版本事实已返回，可关闭后查看。", actionTitle: nil).accessibilityIdentifier("v15.f3c.sheet.success")
        default: EmptyView()
        }
        V15FieldIssues(issues: serverIssues).accessibilityIdentifier("v15.f3c.sheet.remote-reasons")
    }

    private func unknownState(_ message: String, retry: @escaping () -> Void) -> some View { V15ServiceErrorState(message: message, retry: retry) }
    private func nonRetryableMessage(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.xs) {
            Label(title, systemImage: V15Symbol.warning).font(V15Typography.cardTitle).foregroundStyle(V15Palette.teal.color)
            Text(message).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color).fixedSize(horizontal: false, vertical: true)
        }
        .padding(V15Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(V15Palette.selected.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
        .overlay { RoundedRectangle(cornerRadius: V15Radius.control).stroke(V15Palette.teal.color.opacity(0.55), lineWidth: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)：\(message)")
    }
    private func issues(_ values: [V15FieldIssue], prefix: String) -> [V15FieldIssue] { values.filter { $0.fieldPath == prefix || $0.fieldPath?.hasPrefix(prefix + ".") == true } }
    private func money(_ value: V15MinorUnits) -> String { V15MoneyPresentation(minorUnits: value, direction: .neutral, includeCurrency: true).text }
    private func claimAmountFact(_ title: String, _ value: V15MinorUnits, emphasized: Bool = false) -> some View { VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text(title).font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.62)); V15MoneyText(minorUnits: value, direction: .neutral, font: V15Typography.body.weight(.semibold)) }.padding(V15Spacing.sm).frame(maxWidth: .infinity, alignment: .leading).background(emphasized ? V15Palette.selected.color : V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control)) }
}
#endif
