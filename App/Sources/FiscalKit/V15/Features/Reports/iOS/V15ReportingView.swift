import SwiftUI

#if os(iOS)
public struct V15ReportingView: View {
    @State private var model: V15ReportingModel
    public init(services: V15Services, offlineSnapshotAt: Date? = nil) { _model = State(initialValue: .init(services: services, offlineSnapshotAt: offlineSnapshotAt)) }
    public var body: some View {
        NavigationStack { ScrollView { VStack(alignment: .leading, spacing: V15Spacing.section) {
            header; periodControls; lensControls
            if let at = model.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: at).accessibilityIdentifier("v15.f4a.offline") }
            surface
        }.padding(V15Spacing.md).frame(maxWidth: 720, alignment: .leading) }
            .background(V15Palette.paper.color).navigationTitle("报告")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Menu { Button("导出 CSV") { model.beginExport(.csv) }.disabled(model.exportDisabledReason != nil); Button("导出 PDF") { model.beginExport(.pdf) }.disabled(model.exportDisabledReason != nil) } label: { Label("导出", systemImage: "square.and.arrow.up") }.accessibilityIdentifier("v15.f4b.export") }; ToolbarItem(placement: .topBarTrailing) { Button { Task { await model.load() } } label: { Label("重新读取", systemImage: V15Symbol.retry) }.accessibilityIdentifier("v15.f4a.reload") } }
        }
        .sheet(isPresented: Binding(get: { model.drillCapability != nil && model.selectedDrillLabel != nil }, set: { if !$0 { model.dismissDrill() } })) { drillSheet.presentationDetents([.medium, .large]) }
        .sheet(isPresented: Binding(get: { if case .idle = model.exportPhase { false } else { true } }, set: { if !$0 { model.dismissExport() } })) { exportSheet }
        .task { await model.load() }
        .accessibilityIdentifier("v15.f4a.reports.ios")
    }
    @ViewBuilder private var exportSheet: some View { NavigationStack { VStack(alignment: .leading, spacing: V15Spacing.md) {
        Text("导出当前正式报告").font(V15Typography.surfaceTitle)
        if let owner = model.exportOwner { Text("期间 \(owner.period.rawValue) · 上海业务日 · CNY · 版本 \(owner.expectedRevision)").font(V15Typography.secondary) }
        switch model.exportPhase {
        case .confirming(let format): Text(format == .pdf ? "PDF 仅供阅读；不含凭证、完整账户标识、账单或 Provider 原文。" : "CSV 用于逐行复核；不含凭证、完整账户标识、账单或 Provider 原文。").font(V15Typography.body); HStack { Button("取消") { model.cancelExport() }; Spacer(); Button("开始导出") { Task { await model.exportConfirmed() } }.buttonStyle(.borderedProminent).accessibilityIdentifier("v15.f4b.export.confirm") }
        case .transferring: ProgressView("正在从服务器传输文件…").accessibilityIdentifier("v15.f4b.export.transfer"); Button("取消") { model.cancelExport() }
        case .ready(let artifact): Text("服务器文件已验证 · 版本 \(artifact.dataRevision)。请共享或存入文件；关闭会删除临时副本。").accessibilityIdentifier("v15.f4b.export.ready"); if let url = model.exportURL { ShareLink(item: url) { Label("共享或存入文件", systemImage: "square.and.arrow.up") }.accessibilityIdentifier("v15.f4b.export.handoff") }; Button("关闭并删除临时副本") { model.dismissExport() }.accessibilityIdentifier("v15.f4b.export.done")
        case .saving: ProgressView("正在存入文件…")
        case .saveFailed(_, let failure): Text(failure.message).accessibilityIdentifier("v15.f4b.export.error"); Button("关闭") { model.dismissExport() }
        case .completed(let artifact): Text("已存入此设备 · 版本 \(artifact.dataRevision)").accessibilityIdentifier("v15.f4b.export.success"); Button("完成") { model.dismissExport() }
        case .requiresReload(let failure): Text(failure.message); Text("文件结果未知，未保留本地副本。请取最新数据重新决定。").font(V15Typography.secondary); Button("取最新数据重新决定") { Task { await model.reloadFresh() } }.accessibilityIdentifier("v15.f4b.export.reload")
        case .failed(let failure): Text(failure.message).accessibilityIdentifier("v15.f4b.export.error"); Button("关闭") { model.dismissExport() }
        case .idle: EmptyView()
        }
    }.padding(V15Spacing.md) }.accessibilityIdentifier("v15.f4b.export.sheet") }
    private var header: some View { VStack(alignment: .leading, spacing: V15Spacing.xs) {
        Text("正式报告事实").font(V15Typography.surfaceTitle).foregroundStyle(V15Palette.ink.color)
        if let meta = model.report?.meta { Text("上海业务日 \(meta.dateFrom) 至 \(meta.dateTo) · CNY · 版本 \(meta.dataRevision)\n生成于 \(V15TodayReadModel.shanghaiDateLabel(meta.generatedAt))").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("v15.f4a.meta") }
        else { Text("仅显示服务器返回的正式事实；个人实际口径不在客户端重新计算。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }
    } }
    private var periodControls: some View { HStack(spacing: V15Spacing.xs) {
        Button { Task { await model.movePeriod(by: -1) } } label: { Image(systemName: "chevron.left") }.v15PlatformHitArea().accessibilityIdentifier("v15.f4a.period.previous")
        Button(model.periodLabel) { Task { await model.togglePeriodKind() } }.buttonStyle(.bordered).accessibilityIdentifier("v15.f4a.period.toggle")
        Button { Task { await model.movePeriod(by: 1) } } label: { Image(systemName: "chevron.right") }.v15PlatformHitArea().accessibilityIdentifier("v15.f4a.period.next")
        Spacer(); Text("月 / 年").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
    } }
    private var lensControls: some View { Picker("报告镜头", selection: Binding(get: { model.lens }, set: { model.selectLens($0) })) { ForEach(V15ReportingModel.Lens.allCases, id: \.self) { Text(lensLabel($0)).tag($0) } }.pickerStyle(.segmented).accessibilityIdentifier("v15.f4a.lens") }
    @ViewBuilder private var surface: some View { switch model.phase {
    case .idle, .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f4a.loading")
    case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.load() } }.accessibilityIdentifier("v15.f4a.error")
    case .requiresReload(let failure): V15Section("报告版本已变化") { Text(failure.message).font(V15Typography.body); Text("未修改任何事实。请取最新数据重新决定。").font(V15Typography.secondary); V15ActionButton("取最新数据重新决定", symbol: V15Symbol.conflict) { Task { await model.reloadFresh() } }.accessibilityIdentifier("v15.f4a.conflict.reload") }.accessibilityIdentifier("v15.f4a.conflict")
    case .empty: V15EmptyState(title: "该期间没有正式事实", explanation: "服务器在这个期间没有返回正式报告，不代表没有发生过变化。").accessibilityIdentifier("v15.f4a.empty")
    case .loaded: reportSurface
    } }
    private var reportSurface: some View { VStack(alignment: .leading, spacing: V15Spacing.md) { if let summary = model.report?.summary { V15Section("主口径 · 个人实际") { V15MoneyText(minorUnits: summary.personalRealizedMinor, direction: .balance, font: V15Typography.money).accessibilityIdentifier("v15.f4a.personal-realized"); Text("个人实际 · 服务器事实，非同比、预测或客户端汇总。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) } }
        lensRows
    } }
    @ViewBuilder private var lensRows: some View {
        if let report = model.report {
            switch model.lens {
            case .categories: V15Section("分类") { ForEach(Array(report.categories.enumerated()), id: \.offset) { indexed in aggregateRow(title: indexed.element.categoryName, detail: "\(indexed.element.transactionCount) 笔 · 服务端分类", amount: indexed.element.netConsumptionMinor, capability: indexed.element.drillCapability, id: "category.\(indexed.offset)") } }
            case .merchants: V15Section("商户") { ForEach(Array(report.merchants.enumerated()), id: \.offset) { indexed in aggregateRow(title: indexed.element.merchantName, detail: "\(indexed.element.transactionCount) 笔 · 服务端商户", amount: indexed.element.netConsumptionMinor, capability: indexed.element.drillCapability, id: "merchant.\(indexed.offset)") } }
            case .accounts: V15Section("账户") { ForEach(Array(report.accounts.enumerated()), id: \.offset) { indexed in aggregateRow(title: indexed.element.accountName, detail: "\(accountKindLabel(indexed.element.accountKind)) · 期末余额", amount: indexed.element.closingBalanceMinor, capability: indexed.element.drillCapability, id: "account.\(indexed.offset)") } }
            case .sources: V15Section("来源") { ForEach(Array(report.sources.enumerated()), id: \.offset) { indexed in aggregateRow(title: sourceLabel(indexed.element.source), detail: "\(indexed.element.transactionCount) 笔 · 服务端来源", amount: nil, capability: indexed.element.drillCapability, id: "source.\(indexed.offset)") } }
            case .completeness: V15Section("完整性") { aggregateRow(title: "导入与分类完整性", detail: completenessDetail(report.completeness), amount: nil, capability: .disabled("此汇总没有可安全定位的明细筛选条件"), id: "completeness") }
            }
        }
    }
    private func aggregateRow(title: String, detail: String, amount: Int64?, capability: V15ReportDrillCapability, id: String) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.xxs) {
            Button(action: {
                guard let owner = model.beginDrill(capability: capability, label: title) else { return }
                Task { @MainActor in await model.loadDrill(owner: owner) }
            }) {
                HStack(alignment: .top, spacing: V15Spacing.sm) {
                    VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                        Text(title).font(V15Typography.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: V15Spacing.sm)
                    if let amount { V15MoneyText(minorUnits: amount, direction: .balance, font: V15Typography.secondary).fixedSize() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled(capability))
            .v15PlatformHitArea()
            .accessibilityIdentifier("v15.f4a.row.\(id)")
            if case .disabled(let reason) = capability {
                Button(reason) { model.showDisabledReason(capability) }
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("v15.f4a.disabled.\(id)")
            }
            Divider()
        }
    }
    @ViewBuilder private var drillSheet: some View { NavigationStack { ScrollView { VStack(alignment: .leading, spacing: V15Spacing.md) { HStack { Text(model.selectedDrillLabel ?? "明细").font(V15Typography.surfaceTitle); Spacer(); Button("返回") { model.dismissDrill() }.accessibilityIdentifier("v15.f4a.drill.return") }
        Text("固定为报告版本 \(model.owner.revision.map(String.init) ?? "—")；只显示该汇总的安全筛选明细。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
        if model.drillItems.isEmpty {
            switch model.drillPhase {
            case .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f4a.drill.loading")
            case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.retryCurrentDrill() } }.accessibilityIdentifier("v15.f4a.drill.error")
            case .idle: V15EmptyState(title: "没有可显示的同版本明细", explanation: "服务器未返回此汇总的账目。 ").accessibilityIdentifier("v15.f4a.drill.empty")
            }
        }
        ForEach(model.drillItems) { item in V15LedgerRow(title: item.businessDate, detail: "\(item.kind.rawValue) · \(item.source.rawValue)", amountMinor: item.netConsumptionMinor, direction: .balance).accessibilityIdentifier("v15.f4a.drill.item.\(item.id)") }
        if model.hasNextPage { V15ActionButton("读取下一页", kind: .secondary, disabledReason: model.isPaging ? .init(code: "loading", message: "正在读取下一页。", fieldPath: nil) : nil) { Task { await model.loadNextPage() } }.accessibilityIdentifier("v15.f4a.drill.next") }
        if let failure = model.pageFailure, !model.drillItems.isEmpty { V15ServiceErrorState(message: failure.message) { Task { await model.retryNextPage() } }.accessibilityIdentifier("v15.f4a.drill.page-error") }
    }.padding(V15Spacing.md) } }.accessibilityIdentifier("v15.f4a.drill") }
    private func isEnabled(_ capability: V15ReportDrillCapability) -> Bool { if case .enabled = capability { true } else { false } }
    private func lensLabel(_ lens: V15ReportingModel.Lens) -> String { switch lens { case .categories: "分类"; case .merchants: "商户"; case .accounts: "账户"; case .sources: "来源"; case .completeness: "完整性" } }
    private func sourceLabel(_ source: V15ReportTransactionSource) -> String { source.isKnown ? source.rawValue : "服务器新增类型" }
    private func accountKindLabel(_ kind: V15ReportAccountKind) -> String { kind.isKnown ? kind.rawValue : "服务器新增类型" }
    private func completenessDetail(_ value: V15PeriodReport.Completeness) -> String { "未处理导入 \(value.unresolvedImportCount) · 失败导入 \(value.failedImportCount) · 未分类 \(value.uncategorizedTransactionCount) · 对账差异 \(value.openReconciliationDifferenceCount)" }
}
#endif
