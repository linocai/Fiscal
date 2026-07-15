import SwiftUI

private extension CreditCycleStatus {
    var color: Color { switch self { case .settled: FiscalColor.income; case .overdue: FiscalColor.expense; case .partial, .unpaid: FiscalColor.debt; case .open: FiscalColor.accent } }
}

private struct CreditStatusPill: View {
    let cycle: CreditCycleDTO
    var body: some View { Text(cycle.status.title).font(.caption2.weight(.semibold)).foregroundStyle(cycle.status.color).padding(.horizontal, 8).padding(.vertical, 4).background(cycle.status.color.opacity(0.11), in: .capsule) }
}

struct CreditDashboardTotals: Equatable {
    let assets: Int64
    let debt: Int64
    let netWorth: Int64

    static func checked(accounts: [AccountDTO], credit: [CreditAccountSummaryDTO]) -> CreditDashboardTotals? {
        var assets: Int64 = 0
        for account in accounts where account.kind != .credit && account.archivedAt == nil {
            let result = assets.addingReportingOverflow(account.currentBalanceMinor)
            guard !result.overflow else { return nil }
            assets = result.partialValue
        }
        var debt: Int64 = 0
        for summary in credit {
            let result = debt.addingReportingOverflow(summary.currentDebtMinor)
            guard !result.overflow else { return nil }
            debt = result.partialValue
        }
        let net = assets.subtractingReportingOverflow(debt)
        guard !net.overflow else { return nil }
        return .init(assets: assets, debt: debt, netWorth: net.partialValue)
    }
}

#if os(iOS)
public struct IOSCreditAccountsScreen: View {
    @Bindable var credit: CreditModel
    @Bindable var installments: InstallmentModel
    let transactions: TransactionsModel; let accounts: AccountsModel; let categories: CategoriesModel
    @State private var archivedCreditAccounts: [AccountDTO] = []
    public init(credit: CreditModel, installments: InstallmentModel, transactions: TransactionsModel, accounts: AccountsModel, categories: CategoriesModel) { self.credit = credit; self.installments = installments; self.transactions = transactions; self.accounts = accounts; self.categories = categories }
    public var body: some View {
        Group {
            switch credit.phase {
            case .idle, .loading: ProgressView("正在读取信用账户…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                if archivedCreditAccounts.isEmpty { ContentUnavailableView("还没有信用账户", systemImage: "creditcard", description: Text("先在账户中添加信用卡及账单日、还款日。")) }
                else { archivedOnlyList }
            case .unauthorized: retry("设备密钥无效", "key")
            case .offline: retry("无法连接个人 VPS", "wifi.slash")
            case .failed: retry(credit.message ?? "读取失败", "exclamationmark.triangle")
            case .loaded:
                ScrollView { LazyVStack(spacing: 14) { ForEach(credit.accounts) { summary in NavigationLink { IOSCreditAccountDetail(credit: credit, installments: installments, accountID: summary.accountID, transactions: transactions, accounts: accounts, categories: categories) } label: { accountCard(summary) }.buttonStyle(.plain) }; if !archivedCreditAccounts.isEmpty { Text("已归档信用账户").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8); ForEach(archivedCreditAccounts) { account in NavigationLink { IOSCreditAccountDetail(credit: credit, installments: installments, accountID: account.id, transactions: transactions, accounts: accounts, categories: categories, readOnly: true) } label: { archivedAccountCard(account) }.buttonStyle(.plain) } } }.padding(16).padding(.bottom, 90) }.background(FiscalColor.iOSBackground)
            }
        }
        .navigationTitle("信用账期与分期").onAppear { Task { await reload() } }.refreshable { await reload() }
    }
    private func archivedAccountCard(_ account: AccountDTO) -> some View { FiscalCard(radius: 20) { HStack { FiscalIconTile("archivebox.fill", color: FiscalColor.tertiary); VStack(alignment: .leading, spacing: 4) { Text(account.name).font(.headline); Text("已归档 · 只读历史").font(.caption).foregroundStyle(FiscalColor.tertiary) }; Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(FiscalColor.tertiary) } } }
    private var archivedOnlyList: some View { ScrollView { LazyVStack(alignment: .leading, spacing: 14) { Text("已归档信用账户").font(.headline); ForEach(archivedCreditAccounts) { account in NavigationLink { IOSCreditAccountDetail(credit: credit, installments: installments, accountID: account.id, transactions: transactions, accounts: accounts, categories: categories, readOnly: true) } label: { archivedAccountCard(account) }.buttonStyle(.plain) } }.padding(16).padding(.bottom, 90) }.background(FiscalColor.iOSBackground) }
    private func reload() async { async let summaries: Void = credit.loadAccounts(); async let options = accounts.transactionOptions(); if let values = try? await options { archivedCreditAccounts = values.filter { $0.kind == .credit && $0.archivedAt != nil } }; await summaries }
    private func accountCard(_ value: CreditAccountSummaryDTO) -> some View {
        FiscalCard(radius: 20) { VStack(alignment: .leading, spacing: 13) { HStack { FiscalIconTile("creditcard.fill", color: FiscalColor.debt); VStack(alignment: .leading, spacing: 3) { Text(value.name).font(.headline); Text(value.lastFour.map { "尾号 \($0)" } ?? "信用账户").font(.caption).foregroundStyle(FiscalColor.tertiary) }; Spacer(); if value.hasOverdueCycle { Text("有逾期").font(.caption2.bold()).foregroundStyle(FiscalColor.expense) }; Image(systemName: "chevron.right").font(.caption).foregroundStyle(FiscalColor.tertiary) }; HStack(alignment: .firstTextBaseline) { VStack(alignment: .leading) { Text("当前欠款").font(.caption).foregroundStyle(FiscalColor.tertiary); Text(Money(minorUnits: value.currentDebtMinor).formatted()).font(.title2.bold()).foregroundStyle(FiscalColor.debt) }; Spacer(); VStack(alignment: .trailing) { Text("可用额度").font(.caption).foregroundStyle(FiscalColor.tertiary); Text(Money(minorUnits: value.availableCreditMinor).formatted()).font(.subheadline.weight(.semibold)) } }; if value.activeInstallmentCount > 0 { Label("\(value.activeInstallmentCount) 个分期 · 未来计划毛额 \(Money(minorUnits: value.futureScheduledGrossMinor).formatted())", systemImage: "calendar.badge.clock").font(.caption).foregroundStyle(FiscalColor.debt) }; if value.openingConfigurationRequired { Label("请确认期初欠款日期；未知期初部分不判断到期或还款", systemImage: "calendar.badge.exclamationmark").font(.caption).foregroundStyle(FiscalColor.debt) }; if value.overLimitMinor > 0 { Label("已超额度 \(Money(minorUnits: value.overLimitMinor).formatted())", systemImage: "exclamationmark.triangle.fill").font(.caption.bold()).foregroundStyle(FiscalColor.expense) }; if let cycle = value.nextDueCycle { HStack { CreditStatusPill(cycle: cycle); Spacer(); Text("\(cycle.dueDate) 前还 \(Money(minorUnits: cycle.remainingMinor).formatted())").font(.caption).foregroundStyle(FiscalColor.secondary) } } } }
    }
    private func retry(_ title: String, _ symbol: String) -> some View { ContentUnavailableView { Label(title, systemImage: symbol) } description: { Text(credit.message ?? "不会使用预览数据替代。") } actions: { Button("重试") { Task { await credit.loadAccounts() } } } }
}

private struct IOSCreditAccountDetail: View {
    @Bindable var credit: CreditModel
    @Bindable var installments: InstallmentModel
    let accountID: UUID; let transactions: TransactionsModel; let accounts: AccountsModel; let categories: CategoriesModel
    @State private var repayCycle: CreditCycleDTO?
    let readOnly: Bool
    init(credit: CreditModel, installments: InstallmentModel, accountID: UUID, transactions: TransactionsModel, accounts: AccountsModel, categories: CategoriesModel, readOnly: Bool = false) { self.credit = credit; self.installments = installments; self.accountID = accountID; self.transactions = transactions; self.accounts = accounts; self.categories = categories; self.readOnly = readOnly }
    var body: some View {
        Group { if credit.phase == .loading && credit.selectedAccount?.accountID != accountID { ProgressView("正在读取账期…") } else if let summary = credit.selectedAccount, summary.accountID == accountID { ScrollView { VStack(spacing: 14) { if readOnly { Label("已归档账户 · 只读历史", systemImage: "archivebox").font(.caption).foregroundStyle(FiscalColor.tertiary).frame(maxWidth: .infinity, alignment: .leading) }; debtCard(summary); if let cycle = summary.nextDueCycle ?? summary.currentCycle { cycleCard(cycle, prominent: true) }; installmentCards; if !credit.cycles.isEmpty { VStack(alignment: .leading, spacing: 10) { Text("历史账期").font(.headline); ForEach(credit.cycles) { cycle in NavigationLink { IOSCreditCycleDetail(credit: credit, cycleID: cycle.id, transactions: transactions, accounts: accounts, categories: categories, readOnly: readOnly) } label: { cycleRow(cycle) }.buttonStyle(.plain).task { if cycle.id == credit.cycles.last?.id { await credit.loadMoreCycles() } } } }.padding(16).background(.white, in: .rect(cornerRadius: 18)) } }.padding(16).padding(.bottom, 90) }.background(FiscalColor.iOSBackground) } else { ContentUnavailableView("账期读取失败", systemImage: "exclamationmark.triangle", description: Text(credit.message ?? "请重试。")) } }
        .navigationTitle(credit.selectedAccount?.name ?? "信用账户").onAppear { Task { async let c: Void = credit.loadAccount(accountID); async let i: Void = installments.loadAccount(accountID); _ = await (c, i) } }
        .sheet(item: $repayCycle) { cycle in TransactionEditorSheet(transactions: transactions, accounts: accounts, categories: categories, credit: credit, initialKind: .repayment, creditAccountID: accountID, cycleID: cycle.id, amountMinor: cycle.remainingMinor) }
    }
    private func debtCard(_ value: CreditAccountSummaryDTO) -> some View { FiscalCard(radius: 20) { VStack(alignment: .leading, spacing: 10) { Text("当前信用负债").font(.caption).foregroundStyle(FiscalColor.tertiary); Text(Money(minorUnits: value.currentDebtMinor).formatted()).font(.system(size: 31, weight: .bold)).foregroundStyle(FiscalColor.debt); ProgressView(value: Double(min(value.currentDebtMinor, value.creditLimitMinor)), total: Double(max(1, value.creditLimitMinor))).tint(value.overLimitMinor > 0 ? FiscalColor.expense : FiscalColor.debt); HStack { Text("额度 \(Money(minorUnits: value.creditLimitMinor).formatted())"); Spacer(); Text("可用 \(Money(minorUnits: value.availableCreditMinor).formatted())") }.font(.caption).foregroundStyle(FiscalColor.secondary); if value.overLimitMinor > 0 { Label("超出额度 \(Money(minorUnits: value.overLimitMinor).formatted())，新增消费已暂停", systemImage: "exclamationmark.triangle.fill").font(.caption.bold()).foregroundStyle(FiscalColor.expense) }; if value.openingConfigurationRequired { Label("请在账户编辑中确认期初日期；正常账期仍可还，未知期初部分不可还", systemImage: "calendar.badge.exclamationmark").font(.caption).foregroundStyle(FiscalColor.debt) } } } }
    private func cycleCard(_ cycle: CreditCycleDTO, prominent: Bool) -> some View { FiscalCard(radius: 20) { VStack(alignment: .leading, spacing: 12) { HStack { Text(cycle.isOpeningCycle ? "期初欠款" : "本期应还").font(.headline); Spacer(); CreditStatusPill(cycle: cycle) }; Text(Money(minorUnits: cycle.remainingMinor).formatted()).font(.system(size: 30, weight: .bold)).foregroundStyle(cycle.isOverdue ? FiscalColor.expense : FiscalColor.debt); Text(cycle.isOpeningCycle ? "余额日期 \(cycle.statementDate) · 到期日 \(cycle.dueDate)" : "账期 \(cycle.periodStart)–\(cycle.periodEnd) · 还款日 \(cycle.dueDate)").font(.caption).foregroundStyle(FiscalColor.secondary); HStack { if !readOnly { Button("全额还款") { repayCycle = cycle }.buttonStyle(.borderedProminent).disabled(cycle.remainingMinor == 0) }; NavigationLink("查看明细") { IOSCreditCycleDetail(credit: credit, cycleID: cycle.id, transactions: transactions, accounts: accounts, categories: categories, readOnly: readOnly) }.buttonStyle(.bordered) } } } }
    private func cycleRow(_ cycle: CreditCycleDTO) -> some View { HStack { VStack(alignment: .leading, spacing: 4) { Text(cycle.isOpeningCycle ? "期初欠款 · 余额日期 \(cycle.statementDate)" : "\(cycle.periodStart)–\(cycle.periodEnd)").font(.subheadline.weight(.medium)); Text("到期日 \(cycle.dueDate)").font(.caption).foregroundStyle(FiscalColor.tertiary) }; Spacer(); VStack(alignment: .trailing, spacing: 4) { Text(Money(minorUnits: cycle.remainingMinor).formatted()).font(.subheadline.weight(.semibold)); CreditStatusPill(cycle: cycle) }; Image(systemName: "chevron.right").font(.caption).foregroundStyle(FiscalColor.tertiary) }.padding(.vertical, 6) }
    @ViewBuilder private var installmentCards: some View {
        if installments.loadedAccountID == accountID, let error = installmentError {
            FiscalCard(radius: 18) { VStack(alignment: .leading, spacing: 8) { Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(FiscalColor.expense); Button("重试") { Task { await installments.loadAccount(accountID) } }.buttonStyle(.bordered) } }
        } else if installments.loadedAccountID == accountID, !installments.plans.isEmpty {
            VStack(alignment: .leading, spacing: 10) { Text("分期计划").font(.headline); ForEach(installments.plans) { plan in NavigationLink { IOSInstallmentPlanDetail(installments: installments, planID: plan.id, accounts: accounts, categories: categories, readOnly: readOnly) } label: { VStack(alignment: .leading, spacing: 8) { HStack { Text(plan.title).font(.headline); Spacer(); Text("\(plan.cycleSettledCount + plan.cancelledCount) / \(plan.installmentCount) 期").font(.caption).foregroundStyle(FiscalColor.tertiary); Image(systemName: "chevron.right").font(.caption) }; if let next = plan.nextPeriod { Text("下一期计划毛额 \(Money(minorUnits: next.amountDueMinor).formatted()) · 到期 \(next.dueDate)").font(.subheadline) }; ProgressView(value: Double(plan.cycleSettledCount + plan.cancelledCount), total: Double(max(1, plan.installmentCount))).tint(FiscalColor.debt); HStack { Text("融资总额 \(Money(minorUnits: plan.totalFinancedMinor).formatted())"); Spacer(); Text("未来计划毛额 \(Money(minorUnits: plan.futureScheduledGrossMinor).formatted())") }.font(.caption).foregroundStyle(FiscalColor.secondary); Text("毛额未扣除通用部分还款；精确余额以账期为准。") .font(.caption2).foregroundStyle(FiscalColor.tertiary) }.padding(16).background(.white, in: .rect(cornerRadius: 18)) }.buttonStyle(.plain) } }
        }
    }
    private var installmentError: String? { switch installments.phase { case .unauthorized, .offline, .failed: installments.message ?? "分期读取失败"; default: installments.refreshMessage } }
}

private struct IOSCreditCycleDetail: View {
    @Bindable var credit: CreditModel
    let cycleID: UUID; let transactions: TransactionsModel; let accounts: AccountsModel; let categories: CategoriesModel
    @State private var showRepayment = false
    let readOnly: Bool
    init(credit: CreditModel, cycleID: UUID, transactions: TransactionsModel, accounts: AccountsModel, categories: CategoriesModel, readOnly: Bool = false) { self.credit = credit; self.cycleID = cycleID; self.transactions = transactions; self.accounts = accounts; self.categories = categories; self.readOnly = readOnly }
    var body: some View {
        cycleContent
        .navigationTitle("信用账期").onAppear { Task { await credit.loadCycle(cycleID) } }
        .sheet(isPresented: $showRepayment) { if let cycle = credit.selectedCycle { TransactionEditorSheet(transactions: transactions, accounts: accounts, categories: categories, credit: credit, initialKind: .repayment, creditAccountID: cycle.accountID, cycleID: cycle.id, amountMinor: cycle.remainingMinor) } }
    }
    @ViewBuilder private var cycleContent: some View {
        if let cycle = credit.selectedCycle, cycle.id == cycleID {
            ScrollView { VStack(spacing: 14) { FiscalCard(radius: 20) { VStack(alignment: .leading, spacing: 10) { HStack { Text(cycle.isOpeningCycle ? "期初欠款" : "账期详情").font(.headline); Spacer(); CreditStatusPill(cycle: cycle) }; Text(Money(minorUnits: cycle.remainingMinor).formatted()).font(.system(size: 30, weight: .bold)).foregroundStyle(cycle.isOverdue ? FiscalColor.expense : FiscalColor.debt); if cycle.isOpeningCycle { valueRow("余额日期", cycle.statementDate) } else { valueRow("账期", "\(cycle.periodStart)–\(cycle.periodEnd)") }; valueRow("消费与期初", Money(minorUnits: cycle.amountDueMinor).formatted()); valueRow("已还", Money(minorUnits: cycle.repaidMinor).formatted()); valueRow("还款日", cycle.dueDate); if readOnly { Label("已归档账户 · 只读历史", systemImage: "archivebox").font(.caption).foregroundStyle(FiscalColor.tertiary) } else if cycle.remainingMinor > 0 { Button("全额或部分还款") { showRepayment = true }.buttonStyle(.borderedProminent) } } }; VStack(alignment: .leading, spacing: 10) { Text("本期流水").font(.headline); FiscalCard(radius: 18) { VStack(spacing: 0) { if credit.cycleTransactions.isEmpty { Text("本账期暂无流水").foregroundStyle(FiscalColor.tertiary).frame(maxWidth: .infinity).padding() }; ForEach(credit.cycleTransactions) { item in HStack { Image(systemName: item.kind.symbol).foregroundStyle(item.kind == .repayment ? FiscalColor.income : FiscalColor.debt); Text(item.title); Spacer(); Text(Money(minorUnits: item.amountMinor).formatted()).monospacedDigit() }.padding(.vertical, 9).task { if item.id == credit.cycleTransactions.last?.id { await credit.loadMoreTransactions() } }; Divider() } } } } }.padding(16).padding(.bottom, 90) }.background(FiscalColor.iOSBackground)
        } else {
            switch credit.phase {
            case .unauthorized: cycleRetry("设备密钥无效", "key")
            case .offline: cycleRetry("无法连接个人 VPS", "wifi.slash")
            case .failed: cycleRetry(credit.message ?? "账期读取失败", "exclamationmark.triangle")
            default: ProgressView("正在读取账期明细…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    private func cycleRetry(_ title: String, _ symbol: String) -> some View { ContentUnavailableView { Label(title, systemImage: symbol) } description: { Text(credit.message ?? "不会使用预览数据替代。") } actions: { Button("重试") { Task { await credit.loadCycle(cycleID) } } } }
    private func valueRow(_ label: String, _ value: String) -> some View { HStack { Text(label).foregroundStyle(FiscalColor.tertiary); Spacer(); Text(value).fontWeight(.medium) }.font(.subheadline) }
}
#endif

#if os(macOS)
public struct MacAccountsCreditScreen: View {
    @Bindable var accounts: AccountsModel
    @Bindable var credit: CreditModel
    @Bindable var installments: InstallmentModel
    let transactions: TransactionsModel; let categories: CategoriesModel
    @State private var selectedCreditID: UUID?
    @State private var showManagement = false
    @State private var repayCycle: CreditCycleDTO?
    @State private var archivedCreditAccounts: [AccountDTO] = []
    @State private var selectedPlanID: UUID?
    @State private var showInstallmentEdit = false
    @State private var showInstallmentSettlement = false
    @State private var showInstallmentCancellation = false
    @State private var showInstallmentReverse = false
    public init(accounts: AccountsModel, credit: CreditModel, installments: InstallmentModel, transactions: TransactionsModel, categories: CategoriesModel) { self.accounts = accounts; self.credit = credit; self.installments = installments; self.transactions = transactions; self.categories = categories }
    public var body: some View {
        VStack(spacing: 0) {
            HStack { Text("账户").font(.system(size: 22, weight: .bold)); Spacer(); Button("管理账户") { showManagement = true }.buttonStyle(.bordered) }.padding(.horizontal, 20).frame(height: 54).background(.white)
            if let creditError {
                HStack {
                    Label(creditError, systemImage: "wifi.exclamationmark")
                    Spacer()
                    Button("重试") { Task { await credit.loadAccounts() } }.buttonStyle(.plain).fontWeight(.semibold)
                }
                .font(.caption).foregroundStyle(FiscalColor.expense).padding(.horizontal, 20).frame(height: 34)
                .background(FiscalColor.expense.opacity(0.08))
            }
            HStack(spacing: 0) { content.frame(maxWidth: .infinity, maxHeight: .infinity); Divider(); inspector.frame(width: 256).frame(maxHeight: .infinity) }
        }.background(FiscalColor.macBackground)
        .onAppear { Task { await reload() } }
        .onChange(of: showManagement) { wasShowing, isShowing in if wasShowing && !isShowing { Task { await reload() } } }
        .sheet(isPresented: $showManagement) { NavigationStack { AccountsManagementScreen(model: accounts) }.frame(width: 620, height: 620) }
        .sheet(item: $repayCycle) { cycle in TransactionEditorSheet(transactions: transactions, accounts: accounts, categories: categories, credit: credit, initialKind: .repayment, creditAccountID: cycle.accountID, cycleID: cycle.id, amountMinor: cycle.remainingMinor) }
        .sheet(isPresented: $showInstallmentEdit) { if let plan = installments.selectedPlan, let purchase = installments.selectedPurchase { InstallmentEditorSheet(installments: installments, plan: plan, purchase: purchase, accounts: accounts, categories: categories) } }
        .sheet(isPresented: $showInstallmentSettlement) { if let plan = installments.selectedPlan { InstallmentSettlementSheet(installments: installments, plan: plan, accounts: accounts) } }
        .sheet(isPresented: $showInstallmentCancellation) { if let plan = installments.selectedPlan { InstallmentCancellationSheet(installments: installments, plan: plan) } }
        .sheet(isPresented: $showInstallmentReverse) { if let plan = installments.selectedPlan { InstallmentReverseSettlementSheet(installments: installments, plan: plan) } }
    }
    private var creditError: String? {
        if let refresh = credit.refreshMessage { return refresh }
        switch credit.phase {
        case .unauthorized: return credit.message ?? "设备密钥无效"
        case .offline: return credit.message ?? "无法连接个人 VPS"
        case .failed: return credit.message ?? "信用账期读取失败"
        default: return nil
        }
    }
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                summaryCards
                Text("账户").font(.headline)
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 14) {
                    ForEach(accounts.accounts.filter { $0.archivedAt == nil }) { account in accountCard(account) }
                }
                if !archivedCreditAccounts.isEmpty {
                    Text("已归档信用账户").font(.headline).padding(.top, 8)
                    LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 14) {
                        ForEach(archivedCreditAccounts) { account in accountCard(account) }
                    }
                }
            }
            .padding(20)
        }
    }
    @ViewBuilder private var summaryCards: some View {
        if let totals = CreditDashboardTotals.checked(accounts: accounts.accounts, credit: credit.accounts) {
            HStack(spacing: 12) { stat("总资产", totals.assets, FiscalColor.accent); stat("总负债", totals.debt, FiscalColor.debt); stat("净值", totals.netWorth, FiscalColor.text) }
        } else {
            Label("账户汇总超出可表示范围，请检查异常余额", systemImage: "exclamationmark.triangle.fill").foregroundStyle(FiscalColor.expense).padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: .rect(cornerRadius: 14))
        }
    }
    private func stat(_ title: String, _ amount: Int64, _ color: Color) -> some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption).foregroundStyle(FiscalColor.tertiary); Text(Money(minorUnits: amount).formatted()).font(.title3.bold()).foregroundStyle(color).monospacedDigit() }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: .rect(cornerRadius: 14)) }
    private func accountCard(_ account: AccountDTO) -> some View {
        Button {
            guard account.kind == .credit else { return }
            selectedCreditID = account.id
            selectedPlanID = nil
            Task { async let c: Void = credit.loadAccount(account.id); async let i: Void = installments.loadAccount(account.id); _ = await (c, i) }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    FiscalIconTile(account.kind.symbol, color: account.kind == .credit ? FiscalColor.debt : FiscalColor.accent)
                    VStack(alignment: .leading) {
                        Text(account.name).font(.headline)
                        Text(account.archivedAt == nil ? (account.lastFour.map { "尾号 \($0)" } ?? account.kind.title) : "已归档 · 只读历史").font(.caption).foregroundStyle(FiscalColor.tertiary)
                    }
                    Spacer()
                }
                if let summary = credit.accounts.first(where: { $0.accountID == account.id }) {
                    Text("当前欠款").font(.caption).foregroundStyle(FiscalColor.tertiary)
                    Text(Money(minorUnits: summary.currentDebtMinor).formatted()).font(.title2.bold()).foregroundStyle(FiscalColor.debt)
                    ProgressView(value: Double(min(summary.currentDebtMinor, summary.creditLimitMinor)), total: Double(max(1, summary.creditLimitMinor)))
                        .tint(summary.overLimitMinor > 0 ? FiscalColor.expense : FiscalColor.debt)
                    HStack {
                        Text("额度 \(Money(minorUnits: summary.creditLimitMinor).formatted())")
                        Spacer()
                        Text("账单日 \(summary.statementDay) · 还款日 \(summary.dueDay)")
                    }
                    .font(.caption).foregroundStyle(FiscalColor.secondary)
                    if summary.openingConfigurationRequired {
                        Label("需确认期初日期", systemImage: "calendar.badge.exclamationmark").font(.caption.bold()).foregroundStyle(FiscalColor.debt)
                    }
                    if let due = summary.nextDueCycle {
                        Text("本期应还 \(Money(minorUnits: due.remainingMinor).formatted()) · \(due.dueDate)").font(.caption.weight(.semibold)).foregroundStyle(due.isOverdue ? FiscalColor.expense : FiscalColor.debt)
                    }
                    if let teaser = summary.nextInstallment {
                        Text("分期中 · \(teaser.title) · \(teaser.installmentCount) 期\(teaser.nextPeriod.map { " · 下一期计划毛额 \(Money(minorUnits: $0.amountDueMinor).formatted())" } ?? "")")
                            .font(.caption).foregroundStyle(FiscalColor.debt).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(FiscalColor.debt.opacity(0.09), in: .rect(cornerRadius: 9))
                    }
                    if summary.overLimitMinor > 0 {
                        Text("超额 \(Money(minorUnits: summary.overLimitMinor).formatted())").font(.caption.bold()).foregroundStyle(FiscalColor.expense)
                    }
                } else {
                    Text(Money(minorUnits: account.currentBalanceMinor).formatted()).font(.title3.bold())
                }
            }
            .padding(16).frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .background(selectedCreditID == account.id ? FiscalColor.accent.opacity(0.10) : .white, in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var inspector: some View {
        if let summary = credit.selectedAccount, summary.accountID == selectedCreditID {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(summary.name).font(.title3.bold())
                    Text(Money(minorUnits: summary.currentDebtMinor).formatted()).font(.system(size: 28, weight: .bold)).foregroundStyle(FiscalColor.debt)
                    if summary.openingConfigurationRequired {
                        Label("请先在账户管理中确认期初余额日期与到期日", systemImage: "calendar.badge.exclamationmark").font(.caption).foregroundStyle(FiscalColor.debt)
                    }
                    if summary.overLimitMinor > 0 {
                        Label("已超额度 \(Money(minorUnits: summary.overLimitMinor).formatted())", systemImage: "exclamationmark.triangle.fill").foregroundStyle(FiscalColor.expense)
                    } else if summary.hasOverdueCycle {
                        Label("存在逾期账期", systemImage: "exclamationmark.triangle.fill").foregroundStyle(FiscalColor.expense)
                    }
                    Divider()
                    Text("账期").font(.headline)
                    ForEach(credit.cycles) { cycle in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                CreditStatusPill(cycle: cycle)
                                Spacer()
                                Text(Money(minorUnits: cycle.remainingMinor).formatted()).fontWeight(.semibold)
                            }
                            Text(cycle.isOpeningCycle ? "期初欠款 · 余额日期 \(cycle.statementDate)" : "\(cycle.periodStart)–\(cycle.periodEnd)").font(.caption).foregroundStyle(FiscalColor.secondary)
                            Text("到期日 \(cycle.dueDate)").font(.caption).foregroundStyle(FiscalColor.tertiary)
                            if cycle.remainingMinor > 0 && !selectedAccountIsArchived {
                                Button("还款") { repayCycle = cycle }.buttonStyle(.borderedProminent).controlSize(.small)
                            }
                        }
                        .padding(12).background(FiscalColor.macBackground, in: .rect(cornerRadius: 11))
                        .task { if cycle.id == credit.cycles.last?.id { await credit.loadMoreCycles() } }
                    }
                    if !installments.plans.isEmpty {
                        Divider()
                        Text("分期计划").font(.headline)
                        ForEach(installments.plans) { plan in
                            Button { selectedPlanID = plan.id; Task { await installments.loadPlan(plan.id) } } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack { Text(plan.title).fontWeight(.semibold); Spacer(); Text("\(plan.cycleSettledCount + plan.cancelledCount)/\(plan.installmentCount)期").foregroundStyle(FiscalColor.tertiary) }
                                    if let next = plan.nextPeriod { Text("下一期计划毛额 \(Money(minorUnits: next.amountDueMinor).formatted()) · \(next.dueDate)").foregroundStyle(FiscalColor.secondary) }
                                    Text("未来计划毛额 \(Money(minorUnits: plan.futureScheduledGrossMinor).formatted())").foregroundStyle(FiscalColor.debt)
                                }.font(.caption).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(selectedPlanID == plan.id ? FiscalColor.accent.opacity(0.10) : FiscalColor.macBackground, in: .rect(cornerRadius: 10))
                            }.buttonStyle(.plain)
                        }
                    }
                    if installments.loadedAccountID == selectedCreditID, let error = installmentError {
                        Label(error, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(FiscalColor.expense)
                        Button("重试读取分期") { if let selectedCreditID { Task { await installments.loadAccount(selectedCreditID) } } }.buttonStyle(.bordered)
                    }
                    if let plan = installments.selectedPlan, plan.id == selectedPlanID {
                        if installments.conflictDetected { Label("计划已变化", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(FiscalColor.expense); Button("刷新计划") { Task { await installments.loadPlan(plan.id); installments.clearConflict() } }.buttonStyle(.bordered) }
                        Divider(); HStack { Text("期次").font(.headline); Spacer(); if !selectedAccountIsArchived { Menu { if plan.status == .active || plan.status == .partiallyCancelled { Button("编辑") { showInstallmentEdit = true }; if plan.futureCount > 0 { Button("提前结清") { showInstallmentSettlement = true }; Button("取消未来期次", role: .destructive) { showInstallmentCancellation = true } } }; if plan.status == .settledEarly { Button("撤销提前结清") { showInstallmentReverse = true } } } label: { Image(systemName: "ellipsis.circle") } } }
                        ForEach(plan.periods) { period in VStack(alignment: .leading, spacing: 4) { HStack { Text("第 \(period.sequence) 期"); Spacer(); Text(Money(minorUnits: period.amountDueMinor).formatted()).fontWeight(.semibold) }; Text("\(period.effectiveStatementDate) · 到期 \(period.dueDate) · \(period.status.title)").foregroundStyle(FiscalColor.tertiary) }.font(.caption).padding(.vertical, 5) }
                    }
                    if let projection = installments.liabilities, !projection.groups.isEmpty {
                        Divider(); Text("未来计划额").font(.headline)
                        Text("未扣除通用部分还款，精确余额以账期为准。") .font(.caption2).foregroundStyle(FiscalColor.tertiary)
                        ForEach(projection.groups) { group in HStack { VStack(alignment: .leading) { Text(group.month); Text("\(group.periodCount) 个期次").font(.caption2).foregroundStyle(FiscalColor.tertiary) }; Spacer(); Text(Money(minorUnits: group.totalScheduledGrossMinor).formatted()).fontWeight(.semibold).foregroundStyle(FiscalColor.debt) }.font(.caption).padding(.vertical, 5) }
                    }
                }
                .padding(18)
            }
        } else {
            ContentUnavailableView("选择信用账户", systemImage: "creditcard", description: Text("查看账期与还款状态。"))
        }
    }
    private func reload() async {
        async let activeAccounts: Void = accounts.load()
        async let summaries: Void = credit.loadAccounts()
        async let options = accounts.transactionOptions()
        if let values = try? await options { archivedCreditAccounts = values.filter { $0.kind == .credit && $0.archivedAt != nil } }
        _ = await (activeAccounts, summaries)
        if let selectedCreditID { async let selectedCredit: Void = credit.loadAccount(selectedCreditID); async let selectedInstallments: Void = installments.loadAccount(selectedCreditID); _ = await (selectedCredit, selectedInstallments) }
    }
    private var selectedAccountIsArchived: Bool { archivedCreditAccounts.contains { $0.id == selectedCreditID } }
    private var installmentError: String? { switch installments.phase { case .unauthorized, .offline, .failed: installments.message ?? "分期读取失败"; default: installments.refreshMessage } }
}
#endif
