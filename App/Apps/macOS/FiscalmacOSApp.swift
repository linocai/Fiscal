import FiscalKit
import SwiftUI

@main
struct FiscalmacOSApp: App {
    private let services: V15Services

    init() {
        let baseURL = APIConfiguration.baseURL()
        let accessKeyStore = AccessKeyStore()
        let revisions = DataRevisionStore()
        services = V15Services(
            baseURL: baseURL,
            accessKeyStore: accessKeyStore,
            revisionStore: revisions
        )
    }

    var body: some Scene {
        WindowGroup {
            MacRootView(
                services: services,
                bootstrapAccessKey: APIConfiguration.bootstrapAccessKey()
            )
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_440, height: 900)
    }
}
