import Foundation
import Observation

/// The F3-A boundary: a server-owned, revision-bound list of known future
/// events.  It intentionally has no write capability and never derives a
/// forecast from the returned rows.
@MainActor @Observable
public final class V15FutureTimelineModel {
    public enum Phase { case idle, loading, loaded, empty, failed(V15Failure), requiresReload(V15Failure) }
    public enum PagePhase { case idle, loading, failed(V15Failure) }
    public enum AccountOptionsPhase { case idle, loading, loaded, empty, failed(V15Failure) }
    public enum InspectorPhase { case idle, showing(V15FutureEvent), unavailable(String) }

    public private(set) var phase: Phase = .idle
    public private(set) var pagePhase: PagePhase = .idle
    public private(set) var inspectorPhase: InspectorPhase = .idle
    public private(set) var events: [V15FutureEvent] = []
    public private(set) var meta: V15FactsMeta?
    public private(set) var serverWindow: V15BusinessDateRange?
    public private(set) var pageFailure: V15Failure?
    public private(set) var selectedWindowDays = 30
    public private(set) var selectedAccountID: UUID?
    public private(set) var accountOptions: [V15AccountResponse] = []
    public private(set) var accountOptionsPhase: AccountOptionsPhase = .idle
    public private(set) var requiresFreshReload = false
    public private(set) var requiredRevision: Int64?

    private let services: V15Services
    private let offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)?
    private var generation: UInt64 = 0
    private var accountOptionsGeneration: UInt64 = 0
    private var nextCursor: String?
    private var pageRevision: Int64?

    public init(services: V15Services, offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)? = nil) {
        self.services = services
        self.offlineSnapshotProvider = offlineSnapshotProvider
    }

    public var offlineSnapshotAt: Date? { offlineSnapshotProvider?() ?? services.offlineSnapshotAt }
    public var isOffline: Bool { offlineSnapshotAt != nil }
    public var hasNextPage: Bool { nextCursor != nil }
    public var isLoadingNextPage: Bool { if case .loading = pagePhase { return true }; return false }
    public var isLoadingAccountOptions: Bool { if case .loading = accountOptionsPhase { return true }; return false }
    public var selectedAccountDisplayName: String? { accountOptions.first(where: { $0.id == selectedAccountID })?.name }

    public func setWindowDays(_ value: Int) async {
        guard [7, 30, 60, 90].contains(value) else { return }
        selectedWindowDays = value
        await reload()
    }

    public func setAccount(_ value: UUID?) async {
        selectedAccountID = value
        await reload()
    }

    /// Account options are their own authoritative F1 typed read. They are not
    /// inferred from whatever a bounded timeline page happens to contain.
    public func loadAccountOptions() async {
        accountOptionsGeneration &+= 1
        let current = accountOptionsGeneration
        accountOptionsPhase = .loading
        do {
            let accounts = try await services.masterData.activeAccounts()
            guard current == accountOptionsGeneration else { return }
            accountOptions = accounts.filter(\.isActive).sorted { $0.sortOrder == $1.sortOrder ? $0.name < $1.name : $0.sortOrder < $1.sortOrder }
            accountOptionsPhase = accountOptions.isEmpty ? .empty : .loaded
        } catch is CancellationError {
            guard current == accountOptionsGeneration else { return }
            accountOptionsPhase = .idle
        } catch let failure as V15Failure {
            guard current == accountOptionsGeneration else { return }
            accountOptionsPhase = .failed(failure)
        } catch {
            guard current == accountOptionsGeneration else { return }
            accountOptionsPhase = .failed(.init(kind: .transport, message: "可筛选账户读取失败。"))
        }
    }

    public func retryAccountOptions() async { await loadAccountOptions() }

    /// A reload always abandons an old opaque cursor. After a scope conflict it
    /// additionally bypasses the read cache and refuses an older revision.
    public func reload() async {
        generation &+= 1
        let current = generation
        events = []; meta = nil; serverWindow = nil; nextCursor = nil; pageFailure = nil; pagePhase = .idle; inspectorPhase = .idle
        phase = .loading
        await read(cursor: nil, appending: false, generation: current, policy: requiresFreshReload ? .reloadIgnoringCache : .standard)
    }

    public func loadNextPage() async {
        guard let cursor = nextCursor, !isLoadingNextPage, !requiresFreshReload else { return }
        let current = generation
        pagePhase = .loading; pageFailure = nil
        await read(cursor: cursor, appending: true, generation: current, policy: .standard)
    }

    public func retryNextPage() async { await loadNextPage() }

    public func openInspector(_ event: V15FutureEvent) {
        guard Self.isSafeLocator(event.deepLink, event: event) else {
            inspectorPhase = .unavailable("链接不符合当前只读安全规则，未发起请求。")
            return
        }
        inspectorPhase = .showing(event)
    }

    public func closeInspector() { inspectorPhase = .idle }

    private func read(cursor: String?, appending: Bool, generation candidate: UInt64, policy: V15ReadCachePolicy) async {
        do {
            let page = try await services.reports.futureEvents(windowDays: selectedWindowDays, accountID: selectedAccountID, cursor: cursor, limit: 50, readCachePolicy: policy)
            guard candidate == generation else { return }
            guard valid(page), (!appending || page.meta.dataRevision == pageRevision) else {
                takeScopeConflict(.init(kind: .conflict, code: "future_events_scope_changed", message: "未来时间线范围已变化，请重新读取。"), generation: candidate)
                return
            }
            if let requiredRevision, page.meta.dataRevision < requiredRevision {
                takeScopeConflict(.init(kind: .conflict, code: "future_events_scope_changed", message: "服务器尚未返回所需的新版本，请重新读取。"), generation: candidate)
                return
            }
            meta = page.meta; serverWindow = page.window; pageRevision = page.meta.dataRevision; requiredRevision = nil; requiresFreshReload = false
            events = appending ? events + page.items : page.items
            nextCursor = page.nextCursor; pagePhase = .idle; pageFailure = nil; phase = events.isEmpty ? .empty : .loaded
        } catch let failure as V15Failure {
            guard candidate == generation else { return }
            if failure.kind == .conflict, failure.code == "future_events_scope_changed" { takeScopeConflict(failure, generation: candidate) }
            else if appending { pagePhase = failure.kind == .cancelled ? .idle : .failed(failure); pageFailure = failure.kind == .cancelled ? nil : failure }
            else { phase = failure.kind == .cancelled ? .idle : .failed(failure) }
        } catch {
            guard candidate == generation else { return }
            let failure = V15Failure(kind: .transport, message: appending ? "下一页未来事项读取失败。" : "未来时间线读取失败。")
            if appending { pagePhase = .failed(failure); pageFailure = failure } else { phase = .failed(failure) }
        }
    }

    private func valid(_ page: V15FutureEvents) -> Bool {
        page.meta.timezone == "Asia/Shanghai" && page.meta.currency == "CNY" && page.meta.schemaVersion == "1" && page.meta.dataRevision >= 0 && page.accountID == selectedAccountID
    }

    private func takeScopeConflict(_ failure: V15Failure, generation candidate: UInt64) {
        guard candidate == generation else { return }
        requiresFreshReload = true
        requiredRevision = [failure.conflict?.currentDataRevision, failure.conflict?.latestRevision].compactMap { $0 }.max()
        events = []; meta = nil; serverWindow = nil; nextCursor = nil; pageFailure = nil; pagePhase = .idle; inspectorPhase = .idle
        phase = .requiresReload(failure)
    }

    /// Strict source-aware local routes. Query/fragment, host aliases and
    /// arbitrary paths never enter the inspector and never trigger a request.
    public static func isSafeLocator(_ raw: String, event: V15FutureEvent) -> Bool {
        guard let c = URLComponents(string: raw), c.scheme == "fiscal", c.user == nil, c.password == nil, c.port == nil, c.percentEncodedQuery == nil, c.percentEncodedFragment == nil, !c.path.contains("//") else { return false }
        let parts = c.path.split(separator: "/").map(String.init)
        func matchesUUID(_ value: String, _ id: UUID) -> Bool { UUID(uuidString: value) == id }
        func hasTwoSegmentPath(_ prefix: String, _ id: UUID) -> Bool {
            parts.count == 2 && parts[0] == prefix && matchesUUID(parts[1], id)
        }
        switch event.sourceType {
        case .creditCycle:
            return c.host == "credit" && event.cycleID == event.sourceID && hasTwoSegmentPath("cycles", event.sourceID)
        case .reimbursementParty:
            guard let claimID = event.claimID, event.partyID == event.sourceID else { return false }
            return c.host == "reimbursements" && parts.count == 3 && matchesUUID(parts[0], claimID) && parts[1] == "parties" && matchesUUID(parts[2], event.sourceID)
        case .cashFlowItem:
            return c.host == "cash-flow" && hasTwoSegmentPath("items", event.sourceID)
        }
    }
}
