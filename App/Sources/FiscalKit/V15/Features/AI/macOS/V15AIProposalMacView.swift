import SwiftUI

public struct V15AIProposalMacView: View {
    private enum ListScope: String, CaseIterable, Identifiable { case pending, history; var id: String { rawValue } }
    @State private var model: V15AIProposalModel
    @State private var showsReview = false
    @State private var listScope: ListScope = .pending
    private let initialGalleryScenario: String?

    @MainActor public init(services: V15Services, offlineSnapshotAt: Date? = nil, initialGalleryScenario: String? = nil) {
        _model = State(initialValue: V15AIProposalModel(services: services, offlineSnapshotAt: offlineSnapshotAt))
        self.initialGalleryScenario = initialGalleryScenario
    }

    public var body: some View {
        HStack(spacing: 0) {
            spine.frame(minWidth: V15MacLayout.compactAIWidths.spine, idealWidth: 290, maxWidth: 340)
            Divider()
            detail.frame(minWidth: V15MacLayout.compactAIWidths.detail, maxWidth: .infinity)
            Divider()
            inspector.frame(minWidth: V15MacLayout.compactAIWidths.inspector, idealWidth: 330, maxWidth: 330)
        }
        .v15MacWorkspaceCanvas()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f3f.ai.macos")
        .task { if model.phase == .idle { await model.load(); await applyInitialScenario() } }
        .onChange(of: listScope) { _, _ in reconcileVisibleSelection() }
        .onChange(of: proposalScopeSignature) { _, _ in reconcileVisibleSelection() }
        .sheet(isPresented: $showsReview, onDismiss: { model.dismissEditor() }) { reviewSheet.frame(minWidth: 620, minHeight: 720) }
    }

    private var spine: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                Text("AI 记账").font(V15Typography.cardTitle)
                Text(model.pendingCount == 0 ? "当前没有待确认内容" : "\(model.pendingCount) 笔需要你确认")
                    .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
                Picker("内容范围", selection: $listScope) {
                    Text("待确认").tag(ListScope.pending).accessibilityIdentifier("v15.f3f.scope.pending")
                    Text("历史").tag(ListScope.history).accessibilityIdentifier("v15.f3f.scope.history")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("v15.f3f.list.scope")
            }.padding(V15Spacing.md)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                    switch model.phase {
                    case .idle, .loading: V15LoadingSkeleton()
                    case .empty: V15EmptyState(title: listScope == .pending ? "没有待确认内容" : "还没有历史记录", explanation: listScope == .pending ? "在右侧输入记账文字，或查看历史。" : "切换到待确认可处理新内容。")
                    case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.load() } }
                    case .loaded:
                        if displayedProposals.isEmpty {
                            V15EmptyState(title: listScope == .pending ? "没有待确认内容" : "当前没有历史记录", explanation: listScope == .pending ? "所有项目都已处理；可在历史中查看记录。" : "处理完成的内容会显示在这里。")
                        } else {
                            ForEach(displayedProposals) { proposal in V15AIProposalRow(proposal: proposal, selected: model.selectedProposal?.id == proposal.id) { Task { await model.select(proposal) } } }
                        }
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

    private var displayedProposals: [V15AIProposal] {
        model.proposals.filter { proposal in
            listScope == .pending ? proposal.status == .pending || proposal.status == .processing || proposal.status == .failed : ![.pending, .processing, .failed].contains(proposal.status)
        }
    }

    private var visibleSelectedProposal: V15AIProposal? {
        guard let selected = model.selectedProposal else { return nil }
        return displayedProposals.first(where: { $0.id == selected.id })
    }

    private var proposalScopeSignature: [String] {
        model.proposals.map { "\($0.id.uuidString):\($0.status)" }
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: V15Spacing.section) {
                HStack { Text("内容详情").font(V15Typography.surfaceTitle); Spacer(); Button("刷新") { Task { await model.load() } } }
                V15AIMutationSurface(model: model)
                switch model.detailPhase {
                case .idle: V15EmptyState(title: "选择一项内容", explanation: "这里显示识别结果和待补充内容。")
                case .loading: V15LoadingSkeleton()
                case .empty: V15EmptyState(title: "没有详情", explanation: "暂时没有取得这项内容。")
                case .failed(let failure): V15ServiceErrorState(message: failure.message) { if let proposal = visibleSelectedProposal { Task { await model.select(proposal) } } }
                case .loaded:
                    if let proposal = visibleSelectedProposal { V15AIProposalDetail(proposal: proposal, events: model.qualityEvents) }
                    else { V15EmptyState(title: "选择一项内容", explanation: "这里显示当前范围内的识别结果和处理状态。") }
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
                    Text("每一笔都由你确认，AI 不会自动记账。").font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("v15.f3f.d3-invariant")
                    if let reason = model.settingsSafetyReason {
                        V15ServiceErrorState(message: reason.message) { Task { await model.load() } }
                            .accessibilityIdentifier("v15.f3f.d3-contract-banner")
                    }
                    if let snapshot = model.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: snapshot) }
                }
                V15Section("新建待确认内容") {
                    Picker("来源", selection: $model.source) { ForEach(V15AIProposalSource.allCases) { Text($0.displayName).tag($0) } }.pickerStyle(.menu)
                    V15Field("记账文字", text: $model.inputText, prompt: "午餐 132 元", axis: .vertical)
                    V15ActionButton("生成待确认账目", kind: .primary, disabledReasons: model.createReasons) { Task { await model.create() } }.accessibilityIdentifier("v15.f3f.create.submit")
                    V15AIStableCreateRecoverySurface(model: model)
                }
                if let proposal = visibleSelectedProposal {
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
                    Text("检查并修改").font(V15Typography.cardTitle)
                    Text("保存修改后，还需要由你确认记账。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
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
                        V15ActionButton("保存修改", kind: .secondary, disabledReasons: model.confirmReasons) { Task { await model.confirmDraft() } }.accessibilityIdentifier("v15.f3f.editor.confirm")
                        if let proposal = model.selectedProposal {
                            V15ActionButton("确认记账", kind: .primary, disabledReasons: model.actionReasons(.execute, proposal: proposal)) { Task { await model.execute(); if model.selectedProposal?.status == .executed { showsReview = false } } }.accessibilityIdentifier("v15.f3f.editor.execute")
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


    private func reconcileVisibleSelection() {
        guard !model.writeLocked else { return }
        if case .succeeded = model.mutationPhase { return }
        let visible = displayedProposals
        guard !visible.contains(where: { $0.id == model.selectedProposal?.id }) else { return }
        guard let first = visible.first else { model.clearSelection(); return }
        Task { await model.select(first) }
    }
}
