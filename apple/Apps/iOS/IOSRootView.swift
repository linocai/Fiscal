import FiscalKit
import SwiftUI

private enum IOSTab: Hashable { case overview, transactions, cashFlow, more }
private enum IOSMoreDestination: Hashable {
    case accounts, categories, credit, creditAccount(UUID), reimbursements
    case reports(ReportLens)
    case cloudConnection, settings
}

struct IOSRootView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable var connection: ConnectionModel
    let accounts: AccountsModel
    let categories: CategoriesModel
    let transactions: TransactionsModel
    let credit: CreditModel
    let installments: InstallmentModel
    let reimbursements: ReimbursementModel
    let reports: ReportingModel
    let overview: ReportingModel
    let cashFlow: FutureCashFlowModel
    let aiProposals: AIProposalModel
    let aiSettings: AISettingsModel
    let passphrase: PassphraseModel
    let recordingPreferences: RecordingPreferences
    @State private var selection: IOSTab = .overview
    @State private var showRecordSheet = false
    @State private var morePath: [IOSMoreDestination] = []
    @State private var showAIProposals = false
    @State private var repaymentItem: FutureCashFlowItem?
    @State private var creditCycleItem: FutureCashFlowItem?

    var body: some View {
        Group {
            switch selection {
            case .overview:
                NavigationStack {
                    IOSReportingOverviewScreen(
                        model: overview,
                        pendingProposalCount: aiProposals.pendingCount,
                        openAI: { showAIProposals = true },
                        openCashFlow: { selection = .cashFlow },
                        openAccounts: { morePath = [.accounts]; selection = .more },
                        openCreditAccount: { accountID in
                            morePath = [.creditAccount(accountID)]; selection = .more
                        },
                        openReport: { lens in morePath = [.reports(lens)]; selection = .more },
                        openUncategorized: {
                            transactions.classification = .uncategorized
                            selection = .transactions
                            Task { await transactions.load() }
                        }
                    )
                }
            case .transactions: NavigationStack { IOSTransactionsScreen(model: transactions, accounts: accounts, categories: categories, credit: credit, installments: installments) }
            case .cashFlow:
                NavigationStack {
                    IOSFutureCashFlowScreen(
                        model: cashFlow, accounts: accounts, categories: categories,
                        confirmRepayment: {
                            if $0.creditCycleParts.count > 1 { creditCycleItem = $0 }
                            else { repaymentItem = $0 }
                        },
                        viewCreditCycle: { creditCycleItem = $0 },
                        markReceived: { _ in morePath = [.reimbursements]; selection = .more }
                    )
                }
            case .more: IOSMoreScreen(path: $morePath, accounts: accounts, categories: categories, transactions: transactions, credit: credit, installments: installments, reimbursements: reimbursements, reports: reports, overview: overview, cashFlow: cashFlow, aiProposals: aiProposals, aiSettings: aiSettings, passphrase: passphrase, connection: connection, recordingPreferences: recordingPreferences, openAI: { showAIProposals = true })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FiscalColor.iOSBackground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selection != .more || morePath.isEmpty { tabBar }
        }
        .sheet(isPresented: $showRecordSheet) { TransactionEditorSheet(transactions: transactions, accounts: accounts, categories: categories, credit: credit, installments: installments, preferences: recordingPreferences) }
        .sheet(isPresented: $showAIProposals) { IOSAIProposalSheet(model: aiProposals, accounts: accounts, categories: categories, credit: credit) }
        .sheet(item: $repaymentItem) { item in
            TransactionEditorSheet(
                transactions: transactions, accounts: accounts, categories: categories,
                credit: credit, initialKind: .repayment, creditAccountID: item.accountID,
                cycleID: item.systemReferenceID, amountMinor: item.plannedAmountMinor,
                preferences: recordingPreferences
            )
        }
        .sheet(item: $creditCycleItem) { item in
            if item.creditCycleParts.count > 1 {
                CreditCashFlowGroupSheet(
                    item: item, credit: credit, transactions: transactions,
                    accounts: accounts, categories: categories)
            } else if let cycleID = item.systemReferenceID {
                CreditCycleProjectionSheet(credit: credit, cycleID: cycleID)
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton("总览", symbol: "house", tab: .overview)
            tabButton("流水", symbol: "list.bullet.rectangle", tab: .transactions)
            Button { showRecordSheet = true } label: {
                Image(systemName: "plus").font(.title3.bold()).foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(LinearGradient(colors: [FiscalColor.accent, FiscalColor.accentDark], startPoint: .top, endPoint: .bottom), in: .rect(cornerRadius: 16))
                    .shadow(color: FiscalColor.accent.opacity(0.4), radius: 9, y: 5)
            }
            .frame(maxWidth: .infinity).accessibilityLabel("记一笔")
            tabButton("现金流", symbol: "arrow.up.arrow.down", tab: .cashFlow)
            tabButton("更多", symbol: "ellipsis", tab: .more)
        }
        .padding(.horizontal, 8).frame(height: 72)
        .glassEffect(.regular, in: .rect(cornerRadius: 31))
        .padding(.horizontal, 12)
        .padding(.bottom, 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fiscal.customBottomBar")
    }

    private func tabButton(_ title: String, symbol: String, tab: IOSTab) -> some View {
        Button { selection = tab } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 20, weight: .medium))
                if !dynamicTypeSize.isAccessibilitySize {
                    Text(title).font(.caption2.weight(.medium))
                }
            }
            .foregroundStyle(selection == tab ? FiscalColor.accent : Color(hex: 0x9098A4))
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
        .accessibilityHint(selection == tab ? "当前页面" : "切换到\(title)")
    }
}

private struct IOSMoreScreen: View {
    @Binding var path: [IOSMoreDestination]
    let accounts: AccountsModel
    let categories: CategoriesModel
    let transactions: TransactionsModel
    let credit: CreditModel
    let installments: InstallmentModel
    let reimbursements: ReimbursementModel
    let reports: ReportingModel
    let overview: ReportingModel
    let cashFlow: FutureCashFlowModel
    let aiProposals: AIProposalModel
    let aiSettings: AISettingsModel
    let passphrase: PassphraseModel
    let connection: ConnectionModel
    let recordingPreferences: RecordingPreferences
    let openAI: () -> Void

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 14) {
                    FiscalCard(radius: 20) {
                        VStack(spacing: 0) {
                            NavigationLink(value: IOSMoreDestination.accounts) {
                                row("账户", symbol: "wallet.bifold", detail: "现金 · 储蓄卡 · 信用卡", color: FiscalColor.accent)
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 46)
                            NavigationLink(value: IOSMoreDestination.categories) {
                                row("分类设置", symbol: "tag", detail: "两级 · AI 识别资料", color: FiscalColor.reimbursement)
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 46)
                            NavigationLink(value: IOSMoreDestination.credit) {
                                row("信用账期与分期", symbol: "calendar.badge.clock", detail: "账期 · 分期 · 还款", color: FiscalColor.debt)
                            }.buttonStyle(.plain)
                        }
                    }
                    NavigationLink(value: IOSMoreDestination.cloudConnection) {
                        FiscalCard(radius: 18) {
                            HStack(spacing: 12) {
                                ConnectionBadge(phase: connection.phase)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(cloudEntryTitle).font(.subheadline.weight(.semibold))
                                    Text(cloudEntryDetail).font(.caption).foregroundStyle(FiscalColor.tertiary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.bold())
                                    .foregroundStyle(FiscalColor.tertiary)
                            }
                            .frame(minHeight: 48)
                            .contentShape(.rect)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ios.cloudConnection.entry")
                    FiscalCard(radius: 20) { VStack(spacing: 0) { NavigationLink(value: IOSMoreDestination.reimbursements) { row("报销", symbol: "doc.text", detail: "多人 · 分次到账", color: FiscalColor.reimbursement) }.buttonStyle(.plain); Divider(); NavigationLink(value: IOSMoreDestination.reports(.spending)) { row("报表", symbol: "list.bullet.rectangle", detail: "消费", color: FiscalColor.accent) }.buttonStyle(.plain); Divider(); Button(action: openAI) { badgeRow("AI 待确认", symbol: "sparkles", count: aiProposals.pendingCount) }.buttonStyle(.plain); Divider(); NavigationLink(value: IOSMoreDestination.settings) { row("设置", symbol: "gearshape", detail: "偏好 · AI · 数据", color: FiscalColor.secondary) }.buttonStyle(.plain) } }
                }.padding(16)
            }
            .background(FiscalColor.iOSBackground).navigationTitle("更多")
            .navigationDestination(for: IOSMoreDestination.self) { destination in
                switch destination {
                case .accounts: AccountsManagementScreen(model: accounts)
                case .categories: CategoriesManagementScreen(model: categories)
                case .credit: IOSCreditAccountsScreen(credit: credit, installments: installments, transactions: transactions, accounts: accounts, categories: categories, cashFlow: cashFlow)
                case .creditAccount(let accountID):
                    IOSCreditAccountDetail(credit: credit, installments: installments, accountID: accountID, transactions: transactions, accounts: accounts, categories: categories, cashFlow: cashFlow)
                case .reimbursements: IOSReimbursementsScreen(model: reimbursements, accounts: accounts)
                case .reports: IOSReportsScreen(model: reports)
                case .cloudConnection:
                    IOSCloudConnectionScreen(
                        passphrase: passphrase,
                        connection: connection,
                        refreshContent: refreshCloudContent
                    )
                case .settings:
                    IOSSettingsScreen(
                        model: aiSettings,
                        passphrase: passphrase,
                        preferences: recordingPreferences,
                        accounts: accounts,
                        transactions: transactions,
                        openCategories: { path = [.categories] },
                        openReports: { path = [.reports(.spending)] }
                    )
                }
            }
        }
    }

    private var cloudEntryTitle: String {
        switch connection.phase {
        case .connected: "云端已连接"
        case .unauthorized: "连接云端"
        case .offline: "云端连接异常"
        case .idle, .loading: "正在连接云端"
        }
    }

    private var cloudEntryDetail: String {
        switch connection.phase {
        case .connected: "改访问口令与同步状态"
        case .unauthorized: "输入访问口令连接"
        case .offline: "重试连接或重新输入访问口令"
        case .idle, .loading: "正在核验个人 VPS"
        }
    }

    private func refreshCloudContent() async {
        await connection.refresh()
        guard case .connected = connection.phase else { return }
        // Overview and spending reports live in separate ReportingModel instances (P18); refresh
        // both here — loadAll() on one instance would leave the overview tab stale and let the two
        // loads race each other's shared phase.
        async let overviewLoad: Void = overview.loadOverview()
        async let reportLoad: Void = reports.loadSpending()
        async let proposalLoad: Void = aiProposals.load()
        async let settingsLoad: Void = aiSettings.load()
        _ = await (overviewLoad, reportLoad, proposalLoad, settingsLoad)
    }
    private func row(_ title: String, symbol: String, detail: String, color: Color) -> some View {
        HStack(spacing: 12) { FiscalIconTile(symbol, color: color); Text(title).font(.headline); Spacer(); Text(detail).font(.caption).foregroundStyle(FiscalColor.tertiary).lineLimit(1); Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(FiscalColor.tertiary) }
            .frame(minHeight: 56)
            .contentShape(.rect)
    }
    private func badgeRow(_ title: String, symbol: String, count: Int) -> some View {
        HStack(spacing: 12) { FiscalIconTile(symbol, color: FiscalColor.accent); Text(title).font(.headline); Spacer(); if count > 0 { Text(count > 99 ? "99+" : String(count)).font(.caption2.bold()).foregroundStyle(.white).padding(.horizontal, 7).frame(minHeight: 20).background(FiscalColor.expense, in: .capsule) }; Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(FiscalColor.tertiary) }.frame(minHeight: 56).contentShape(.rect).accessibilityLabel("AI 待确认，\(count) 笔")
    }
}

private struct IOSCloudConnectionScreen: View {
    let passphrase: PassphraseModel
    let connection: ConnectionModel
    let refreshContent: () async -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("连接个人云端").font(.title2.bold())
                    Text("无需填写服务器地址。输入你设定的访问口令即可连接；连接凭证会安全存入 iCloud 同步钥匙串。")
                        .font(.subheadline).foregroundStyle(FiscalColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PassphraseSettingsCard(
                    model: passphrase,
                    compact: true,
                    onConnected: { Task { await refreshContent() } }
                )
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(FiscalColor.iOSBackground)
        .navigationTitle("云端连接")
        .navigationBarTitleDisplayMode(.inline)
        .task { await passphrase.loadStatus() }
        .accessibilityIdentifier("ios.cloudConnection.screen")
    }
}
