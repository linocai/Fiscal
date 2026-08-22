import SwiftUI

#if os(macOS)
import AppKit

public struct V15ReportingMacView: View {
    @State private var model: V15ReportingModel
    private let artifactSaver: any V15ReportArtifactSaving
    public init(services: V15Services, offlineSnapshotAt: Date? = nil) { self.init(services: services, offlineSnapshotAt: offlineSnapshotAt, artifactSaver: V15SystemReportArtifactSaver()) }
    init(services: V15Services, offlineSnapshotAt: Date? = nil, artifactSaver: any V15ReportArtifactSaving) { _model = State(initialValue: .init(services: services, offlineSnapshotAt: offlineSnapshotAt)); self.artifactSaver = artifactSaver }
    public var body: some View { HStack(spacing: 0) { sidebar.frame(minWidth: 190, idealWidth: 230); Divider(); spine.frame(minWidth: 420, idealWidth: 560); Divider(); inspector.frame(minWidth: 280, idealWidth: 360) }.background(V15Palette.paper.color).accessibilityElement(children: .contain).task { await model.load() }.accessibilityIdentifier("v15.f4a.reports.macos") }
    private var sidebar: some View { VStack(alignment: .leading, spacing: V15Spacing.md) { Text("报告").font(V15Typography.surfaceTitle); Text("返回脊柱 · 服务器正式事实").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)); HStack { Button { Task { await model.movePeriod(by: -1) } } label: { Image(systemName: "chevron.left") }.accessibilityIdentifier("v15.f4a.period.previous"); Button(model.periodLabel) { Task { await model.togglePeriodKind() } }.buttonStyle(.bordered).accessibilityIdentifier("v15.f4a.period.toggle"); Button { Task { await model.movePeriod(by: 1) } } label: { Image(systemName: "chevron.right") }.accessibilityIdentifier("v15.f4a.period.next") }
        Text("导出当前报告").font(V15Typography.secondary)
        Button("导出 CSV") { model.beginExport(.csv) }.disabled(model.exportDisabledReason != nil).accessibilityIdentifier("v15.f4b.export.csv")
        Button("导出 PDF") { model.beginExport(.pdf) }.disabled(model.exportDisabledReason != nil).accessibilityIdentifier("v15.f4b.export.pdf")
        Divider(); ForEach(V15ReportingModel.Lens.allCases, id: \.self) { lens in Button(lensLabel(lens)) { model.selectLens(lens) }.buttonStyle(.plain).padding(V15Spacing.sm).frame(maxWidth: .infinity, alignment: .leading).background(model.lens == lens ? V15Palette.selected.color : .clear, in: RoundedRectangle(cornerRadius: V15Radius.control)).accessibilityIdentifier("v15.f4a.lens.\(lens.rawValue)") }; Spacer(); if let at = model.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: at).accessibilityIdentifier("v15.f4a.offline") } }.padding(V15Spacing.md).accessibilityElement(children: .contain).accessibilityIdentifier("v15.f4a.mac.sidebar") }
    @ViewBuilder private var spine: some View { ScrollView { VStack(alignment: .leading, spacing: V15Spacing.md) { HStack { VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text("报告脊柱").font(V15Typography.cardTitle); Text(model.report.map { "上海业务日 \($0.meta.dateFrom) 至 \($0.meta.dateTo) · 版本 \($0.meta.dataRevision)" } ?? "正在读取服务器报告").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true) }; Spacer(); Button { Task { await model.load() } } label: { Image(systemName: V15Symbol.retry) }.accessibilityIdentifier("v15.f4a.reload") }
        switch model.phase { case .idle, .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f4a.loading"); case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.load() } }.accessibilityIdentifier("v15.f4a.error"); case .requiresReload(let failure): V15Section("报告版本已变化") { Text(failure.message); V15ActionButton("取最新数据重新决定") { Task { await model.reloadFresh() } }.accessibilityIdentifier("v15.f4a.conflict.reload") }.accessibilityIdentifier("v15.f4a.conflict"); case .empty: V15EmptyState(title: "该期间没有正式事实", explanation: "服务器没有返回正式报告。 ").accessibilityIdentifier("v15.f4a.empty"); case .loaded: rows }
    }.padding(V15Spacing.md) }.accessibilityElement(children: .contain).accessibilityIdentifier("v15.f4a.mac.spine") }
    @ViewBuilder private var rows: some View { if let report = model.report { VStack(alignment: .leading, spacing: V15Spacing.md) { V15Section("主口径 · 个人实际") { V15MoneyText(minorUnits: report.summary.personalRealizedMinor, direction: .balance, font: V15Typography.money).accessibilityIdentifier("v15.f4a.personal-realized") }; lensRows(report) } } }
    @ViewBuilder private func lensRows(_ report: V15PeriodReport) -> some View {
        switch model.lens {
        case .overview:
            V15Section("总览") {
                factRow("收入", report.summary.incomeMinor, .inflow)
                factRow("个人实际支出", report.summary.personalRealizedMinor, .outflow)
                factRow("净收支", report.summary.netIncomeExpenseMinor, .balance)
                Text(completenessDetail(report.completeness)).font(V15Typography.secondary)
            }
        case .spending:
            V15Section("七种支出口径") {
                Picker("当前口径", selection: Binding(get: { model.spendingMeasure }, set: { model.selectSpendingMeasure($0) })) {
                    ForEach(V15ReportingModel.SpendingMeasure.allCases, id: \.self) { Text(spendingLabel($0)).tag($0) }
                }.pickerStyle(.menu)
                factRow(spendingLabel(model.spendingMeasure), model.spendingAmount(in: report.summary), spendingDirection(model.spendingMeasure))
                Text("下方分类明细固定展示净消费；切换口径不会伪造分类拆分。").font(V15Typography.secondary)
                ForEach(Array(report.categories.enumerated()), id: \.offset) { indexed in rowButton(indexed.element.categoryName, "\(indexed.element.transactionCount) 笔 · 净消费", indexed.element.netConsumptionMinor, indexed.element.drillCapability, "category.\(indexed.offset)") }
            }
        case .cashFlow:
            V15Section("现金流") {
                factRow("流入", report.summary.cashInflowMinor, .inflow)
                factRow("流出", report.summary.cashOutflowMinor, .outflow)
                factRow("净现金流", report.summary.cashNetMinor, .balance)
                factRow("内部转入", report.summary.internalTransferInflowMinor, .neutral)
                factRow("内部转出", report.summary.internalTransferOutflowMinor, .neutral)
                ForEach(Array(report.accounts.enumerated()), id: \.offset) { indexed in rowButton(indexed.element.accountName, "期末余额", indexed.element.closingBalanceMinor, indexed.element.drillCapability, "account.\(indexed.offset)") }
            }
        case .debt:
            V15Section("债务") {
                factRow("信用欠款", report.summary.creditDebtAtPeriodEndMinor, .outflow)
                factRow("未收报销", report.summary.reimbursementOutstandingAtPeriodEndMinor, .balance)
                Text("均为期末服务器事实；不把未来计划计入已发生支出。").font(V15Typography.secondary)
            }
        case .categories: V15Section("分类") { ForEach(Array(report.categories.enumerated()), id: \.offset) { indexed in rowButton(indexed.element.categoryName, "分类", indexed.element.netConsumptionMinor, indexed.element.drillCapability, "category.\(indexed.offset)") } }
        case .merchants: V15Section("商户") { ForEach(Array(report.merchants.enumerated()), id: \.offset) { indexed in rowButton(indexed.element.merchantName, "商户", indexed.element.netConsumptionMinor, indexed.element.drillCapability, "merchant.\(indexed.offset)") } }
        case .accounts: V15Section("账户") { ForEach(Array(report.accounts.enumerated()), id: \.offset) { indexed in rowButton(indexed.element.accountName, indexed.element.accountKind.isKnown ? indexed.element.accountKind.rawValue : "服务器新增类型", indexed.element.closingBalanceMinor, indexed.element.drillCapability, "account.\(indexed.offset)") } }
        case .sources: V15Section("来源") { ForEach(Array(report.sources.enumerated()), id: \.offset) { indexed in rowButton(indexed.element.source.isKnown ? indexed.element.source.rawValue : "服务器新增类型", "来源", nil, indexed.element.drillCapability, "source.\(indexed.offset)") } }
        case .completeness: V15Section("完整性") { Text(completenessDetail(report.completeness)).font(V15Typography.secondary) }
        }
    }
    private func factRow(_ title: String, _ amount: Int64, _ direction: V15MoneyDirection) -> some View { HStack { Text(title); Spacer(); V15MoneyText(minorUnits: amount, direction: direction, font: V15Typography.secondary) }.padding(.vertical, V15Spacing.xxs) }
    private func rowButton(_ title: String, _ detail: String, _ amount: Int64?, _ capability: V15ReportDrillCapability, _ id: String) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.xxs) {
            Button(action: {
                guard let owner = model.beginDrill(capability: capability, label: title) else { return }
                Task { await model.loadDrill(owner: owner) }
            }) {
                HStack(alignment: .top, spacing: V15Spacing.sm) {
                    VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                        Text(title).fixedSize(horizontal: false, vertical: true)
                        Text(detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    }
                    Spacer(minLength: V15Spacing.sm)
                    if let amount { V15MoneyText(minorUnits: amount, direction: .balance, font: V15Typography.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled(capability))
            .v15PlatformHitArea()
            .accessibilityIdentifier("v15.f4a.row.\(id)")
            if case .disabled(let reason) = capability {
                Button(reason) { model.showDisabledReason(capability) }
                    .buttonStyle(.plain)
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    .accessibilityIdentifier("v15.f4a.disabled.\(id)")
            }
            Divider()
        }
    }
    @ViewBuilder private var inspector: some View { ScrollView { VStack(alignment: .leading, spacing: V15Spacing.md) { if case .idle = model.exportPhase { EmptyView() } else { exportPanel; Divider() }; HStack { Text("明细上下文").font(V15Typography.cardTitle); Spacer(); Button("返回") { model.dismissDrill() }.buttonStyle(.borderless).accessibilityIdentifier("v15.f4a.drill.return") }
        if let selectedLabel = model.selectedDrillLabel { Text(selectedLabel).font(V15Typography.body.weight(.semibold)).accessibilityIdentifier("v15.f4a.drill.context"); Text("同一报告版本 \(model.owner.revision.map(String.init) ?? "—")；不会用空筛选回退全期间账目。 ").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)); if model.drillItems.isEmpty { switch model.drillPhase { case .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f4a.drill.loading"); case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.retryCurrentDrill() } }.accessibilityIdentifier("v15.f4a.drill.error"); case .idle: V15EmptyState(title: "没有可显示的同版本明细", explanation: "服务器未返回此汇总的账目。 ").accessibilityIdentifier("v15.f4a.drill.empty") } }; ForEach(model.drillItems) { item in V15LedgerRow(title: item.businessDate, detail: "\(item.kind.rawValue) · \(item.source.rawValue)", amountMinor: item.netConsumptionMinor, direction: .balance).accessibilityIdentifier("v15.f4a.drill.item.\(item.id)") }; if model.hasNextPage { V15ActionButton("读取下一页", kind: .secondary, disabledReason: model.isPaging ? .init(code: "loading", message: "正在读取下一页。", fieldPath: nil) : nil) { Task { await model.loadNextPage() } }.accessibilityIdentifier("v15.f4a.drill.next") }; if let failure = model.pageFailure { V15ServiceErrorState(message: failure.message) { Task { await model.retryNextPage() } }.accessibilityIdentifier("v15.f4a.drill.page-error") } } else { V15EmptyState(title: "选择可定位汇总", explanation: "右侧只读取同版本且带稳定筛选条件的明细。") }
    }.padding(V15Spacing.md) }.accessibilityElement(children: .contain).accessibilityIdentifier("v15.f4a.mac.inspector") }
    private func enabled(_ capability: V15ReportDrillCapability) -> Bool { if case .enabled = capability { true } else { false } }
    @ViewBuilder private var exportPanel: some View { VStack(alignment: .leading, spacing: V15Spacing.md) { Text("导出当前正式报告").font(V15Typography.cardTitle); if let owner = model.exportOwner { Text("\(owner.period.rawValue) · 上海业务日 · CNY · 版本 \(owner.expectedRevision)").font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true) }; switch model.exportPhase { case .confirming(let format): Text(format == .pdf ? "PDF 仅供阅读；不含凭证、完整账户标识、账单或 Provider 原文。" : "CSV 用于逐行复核；不含凭证、完整账户标识、账单或 Provider 原文。").fixedSize(horizontal: false, vertical: true); HStack { Button("取消") { model.cancelExport() }.accessibilityIdentifier("v15.f4b.export.cancel"); Spacer(); Button("开始导出") { Task { await model.exportConfirmed() } }.buttonStyle(.borderedProminent).accessibilityIdentifier("v15.f4b.export.confirm") }; case .transferring: ProgressView("正在从服务器传输文件…").accessibilityIdentifier("v15.f4b.export.transfer"); Button("取消") { model.cancelExport() }.accessibilityIdentifier("v15.f4b.export.cancel"); case .ready(let artifact): Text("服务器文件已验证 · 版本 \(artifact.dataRevision)；请选择本地保存位置。").accessibilityIdentifier("v15.f4b.export.ready"); Button("存入文件…") { Task { await model.saveReadyArtifact(using: artifactSaver) } }.accessibilityIdentifier("v15.f4b.export.handoff"); case .saving: ProgressView("正在存入文件…").accessibilityIdentifier("v15.f4b.export.saving"); case .saveFailed(_, let failure): Text(failure.message).accessibilityIdentifier("v15.f4b.export.error"); Button("重试存入文件") { Task { await model.retrySave(using: artifactSaver) } }.accessibilityIdentifier("v15.f4b.export.save.retry"); Button("关闭") { model.dismissExport() }.accessibilityIdentifier("v15.f4b.export.done"); case .completed(let artifact): Text("已存入此设备 · 版本 \(artifact.dataRevision)").accessibilityIdentifier("v15.f4b.export.success"); Button("完成") { model.dismissExport() }.accessibilityIdentifier("v15.f4b.export.done"); case .requiresReload(let failure): Text(failure.message); Text("文件结果未知，未保留本地副本。请取最新数据重新决定。").font(V15Typography.secondary); Button("取最新数据重新决定") { Task { await model.reloadFresh() } }.accessibilityIdentifier("v15.f4b.export.reload"); case .failed(let failure): Text(failure.message).accessibilityIdentifier("v15.f4b.export.error"); Button("关闭") { model.dismissExport() }.accessibilityIdentifier("v15.f4b.export.done"); case .idle: EmptyView() } }.accessibilityElement(children: .contain).accessibilityIdentifier("v15.f4b.export.inspector") }
    private func lensLabel(_ lens: V15ReportingModel.Lens) -> String { switch lens { case .overview: "总览"; case .spending: "支出"; case .cashFlow: "现金流"; case .debt: "债务"; case .categories: "分类"; case .merchants: "商户"; case .accounts: "账户"; case .sources: "来源"; case .completeness: "完整性" } }
    private func spendingLabel(_ measure: V15ReportingModel.SpendingMeasure) -> String { switch measure { case .grossConsumption: "消费总额"; case .merchantRefund: "商户退款"; case .netConsumption: "净消费"; case .expectedReimbursement: "预计可报销"; case .receivedReimbursement: "已收报销"; case .personalExpected: "个人预计承担"; case .personalRealized: "个人实际承担" } }
    private func spendingDirection(_ measure: V15ReportingModel.SpendingMeasure) -> V15MoneyDirection { measure == .receivedReimbursement || measure == .merchantRefund ? .inflow : .outflow }
    private func completenessDetail(_ value: V15PeriodReport.Completeness) -> String { "未处理导入 \(value.unresolvedImportCount) · 失败导入 \(value.failedImportCount) · 未分类 \(value.uncategorizedTransactionCount) · 对账差异 \(value.openReconciliationDifferenceCount)" }
}

@MainActor private struct V15SystemReportArtifactSaver: V15ReportArtifactSaving {
    func save(temporaryURL: URL, suggestedFilename: String) async throws -> V15ReportArtifactSaveResult {
        guard temporaryURL.lastPathComponent == suggestedFilename else { throw CocoaError(.fileNoSuchFile) }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return .cancelled }
        guard let destination = panel.url else { return .cancelled }
        try V15ReportArtifactAtomicWriter.replace(temporaryURL: temporaryURL, destinationURL: destination)
        return .saved
    }
}

/// A validated temporary artifact is copied beside the chosen destination and
/// then atomically replaces an existing file.  The model retains the source
/// until this handoff reports success, so a local failure remains retryable
/// without another export request.
enum V15ReportArtifactAtomicWriter {
    static func replace(temporaryURL: URL, destinationURL: URL) throws {
        guard temporaryURL.isFileURL, destinationURL.isFileURL,
              FileManager.default.fileExists(atPath: temporaryURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let manager = FileManager.default
        let directory = destinationURL.deletingLastPathComponent()
        guard manager.fileExists(atPath: directory.path) else { throw CocoaError(.fileNoSuchFile) }
        let staged = directory.appendingPathComponent(".fiscal-export-\(UUID().uuidString).partial", isDirectory: false)
        defer { try? manager.removeItem(at: staged) }
        try manager.copyItem(at: temporaryURL, to: staged)
        if manager.fileExists(atPath: destinationURL.path) {
            _ = try manager.replaceItemAt(destinationURL, withItemAt: staged, backupItemName: nil, options: [])
        } else {
            try manager.moveItem(at: staged, to: destinationURL)
        }
    }
}
#endif
