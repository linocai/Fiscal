import FiscalKit
import SwiftUI

@main
struct FiscaliOSApp: App {
    @State private var connection: ConnectionModel
    @State private var accounts: AccountsModel
    @State private var categories: CategoriesModel

    init() {
        let baseURL = APIConfiguration.baseURL()
        let transport = APITransport(baseURL: baseURL)
        _connection = State(initialValue: ConnectionModel(client: SystemStatusClient(baseURL: baseURL)))
        _accounts = State(initialValue: AccountsModel(repository: RemoteAccountRepository(transport: transport)))
        _categories = State(initialValue: CategoriesModel(repository: RemoteCategoryRepository(transport: transport)))
    }

    var body: some Scene {
        WindowGroup {
            IOSRootView(connection: connection, accounts: accounts, categories: categories)
                .tint(FiscalColor.accent)
                .preferredColorScheme(.light)
                .task { await connection.configureAndRefresh(bootstrapToken: APIConfiguration.bootstrapDeviceToken()) }
        }
    }
}
