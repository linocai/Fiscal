import FiscalKit
import SwiftUI

/// Isolated local-network launch target for the formal V15 composition.  It
/// cannot share the formal macOS bundle or any Gallery fixture surface.
@main
struct V15RootSmokemacOSApp: App {
    private static let keychainServicePrefix = "com.linotsai.fiscal.v15-root-smoke.macos.access."
    private let services: V15Services
    private let accessKeyStore: AccessKeyStore
    private let offlineSnapshots: OfflineSnapshotStore
    private let cleanupOnly: Bool

    init() {
        let environment = ProcessInfo.processInfo.environment
        // Keep the production-shaped loopback URL so a forced transport
        // failure uses the same encrypted offline-snapshot cache key as the
        // preceding online launch.
        let baseURL = APIConfiguration.baseURL()
        let session: URLSession
        if environment["FISCAL_ROOT_SMOKE_FORCE_TRANSPORT_ERROR"] == "1" {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [V15RootSmokemacOSFailingURLProtocol.self]
            session = URLSession(configuration: configuration)
        } else {
            session = .shared
        }
        let bundleIdentifier = Bundle.main.bundleIdentifier
        let keychainService = environment["FISCAL_ROOT_SMOKE_KEYCHAIN_SERVICE"]
            ?? "\(Self.keychainServicePrefix)manual"
        precondition(["127.0.0.1", "localhost"].contains(baseURL.host), "RootSmoke must use a loopback API")
        precondition(bundleIdentifier != "com.linotsai.fiscal.mac", "RootSmoke must not use the formal bundle")
        precondition(keychainService.hasPrefix(Self.keychainServicePrefix), "RootSmoke must use a QA-only Keychain service")
        accessKeyStore = AccessKeyStore(service: keychainService)
        offlineSnapshots = OfflineSnapshotStore(
            directory: FileManager.default.temporaryDirectory
                .appending(path: "FiscalRootSmoke/\(keychainService)", directoryHint: .isDirectory),
            keyStore: SnapshotKeyStore(service: "\(keychainService).offline-snapshot")
        )
        cleanupOnly = environment["FISCAL_ROOT_SMOKE_CLEANUP_ONLY"] == "1"
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
            } else {
                MacRootView(services: services, bootstrapAccessKey: APIConfiguration.bootstrapAccessKey())
            }
        }
        .defaultSize(width: 1_280, height: 820)
    }
}

/// Keeps the loopback cache key intact while deterministically failing requests.
private final class V15RootSmokemacOSFailingURLProtocol: URLProtocol {
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
