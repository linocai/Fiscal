import SwiftUI

public struct V15AIProposalMacView: View {
    @State private var model: V15AIProposalModel
    @State private var showsReview = false
    private let initialGalleryScenario: String?

    @MainActor public init(services: V15Services, offlineSnapshotAt: Date? = nil, initialGalleryScenario: String? = nil) {
        _model = State(initialValue: V15AIProposalModel(services: services, offlineSnapshotAt: offlineSnapshotAt))
        self.initialGalleryScenario = initialGalleryScenario
    }

    public var body: some View {
        HStack(spacing: 0) {
            spine.frame(minWidth: 250, idealWidth: 290, maxWidth: 340)
            Divider()
            detail.frame(minWidth: 420, maxWidth: .infinity)
            Divider()
            inspector.frame(width: 330)
        }
        .background(V15Palette.paper.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f3f.ai.macos")
        .task { if model.phase == .idle { await model.load(); await applyInitialScenario() } }
        .sheet(isPresented: $showsReview, onDismiss: { model.dismissEditor() }) { reviewSheet.frame(minWidth: 620, minHeight: 720) }
    }

    private var spine: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                Text("AI 提案").font(V15Typography.cardTitle)
                Text("\(model.pendingCount) 笔待人工确认").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
            }.padding(V15Spacing.md)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                    switch model.phase {
                    case .idle, .loading: V15LoadingSkeleton()
                    case .empty: V15EmptyState(title: "没有提案", explanation: "在右侧输入文字建立提案。")
                    case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.load() } }
                    case .loaded:
                        ForEach(model.proposals) { proposal in V15AIProposalRow(proposal: proposal, selected: model.selectedProposal?.id == proposal.id) { Task { await model.select(proposal) } } }
                        if model.nextCursor != nil {
                            switch model.pagePhase {
                            case .loading:
                                V15LoadingSkeleton().accessibilityIdentifier("v15.f3f.page.loading")
                            case .failed(let failure):
                                V15ServiceErrorState(message: failure.message) { Task { await model.loadNextPage() } }.accessibilityIdentifier("v15.f3f.page.error")
                            default:
                                V15ActionButton("加载更多", kind: .quiet) { Task { await model.loadNextPage() } }.accessibilityIdentifier("v15.f3f.page.more")
                            }
                        }
                    }
                }.padding(V15Spacing.sm)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f3f.spine")
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: V15Spacing.section) {
                HStack { Text("提案事实").font(V15Typography.surfaceTitle); Spacer(); Button("刷新") { Task { await model.load() } } }
                V15AIMutationSurface(model: model)
                switch model.detailPhase {
                case .idle: V15EmptyState(title: "选择一项提案", explanation: "中栏显示解析事实与质量事件。")
                case .loading: V15LoadingSkeleton()
                case .empty: V15EmptyState(title: "没有详情", explanation: "服务端没有返回此提案。")
                case .failed(let failure): V15ServiceErrorState(message: failure.message) { if let proposal = model.selectedProposal { Task { await model.select(proposal) } } }
                case .loaded: if let proposal = model.selectedProposal { V15AIProposalDetail(proposal: proposal, events: model.qualityEvents) }
                }
            }.padding(V15Spacing.lg)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f3f.detail")
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: V15Spacing.lg) {
                V15Section("安全边界") {
                    Label("只接受人工确认", systemImage: "hand.raised.fill").font(V15Typography.body.weight(.semibold)).foregroundStyle(V15Palette.teal.color)
                    Text("effective_auto_execute=false").font(.caption.monospaced()).foregroundStyle(V15Palette.ink.color.opacity(0.66)).accessibilityIdentifier("v15.f3f.d3-invariant")
                    Text("不提供策略放宽、提供方密钥或财务聊天入口。").font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
                    if let reason = model.settingsSafetyReason {
                        V15ServiceErrorState(message: reason.message) { Task { await model.load() } }
                            .accessibilityIdentifier("v15.f3f.d3-contract-banner")
                    }
                    if let snapshot = model.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: snapshot) }
                }
                V15Section("新建提案") {
                    Picker("来源", selection: $model.source) { ForEach(V15AIProposalSource.allCases) { Text($0.displayName).tag($0) } }.pickerStyle(.menu)
                    V15Field("记账文字", text: $model.inputText, prompt: "午餐 132 元", axis: .vertical)
                    V15ActionButton("生成待确认提案", kind: .primary, disabledReasons: model.createReasons) { Task { await model.create() } }.accessibilityIdentifier("v15.f3f.create.submit")
                    V15AIStableCreateRecoverySurface(model: model)
                }
                if let proposal = model.selectedProposal {
                    V15Section("人工动作") { V15AIProposalActions(model: model, proposal: proposal) { model.openReview(proposal); showsReview = true } }
                }
            }.padding(V15Spacing.md)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f3f.inspector")
    }

    private var reviewSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                    Text("人工审核").font(V15Typography.cardTitle)
                    Text("保存审核与人工执行是两个独立步骤。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
                }
                Spacer()
                Button("关闭") { showsReview = false }.disabled(model.mutationPhase == .loading)
            }.padding(V15Spacing.lg)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.lg) {
                    V15AIEditorFields(model: model)
                    V15AIMutationSurface(model: model)
                    HStack(alignment: .top, spacing: V15Spacing.sm) {
                        V15ActionButton("保存并确认审核内容", kind: .secondary, disabledReasons: model.confirmReasons) { Task { await model.confirmDraft() } }.accessibilityIdentifier("v15.f3f.editor.confirm")
                        if let proposal = model.selectedProposal {
                            V15ActionButton("人工执行", kind: .primary, disabledReasons: model.actionReasons(.execute, proposal: proposal)) { Task { await model.execute(); if model.selectedProposal?.status == .executed { showsReview = false } } }.accessibilityIdentifier("v15.f3f.editor.execute")
                        }
                    }
                }.padding(V15Spacing.lg)
            }
        }
        .background(V15Palette.paper.color)
        .interactiveDismissDisabled(model.mutationPhase == .loading || model.hasUnknownDirect)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f3f.editor.sheet")
    }

    private func applyInitialScenario() async {
        guard let initialGalleryScenario, let proposal = model.selectedProposal else { return }
        switch initialGalleryScenario {
        case "ai-review":
            model.openReview(proposal)
            guard let categoryID = model.visibleCategories.first?.id else { return }
            model.categoryID = categoryID
            showsReview = true
        case "ai-field-error", "ai-conflict", "ai-response-unknown", "ai-response-unknown-read-failure":
            model.openReview(proposal)
            guard let categoryID = model.visibleCategories.first?.id else { return }
            model.categoryID = categoryID
            showsReview = true
            await model.confirmDraft()
            if initialGalleryScenario == "ai-response-unknown-read-failure" { await model.recoverUnknownDirect() }
        case "ai-page-error":
            await model.loadNextPage()
        case "ai-create-unknown", "ai-create-unknown-settings-transport-after-safe":
            model.inputText = "午餐 132 元"
            await model.create()
            if initialGalleryScenario == "ai-create-unknown-settings-transport-after-safe" { await model.load() }
        case "ai-cash-flow":
            model.openReview(proposal)
            showsReview = true
        default:
            break
        }
    }
}
