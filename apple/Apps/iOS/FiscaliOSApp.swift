import FiscalKit
import SwiftUI

@main
struct FiscaliOSApp: App {
    @State private var connection: ConnectionModel
    @State private var accounts: AccountsModel
    @State private var categories: CategoriesModel
    @State private var transactions: TransactionsModel
    @State private var credit: CreditModel

    init() {
        let baseURL = APIConfiguration.baseURL()
        let transport = APITransport(baseURL: baseURL)
        let accounts = AccountsModel(repository: RemoteAccountRepository(transport: transport))
        let categories = CategoriesModel(repository: RemoteCategoryRepository(transport: transport))
        let credit = CreditModel(repository: RemoteCreditRepository(transport: transport))
        _connection = State(initialValue: ConnectionModel(client: SystemStatusClient(baseURL: baseURL)))
        _accounts = State(initialValue: accounts)
        _categories = State(initialValue: categories)
        _credit = State(initialValue: credit)
        _transactions = State(initialValue: TransactionsModel(repository: RemoteTransactionRepository(transport: transport), accounts: accounts, categories: categories, credit: credit))
    }

    var body: some Scene {
        WindowGroup {
            IOSRootView(connection: connection, accounts: accounts, categories: categories, transactions: transactions, credit: credit)
                .tint(FiscalColor.accent)
                .preferredColorScheme(.light)
                .task { await connection.configureAndRefresh(bootstrapToken: APIConfiguration.bootstrapDeviceToken()) }
        }
    }
}
