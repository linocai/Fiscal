import FiscalKit
import SwiftUI

@main
struct FiscaliOSApp: App {
    @UIApplicationDelegateAdaptor(FiscalAppDelegate.self) private var appDelegate
    @State private var connection: ConnectionModel
    @State private var accounts: AccountsModel
    @State private var categories: CategoriesModel
    @State private var transactions: TransactionsModel
    @State private var credit: CreditModel
    @State private var installments: InstallmentModel
    @State private var reimbursements: ReimbursementModel
    @State private var reports: ReportingModel
    @State private var aiProposals: AIProposalModel
    @State private var aiSettings: AISettingsModel

    init() {
        let baseURL = APIConfiguration.baseURL()
        let transport = APITransport(baseURL: baseURL)
        let accounts = AccountsModel(repository: RemoteAccountRepository(transport: transport))
        let categories = CategoriesModel(repository: RemoteCategoryRepository(transport: transport))
        let credit = CreditModel(repository: RemoteCreditRepository(transport: transport))
        let transactionRepository = RemoteTransactionRepository(transport: transport)
        let transactions = TransactionsModel(repository: transactionRepository, accounts: accounts, categories: categories, credit: credit)
        let installments = InstallmentModel(repository: RemoteInstallmentRepository(transport: transport), transactions: transactionRepository, credit: credit, transactionList: transactions)
        let reimbursements = ReimbursementModel(repository: RemoteReimbursementRepository(transport: transport), transactions: transactions, accounts: accounts)
        let reports = ReportingModel(repository: RemoteReportingRepository(transport: transport))
        let aiProposals = AIProposalModel(repository: RemoteAIProposalRepository(transport: transport), transactions: transactions, reports: reports)
        _connection = State(initialValue: ConnectionModel(client: SystemStatusClient(baseURL: baseURL)))
        _accounts = State(initialValue: accounts)
        _categories = State(initialValue: categories)
        _credit = State(initialValue: credit)
        _installments = State(initialValue: installments)
        _transactions = State(initialValue: transactions)
        _reimbursements = State(initialValue: reimbursements)
        _reports = State(initialValue: reports)
        _aiProposals = State(initialValue: aiProposals)
        _aiSettings = State(initialValue: AISettingsModel(repository: RemoteAISettingsRepository(transport: transport)))
    }

    var body: some Scene {
        WindowGroup {
            IOSRootView(connection: connection, accounts: accounts, categories: categories, transactions: transactions, credit: credit, installments: installments, reimbursements: reimbursements, reports: reports, aiProposals: aiProposals, aiSettings: aiSettings)
                .tint(FiscalColor.accent)
                .preferredColorScheme(.light)
                .task {
                    await connection.configureAndRefresh(bootstrapToken: APIConfiguration.bootstrapDeviceToken())
                    if case .connected = connection.phase {
                        async let reportLoad: Void = reports.loadAll()
                        async let proposalLoad: Void = aiProposals.load()
                        async let settingsLoad: Void = aiSettings.load()
                        _ = await (reportLoad, proposalLoad, settingsLoad)
                    }
                }
        }
    }
}
