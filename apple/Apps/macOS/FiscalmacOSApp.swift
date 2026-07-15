import FiscalKit
import SwiftUI

@main
struct FiscalmacOSApp: App {
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
            MacRootView(connection: connection, accounts: accounts, categories: categories)
                .tint(FiscalColor.accent)
                .preferredColorScheme(.light)
                .frame(minWidth: 940, minHeight: 700)
                .task { await connection.configureAndRefresh(bootstrapToken: APIConfiguration.bootstrapDeviceToken()) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 940, height: 700)
    }
}
