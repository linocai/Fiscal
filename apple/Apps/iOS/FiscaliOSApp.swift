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
    @State private var cashFlow: FutureCashFlowModel
    @State private var aiProposals: AIProposalModel
    @State private var aiSettings: AISettingsModel
    @State private var deviceSecurity: DeviceSecurityModel
    @State private var recordingPreferences = RecordingPreferences()

    init() {
        let baseURL = APIConfiguration.baseURL()
        let tokenStore = KeychainTokenStore()
        let transport = APITransport(baseURL: baseURL, tokenStore: tokenStore)
        let accounts = AccountsModel(repository: RemoteAccountRepository(transport: transport))
        let categories = CategoriesModel(repository: RemoteCategoryRepository(transport: transport))
        let credit = CreditModel(repository: RemoteCreditRepository(transport: transport))
        let transactionRepository = RemoteTransactionRepository(transport: transport)
        let transactions = TransactionsModel(repository: transactionRepository, accounts: accounts, categories: categories, credit: credit)
        let installments = InstallmentModel(repository: RemoteInstallmentRepository(transport: transport), transactions: transactionRepository, credit: credit, transactionList: transactions)
        let reimbursements = ReimbursementModel(repository: RemoteReimbursementRepository(transport: transport), transactions: transactions, accounts: accounts)
        let reports = ReportingModel(repository: RemoteReportingRepository(transport: transport))
        let cashFlow = FutureCashFlowModel(repository: RemoteFutureCashFlowRepository(transport: transport))
        let aiProposals = AIProposalModel(repository: RemoteAIProposalRepository(transport: transport), transactions: transactions, reports: reports, cashFlow: cashFlow)
        _connection = State(initialValue: ConnectionModel(client: SystemStatusClient(baseURL: baseURL, tokenStore: tokenStore)))
        _deviceSecurity = State(initialValue: DeviceSecurityModel(
            repository: RemoteDeviceSecurityRepository(transport: transport), tokenStore: tokenStore))
        _accounts = State(initialValue: accounts)
        _categories = State(initialValue: categories)
        _credit = State(initialValue: credit)
        _installments = State(initialValue: installments)
        _transactions = State(initialValue: transactions)
        _reimbursements = State(initialValue: reimbursements)
        _reports = State(initialValue: reports)
        _cashFlow = State(initialValue: cashFlow)
        _aiProposals = State(initialValue: aiProposals)
        _aiSettings = State(initialValue: AISettingsModel(repository: RemoteAISettingsRepository(transport: transport)))
    }

    var body: some Scene {
        WindowGroup {
            IOSRootView(connection: connection, accounts: accounts, categories: categories, transactions: transactions, credit: credit, installments: installments, reimbursements: reimbursements, reports: reports, cashFlow: cashFlow, aiProposals: aiProposals, aiSettings: aiSettings, deviceSecurity: deviceSecurity, recordingPreferences: recordingPreferences)
                .tint(FiscalColor.accent)
                .task {
                    await connection.configure(bootstrapToken: APIConfiguration.bootstrapDeviceToken())
                    _ = await deviceSecurity.recoverPendingRotation()
                    await connection.refresh()
                    if case .connected = connection.phase {
                        async let reportLoad: Void = reports.loadAll()
                        async let cashFlowLoad: Void = cashFlow.load()
                        async let proposalLoad: Void = aiProposals.load()
                        async let settingsLoad: Void = aiSettings.load()
                        _ = await (reportLoad, cashFlowLoad, proposalLoad, settingsLoad)
                    }
                }
        }
    }
}
