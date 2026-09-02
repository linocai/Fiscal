import SwiftUI

#if os(macOS)
import AppKit

public struct V15DataSecurityMacView: View {
    @State private var model: V15ArchiveModel
    @State private var facts: V15SystemFactsModel
    @State private var archiveCredentialsTouched = false
    @State private var passphraseFieldsTouched = false
    private let saver: any V15ArchiveArtifactSaving

    public init(services: V15Services, offlineSnapshotAt: Date? = nil) {
        self.init(services: services, offlineSnapshotAt: offlineSnapshotAt, saver: V15SystemArchiveSaver())
    }

    init(services: V15Services, offlineSnapshotAt: Date? = nil, saver: any V15ArchiveArtifactSaving) {
        _model = State(initialValue: .init(services: services, offlineSnapshotAt: offlineSnapshotAt))
        _facts = State(initialValue: .init(services: services, offlineSnapshotAt: offlineSnapshotAt))
        self.saver = saver
    }

    init(services: V15Services, model: V15ArchiveModel, saver: any V15ArchiveArtifactSaving) {
        _model = State(initialValue: model)
        _facts = State(initialValue: .init(services: services, offlineSnapshotAt: model.offlineSnapshotAt))
        self.saver = saver
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: V15Spacing.xl) {
                heading
                if case .offline(let at) = facts.phase {
                    V15OfflineReadOnlyBanner(snapshotAt: at)
                    message("离线时无法取得备份、恢复检查或存储空间的最新状态。")
                }
                operations
                LazyVGrid(columns: [GridItem(.flexible(minimum: 360), spacing: V15Spacing.lg), GridItem(.flexible(minimum: 360), spacing: V15Spacing.lg)], alignment: .leading, spacing: V15Spacing.lg) {
                    archiveExport
                    restoreBoundary
                    passphrase
                }
            }
            .padding(V15MacLayout.contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .v15MacWorkspaceCanvas()
        .sheet(isPresented: confirmationPresented) { confirmation }
        .task { await facts.load() }
        .onChange(of: facts.passphrasePhase) { _, phase in
            if case .succeeded = phase { passphraseFieldsTouched = false }
            if case .requiresReunlock = phase { passphraseFieldsTouched = false }
        }
        .onDisappear { resetArchiveForm(); facts.invalidate() }
        .accessibilityIdentifier("v15.f4c.security.macos")
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: V15Spacing.xs) {
            Text("系统与数据").font(V15Typography.surfaceTitle)
            Text("查看运行状态、导出加密归档或修改个人口令。")
                .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
        }
    }

    @ViewBuilder private var operations: some View {
        if case .loading = facts.phase {
            V15LoadingSkeleton().accessibilityIdentifier("v15.system.loading")
        } else if let value = facts.operationsStatus {
            VStack(alignment: .leading, spacing: V15Spacing.sm) {
                Text("运行状态").font(V15Typography.cardTitle)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: V15Spacing.md)], spacing: V15Spacing.md) {
                    operationCard("备份", state: value.backup.state, detail: operationDetail(age: value.backup.ageHours, duration: value.backup.durationSeconds, size: value.backup.sizeBytes))
                    operationCard("恢复演练", state: value.restore.state, detail: operationDetail(age: value.restore.ageHours, duration: value.restore.durationSeconds, size: nil))
                    operationCard("磁盘", state: value.disk.state, detail: diskDetail(value.disk))
                }
            }
            .accessibilityIdentifier("v15.system.operations")
        } else if facts.offlineSnapshotAt == nil, let failure = facts.operationsFailure {
            V15ServiceErrorState(message: failure.message, retry: { Task { await facts.load() } })
        }
    }

    private var archiveExport: some View {
        V15Section("归档导出") {
            VStack(alignment: .leading, spacing: V15Spacing.sm) {
                Text("归档经过加密，不包含登录信息和 AI 原始内容。创建后请妥善保管文件和密码。")
                    .font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
                SecureField("归档密码（12–128 个字符）", text: archivePassword).accessibilityIdentifier("v15.f4c.password")
                SecureField("再次输入归档密码", text: archivePasswordConfirmation).accessibilityIdentifier("v15.f4c.password-confirmation")
                if archiveCredentialsTouched, let issue = model.passwordIssue { fieldIssue(issue) }
                phase
                V15ActionButton("创建加密归档", disabledReason: model.canBeginExport ? nil : .init(code: "archive_unavailable", message: model.exportDisabledReason ?? "请先完成当前归档流程。", fieldPath: nil), showsDisabledReasons: false, accessibilityIdentifier: "v15.f4c.export") { model.beginExport() }
            }
        }
    }

    private var restoreBoundary: some View {
        V15Section("恢复前置条件") {
            VStack(alignment: .leading, spacing: V15Spacing.sm) {
                Text("归档只能恢复到全新的空账本，不能覆盖当前账本。当前应用暂不提供恢复操作。")
                    .font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
                Label("恢复功能当前不可用", systemImage: "lock.fill")
                    .font(V15Typography.body.weight(.semibold))
                    .foregroundStyle(V15Palette.ink.color.opacity(0.72))
                    .accessibilityIdentifier("v15.f4c.restore-disabled")
                Text(model.restoreDisabledReason).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
            }
        }
    }

    private var passphrase: some View {
        V15Section("修改个人口令") {
            VStack(alignment: .leading, spacing: V15Spacing.sm) {
                Text("修改后，本机继续使用新口令；其他设备需要用新口令重新解锁。账本数据不受影响。")
                    .font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
                SecureField("当前口令", text: oldPassphrase).disabled(facts.passphraseEntryDisabled).accessibilityIdentifier("v15.system.passphrase.old")
                SecureField("新口令（8–128 个字符）", text: newPassphrase).disabled(facts.passphraseEntryDisabled).accessibilityIdentifier("v15.system.passphrase.new")
                SecureField("再次输入新口令", text: newPassphraseConfirmation).disabled(facts.passphraseEntryDisabled).accessibilityIdentifier("v15.system.passphrase.confirmation")
                if passphraseFieldsTouched, let issue = facts.passphraseDisabledReason, issue.fieldPath != nil { fieldIssue(issue.message) }
                passphraseResult
                V15ActionButton("修改口令", disabledReason: facts.passphraseDisabledReason, showsDisabledReasons: false, accessibilityIdentifier: "v15.system.passphrase.change") { Task { await facts.changePassphrase() } }
                Text("口令不会显示或记录。忘记口令后无法找回。")
                    .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
            }
        }
    }

    @ViewBuilder private var phase: some View {
        switch model.phase {
        case .creating:
            V15LoadingSkeleton(); Text("正在创建加密归档…").font(V15Typography.secondary).accessibilityIdentifier("v15.f4c.creating")
        case .ready:
            V15ActionButton("存入文件…", accessibilityIdentifier: "v15.f4c.handoff") { Task { await model.saveReadyArtifact(using: saver) } }
        case .completed:
            V15SuccessReceiptState(title: "归档已导出", detail: "已在此设备导出加密归档。")
                .accessibilityIdentifier("v15.f4c.success")
        case .failed(let failure):
            V15ErrorMessageState(title: "归档创建失败", message: failure.message)
                .accessibilityIdentifier("v15.f4c.error")
            retryControls
        case .unknown:
            message("文件结果未知，未保留本地副本。请重新创建归档。").accessibilityIdentifier("v15.f4c.unknown"); retryControls
        case .saveFailed(_, let failure):
            V15ErrorMessageState(title: "文件保存失败", message: failure.message)
            V15ActionButton("重试存入文件", accessibilityIdentifier: "v15.f4c.save-retry") { Task { await model.retrySave(using: saver) } }
            V15ActionButton("关闭", kind: .secondary, accessibilityIdentifier: "v15.f4c.close") { resetArchiveForm() }
        default: EmptyView()
        }
    }

    @ViewBuilder private var passphraseResult: some View {
        switch facts.passphrasePhase {
        case .idle: EmptyView()
        case .changing: V15LoadingSkeleton(); Text("正在修改口令…").font(V15Typography.secondary)
        case .succeeded:
            V15SuccessReceiptState(title: "口令已修改", detail: "其他设备需要使用新口令重新解锁。")
                .accessibilityIdentifier("v15.system.passphrase.success")
        case .failed(let failure):
            V15ErrorMessageState(title: "口令修改失败", message: failure.message)
                .accessibilityIdentifier("v15.system.passphrase.error")
        case .responseUnknown: message("修改结果未知。不要重复提交；请先尝试使用新口令重新解锁，失败后再尝试原口令。").accessibilityIdentifier("v15.system.passphrase.unknown")
        case .requiresReunlock:
            V15ServerFactState(title: "口令已修改", detail: "本机未能保存新的登录信息。输入已清空，请使用新口令重新解锁。")
                .accessibilityIdentifier("v15.system.passphrase.reunlock")
        }
    }

    private var retryControls: some View {
        HStack { V15ActionButton("重新输入并创建", accessibilityIdentifier: "v15.f4c.retry") { resetArchiveForm() }; V15ActionButton("关闭", kind: .secondary, accessibilityIdentifier: "v15.f4c.close") { resetArchiveForm() } }
    }
    private func message(_ value: String) -> some View {
        Text(value).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color).fixedSize(horizontal: false, vertical: true).padding(V15Spacing.sm).background(V15Palette.provisional.color, in: RoundedRectangle(cornerRadius: V15Radius.tag))
    }
    private func fieldIssue(_ value: String) -> some View {
        Label(value, systemImage: "exclamationmark.circle.fill")
            .font(V15Typography.secondary)
            .foregroundStyle(V15Palette.danger.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(V15Spacing.sm)
            .background(V15Palette.dangerSurface.color, in: RoundedRectangle(cornerRadius: V15Radius.tag))
    }
    private var confirmationPresented: Binding<Bool> {
        .init(get: { if case .confirming = model.phase { true } else { false } }, set: { presented in guard !presented, case .confirming = model.phase else { return }; resetArchiveForm() })
    }
    private var confirmation: some View {
        VStack(alignment: .leading, spacing: V15Spacing.lg) {
            Text("确认创建加密归档").font(V15Typography.surfaceTitle)
            Text("不包含 AI 原始内容或登录信息；不能恢复到当前账本。")
                .font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { V15ActionButton("取消", kind: .secondary) { resetArchiveForm() }; Spacer(); V15ActionButton("开始创建", accessibilityIdentifier: "v15.f4c.confirm") { model.confirmExport() } }
        }
        .padding(V15Spacing.lg).frame(width: 440)
    }

    private var archivePassword: Binding<String> {
        .init(get: { model.password }, set: { value in guard value != model.password else { return }; archiveCredentialsTouched = true; model.password = value })
    }

    private var archivePasswordConfirmation: Binding<String> {
        .init(get: { model.passwordConfirmation }, set: { value in guard value != model.passwordConfirmation else { return }; archiveCredentialsTouched = true; model.passwordConfirmation = value })
    }

    private var oldPassphrase: Binding<String> {
        .init(get: { facts.oldPassphrase }, set: { value in guard value != facts.oldPassphrase else { return }; passphraseFieldsTouched = true; facts.oldPassphrase = value })
    }

    private var newPassphrase: Binding<String> {
        .init(get: { facts.newPassphrase }, set: { value in guard value != facts.newPassphrase else { return }; passphraseFieldsTouched = true; facts.newPassphrase = value })
    }

    private var newPassphraseConfirmation: Binding<String> {
        .init(get: { facts.newPassphraseConfirmation }, set: { value in guard value != facts.newPassphraseConfirmation else { return }; passphraseFieldsTouched = true; facts.newPassphraseConfirmation = value })
    }

    private func resetArchiveForm() {
        model.dismiss()
        archiveCredentialsTouched = false
    }

    private func operationCard(_ title: String, state: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack { Text(title).font(V15Typography.body.weight(.semibold)); Spacer(); Text(operationLabel(state)).font(V15Typography.label) }
            Text(detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(V15Spacing.md).frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(operationIsProvisional(state) ? V15Palette.provisional.color : V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.decisionCard))
        .overlay { RoundedRectangle(cornerRadius: V15Radius.decisionCard).stroke(V15Palette.hairline.color) }
    }
    private func factRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(title).font(V15Typography.secondary); Spacer(); Text(value).font(V15Typography.body.monospaced()).multilineTextAlignment(.trailing) }
    }
    private func operationLabel(_ state: String) -> String { switch state { case "healthy", "verified", "current", "ok": "已校验"; case "stale": "陈旧"; case "warning": "需关注"; case "failed", "failure": "失败"; default: state } }
    private func operationIsProvisional(_ state: String) -> Bool { !["healthy", "verified", "current", "ok"].contains(state) }
    private func operationDetail(age: Int?, duration: Int?, size: Int?) -> String {
        let value = [age.map { "\($0) 小时前" }, duration.map { "耗时 \($0) 秒" }, size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }].compactMap { $0 }.joined(separator: " · ")
        return value.isEmpty ? "暂无时间或大小" : value
    }
    private func diskDetail(_ disk: DiskOperationStatus) -> String {
        let value = [disk.usedPercent.map { "已用 \($0)%" }, disk.warningPercent.map { "警告阈值 \($0)%" }, disk.failurePercent.map { "失败阈值 \($0)%" }].compactMap { $0 }.joined(separator: " · ")
        return value.isEmpty ? "暂无容量比例" : value
    }
}

@MainActor private struct V15SystemArchiveSaver: V15ArchiveArtifactSaving {
    func save(temporaryURL: URL, suggestedFilename: String) async throws -> V15ArchiveArtifactSaveResult {
        guard temporaryURL.lastPathComponent == suggestedFilename else { throw CocoaError(.fileNoSuchFile) }
        let panel = NSSavePanel(); panel.nameFieldStringValue = suggestedFilename; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return .cancelled }
        try V15ArchiveAtomicWriter.replace(temporaryURL: temporaryURL, destinationURL: destination)
        return .saved
    }
}

enum V15ArchiveAtomicWriter {
    static func replace(temporaryURL: URL, destinationURL: URL) throws {
        guard temporaryURL.isFileURL, destinationURL.isFileURL, FileManager.default.fileExists(atPath: temporaryURL.path) else { throw CocoaError(.fileNoSuchFile) }
        let manager = FileManager.default; let directory = destinationURL.deletingLastPathComponent()
        guard manager.fileExists(atPath: directory.path) else { throw CocoaError(.fileNoSuchFile) }
        let staged = directory.appendingPathComponent(".fiscal-archive-\(UUID().uuidString).partial")
        defer { try? manager.removeItem(at: staged) }
        try manager.copyItem(at: temporaryURL, to: staged)
        if manager.fileExists(atPath: destinationURL.path) { _ = try manager.replaceItemAt(destinationURL, withItemAt: staged, backupItemName: nil, options: []) }
        else { try manager.moveItem(at: staged, to: destinationURL) }
    }
}
#endif
