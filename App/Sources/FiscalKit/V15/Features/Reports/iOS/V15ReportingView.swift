import SwiftUI

#if os(iOS)
public struct V15ReportingView: View {
    @State private var model: V15ReportingModel

    public init(services: V15Services, offlineSnapshotAt: Date? = nil, initialLens: V15ReportingModel.Lens = .overview) {
        let model = V15ReportingModel(services: services, offlineSnapshotAt: offlineSnapshotAt)
        model.selectLens(initialLens)
        _model = State(initialValue: model)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.lg) {
                    reportHeader
                    periodControls
                    lensControls
                    if let at = model.offlineSnapshotAt {
                        V15OfflineReadOnlyBanner(snapshotAt: at)
                            .accessibilityIdentifier("v15.f4a.offline")
                    }
                    phaseSurface
                }
                .padding(V15Spacing.md)
                .frame(maxWidth: 760, alignment: .leading)
            }
            .background(V15Palette.paper.color)
            .navigationTitle("报表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button("导出 CSV") { model.beginExport(.csv) }
                            .disabled(model.exportDisabledReason != nil)
                            .accessibilityIdentifier("v15.f4b.export.csv")
                        Button("导出 PDF") { model.beginExport(.pdf) }
                            .disabled(model.exportDisabledReason != nil)
                            .accessibilityIdentifier("v15.f4b.export.pdf")
                    } label: {
                        Label("导出", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("v15.f4b.export")
                    Button { Task { await model.load() } } label: {
                        Label("重新读取", systemImage: V15Symbol.retry)
                    }
                    .accessibilityIdentifier("v15.f4a.reload")
                }
            }
        }
        .tint(V15Palette.teal.color)
        .fullScreenCover(isPresented: drillPresented) { drillTakeover }
        .sheet(isPresented: exportPresented) { exportSheet.presentationDetents([.medium, .large]) }
        .task { await model.load() }
        .accessibilityIdentifier("v15.f4a.reports.ios")
    }

    private var drillPresented: Binding<Bool> {
        Binding(
            get: { model.drillCapability != nil && model.selectedDrillLabel != nil },
            set: { if !$0 { model.dismissDrill() } }
        )
    }

    private var exportPresented: Binding<Bool> {
        Binding(
            get: { if case .idle = model.exportPhase { false } else { true } },
            set: { if !$0 { model.dismissExport() } }
        )
    }

    private var reportHeader: some View {
        VStack(alignment: .leading, spacing: V15Spacing.xs) {
            Text("报表是看法，不是地点")
                .font(V15Typography.surfaceTitle)
            if let meta = model.report?.meta {
                Text("上海业务日 \(meta.dateFrom) 至 \(meta.dateTo) · CNY\n更新于 \(V15TodayReadModel.shanghaiDateLabel(meta.generatedAt))")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("v15.f4a.meta")
            } else {
                Text("收支、资产、信用和分类使用同一期间。")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var periodControls: some View {
        HStack(spacing: V15Spacing.xs) {
            Button { Task { await model.movePeriod(by: -1) } } label: { Image(systemName: "chevron.left") }
                .v15PlatformHitArea()
                .accessibilityLabel("上一个期间")
                .accessibilityIdentifier("v15.f4a.period.previous")
            Button(model.periodLabel) { Task { await model.togglePeriodKind() } }
                .buttonStyle(.plain)
                .font(V15Typography.body.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: V15Accessibility.minimumTouchTarget)
                .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
                .overlay { RoundedRectangle(cornerRadius: V15Radius.control).stroke(V15Palette.hairline.color) }
                .accessibilityHint("在月报表和年报表之间切换")
                .accessibilityIdentifier("v15.f4a.period.toggle")
            Button { Task { await model.movePeriod(by: 1) } } label: { Image(systemName: "chevron.right") }
                .v15PlatformHitArea()
                .accessibilityLabel("下一个期间")
                .accessibilityIdentifier("v15.f4a.period.next")
            Spacer(minLength: V15Spacing.sm)
            Text(model.selectedPeriod.kind == .month ? "月" : "年")
                .font(V15Typography.label)
                .foregroundStyle(V15Palette.ink.color.opacity(0.58))
        }
    }

    private var lensControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: V15Spacing.xs) {
                ForEach(V15ReportingModel.Lens.allCases, id: \.self) { lens in
                    Button(lensLabel(lens)) { model.selectLens(lens) }
                        .buttonStyle(.plain)
                        .font(V15Typography.secondary.weight(.semibold))
                        .foregroundStyle(model.lens == lens ? V15Palette.primaryButtonText.color : V15Palette.ink.color.opacity(0.68))
                        .padding(.horizontal, 16)
                        .frame(minHeight: V15Accessibility.minimumTouchTarget)
                        .background(model.lens == lens ? V15Palette.teal.color : V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
                        .accessibilityAddTraits(model.lens == lens ? .isSelected : [])
                        .accessibilityIdentifier("v15.f4a.lens.\(lens.rawValue)")
                }
            }
        }
        .accessibilityIdentifier("v15.f4a.lens")
    }

    @ViewBuilder private var phaseSurface: some View {
        switch model.phase {
        case .idle, .loading:
            V15LoadingSkeleton().accessibilityIdentifier("v15.f4a.loading")
        case .failed(let failure):
            V15ServiceErrorState(message: failure.message) { Task { await model.load() } }
                .accessibilityIdentifier("v15.f4a.error")
        case .requiresReload(let failure):
            reportCard("报表数据已更新") {
                Text(failure.message).font(V15Typography.body)
                Text("没有修改任何数据。请取最新数据后继续。")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                V15ActionButton("取最新数据重新决定", symbol: V15Symbol.conflict) { Task { await model.reloadFresh() } }
                    .accessibilityIdentifier("v15.f4a.conflict.reload")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("v15.f4a.conflict")
        case .empty:
            V15EmptyState(title: "这个期间没有报表数据", explanation: "可以选择其他期间继续查看。")
                .accessibilityIdentifier("v15.f4a.empty")
        case .loaded:
            if let report = model.report { lensSurface(report) }
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
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            Text("期间总览").font(V15Typography.cardTitle)
            metricGrid([
                ("收入", report.summary.incomeMinor, .inflow),
                ("个人实际承担", report.summary.personalRealizedMinor, .outflow),
                ("净收支", report.summary.netIncomeExpenseMinor, .balance),
                ("期末信用欠款", report.summary.creditDebtAtPeriodEndMinor, .outflow)
            ])
            reportCard("数据完整性") {
                completenessGrid(report.completeness)
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f4a.surface.overview")
    }

    private func spendingSurface(_ report: V15PeriodReport) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            reportCard("本期支出 · \(spendingLabel(model.spendingMeasure))") {
                HStack(alignment: .firstTextBaseline) {
                    V15MoneyText(minorUnits: model.spendingAmount(in: report.summary), direction: .neutral, font: V15Typography.moneyLarge)
                        .accessibilityIdentifier("v15.f4a.spending.hero")
                    Spacer(minLength: V15Spacing.sm)
                    Menu("切换口径") {
                        ForEach(V15ReportingModel.SpendingMeasure.allCases, id: \.self) { measure in
                            Button(spendingLabel(measure)) { model.selectSpendingMeasure(measure) }
                        }
                    }
                    .font(V15Typography.secondary.weight(.semibold))
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
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            sevenMeasures(report.summary)
            categoryDistribution(report)
            if let daily = report.daily {
                reportCard("每日 · \(spendingLabel(model.spendingMeasure))") {
                    ForEach(daily) { point in valueRow(point.date, dailyAmount(point), .neutral) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f4a.surface.spending")
    }

    private func cashFlowSurface(_ report: V15PeriodReport) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            Text("现金流 · 钱实际如何进出").font(V15Typography.cardTitle)
            metricGrid([
                ("流入", report.summary.cashInflowMinor, .inflow),
                ("流出", report.summary.cashOutflowMinor, .outflow),
                ("净现金流", report.summary.cashNetMinor, .balance)
            ])
            reportCard("内部转账单列") {
                valueRow("内部转入", report.summary.internalTransferInflowMinor, .neutral)
                valueRow("内部转出", report.summary.internalTransferOutflowMinor, .neutral)
                Text("内部转账不是收入或支出，不计入上方流入/流出。")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.66))
            }
            reportCard("按账户") {
                ForEach(Array(report.accounts.enumerated()), id: \.offset) { indexed in
                    cashAccountRow(indexed.element, id: indexed.offset)
                }
            }
            knownFutureCard(report)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f4a.surface.cashFlow")
    }

    private func debtSurface(_ report: V15PeriodReport) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            Text("债务 · 期末存量").font(V15Typography.cardTitle)
            metricGrid([
                ("当前信用欠款", report.summary.creditDebtAtPeriodEndMinor, .outflow),
                ("待收报销", report.summary.reimbursementOutstandingAtPeriodEndMinor, .balance)
            ])
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
            if let cycles = report.debtCycles {
                reportCard("信用账期") {
                    if cycles.isEmpty { Text("本期没有已知信用账期。") }
                    ForEach(cycles) { cycle in valueRow("\(cycle.accountName) · \(cycle.dueDate)", cycle.remainingMinor, .neutral) }
                }
            }
            if let installments = report.installments {
                reportCard("分期安排") {
                    if installments.isEmpty { Text("本期没有已排期的分期。") }
                    ForEach(installments) { group in valueRow("\(group.month) · \(group.periodCount) 期（本金 \(money(group.principalScheduledGrossMinor))，手续费 \(money(group.feeScheduledGrossMinor))）", group.totalScheduledGrossMinor, .neutral) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f4a.surface.debt")
    }

    private func sevenMeasures(_ summary: V15PeriodReport.Summary) -> some View {
        reportCard("支出统计方式") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: V15Spacing.xs)], spacing: V15Spacing.xs) {
                ForEach(V15ReportingModel.SpendingMeasure.allCases, id: \.self) { measure in
                    Button { model.selectSpendingMeasure(measure) } label: {
                        VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                            Text(spendingLabel(measure))
                                .font(V15Typography.secondary.weight(measure == model.spendingMeasure ? .bold : .regular))
                                .foregroundStyle(V15Palette.ink.color)
                                .fixedSize(horizontal: false, vertical: true)
                            V15MoneyText(minorUnits: model.spendingAmount(measure, in: summary), direction: .neutral, includeCurrency: false, font: V15Typography.money)
                            if measure == model.spendingMeasure {
                                Text("当前口径").font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.58))
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                        .padding(V15Spacing.sm)
                        .background(measure == model.spendingMeasure ? V15Palette.selected.color : V15Palette.paper.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
                        .overlay { RoundedRectangle(cornerRadius: V15Radius.control).stroke(V15Palette.hairline.color) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(measure == model.spendingMeasure ? .isSelected : [])
                    .accessibilityIdentifier("v15.f4a.measure.\(measure.rawValue)")
                }
            }
        }
    }

    @ViewBuilder private func knownFutureCard(_ report: V15PeriodReport) -> some View {
        if let events = report.knownFutureEvents {
            reportCard("已知未来事项") {
                if events.isEmpty { Text("本期没有已知的未来事项。") }
                ForEach(events) { event in valueRow("\(event.date) · \(event.title) · \(certaintyLabel(event.certainty))", event.amountMinor, .neutral) }
            }
        }
    }

    private func dailyAmount(_ point: V15PeriodReport.Daily) -> Int64 {
        switch model.spendingMeasure { case .grossConsumption: point.grossConsumptionMinor; case .merchantRefund: point.merchantRefundMinor; case .netConsumption: point.netConsumptionMinor; case .expectedReimbursement: point.expectedReimbursementMinor; case .receivedReimbursement: point.receivedReimbursementMinor; case .personalExpected: point.personalExpectedMinor; case .personalRealized: point.personalRealizedMinor }
    }
    private func money(_ value: V15MinorUnits) -> String { V15MoneyPresentation(minorUnits: value, direction: .neutral).text }
    private func certaintyLabel(_ value: V15FutureEventCertainty) -> String { switch value { case .exactDue: "确定应还"; case .confirmed: "已确认"; case .expected: "预计"; case .scheduled: "已排期" } }

    @ViewBuilder private func categoryDistribution(_ report: V15PeriodReport) -> some View {
        let available = report.categories.compactMap { category -> (V15PeriodReport.Category, Int64)? in
            model.categoryAmount(category, for: model.spendingMeasure).map { (category, $0) }
        }
        if available.count == report.categories.count {
            reportCard("按分类 · \(spendingLabel(model.spendingMeasure))") {
                let maximum = max(available.map { max($0.1, 0) }.max() ?? 0, 1)
                ForEach(Array(available.enumerated()), id: \.offset) { indexed in
                    categoryRow(indexed.element.0, amount: indexed.element.1, maximum: maximum, id: indexed.offset)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: V15Spacing.md) {
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
        VStack(alignment: .leading, spacing: V15Spacing.xs) {
            Button {
                guard let owner = model.beginDrill(capability: category.drillCapability, label: category.categoryName) else { return }
                Task { await model.loadDrill(owner: owner) }
            } label: {
                VStack(alignment: .leading, spacing: V15Spacing.xs) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                            Text(category.categoryName).font(V15Typography.body.weight(.semibold))
                            Text("\(category.transactionCount) 笔").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.62))
                        }
                        Spacer(minLength: V15Spacing.sm)
                        V15MoneyText(minorUnits: amount, direction: .neutral, font: V15Typography.money)
                    }
                    GeometryReader { proxy in
                        Capsule()
                            .fill(V15Palette.hairline.color)
                            .overlay(alignment: .leading) {
                                Capsule().fill(V15Palette.teal.color).frame(width: proxy.size.width * CGFloat(max(0, Double(amount) / Double(maximum))))
                            }
                    }
                    .frame(height: 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(V15Spacing.sm)
                .background(category.categoryID == nil ? V15Palette.provisional.color : V15Palette.paper.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
                .overlay(alignment: .leading) { if category.categoryID == nil { Rectangle().fill(V15Palette.yellow.color).frame(width: 4) } }
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled(category.drillCapability))
            .accessibilityIdentifier("v15.f4a.row.category.\(id)")
            if category.categoryID == nil {
                Text("未分类金额仍计入总额，暂时不能查看明细。")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func metricGrid(_ values: [(String, Int64, V15MoneyDirection)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: V15Spacing.xs)], spacing: V15Spacing.xs) {
            ForEach(Array(values.enumerated()), id: \.offset) { indexed in
                VStack(alignment: .leading, spacing: V15Spacing.xs) {
                    Text(indexed.element.0).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    V15MoneyText(minorUnits: indexed.element.1, direction: indexed.element.2, font: V15Typography.moneyLarge)
                }
                .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
                .padding(V15Spacing.md)
                .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.card))
                .overlay { RoundedRectangle(cornerRadius: V15Radius.card).stroke(V15Palette.hairline.color) }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("v15.f4a.metric.\(indexed.offset)")
            }
        }
    }

    private func completenessGrid(_ value: V15PeriodReport.Completeness) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: V15Spacing.xs)], spacing: V15Spacing.xs) {
            countCell("未处理导入", value.unresolvedImportCount)
            countCell("失败导入", value.failedImportCount)
            countCell("未分类", value.uncategorizedTransactionCount)
        }
    }

    private func countCell(_ title: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.xxs) {
            Text(title).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
            Text("\(count)").font(V15Typography.moneyLarge).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(V15Spacing.sm)
        .background(count > 0 ? V15Palette.provisional.color : V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
    }

    private func cashAccountRow(_ account: V15PeriodReport.Account, id: Int) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.xs) {
            Button {
                guard let owner = model.beginDrill(capability: account.drillCapability, label: account.accountName) else { return }
                Task { await model.loadDrill(owner: owner) }
            } label: {
                VStack(alignment: .leading, spacing: V15Spacing.xs) {
                    HStack { Text(account.accountName).font(V15Typography.body.weight(.semibold)); Spacer(); V15MoneyText(minorUnits: account.closingBalanceMinor, direction: .balance) }
                    Text("期内流入 \(V15MoneyPresentation(minorUnits: account.periodInflowMinor, direction: .inflow, includeCurrency: false).text) · 流出 \(V15MoneyPresentation(minorUnits: account.periodOutflowMinor, direction: .outflow, includeCurrency: false).text)")
                        .font(V15Typography.secondary)
                        .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("内部转入 \(V15MoneyPresentation(minorUnits: account.internalTransferInflowMinor, direction: .neutral, includeCurrency: false).text) · 转出 \(V15MoneyPresentation(minorUnits: account.internalTransferOutflowMinor, direction: .neutral, includeCurrency: false).text)")
                        .font(V15Typography.secondary)
                        .foregroundStyle(V15Palette.ink.color.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, V15Spacing.xs)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled(account.drillCapability))
            .accessibilityIdentifier("v15.f4a.row.cash-account.\(id)")
            Divider()
        }
    }

    private func aggregateRow(title: String, detail: String, amount: Int64?, capability: V15ReportDrillCapability, id: String) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.xxs) {
            Button {
                guard let owner = model.beginDrill(capability: capability, label: title) else { return }
                Task { await model.loadDrill(owner: owner) }
            } label: {
                HStack(alignment: .top, spacing: V15Spacing.sm) {
                    VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                        Text(title).font(V15Typography.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: V15Spacing.sm)
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
        HStack { Text(title).font(V15Typography.body); Spacer(); V15MoneyText(minorUnits: amount, direction: direction) }
            .padding(.vertical, V15Spacing.xxs)
    }

    private func reportCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.sm) {
            Text(title).font(V15Typography.cardTitle)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(V15Spacing.md)
        .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.card))
        .overlay { RoundedRectangle(cornerRadius: V15Radius.card).stroke(V15Palette.hairline.color) }
    }

    private func unavailableCard(_ title: String, _ reason: String) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.xs) {
            HStack(alignment: .top, spacing: V15Spacing.xs) {
                Image(systemName: "minus.circle").foregroundStyle(V15Palette.ink.color.opacity(0.58))
                Text(title).font(V15Typography.body.weight(.semibold))
            }
            Text("暂时没有这项数据 · \(reason)")
                .font(V15Typography.secondary)
                .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(V15Spacing.md)
        .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.card))
        .overlay { RoundedRectangle(cornerRadius: V15Radius.card).stroke(V15Palette.hairline.color, style: StrokeStyle(lineWidth: 1, dash: [5, 4])) }
    }

    private var drillTakeover: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.md) {
                    VStack(alignment: .leading, spacing: V15Spacing.xs) {
                        Text("\(lensLabel(model.lens)) · \(model.periodLabel) ›")
                            .font(V15Typography.secondary.weight(.semibold))
                            .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                        Text(model.selectedDrillLabel ?? "明细").font(V15Typography.surfaceTitle)
                        Text("以下明细与当前报表范围一致。")
                            .font(V15Typography.secondary)
                            .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    drillItems
                }
                .padding(V15Spacing.md)
                .frame(maxWidth: 760, alignment: .leading)
            }
            .background(V15Palette.paper.color)
            .navigationTitle("报表钻取")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回报表") { model.dismissDrill() }
                        .accessibilityIdentifier("v15.f4a.drill.return")
                }
            }
        }
        .tint(V15Palette.teal.color)
        .accessibilityIdentifier("v15.f4a.drill")
    }

    @ViewBuilder private var drillItems: some View {
        if model.drillItems.isEmpty {
            switch model.drillPhase {
            case .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f4a.drill.loading")
            case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.retryCurrentDrill() } }.accessibilityIdentifier("v15.f4a.drill.error")
            case .idle: V15EmptyState(title: "没有明细", explanation: "当前筛选范围内没有记录。").accessibilityIdentifier("v15.f4a.drill.empty")
            }
        } else {
            ForEach(model.drillItems) { item in
                VStack(alignment: .leading, spacing: V15Spacing.xs) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                            Text(item.merchantName ?? item.categoryName ?? kindLabel(item.kind)).font(V15Typography.body.weight(.semibold))
                            Text("\(item.businessDate) · \(sourceLabel(item.source)) · \(item.categoryName ?? "未分类")")
                                .font(V15Typography.secondary)
                                .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: V15Spacing.sm)
                        V15MoneyText(minorUnits: item.netConsumptionMinor, direction: .neutral)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: V15Spacing.xs)], spacing: V15Spacing.xs) {
                        drillMeasure("总消费", item.grossConsumptionMinor)
                        drillMeasure("商户退款", item.merchantRefundMinor)
                        drillMeasure("净消费", item.netConsumptionMinor)
                    }
                }
                .padding(V15Spacing.md)
                .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.card))
                .overlay { RoundedRectangle(cornerRadius: V15Radius.card).stroke(V15Palette.hairline.color) }
                .accessibilityIdentifier("v15.f4a.drill.item.\(item.id)")
            }
            if model.hasNextPage {
                V15ActionButton("读取下一页", kind: .secondary, disabledReason: model.isPaging ? .init(code: "loading", message: "正在读取下一页。", fieldPath: nil) : nil) { Task { await model.loadNextPage() } }
                    .accessibilityIdentifier("v15.f4a.drill.next")
            }
            if let failure = model.pageFailure {
                V15ServiceErrorState(message: failure.message) { Task { await model.retryNextPage() } }
                    .accessibilityIdentifier("v15.f4a.drill.page-error")
            }
        }
    }

    private func drillMeasure(_ title: String, _ amount: Int64) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.xxs) {
            Text(title).font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.58))
            V15MoneyText(minorUnits: amount, direction: .neutral, includeCurrency: false, font: V15Typography.money)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var exportSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: V15Spacing.md) {
                Text("导出当前正式报表").font(V15Typography.surfaceTitle)
                if let owner = model.exportOwner {
                    Text("期间 \(owner.period.rawValue) · 上海业务日 · CNY")
                        .font(V15Typography.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                switch model.exportPhase {
                case .confirming(let format):
                    Text(format == .pdf ? "PDF 仅供阅读；不含口令、完整账户标识、账单或 AI 原始内容。" : "CSV 用于逐行复核；不含口令、完整账户标识、账单或 AI 原始内容。")
                    V15AdaptiveStack {
                        V15ActionButton("取消", kind: .secondary) { model.cancelExport() }
                        V15ActionButton("开始导出") { Task { await model.exportConfirmed() } }
                            .accessibilityIdentifier("v15.f4b.export.confirm")
                    }
                case .transferring:
                    V15LoadingSkeleton(); Text("正在准备文件…").font(V15Typography.secondary)
                    V15ActionButton("取消", kind: .secondary) { model.cancelExport() }
                case .ready:
                    VStack(alignment: .leading, spacing: V15Spacing.sm) {
                        Text("文件已准备好。关闭后会删除临时副本。")
                        if let url = model.exportURL {
                            ShareLink(item: url) { Label("共享或存入文件", systemImage: "square.and.arrow.up") }
                                .accessibilityIdentifier("v15.f4b.export.handoff")
                        }
                        V15ActionButton("关闭并删除临时副本", kind: .secondary) { model.dismissExport() }
                            .accessibilityIdentifier("v15.f4b.export.done")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("v15.f4b.export.ready")
                case .saving:
                    V15LoadingSkeleton(); Text("正在存入文件…").font(V15Typography.secondary)
                case .saveFailed(_, let failure):
                    V15ServiceErrorState(message: failure.message) { model.dismissExport() }
                        .accessibilityIdentifier("v15.f4b.export.error")
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
                Spacer(minLength: 0)
            }
            .padding(V15Spacing.md)
            .background(V15Palette.paper.color)
        }
        .tint(V15Palette.teal.color)
        .accessibilityIdentifier("v15.f4b.export.sheet")
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
#endif
