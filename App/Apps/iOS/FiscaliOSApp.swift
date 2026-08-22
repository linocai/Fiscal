import FiscalKit
import SwiftUI

@main
struct FiscaliOSApp: App {
    @UIApplicationDelegateAdaptor(FiscalAppDelegate.self) private var appDelegate
    private let services: V15Services

    init() {
        let baseURL = APIConfiguration.baseURL()
        let policy = APIConfiguration.iOSAccessKeyPolicy(bundleIdentifier: Bundle.main.bundleIdentifier)
        let accessKeyStore = AccessKeyStore(
            accessGroup: policy.accessGroup,
            prefersSynchronizable: policy.prefersSynchronizable
        )
        let revisions = DataRevisionStore()
        services = V15Services(
            baseURL: baseURL,
            accessKeyStore: accessKeyStore,
            revisionStore: revisions
        )
    }

    var body: some Scene {
        WindowGroup {
            IOSRootView(
                services: services,
                bootstrapAccessKey: APIConfiguration.bootstrapAccessKey()
            )
        }
    }
}
