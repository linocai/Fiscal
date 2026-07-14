import FiscalKit
import SwiftUI

@main
struct FiscalmacOSApp: App {
    @State private var connection = ConnectionModel(
        client: SystemStatusClient(baseURL: APIConfiguration.baseURL())
    )

    var body: some Scene {
        WindowGroup {
            MacRootView(connection: connection)
                .tint(FiscalColor.accent)
                .preferredColorScheme(.light)
                .frame(minWidth: 940, minHeight: 700)
                .task { await connection.configureAndRefresh(bootstrapToken: APIConfiguration.bootstrapDeviceToken()) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 940, height: 700)
    }
}
