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
    private let formalFixture: Bool
    private let formalFixtureRoute: String
    private let preferredScheme: ColorScheme?

    init() {
        let environment = ProcessInfo.processInfo.environment
        let baseURL = APIConfiguration.baseURL()
        let session: URLSession
        if environment["FISCAL_ROOT_SMOKE_FORCE_TRANSPORT_ERROR"] == "1" {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [V15RootSmokeFailingURLProtocol.self]
            session = URLSession(configuration: configuration)
        } else {
            session = .shared
        }
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
        formalFixture = environment["FISCAL_ROOT_SMOKE_FORMAL_FIXTURE"] == "1"
        formalFixtureRoute = environment["FISCAL_ROOT_SMOKE_FORMAL_BOUNDARY"] == "1"
            ? "today-root-workspace-boundary"
            : "today-root-workspace"
        preferredScheme = environment["FISCAL_ROOT_SMOKE_COLOR_SCHEME"] == "dark" ? .dark : environment["FISCAL_ROOT_SMOKE_COLOR_SCHEME"] == "light" ? .light : nil
        let revisionStore = DataRevisionStore()
        services = V15Services(
            baseURL: baseURL,
            session: session,
            accessKeyStore: accessKeyStore,
            offlineSnapshots: offlineSnapshots,
            revisionStore: revisionStore
        )
    }

    var body: some Scene {
        WindowGroup {
            if cleanupOnly {
                V15RootSmokeCleanupView(accessKeyStore: accessKeyStore, offlineSnapshots: offlineSnapshots)
            } else if formalFixture {
                // Test-only host: this is the actual formal workspace, fed by
                // deterministic read-only facts rather than the Gallery shell.
                V151IOSWorkspace(services: V15F2BFixtures.services(route: formalFixtureRoute))
                    .preferredColorScheme(preferredScheme)
            } else {
                IOSRootView(services: services, bootstrapAccessKey: APIConfiguration.bootstrapAccessKey())
            }
        }
    }
}

/// Keeps the production-shaped loopback URL (and therefore the same encrypted
/// snapshot cache key) while deterministically simulating a transport outage.
private final class V15RootSmokeFailingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
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
