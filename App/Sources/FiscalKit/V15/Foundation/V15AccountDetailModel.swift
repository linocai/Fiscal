import Foundation
import Observation

@MainActor @Observable
public final class V15AccountDetailModel {
    public enum Phase: Equatable { case idle, loading, loaded, failed(V15Failure) }
    public private(set) var phase: Phase = .idle
    public private(set) var account: V15AccountResponse?
    private let services: V15Services
    private var generation: UInt64 = 0
    private var ownerID: UUID?

    public init(services: V15Services) { self.services = services }

    public func load(accountID: UUID, fresh: Bool = false) async {
        generation &+= 1; let current = generation; ownerID = accountID
        account = nil; phase = .loading
        let policy: V15ReadCachePolicy = fresh ? .reloadIgnoringCache : .standard
        do {
            let value = try await services.masterData.account(id: accountID, readCachePolicy: policy)
            guard current == generation, ownerID == accountID else { return }
            account = value
            phase = .loaded
        } catch let failure as V15Failure {
            guard current == generation, ownerID == accountID else { return }
            phase = failure.kind == .cancelled ? .idle : .failed(failure)
        } catch {
            guard current == generation, ownerID == accountID else { return }
            phase = .failed(.init(kind: .transport, message: "暂时无法取得账户信息。"))
        }
    }

    public func clear() { generation &+= 1; ownerID = nil; account = nil; phase = .idle }
}
