import Foundation
import Observation

@MainActor
@Observable
public final class ConnectionModel {
    public enum Phase: Sendable, Equatable {
        case idle
        case loading
        case connected(SystemStatus)
        case unauthorized
        case offline(String)
    }

    public private(set) var phase: Phase = .idle
    private let client: SystemStatusClient

    public init(client: SystemStatusClient) {
        self.client = client
    }

    public func refresh() async {
        phase = .loading
        do {
            phase = .connected(try await client.fetch())
        } catch APIClientError.unauthorized {
            phase = .unauthorized
        } catch {
            phase = .offline(error.localizedDescription)
        }
    }

    public func configure(bootstrapToken: String?) async {
        if let bootstrapToken, !bootstrapToken.isEmpty {
            do {
                try await client.saveBootstrapTokenIfMissing(bootstrapToken)
            } catch {
                phase = .offline("无法安全保存设备密钥")
                return
            }
        }
    }
}
