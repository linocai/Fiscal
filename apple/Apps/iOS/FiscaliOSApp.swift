import FiscalKit
import SwiftUI

@main
struct FiscaliOSApp: App {
    @State private var connection = ConnectionModel(
        client: SystemStatusClient(baseURL: APIConfiguration.baseURL())
    )

    var body: some Scene {
        WindowGroup {
            IOSRootView(connection: connection)
                .tint(FiscalColor.accent)
                .preferredColorScheme(.light)
                .task { await connection.configureAndRefresh(bootstrapToken: APIConfiguration.bootstrapDeviceToken()) }
        }
    }
}
