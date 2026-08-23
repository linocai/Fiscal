import Foundation
import Observation

/// F3-D presents the server's cash-flow facts without deriving rows from the
/// future timeline. Every mutation is owner-scoped; only create and settle may
/// be replayed, and then only with their immutable body and original key.
@MainActor @Observable
public final class V15CashFlowModel {
    public enum Phase: Equatable { case idle, loading, loaded, empty, failed(V15Failure) }
    public enum MutationPhase: Equatable { case idle, loading, unknown, conflict(V15Conflict), failed(V15Failure), succeeded }
    public enum EditorMode: Equatable { case none, create, edit(String), settle(String), systemEdit(String) }
    public enum DirectAction: String, CaseIterable, Sendable { case confirm, cancel }
    public enum ListKind: Sendable, Equatable { case active, history }

    public private(set) var phase: Phase = .idle
    public private(set) var historyPhase: Phase = .idle
    public private(set) var detailPhase: Phase = .idle
    public private(set) var mutationPhase: MutationPhase = .idle
    public private(set) var active: V15CashFlowActiveResponse?
    public private(set) var history: V15CashFlowHistoryResponse?
    public private(set) var selectedItem: V15CashFlowItem?
    public private(set) var accounts: [V15AccountResponse] = []
    public private(set) var incomeCategories: [V15CategoryResponse] = []
    public private(set) var expenseCategories: [V15CategoryResponse] = []
    public private(set) var editorMode: EditorMode = .none
    public private(set) var serverIssues: [V15FieldIssue] = []
    public private(set) var resultItems: [V15CashFlowItem] = []
    public private(set) var directReadbackMessage: String?
    public private(set) var directReadbackCompleted = false
    public private(set) var factRefreshMessage: String?
    public private(set) var visibleList: ListKind = .active

    public var accountFilterID: UUID?
    public var historyMonth: String
    public var title = "" { didSet { editorInputChanged() } }
    public var note = "" { didSet { editorInputChanged() } }
    public var direction: V15CashFlowDirection = .outflow { didSet { directionChanged() } }
    public var amountText = "" { didSet { editorInputChanged() } }
    public var expectedDateText = "" { didSet { editorInputChanged() } }
    public var recurrenceEnabled = false { didSet { editorInputChanged() } }
    public var recurrenceEndDateText = "" { didSet { editorInputChanged() } }
    public var selectedAccountID: UUID? { didSet { editorInputChanged() } }
    public var selectedDestinationAccountID: UUID? { didSet { editorInputChanged() } }
    public var selectedCategoryID: UUID? { didSet { editorInputChanged() } }
    public var mutationScope: V15CashFlowMutationScope = .occurrence { didSet { editorInputChanged() } }
    public var settleAmountText = "" { didSet { settleInputChanged() } }
    public var settleDateText = "" { didSet { settleInputChanged() } }
    public var settleTitle = "" { didSet { settleInputChanged() } }
    public var settleNote = "" { didSet { settleInputChanged() } }
    public var settleAccountID: UUID? { didSet { settleInputChanged() } }
    public var settleDestinationAccountID: UUID? { didSet { settleInputChanged() } }
    public var settleCategoryID: UUID? { didSet { settleInputChanged() } }

    private let services: V15Services
    private let offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)?
    private let now: () -> Date
    private var listGeneration: UInt64 = 0
    private var historyGeneration: UInt64 = 0
    private var detailGeneration: UInt64 = 0
    private var masterGeneration: UInt64 = 0
    private var editorSession = UUID()
    private var applyingDraft = false

    private struct StableAttempt: Sendable, Equatable {
        enum Intent: Sendable, Equatable { case create(V15CashFlowDraft); case settle(UUID, V15CashFlowSettlementDraft) }
        let operationID: UUID; let owner: String; let intent: Intent; let key: UUID
    }
    private struct DirectAttempt: Sendable, Equatable {
        enum Intent: Sendable, Equatable { case update(UUID, V15CashFlowReplace); case confirm(UUID, V15CashFlowVersionRequest); case cancel(UUID, V15CashFlowVersionRequest); case system(V15CashFlowSystemKind, UUID, V15CashFlowSystemReplace) }
        let operationID: UUID; let owner: String; let intent: Intent
    }
    private struct FactRefreshGate: Sendable, Equatable { let operationID: UUID; let owner: String; let manualItemID: UUID?; let filterID: UUID?; let month: String }
    private struct SelectionOwner: Sendable, Equatable {
        let list: ListKind
        let itemID: String
        let accountFilterID: UUID?
        let month: String
        let generation: UInt64
    }
    private var stableAttempt: StableAttempt?
    private var directAttempt: DirectAttempt?
    private var factRefreshGate: FactRefreshGate?
    private var selectionOwner: SelectionOwner?

    public init(services: V15Services, offlineSnapshotAt: Date? = nil, offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)? = nil, now: @escaping () -> Date = { .now }) {
        self.services = services
        self.offlineSnapshotProvider = offlineSnapshotProvider ?? { offlineSnapshotAt ?? services.offlineSnapshotAt }
        self.now = now
        self.historyMonth = Self.monthString(now())
    }

    public var offlineSnapshotAt: Date? { offlineSnapshotProvider?() }
    public var isOffline: Bool { offlineSnapshotAt != nil }
    public var cashAccounts: [V15AccountResponse] { accounts.filter { $0.isActive && ($0.kind == .cash || $0.kind == .debit) } }
    public var visibleCategories: [V15CategoryResponse] { direction == .inflow ? incomeCategories : direction == .outflow ? expenseCategories : [] }
    public var hasUnknownStableAttempt: Bool { stableAttempt != nil && mutationPhase == .unknown }
    public var hasUnknownDirectAttempt: Bool { directAttempt != nil && mutationPhase == .unknown }
    public var hasFactRefreshGate: Bool { factRefreshGate != nil }
    public var canAbandonUnknownDirect: Bool { hasUnknownDirectAttempt && directReadbackCompleted }
    public var writeLocked: Bool { stableAttempt != nil || directAttempt != nil || factRefreshGate != nil || mutationPhase == .loading }

    public var editorIssues: [V15FieldIssue] { makeDraft(recording: false).issues }
    public var settleIssues: [V15FieldIssue] { makeSettlement(recording: false).issues }
    public var createReasons: [V15DisabledReason] { baseWriteReasons() + editorIssues.map(Self.reason) }
    public var updateReasons: [V15DisabledReason] {
        var reasons = baseWriteReasons() + editorIssues.map(Self.reason)
        guard case .edit(let id) = editorMode, let item = selectedItem, item.id == id else { reasons.append(.init(code: "editor_owner_changed", message: "请选择要修改的现金流事项。", fieldPath: nil)); return Self.unique(reasons) }
        if !item.allows(.edit) { reasons.append(.init(code: "server_action_unavailable", message: "此事项当前不能修改。", fieldPath: "actions")) }
        if item.manualItemID == nil { reasons.append(.init(code: "manual_item_required", message: "系统事项必须使用受限的系统编辑入口。", fieldPath: "manual_item_id")) }
        if item.seriesID == nil && mutationScope == .thisAndFuture { reasons.append(.init(code: "scope_unavailable", message: "单次事项没有“本次及以后”的范围。", fieldPath: "scope")) }
        if (item.status == .settled || item.status == .cancelled) && mutationScope != .occurrence { reasons.append(.init(code: "completed_scope_invalid", message: "已入账或已取消事项只能修改本次。", fieldPath: "scope")) }
        return Self.unique(reasons)
    }
    public var settleReasons: [V15DisabledReason] {
        var reasons = baseWriteReasons() + settleIssues.map(Self.reason)
        guard case .settle(let id) = editorMode, let item = selectedItem, item.id == id else { reasons.append(.init(code: "settle_owner_changed", message: "请选择要入账的现金流事项。", fieldPath: nil)); return Self.unique(reasons) }
        if !item.allows(.settle) { reasons.append(.init(code: "server_action_unavailable", message: "此事项当前不能入账。", fieldPath: "actions")) }
        return Self.unique(reasons)
    }
    public var systemUpdateReasons: [V15DisabledReason] {
        var reasons = baseWriteReasons()
        guard case .systemEdit(let id) = editorMode, let item = selectedItem, item.id == id else { reasons.append(.init(code: "system_owner_changed", message: "请选择系统事项。", fieldPath: nil)); return Self.unique(reasons) }
        if item.systemKind == .creditCycle { reasons.append(.init(code: "credit_projection_read_only", message: "信用账单投影来自真实债务，请到还款流程处理。", fieldPath: "system_kind")) }
        if item.systemKind != .reimbursement || item.systemReferenceID == nil { reasons.append(.init(code: "system_item_unsupported", message: "此系统事项没有可用的受限编辑入口。", fieldPath: "system_kind")) }
        if !item.allows(.edit) { reasons.append(.init(code: "server_action_unavailable", message: "此自动事项当前不能修改。", fieldPath: "actions")) }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { reasons.append(.init(code: "title_required", message: "请填写标题。", fieldPath: "title")) }
        if trimmed.count > 120 { reasons.append(.init(code: "title_too_long", message: "标题最多 120 个字符。", fieldPath: "title")) }
        if note.count > 500 { reasons.append(.init(code: "note_too_long", message: "备注最多 500 个字符。", fieldPath: "note")) }
        if !Self.isStrictDate(expectedDateText) { reasons.append(.init(code: "date_invalid", message: "预计日期必须是有效的 YYYY-MM-DD。", fieldPath: "expected_date")) }
        return Self.unique(reasons)
    }

    public func actionReasons(_ action: DirectAction, for item: V15CashFlowItem) -> [V15DisabledReason] {
        var reasons = baseWriteReasons()
        if item.isDisplayOnly { reasons.append(.init(code: "unknown_cash_flow_fact", message: "未知状态或方向只可查看。", fieldPath: "status")) }
        guard item.manualItemID != nil else { reasons.append(.init(code: "manual_item_required", message: "系统投影不能使用手工事项命令。", fieldPath: "manual_item_id")); return Self.unique(reasons) }
        let serverAction: V15CashFlowAction = action == .confirm ? .confirm : .cancel
        if !item.allows(serverAction) { reasons.append(.init(code: "server_action_unavailable", message: "当前状态不能执行此操作。", fieldPath: "actions")) }
        if item.seriesID == nil && mutationScope == .thisAndFuture { reasons.append(.init(code: "scope_unavailable", message: "单次事项没有“本次及以后”的范围。", fieldPath: "scope")) }
        if (item.status == .settled || item.status == .cancelled) && mutationScope != .occurrence { reasons.append(.init(code: "completed_scope_invalid", message: "已入账或已取消事项只能操作本次。", fieldPath: "scope")) }
        return Self.unique(reasons)
    }

    public func load() async {
        async let activeLoad: Void = loadActive(policy: .standard)
        async let historyLoad: Void = loadHistory(policy: .standard)
        async let masterLoad: Void = loadMasterData()
        _ = await (activeLoad, historyLoad, masterLoad)
        await selectFirstIfNeeded(in: visibleList)
    }

    public func refresh() async { await load() }

    public func setAccountFilter(_ id: UUID?) async {
        accountFilterID = id
        clearSelectionSurface(for: .active)
        await loadActive(policy: .standard)
        await selectFirstIfNeeded(in: .active)
    }

    public func setHistoryMonth(_ value: String) async {
        historyMonth = value
        clearSelectionSurface(for: .history)
        await loadHistory(policy: .standard)
        await selectFirstIfNeeded(in: .history)
    }

    public func setVisibleList(_ value: ListKind) async {
        guard visibleList != value else { return }
        visibleList = value
        clearSelectionSurface()
        await selectFirstIfNeeded(in: value)
    }

    public func selectItem(_ item: V15CashFlowItem, from list: ListKind = .active) async {
        guard let owner = makeSelectionOwner(for: item, in: list) else { return }
        detailGeneration &+= 1; let token = detailGeneration
        selectionOwner = owner
        selectedItem = item; editorMode = .none; resultItems = []; serverIssues = []
        guard let id = item.manualItemID else { detailPhase = .loaded; return }
        detailPhase = .loading
        do { let value = try await services.cashFlow.item(id: id); guard token == detailGeneration, selectionOwner == owner, selectionOwnerIsCurrent(owner) else { return }; selectedItem = value; detailPhase = .loaded }
        catch let failure as V15Failure { guard token == detailGeneration, selectionOwner == owner, selectionOwnerIsCurrent(owner) else { return }; detailPhase = failure.kind == .cancelled ? .idle : .failed(failure) }
        catch { guard token == detailGeneration, selectionOwner == owner, selectionOwnerIsCurrent(owner) else { return }; detailPhase = .failed(.init(kind: .transport, message: "现金流详情读取失败。")) }
    }

    public func openCreate() {
        guard stableAttempt == nil, directAttempt == nil, factRefreshGate == nil else { return }
        editorSession = UUID(); applyingDraft = true
        title = ""; note = ""; direction = .outflow; amountText = ""; expectedDateText = ShanghaiBusinessDate.string(for: now()); recurrenceEnabled = false; recurrenceEndDateText = ""; selectedAccountID = cashAccounts.first?.id; selectedDestinationAccountID = nil; selectedCategoryID = nil; mutationScope = .occurrence
        applyingDraft = false; editorMode = .create; mutationPhase = .idle; serverIssues = []; resultItems = []
    }

    public func openEdit(_ item: V15CashFlowItem) {
        guard stableAttempt == nil, directAttempt == nil, factRefreshGate == nil else { return }
        adoptSelection(item); editorSession = UUID(); applyingDraft = true
        title = item.title; note = item.note ?? ""; direction = item.direction; amountText = Self.amountText(item.plannedAmountMinor); expectedDateText = item.expectedDate; recurrenceEnabled = false; recurrenceEndDateText = ""; selectedAccountID = item.accountID; selectedDestinationAccountID = item.destinationAccountID; selectedCategoryID = item.categoryID; mutationScope = .occurrence
        applyingDraft = false; editorMode = item.isSystem ? .systemEdit(item.id) : .edit(item.id); mutationPhase = .idle; serverIssues = []; resultItems = []
    }

    public func openSettle(_ item: V15CashFlowItem) {
        guard stableAttempt == nil, directAttempt == nil, factRefreshGate == nil else { return }
        adoptSelection(item); editorSession = UUID(); applyingDraft = true
        settleAmountText = Self.amountText(item.plannedAmountMinor); settleDateText = ShanghaiBusinessDate.string(for: now()); settleTitle = item.title; settleNote = item.note ?? ""; settleAccountID = item.accountID.flatMap { id in cashAccounts.contains(where: { $0.id == id }) ? id : nil } ?? cashAccounts.first?.id; settleDestinationAccountID = item.destinationAccountID; settleCategoryID = item.categoryID
        applyingDraft = false; editorMode = .settle(item.id); mutationPhase = .idle; serverIssues = []; resultItems = []
    }

    public func dismissEditor() { guard mutationPhase != .loading else { return }; editorSession = UUID(); editorMode = .none; serverIssues = []; if stableAttempt == nil && directAttempt == nil && factRefreshGate == nil { mutationPhase = .idle } }

    public func create() async {
        let built = makeDraft(recording: true)
        guard createReasons.isEmpty, let request = built.value, !isOffline else { return }
        let attempt = StableAttempt(operationID: UUID(), owner: "create:\(editorSession.uuidString)", intent: .create(request), key: UUID())
        stableAttempt = attempt; mutationPhase = .loading; resultItems = []
        await performStable(attempt)
    }

    public func settle() async {
        let built = makeSettlement(recording: true)
        guard settleReasons.isEmpty, let item = selectedItem, let id = item.manualItemID, let request = built.value, !isOffline else { return }
        let attempt = StableAttempt(operationID: UUID(), owner: item.id, intent: .settle(id, request), key: UUID())
        stableAttempt = attempt; mutationPhase = .loading; resultItems = []
        await performStable(attempt)
    }

    public func retryUnknownStable() async { guard let attempt = stableAttempt, mutationPhase == .unknown, !isOffline, factRefreshGate == nil else { return }; mutationPhase = .loading; await performStable(attempt) }
    public func abandonUnknownStable() { guard stableAttempt != nil, mutationPhase == .unknown else { return }; stableAttempt = nil; mutationPhase = .idle; serverIssues = [] }

    public func update() async {
        let built = makeDraft(recording: true)
        guard updateReasons.isEmpty, let item = selectedItem, let id = item.manualItemID, let draft = built.value else { return }
        let request = V15CashFlowReplace(draft: draft, expectedVersion: item.version, scope: mutationScope)
        let attempt = DirectAttempt(operationID: UUID(), owner: item.id, intent: .update(id, request))
        directAttempt = attempt; beginDirect(); await performDirect(attempt)
    }

    public func updateSystem() async {
        guard systemUpdateReasons.isEmpty, let item = selectedItem, let kind = item.systemKind, let reference = item.systemReferenceID else { return }
        // D5: reimbursement amount is absent from the override wire. It remains
        // a live server fact; actual receipt entry belongs to reimbursement.
        let request = V15CashFlowSystemReplace(title: title.trimmingCharacters(in: .whitespacesAndNewlines), note: note.nilIfEmpty, expectedDate: expectedDateText, status: .confirmed, expectedVersion: item.version)
        let attempt = DirectAttempt(operationID: UUID(), owner: item.id, intent: .system(kind, reference, request))
        directAttempt = attempt; beginDirect(); await performDirect(attempt)
    }

    public func perform(_ action: DirectAction, on item: V15CashFlowItem) async {
        guard actionReasons(action, for: item).isEmpty, let id = item.manualItemID else { return }
        adoptSelection(item)
        let request = V15CashFlowVersionRequest(expectedVersion: item.version, scope: mutationScope)
        let intent: DirectAttempt.Intent = action == .confirm ? .confirm(id, request) : .cancel(id, request)
        let attempt = DirectAttempt(operationID: UUID(), owner: item.id, intent: intent)
        directAttempt = attempt; beginDirect(); await performDirect(attempt)
    }

    public func readBackUnknownDirect() async {
        guard let attempt = directAttempt, mutationPhase == .unknown else { return }
        detailGeneration &+= 1; let token = detailGeneration
        mutationPhase = .loading; directReadbackCompleted = false
        do {
            let observed: V15CashFlowItem?
            switch attempt.intent {
            case .update(let id, _), .confirm(let id, _), .cancel(let id, _): observed = try await services.cashFlow.item(id: id, readCachePolicy: .reloadIgnoringCache)
            case .system(let kind, let reference, _): observed = try await services.cashFlow.active(accountID: nil, readCachePolicy: .reloadIgnoringCache).items.first { $0.systemKind == kind && $0.systemReferenceID == reference }
            }
            guard token == detailGeneration, directAttempt == attempt else { return }
            if let observed { if selectedItem?.id == attempt.owner { selectedItem = observed }; replaceVisible(observed); directReadbackMessage = "最新状态为“\(observed.status.displayName)”，但仍无法确认是否由刚才的操作造成。请核对后继续。" }
            else { directReadbackMessage = "最新列表中没有找到此事项，但仍无法确认刚才的操作结果。请核对后继续。" }
            directReadbackCompleted = true; mutationPhase = .unknown
        } catch let failure as V15Failure {
            guard token == detailGeneration, directAttempt == attempt else { return }
            directReadbackMessage = "检查最新状态失败：\(failure.message)。暂时不能继续保存。"; mutationPhase = .unknown
        } catch {
            guard token == detailGeneration, directAttempt == attempt else { return }
            directReadbackMessage = "检查最新状态失败，暂时不能继续保存。"; mutationPhase = .unknown
        }
    }

    public func abandonUnknownDirect() { guard directAttempt != nil, mutationPhase == .unknown, directReadbackCompleted else { return }; directAttempt = nil; mutationPhase = .idle; directReadbackMessage = nil; directReadbackCompleted = false; editorMode = .none }
    public func retryFactRefresh() async { guard let gate = factRefreshGate, !isOffline else { return }; mutationPhase = .loading; await convergeFacts(gate) }
    public func reloadAfterConflict() async { guard case .conflict = mutationPhase else { return }; mutationPhase = .idle; editorMode = .none; await loadFreshFacts() }

    private func performStable(_ attempt: StableAttempt) async {
        do {
            let returned: [V15CashFlowItem]
            let ownerID: UUID?
            switch attempt.intent {
            case .create(let request): returned = try await services.cashFlow.create(request, idempotencyKey: attempt.key).items; ownerID = returned.first?.manualItemID
            case .settle(let id, let request): let item = try await services.cashFlow.settle(itemID: id, request: request, idempotencyKey: attempt.key); returned = [item]; ownerID = id
            }
            guard stableAttempt == attempt else { return }
            stableAttempt = nil; resultItems = returned
            returned.forEach(replaceVisible)
            if let first = returned.first, selectionStillOwned(by: attempt) { selectedItem = first }
            let gate = FactRefreshGate(operationID: UUID(), owner: attempt.owner, manualItemID: ownerID, filterID: accountFilterID, month: historyMonth)
            factRefreshGate = gate; mutationPhase = .loading; factRefreshMessage = "更改已经保存，正在更新现金流与历史。"
            await convergeFacts(gate)
        } catch let failure as V15Failure {
            guard stableAttempt == attempt else { return }
            serverIssues = failure.fieldIssues
            if Self.outcomeUnknown(failure) { mutationPhase = .unknown }
            else { stableAttempt = nil; mutationPhase = failure.kind == .conflict && failure.conflict != nil ? .conflict(failure.conflict!) : .failed(failure) }
        } catch {
            guard stableAttempt == attempt else { return }; mutationPhase = .unknown
        }
    }

    private func performDirect(_ attempt: DirectAttempt) async {
        do {
            let returned: [V15CashFlowItem]
            let manualID: UUID?
            switch attempt.intent {
            case .update(let id, let request): returned = try await services.cashFlow.update(itemID: id, request: request).items; manualID = id
            case .confirm(let id, let request): returned = [try await services.cashFlow.confirm(itemID: id, request: request)]; manualID = id
            case .cancel(let id, let request): returned = try await services.cashFlow.cancel(itemID: id, request: request).items; manualID = id
            case .system(let kind, let reference, let request): returned = [try await services.cashFlow.updateSystem(kind: kind, referenceID: reference, request: request)]; manualID = nil
            }
            guard directAttempt == attempt else { return }
            directAttempt = nil; resultItems = returned; returned.forEach(replaceVisible); if selectedItem?.id == attempt.owner, let owner = returned.first(where: { $0.id == attempt.owner }) ?? returned.first { selectedItem = owner }
            let gate = FactRefreshGate(operationID: UUID(), owner: attempt.owner, manualItemID: manualID, filterID: accountFilterID, month: historyMonth)
            factRefreshGate = gate; mutationPhase = .loading; factRefreshMessage = "操作已经完成，正在更新现金流与历史。"
            await convergeFacts(gate)
        } catch let failure as V15Failure {
            guard directAttempt == attempt else { return }; serverIssues = failure.fieldIssues
            if Self.outcomeUnknown(failure) { mutationPhase = .unknown; directReadbackMessage = "暂时无法确认操作结果。检查最新状态不会重复操作。" }
            else { directAttempt = nil; mutationPhase = failure.kind == .conflict && failure.conflict != nil ? .conflict(failure.conflict!) : .failed(failure) }
        } catch {
            guard directAttempt == attempt else { return }; mutationPhase = .unknown; directReadbackMessage = "暂时无法确认操作结果。检查最新状态不会重复操作。"
        }
    }

    private func beginDirect() { mutationPhase = .loading; directReadbackMessage = nil; directReadbackCompleted = false; resultItems = [] }

    private func convergeFacts(_ gate: FactRefreshGate) async {
        guard factRefreshGate == gate else { return }
        listGeneration &+= 1
        historyGeneration &+= 1
        detailGeneration &+= 1
        let activeToken = listGeneration
        let historyToken = historyGeneration
        let detailToken = detailGeneration
        do {
            async let activeRequest = services.cashFlow.active(accountID: gate.filterID, readCachePolicy: .reloadIgnoringCache)
            async let historyRequest = services.cashFlow.history(month: gate.month, readCachePolicy: .reloadIgnoringCache)
            let detailRequest: V15CashFlowItem? = if let id = gate.manualItemID { try await services.cashFlow.item(id: id, readCachePolicy: .reloadIgnoringCache) } else { nil }
            let (activeValue, historyValue) = try await (activeRequest, historyRequest)
            guard factRefreshGate == gate else { return }
            if accountFilterID == gate.filterID, listGeneration == activeToken {
                active = activeValue
                phase = activeValue.items.isEmpty ? .empty : .loaded
                reconcileSelection(in: .active, items: activeValue.items, generation: activeToken)
            }
            if historyMonth == gate.month, historyGeneration == historyToken {
                history = historyValue
                historyPhase = historyValue.items.isEmpty ? .empty : .loaded
                reconcileSelection(in: .history, items: historyValue.items, generation: historyToken)
            }
            if let detailRequest, detailGeneration == detailToken {
                if selectedItem?.id == gate.owner {
                    selectedItem = detailRequest
                } else if gate.owner.hasPrefix("create:"), editorMode == .create {
                    selectedItem = detailRequest
                    selectionOwner = makeSelectionOwner(for: detailRequest, in: .active)
                }
                replaceVisible(detailRequest)
            }
            factRefreshGate = nil; factRefreshMessage = nil; mutationPhase = .succeeded; editorMode = .none
        } catch let failure as V15Failure {
            guard factRefreshGate == gate else { return }
            mutationPhase = .failed(failure); factRefreshMessage = "更改已经保存，但最新数据没有全部更新：\(failure.message)。重新读取不会重复保存。"
        } catch {
            guard factRefreshGate == gate else { return }
            mutationPhase = .failed(.init(kind: .transport, message: "更改已经保存，但最新现金流读取失败。")); factRefreshMessage = "更改已经保存，但最新数据没有全部更新。重新读取不会重复保存。"
        }
    }

    private func loadFreshFacts() async { await loadActive(policy: .reloadIgnoringCache); await loadHistory(policy: .reloadIgnoringCache) }

    private func loadActive(policy: V15ReadCachePolicy) async {
        listGeneration &+= 1; detailGeneration &+= 1
        let token = listGeneration, filter = accountFilterID
        phase = .loading
        do { let value = try await services.cashFlow.active(accountID: filter, readCachePolicy: policy); guard token == listGeneration, filter == accountFilterID else { return }; active = value; phase = value.items.isEmpty ? .empty : .loaded; reconcileSelection(in: .active, items: value.items, generation: token) }
        catch let failure as V15Failure { guard token == listGeneration, filter == accountFilterID else { return }; phase = failure.kind == .cancelled ? .idle : .failed(failure) }
        catch { guard token == listGeneration, filter == accountFilterID else { return }; phase = .failed(.init(kind: .transport, message: "现金流事项读取失败。")) }
    }

    private func loadHistory(policy: V15ReadCachePolicy) async {
        historyGeneration &+= 1; detailGeneration &+= 1
        let token = historyGeneration, month = historyMonth
        historyPhase = .loading
        do { let value = try await services.cashFlow.history(month: month, readCachePolicy: policy); guard token == historyGeneration, month == historyMonth else { return }; history = value; historyPhase = value.items.isEmpty ? .empty : .loaded; reconcileSelection(in: .history, items: value.items, generation: token) }
        catch let failure as V15Failure { guard token == historyGeneration, month == historyMonth else { return }; historyPhase = failure.kind == .cancelled ? .idle : .failed(failure) }
        catch { guard token == historyGeneration, month == historyMonth else { return }; historyPhase = .failed(.init(kind: .transport, message: "现金流历史读取失败。")) }
    }

    private func loadMasterData() async {
        masterGeneration &+= 1; let token = masterGeneration
        do {
            async let accountsRequest = services.masterData.activeAccounts()
            async let incomeRequest = services.masterData.activeCategories(direction: .income)
            async let expenseRequest = services.masterData.activeCategories(direction: .expense)
            let (accountValues, incomeValues, expenseValues) = try await (accountsRequest, incomeRequest, expenseRequest)
            guard token == masterGeneration else { return }
            accounts = accountValues.filter(\.isActive).sorted { $0.sortOrder == $1.sortOrder ? $0.name < $1.name : $0.sortOrder < $1.sortOrder }
            incomeCategories = Self.flatten(incomeValues).filter { $0.archivedAt == nil && $0.direction == "income" }
            expenseCategories = Self.flatten(expenseValues).filter { $0.archivedAt == nil && $0.direction == "expense" }
        } catch { guard token == masterGeneration else { return }; accounts = []; incomeCategories = []; expenseCategories = [] }
    }

    private func replaceVisible(_ item: V15CashFlowItem) {
        if let value = active, let index = value.items.firstIndex(where: { $0.id == item.id }) { var items = value.items; items[index] = item; active = .init(summary: value.summary, items: items) }
        if let value = history, let index = value.items.firstIndex(where: { $0.id == item.id }) { var items = value.items; items[index] = item; history = .init(month: value.month, items: items) }
    }

    private func makeSelectionOwner(for item: V15CashFlowItem, in list: ListKind) -> SelectionOwner? {
        switch list {
        case .active:
            guard active?.items.contains(where: { $0.id == item.id }) == true else { return nil }
            return .init(list: .active, itemID: item.id, accountFilterID: accountFilterID, month: historyMonth, generation: listGeneration)
        case .history:
            guard history?.items.contains(where: { $0.id == item.id }) == true else { return nil }
            return .init(list: .history, itemID: item.id, accountFilterID: accountFilterID, month: historyMonth, generation: historyGeneration)
        }
    }

    private func selectionOwnerIsCurrent(_ owner: SelectionOwner) -> Bool {
        guard owner == selectionOwner, owner.list == visibleList else { return false }
        switch owner.list {
        case .active: return owner.accountFilterID == accountFilterID && owner.generation == listGeneration
        case .history: return owner.month == historyMonth && owner.generation == historyGeneration
        }
    }

    private func reconcileSelection(in list: ListKind, items: [V15CashFlowItem], generation: UInt64) {
        guard let owner = selectionOwner, owner.list == list else { return }
        let scopeMatches = switch list {
        case .active: owner.accountFilterID == accountFilterID
        case .history: owner.month == historyMonth
        }
        guard scopeMatches, let replacement = items.first(where: { $0.id == owner.itemID }) else {
            clearSelectionSurface(for: list)
            return
        }
        selectionOwner = .init(list: list, itemID: replacement.id, accountFilterID: accountFilterID, month: historyMonth, generation: generation)
        selectedItem = replacement
        detailPhase = .loaded
    }

    private func clearSelectionSurface(for list: ListKind? = nil) {
        if let list, selectionOwner?.list != list { return }
        detailGeneration &+= 1
        selectionOwner = nil
        selectedItem = nil
        detailPhase = .idle
        editorSession = UUID()
        editorMode = .none
        mutationScope = .occurrence
        serverIssues = []
        resultItems = []
        if stableAttempt == nil && directAttempt == nil && factRefreshGate == nil {
            mutationPhase = .idle
            directReadbackMessage = nil
            directReadbackCompleted = false
            factRefreshMessage = nil
        }
    }

    private func adoptSelection(_ item: V15CashFlowItem) {
        selectedItem = item
        if let owner = makeSelectionOwner(for: item, in: visibleList) { selectionOwner = owner }
    }

    private func selectFirstIfNeeded(in list: ListKind) async {
        guard visibleList == list, selectedItem == nil else { return }
        let item = switch list {
        case .active: active?.items.first
        case .history: history?.items.first
        }
        guard let item else { return }
        await selectItem(item, from: list)
    }

    private func selectionStillOwned(by attempt: StableAttempt) -> Bool {
        switch attempt.intent {
        case .create: editorMode == .create && attempt.owner == "create:\(editorSession.uuidString)"
        case .settle: selectedItem?.id == attempt.owner
        }
    }

    private func directionChanged() {
        guard !applyingDraft else { return }
        if direction == .transfer { selectedCategoryID = nil } else { selectedDestinationAccountID = nil }
        editorInputChanged()
    }
    private func editorInputChanged() { guard !applyingDraft else { return }; serverIssues = [] }
    private func settleInputChanged() { guard !applyingDraft else { return }; serverIssues = [] }

    private func makeDraft(recording: Bool) -> (value: V15CashFlowDraft?, issues: [V15FieldIssue]) {
        var issues: [V15FieldIssue] = []
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanTitle.isEmpty { issues.append(.init(code: "title_required", message: "请填写标题。", fieldPath: "title")) }
        if cleanTitle.count > 120 { issues.append(.init(code: "title_too_long", message: "标题最多 120 个字符。", fieldPath: "title")) }
        if note.count > 500 { issues.append(.init(code: "note_too_long", message: "备注最多 500 个字符。", fieldPath: "note")) }
        guard direction.isActionable else { issues.append(.init(code: "direction_unknown", message: "请选择已支持的现金流方向。", fieldPath: "direction")); return (nil, issues) }
        guard let amount = CNYAmountParser.minorUnits(amountText), amount > 0 else { issues.append(.init(code: "amount_invalid", message: "计划金额须为正数，最多两位小数。", fieldPath: "planned_amount_minor")); return (nil, issues) }
        if !Self.isStrictDate(expectedDateText) { issues.append(.init(code: "date_invalid", message: "预计日期必须是有效的 YYYY-MM-DD。", fieldPath: "expected_date")) }
        if direction == .transfer {
            if selectedAccountID == nil { issues.append(.init(code: "source_required", message: "转账必须选择来源账户。", fieldPath: "account_id")) }
            if selectedDestinationAccountID == nil { issues.append(.init(code: "destination_required", message: "转账必须选择目标账户。", fieldPath: "destination_account_id")) }
            if selectedAccountID == selectedDestinationAccountID, selectedAccountID != nil { issues.append(.init(code: "transfer_same_account", message: "转账来源与目标账户必须不同。", fieldPath: "destination_account_id")) }
            if selectedCategoryID != nil { issues.append(.init(code: "transfer_category_invalid", message: "转账不能选择分类。", fieldPath: "category_id")) }
        } else if selectedDestinationAccountID != nil { issues.append(.init(code: "destination_not_allowed", message: "只有转账可选择目标账户。", fieldPath: "destination_account_id")) }
        if let selectedAccountID, !cashAccounts.contains(where: { $0.id == selectedAccountID }) { issues.append(.init(code: "account_kind_invalid", message: "现金流落账账户必须是现金或借记账户。", fieldPath: "account_id")) }
        if let selectedDestinationAccountID, !cashAccounts.contains(where: { $0.id == selectedDestinationAccountID }) { issues.append(.init(code: "destination_kind_invalid", message: "转账目标必须是现金或借记账户。", fieldPath: "destination_account_id")) }
        if recurrenceEnabled {
            if !Self.isStrictDate(recurrenceEndDateText) { issues.append(.init(code: "recurrence_end_invalid", message: "重复结束日期必须是有效的 YYYY-MM-DD。", fieldPath: "recurrence_end_date")) }
            else if recurrenceEndDateText < expectedDateText { issues.append(.init(code: "recurrence_end_before_start", message: "重复结束日期不能早于首次日期。", fieldPath: "recurrence_end_date")) }
        }
        if recording { serverIssues = [] }
        guard issues.isEmpty else { return (nil, issues) }
        return (.init(title: cleanTitle, note: note.nilIfEmpty, direction: direction, plannedAmountMinor: amount, expectedDate: expectedDateText, accountID: selectedAccountID, destinationAccountID: selectedDestinationAccountID, categoryID: selectedCategoryID, recurrence: recurrenceEnabled ? "monthly" : nil, recurrenceEndDate: recurrenceEnabled ? recurrenceEndDateText : nil), issues)
    }

    private func makeSettlement(recording: Bool) -> (value: V15CashFlowSettlementDraft?, issues: [V15FieldIssue]) {
        var issues: [V15FieldIssue] = []
        guard let item = selectedItem else { return (nil, [.init(code: "item_required", message: "请选择现金流事项。", fieldPath: nil)]) }
        guard let amount = CNYAmountParser.minorUnits(settleAmountText), amount > 0 else { return (nil, [.init(code: "amount_invalid", message: "实际金额须为正数，最多两位小数。", fieldPath: "actual_amount_minor")]) }
        guard let occurredAt = Self.shanghaiNoon(settleDateText) else { return (nil, [.init(code: "date_invalid", message: "发生日期必须是有效的 YYYY-MM-DD。", fieldPath: "occurred_at")]) }
        // Settlement is a Shanghai business-date fact. Comparing the encoded
        // noon instant with the current clock would reject "today" before
        // 12:00, even though the business date is not in the future.
        if settleDateText > ShanghaiBusinessDate.string(for: now()) { issues.append(.init(code: "future_settlement", message: "入账日期不能晚于现在。", fieldPath: "occurred_at")) }
        guard let accountID = settleAccountID else { issues.append(.init(code: "account_required", message: "请选择落账账户。", fieldPath: "account_id")); return (nil, issues) }
        if !cashAccounts.contains(where: { $0.id == accountID }) { issues.append(.init(code: "account_kind_invalid", message: "落账账户必须是现金或借记账户。", fieldPath: "account_id")) }
        if item.direction == .transfer {
            guard let destination = settleDestinationAccountID else { issues.append(.init(code: "destination_required", message: "转账必须选择目标账户。", fieldPath: "destination_account_id")); return (nil, issues) }
            if destination == accountID { issues.append(.init(code: "transfer_same_account", message: "转账来源与目标账户必须不同。", fieldPath: "destination_account_id")) }
            if !cashAccounts.contains(where: { $0.id == destination }) { issues.append(.init(code: "destination_kind_invalid", message: "转账目标必须是现金或借记账户。", fieldPath: "destination_account_id")) }
            if settleCategoryID != nil { issues.append(.init(code: "transfer_category_invalid", message: "转账入账不能选择分类。", fieldPath: "category_id")) }
        } else if settleDestinationAccountID != nil { issues.append(.init(code: "destination_not_allowed", message: "只有转账可选择目标账户。", fieldPath: "destination_account_id")) }
        let cleanTitle = settleTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTitle.isEmpty && cleanTitle.count > 120 { issues.append(.init(code: "title_too_long", message: "标题最多 120 个字符。", fieldPath: "title")) }
        if settleNote.count > 500 { issues.append(.init(code: "note_too_long", message: "备注最多 500 个字符。", fieldPath: "note")) }
        if recording { serverIssues = [] }
        guard issues.isEmpty else { return (nil, issues) }
        return (.init(expectedVersion: item.version, actualAmountMinor: amount, occurredAt: occurredAt, accountID: accountID, destinationAccountID: item.direction == .transfer ? settleDestinationAccountID : nil, categoryID: item.direction == .transfer ? nil : settleCategoryID, title: cleanTitle.nilIfEmpty, note: settleNote.nilIfEmpty), issues)
    }

    private func baseWriteReasons() -> [V15DisabledReason] {
        var reasons: [V15DisabledReason] = []
        if isOffline { reasons.append(.init(code: "offline_read_only", message: "离线时只可查看，不能保存现金流。", fieldPath: nil)) }
        if stableAttempt != nil { reasons.append(.init(code: "stable_attempt_pending", message: "上一笔操作仍在处理中，或结果暂时不明。请先安全检查保存结果。", fieldPath: nil)) }
        if directAttempt != nil { reasons.append(.init(code: "direct_attempt_pending", message: "上一笔操作结果暂时不明。请先检查最新状态。", fieldPath: nil)) }
        if factRefreshGate != nil { reasons.append(.init(code: "fact_refresh_required", message: "更改已经保存，最新数据还没有更新完成；请重新读取。", fieldPath: nil)) }
        return Self.unique(reasons)
    }

    private static func outcomeUnknown(_ failure: V15Failure) -> Bool { V15LedgerCreateService.outcomeMayBeUnknown(failure) }
    private static func reason(_ issue: V15FieldIssue) -> V15DisabledReason { .init(code: issue.code, message: issue.message, fieldPath: issue.fieldPath) }
    private static func unique(_ reasons: [V15DisabledReason]) -> [V15DisabledReason] { var seen = Set<String>(); return reasons.filter { seen.insert("\($0.code)|\($0.fieldPath ?? "")|\($0.message)").inserted } }
    private static func flatten(_ categories: [V15CategoryResponse]) -> [V15CategoryResponse] { categories.flatMap { [$0] + flatten($0.children) } }
    private static func amountText(_ minor: V15MinorUnits) -> String { String(format: "%.2f", Double(minor) / 100) }
    private static func isStrictDate(_ value: String) -> Bool { shanghaiNoon(value) != nil }
    private static func shanghaiNoon(_ value: String) -> Date? {
        guard value.range(of: "^[0-9]{4}-(0[1-9]|1[0-2])-([0-2][0-9]|3[01])$", options: .regularExpression) != nil else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = ShanghaiBusinessDate.timeZone
        let parts = value.split(separator: "-").compactMap { Int($0) }; guard parts.count == 3 else { return nil }
        let components = DateComponents(timeZone: ShanghaiBusinessDate.timeZone, year: parts[0], month: parts[1], day: parts[2], hour: 12)
        guard let date = calendar.date(from: components), calendar.dateComponents([.year, .month, .day], from: date).year == parts[0], calendar.dateComponents([.year, .month, .day], from: date).month == parts[1], calendar.dateComponents([.year, .month, .day], from: date).day == parts[2] else { return nil }
        return date
    }
    private static func monthString(_ date: Date) -> String { let values = ShanghaiBusinessDate.date(for: date); return String(format: "%04d-%02d", values.year ?? 0, values.month ?? 0) }
}

private extension String { var nilIfEmpty: String? { let value = trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? nil : value } }
