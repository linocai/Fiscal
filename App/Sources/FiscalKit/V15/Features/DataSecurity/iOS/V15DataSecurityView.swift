import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
public struct V15DataSecurityView: View {
    @State private var model: V15ArchiveModel
    @State private var exporterPresented = false

    public init(services: V15Services, offlineSnapshotAt: Date? = nil) {
        _model = State(initialValue: .init(services: services, offlineSnapshotAt: offlineSnapshotAt))
    }

    init(model: V15ArchiveModel) { _model = State(initialValue: model) }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.lg) {
                    heading
                    securityFacts
                    exportCard
                    restoreCard
                }
                .padding(V15Spacing.md)
                .frame(maxWidth: 680, alignment: .leading)
            }
            .background(V15Palette.paper.color)
            .navigationTitle("数据与安全")
        }
        .sheet(isPresented: confirmationPresented) { confirmationSheet }
        .fileExporter(
            isPresented: $exporterPresented,
            document: V15ArchiveFileDocument(url: model.temporaryURL),
            contentType: UTType("com.fiscal.archive") ?? .data,
            defaultFilename: "fiscal-archive-v1.far"
        ) { result in
            switch result { case .success: model.completeIOSHandoff(success: true); case .failure: model.completeIOSHandoff(success: false) }
        }
        .onDisappear { model.dismiss() }
        .accessibilityIdentifier("v15.f4c.security.ios")
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: V15Spacing.xs) {
            Text("加密 Archive v1").font(V15Typography.surfaceTitle).foregroundStyle(V15Palette.ink.color)
            Text("按上海业务时区创建。归档不等于删除，也不会恢复访问凭证或 Provider 配置。")
                .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.68)).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var securityFacts: some View {
        V15Section("归档范围") {
            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                Text("• 使用 server-side scrypt + AES-256-GCM 加密")
                Text("• 不包含访问凭证、Provider 配置或 AI 原文")
                Text("• 创建后请立即存入受控位置并妥善保管密码")
            }.font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var exportCard: some View {
        V15Section("导出加密归档") {
            VStack(alignment: .leading, spacing: V15Spacing.sm) {
                SecureField("归档密码（12–128 个字符）", text: $model.password).textContentType(.newPassword).accessibilityIdentifier("v15.f4c.password")
                SecureField("再次输入归档密码", text: $model.passwordConfirmation).textContentType(.newPassword).accessibilityIdentifier("v15.f4c.password-confirmation")
                if let issue = model.passwordIssue { message(issue) }
                if model.isOffline { message(model.exportDisabledReason ?? "离线快照不能创建归档。") }
                phaseSurface
                if model.phase == .idle {
                    Button("创建加密归档") { model.beginExport() }.buttonStyle(.borderedProminent).disabled(!model.canBeginExport).accessibilityIdentifier("v15.f4c.export")
                }
            }
        }
    }
    @ViewBuilder private var phaseSurface: some View {
        switch model.phase {
        case .creating: ProgressView("正在创建加密归档…").accessibilityIdentifier("v15.f4c.creating")
        case .ready: Button("存入文件…") { exporterPresented = true }.buttonStyle(.borderedProminent).accessibilityIdentifier("v15.f4c.handoff")
        case .completed: message("已在此设备导出加密归档。").accessibilityIdentifier("v15.f4c.success")
        case .failed(let failure):
            VStack(alignment: .leading, spacing: V15Spacing.sm) {
                failureSurface(failure, id: "v15.f4c.error")
                retryControls
            }
        case .unknown:
            VStack(alignment: .leading, spacing: V15Spacing.sm) {
                message("文件结果未知，未保留本地副本。请重新创建归档。").accessibilityIdentifier("v15.f4c.unknown")
                retryControls
            }
        case .saveFailed(_, let failure):
            VStack(alignment: .leading, spacing: V15Spacing.sm) {
                failureSurface(failure, id: "v15.f4c.error")
                Button("重试存入文件") { exporterPresented = true }.accessibilityIdentifier("v15.f4c.save-retry")
                Button("关闭") { model.dismiss() }.accessibilityIdentifier("v15.f4c.close")
            }
        default: EmptyView()
        }
    }
    private func failureSurface(_ failure: V15Failure, id: String) -> some View { message(failure.message).accessibilityIdentifier(id) }
    private var retryControls: some View {
        HStack {
            Button("重新输入并创建") { model.resetForNewExport() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("v15.f4c.retry")
            Button("关闭") { model.dismiss() }.accessibilityIdentifier("v15.f4c.close")
        }
    }
    private func message(_ value: String) -> some View { Text(value).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color).fixedSize(horizontal: false, vertical: true).padding(V15Spacing.sm).background(V15Palette.provisional.color, in: RoundedRectangle(cornerRadius: V15Radius.tag)) }
    private var restoreCard: some View {
        V15Section("恢复前置条件") {
            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                Text("仅受控操作员可在 schema-compatible 的全新空目标执行：先 CLI 校验与 dry-run，再确认空目标恢复并读回核对。")
                    .font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
                Button("恢复 Archive") {}.disabled(true).accessibilityHint(model.restoreDisabledReason).accessibilityIdentifier("v15.f4c.restore-disabled")
                Text(model.restoreDisabledReason).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.68)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var confirmationPresented: Binding<Bool> {
        .init(get: { if case .confirming = model.phase { true } else { false } }, set: { presented in
            guard !presented, case .confirming = model.phase else { return }
            model.cancel()
        })
    }
    private var confirmationSheet: some View {
        VStack(alignment: .leading, spacing: V15Spacing.lg) {
            Text("确认创建加密归档").font(V15Typography.surfaceTitle)
            Text("归档固定排除 AI 原文、访问凭证和 Provider 配置。服务器创建与文件传输均不显示虚假的百分比进度。")
                .font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Button("取消") { model.cancel() }; Spacer(); Button("开始创建") { model.confirmExport() }.buttonStyle(.borderedProminent).accessibilityIdentifier("v15.f4c.confirm") }
        }
        .padding(V15Spacing.lg)
        .presentationDetents([.medium])
    }
}

private struct V15ArchiveFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [UTType("com.fiscal.archive") ?? .data] }
    let url: URL?
    init(url: URL?) { self.url = url }
    init(configuration: ReadConfiguration) throws { url = nil }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        return try FileWrapper(url: url, options: .immediate)
    }
}
#endif
