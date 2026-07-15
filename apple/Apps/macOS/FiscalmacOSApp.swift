import FiscalKit
import SwiftUI

@main
struct FiscalmacOSApp: App {
    @State private var connection: ConnectionModel
    @State private var accounts: AccountsModel
    @State private var categories: CategoriesModel
    @State private var transactions: TransactionsModel

    init() {
        let baseURL = APIConfiguration.baseURL()
        let transport = APITransport(baseURL: baseURL)
        let accounts = AccountsModel(repository: RemoteAccountRepository(transport: transport))
        let categories = CategoriesModel(repository: RemoteCategoryRepository(transport: transport))
        _connection = State(initialValue: ConnectionModel(client: SystemStatusClient(baseURL: baseURL)))
        _accounts = State(initialValue: accounts)
        _categories = State(initialValue: categories)
        _transactions = State(initialValue: TransactionsModel(repository: RemoteTransactionRepository(transport: transport), accounts: accounts, categories: categories))
    }

    var body: some Scene {
        WindowGroup {
            MacRootView(connection: connection, accounts: accounts, categories: categories, transactions: transactions)
                .tint(FiscalColor.accent)
                .preferredColorScheme(.light)
                .frame(minWidth: 940, minHeight: 700)
                .task { await connection.configureAndRefresh(bootstrapToken: APIConfiguration.bootstrapDeviceToken()) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 940, height: 700)
    }
}
