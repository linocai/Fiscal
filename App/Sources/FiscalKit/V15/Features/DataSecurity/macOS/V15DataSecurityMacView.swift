import SwiftUI

#if os(macOS)
import AppKit

public struct V15DataSecurityMacView: View {
    @State private var model: V15ArchiveModel
    private let saver: any V15ArchiveArtifactSaving
    public init(services: V15Services, offlineSnapshotAt: Date? = nil) { self.init(services: services, offlineSnapshotAt: offlineSnapshotAt, saver: V15SystemArchiveSaver()) }
    init(services: V15Services, offlineSnapshotAt: Date? = nil, saver: any V15ArchiveArtifactSaving) { _model = State(initialValue: .init(services: services, offlineSnapshotAt: offlineSnapshotAt)); self.saver = saver }
    init(model: V15ArchiveModel, saver: any V15ArchiveArtifactSaving) { _model = State(initialValue: model); self.saver = saver }
    public var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: V15Spacing.md) { Text("系统与数据").font(V15Typography.surfaceTitle); Text("加密 Archive v1").font(V15Typography.label); Spacer() }.padding(V15Spacing.lg).frame(minWidth: 210, idealWidth: 240)
            Divider()
            ScrollView { VStack(alignment: .leading, spacing: V15Spacing.lg) { Text("导出加密 Archive").font(V15Typography.surfaceTitle); Text("上海业务时区 · scrypt + AES-256-GCM · 不包含访问凭证、Provider 配置或 AI 原文。") .font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true); SecureField("归档密码（12–128 个字符）", text: $model.password).accessibilityIdentifier("v15.f4c.password"); SecureField("再次输入归档密码", text: $model.passwordConfirmation).accessibilityIdentifier("v15.f4c.password-confirmation"); if let issue = model.passwordIssue { message(issue) }; phase; HStack { Button("创建加密归档") { model.beginExport() }.disabled(!model.canBeginExport).accessibilityIdentifier("v15.f4c.export"); Spacer() }; Divider(); Text("恢复前置条件").font(V15Typography.cardTitle); Text("仅操作员可先执行 CLI dry-run，随后恢复到 schema-compatible 的全新空目标。此界面没有恢复入口。") .font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true); Button("恢复 Archive") {}.disabled(true).accessibilityHint(model.restoreDisabledReason).accessibilityIdentifier("v15.f4c.restore-disabled") }.padding(V15Spacing.xl) }.frame(minWidth: 460, maxWidth: .infinity)
        }
        .background(V15Palette.paper.color).sheet(isPresented: confirmationPresented) { confirmation }.onDisappear { model.dismiss() }.accessibilityIdentifier("v15.f4c.security.macos")
    }
    @ViewBuilder private var phase: some View { switch model.phase { case .creating: ProgressView("正在创建加密归档…").accessibilityIdentifier("v15.f4c.creating"); case .ready: Button("存入文件…") { Task { await model.saveReadyArtifact(using: saver) } }.buttonStyle(.borderedProminent).accessibilityIdentifier("v15.f4c.handoff"); case .completed: message("已在此设备导出加密归档。").accessibilityIdentifier("v15.f4c.success"); case .failed(let f): message(f.message).accessibilityIdentifier("v15.f4c.error"); retryControls; case .unknown: message("文件结果未知，未保留本地副本。请重新创建归档。").accessibilityIdentifier("v15.f4c.unknown"); retryControls; case .saveFailed(_, let f): message(f.message); Button("重试存入文件") { Task { await model.retrySave(using: saver) } }.accessibilityIdentifier("v15.f4c.save-retry"); Button("关闭") { model.dismiss() }.accessibilityIdentifier("v15.f4c.close"); default: EmptyView() } }
    private var retryControls: some View { HStack { Button("重新输入并创建") { model.resetForNewExport() }.buttonStyle(.borderedProminent).accessibilityIdentifier("v15.f4c.retry"); Button("关闭") { model.dismiss() }.accessibilityIdentifier("v15.f4c.close") } }
    private func message(_ value: String) -> some View { Text(value).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color).fixedSize(horizontal: false, vertical: true).padding(V15Spacing.sm).background(V15Palette.provisional.color, in: RoundedRectangle(cornerRadius: V15Radius.tag)) }
    private var confirmationPresented: Binding<Bool> { .init(get: { if case .confirming = model.phase { true } else { false } }, set: { presented in guard !presented, case .confirming = model.phase else { return }; model.cancel() }) }
    private var confirmation: some View { VStack(alignment: .leading, spacing: V15Spacing.lg) { Text("确认创建加密归档").font(V15Typography.surfaceTitle); Text("不包含 AI 原文、访问凭证或 Provider 配置；此操作不提供恢复到当前数据库。") .font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true); HStack { Button("取消") { model.cancel() }; Spacer(); Button("开始创建") { model.confirmExport() }.buttonStyle(.borderedProminent).accessibilityIdentifier("v15.f4c.confirm") } }.padding(V15Spacing.lg).frame(width: 440) }
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
        if manager.fileExists(atPath: destinationURL.path) { _ = try manager.replaceItemAt(destinationURL, withItemAt: staged, backupItemName: nil, options: []) } else { try manager.moveItem(at: staged, to: destinationURL) }
    }
}
#endif
