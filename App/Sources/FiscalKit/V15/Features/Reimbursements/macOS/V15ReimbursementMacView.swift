import SwiftUI

#if os(macOS)
public struct V15ReimbursementMacView: View {
    @State private var model: V15ReimbursementModel
    @State private var inspectorMode: InspectorMode = .claim
    private let initialGalleryScenario: String?

    private enum InspectorMode: Equatable { case claim, claimReplacement, receiptActions(UUID), receiptReplacement(UUID) }

    public init(services: V15Services, offlineSnapshotAt: Date? = nil, initialGalleryScenario: String? = nil) {
        _model = State(initialValue: V15ReimbursementModel(services: services, offlineSnapshotAt: offlineSnapshotAt))
        self.initialGalleryScenario = initialGalleryScenario
    }

    public var body: some View {
        HStack(spacing: 0) {
            spine.frame(minWidth: 260, idealWidth: 300, maxWidth: 340)
            Divider()
            detail.frame(minWidth: 420, maxWidth: .infinity)
            Divider()
            inspector.frame(minWidth: 330, idealWidth: 370, maxWidth: 420)
        }
        .background(V15Palette.paper.color)
        .task {
            if model.phase == .idle { await model.load() }
            if let initialGalleryScenario { await prepareGalleryScenario(initialGalleryScenario) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f3c.reimbursements.macos")
    }

    private var spine: some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            HStack { Text("报销脊柱").font(V15Typography.cardTitle); Spacer(); Button { Task { await model.refresh() } } label: { Image(systemName: V15Symbol.retry) }.accessibilityLabel("刷新报销事实") }
            V15ActionButton("新建报销单", symbol: "plus", disabledReason: model.isOffline ? .init(code: "offline_read_only", message: "离线快照仅可查看。", fieldPath: nil) : nil) { Task { await model.openNewClaim() } }.accessibilityIdentifier("v15.f3c.mac.claim.new.open")
            if let snapshot = model.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: snapshot).accessibilityIdentifier("v15.f3c.mac.offline") }
            ScrollView {
                LazyVStack(spacing: 0) {
                    switch model.phase {
                    case .idle, .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f3c.mac.claims.loading")
                    case .empty: V15EmptyState(title: "还没有报销单", explanation: "先从垫付候选新建。")
                    case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.load() } }
                    case .loaded:
                        ForEach(model.claims, id: \.id) { claim in
                            V15LedgerRow(title: claim.title, detail: "\(claim.status.displayName) · v\(claim.version)", amountMinor: claim.outstandingMinor, direction: .inflow, marker: claim.status.isKnown ? .decision : .provisional) { Task { await model.selectClaim(claim) } }
                                .background(model.selectedClaim?.id == claim.id ? V15Palette.selected.color : .clear)
                                .accessibilityIdentifier("v15.f3c.mac.claim.\(claim.id)")
                            Divider()
                        }
                    }
                }
            }
            if model.nextClaimCursor != nil { V15ActionButton("加载更多", kind: .quiet, disabledReason: model.claimPagePhase == .loading ? .init(code: "page_loading", message: "下一页正在读取。", fieldPath: nil) : nil) { Task { await model.loadNextClaims() } } }
        }
        .padding(V15Spacing.md)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f3c.mac.spine")
    }

    @ViewBuilder private var detail: some View {
        if let claim = model.selectedClaim {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.lg) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text(claim.title).font(V15Typography.surfaceTitle); Text("\(claim.status.displayName) · v\(claim.version)").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }
                        Spacer(); Text(money(claim.outstandingMinor)).font(V15Typography.moneyLarge).foregroundStyle(V15Palette.teal.color).monospacedDigit()
                    }
                    V15Section("报销金额矩阵") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: V15Spacing.sm)], alignment: .leading, spacing: V15Spacing.sm) {
                            claimAmountFact("已申报", claim.totalClaimedMinor)
                            claimAmountFact("已到账", claim.receivedMinor)
                            claimAmountFact("未到账", claim.outstandingMinor, emphasized: true)
                        }
                        Text("留存与释放只在取消未到账的服务端预览中出现，不从当前金额自行推算。")
                            .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
                    }.accessibilityIdentifier("v15.f3c.mac.amount-matrix")
                    if !claim.status.isKnown { V15EmptyState(title: "未知状态，只读", explanation: "服务端状态 \(claim.status.rawValue) 尚未被当前版本识别。") }
                    V15Section("当事人与分摊", detail: "\(claim.partyCount) 位") {
                        ForEach(claim.parties, id: \.id) { party in
                            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                                HStack { Text(party.name).font(V15Typography.body.weight(.semibold)); Spacer(); Text("未到账 \(money(party.outstandingMinor))").font(V15Typography.money).monospacedDigit() }
                                ForEach(party.allocations, id: \.id) { allocation in Text("\(allocation.expenseTitle) · 分摊 \(money(allocation.amountMinor)) · 已到账 \(money(allocation.receivedMinor))").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }
                            }.padding(V15Spacing.md).background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
                        }
                    }
                    V15Section("到账历史", detail: "\(model.receipts.count) 笔") {
                        if model.receiptPagePhase == .loading { V15LoadingSkeleton() }
                        else if model.receipts.isEmpty { Text("暂无到账记录").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }
                        ForEach(model.receipts, id: \.id) { receipt in
                            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                                V15LedgerRow(title: receipt.title, detail: "v\(receipt.version)\(receipt.voidedAt == nil ? "" : " · 已作废")", amountMinor: receipt.amountMinor, direction: .inflow, marker: receipt.voidedAt == nil ? .ordinary : .archive).accessibilityIdentifier("v15.f3c.mac.receipt.\(receipt.id)")
                                V15ActionButton("管理到账", kind: .quiet, disabledReasons: model.selectedClaim.map { receiptOperationOpenReasons(receipt, claim: $0) } ?? []) { inspectorMode = .receiptActions(receipt.id) }
                                    .accessibilityIdentifier("v15.f3c.mac.receipt.actions.\(receipt.id)")
                            }
                        }
                    }
                }.padding(V15Spacing.lg)
            }.accessibilityElement(children: .contain).accessibilityIdentifier("v15.f3c.mac.detail")
        } else { V15EmptyState(title: "选择一张报销单", explanation: "中栏展示服务端报销矩阵和到账历史。") }
    }

    @ViewBuilder private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: V15Spacing.md) {
                factRefreshInspector
                if model.newClaimSheetVisible { newClaimInspector }
                else if model.receiptSheetVisible { receiptInspector }
                else if let claim = model.selectedClaim {
                    switch inspectorMode {
                    case .claim: claimInspector(claim)
                    case .claimReplacement: claimReplacementInspector(claim)
                    case .receiptActions(let id): receiptActionsInspector(id: id, claim: claim)
                    case .receiptReplacement(let id): receiptReplacementInspector(id: id, claim: claim)
                    }
                }
                else { V15EmptyState(title: "检查器", explanation: "选择报销单后显示可用操作与逐项原因。") }
            }
        }.padding(V15Spacing.md).accessibilityElement(children: .contain).accessibilityIdentifier("v15.f3c.mac.inspector")
    }

    private func claimInspector(_ claim: V15ReimbursementClaim) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            Text("决策检查器").font(V15Typography.cardTitle)
            Text("所有禁用操作都必须说明原因；未知状态和归档事实只读。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
            V15ActionButton("登记到账", disabledReasons: model.receiptOpenReasons(for: claim)) { Task { await model.openReceipt() } }.accessibilityIdentifier("v15.f3c.mac.receipt.open")
            if model.isClaimActionApplicable(.cancelOutstanding, to: claim) { V15ActionButton("预览取消未到账", kind: .secondary, disabledReasons: model.cancelReasons(for: claim)) { Task { await model.previewCancellation() } }.accessibilityIdentifier("v15.f3c.mac.cancel.preview") }
            if model.isClaimActionApplicable(.replace, to: claim) { V15ActionButton("修改报销单", kind: .secondary, disabledReasons: model.claimActionReasons(for: claim, action: .replace)) { model.openClaimReplacement(); inspectorMode = .claimReplacement }.accessibilityIdentifier("v15.f3c.mac.replace.open") }
            ForEach(V15ReimbursementModel.DirectClaimAction.allCases, id: \.rawValue) { action in
                if model.isClaimActionApplicable(model.typedClaimAction(for: action), to: claim) {
                    V15ActionButton(claimActionTitle(action), kind: claimActionKind(action), disabledReasons: model.directClaimReasons(for: claim, action: action)) { Task { await model.performDirectClaim(action) } }
                        .accessibilityIdentifier("v15.f3c.mac.direct.\(action.rawValue)")
                }
            }
            mutationInspector
        }
    }

    private func claimReplacementInspector(_ claim: V15ReimbursementClaim) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            HStack { Text("修改报销单").font(V15Typography.cardTitle); Spacer(); Button("返回") { inspectorMode = .claim } }
            Text("编辑后先由服务端预览完整矩阵；任何输入变化都会使旧预览失效。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
            V15Field("报销标题", text: Binding(get: { model.claimReplacementTitle }, set: { model.claimReplacementTitle = $0 }), issues: fieldIssues(model.secondaryIssues, path: "title")).accessibilityIdentifier("v15.f3c.mac.replace.title")
            V15Field("备注", text: Binding(get: { model.claimReplacementNote }, set: { model.claimReplacementNote = $0 })).accessibilityIdentifier("v15.f3c.mac.replace.note")
            V15ActionButton("预览报销单修改", kind: .secondary, disabledReasons: model.claimReplacementPreviewReasons(for: claim)) { Task { await model.previewCurrentClaimReplacement() } }.accessibilityIdentifier("v15.f3c.mac.replace.preview")
            mutationInspector
        }
    }

    private func receiptActionsInspector(id: UUID, claim: V15ReimbursementClaim) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            HStack { Text("到账记录操作").font(V15Typography.cardTitle); Spacer(); Button("返回") { inspectorMode = .claim } }
            if let receipt = model.receipts.first(where: { $0.id == id }) {
                V15LedgerRow(title: receipt.title, detail: "receipt v\(receipt.version)", amountMinor: receipt.amountMinor, direction: .inflow, marker: receipt.voidedAt == nil ? .ordinary : .archive)
                if model.isReceiptActionApplicable(.replace, to: receipt, claim: claim) {
                    V15ActionButton("修改到账记录", kind: .secondary, disabledReasons: model.receiptActionReasons(for: receipt, claim: claim, action: .replace)) { model.openReceiptReplacement(receipt); inspectorMode = .receiptReplacement(receipt.id) }.accessibilityIdentifier("v15.f3c.mac.receipt.replace.open")
                }
                ForEach(V15ReimbursementModel.DirectReceiptAction.allCases, id: \.rawValue) { action in
                    let typed: V15ReimbursementModel.ReceiptAction = action == .void ? .void : .restore
                    if model.isReceiptActionApplicable(typed, to: receipt, claim: claim) {
                        V15ActionButton(action == .void ? "作废到账记录" : "恢复到账记录", kind: action == .void ? .destructive : .secondary, disabledReasons: model.directReceiptReasons(for: receipt, claim: claim, action: action)) { Task { await model.performDirectReceipt(receipt, action: action) } }.accessibilityIdentifier("v15.f3c.mac.receipt.direct.\(action.rawValue)")
                    }
                }
            }
            mutationInspector
        }
    }

    private func receiptReplacementInspector(id: UUID, claim: V15ReimbursementClaim) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            HStack { Text("修改到账记录").font(V15Typography.cardTitle); Spacer(); Button("返回") { inspectorMode = .receiptActions(id) } }
            if let receipt = model.receipts.first(where: { $0.id == id }) {
                Text("沿用原当事人与收款账户；金额、日期和标题重新预览。收款账户 \(receipt.destinationAccountID.uuidString)").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).textSelection(.enabled)
                V15Field("到账标题", text: Binding(get: { model.receiptReplacementTitle }, set: { model.receiptReplacementTitle = $0 }), issues: fieldIssues(model.secondaryIssues, path: "title")).accessibilityIdentifier("v15.f3c.mac.receipt.replace.title")
                V15Field("到账金额（元）", text: Binding(get: { model.receiptReplacementAmountText }, set: { model.receiptReplacementAmountText = $0 }), issues: fieldIssues(model.secondaryIssues, path: "amount_minor")).accessibilityIdentifier("v15.f3c.mac.receipt.replace.amount")
                V15Field("到账日期", text: Binding(get: { model.receiptReplacementDateText }, set: { model.receiptReplacementDateText = $0 }), prompt: "YYYY-MM-DD", issues: fieldIssues(model.secondaryIssues, path: "received_at")).accessibilityIdentifier("v15.f3c.mac.receipt.replace.date")
                V15ActionButton("预览到账修改", kind: .secondary, disabledReasons: model.receiptReplacementPreviewReasons(for: receipt, claim: claim)) { Task { await model.previewReceiptReplacement(receipt) } }.accessibilityIdentifier("v15.f3c.mac.receipt.replace.preview")
            }
            mutationInspector
        }
    }

    @ViewBuilder private var factRefreshInspector: some View {
        if model.hasPendingFactRefresh {
            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                Label(model.isFactRefreshInFlight ? "事实刷新中" : "到账事实尚未收敛", systemImage: model.isFactRefreshInFlight ? "arrow.triangle.2.circlepath" : V15Symbol.warning)
                    .font(V15Typography.cardTitle)
                    .foregroundStyle(V15Palette.teal.color)
                    .accessibilityIdentifier("v15.f3c.mac.fact-refresh.required")
                Text(model.factRefreshMessage ?? "到账写入已被接受，但最新报销事实尚未收敛。")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                Text("最新 claim 与 receipts 同时读取成功前，当前展示无法归因到最终版本。重试只执行 fresh GET，不会再次发送 POST 或 PUT。")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)
                V15ActionButton("仅重试读取最新事实", kind: .secondary, disabledReasons: model.factRefreshRetryReasons) { Task { await model.retryFactRefresh() } }
                    .accessibilityIdentifier("v15.f3c.mac.fact-refresh.retry")
            }
            .padding(V15Spacing.md)
            .background(V15Palette.selected.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
            .overlay { RoundedRectangle(cornerRadius: V15Radius.control).stroke(V15Palette.teal.color.opacity(0.55), lineWidth: 1) }
        }
    }

    @ViewBuilder private var mutationInspector: some View {
        switch model.secondaryMutationPhase {
        case .previewed:
            if let preview = model.cancellationPreview {
                V15PreviewState(version: "claim v\(preview.claimVersion)") {
                    VStack(alignment: .leading, spacing: V15Spacing.sm) {
                        Text("取消未到账后的五项事实").font(V15Typography.body.weight(.semibold))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 115), spacing: V15Spacing.sm)], alignment: .leading, spacing: V15Spacing.sm) {
                            claimAmountFact("已申报", preview.current.totalClaimedMinor)
                            claimAmountFact("已到账", preview.current.receivedMinor)
                            claimAmountFact("取消前未到账", preview.current.outstandingMinor)
                            claimAmountFact("留存", preview.retainedReceivedMinor)
                            claimAmountFact("释放", preview.releasedMinor, emphasized: true)
                        }
                        Text("状态 \(preview.current.status.displayName) → \(preview.proposedStatus)").font(V15Typography.secondary)
                    }
                }.accessibilityIdentifier("v15.f3c.mac.cancel.preview.result")
                V15ActionButton("确认取消未到账", kind: .destructive, disabledReasons: model.selectedClaim.map { model.cancellationCommitReasons(for: $0) } ?? []) { Task { await model.commitCancellation() } }.accessibilityIdentifier("v15.f3c.mac.cancel.commit")
            } else if let preview = model.claimReplacePreview {
                V15PreviewState(version: "claim v\(preview.claimVersion)") { Text("当前 \(money(preview.current.totalClaimedMinor)) → 服务端提议 \(money(preview.proposed.totalClaimedMinor))。\(preview.warnings.joined(separator: "；"))").font(V15Typography.secondary) }.accessibilityIdentifier("v15.f3c.mac.replace.preview.result")
                V15ActionButton("确认替换", kind: .destructive, disabledReasons: model.selectedClaim.map { model.claimReplacementCommitReasons(for: $0) } ?? []) { Task { await model.commitCurrentClaimReplacement() } }.accessibilityIdentifier("v15.f3c.mac.replace.commit")
            } else if let preview = model.replacementReceiptPreview, let receipt = model.selectedReplacementReceipt, let claim = model.selectedClaim {
                V15PreviewState(version: "claim v\(preview.claimVersion) · receipt v\(preview.receiptVersion ?? receipt.version)") { Text("到账金额 \(money(preview.amountMinor))；报销单已到账更新为 \(money(preview.claimReceivedAfterMinor))。").font(V15Typography.secondary) }.accessibilityIdentifier("v15.f3c.mac.receipt.replace.preview.result")
                V15ActionButton("确认修改到账", kind: .destructive, disabledReasons: model.receiptReplacementCommitReasons(for: receipt, claim: claim)) { Task { await model.commitReceiptReplacement(receipt) } }.accessibilityIdentifier("v15.f3c.mac.receipt.replace.commit")
            }
        case .unknown:
            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                V15ServiceErrorState(message: "结果未知；只可用同一请求键恢复。") { Task { await model.retryUnknownSecondary() } }
                V15ActionButton("放弃本次恢复", kind: .quiet) { model.abandonUnknownSecondary() }.accessibilityIdentifier("v15.f3c.mac.secondary.abandon")
            }.accessibilityIdentifier("v15.f3c.mac.secondary.unknown")
        case .conflict(let conflict): V15ConflictState(conflict: conflict) { Task { await model.refresh() } }.accessibilityIdentifier("v15.f3c.mac.conflict")
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.refresh() } }
        case .succeeded: V15SuccessReceiptState(title: "事实已更新", detail: "服务端已返回新版本。")
        default: EmptyView()
        }
        if model.directMutationPhase == .unknown || model.directMutationPhase == .loading {
            V15ServiceErrorState(message: model.directReadbackMessage ?? "直接命令结果未知；不能再次发送，只能 fresh GET 核对。") { Task { await model.readBackUnknownDirect() } }.accessibilityIdentifier("v15.f3c.mac.direct.unknown")
            V15ActionButton("按最新事实解除写入锁", kind: .quiet, disabledReason: model.canAbandonUnknownDirect ? nil : .init(code: "fresh_readback_required", message: "请先读取最新服务端事实，再明确解除本地写入锁。", fieldPath: nil)) { model.abandonUnknownDirect() }.accessibilityIdentifier("v15.f3c.mac.direct.abandon")
        }
    }

    private var newClaimInspector: some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            HStack { Text("新建报销单").font(V15Typography.cardTitle); Spacer(); Button("关闭") { model.dismissNewClaim() } }
            editorBanner(model.newClaimPhase, issues: model.newClaimServerIssues)
            V15Field("标题", text: Binding(get: { model.claimTitle }, set: { model.claimTitle = $0 }), prompt: "例如：八月差旅", issues: fieldIssues(model.newClaimIssues, path: "title")).accessibilityIdentifier("v15.f3c.mac.claim.title")
            V15Field("当事人", text: Binding(get: { model.partyName }, set: { model.partyName = $0 }), prompt: "例如：公司", issues: fieldIssues(model.newClaimIssues, path: "parties[0].name")).accessibilityIdentifier("v15.f3c.mac.claim.party")
            V15Field("预计日期", text: Binding(get: { model.expectedDateText }, set: { model.expectedDateText = $0 }), prompt: "YYYY-MM-DD", issues: fieldIssues(model.newClaimIssues, path: "parties[0].expected_date")).accessibilityIdentifier("v15.f3c.mac.claim.date")
            V15SearchField(text: Binding(get: { model.candidateQuery }, set: { model.candidateQuery = $0 })).accessibilityIdentifier("v15.f3c.mac.candidates.query")
            V15ActionButton("读取候选", kind: .secondary) { Task { await model.retryCandidates() } }.accessibilityIdentifier("v15.f3c.mac.candidates.load")
            candidateInspector
            V15Field("分摊金额（元）", text: Binding(get: { model.allocationAmountText }, set: { model.allocationAmountText = $0 }), prompt: "0.00", issues: fieldIssues(model.newClaimIssues, path: "parties[0].allocations[0].amount_minor")).accessibilityIdentifier("v15.f3c.mac.claim.amount")
            V15ActionButton("创建报销单", disabledReasons: model.createClaimDisabledReasons) { Task { await model.createClaim() } }.accessibilityIdentifier("v15.f3c.mac.claim.create")
            if model.hasRecoverableCreateAttempt && model.newClaimPhase == .unknown {
                HStack(alignment: .top) {
                    V15ActionButton("同一请求键重试", kind: .secondary, disabledReason: model.isOffline ? .init(code: "offline_read_only", message: "离线时不能重试写入。", fieldPath: nil) : nil) { Task { await model.retryUnknownCreateClaim() } }.accessibilityIdentifier("v15.f3c.mac.claim.retry-same-key")
                    V15ActionButton("放弃恢复", kind: .quiet) { model.abandonUnknownCreateClaim() }.accessibilityIdentifier("v15.f3c.mac.claim.abandon")
                }
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("v15.f3c.mac.claim.inspector")
    }

    @ViewBuilder private var candidateInspector: some View {
        switch model.candidatesPhase {
        case .idle, .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f3c.mac.candidates.loading")
        case .empty: V15EmptyState(title: "没有垫付候选", explanation: "调整搜索条件后重试。", actionTitle: "重试") { Task { await model.retryCandidates() } }.accessibilityIdentifier("v15.f3c.mac.candidates.empty")
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.retryCandidates() } }.accessibilityIdentifier("v15.f3c.mac.candidates.error")
        case .loaded:
            ForEach(model.candidates, id: \.transactionID) { candidate in Button { model.chooseCandidate(candidate) } label: { VStack(alignment: .leading) { HStack { Text(candidate.title); Spacer(); Text(money(candidate.availableMinor)).monospacedDigit() }; Text(candidate.categoryID == nil ? "未分类 · 服务端允许" : candidate.businessDate).font(V15Typography.secondary); ForEach(candidate.eligibility.reasonDetails, id: \.code) { Text($0.message).font(V15Typography.secondary).foregroundStyle(V15Palette.teal.color) } }.padding(V15Spacing.sm).background(model.selectedCandidate?.transactionID == candidate.transactionID ? V15Palette.selected.color : V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control)) }.buttonStyle(.plain).disabled(!candidate.eligibility.eligible).accessibilityIdentifier("v15.f3c.mac.candidate.\(candidate.transactionID)") }
        }
    }

    private var receiptInspector: some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            HStack { Text("登记到账").font(V15Typography.cardTitle); Spacer(); Button("关闭") { model.dismissReceipt() }.accessibilityIdentifier("v15.f3c.mac.receipt.close") }
            editorBanner(model.receiptPhase, issues: model.receiptServerIssues)
            if let claim = model.selectedClaim {
                ForEach(claim.parties, id: \.id) { party in Button { model.chooseParty(party.id) } label: { HStack { Text(party.name); Spacer(); Text(money(party.outstandingMinor)).monospacedDigit() }.padding(V15Spacing.sm).background(model.selectedPartyID == party.id ? V15Palette.selected.color : V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control)) }.buttonStyle(.plain).disabled(party.outstandingMinor <= 0).accessibilityIdentifier("v15.f3c.mac.receipt.party.\(party.id)") }
            }
            V15Field("到账标题", text: Binding(get: { model.receiptTitle }, set: { model.receiptTitle = $0 }), issues: fieldIssues(model.receiptIssues, path: "title")).accessibilityIdentifier("v15.f3c.mac.receipt.title")
            V15Field("到账金额（元）", text: Binding(get: { model.receiptAmountText }, set: { model.receiptAmountText = $0 }), issues: fieldIssues(model.receiptIssues, path: "amount_minor")).accessibilityIdentifier("v15.f3c.mac.receipt.amount")
            V15Field("到账日期", text: Binding(get: { model.receiptDateText }, set: { model.receiptDateText = $0 }), prompt: "YYYY-MM-DD", issues: fieldIssues(model.receiptIssues, path: "received_at")).accessibilityIdentifier("v15.f3c.mac.receipt.date")
            accountInspector
            V15ActionButton("预览到账影响", kind: .secondary, disabledReasons: model.receiptPreviewDisabledReasons) { Task { await model.previewReceipt() } }.accessibilityIdentifier("v15.f3c.mac.receipt.preview")
            if let preview = model.receiptPreview { V15PreviewState(version: "claim v\(preview.claimVersion)") { Text("已到账 \(money(preview.claimReceivedBeforeMinor)) → \(money(preview.claimReceivedAfterMinor))；\(preview.persistedAllocations.count) 条服务端分配。").font(V15Typography.secondary) }.accessibilityIdentifier("v15.f3c.mac.receipt.preview.result") }
            V15ActionButton("确认登记到账", disabledReasons: model.receiptCommitDisabledReasons) { Task { await model.commitReceipt() } }.accessibilityIdentifier("v15.f3c.mac.receipt.commit")
            if model.hasRecoverableReceiptAttempt && model.receiptPhase == .unknown {
                HStack(alignment: .top) {
                    V15ActionButton("同一请求键重试", kind: .secondary, disabledReason: model.isOffline ? .init(code: "offline_read_only", message: "离线时不能重试写入。", fieldPath: nil) : nil) { Task { await model.retryUnknownReceipt() } }.accessibilityIdentifier("v15.f3c.mac.receipt.retry-same-key")
                    V15ActionButton("放弃恢复", kind: .quiet) { model.abandonUnknownReceipt() }.accessibilityIdentifier("v15.f3c.mac.receipt.abandon")
                }
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("v15.f3c.mac.receipt.inspector")
    }

    @ViewBuilder private var accountInspector: some View {
        switch model.receiptAccountsPhase {
        case .idle, .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f3c.mac.receipt.accounts.loading")
        case .empty: V15EmptyState(title: "没有收款账户", explanation: "需要启用的现金或借记账户。", actionTitle: "重试") { Task { await model.retryReceiptAccounts() } }.accessibilityIdentifier("v15.f3c.mac.receipt.accounts.empty")
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.retryReceiptAccounts() } }.accessibilityIdentifier("v15.f3c.mac.receipt.accounts.error")
        case .loaded: ForEach(model.receiptAccounts) { account in Button { model.chooseReceiptAccount(account) } label: { HStack { Text(account.name); Spacer(); Text(account.kind) }.padding(V15Spacing.sm).background(model.selectedReceiptAccount?.id == account.id ? V15Palette.selected.color : V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control)) }.buttonStyle(.plain).accessibilityIdentifier("v15.f3c.mac.receipt.account.\(account.id)") }
        }
    }

    @ViewBuilder private func editorBanner(_ phase: V15ReimbursementModel.EditorPhase, issues: [V15FieldIssue]) -> some View {
        switch phase {
        case .failed(let failure): nonRetryableMessage(title: "操作未完成", message: failure.message).accessibilityIdentifier("v15.f3c.mac.inspector.error")
        case .conflict(let conflict): V15ConflictState(conflict: conflict) { Task { await model.refresh() } }.accessibilityIdentifier("v15.f3c.mac.inspector.conflict")
        case .unknown: nonRetryableMessage(title: "请求结果未知", message: "不可换请求键盲重发；请使用下方同一请求键恢复操作，或明确放弃恢复。").accessibilityIdentifier("v15.f3c.mac.inspector.unknown")
        case .succeeded: V15SuccessReceiptState(title: "服务端已确认", detail: "新版本事实已返回。")
        default: EmptyView()
        }
        V15FieldIssues(issues: issues).accessibilityIdentifier("v15.f3c.mac.remote-reasons")
    }

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

    private func fieldIssues(_ values: [V15FieldIssue], path: String) -> [V15FieldIssue] { values.filter { $0.fieldPath == path || $0.fieldPath?.hasPrefix(path + ".") == true } }
    private func money(_ value: V15MinorUnits) -> String { V15MoneyPresentation(minorUnits: value, direction: .neutral, includeCurrency: true).text }
    private func claimAmountFact(_ title: String, _ value: V15MinorUnits, emphasized: Bool = false) -> some View { VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text(title).font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.62)); V15MoneyText(minorUnits: value, direction: .neutral, font: V15Typography.body.weight(.semibold)) }.padding(V15Spacing.sm).frame(maxWidth: .infinity, alignment: .leading).background(emphasized ? V15Palette.selected.color : V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control)) }
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
    @MainActor private func prepareGalleryScenario(_ scenario: String) async {
        switch scenario {
        case "reimbursements-claim-new":
            await model.openNewClaim(); model.claimTitle = "八月差旅报销"; model.partyName = "示例公司"
            if let candidate = model.candidates.first(where: { $0.eligibility.eligible && $0.categoryID == nil }) { model.chooseCandidate(candidate) }
        case "reimbursements-claim-reasons":
            await model.openNewClaim()
        case "reimbursements-receipt-loading", "reimbursements-receipt-empty", "reimbursements-receipt-retry":
            await model.openReceipt()
        case "reimbursements-invalid-valid":
            await model.openReceipt(); model.receiptTitle = ""; model.receiptAmountText = "180.001"; model.receiptDateText = "9999-12-31"
        case "reimbursements-preview":
            await model.openReceipt(); await model.previewReceipt()
        case "reimbursements-receipt-replace":
            if let receipt = model.receipts.first { model.openReceiptReplacement(receipt); inspectorMode = .receiptReplacement(receipt.id) }
        case "reimbursements-conflict":
            await model.openReceipt(); await model.previewReceipt()
        case "reimbursements-success":
            await model.openReceipt(); await model.previewReceipt(); await model.commitReceipt()
        case "reimbursements-receipt-refresh-failure":
            await model.openReceipt(); await model.previewReceipt(); await model.commitReceipt()
        default:
            break
        }
    }
}
#endif
