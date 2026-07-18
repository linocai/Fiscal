import FiscalKit
import AppKit
import SwiftUI

@main
struct FiscalmacOSApp: App {
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
    @State private var deviceSecurity: DeviceSecurityModel
    @State private var recordingPreferences = RecordingPreferences()

    init() {
        let baseURL = APIConfiguration.baseURL()
        let tokenStore = KeychainTokenStore()
        let transport = APITransport(baseURL: baseURL, tokenStore: tokenStore)
        let accounts = AccountsModel(repository: RemoteAccountRepository(transport: transport))
        let categories = CategoriesModel(repository: RemoteCategoryRepository(transport: transport))
        let credit = CreditModel(repository: RemoteCreditRepository(transport: transport))
        let cashFlow = FutureCashFlowModel(repository: RemoteFutureCashFlowRepository(transport: transport))
        let transactionRepository = RemoteTransactionRepository(transport: transport)
        let transactions = TransactionsModel(repository: transactionRepository, accounts: accounts, categories: categories, credit: credit, cashFlow: cashFlow)
        let installments = InstallmentModel(repository: RemoteInstallmentRepository(transport: transport), transactions: transactionRepository, credit: credit, transactionList: transactions, cashFlow: cashFlow)
        let reimbursements = ReimbursementModel(repository: RemoteReimbursementRepository(transport: transport), transactions: transactions, accounts: accounts)
        let reports = ReportingModel(repository: RemoteReportingRepository(transport: transport))
        // A dedicated overview model so the always-current-month home view never resets the month
        // (or drill-down) the user navigated to on the reports page.
        let overview = ReportingModel(repository: RemoteReportingRepository(transport: transport))
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
        _overview = State(initialValue: overview)
        _cashFlow = State(initialValue: cashFlow)
        _aiProposals = State(initialValue: aiProposals)
        _aiSettings = State(initialValue: AISettingsModel(repository: RemoteAISettingsRepository(transport: transport)))
    }

    var body: some Scene {
        WindowGroup {
            MacRootView(connection: connection, accounts: accounts, categories: categories, transactions: transactions, credit: credit, installments: installments, reimbursements: reimbursements, reports: reports, overview: overview, cashFlow: cashFlow, aiProposals: aiProposals, aiSettings: aiSettings, deviceSecurity: deviceSecurity, recordingPreferences: recordingPreferences, cache: .shared)
                .tint(FiscalColor.accent)
                .frame(minWidth: 1_040, minHeight: 700)
                .background(
                    WindowSizeLimits(
                        minimum: NSSize(width: 1_040, height: 700),
                        maximum: NSSize(width: 1_600, height: 920)
                    )
                )
                .task {
                    await connection.configure(bootstrapToken: APIConfiguration.bootstrapDeviceToken())
                    _ = await deviceSecurity.recoverPendingRotation()
                    await connection.refresh()
                    if case .connected = connection.phase {
                        async let reportLoad: Void = reports.loadAll()
                        async let overviewLoad: Void = overview.loadAll()
                        async let cashFlowLoad: Void = cashFlow.load()
                        async let proposalLoad: Void = aiProposals.load()
                        async let settingsLoad: Void = aiSettings.load()
                        _ = await (reportLoad, overviewLoad, cashFlowLoad, proposalLoad, settingsLoad)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_280, height: 820)
    }
}

private struct WindowSizeLimits: NSViewRepresentable {
    let minimum: NSSize
    let maximum: NSSize

    func makeNSView(context: Context) -> NSView {
        SizeLimitView(minimum: minimum, maximum: maximum)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class SizeLimitView: NSView {
    private let minimum: NSSize
    private let maximum: NSSize

    init(minimum: NSSize, maximum: NSSize) {
        self.minimum = minimum
        self.maximum = maximum
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.contentMinSize = minimum
        window.contentMaxSize = maximum
        let contentSize = window.contentLayoutRect.size
        if contentSize.width > maximum.width || contentSize.height > maximum.height {
            window.setContentSize(
                NSSize(
                    width: min(contentSize.width, maximum.width),
                    height: min(contentSize.height, maximum.height)
                )
            )
        }
    }
}
