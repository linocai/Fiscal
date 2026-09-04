import SwiftUI
#if os(iOS)
import UIKit
#endif

public struct V15AIProposalView: View {
    @State private var model: V15AIProposalModel
    @State private var showsReview = false
    private let closeAction: (() -> Void)?

    @MainActor public init(
        services: V15Services,
        offlineSnapshotAt: Date? = nil,
        onClose: (() -> Void)? = nil
    ) {
        _model = State(initialValue: V15AIProposalModel(services: services, offlineSnapshotAt: offlineSnapshotAt))
        closeAction = onClose
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.section) {
                    header
                    if let reason = model.settingsSafetyReason {
                        V15ServiceErrorState(message: reason.message) { Task { await model.load() } }
                            .accessibilityIdentifier("v15.f3f.d3-contract-banner")
                    }
                    if !showsReview { V15AIMutationSurface(model: model) }
                    createSurface
                    queueSurface
                    detailSurface
                }
                .padding(V15Spacing.md)
                .frame(maxWidth: 720, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .v15IOSScreenCanvas()
            .navigationTitle("AI 记账")
            .toolbar {
#if os(iOS)
                if let closeAction {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭", action: closeAction).accessibilityIdentifier("v15.f3f.close")
                    }
                }
#endif
#if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("刷新") { Task { await model.load() } }.accessibilityIdentifier("v15.f3f.refresh")
                }
#endif
            }
        }
        .accessibilityIdentifier("v15.f3f.ai.ios")
        .task { if model.phase == .idle { await model.load() } }
        .sheet(isPresented: $showsReview, onDismiss: { model.dismissEditor() }) { reviewSheet }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: V15Spacing.sm) {
            Text("先看清，再记账").font(V15Typography.surfaceTitle).foregroundStyle(V15Palette.ink.color)
            Text("AI 会先整理出待确认内容。请检查并保存修改，确认无误后再记账。").font(V15Typography.body).foregroundStyle(V15Palette.ink.color.opacity(0.68)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: V15Spacing.xs) {
                Image(systemName: "hand.raised.fill").foregroundStyle(V15Palette.teal.color)
                Text("每一笔都由你确认，AI 不会自动记账").font(V15Typography.secondary.weight(.semibold)).foregroundStyle(V15Palette.teal.color)
            }
            .padding(V15Spacing.sm)
            .background(V15Palette.selected.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
            .accessibilityIdentifier("v15.f3f.d3-invariant")
            if let snapshot = model.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: snapshot).accessibilityIdentifier("v15.f3f.offline") }
        }
        .padding(V15Spacing.md)
        .v15IOSCard()
    }

    private var createSurface: some View {
        V15Section("新建待确认内容") {
            Picker("来源", selection: $model.source) { ForEach(V15AIProposalSource.allCases) { Text($0.displayName).tag($0) } }.pickerStyle(.segmented).accessibilityIdentifier("v15.f3f.create.source")
            V15Field("记账文字", text: $model.inputText, prompt: "例如：午餐 132 元，日常借记", issues: [], axis: .vertical).accessibilityIdentifier("v15.f3f.create.text")
            V15ActionButton("生成待确认账目", kind: .primary, disabledReasons: model.createReasons) {
                dismissKeyboard()
                Task { await model.create() }
            }.accessibilityIdentifier("v15.f3f.create.submit")
            V15AIStableCreateRecoverySurface(model: model)
        }
    }

    @ViewBuilder private var queueSurface: some View {
        V15Section("待确认内容", detail: "\(model.pendingCount) 笔") {
            switch model.phase {
            case .idle, .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f3f.queue.loading")
            case .empty: V15EmptyState(title: "没有待确认内容", explanation: "输入一段记账文字，识别结果会留在这里等待你确认。").accessibilityIdentifier("v15.f3f.queue.empty")
            case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.load() } }.accessibilityIdentifier("v15.f3f.queue.error")
            case .loaded:
                LazyVStack(spacing: V15Spacing.xxs) {
                    ForEach(model.proposals) { proposal in V15AIProposalRow(proposal: proposal, selected: model.selectedProposal?.id == proposal.id) { Task { await model.select(proposal) } } }
                }
                if model.nextCursor != nil {
                    switch model.pagePhase {
                    case .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f3f.page.loading")
                    case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.loadNextPage() } }.accessibilityIdentifier("v15.f3f.page.error")
                    default: V15ActionButton("加载更多", kind: .quiet) { Task { await model.loadNextPage() } }.accessibilityIdentifier("v15.f3f.page.more")
                    }
                }
            }
        }
    }

    @ViewBuilder private var detailSurface: some View {
        V15Section("内容详情") {
            switch model.detailPhase {
            case .idle: V15EmptyState(title: "选择一项内容", explanation: "查看识别结果、待补充内容和处理记录。")
            case .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f3f.detail.loading")
            case .empty: V15EmptyState(title: "没有详情", explanation: "暂时没有取得这项内容。")
            case .failed(let failure): V15ServiceErrorState(message: failure.message) { if let proposal = model.selectedProposal { Task { await model.select(proposal) } } }.accessibilityIdentifier("v15.f3f.detail.error")
            case .loaded:
                if let proposal = model.selectedProposal {
                    V15AIProposalDetail(proposal: proposal, events: model.qualityEvents)
                    Divider()
                    V15AIProposalActions(model: model, proposal: proposal) { model.openReview(proposal); showsReview = true }
                }
            }
        }
    }

    private var reviewSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.lg) {
                    Text("检查并修改").font(V15Typography.cardTitle)
                    Text("保存修改不会自动记账。确认无误后，请再点一次确认记账。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.68)).fixedSize(horizontal: false, vertical: true)
                    V15AIEditorFields(model: model)
                    V15AIMutationSurface(model: model)
                    V15ActionButton("保存修改", kind: .secondary, disabledReasons: model.confirmReasons) { Task { await model.confirmDraft() } }.accessibilityIdentifier("v15.f3f.editor.confirm")
                    if let proposal = model.selectedProposal {
                        V15ActionButton("确认记账", symbol: "checkmark.circle", kind: .primary, disabledReasons: model.actionReasons(.execute, proposal: proposal)) {
                            Task { await model.execute(); if model.selectedProposal?.status == .executed { showsReview = false } }
                        }.accessibilityIdentifier("v15.f3f.editor.execute")
                    }
                }.padding(V15Spacing.md)
            }
            .scrollDismissesKeyboard(.interactively)
            .v15IOSScreenCanvas()
            .navigationTitle("检查 AI 内容")
            .toolbar { Button("关闭") { showsReview = false }.disabled(model.mutationPhase == .loading).accessibilityIdentifier("v15.f3f.editor.close") }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(model.mutationPhase == .loading || model.hasUnknownDirect)
        .accessibilityIdentifier("v15.f3f.editor.sheet")
    }

    private func dismissKeyboard() {
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}
