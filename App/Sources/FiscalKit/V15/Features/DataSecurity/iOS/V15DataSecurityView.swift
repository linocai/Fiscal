import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
public struct V15DataSecurityView: View {
    @State private var model: V15ArchiveModel
    @State private var facts: V15SystemFactsModel
    @State private var exporterPresented = false

    public init(services: V15Services, offlineSnapshotAt: Date? = nil) {
        _model = State(initialValue: .init(services: services, offlineSnapshotAt: offlineSnapshotAt))
        _facts = State(initialValue: .init(services: services, offlineSnapshotAt: offlineSnapshotAt))
    }

    init(services: V15Services, model: V15ArchiveModel) {
        _model = State(initialValue: model)
        _facts = State(initialValue: .init(services: services, offlineSnapshotAt: model.offlineSnapshotAt))
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.lg) {
                    heading
                    operationsCard
                    versionCard
                    securityFacts
                    exportCard
                    restoreCard
                    passphraseCard
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
        .task { await facts.load() }
        .onDisappear { model.dismiss(); facts.invalidate() }
        .accessibilityIdentifier("v15.f4c.security.ios")
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: V15Spacing.xs) {
            Text("系统运行事实与安全操作").font(V15Typography.surfaceTitle).foregroundStyle(V15Palette.ink.color)
            Text("状态均由当前服务返回；离线快照不会伪装成实时系统状态。")
                .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.68)).fixedSize(horizontal: false, vertical: true)
        }
    }
    @ViewBuilder private var operationsCard: some View {
        if case .loading = facts.phase { V15LoadingSkeleton().accessibilityIdentifier("v15.system.loading") }
        if case .offline(let at) = facts.phase {
            V15OfflineReadOnlyBanner(snapshotAt: at)
            message("离线快照不包含备份、恢复演练或磁盘的实时状态。")
        } else if let operations = facts.operationsStatus {
            V15Section("运行状态") {
                operationRow("备份", state: operations.backup.state, detail: operationDetail(age: operations.backup.ageHours, duration: operations.backup.durationSeconds, size: operations.backup.sizeBytes))
                operationRow("恢复演练", state: operations.restore.state, detail: operationDetail(age: operations.restore.ageHours, duration: operations.restore.durationSeconds, size: nil))
                operationRow("磁盘", state: operations.disk.state, detail: diskDetail(operations.disk))
            }
            .accessibilityIdentifier("v15.system.operations")
        } else if let failure = facts.operationsFailure {
            V15ServiceErrorState(message: failure.message, retry: { Task { await facts.load() } })
        }
    }
    @ViewBuilder private var versionCard: some View {
        if facts.systemStatus != nil || facts.operationsStatus != nil || facts.dataRevision != nil {
            V15Section("版本") {
                factRow("服务版本", facts.systemStatus?.version ?? facts.operationsStatus?.serviceVersion ?? "未提供")
                factRow("数据库结构", schemaLabel(facts.operationsStatus?.schemaState))
                factRow("数据修订号", facts.dataRevision.map { "r-\($0.revision)" } ?? "未提供")
                if let release = facts.operationsStatus?.releaseRevision { factRow("发行修订", release) }
            }
            .accessibilityIdentifier("v15.system.versions")
        } else if let failure = facts.systemFailure ?? facts.revisionFailure {
            V15ServiceErrorState(message: failure.message, retry: { Task { await facts.load() } })
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
                    V15ActionButton("创建加密归档", disabledReason: model.canBeginExport ? nil : .init(code: "archive_unavailable", message: model.exportDisabledReason ?? "请先完成当前归档流程。", fieldPath: nil), accessibilityIdentifier: "v15.f4c.export") { model.beginExport() }
                }
            }
        }
    }
    @ViewBuilder private var phaseSurface: some View {
        switch model.phase {
        case .creating: V15LoadingSkeleton(); Text("正在创建加密归档…").font(V15Typography.secondary).accessibilityIdentifier("v15.f4c.creating")
        case .ready: V15ActionButton("存入文件…", accessibilityIdentifier: "v15.f4c.handoff") { exporterPresented = true }
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
                V15ActionButton("重试存入文件", accessibilityIdentifier: "v15.f4c.save-retry") { exporterPresented = true }
                V15ActionButton("关闭", kind: .secondary, accessibilityIdentifier: "v15.f4c.close") { model.dismiss() }
            }
        default: EmptyView()
        }
    }
    private func failureSurface(_ failure: V15Failure, id: String) -> some View { message(failure.message).accessibilityIdentifier(id) }
    private var retryControls: some View {
        HStack { V15ActionButton("重新输入并创建", accessibilityIdentifier: "v15.f4c.retry") { model.resetForNewExport() }; V15ActionButton("关闭", kind: .secondary, accessibilityIdentifier: "v15.f4c.close") { model.dismiss() } }
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
    private var passphraseCard: some View {
        V15Section("修改个人口令") {
            VStack(alignment: .leading, spacing: V15Spacing.sm) {
                Text("修改后本机使用新凭证继续连接，其他设备上的访问密钥立即失效；账本数据不受影响。")
                    .font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
                SecureField("当前口令", text: $facts.oldPassphrase).textContentType(.password).disabled(facts.passphraseEntryDisabled).accessibilityIdentifier("v15.system.passphrase.old")
                SecureField("新口令（8–128 个字符）", text: $facts.newPassphrase).textContentType(.newPassword).disabled(facts.passphraseEntryDisabled).accessibilityIdentifier("v15.system.passphrase.new")
                SecureField("再次输入新口令", text: $facts.newPassphraseConfirmation).textContentType(.newPassword).disabled(facts.passphraseEntryDisabled).accessibilityIdentifier("v15.system.passphrase.confirmation")
                passphraseResult
                V15ActionButton("修改口令", disabledReason: facts.passphraseDisabledReason, accessibilityIdentifier: "v15.system.passphrase.change") { Task { await facts.changePassphrase() } }
                Text("界面不显示、不记录、不上报任何口令片段。忘记口令无法找回，也不能由服务端重置。")
                    .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    @ViewBuilder private var passphraseResult: some View {
        switch facts.passphrasePhase {
        case .idle: EmptyView()
        case .changing: V15LoadingSkeleton(); Text("正在轮换连接凭证…").font(V15Typography.secondary)
        case .succeeded(let generation):
            message("口令已修改 · 凭证代次 \(generation)。其他设备需要用新口令重新解锁。")
                .accessibilityIdentifier("v15.system.passphrase.success")
        case .failed(let failure):
            message(failure.message).accessibilityIdentifier("v15.system.passphrase.error")
        case .responseUnknown:
            message("修改结果未知。不要重复提交；请先关闭并尝试使用新口令重新解锁，失败后再尝试原口令。")
                .accessibilityIdentifier("v15.system.passphrase.unknown")
        case .requiresReunlock:
            V15ServerFactState(title: "口令已修改", detail: "服务器已轮换口令，但本机无法保存新凭证。输入已清空且不能再次提交；请使用新口令重新解锁。")
                .accessibilityIdentifier("v15.system.passphrase.reunlock")
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
            HStack { V15ActionButton("取消", kind: .secondary) { model.cancel() }; Spacer(); V15ActionButton("开始创建", accessibilityIdentifier: "v15.f4c.confirm") { model.confirmExport() } }
        }
        .padding(V15Spacing.lg)
        .presentationDetents([.medium])
    }

    private func operationRow(_ title: String, state: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title).font(V15Typography.body.weight(.semibold)); Spacer(); Text(operationLabel(state)).font(V15Typography.label) }
            Text(detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(V15Spacing.sm)
        .background(operationIsProvisional(state) ? V15Palette.provisional.color : V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
    }
    private func factRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(title).font(V15Typography.secondary); Spacer(); Text(value).font(V15Typography.body.monospaced()).multilineTextAlignment(.trailing) }
    }
    private func operationLabel(_ state: String) -> String {
        switch state { case "healthy", "verified", "current", "ok": "已校验"; case "stale": "陈旧"; case "warning": "需关注"; case "failed", "failure": "失败"; default: state }
    }
    private func operationIsProvisional(_ state: String) -> Bool { !["healthy", "verified", "current", "ok"].contains(state) }
    private func operationDetail(age: Int?, duration: Int?, size: Int?) -> String {
        [age.map { "\($0) 小时前" }, duration.map { "耗时 \($0) 秒" }, size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "服务未提供时间或大小"
    }
    private func diskDetail(_ disk: DiskOperationStatus) -> String {
        [disk.usedPercent.map { "已用 \($0)%" }, disk.warningPercent.map { "警告阈值 \($0)%" }, disk.failurePercent.map { "失败阈值 \($0)%" }].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "服务未提供容量比例"
    }
    private func schemaLabel(_ state: String?) -> String { switch state { case "current": "与发行版一致"; case "mismatch": "与发行版不一致"; case "unknown": "发行结构未知"; case .some(let value): value; case nil: "未提供" } }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

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
