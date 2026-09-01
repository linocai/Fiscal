import Foundation
import Observation

@MainActor @Observable
public final class V15LedgerModel {
    public enum Phase: Equatable { case idle, loading, loaded, empty, failed(V15Failure) }
    public enum DetailPhase: Equatable { case idle, loading, loaded, failed(V15Failure) }
    public enum ReferencePhase: Equatable { case idle, loading, loaded, empty, failed(V15Failure) }
    public enum NextPagePhase: Equatable { case idle, loading, failed(V15Failure) }
    public enum MutationState: Equatable { case idle, working, reconciled(String), conflict(V15Conflict), failed(V15Failure) }
    public enum MutationAction: String, Equatable, Sendable { case void, restore, replace }
    public struct BatchCategoryFailure: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let title: String
        public let message: String
    }
    public struct BatchCategoryResult: Sendable, Equatable {
        public let committedIDs: [UUID]
        public let succeededIDs: [UUID]
        public let failures: [BatchCategoryFailure]
        public let queued: Bool

        public init(
            succeededIDs: [UUID],
            committedIDs: [UUID]? = nil,
            failures: [BatchCategoryFailure],
            queued: Bool
        ) {
            self.committedIDs = committedIDs ?? succeededIDs
            self.succeededIDs = succeededIDs
            self.failures = failures
            self.queued = queued
        }
    }

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
    public private(set) var referencePhase: ReferencePhase = .idle
    public private(set) var mutation: MutationState = .idle
    public private(set) var categoryChangePreview: V15CategoryChangePreview?
    public private(set) var categoryChangeFailure: V15Failure?
    public private(set) var categoryChangeIsCommitting = false
    public private(set) var mutationConflictChanges: [V15ConflictChange] = []
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
    private var categoryChangeGeneration: UInt64 = 0
    private var referenceGeneration: UInt64 = 0
    private var lastReplacementCategoryID: UUID?

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
        referencePhase = .loading
        do {
            async let accountValues = services.masterData.activeAccounts()
            async let categoryValues = services.masterData.activeCategories()
            let result = try await (accountValues, categoryValues)
            guard current == referenceGeneration else { return }
            accounts = result.0; categories = flatten(result.1)
            referencePhase = accounts.isEmpty ? .empty : .loaded
        } catch let failure as V15Failure {
            guard current == referenceGeneration else { return }
            referencePhase = failure.kind == .cancelled ? .idle : .failed(failure)
        } catch {
            guard current == referenceGeneration else { return }
            referencePhase = .failed(.init(kind: .transport, message: "账户与分类读取失败。"))
        }
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
    public func clearSelection() {
        clearCategoryPreview()
        detailGeneration &+= 1
        mutationGeneration &+= 1
        requestedDetailID = nil
        selected = nil
        detailPhase = .idle
        revisions = []
        provenance = nil
        selectedCycle = nil
        cycleReadError = nil
        mutation = .idle
    }
    public func retryDetail() async { guard let requestedDetailID else { return }; await loadDetail(transactionID: requestedDetailID) }
    public func loadDetail(transactionID: UUID) async {
        if requestedDetailID != transactionID { clearCategoryPreview() }
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
    public func replaceSelectedCategory(_ categoryID: UUID?) async {
        guard let selected else { return }
        guard let kind = V15ManualTransactionKind(rawValue: selected.kind) else {
            mutation = .failed(.init(kind: .decoding, code: "category_replace_unsupported", message: "这类系统账目不能在此修改分类。"))
            return
        }
        mutationGeneration &+= 1
        let current = mutationGeneration
        lastAction = .replace
        lastReplacementCategoryID = categoryID
        mutation = .working
        mutationConflictChanges = []
        let draft = V15TransactionCreateRequest(
            kind: kind,
            amountMinor: selected.amountMinor,
            occurredAt: selected.occurredAt,
            title: selected.title,
            note: selected.note,
            accountID: selected.accountID,
            categoryID: categoryID,
            destinationAccountID: selected.destinationAccountID,
            creditCycleID: selected.creditCycleID
        )
        let request = V15TransactionReplaceRequest(draft: draft, expectedVersion: selected.version)
        if isOffline {
            _ = services.pendingWrites.enqueueCategory(
                transactionID: selected.id,
                transactionTitle: selected.title,
                amountMinor: selected.amountMinor,
                request: request
            )
            mutation = .reconciled("已加入待同步；同步前仍显示上次保存的分类。")
            return
        }
        do {
            let value = try await services.ledger.replace(
                transactionID: selected.id,
                request: request
            )
            guard current == mutationGeneration else { return }
            self.selected = value
            replaceInList(value)
            mutation = .idle
            await loadDetail(transactionID: value.id)
        } catch let failure as V15Failure {
            guard current == mutationGeneration else { return }
            if failure.kind == .conflict, let conflict = failure.conflict {
                if let latest = try? await services.ledger.get(transactionID: selected.id) {
                    guard current == mutationGeneration else { return }
                    mutationConflictChanges = categoryConflictChanges(previous: selected, current: latest)
                    self.selected = latest
                    replaceInList(latest)
                }
                mutation = .conflict(conflict)
            } else if V15LedgerCreateService.outcomeMayBeUnknown(failure) {
                await reconcileUnknown(.replace, transactionID: selected.id, generation: current)
            } else {
                mutation = .failed(failure)
            }
        } catch {
            guard current == mutationGeneration else { return }
            await reconcileUnknown(.replace, transactionID: selected.id, generation: current)
        }
    }
    private func categoryConflictChanges(previous: V15Transaction, current: V15Transaction) -> [V15ConflictChange] {
        var changes: [V15ConflictChange] = []
        if previous.categoryID != current.categoryID {
            changes.append(.init(field: "分类", previousValue: categoryName(previous.categoryID), currentValue: categoryName(current.categoryID)))
        }
        if previous.version != current.version {
            changes.append(.init(field: "账目数据", previousValue: "你打开时", currentValue: "已更新"))
        }
        return changes
    }
    public func retryLastMutation() async {
        guard let lastAction else { return }
        if lastAction == .replace { await replaceSelectedCategory(lastReplacementCategoryID) }
        else { await mutate(lastAction) }
    }
    public func replaceCategories(_ transactionIDs: Set<UUID>, categoryID: UUID) async -> BatchCategoryResult {
        var available = items
        if let selected, !available.contains(where: { $0.id == selected.id }) { available.append(selected) }
        let targets = available.filter { transactionIDs.contains($0.id) }
        var succeeded: [UUID] = []
        var failures: [BatchCategoryFailure] = []
        for transaction in targets {
            guard let kind = V15ManualTransactionKind(rawValue: transaction.kind) else {
                failures.append(.init(id: transaction.id, title: transaction.title, message: "系统账目不能在此批量修改分类。"))
                continue
            }
            let draft = V15TransactionCreateRequest(
                kind: kind,
                amountMinor: transaction.amountMinor,
                occurredAt: transaction.occurredAt,
                title: transaction.title,
                note: transaction.note,
                accountID: transaction.accountID,
                categoryID: categoryID,
                destinationAccountID: transaction.destinationAccountID,
                creditCycleID: transaction.creditCycleID
            )
            let request = V15TransactionReplaceRequest(draft: draft, expectedVersion: transaction.version)
            if isOffline {
                _ = services.pendingWrites.enqueueCategory(
                    transactionID: transaction.id,
                    transactionTitle: transaction.title,
                    amountMinor: transaction.amountMinor,
                    request: request
                )
                succeeded.append(transaction.id)
                continue
            }
            do {
                let value = try await services.ledger.replace(transactionID: transaction.id, request: request)
                replaceInList(value)
                succeeded.append(transaction.id)
            } catch let failure as V15Failure {
                if V15LedgerCreateService.outcomeMayBeUnknown(failure) {
                    do {
                        let current = try await services.ledger.get(transactionID: transaction.id)
                        replaceInList(current)
                        if current.categoryID == categoryID { succeeded.append(transaction.id) }
                        else { failures.append(.init(id: transaction.id, title: transaction.title, message: "结果不明；当前分类未达到目标值。")) }
                    } catch {
                        failures.append(.init(id: transaction.id, title: transaction.title, message: "结果暂时不明，请稍后重新读取。"))
                    }
                } else {
                    failures.append(.init(id: transaction.id, title: transaction.title, message: failure.message))
                }
            } catch {
                failures.append(.init(id: transaction.id, title: transaction.title, message: "结果不明，未自动重试。"))
            }
        }
        return .init(succeededIDs: succeeded, failures: failures, queued: isOffline)
    }

    public func previewCategories(_ transactionIDs: Set<UUID>, categoryID: UUID) async {
        guard !categoryChangeIsCommitting else { return }
        categoryChangeGeneration &+= 1; let current = categoryChangeGeneration
        categoryChangePreview = nil; categoryChangeFailure = nil
        guard !isOffline else {
            categoryChangeFailure = .init(kind: .offlineReadOnly, code: "preview_requires_network", message: "需要联网取得最新分类影响。")
            return
        }
        var available = items
        if let selected, !available.contains(where: { $0.id == selected.id }) { available.append(selected) }
        let targets = available.filter { transactionIDs.contains($0.id) }
        guard targets.count == transactionIDs.count, !targets.isEmpty else {
            categoryChangeFailure = .init(kind: .conflict, code: "category_selection_changed", message: "所选账目已经变化，请重新选择。")
            return
        }
        let request = V15BatchCategoryRequest(
            items: targets.map { .init(transactionID: $0.id, expectedVersion: $0.version) },
            categoryID: categoryID
        )
        do {
            let value = try await services.actions.categoryPreview(request)
            guard current == categoryChangeGeneration else { return }
            categoryChangePreview = value
        } catch let failure as V15Failure {
            guard current == categoryChangeGeneration else { return }
            categoryChangeFailure = failure.kind == .cancelled ? nil : failure
        } catch {
            guard current == categoryChangeGeneration else { return }
            categoryChangeFailure = .init(kind: .transport, message: "暂时无法取得分类影响。")
        }
    }

    public func commitPreviewedCategories() async -> BatchCategoryResult {
        guard !categoryChangeIsCommitting, let preview = categoryChangePreview else {
            return .init(succeededIDs: [], failures: [], queued: false)
        }
        categoryChangeGeneration &+= 1; let current = categoryChangeGeneration
        let key = UUID()
        categoryChangeIsCommitting = true
        categoryChangeFailure = nil
        defer {
            if current == categoryChangeGeneration { categoryChangeIsCommitting = false }
        }
        do {
            _ = try await services.actions.commitCategory(previewToken: preview.meta.previewToken, idempotencyKey: key)
            guard current == categoryChangeGeneration else { return .init(succeededIDs: [], failures: [], queued: false) }
            let committed = preview.items.map(\.transactionID)
            var refreshed: [UUID] = []
            var failures: [BatchCategoryFailure] = []
            for item in preview.items {
                do { let value = try await services.ledger.get(transactionID: item.transactionID, readCachePolicy: .reloadIgnoringCache); replaceInList(value); refreshed.append(value.id) }
                catch { failures.append(.init(id: item.transactionID, title: item.title, message: "已提交，但最新账目暂时无法读取。")) }
            }
            categoryChangePreview = nil
            return .init(succeededIDs: refreshed, committedIDs: committed, failures: failures, queued: false)
        } catch let failure as V15Failure {
            guard current == categoryChangeGeneration else { return .init(succeededIDs: [], failures: [], queued: false) }
            if V15LedgerCreateService.outcomeMayBeUnknown(failure) {
                return await reconcileCategoryReceipt(key: key, preview: preview, generation: current)
            }
            categoryChangeFailure = failure
            if failure.kind == .conflict { categoryChangePreview = nil }
            return .init(succeededIDs: [], failures: preview.items.map { .init(id: $0.transactionID, title: $0.title, message: failure.message) }, queued: false)
        } catch {
            guard current == categoryChangeGeneration else { return .init(succeededIDs: [], failures: [], queued: false) }
            return await reconcileCategoryReceipt(key: key, preview: preview, generation: current)
        }
    }

    private func reconcileCategoryReceipt(key: UUID, preview: V15CategoryChangePreview, generation: UInt64) async -> BatchCategoryResult {
        do {
            let receipt = try await services.actions.receipt(idempotencyKey: key)
            guard generation == categoryChangeGeneration, receipt.action == .categoryChange else { return .init(succeededIDs: [], failures: [], queued: false) }
            let committed = preview.items.map(\.transactionID)
            var refreshed: [UUID] = []
            var failures: [BatchCategoryFailure] = []
            for item in preview.items {
                if let value = try? await services.ledger.get(transactionID: item.transactionID, readCachePolicy: .reloadIgnoringCache) { replaceInList(value); refreshed.append(value.id) }
                else { failures.append(.init(id: item.transactionID, title: item.title, message: "已提交，但最新账目暂时无法读取。")) }
            }
            categoryChangePreview = nil
            return .init(succeededIDs: refreshed, committedIDs: committed, failures: failures, queued: false)
        } catch {
            guard generation == categoryChangeGeneration else { return .init(succeededIDs: [], failures: [], queued: false) }
            categoryChangePreview = nil
            let message = "结果暂时不明，请重新读取账目；不会自动重复提交。"
            categoryChangeFailure = .init(kind: .responseUnknown, code: "response_unknown", message: message)
            return .init(succeededIDs: [], failures: preview.items.map { .init(id: $0.transactionID, title: $0.title, message: message) }, queued: false)
        }
    }

    public func clearCategoryPreview() {
        guard !categoryChangeIsCommitting else { return }
        categoryChangeGeneration &+= 1; categoryChangePreview = nil; categoryChangeFailure = nil
    }
    public func disabledReason(for action: MutationAction, transaction: V15Transaction? = nil) -> V15DisabledReason? {
        guard let transaction = transaction ?? selected else {
            return .init(code: "transaction_required", message: "请先选择一笔账目。", fieldPath: nil)
        }
        if isOffline && action != .replace {
            return .init(code: "offline_read_only", message: "需要联网，当前暂时无法完成此操作。", fieldPath: nil)
        }
        switch action {
        case .replace:
            return V15ManualTransactionKind(rawValue: transaction.kind) == nil
                ? .init(code: "category_replace_unsupported", message: "这类系统账目不能修改分类。", fieldPath: nil)
                : nil
        case .void:
            guard let capability = transaction.availableActions.first(where: { $0.action == "void" }) else {
                return .init(code: "void_capability_missing", message: "当前状态不能作废。", fieldPath: nil)
            }
            return capability.enabled ? nil : .init(code: capability.reasonCode ?? "void_unavailable", message: capability.reasonMessage ?? "当前不能作废。", fieldPath: nil)
        case .restore:
            guard transaction.voidedAt != nil else {
                return .init(code: "transaction_not_voided", message: "只有已作废账目可以恢复。", fieldPath: nil)
            }
            if let capability = transaction.availableActions.first(where: { $0.action == "void" }),
               capability.reasonCode != "transaction_already_voided" {
                return .init(code: capability.reasonCode ?? "restore_unavailable", message: capability.reasonMessage ?? "当前不能恢复。", fieldPath: nil)
            }
            return nil
        }
    }
    public func accountName(_ id: UUID?) -> String { guard let id else { return "未提供账户" }; return accounts.first(where: { $0.id == id })?.name ?? "账户信息不可读取" }
    public func categoryName(_ id: UUID?) -> String { guard let id else { return "未分类" }; return categories.first(where: { $0.id == id })?.name ?? "分类信息不可读取" }
    public func transactionPresentation(_ transaction: V15Transaction) -> V15AccountTransactionPresentation {
        V15AccountTransactionPresenter.present(transaction, scopedAccountID: filter.accountID, accounts: accounts)
    }

    private func mutate(_ action: MutationAction) async {
        guard let selected else { return }; lastAction = action
        guard !isOffline else { mutation = .failed(.init(kind: .offlineReadOnly, code: "offline_read_only", message: "离线时只可查看，无法提交更改。")); return }
        guard action != .replace, disabledReason(for: action, transaction: selected) == nil else { return }
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
            let happened: Bool
            switch action {
            case .void: happened = result.0.voidedAt != nil
            case .restore: happened = result.0.voidedAt == nil
            case .replace: happened = result.0.categoryID == lastReplacementCategoryID
            }
            mutation = .reconciled(happened ? "连接恢复后已确认操作成功。" : "连接恢复后仍无法确认操作结果；请根据最新状态重新决定。")
        } catch { guard generation == mutationGeneration else { return }; mutation = .reconciled("连接中断，暂时无法确认操作结果；系统没有重复保存，请稍后重新加载。") }
    }

    private func loadSelectedCycle(for transaction: V15Transaction, generation: UInt64) async {
        guard let cycleID = transaction.creditCycleID else { return }
        let creditID = [transaction.accountID, transaction.destinationAccountID].compactMap { $0 }.first { id in accounts.first(where: { $0.id == id })?.kind == .credit }
        guard let creditID else { cycleReadError = "账期所属信用账户不可读取。"; return }
        do {
            let page = try await services.creditCycles.list(accountID: creditID)
            guard generation == detailGeneration, requestedDetailID == transaction.id else { return }
            selectedCycle = page.items.first(where: { $0.id == cycleID }); if selectedCycle == nil { cycleReadError = "没有找到对应账期。" }
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
