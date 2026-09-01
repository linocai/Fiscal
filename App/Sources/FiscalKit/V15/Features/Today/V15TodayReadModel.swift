import Foundation
import Observation

/// The F2-A state boundary for the current-facts home. It deliberately owns
/// reads only: no generic decision queue, future workflow, or legacy overview
/// path can enter through this model.
@MainActor @Observable
public final class V15TodayReadModel {
    public enum FactsPhase { case idle, loading, loaded, failed(V15Failure), requiresReload(V15Failure) }
    public enum ScopePhase { case idle, loading, loaded, empty, failed(V15Failure), requiresFactsReload(V15Failure) }
    public enum NextPagePhase { case idle, loading, failed(V15Failure) }
    public enum LinkedReadPhase {
        case idle, loading
        case requiresFactsReload(V15Failure)
        case localFactsInspector(String)
        case account(V15AccountResponse)
        case transaction(V15Transaction)
        case unavailable(String)
        case failed(V15Failure)
    }

    public private(set) var facts: V15Facts?
    public private(set) var factsPhase: FactsPhase = .idle
    public private(set) var selectedScope: V15DrillDownScope?
    public private(set) var scopeItems: [V15FactDrillDownItem] = []
    public private(set) var scopePhase: ScopePhase = .idle
    public private(set) var nextPagePhase: NextPagePhase = .idle
    public private(set) var nextPageFailure: V15Failure?
    public private(set) var linkedReadPhase: LinkedReadPhase = .idle
    public private(set) var requiresFactsReload = false
    public private(set) var requiredFactsRevision: Int64?
    /// Stable presentation reason for a server facts-scope conflict. F2-B/C
    /// can render this without inventing an action or exposing raw 409 text.
    public private(set) var factsReloadRequiredReason: V15DisabledReason?

    private let services: V15Services
    private let offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)?
    private var factsGeneration: UInt64 = 0
    private var scopeGeneration: UInt64 = 0
    private var linkGeneration: UInt64 = 0
    private var nextCursor: String?
    /// Only a parsed account/transaction locator is retained for retry. Raw
    /// unsafe or later-stage links are never stored as executable input.
    private var retryableLinkedRead: String?
    /// A facts scope conflict owns every inspector entry point until a fresh,
    /// successful facts response replaces this boundary.
    private var factsReloadFailure: V15Failure?

    public init(services: V15Services, offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)? = nil) {
        self.services = services
        self.offlineSnapshotProvider = offlineSnapshotProvider
    }

    /// Production reads the revision store dynamically: a read can fall back
    /// to an offline snapshot after this model has already been created.
    public var offlineSnapshotAt: Date? {
        if let offlineSnapshotProvider { return offlineSnapshotProvider() }
        return services.offlineSnapshotAt
    }
    public var isOffline: Bool { offlineSnapshotAt != nil }
    /// Only a server snapshot timestamp is shown in offline mode. The client
    /// deliberately has no invented stale-age threshold.
    public var offlineAsOf: Date? { isOffline ? facts?.meta.asOf : nil }
    public var hasNextPage: Bool { nextCursor != nil }
    public var isLoadingNextPage: Bool { if case .loading = nextPagePhase { return true }; return false }

    public func refresh(windowDays: Int = 30) async {
        factsGeneration &+= 1
        let currentFacts = factsGeneration
        let requiresFreshFacts = requiresFactsReload
        invalidateScopeForFactsChange()
        factsPhase = .loading
        async let factResult = services.reports.facts(windowDays: windowDays, readCachePolicy: requiresFreshFacts ? .reloadIgnoringCache : .standard)

        do {
            let result = try await factResult
            if currentFacts == factsGeneration {
                if !validFactsMeta(result.meta) {
                    facts = nil
                    if requiresFactsReload { factsPhase = .requiresReload(factsReloadFailure ?? reloadRequiredFailure()); holdFactsReloadGate() }
                    else { factsPhase = .failed(.init(kind: .decoding, code: "invalid_facts_meta", message: "今日概览的数据范围不一致，请重新读取。")) }
                } else if let requiredFactsRevision, result.meta.dataRevision < requiredFactsRevision {
                    facts = nil
                    factsPhase = .requiresReload(factsReloadFailure ?? reloadRequiredFailure())
                    holdFactsReloadGate()
                } else {
                    facts = result
                    requiresFactsReload = false
                    factsReloadFailure = nil
                    requiredFactsRevision = nil
                    factsReloadRequiredReason = nil
                    factsPhase = .loaded
                    scopePhase = .idle
                    retryableLinkedRead = nil
                    linkedReadPhase = .idle
                }
            }
        } catch let failure as V15Failure {
            if currentFacts == factsGeneration {
                if requiresFactsReload { factsPhase = .requiresReload(factsReloadFailure ?? reloadRequiredFailure()); holdFactsReloadGate() }
                else { factsPhase = failure.kind == .cancelled ? .idle : .failed(failure) }
            }
        } catch {
            if currentFacts == factsGeneration {
                if requiresFactsReload { factsPhase = .requiresReload(factsReloadFailure ?? reloadRequiredFailure()); holdFactsReloadGate() }
                else { factsPhase = .failed(.init(kind: .transport, message: "今日概览读取失败。")) }
            }
        }

    }

    public func openScope(_ scope: V15DrillDownScope) async {
        guard !holdFactsReloadGate() else { return }
        guard let facts else {
            scopePhase = .failed(.init(kind: .decoding, code: "facts_missing", message: "请先读取今日概览。"))
            return
        }
        guard validScope(scope, for: facts) else {
            scopePhase = .failed(.init(kind: .decoding, code: "unsupported_facts_scope", message: "暂时无法打开这项详情。"))
            return
        }
        scopeGeneration &+= 1
        let current = scopeGeneration
        selectedScope = scope; scopeItems = []; nextCursor = nil; nextPageFailure = nil; nextPagePhase = .idle; scopePhase = .loading
        await readScope(scope: scope, cursor: nil, generation: current, appending: false)
    }

    public func openScope(type: String) async {
        guard !holdFactsReloadGate() else { return }
        guard let facts else { scopePhase = .failed(.init(kind: .decoding, code: "facts_missing", message: "请先读取今日概览。")); return }
        let scopes = [facts.cash.scope, facts.credit.scope, facts.reimbursements.scope, facts.completeness.scope].compactMap { $0 }
        guard let scope = scopes.first(where: { $0.scopeType == type }) else { scopePhase = .failed(.init(kind: .decoding, code: "unsupported_facts_scope", message: "暂时无法打开这项详情。")); return }
        await openScope(scope)
    }

    public func loadNextPage() async {
        guard !holdFactsReloadGate() else { return }
        guard let scope = selectedScope, let cursor = nextCursor, !isLoadingNextPage else { return }
        let current = scopeGeneration
        nextPagePhase = .loading; nextPageFailure = nil
        await readScope(scope: scope, cursor: cursor, generation: current, appending: true)
    }

    public func closeScopeInspector() {
        scopeGeneration &+= 1
        selectedScope = nil; scopeItems = []; nextCursor = nil; nextPageFailure = nil; nextPagePhase = .idle
        if !holdFactsReloadGate() { scopePhase = .idle; invalidateLinkedRead() }
    }

    public func openFactItem(_ item: V15FactDrillDownItem) async {
        guard !holdFactsReloadGate() else { return }
        switch item {
        case .cashAccount(let value): await openLinkedRead(value.deepLink)
        case .creditCycle, .reimbursementOutstanding, .completenessIssue, .unknown:
            retryableLinkedRead = nil
            linkedReadPhase = .unavailable("这项数据的详情暂时无法打开。")
        }
    }

    public func openLinkedRead(_ raw: String) async {
        guard !holdFactsReloadGate() else { return }
        linkGeneration &+= 1
        let current = linkGeneration
        guard let destination = parseLink(raw) else {
            retryableLinkedRead = nil
            linkedReadPhase = .unavailable("此链接暂时无法打开。")
            return
        }
        switch destination {
        case .localFacts(let label):
            retryableLinkedRead = nil
            linkedReadPhase = .localFactsInspector(label)
        case .unavailable(let message):
            retryableLinkedRead = nil
            linkedReadPhase = .unavailable(message)
        case .account(let id):
            retryableLinkedRead = raw
            linkedReadPhase = .loading
            do {
                let account = try await services.masterData.account(id: id)
                guard current == linkGeneration else { return }; linkedReadPhase = .account(account)
            } catch let failure as V15Failure {
                guard current == linkGeneration else { return }; linkedReadPhase = failure.kind == .cancelled ? .idle : .failed(failure)
            } catch { guard current == linkGeneration else { return }; linkedReadPhase = .failed(.init(kind: .transport, message: "账户只读信息读取失败。")) }
        case .transaction(let id):
            retryableLinkedRead = raw
            linkedReadPhase = .loading
            do {
                let transaction = try await services.ledger.get(transactionID: id)
                guard current == linkGeneration else { return }; linkedReadPhase = .transaction(transaction)
            } catch let failure as V15Failure {
                guard current == linkGeneration else { return }; linkedReadPhase = failure.kind == .cancelled ? .idle : .failed(failure)
            } catch { guard current == linkGeneration else { return }; linkedReadPhase = .failed(.init(kind: .transport, message: "账目只读信息读取失败。")) }
        }
    }

    /// Reuses only the previously parsed safe account/transaction locator.
    /// It has normal link-generation ownership, so close/new links can never
    /// be overwritten by an older failed retry.
    public func retryLinkedRead() async {
        guard let raw = retryableLinkedRead else { return }
        await openLinkedRead(raw)
    }

    public func closeLinkedRead() {
        retryableLinkedRead = nil
        invalidateLinkedRead()
    }

    public static func shanghaiDateLabel(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        return formatter.string(from: value)
    }

    private func readScope(scope: V15DrillDownScope, cursor: String?, generation: UInt64, appending: Bool) async {
        do {
            let page = try await services.reports.drillDown(scope: scope, cursor: cursor)
            guard generation == scopeGeneration, selectedScope == scope else { return }
            guard page.meta.dataRevision == scope.expectedDataRevision, page.scope.scopeType == scope.scopeType, page.scope.expectedDataRevision == scope.expectedDataRevision else {
                takeFactsConflict(.init(kind: .conflict, code: "report_facts_scope_changed", message: "今日概览已经更新，请重新读取。"), generation: generation)
                return
            }
            scopeItems = appending ? scopeItems + page.items : page.items
            nextCursor = page.nextCursor
            nextPagePhase = .idle; nextPageFailure = nil
            scopePhase = scopeItems.isEmpty ? .empty : .loaded
        } catch let failure as V15Failure {
            guard generation == scopeGeneration, selectedScope == scope else { return }
            if failure.kind == .conflict, failure.code == "report_facts_scope_changed" {
                takeFactsConflict(failure, generation: generation)
            } else if appending {
                nextPagePhase = failure.kind == .cancelled ? .idle : .failed(failure)
                nextPageFailure = failure.kind == .cancelled ? nil : failure
            } else {
                scopePhase = failure.kind == .cancelled ? .idle : .failed(failure)
            }
        } catch {
            guard generation == scopeGeneration, selectedScope == scope else { return }
            let failure = V15Failure(kind: .transport, message: appending ? "下一页加载失败。" : "这项数据加载失败。")
            if appending { nextPagePhase = .failed(failure); nextPageFailure = failure } else { scopePhase = .failed(failure) }
        }
    }

    private func takeFactsConflict(_ failure: V15Failure, generation: UInt64) {
        guard generation == scopeGeneration else { return }
        requiresFactsReload = true
        factsReloadFailure = failure
        requiredFactsRevision = [failure.conflict?.currentDataRevision, failure.conflict?.latestRevision].compactMap { $0 }.max()
        factsReloadRequiredReason = .init(code: "facts_reload_required", message: "今日概览已经更新，请重新读取后再继续。", fieldPath: nil)
        facts = nil
        factsPhase = .requiresReload(failure)
        scopeGeneration &+= 1
        selectedScope = nil; scopeItems = []; nextCursor = nil; nextPagePhase = .idle; nextPageFailure = nil; scopePhase = .requiresFactsReload(failure)
        linkGeneration &+= 1; retryableLinkedRead = nil; linkedReadPhase = .requiresFactsReload(failure)
    }

    private func invalidateScopeForFactsChange() {
        scopeGeneration &+= 1
        selectedScope = nil; scopeItems = []; nextCursor = nil; nextPageFailure = nil; nextPagePhase = .idle
        if !holdFactsReloadGate() { scopePhase = .idle; invalidateLinkedRead() }
    }

    /// Returns true after preserving the original conflict in both surfaces.
    @discardableResult private func holdFactsReloadGate() -> Bool {
        guard requiresFactsReload else { return false }
        let failure = factsReloadFailure ?? reloadRequiredFailure()
        scopePhase = .requiresFactsReload(failure)
        linkedReadPhase = .requiresFactsReload(failure)
        return true
    }
    private func reloadRequiredFailure() -> V15Failure { .init(kind: .conflict, code: "facts_reload_required", message: factsReloadRequiredReason?.message ?? "数据已经更新，请先刷新。") }
    private func invalidateLinkedRead() { linkGeneration &+= 1; retryableLinkedRead = nil; linkedReadPhase = .idle }
    private func validFactsMeta(_ meta: V15FactsMeta) -> Bool { meta.timezone == "Asia/Shanghai" && meta.currency == "CNY" && meta.schemaVersion == "1" && meta.dataRevision >= 0 }
    private func validScope(_ scope: V15DrillDownScope, for facts: V15Facts) -> Bool {
        ["cash_accounts", "credit_cycles", "reimbursement_outstanding", "completeness_issues"].contains(scope.scopeType) && scope.schemaVersion == "1" && scope.expectedDataRevision == facts.meta.dataRevision
    }

    private enum LinkDestination { case localFacts(String), account(UUID), transaction(UUID), unavailable(String) }
    private func parseLink(_ raw: String) -> LinkDestination? {
        guard let components = URLComponents(string: raw), components.scheme == "fiscal", components.percentEncodedQuery == nil, components.fragment == nil, let host = components.host else { return nil }
        let pieces = components.path.split(separator: "/").map(String.init)
        if host == "reports", pieces.count == 2, pieces[0] == "facts", ["cash_accounts", "credit_cycles", "reimbursement_outstanding", "completeness_issues"].contains(pieces[1]) { return .localFacts(scopeTitle(pieces[1])) }
        if host == "accounts", pieces.count == 1, let id = UUID(uuidString: pieces[0]) { return .account(id) }
        if host == "transactions", pieces.count == 1, let id = UUID(uuidString: pieces[0]) { return .transaction(id) }
        if ["credit", "reimbursements", "cash-flow", "statement-imports", "ai", "settings"].contains(host) { return .unavailable("这项内容暂时不能在这里打开。") }
        return nil
    }
    private func scopeTitle(_ value: String) -> String {
        switch value {
        case "cash_accounts": "现金账户"
        case "credit_cycles": "信用账期"
        case "reimbursement_outstanding": "待报销"
        case "completeness_issues": "需要补充的信息"
        default: "相关数据"
        }
    }
}
