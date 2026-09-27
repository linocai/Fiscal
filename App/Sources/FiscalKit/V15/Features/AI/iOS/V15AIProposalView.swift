import SwiftUI
#if os(iOS)
import UIKit
import PhotosUI
#endif

#if os(iOS)
public struct V15AIProposalView: View {
    @State private var model: V15AIProposalModel
    @State private var showsReview = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoPickerPresented = false
    @State private var photoSelectionSerial: UInt64 = 0
    @State private var photoImportMessage: String?
    @State private var isReadingPhoto = false
    @State private var initialOpenMessage: String?
    private let services: V15Services
    private let initialProposalID: UUID?
    private let closeAction: (() -> Void)?

    @MainActor public init(
        services: V15Services,
        offlineSnapshotAt: Date? = nil,
        initialProposalID: UUID? = nil,
        onClose: (() -> Void)? = nil
    ) {
        _model = State(initialValue: V15AIProposalModel(services: services, offlineSnapshotAt: offlineSnapshotAt))
        self.services = services
        self.initialProposalID = initialProposalID
        closeAction = onClose
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.section) {
                    header
                    if let initialOpenMessage {
                        V15ErrorMessageState(title: "无法打开待确认内容", message: initialOpenMessage)
                            .accessibilityIdentifier("v15.f3f.route.error")
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
            .navigationTitle("AI 记账").v22CompactNavigationTitle()
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
        .task(id: initialProposalID) {
            if model.phase == .idle { await model.load() }
            await openInitialProposal()
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            photoSelectionSerial &+= 1
            Task { await recognizeAndCreate(item) }
        }
        .onChange(of: photoPickerPresented) { wasPresented, isPresented in
            guard wasPresented && !isPresented else { return }
            let serial = photoSelectionSerial
            Task { @MainActor in
                // PhotosPicker can publish dismissal just before the selected
                // item. Give that state change one turn before showing cancel.
                try? await Task.sleep(for: .milliseconds(200))
                if serial == photoSelectionSerial && !photoPickerPresented && selectedPhoto == nil && !isReadingPhoto {
                    photoImportMessage = "已取消选择截图，现有文字仍可继续编辑。"
                }
            }
        }
        .sheet(isPresented: $showsReview, onDismiss: { model.dismissEditor() }) { reviewSheet }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: V15Spacing.sm) {
            V22PageHeader("AI 记账", symbol: "sparkles", subtitle: "说一句，整理成一笔待确认账目")
            HStack(spacing: V15Spacing.xs) {
                Image(systemName: "hand.raised.fill").foregroundStyle(V15Palette.teal.color)
                Text("每一笔都由你确认，AI 不会自动记账").font(V15Typography.secondary.weight(.semibold)).foregroundStyle(V15Palette.teal.color)
            }
            .padding(V15Spacing.sm)
            .background(V15Palette.selected.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
            .accessibilityIdentifier("v15.f3f.d3-invariant")
            if let snapshot = model.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: snapshot).accessibilityIdentifier("v15.f3f.offline") }
        }
    }

    private var createSurface: some View {
        let photoButtonTitle = isReadingPhoto ? "正在识别截图" : "选择截图识别"
        return V22FormSection("描述这笔收支") {
            HStack {
                Text(model.source == .ocr ? "截图文字" : "手工文字").font(V15Typography.secondary.weight(.semibold))
                Spacer()
                if model.source == .ocr {
                    Button("改用文字") { model.source = .text }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("v15.f3f.create.source.text")
                }
            }
            Button {
                selectedPhoto = nil
                photoImportMessage = nil
                photoPickerPresented = true
            } label: {
                Label(photoButtonTitle, systemImage: "text.viewfinder")
            }
            .photosPicker(isPresented: $photoPickerPresented, selection: $selectedPhoto, matching: .images)
            .disabled(isReadingPhoto)
            .accessibilityIdentifier("v15.f3f.create.photo")
            Text("截图只在本机识别文字；发送给 AI 的只有识别结果。")
                .font(V15Typography.secondary)
                .foregroundStyle(V15Palette.ink.color.opacity(0.66))
            if let photoImportMessage {
                V15ErrorMessageState(title: "截图识别未完成", message: photoImportMessage)
                    .accessibilityIdentifier("v15.f3f.create.photo-error")
            }
            V15Field("记账文字", text: $model.inputText, prompt: "例如：午餐 132 元，日常借记", issues: [], axis: .vertical).accessibilityIdentifier("v15.f3f.create.text")
            V15ActionButton("生成待确认账目", kind: .primary, disabledReasons: model.createReasons + (isReadingPhoto ? [.init(code: "ocr_in_progress", message: "正在识别截图，请稍候。", fieldPath: nil)] : [])) {
                dismissKeyboard()
                Task { await model.create() }
            }.accessibilityIdentifier("v15.f3f.create.submit")
            V15AIStableCreateRecoverySurface(model: model)
        }
    }

    @MainActor private func recognizeAndCreate(_ item: PhotosPickerItem) async {
        isReadingPhoto = true
        photoImportMessage = nil
        defer { isReadingPhoto = false; selectedPhoto = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw OCRInputError.screenshotUnavailable
            }
            let result = try await VisionOCRService().recognize(imageData: data)
            model.source = .ocr
            model.inputText = result.text
            guard model.createReasons.isEmpty else {
                photoImportMessage = model.createReasons.map(\.message).joined(separator: "；")
                return
            }
            await model.create()
        } catch is CancellationError {
            photoImportMessage = "识别已取消，现有文字仍可继续编辑。"
        } catch {
            photoImportMessage = (error as? LocalizedError)?.errorDescription ?? "截图读取失败，请重新选择。"
        }
    }

    @MainActor private func openInitialProposal() async {
        guard let initialProposalID else { return }
        do {
            let proposal = try await services.ai.proposal(id: initialProposalID, readCachePolicy: .reloadIgnoringCache)
            await model.select(proposal)
            initialOpenMessage = nil
        } catch let failure as V15Failure {
            initialOpenMessage = failure.message
        } catch {
            initialOpenMessage = "这项待确认内容暂时不可读取。"
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
                    V15AIProposalDetail(proposal: proposal)
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
                    V22PageHeader("核对这笔账", symbol: "checkmark.bubble", subtitle: "保存修改后，再由你确认记账")
                    V22FlowProgress(["核对信息", "保存修改", "确认记账"], current: 0)
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
            .navigationTitle("检查 AI 内容").v22CompactNavigationTitle()
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
#endif
