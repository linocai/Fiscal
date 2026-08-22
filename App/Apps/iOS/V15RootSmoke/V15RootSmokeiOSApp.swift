import FiscalKit
import SwiftUI

/// Isolated local-network launch target for the formal V15 composition.  This
/// target intentionally shares `V15IOSLiveAppShell` with FiscaliOS while its
/// bundle, Keychain policy and API endpoint remain QA-only.
@main
struct V15RootSmokeiOSApp: App {
    private static let keychainServicePrefix = "com.linotsai.fiscal.v15-root-smoke.ios.access."
    private let services: V15Services
    private let accessKeyStore: AccessKeyStore
    private let offlineSnapshots: OfflineSnapshotStore
    private let cleanupOnly: Bool

    init() {
        let environment = ProcessInfo.processInfo.environment
        let baseURL = environment["FISCAL_ROOT_SMOKE_FORCE_TRANSPORT_ERROR"] == "1"
            ? URL(string: "http://127.0.0.1:1")!
            : APIConfiguration.baseURL()
        let bundleIdentifier = Bundle.main.bundleIdentifier
        let policy = APIConfiguration.iOSAccessKeyPolicy(bundleIdentifier: bundleIdentifier)
        let keychainService = environment["FISCAL_ROOT_SMOKE_KEYCHAIN_SERVICE"]
            ?? "\(Self.keychainServicePrefix)manual"
        precondition(["127.0.0.1", "localhost"].contains(baseURL.host), "RootSmoke must use a loopback API")
        precondition(bundleIdentifier != "com.linotsai.fiscal", "RootSmoke must not use the formal bundle")
        precondition(policy.accessGroup == nil, "RootSmoke must not use the formal Keychain group")
        precondition(keychainService.hasPrefix(Self.keychainServicePrefix), "RootSmoke must use a QA-only Keychain service")
        accessKeyStore = AccessKeyStore(
            service: keychainService,
            accessGroup: policy.accessGroup,
            prefersSynchronizable: policy.prefersSynchronizable
        )
        offlineSnapshots = OfflineSnapshotStore(
            directory: FileManager.default.temporaryDirectory
                .appending(path: "FiscalRootSmoke/\(keychainService)", directoryHint: .isDirectory),
            keyStore: SnapshotKeyStore(service: "\(keychainService).offline-snapshot")
        )
        cleanupOnly = environment["FISCAL_ROOT_SMOKE_CLEANUP_ONLY"] == "1"
        let revisionStore = DataRevisionStore()
        services = V15Services(
            baseURL: baseURL,
            accessKeyStore: accessKeyStore,
            offlineSnapshots: offlineSnapshots,
            revisionStore: revisionStore
        )
    }

    var body: some Scene {
        WindowGroup {
            if cleanupOnly {
                V15RootSmokeCleanupView(accessKeyStore: accessKeyStore, offlineSnapshots: offlineSnapshots)
            } else {
                IOSRootView(services: services, bootstrapAccessKey: APIConfiguration.bootstrapAccessKey())
            }
        }
    }
}

private struct V15RootSmokeCleanupView: View {
    let accessKeyStore: AccessKeyStore
    let offlineSnapshots: OfflineSnapshotStore
    @State private var state = CleanupState.running

    var body: some View {
        Text(state.message)
            .accessibilityIdentifier(state.accessibilityIdentifier)
            .task {
                do {
                    await offlineSnapshots.removeAll()
                    try await accessKeyStore.delete()
                    state = .complete
                } catch {
                    state = .failed
                }
            }
    }

    private enum CleanupState {
        case running
        case complete
        case failed

        var message: String {
            switch self {
            case .running: "RootSmoke cleanup running"
            case .complete: "RootSmoke cleanup complete"
            case .failed: "RootSmoke cleanup failed"
            }
        }

        var accessibilityIdentifier: String {
            switch self {
            case .running: "v15.rootsmoke.cleanup.running"
            case .complete: "v15.rootsmoke.cleanup.complete"
            case .failed: "v15.rootsmoke.cleanup.failed"
            }
        }
    }
}
