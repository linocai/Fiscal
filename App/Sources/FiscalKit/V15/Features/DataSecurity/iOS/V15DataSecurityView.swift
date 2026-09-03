import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

#if os(iOS)
public struct V15DataSecurityView: View {
    @State private var model: V15ArchiveModel
    @State private var facts: V15SystemFactsModel
    @State private var exporterPresented = false
    private let closeAction: (() -> Void)?

    public init(services: V15Services, offlineSnapshotAt: Date? = nil, onClose: (() -> Void)? = nil) {
        _model = State(initialValue: .init(services: services, offlineSnapshotAt: offlineSnapshotAt))
        _facts = State(initialValue: .init(services: services, offlineSnapshotAt: offlineSnapshotAt))
        closeAction = onClose
    }

    init(services: V15Services, model: V15ArchiveModel, onClose: (() -> Void)? = nil) {
        _model = State(initialValue: model)
        _facts = State(initialValue: .init(services: services, offlineSnapshotAt: model.offlineSnapshotAt))
        closeAction = onClose
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.lg) {
                    heading
                    operationsCard
                    securityFacts
                    exportCard
                    restoreCard
                    passphraseCard
                }
                .padding(V15Spacing.md)
                .frame(maxWidth: 680, alignment: .leading)
            }
            .v15IOSScreenCanvas()
            .navigationTitle("数据与安全")
            .toolbar {
                if let closeAction {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭", action: closeAction).accessibilityIdentifier("v15.settings.pane.close")
                    }
                }
            }
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
            Text("数据与安全").font(V15Typography.surfaceTitle).foregroundStyle(V15Palette.ink.color)
            Text("查看运行状态、导出加密归档或修改个人口令。")
                .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.68)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(V15Spacing.md)
        .v15IOSCard()
    }
    @ViewBuilder private var operationsCard: some View {
        if case .loading = facts.phase { V15LoadingSkeleton().accessibilityIdentifier("v15.system.loading") }
        if case .offline(let at) = facts.phase {
            V15OfflineReadOnlyBanner(snapshotAt: at)
            message("离线时无法取得备份、恢复检查或存储空间的最新状态。")
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
    private var securityFacts: some View {
        V15Section("归档范围") {
            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                Text("• 归档经过加密，必须使用密码打开")
                Text("• 不包含登录信息和 AI 原始内容")
                Text("• 创建后请妥善保管文件和密码")
            }.font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var exportCard: some View {
        V15Section("导出加密归档") {
            VStack(alignment: .leading, spacing: V15Spacing.sm) {
                secureInput("归档密码", prompt: "12–128 个字符", text: $model.password, contentType: .newPassword, identifier: "v15.f4c.password")
                secureInput("确认归档密码", prompt: "再次输入归档密码", text: $model.passwordConfirmation, contentType: .newPassword, identifier: "v15.f4c.password-confirmation")
                if let issue = model.passwordIssue {
                    V15FieldIssues(issues: [.init(code: "archive_password_invalid", message: issue, fieldPath: "password")])
                        .accessibilityIdentifier("v15.f4c.password-issue")
                }
                if model.isOffline { message(model.exportDisabledReason ?? "离线时不能创建备份文件。") }
                phaseSurface
                if model.phase == .idle {
                    V15ActionButton("创建加密归档", disabledReason: model.canBeginExport ? nil : .init(code: "archive_unavailable", message: model.exportDisabledReason ?? "请先完成当前归档流程。", fieldPath: nil), showsDisabledReasons: false, accessibilityIdentifier: "v15.f4c.export") { model.beginExport() }
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
    private func failureSurface(_ failure: V15Failure, id: String) -> some View { V15ErrorMessageState(message: failure.message).accessibilityIdentifier(id) }
    private var retryControls: some View {
        HStack { V15ActionButton("重新输入并创建", accessibilityIdentifier: "v15.f4c.retry") { model.resetForNewExport() }; V15ActionButton("关闭", kind: .secondary, accessibilityIdentifier: "v15.f4c.close") { model.dismiss() } }
    }
    private func message(_ value: String) -> some View { Text(value).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color).fixedSize(horizontal: false, vertical: true).padding(V15Spacing.sm).background(V15Palette.provisional.color, in: RoundedRectangle(cornerRadius: V15Radius.tag)) }
    private var restoreCard: some View {
        V15Section("恢复前置条件") {
            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                Text("归档只能恢复到全新的空账本，不能覆盖当前账本。当前应用暂不提供恢复操作。")
                    .font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
                Button("恢复归档") {}.disabled(true).accessibilityHint(model.restoreDisabledReason).accessibilityIdentifier("v15.f4c.restore-disabled")
                Text(model.restoreDisabledReason).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.68)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var passphraseCard: some View {
        V15Section("修改个人口令") {
            VStack(alignment: .leading, spacing: V15Spacing.sm) {
                Text("修改后，本机继续使用新口令；其他设备需要用新口令重新解锁。账本数据不受影响。")
                    .font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
                secureInput("当前口令", prompt: "输入当前口令", text: $facts.oldPassphrase, contentType: .password, identifier: "v15.system.passphrase.old")
                    .disabled(facts.passphraseEntryDisabled)
                secureInput("新口令", prompt: "8–128 个字符", text: $facts.newPassphrase, contentType: .newPassword, identifier: "v15.system.passphrase.new")
                    .disabled(facts.passphraseEntryDisabled)
                secureInput("确认新口令", prompt: "再次输入新口令", text: $facts.newPassphraseConfirmation, contentType: .newPassword, identifier: "v15.system.passphrase.confirmation")
                    .disabled(facts.passphraseEntryDisabled)
                passphraseResult
                V15ActionButton("修改口令", disabledReason: facts.passphraseDisabledReason, accessibilityIdentifier: "v15.system.passphrase.change") { Task { await facts.changePassphrase() } }
                Text("口令不会显示或记录。忘记口令后无法找回。")
                    .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    @ViewBuilder private var passphraseResult: some View {
        switch facts.passphrasePhase {
        case .idle: EmptyView()
        case .changing: V15LoadingSkeleton(); Text("正在修改口令…").font(V15Typography.secondary)
        case .succeeded:
            message("口令已修改。其他设备需要用新口令重新解锁。")
                .accessibilityIdentifier("v15.system.passphrase.success")
        case .failed(let failure):
            V15ErrorMessageState(message: failure.message).accessibilityIdentifier("v15.system.passphrase.error")
        case .responseUnknown:
            V15OutcomeUnknownState(message: "修改结果未知。不要重复提交；请先关闭并尝试使用新口令重新解锁，失败后再尝试原口令。")
                .accessibilityIdentifier("v15.system.passphrase.unknown")
        case .requiresReunlock:
            V15ServerFactState(title: "口令已修改", detail: "本机未能保存新的登录信息。输入已清空，请使用新口令重新解锁。")
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
            Text("归档不包含 AI 原始内容或登录信息。")
                .font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { V15ActionButton("取消", kind: .secondary) { model.cancel() }; Spacer(); V15ActionButton("开始创建", accessibilityIdentifier: "v15.f4c.confirm") { model.confirmExport() } }
        }
        .padding(V15Spacing.lg)
        .v15IOSScreenCanvas()
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
    private func secureInput(_ title: String, prompt: String, text: Binding<String>, contentType: UITextContentType, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.xs) {
            Text(title)
                .font(V15Typography.secondary.weight(.semibold))
                .foregroundStyle(V15Palette.ink.color)
            SecureField(prompt, text: text)
                .textContentType(contentType)
                .font(V15Typography.body)
                .textFieldStyle(.plain)
                .padding(V15Spacing.sm)
                .background(V15Palette.surfaceRaised.color, in: RoundedRectangle(cornerRadius: V15Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: V15Radius.control, style: .continuous)
                        .stroke(V15Palette.hairline.color, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
        }
    }
    private func factRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(title).font(V15Typography.secondary); Spacer(); Text(value).font(V15Typography.body.monospaced()).multilineTextAlignment(.trailing) }
    }
    private func operationLabel(_ state: String) -> String {
        switch state { case "healthy", "verified", "current", "ok": "已校验"; case "stale": "陈旧"; case "warning": "需关注"; case "failed", "failure": "失败"; default: state }
    }
    private func operationIsProvisional(_ state: String) -> Bool { !["healthy", "verified", "current", "ok"].contains(state) }
    private func operationDetail(age: Int?, duration: Int?, size: Int?) -> String {
        [age.map { "\($0) 小时前" }, duration.map { "耗时 \($0) 秒" }, size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "暂无时间或大小"
    }
    private func diskDetail(_ disk: DiskOperationStatus) -> String {
        [disk.usedPercent.map { "已用 \($0)%" }, disk.warningPercent.map { "提醒线 \($0)%" }, disk.failurePercent.map { "上限 \($0)%" }].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "暂无容量比例"
    }
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
