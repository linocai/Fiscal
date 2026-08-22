import Foundation
import Observation

@MainActor @Observable
public final class V15LedgerModel {
    public enum Phase: Equatable { case idle, loading, loaded, empty, failed(V15Failure) }
    public enum DetailPhase: Equatable { case idle, loading, loaded, failed(V15Failure) }
    public enum NextPagePhase: Equatable { case idle, loading, failed(V15Failure) }
    public enum MutationState: Equatable { case idle, working, reconciled(String), conflict(V15Conflict), failed(V15Failure) }
    public enum MutationAction: String, Equatable, Sendable { case void, restore, replace }

    public var filter = V15LedgerFilter() { didSet { guard filter != oldValue else { return }; filterChanged() } }
    public private(set) var items: [V15Transaction] = []
    public private(set) var nextCursor: String?
    public private(set) var phase: Phase = .idle
    public private(set) var nextPagePhase: NextPagePhase = .idle
    public private(set) var nextPageFailure: V15Failure?
    public private(set) var selected: V15Transaction?
    public private(set) var requestedDetailID: UUID?
    public private(set) var detailPhase: DetailPhase = .idle
    public private(set) var revisions: [V15TransactionRevision] = []
    public private(set) var provenance: V15TransactionProvenance?
    public private(set) var selectedCycle: V15CreditCycle?
    public private(set) var cycleReadError: String?
    public private(set) var accounts: [V15AccountResponse] = []
    public private(set) var categories: [V15CategoryResponse] = []
    public private(set) var mutation: MutationState = .idle
    public private(set) var lastAction: MutationAction?
    public private(set) var deepLinkError: String?
    public private(set) var filterIssues: [V15FieldIssue] = []
    public private(set) var amountMinText = ""
    public private(set) var amountMaxText = ""
    public private(set) var dateFromText = ""
    public private(set) var dateToText = ""

    private let services: V15Services
    public let offlineSnapshotAt: Date?
    private var listGeneration: UInt64 = 0
    private var detailGeneration: UInt64 = 0
    private var mutationGeneration: UInt64 = 0
    private var referenceGeneration: UInt64 = 0

    public init(services: V15Services, offlineSnapshotAt: Date? = nil) {
        self.services = services
        self.offlineSnapshotAt = offlineSnapshotAt ?? services.offlineSnapshotAt
    }

    public var isOffline: Bool { offlineSnapshotAt != nil }
    public var isLoadingNext: Bool { nextPagePhase == .loading }
    public var canLoadWithCurrentFilter: Bool { filterIssues.isEmpty }
    public func filterChanged() { listGeneration &+= 1; nextCursor = nil; nextPagePhase = .idle; nextPageFailure = nil }

    public func setQuery(_ value: String) { updateFilter { $0.query = value.isEmpty ? nil : value } }
    public func setKind(_ value: String?) { updateFilter { $0.kind = value } }
    public func setAccount(_ value: UUID?) { updateFilter { $0.accountID = value } }
    public func setCategory(_ value: UUID?) { updateFilter { $0.categoryID = value } }
    public func setClassification(_ value: String) { updateFilter { $0.classification = value } }
    public func setSource(_ value: String?) { updateFilter { $0.source = value } }
    public func setIncludeVoided(_ value: Bool) { updateFilter { $0.includeVoided = value } }
    public func setDateFrom(_ value: String) { dateFromText = value; validateDateFilters() }
    public func setDateTo(_ value: String) { dateToText = value; validateDateFilters() }
    public func setAmountMin(_ value: String) { amountMinText = value; validateAmountFilters() }
    public func setAmountMax(_ value: String) { amountMaxText = value; validateAmountFilters() }

    public func loadReferences() async {
        referenceGeneration &+= 1; let current = referenceGeneration
        do {
            async let accountValues = services.masterData.activeAccounts()
            async let categoryValues = services.masterData.activeCategories()
            let result = try await (accountValues, categoryValues)
            guard current == referenceGeneration else { return }
            accounts = result.0; categories = flatten(result.1)
        } catch { /* Labels fall back to non-identifying read-only text. */ }
    }

    public func load() async {
        guard canLoadWithCurrentFilter else { return }
        listGeneration &+= 1; let current = listGeneration
        phase = .loading; nextCursor = nil; nextPagePhase = .idle; nextPageFailure = nil
        var request = filter; request.cursor = nil
        do {
            let page = try await services.ledger.list(request)
            guard current == listGeneration else { return }
            items = unique(page.items); nextCursor = page.nextCursor; phase = items.isEmpty ? .empty : .loaded
        } catch let failure as V15Failure {
            guard current == listGeneration else { return }
            phase = failure.kind == .cancelled ? .idle : .failed(failure)
        } catch { guard current == listGeneration else { return }; phase = .failed(.init(kind: .transport, message: "账目列表读取失败。")) }
    }

    public func loadNext() async {
        guard let cursor = nextCursor, nextPagePhase != .loading else { return }
        let current = listGeneration; nextPagePhase = .loading; nextPageFailure = nil
        var request = filter; request.cursor = cursor
        do {
            let page = try await services.ledger.list(request)
            guard current == listGeneration else { return }
            items = unique(items + page.items); nextCursor = page.nextCursor; nextPagePhase = .idle
        } catch let failure as V15Failure {
            guard current == listGeneration else { return }
            nextPagePhase = failure.kind == .cancelled ? .idle : .failed(failure); nextPageFailure = failure.kind == .cancelled ? nil : failure
        } catch {
            guard current == listGeneration else { return }
            let failure = V15Failure(kind: .transport, message: "下一页读取失败。"); nextPagePhase = .failed(failure); nextPageFailure = failure
        }
    }

    public func select(_ transaction: V15Transaction) async { await loadDetail(transactionID: transaction.id) }
    public func retryDetail() async { guard let requestedDetailID else { return }; await loadDetail(transactionID: requestedDetailID) }
    public func loadDetail(transactionID: UUID) async {
        detailGeneration &+= 1; let current = detailGeneration
        requestedDetailID = transactionID; selected = nil; detailPhase = .loading; revisions = []; provenance = nil; selectedCycle = nil; cycleReadError = nil; mutation = .idle
        do {
            async let detail: V15Transaction = services.ledger.get(transactionID: transactionID)
            async let history: V15TransactionRevisionPage = services.ledger.revisions(transactionID: transactionID)
            async let links: V15TransactionProvenance = services.ledger.provenance(transactionID: transactionID)
            let result = try await (detail, history, links)
            guard current == detailGeneration, requestedDetailID == transactionID else { return }
            selected = result.0; revisions = result.1.items; provenance = result.2; detailPhase = .loaded
            await loadSelectedCycle(for: result.0, generation: current)
        } catch let failure as V15Failure {
            guard current == detailGeneration, requestedDetailID == transactionID else { return }; detailPhase = failure.kind == .cancelled ? .idle : .failed(failure)
        } catch { guard current == detailGeneration, requestedDetailID == transactionID else { return }; detailPhase = .failed(.init(kind: .transport, message: "账目详情读取失败。")) }
    }

    public func openReadOnlyDeepLink(_ raw: String) async {
        guard let url = URL(string: raw), url.scheme == "fiscal", url.host == "transactions" else { deepLinkError = "无法识别此账目链接。"; return }
        let candidate = url.pathComponents.drop(while: { $0 == "/" }).first
        guard let candidate, let id = UUID(uuidString: candidate) else { deepLinkError = "账目链接缺少可读取的编号。"; return }
        deepLinkError = nil; await loadDetail(transactionID: id)
    }

    public func voidSelected() async { await mutate(.void) }
    public func restoreSelected() async { await mutate(.restore) }
    public func retryLastMutation() async { guard let lastAction else { return }; await mutate(lastAction) }
    public func accountName(_ id: UUID?) -> String { guard let id else { return "未提供账户" }; return accounts.first(where: { $0.id == id })?.name ?? "账户信息不可读取" }
    public func categoryName(_ id: UUID?) -> String { guard let id else { return "未分类" }; return categories.first(where: { $0.id == id })?.name ?? "分类信息不可读取" }

    private func mutate(_ action: MutationAction) async {
        guard let selected else { return }; lastAction = action
        guard !isOffline else { mutation = .failed(.init(kind: .offlineReadOnly, code: "offline_read_only", message: "离线快照仅可查看，无法提交更改。")); return }
        guard action != .replace, let serverAction = selected.availableActions.first(where: { $0.action == action.rawValue }), serverAction.enabled else { return }
        mutationGeneration &+= 1; let current = mutationGeneration; mutation = .working
        do {
            let value: V15Transaction
            switch action { case .void: value = try await services.ledger.void(transactionID: selected.id, expectedVersion: selected.version); case .restore: value = try await services.ledger.restore(transactionID: selected.id, expectedVersion: selected.version); case .replace: return }
            guard current == mutationGeneration else { return }; self.selected = value; replaceInList(value); mutation = .idle; await loadDetail(transactionID: value.id)
        } catch let failure as V15Failure {
            guard current == mutationGeneration else { return }
            if V15LedgerCreateService.outcomeMayBeUnknown(failure) { await reconcileUnknown(action, transactionID: selected.id, generation: current); return }
            if failure.kind == .conflict, let conflict = failure.conflict { mutation = .conflict(conflict); return }; mutation = .failed(failure)
        } catch { guard current == mutationGeneration else { return }; await reconcileUnknown(action, transactionID: selected.id, generation: current) }
    }

    private func reconcileUnknown(_ action: MutationAction, transactionID: UUID, generation: UInt64) async {
        do {
            async let currentFact = services.ledger.get(transactionID: transactionID); async let history = services.ledger.revisions(transactionID: transactionID)
            let result = try await (currentFact, history); guard generation == mutationGeneration else { return }
            selected = result.0; revisions = result.1.items; replaceInList(result.0)
            let happened = action == .void ? result.0.voidedAt != nil : result.0.voidedAt == nil
            mutation = .reconciled(happened ? "连接中断后已读回服务器事实：操作已确认。" : "连接中断后未能确认操作是否执行；请基于当前事实重新决定。")
        } catch { guard generation == mutationGeneration else { return }; mutation = .reconciled("连接中断，且暂时无法读回服务器事实；没有重试写入，请稍后重新加载再决定。") }
    }

    private func loadSelectedCycle(for transaction: V15Transaction, generation: UInt64) async {
        guard let cycleID = transaction.creditCycleID else { return }
        let creditID = [transaction.accountID, transaction.destinationAccountID].compactMap { $0 }.first { id in accounts.first(where: { $0.id == id })?.kind == .credit }
        guard let creditID else { cycleReadError = "账期所属信用账户不可读取。"; return }
        do {
            let page = try await services.creditCycles.list(accountID: creditID)
            guard generation == detailGeneration, requestedDetailID == transaction.id else { return }
            selectedCycle = page.items.first(where: { $0.id == cycleID }); if selectedCycle == nil { cycleReadError = "服务器未返回对应账期。" }
        } catch { guard generation == detailGeneration, requestedDetailID == transaction.id else { return }; cycleReadError = "账期信息不可读取。" }
    }

    private func updateFilter(_ change: (inout V15LedgerFilter) -> Void) { var next = filter; change(&next); filter = next }
    private func validateDateFilters() {
        let values = [("date_from", dateFromText), ("date_to", dateToText)]; var issues = filterIssues.filter { $0.fieldPath != "date_from" && $0.fieldPath != "date_to" }
        for (path, value) in values where !value.isEmpty && !isBusinessDate(value) { issues.append(.init(code: "invalid_date", message: "请输入 YYYY-MM-DD 格式的业务日期。", fieldPath: path)) }
        filterIssues = issues; guard !issues.contains(where: { $0.fieldPath == "date_from" || $0.fieldPath == "date_to" }) else { return }
        updateFilter { $0.dateFrom = dateFromText.isEmpty ? nil : dateFromText; $0.dateTo = dateToText.isEmpty ? nil : dateToText }
    }
    private func validateAmountFilters() {
        var issues = filterIssues.filter { $0.fieldPath != "amount_min" && $0.fieldPath != "amount_max" }; let min = amountMinText.isEmpty ? nil : CNYAmountParser.minorUnits(amountMinText); let max = amountMaxText.isEmpty ? nil : CNYAmountParser.minorUnits(amountMaxText)
        if !amountMinText.isEmpty && min == nil { issues.append(.init(code: "invalid_amount", message: "金额须为最多两位小数的元金额。", fieldPath: "amount_min")) }
        if !amountMaxText.isEmpty && max == nil { issues.append(.init(code: "invalid_amount", message: "金额须为最多两位小数的元金额。", fieldPath: "amount_max")) }
        if let min, let max, min > max { issues.append(.init(code: "amount_range", message: "最低金额不能高于最高金额。", fieldPath: "amount_max")) }
        filterIssues = issues; guard !issues.contains(where: { $0.fieldPath == "amount_min" || $0.fieldPath == "amount_max" }) else { return }
        updateFilter { $0.amountMinMinor = min; $0.amountMaxMinor = max }
    }
    private func isBusinessDate(_ value: String) -> Bool { value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil }
    private func flatten(_ roots: [V15CategoryResponse]) -> [V15CategoryResponse] { roots + roots.flatMap { flatten($0.children) } }
    private func unique(_ values: [V15Transaction]) -> [V15Transaction] { var seen = Set<UUID>(); return values.filter { seen.insert($0.id).inserted } }
    private func replaceInList(_ value: V15Transaction) { if let index = items.firstIndex(where: { $0.id == value.id }) { items[index] = value } }
}
