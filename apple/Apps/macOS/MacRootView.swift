import FiscalKit
import SwiftUI

private enum MacSection: String, CaseIterable, Identifiable {
    case overview = "总览", transactions = "流水", accounts = "账户", cashFlow = "现金流"
    case reimbursement = "报销", reports = "报表", ai = "AI 待确认", settings = "设置"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .overview: "house"
        case .transactions: "list.bullet.rectangle"
        case .accounts: "wallet.bifold"
        case .cashFlow: "arrow.up.arrow.down"
        case .reimbursement: "doc.text"
        case .reports: "chart.bar"
        case .ai: "sparkles"
        case .settings: "gearshape"
        }
    }
    var phase: String {
        switch self {
        case .overview: "P1"
        case .transactions: "P3"
        case .accounts: "P2"
        case .cashFlow, .reports: "P7"
        case .reimbursement: "P6"
        case .ai, .settings: "P8"
        }
    }
}

struct MacRootView: View {
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
    let deviceSecurity: DeviceSecurityModel
    let recordingPreferences: RecordingPreferences
    let cache: HTTPResponseCache
    @State private var section: MacSection = .overview
    @State private var showCategories = false
    @State private var showRecordSheet = false
    @State private var repaymentItem: FutureCashFlowItem?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.45)
            Group {
                if section == .overview {
                    MacReportingOverviewScreen(model: overview) { destination in
                        guard let destination else { section = .reimbursement; return }
                        reports.lens = destination
                        section = destination == .cashFlow ? .cashFlow : .reports
                    }
                } else if section == .accounts {
                    MacAccountsCreditScreen(accounts: accounts, credit: credit, installments: installments, transactions: transactions, categories: categories, cashFlow: cashFlow)
                } else if section == .transactions {
                    MacTransactionWorkbench(model: transactions, accounts: accounts, categories: categories, credit: credit, installments: installments, preferences: recordingPreferences)
                } else if section == .reimbursement {
                    MacReimbursementsScreen(model: reimbursements, accounts: accounts)
                } else if section == .cashFlow {
                    MacFutureCashFlowScreen(
                        model: cashFlow, accounts: accounts, categories: categories,
                        confirmRepayment: { repaymentItem = $0 },
                        markReceived: { _ in section = .reimbursement }
                    )
                } else if section == .reports {
                    MacReportsScreen(model: reports)
                } else if section == .ai {
                    MacAIProposalScreen(model: aiProposals, accounts: accounts, categories: categories, credit: credit)
                } else if section == .settings {
                    MacSettingsScreen(
                        model: aiSettings,
                        security: deviceSecurity,
                        preferences: recordingPreferences,
                        accounts: accounts,
                        transactions: transactions,
                        cache: cache,
                        openCategories: { showCategories = true },
                        openReports: { section = .reports }
                    )
                } else {
                    PlaceholderScreen(section.rawValue, symbol: section.symbol, phase: section.phase)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(FiscalColor.macBackground)
        .sheet(isPresented: $showCategories) {
            NavigationStack { CategoriesManagementScreen(model: categories) }
                .frame(width: 660, height: 680)
        }
        .sheet(isPresented: $showRecordSheet) {
            TransactionEditorSheet(
                transactions: transactions,
                accounts: accounts,
                categories: categories,
                credit: credit,
                preferences: recordingPreferences
            )
        }
        .sheet(item: $repaymentItem) { item in
            TransactionEditorSheet(
                transactions: transactions, accounts: accounts, categories: categories,
                credit: credit, initialKind: .repayment, creditAccountID: item.accountID,
                cycleID: item.systemReferenceID, amountMinor: item.plannedAmountMinor,
                preferences: recordingPreferences
            )
            .frame(width: 560, height: 680)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 7) {
            Spacer().frame(height: 42)
            ForEach(MacSection.allCases) { item in
                Button { section = item } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.symbol).font(.system(size: 18, weight: .semibold))
                            .frame(width: 42, height: 34)
                            .background(section == item ? AnyShapeStyle(LinearGradient(colors: [FiscalColor.accent, FiscalColor.accentDark], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color.clear), in: .rect(cornerRadius: 10))
                            .foregroundStyle(section == item ? .white : Color(hex: 0x6B7484))
                        Text(item.rawValue).font(.system(size: 10, weight: .medium)).foregroundStyle(section == item ? FiscalColor.accent : FiscalColor.secondary).lineLimit(1)
                    }
                    .frame(width: 94, height: 53)
                    .overlay(alignment: .topTrailing) {
                        if item == .ai && aiProposals.pendingCount > 0 { Text(aiProposals.pendingCount > 99 ? "99+" : String(aiProposals.pendingCount)).font(.caption2.bold()).foregroundStyle(.white).padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16).background(FiscalColor.expense, in: .capsule).offset(x: -14, y: 1) }
                    }
                }.buttonStyle(.plain)
            }
            Button { showRecordSheet = true } label: {
                VStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .bold))
                    Text("记一笔")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(width: 84, height: 52)
                .background(
                    LinearGradient(
                        colors: [FiscalColor.accent, FiscalColor.accentDark],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: .rect(cornerRadius: 14)
                )
                .shadow(color: FiscalColor.accent.opacity(0.28), radius: 8, y: 4)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
            .help("记一笔（⌘N）")
            .accessibilityIdentifier("mac.globalRecord")
            .padding(.top, 4)
            Spacer()
        }
        .frame(width: 110)
        .background(.regularMaterial)
    }
}
