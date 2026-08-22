import Foundation
import Observation

@MainActor @Observable
public final class V15BootstrapModel {
    public enum Phase: Equatable {
        case idle, loading, needsPassphrase, passphraseNotSet, wrongPassphrase, systemNotReady, ready, offlineReadOnly(Date), failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var authStatus: V15AuthStatus?
    public private(set) var systemStatus: V15SystemStatus?
    public private(set) var error: V15Failure?
    private let services: V15Services
    private var generation: UInt64 = 0

    public init(services: V15Services) { self.services = services }

    public func connect() async {
        generation &+= 1; let current = generation
        phase = .loading; error = nil
        if let snapshot = services.offlineSnapshotAt {
            guard current == generation else { return }
            phase = .offlineReadOnly(snapshot); return
        }
        do {
            let auth = try await services.session.status()
            let system = try await services.system.status()
            guard current == generation else { return }
            authStatus = auth; systemStatus = system
            phase = system.isReady ? .ready : .systemNotReady
        } catch is CancellationError {
            guard current == generation else { return }; phase = .idle
        } catch let failure as V15Failure {
            guard current == generation else { return }; apply(failure)
        } catch {
            guard current == generation else { return }; phase = .failed("无法完成连接。")
        }
    }

    public func unlock(passphrase: String) async {
        generation &+= 1; let current = generation
        phase = .loading; error = nil
        do {
            _ = try await services.session.unlock(passphrase: passphrase)
            guard current == generation else { return }
            await connect()
        } catch is CancellationError {
            guard current == generation else { return }; phase = .needsPassphrase
        } catch let failure as V15Failure {
            guard current == generation else { return }; apply(failure)
        } catch {
            guard current == generation else { return }; phase = .failed("无法验证口令。")
        }
    }

    public func retry() async { await connect() }
    public func invalidate() { generation &+= 1; error = nil; phase = .idle }

    private func apply(_ failure: V15Failure) {
        error = failure
        switch failure.code {
        case "passphrase_not_set": phase = .passphraseNotSet
        case "invalid_passphrase": phase = .wrongPassphrase
        case "authentication_required", "unauthorized", "invalid_access_key": phase = .needsPassphrase
        case "database_unavailable", "schema_state_unavailable": phase = .systemNotReady
        default: phase = .failed(failure.message)
        }
    }
}
