import SwiftUI

#if os(macOS)
import AppKit

public struct V15ReportingMacView: View {
    @State private var model: V15ReportingModel
    private let artifactSaver: any V15ReportArtifactSaving

    public init(services: V15Services, offlineSnapshotAt: Date? = nil, initialLens: V15ReportingModel.Lens = .overview) {
        self.init(services: services, offlineSnapshotAt: offlineSnapshotAt, initialLens: initialLens, artifactSaver: V15SystemReportArtifactSaver())
    }

    init(services: V15Services, offlineSnapshotAt: Date? = nil, initialLens: V15ReportingModel.Lens = .overview, artifactSaver: any V15ReportArtifactSaving) {
        let model = V15ReportingModel(services: services, offlineSnapshotAt: offlineSnapshotAt)
        model.selectLens(initialLens)
        _model = State(initialValue: model)
        self.artifactSaver = artifactSaver
    }

    public var body: some View {
        VStack(spacing: 0) {
            reportToolbar
            Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
            if model.selectedDrillLabel != nil, model.drillCapability != nil {
                drillTakeover
            } else {
                phaseSurface
            }
        }
        .background(V15Palette.paper.color)
        .tint(V15Palette.teal.color)
        .sheet(isPresented: exportPresented) {
            exportPanel.frame(width: 460).padding(24).background(V15Palette.paper.color)
        }
        .task { await model.load() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f4a.reports.macos")
    }

    private var exportPresented: Binding<Bool> {
        Binding(
            get: { if case .idle = model.exportPhase { false } else { true } },
            set: { if !$0 { model.dismissExport() } }
        )
    }

    private var reportToolbar: some View {
        HStack(spacing: 12) {
            Text("报表").font(V15Typography.cardTitle)
            HStack(spacing: 2) {
                ForEach(V15ReportingModel.Lens.allCases, id: \.self) { lens in
                    Button(lensLabel(lens)) { model.selectLens(lens) }
                        .buttonStyle(.plain)
                        .font(V15Typography.secondary.weight(.semibold))
                        .foregroundStyle(model.lens == lens ? V15Palette.primaryButtonText.color : V15Palette.ink.color.opacity(0.66))
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(model.lens == lens ? V15Palette.teal.color : Color.clear, in: RoundedRectangle(cornerRadius: V15Radius.control))
                        .accessibilityAddTraits(model.lens == lens ? .isSelected : [])
                        .accessibilityIdentifier("v15.f4a.lens.\(lens.rawValue)")
                }
            }
            .padding(3)
            .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
            Spacer(minLength: 16)
            Button { Task { await model.movePeriod(by: -1) } } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
                .accessibilityLabel("上一个期间")
                .accessibilityIdentifier("v15.f4a.period.previous")
            Button(model.periodLabel) { Task { await model.togglePeriodKind() } }
                .buttonStyle(.plain)
                .font(V15Typography.secondary.weight(.semibold))
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(V15Palette.paper.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
                .overlay { RoundedRectangle(cornerRadius: V15Radius.control).stroke(V15Palette.hairline.color) }
                .accessibilityHint("在月报表和年报表之间切换")
                .accessibilityIdentifier("v15.f4a.period.toggle")
            Button { Task { await model.movePeriod(by: 1) } } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
                .accessibilityLabel("下一个期间")
                .accessibilityIdentifier("v15.f4a.period.next")
            Menu {
                Button("导出 CSV") { model.beginExport(.csv) }
                    .disabled(model.exportDisabledReason != nil)
                    .accessibilityIdentifier("v15.f4b.export.csv")
                Button("导出 PDF") { model.beginExport(.pdf) }
                    .disabled(model.exportDisabledReason != nil)
                    .accessibilityIdentifier("v15.f4b.export.pdf")
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
                    .font(V15Typography.secondary.weight(.semibold))
            }
            .menuStyle(.borderlessButton)
            .accessibilityIdentifier("v15.f4b.export")
            Button { Task { await model.load() } } label: { Image(systemName: V15Symbol.retry) }
                .buttonStyle(.plain)
                .accessibilityLabel("重新读取报表")
                .accessibilityIdentifier("v15.f4a.reload")
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
        .background(V15Palette.card.color)
    }

    @ViewBuilder private var phaseSurface: some View {
        switch model.phase {
        case .idle, .loading:
            V15LoadingSkeleton().padding(28).accessibilityIdentifier("v15.f4a.loading")
        case .failed(let failure):
            V15ServiceErrorState(message: failure.message) { Task { await model.load() } }
                .padding(28)
                .accessibilityIdentifier("v15.f4a.error")
        case .requiresReload(let failure):
            reportCard("报表数据已更新") {
                Text(failure.message)
                Text("没有修改任何数据。请取最新数据后继续。")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                V15ActionButton("取最新数据重新决定", symbol: V15Symbol.conflict) { Task { await model.reloadFresh() } }
            }
            .padding(28)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("v15.f4a.conflict")
        case .empty:
            V15EmptyState(title: "这个期间没有报表数据", explanation: "可以选择其他期间继续查看。")
                .padding(28)
                .accessibilityIdentifier("v15.f4a.empty")
        case .loaded:
            if let report = model.report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        reportHeader(report.meta)
                        if let at = model.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: at) }
                        lensSurface(report)
                    }
                    .padding(24)
                    .frame(maxWidth: 1_180, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("v15.f4a.content.scroll")
            }
        }
    }

    private func reportHeader(_ meta: V15ReportMeta) -> some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("报表是看法，不是地点").font(V15Typography.surfaceTitle)
                Text("收支、资产、信用和分类使用同一期间。")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.66))
            }
            Spacer(minLength: 20)
                Text("上海业务日 \(meta.dateFrom) 至 \(meta.dateTo)\nCNY")
                .font(V15Typography.secondary)
                .foregroundStyle(V15Palette.ink.color.opacity(0.62))
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("v15.f4a.meta")
        }
    }

    @ViewBuilder private func lensSurface(_ report: V15PeriodReport) -> some View {
        switch model.lens {
        case .overview: overviewSurface(report)
        case .spending: spendingSurface(report)
        case .cashFlow: cashFlowSurface(report)
        case .debt: debtSurface(report)
        case .categories, .merchants, .accounts, .sources, .completeness: overviewSurface(report)
        }
    }

    private func overviewSurface(_ report: V15PeriodReport) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("期间总览").font(V15Typography.cardTitle)
            metricGrid([
                ("收入", report.summary.incomeMinor, .inflow),
                ("个人实际承担", report.summary.personalRealizedMinor, .outflow),
                ("净收支", report.summary.netIncomeExpenseMinor, .balance),
                ("期末信用欠款", report.summary.creditDebtAtPeriodEndMinor, .outflow)
            ])
            HStack(alignment: .top, spacing: 18) {
                reportCard("数据完整性") {
                    completenessRows(report.completeness)
                    Text("这些记录仍需处理，但已经计入总额。")
                        .font(V15Typography.secondary)
                        .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                }
                reportCard("期末账户余额") {
                    ForEach(Array(report.accounts.enumerated()), id: \.offset) { indexed in
                        aggregateRow(title: indexed.element.accountName, detail: "\(accountKindLabel(indexed.element.accountKind)) · 期末余额", amount: indexed.element.closingBalanceMinor, capability: indexed.element.drillCapability, id: "overview.account.\(indexed.offset)")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f4a.surface.overview")
    }

    private func spendingSurface(_ report: V15PeriodReport) -> some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 18) {
                reportCard("本期支出 · \(spendingLabel(model.spendingMeasure))") {
                    HStack(alignment: .firstTextBaseline) {
                        V15MoneyText(minorUnits: model.spendingAmount(in: report.summary), direction: .neutral, font: .system(size: 34, weight: .semibold, design: .monospaced))
                            .accessibilityIdentifier("v15.f4a.spending.hero")
                        Spacer(minLength: 12)
                        Menu("切换口径") {
                            ForEach(V15ReportingModel.SpendingMeasure.allCases, id: \.self) { measure in
                                Button(spendingLabel(measure)) { model.selectSpendingMeasure(measure) }
                            }
                        }
                        .menuStyle(.borderlessButton)
                    }
                    Text("这些数字是同一期间的不同统计方式，不能相加。")
                        .font(V15Typography.secondary)
                        .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                        .fixedSize(horizontal: false, vertical: true)
                    if model.spendingMeasure == .personalRealized,
                       report.summary.personalExpectedMinor != report.summary.personalRealizedMinor {
                        Text("个人预计承担 \(V15MoneyPresentation(minorUnits: report.summary.personalExpectedMinor, direction: .neutral).text) · 预计可报销 \(V15MoneyPresentation(minorUnits: report.summary.expectedReimbursementMinor, direction: .neutral).text) · 已收 \(V15MoneyPresentation(minorUnits: report.summary.receivedReimbursementMinor, direction: .neutral).text)")
                            .font(V15Typography.secondary)
                            .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    }
                }
                sevenMeasures(report.summary)
                categoryDistribution(report)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 18) {
                reportCard("期间为空时") {
                    Text("可以切换到其他期间继续查看。")
                        .font(V15Typography.secondary)
                        .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                }
            }
            .frame(width: 330, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f4a.surface.spending")
    }

    private func cashFlowSurface(_ report: V15PeriodReport) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("现金流 · 钱实际如何进出").font(V15Typography.cardTitle)
            metricGrid([
                ("流入", report.summary.cashInflowMinor, .inflow),
                ("流出", report.summary.cashOutflowMinor, .outflow),
                ("净现金流", report.summary.cashNetMinor, .balance)
            ])
            HStack(alignment: .top, spacing: 18) {
                reportCard("按账户") {
                    cashAccountHeader
                    ForEach(Array(report.accounts.enumerated()), id: \.offset) { indexed in
                        cashAccountRow(indexed.element, id: indexed.offset)
                    }
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 18) {
                    reportCard("内部转账单列") {
                        valueRow("内部转入", report.summary.internalTransferInflowMinor, .neutral)
                        valueRow("内部转出", report.summary.internalTransferOutflowMinor, .neutral)
                        Text("内部转账不是收入或支出，不计入上方流入/流出。")
                            .font(V15Typography.secondary)
                            .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    }
                }
                .frame(width: 350)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f4a.surface.cashFlow")
    }

    private func debtSurface(_ report: V15PeriodReport) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("债务 · 期末存量").font(V15Typography.cardTitle)
            metricGrid([
                ("当前信用欠款", report.summary.creditDebtAtPeriodEndMinor, .outflow),
                ("待收报销", report.summary.reimbursementOutstandingAtPeriodEndMinor, .balance)
            ])
            HStack(alignment: .top, spacing: 18) {
                reportCard("信用账户期末余额") {
                    let creditAccounts = report.accounts.filter { $0.accountKind == .credit }
                    if creditAccounts.isEmpty {
                        Text("本期报表没有信用账户行。")
                            .font(V15Typography.secondary)
                            .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    } else {
                        ForEach(Array(creditAccounts.enumerated()), id: \.offset) { indexed in
                            aggregateRow(title: indexed.element.accountName, detail: "信用账户 · 期末余额", amount: indexed.element.closingBalanceMinor, capability: indexed.element.drillCapability, id: "debt.account.\(indexed.offset)")
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f4a.surface.debt")
    }

    private func sevenMeasures(_ summary: V15PeriodReport.Summary) -> some View {
        reportCard("支出统计方式") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                ForEach(V15ReportingModel.SpendingMeasure.allCases, id: \.self) { measure in
                    Button { model.selectSpendingMeasure(measure) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(spendingLabel(measure)).font(V15Typography.secondary.weight(measure == model.spendingMeasure ? .bold : .regular))
                                if measure == model.spendingMeasure { Text("当前主口径").font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.58)) }
                            }
                            Spacer(minLength: 8)
                            V15MoneyText(minorUnits: model.spendingAmount(measure, in: summary), direction: .neutral, includeCurrency: false)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 46)
                        .background(measure == model.spendingMeasure ? V15Palette.selected.color : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay { Rectangle().stroke(V15Palette.hairline.color, lineWidth: 0.5) }
                    .accessibilityAddTraits(measure == model.spendingMeasure ? .isSelected : [])
                    .accessibilityIdentifier("v15.f4a.measure.\(measure.rawValue)")
                }
            }
        }
    }

    @ViewBuilder private func categoryDistribution(_ report: V15PeriodReport) -> some View {
        let available = report.categories.compactMap { category -> (V15PeriodReport.Category, Int64)? in
            model.categoryAmount(category, for: model.spendingMeasure).map { (category, $0) }
        }
        if available.count == report.categories.count {
                reportCard("按分类 · \(spendingLabel(model.spendingMeasure)) · 点按查看明细") {
                let maximum = max(available.map { max($0.1, 0) }.max() ?? 0, 1)
                ForEach(Array(available.enumerated()), id: \.offset) { indexed in
                    categoryRow(indexed.element.0, amount: indexed.element.1, maximum: maximum, id: indexed.offset)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                reportCard("分类明细 · 净消费") {
                    let maximum = max(report.categories.map { max($0.netConsumptionMinor, 0) }.max() ?? 0, 1)
                    ForEach(Array(report.categories.enumerated()), id: \.offset) { indexed in
                        categoryRow(indexed.element, amount: indexed.element.netConsumptionMinor, maximum: maximum, id: indexed.offset)
                    }
                }
            }
        }
    }

    private func categoryRow(_ category: V15PeriodReport.Category, amount: Int64, maximum: Int64, id: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                guard let owner = model.beginDrill(capability: category.drillCapability, label: category.categoryName) else { return }
                Task { await model.loadDrill(owner: owner) }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(category.categoryName).font(V15Typography.body.weight(.semibold))
                        Text("\(category.transactionCount) 笔").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.58))
                        Spacer(minLength: 12)
                        V15MoneyText(minorUnits: amount, direction: .neutral)
                    }
                    GeometryReader { proxy in
                        Capsule().fill(V15Palette.hairline.color).overlay(alignment: .leading) {
                            Capsule().fill(V15Palette.teal.color).frame(width: proxy.size.width * CGFloat(max(0, Double(amount) / Double(maximum))))
                        }
                    }
                    .frame(height: 6)
                }
                .padding(10)
                .background(category.categoryID == nil ? V15Palette.provisional.color : Color.clear)
                .overlay(alignment: .leading) { if category.categoryID == nil { Rectangle().fill(V15Palette.yellow.color).frame(width: 4) } }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled(category.drillCapability))
            .accessibilityIdentifier("v15.f4a.row.category.\(id)")
            if category.categoryID == nil {
                Text("未分类金额仍计入总额，暂时不能查看明细。")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.66))
            }
            Divider()
        }
    }

    private func metricGrid(_ values: [(String, Int64, V15MoneyDirection)]) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(values.enumerated()), id: \.offset) { indexed in
                VStack(alignment: .leading, spacing: 5) {
                    Text(indexed.element.0).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    V15MoneyText(minorUnits: indexed.element.1, direction: indexed.element.2, font: V15Typography.moneyLarge)
                }
                .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
                .padding(14)
                .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.card))
                .overlay { RoundedRectangle(cornerRadius: V15Radius.card).stroke(V15Palette.hairline.color) }
            }
        }
    }

    private func completenessRows(_ value: V15PeriodReport.Completeness) -> some View {
        VStack(spacing: 0) {
            countRow("未处理导入", value.unresolvedImportCount)
            countRow("失败导入", value.failedImportCount)
            countRow("未分类", value.uncategorizedTransactionCount)
            countRow("对账差异", value.openReconciliationDifferenceCount)
        }
    }

    private func countRow(_ title: String, _ count: Int) -> some View {
        HStack { Text(title); Spacer(); Text("\(count)").monospacedDigit().fontWeight(.semibold) }
            .font(V15Typography.secondary)
            .padding(.vertical, 7)
            .padding(.horizontal, 9)
            .background(count > 0 ? V15Palette.provisional.color : Color.clear)
    }

    private var cashAccountHeader: some View {
        HStack(spacing: 14) {
            Text("账户").frame(maxWidth: .infinity, alignment: .leading)
            Text("流入").frame(width: 105, alignment: .trailing)
            Text("流出").frame(width: 105, alignment: .trailing)
            Text("期末余额").frame(width: 205, alignment: .trailing)
        }
        .font(V15Typography.label)
        .foregroundStyle(V15Palette.ink.color.opacity(0.58))
        .padding(.bottom, 6)
    }

    private func cashAccountRow(_ account: V15PeriodReport.Account, id: Int) -> some View {
        VStack(spacing: 0) {
            Button {
                guard let owner = model.beginDrill(capability: account.drillCapability, label: account.accountName) else { return }
                Task { await model.loadDrill(owner: owner) }
            } label: {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.accountName).font(V15Typography.body.weight(.semibold))
                        Text("内转入 \(V15MoneyPresentation(minorUnits: account.internalTransferInflowMinor, direction: .neutral, includeCurrency: false).text) · 内转出 \(V15MoneyPresentation(minorUnits: account.internalTransferOutflowMinor, direction: .neutral, includeCurrency: false).text)")
                            .font(V15Typography.label)
                            .foregroundStyle(V15Palette.ink.color.opacity(0.58))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    V15MoneyText(minorUnits: account.periodInflowMinor, direction: .inflow, includeCurrency: false)
                        .frame(width: 105, alignment: .trailing)
                    V15MoneyText(minorUnits: account.periodOutflowMinor, direction: .outflow, includeCurrency: false)
                        .frame(width: 105, alignment: .trailing)
                    V15MoneyText(minorUnits: account.closingBalanceMinor, direction: .balance, includeCurrency: false)
                        .frame(width: 205, alignment: .trailing)
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled(account.drillCapability))
            .accessibilityIdentifier("v15.f4a.row.cash-account.\(id)")
            Divider()
        }
    }

    private func aggregateRow(title: String, detail: String, amount: Int64?, capability: V15ReportDrillCapability, id: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                guard let owner = model.beginDrill(capability: capability, label: title) else { return }
                Task { await model.loadDrill(owner: owner) }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(V15Typography.body.weight(.semibold))
                        Text(detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    }
                    Spacer(minLength: 10)
                    if let amount { V15MoneyText(minorUnits: amount, direction: .neutral) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled(capability))
            .v15PlatformHitArea()
            .accessibilityIdentifier("v15.f4a.row.\(id)")
            if case .disabled(let reason) = capability { Text(reason).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.62)) }
            Divider()
        }
    }

    private func valueRow(_ title: String, _ amount: Int64, _ direction: V15MoneyDirection) -> some View {
        HStack { Text(title); Spacer(); V15MoneyText(minorUnits: amount, direction: direction) }.padding(.vertical, 4)
    }

    private func reportCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(V15Typography.cardTitle)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.card))
        .overlay { RoundedRectangle(cornerRadius: V15Radius.card).stroke(V15Palette.hairline.color) }
    }

    private func unavailableCard(_ title: String, _ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: "minus.circle").font(V15Typography.body.weight(.semibold))
            Text("暂时没有这项数据 · \(reason)")
                .font(V15Typography.secondary)
                .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.card))
        .overlay { RoundedRectangle(cornerRadius: V15Radius.card).stroke(V15Palette.hairline.color, style: StrokeStyle(lineWidth: 1, dash: [5, 4])) }
    }

    private var drillTakeover: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button { model.dismissDrill() } label: { Label("返回报表", systemImage: "chevron.left") }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("v15.f4a.drill.return")
                Text("\(lensLabel(model.lens)) · \(model.periodLabel) ›").font(V15Typography.secondary.weight(.semibold)).foregroundStyle(V15Palette.ink.color.opacity(0.62))
                Text(model.selectedDrillLabel ?? "明细").font(V15Typography.cardTitle)
                Spacer()
                Text("与当前报表范围一致").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.62))
            }
            .padding(.horizontal, 22)
            .frame(height: 46)
            .background(V15Palette.card.color)
            Rectangle().fill(V15Palette.hairline.color).frame(height: 1)
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 14) {
                    drillTable
                }
                .padding(22)
                .frame(minWidth: 920, alignment: .topLeading)
            }
        }
        .accessibilityIdentifier("v15.f4a.drill")
    }

    @ViewBuilder private var drillTable: some View {
        if model.drillItems.isEmpty {
            switch model.drillPhase {
            case .loading: V15LoadingSkeleton().frame(width: 760).accessibilityIdentifier("v15.f4a.drill.loading")
            case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.retryCurrentDrill() } }.frame(width: 760).accessibilityIdentifier("v15.f4a.drill.error")
            case .idle: V15EmptyState(title: "没有明细", explanation: "当前筛选范围内没有记录。").frame(width: 760).accessibilityIdentifier("v15.f4a.drill.empty")
            }
        } else {
            VStack(spacing: 0) {
                drillHeaderRow
                ForEach(model.drillItems) { item in drillItemRow(item) }
            }
            .frame(width: 980)
            .overlay { RoundedRectangle(cornerRadius: V15Radius.card).stroke(V15Palette.hairline.color) }
            if model.hasNextPage {
                V15ActionButton("读取下一页", kind: .secondary, disabledReason: model.isPaging ? .init(code: "loading", message: "正在读取下一页。", fieldPath: nil) : nil) { Task { await model.loadNextPage() } }
                    .accessibilityIdentifier("v15.f4a.drill.next")
            }
            if let failure = model.pageFailure {
                V15ServiceErrorState(message: failure.message) { Task { await model.retryNextPage() } }
                    .frame(width: 760)
                    .accessibilityIdentifier("v15.f4a.drill.page-error")
            }
        }
    }

    private var drillHeaderRow: some View {
        HStack(spacing: 0) {
            tableHeader("日期", width: 90, alignment: .leading)
            tableHeader("摘要", width: 250, alignment: .leading)
            tableHeader("分类", width: 130, alignment: .leading)
            tableHeader("来源", width: 130, alignment: .leading)
            tableHeader("总消费", width: 120, alignment: .trailing)
            tableHeader("商户退款", width: 120, alignment: .trailing)
            tableHeader("净消费", width: 120, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(V15Palette.card.color)
    }

    private func tableHeader(_ title: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(title).font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.58)).frame(width: width, alignment: alignment)
    }

    private func drillItemRow(_ item: V15PeriodReportDrillDown.Item) -> some View {
        HStack(spacing: 0) {
            Text(item.businessDate).font(V15Typography.secondary.monospacedDigit()).foregroundStyle(V15Palette.ink.color.opacity(0.62)).frame(width: 90, alignment: .leading)
            Text(item.merchantName ?? kindLabel(item.kind)).font(V15Typography.body).frame(width: 250, alignment: .leading)
            Text(item.categoryName ?? "未分类").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).frame(width: 130, alignment: .leading)
            Text(sourceLabel(item.source)).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).frame(width: 130, alignment: .leading)
            V15MoneyText(minorUnits: item.grossConsumptionMinor, direction: .neutral, includeCurrency: false).frame(width: 120, alignment: .trailing)
            V15MoneyText(minorUnits: item.merchantRefundMinor, direction: .neutral, includeCurrency: false).frame(width: 120, alignment: .trailing)
            V15MoneyText(minorUnits: item.netConsumptionMinor, direction: .neutral, includeCurrency: false).frame(width: 120, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 42)
        .overlay(alignment: .bottom) { Rectangle().fill(V15Palette.hairline.color).frame(height: 1) }
        .accessibilityIdentifier("v15.f4a.drill.item.\(item.id)")
    }

    private var exportPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导出当前正式报表").font(V15Typography.cardTitle)
            if let owner = model.exportOwner {
            Text("\(owner.period.rawValue) · 上海业务日 · CNY")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.66))
            }
            switch model.exportPhase {
            case .confirming(let format):
                Text(format == .pdf ? "PDF 仅供阅读；不含口令、完整账户标识、账单或 AI 原始内容。" : "CSV 用于逐行复核；不含口令、完整账户标识、账单或 AI 原始内容。")
                HStack {
                    V15ActionButton("取消", kind: .secondary) { model.cancelExport() }
                    V15ActionButton("开始导出") { Task { await model.exportConfirmed() } }
                        .accessibilityIdentifier("v15.f4b.export.confirm")
                }
            case .transferring:
                V15LoadingSkeleton(); Text("正在准备文件…").font(V15Typography.secondary)
                V15ActionButton("取消", kind: .secondary) { model.cancelExport() }
            case .ready:
                VStack(alignment: .leading, spacing: 8) {
                    Text("文件已准备好，请选择保存位置。")
                    V15ActionButton("存入文件…") { Task { await model.saveReadyArtifact(using: artifactSaver) } }
                        .accessibilityIdentifier("v15.f4b.export.handoff")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("v15.f4b.export.ready")
            case .saving:
                V15LoadingSkeleton(); Text("正在存入文件…").font(V15Typography.secondary)
            case .saveFailed(_, let failure):
                V15ServiceErrorState(message: failure.message) { Task { await model.retrySave(using: artifactSaver) } }
                    .accessibilityIdentifier("v15.f4b.export.error")
                V15ActionButton("重试保存") { Task { await model.retrySave(using: artifactSaver) } }
                    .accessibilityIdentifier("v15.f4b.export.save.retry")
                V15ActionButton("关闭", kind: .secondary) { model.dismissExport() }
            case .completed:
                V15SuccessReceiptState(title: "报表已存入此设备", detail: "可以在文件中查看")
                    .accessibilityIdentifier("v15.f4b.export.success")
                V15ActionButton("完成") { model.dismissExport() }
            case .requiresReload(let failure):
                V15ConflictState(conflict: failure.conflict ?? .init(reloadPath: nil, latestRevision: nil, message: failure.message)) { Task { await model.reloadFresh() } }
            case .failed(let failure):
                V15ServiceErrorState(message: failure.message) { model.dismissExport() }
                    .accessibilityIdentifier("v15.f4b.export.error")
            case .idle:
                EmptyView()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f4b.export.inspector")
    }

    private func isEnabled(_ capability: V15ReportDrillCapability) -> Bool { if case .enabled = capability { true } else { false } }

    private func lensLabel(_ lens: V15ReportingModel.Lens) -> String {
        switch lens {
        case .overview: "总览"; case .spending: "支出"; case .cashFlow: "现金流"; case .debt: "债务"
        case .categories: "分类"; case .merchants: "商户"; case .accounts: "账户"; case .sources: "来源"; case .completeness: "完整性"
        }
    }

    private func spendingLabel(_ measure: V15ReportingModel.SpendingMeasure) -> String {
        switch measure {
        case .grossConsumption: "消费总额"; case .merchantRefund: "商户退款"; case .netConsumption: "净消费"
        case .expectedReimbursement: "预计可报销"; case .receivedReimbursement: "已收报销"
        case .personalExpected: "个人预计承担"; case .personalRealized: "个人实际承担"
        }
    }

    private func sourceLabel(_ source: V15ReportTransactionSource) -> String {
        switch source {
        case .manual: "手工录入"; case .system: "系统派生"; case .aiText: "AI 文本"; case .ocr: "OCR"
        case .legacyImport: "旧版导入"; case .cashFlow: "现金流"; case .statementImport: "账单导入"; case .unknown: "其他来源"
        }
    }

    private func kindLabel(_ kind: V15ReportTransactionKind) -> String {
        switch kind {
        case .income: "收入"; case .expense: "支出"; case .transfer: "转账"; case .creditPurchase: "信用消费"
        case .repayment: "还款"; case .installmentFee: "分期手续费"; case .installmentRefund: "分期退款"
        case .reimbursementReceipt: "报销收款"; case .unknown: "其他类型"
        }
    }

    private func accountKindLabel(_ kind: V15ReportAccountKind) -> String {
        switch kind { case .cash: "现金"; case .debit: "借记"; case .credit: "信用"; case .unknown: "其他类型" }
    }
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
