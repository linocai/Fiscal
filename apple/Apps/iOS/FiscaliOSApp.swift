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
    @State private var overview: ReportingModel
    @State private var cashFlow: FutureCashFlowModel
    @State private var aiProposals: AIProposalModel
    @State private var aiSettings: AISettingsModel
    @State private var passphrase: PassphraseModel
    @State private var recordingPreferences = RecordingPreferences()

    init() {
        let baseURL = APIConfiguration.baseURL()
        let accessKeyStore = AccessKeyStore(accessGroup: "HX73DFL88G.com.linotsai.fiscal")
        // Transition bridge: the still-valid legacy device token authorizes the one-time
        // set-passphrase call. Removed with the device_tokens table next release.
        let legacyTokenStore = KeychainTokenStore(accessGroup: "HX73DFL88G.com.linotsai.fiscal")
        let transport = APITransport(baseURL: baseURL, accessKeyStore: accessKeyStore)
        let accounts = AccountsModel(repository: RemoteAccountRepository(transport: transport))
        let categories = CategoriesModel(repository: RemoteCategoryRepository(transport: transport))
        let credit = CreditModel(repository: RemoteCreditRepository(transport: transport))
        let cashFlow = FutureCashFlowModel(repository: RemoteFutureCashFlowRepository(transport: transport))
        let transactionRepository = RemoteTransactionRepository(transport: transport)
        let reports = ReportingModel(repository: RemoteReportingRepository(transport: transport))
        // A dedicated overview model so the always-current-month home view never resets the month
        // (or drill-down) the user navigated to on the reports page.
        let overview = ReportingModel(repository: RemoteReportingRepository(transport: transport))
        let reporting = ReportingInvalidationCoordinator(overview: overview, spending: reports)
        let transactions = TransactionsModel(repository: transactionRepository, accounts: accounts, categories: categories, credit: credit, cashFlow: cashFlow, reporting: reporting)
        let installments = InstallmentModel(repository: RemoteInstallmentRepository(transport: transport), transactions: transactionRepository, credit: credit, transactionList: transactions, cashFlow: cashFlow, reporting: reporting)
        let reimbursements = ReimbursementModel(repository: RemoteReimbursementRepository(transport: transport), transactions: transactions, accounts: accounts, reporting: reporting)
        let aiProposals = AIProposalModel(repository: RemoteAIProposalRepository(transport: transport), transactions: transactions, reporting: reporting, cashFlow: cashFlow)
        _connection = State(initialValue: ConnectionModel(client: SystemStatusClient(baseURL: baseURL, accessKeyStore: accessKeyStore)))
        _passphrase = State(initialValue: PassphraseModel(
            repository: RemoteAuthRepository(transport: transport),
            accessKeyStore: accessKeyStore, legacyTokenStore: legacyTokenStore))
        _accounts = State(initialValue: accounts)
        _categories = State(initialValue: categories)
        _credit = State(initialValue: credit)
        _installments = State(initialValue: installments)
        _transactions = State(initialValue: transactions)
        _reimbursements = State(initialValue: reimbursements)
        _reports = State(initialValue: reports)
        _overview = State(initialValue: overview)
        _cashFlow = State(initialValue: cashFlow)
        _aiProposals = State(initialValue: aiProposals)
        _aiSettings = State(initialValue: AISettingsModel(repository: RemoteAISettingsRepository(transport: transport)))
    }

    var body: some Scene {
        WindowGroup {
            IOSRootView(connection: connection, accounts: accounts, categories: categories, transactions: transactions, credit: credit, installments: installments, reimbursements: reimbursements, reports: reports, overview: overview, cashFlow: cashFlow, aiProposals: aiProposals, aiSettings: aiSettings, passphrase: passphrase, recordingPreferences: recordingPreferences)
                .tint(FiscalColor.accent)
                .task {
                    await connection.configure(bootstrapAccessKey: APIConfiguration.bootstrapAccessKey())
                    await refreshConnectedContent()
                }
        }
    }

    private func refreshConnectedContent() async {
        await connection.refresh()
        guard case .connected = connection.phase else { return }
        async let reportLoad: Void = reports.loadSpending()
        async let overviewLoad: Void = overview.loadOverview()
        async let cashFlowLoad: Void = cashFlow.load()
        async let proposalLoad: Void = aiProposals.load()
        async let settingsLoad: Void = aiSettings.load()
        _ = await (reportLoad, overviewLoad, cashFlowLoad, proposalLoad, settingsLoad)
    }
}
