import Foundation
import Observation

public enum TransactionsPhase: Sendable, Equatable { case idle, loading, loaded, empty, unauthorized, offline, failed }

public struct TransactionDayGroup: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let items: [TransactionDTO]
}

@MainActor
@Observable
public final class TransactionsModel {
    public private(set) var transactions: [TransactionDTO] = []
    public private(set) var phase: TransactionsPhase = .idle
    public private(set) var message: String?
    public private(set) var refreshMessage: String?
    public private(set) var nextCursor: String?
    public private(set) var isLoadingMore = false
    public private(set) var isMutating = false
    public private(set) var conflictDetected = false
    public private(set) var undoTransaction: TransactionDTO?
    public private(set) var shouldRotateCreateKeyAfterFailure = false
    public private(set) var lastSavedTransaction: TransactionDTO?
    public var selectedID: UUID?
    public var kind: TransactionKind?
    public var search = ""
    public var accountID: UUID?
    public var categoryID: UUID?
    public var classification: TransactionClassificationFilter = .all
    public var source: String?
    public var dateFrom: Date?
    public var dateTo: Date?
    public var includeVoided = false
    public var amountMinMinor: Int64?
    public var amountMaxMinor: Int64?

    private let repository: any TransactionRepository
    private let accounts: AccountsModel?
    private let categories: CategoriesModel?
    private let credit: CreditModel?
    private let cashFlow: FutureCashFlowModel?
    private let reporting: ReportingInvalidationCoordinator?
    private var debounceTask: Task<Void, Never>?
    private var pageTask: Task<TransactionPage, Error>?
    private var moreTask: Task<TransactionPage, Error>?
    private var generation = 0
    private var loadMoreToken = 0

    public init(repository: any TransactionRepository, accounts: AccountsModel? = nil, categories: CategoriesModel? = nil, credit: CreditModel? = nil, cashFlow: FutureCashFlowModel? = nil, reporting: ReportingInvalidationCoordinator? = nil) {
        self.repository = repository; self.accounts = accounts; self.categories = categories; self.credit = credit; self.cashFlow = cashFlow; self.reporting = reporting
    }
    public var selected: TransactionDTO? { transactions.first { $0.id == selectedID } }
    public var totalCount: Int { transactions.count }
    public var hasAdvancedFilters: Bool {
        kind != nil || accountID != nil || categoryID != nil || classification != .all
            || source != nil || dateFrom != nil || dateTo != nil || includeVoided
            || amountMinMinor != nil || amountMaxMinor != nil
    }
    public var hasFilters: Bool { hasAdvancedFilters || !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var groups: [TransactionDayGroup] {
        let grouped = Dictionary(grouping: transactions, by: \.businessDate)
        return grouped.keys.sorted(by: >).map { date in .init(id: date, title: Self.dayTitle(date), items: grouped[date] ?? []) }
    }

    public func scheduleLoad() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    public func load() async {
        cancelRequests(); generation += 1; let current = generation
        let snapshot = currentQuery()
        let hasData = !transactions.isEmpty
        if !hasData { phase = .loading }
        message = nil; refreshMessage = nil; conflictDetected = false
        let task = Task { try await repository.list(snapshot) }; pageTask = task
        do {
            let page = try await task.value
            guard current == generation, snapshot == currentQuery(), !Task.isCancelled else { return }
            transactions = page.items; nextCursor = page.nextCursor
            if let selectedID, !transactions.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
            phase = transactions.isEmpty ? .empty : .loaded
        } catch is CancellationError { if current == generation, !hasData { phase = .idle } }
        catch { guard current == generation else { return }; apply(error, preservingData: hasData) }
        if current == generation { pageTask = nil }
    }

    public func loadMoreIfNeeded(after item: TransactionDTO) async {
        guard item.id == transactions.last?.id, let cursor = nextCursor, !isLoadingMore else { return }
        loadMoreToken += 1; let token = loadMoreToken
        let current = generation; var snapshot = currentQuery(); snapshot.cursor = cursor
        let baseQuery = currentQuery(); let knownCursor = nextCursor
        isLoadingMore = true
        let task = Task { try await repository.list(snapshot) }; moreTask = task
        // Only the request that currently owns the paging slot may clear the flag, so a cancelled
        // older request can't reset the loading flag a newer request just set (L14).
        defer { if token == loadMoreToken { isLoadingMore = false; moreTask = nil } }
        do {
            let page = try await task.value
            guard current == generation, baseQuery == currentQuery(), knownCursor == nextCursor, !Task.isCancelled else { return }
            let known = Set(transactions.map(\.id)); transactions.append(contentsOf: page.items.filter { !known.contains($0.id) })
            nextCursor = page.nextCursor
        } catch is CancellationError {} catch { if current == generation, baseQuery == currentQuery() { refreshMessage = display(error) } }
    }

    public func save(draft: TransactionDraft, editing: TransactionDTO?, idempotencyKey: UUID) async -> Bool {
        if let validation = TransactionEditorModel.validate(draft) { message = validation; return false }
        guard !isMutating else { return false }
        beginMutation(); let current = generation
        shouldRotateCreateKeyAfterFailure = false
        isMutating = true; conflictDetected = false; defer { isMutating = false }
        do {
            let canonical = if let editing { try await repository.update(id: editing.id, version: editing.version, draft: draft) }
            else { try await repository.create(draft, idempotencyKey: idempotencyKey) }
            guard current == generation else { return false }
            lastSavedTransaction = canonical
            await refreshAfterMutation(); return true
        } catch is CancellationError { return false }
        catch {
            if editing == nil { shouldRotateCreateKeyAfterFailure = !Self.shouldPreserveCreateKey(after: error) }
            guard current == generation else { return false }; apply(error, preservingData: !transactions.isEmpty); return false
        }
    }

    public func void(_ transaction: TransactionDTO) async -> Bool {
        guard !isMutating else { return false }
        beginMutation(); let current = generation
        isMutating = true; defer { isMutating = false }
        do {
            let voided = try await repository.void(transaction)
            guard current == generation else { return false }; undoTransaction = voided
            await refreshAfterMutation(); return true
        } catch is CancellationError { return false } catch { guard current == generation else { return false }; apply(error, preservingData: !transactions.isEmpty); return false }
    }

    public func undoVoid() async -> Bool {
        guard let transaction = undoTransaction else { return false }
        guard !isMutating else { return false }
        beginMutation(); let current = generation
        isMutating = true; defer { isMutating = false }
        do { _ = try await repository.restore(transaction); guard current == generation else { return false }; undoTransaction = nil; await refreshAfterMutation(); return true }
        catch is CancellationError { return false } catch { guard current == generation else { return false }; apply(error, preservingData: !transactions.isEmpty); return false }
    }
    public func clearUndo() { undoTransaction = nil }
    public func clearConflict() { conflictDetected = false }
    public func clearMessage() { message = nil; refreshMessage = nil }
    public func resetDates() { dateFrom = nil; dateTo = nil }

    public func exportCSV() async throws -> Data {
        try await repository.exportCSV(currentQuery())
    }

    public func batchClassify(
        items: [TransactionBatchClassificationItem], categoryID: UUID
    ) async -> Bool {
        guard !isMutating else { return false }
        guard !items.isEmpty else { message = "没有可重新分类的流水，请重新选择。"; return false }
        beginMutation(); let current = generation
        isMutating = true; defer { isMutating = false }
        do {
            _ = try await repository.batchClassify(
                .init(items: items, categoryID: categoryID))
            guard current == generation else { return false }
            await refreshAfterMutation(); return true
        } catch is CancellationError { return false }
        catch {
            guard current == generation else { return false }
            apply(error, preservingData: !transactions.isEmpty); return false
        }
    }

    public static func shouldPreserveCreateKey(after error: Error) -> Bool {
        guard let api = error as? FiscalAPIError else { return true }
        return switch api {
        case .transport, .invalidResponse, .rateLimited: true
        case .unauthorized, .domain: false
        }
    }

    /// A detached copy of the filter fields, edited in a sheet/popover and only written back on
    /// "应用" so dismissing without applying leaves the applied filters (and the list) untouched.
    public struct FilterDraft: Equatable, Sendable {
        public var kind: TransactionKind?
        public var accountID: UUID?
        public var categoryID: UUID?
        public var classification: TransactionClassificationFilter = .all
        public var source: String?
        public var dateFrom: Date?
        public var dateTo: Date?
        public var includeVoided = false
        public var amountMinMinor: Int64?
        public var amountMaxMinor: Int64?
        public init() {}
    }
    public func currentFilterDraft() -> FilterDraft {
        var draft = FilterDraft()
        draft.kind = kind; draft.accountID = accountID; draft.categoryID = categoryID
        draft.classification = classification; draft.source = source
        draft.dateFrom = dateFrom; draft.dateTo = dateTo; draft.includeVoided = includeVoided
        draft.amountMinMinor = amountMinMinor; draft.amountMaxMinor = amountMaxMinor
        return draft
    }
    public func applyFilters(_ draft: FilterDraft) async {
        kind = draft.kind; accountID = draft.accountID; categoryID = draft.categoryID
        classification = draft.classification; source = draft.source
        dateFrom = draft.dateFrom; dateTo = draft.dateTo; includeVoided = draft.includeVoided
        amountMinMinor = draft.amountMinMinor; amountMaxMinor = draft.amountMaxMinor
        await load()
    }

    /// A normalized value snapshot safe to hand to paging and export operations.
    public func currentQuery() -> TransactionQuery {
        var value = TransactionQuery()
        value.kind = kind; value.accountID = accountID; value.categoryID = categoryID
        value.classification = classification; value.source = source
        value.dateFrom = dateFrom.map(Self.apiDate); value.dateTo = dateTo.map(Self.apiDate)
        value.includeVoided = includeVoided
        value.amountMinMinor = amountMinMinor; value.amountMaxMinor = amountMaxMinor
        value.search = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }
    private func cancelRequests() {
        pageTask?.cancel(); moreTask?.cancel(); pageTask = nil; moreTask = nil; isLoadingMore = false
    }
    private func beginMutation() {
        debounceTask?.cancel(); cancelRequests(); generation += 1; message = nil; refreshMessage = nil; conflictDetected = false
    }
    private func refreshAfterMutation() async {
        async let masterRefresh: Void = refreshMasterData()
        await load()
        _ = await masterRefresh
    }
    private func refreshMasterData() async {
        async let accountRefresh: Void = accounts?.load() ?? ()
        async let categoryRefresh: Void = categories?.load() ?? ()
        async let creditRefresh: Void = credit?.refreshCurrentSelection() ?? ()
        async let cashFlowRefresh: Void = cashFlow?.load() ?? ()
        async let reportingRefresh: Void = reporting?.refresh() ?? ()
        _ = await (accountRefresh, categoryRefresh, creditRefresh, cashFlowRefresh, reportingRefresh)
    }
    private func apply(_ error: Error, preservingData: Bool) {
        let text = display(error); message = text
        if let api = error as? FiscalAPIError, case .domain(_, let detail) = api, detail.code == "resource_version_conflict" {
            conflictDetected = true
            if preservingData { refreshMessage = text; phase = .loaded } else { phase = .failed }
            return
        }
        if preservingData { refreshMessage = text; phase = .loaded; return }
        guard let api = error as? FiscalAPIError else { phase = .failed; return }
        switch api {
        case .unauthorized: phase = .unauthorized
        case .transport: phase = .offline
        case .domain(_, let detail) where detail.code == "resource_version_conflict": phase = .failed; conflictDetected = true
        default: phase = .failed
        }
    }
    private func display(_ error: Error) -> String { (error as? FiscalAPIError)?.displayMessage ?? error.localizedDescription }
    private static func dayTitle(_ date: String) -> String {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian); formatter.locale = Locale(identifier: "zh_CN"); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
        guard let value = formatter.date(from: date) else { return date }
        let calendar = formatter.calendar!; if calendar.isDateInToday(value) { return "今天" }; if calendar.isDateInYesterday(value) { return "昨天" }
        formatter.dateFormat = "M月d日 EEEE"; return formatter.string(from: value)
    }
    private static func apiDate(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: date)
    }
}

@MainActor
@Observable
public final class TransactionEditorModel {
    public var draft: TransactionDraft
    public var amountText: String
    public private(set) var idempotencyKey: UUID
    public private(set) var validationMessage: String?
    public let editing: TransactionDTO?

    public init(editing: TransactionDTO? = nil) {
        self.editing = editing; draft = editing.map(TransactionDraft.init(transaction:)) ?? TransactionDraft()
        amountText = editing.map { Self.major($0.amountMinor) } ?? ""; idempotencyKey = UUID()
    }
    public func prepare() -> Bool {
        guard let amount = CNYAmountParser.minorUnits(amountText), amount > 0 else { validationMessage = "金额必须是大于 0 且最多两位小数的数值。"; return false }
        draft.amountMinor = amount; validationMessage = Self.validate(draft); return validationMessage == nil
    }
    public func changeKind(_ kind: TransactionKind) {
        let previous = draft.kind
        draft.kind = kind
        // Drop references that become invalid for the new kind's direction/account semantics so a
        // stale value (which a constrained Picker renders as blank) can never survive a kind switch
        // and be written with the wrong direction or account type.
        if Self.categoryDirection(kind) != Self.categoryDirection(previous) { draft.categoryID = nil }
        if Self.requiresCreditAccount(kind) != Self.requiresCreditAccount(previous) { draft.accountID = nil }
        if Self.destinationRole(kind) != Self.destinationRole(previous) { draft.destinationAccountID = nil }
        if kind != .repayment { draft.creditCycleID = nil }
        if case .installmentFee = kind { draft.accountID = nil }
        if case .installmentRefund = kind { draft.accountID = nil }
        if case .reimbursementReceipt = kind { draft.accountID = nil }
    }
    /// The category direction each kind requires, or nil when the kind carries no category.
    static func categoryDirection(_ kind: TransactionKind) -> CategoryDirection? {
        switch kind { case .income: .income; case .expense, .creditPurchase: .expense; default: nil }
    }
    /// Credit purchases post to a credit account; every other kind uses a non-credit account.
    static func requiresCreditAccount(_ kind: TransactionKind) -> Bool { kind == .creditPurchase }
    /// The destination-account role: transfers name a non-credit target, repayments a credit
    /// target, and these are not interchangeable; every other kind has no destination.
    static func destinationRole(_ kind: TransactionKind) -> Int {
        switch kind { case .transfer: 1; case .repayment: 2; default: 0 }
    }
    public func rotateCreateKey() { if editing == nil { idempotencyKey = UUID() } }
    public func apply(preferences: RecordingPreferences, accounts: [AccountDTO]) {
        guard editing == nil else { return }
        changeKind(preferences.defaultKind.transactionKind)
        draft.accountID = preferences.validatedDefaultAccount(in: accounts)
    }
    public func resetForNextEntry(validAccounts: [AccountDTO]) {
        guard editing == nil else { return }
        let retainedKind = draft.kind
        let retainedAccount = draft.accountID.flatMap { id in
            validAccounts.contains(where: {
                $0.id == id && $0.archivedAt == nil
                    && (retainedKind == .creditPurchase ? $0.kind == .credit : ($0.kind == .cash || $0.kind == .debit))
            }) ? id : nil
        }
        draft = TransactionDraft()
        changeKind(retainedKind)
        draft.accountID = retainedAccount
        amountText = ""
        validationMessage = nil
        idempotencyKey = UUID()
    }
    public static func validate(_ draft: TransactionDraft) -> String? {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title.count > 120 { return "标题需要 1–120 个字符。" }
        if draft.note.trimmingCharacters(in: .whitespacesAndNewlines).count > 500 { return "备注不能超过 500 个字符。" }
        if draft.amountMinor <= 0 { return "金额必须大于 0。" }
        switch draft.kind {
        case .expense, .income: if draft.accountID == nil || draft.categoryID == nil { return "请选择账户和对应方向的分类。" }
        case .transfer:
            guard let source = draft.accountID, let destination = draft.destinationAccountID else { return "请选择转出和转入账户。" }
            if source == destination { return "转出和转入账户不能相同。" }
        case .creditPurchase: if draft.accountID == nil || draft.categoryID == nil { return "请选择信用账户和支出分类。" }
        case .repayment:
            guard let source = draft.accountID, let destination = draft.destinationAccountID, draft.creditCycleID != nil else { return "请选择付款账户、信用账户和目标账期。" }
            if source == destination { return "付款账户和信用账户不能相同。" }
        case .installmentFee, .installmentRefund, .reimbursementReceipt: return "系统流水不能手工创建或编辑。"
        }
        return nil
    }
    /// Type/direction consistency for the chosen references, checked where the account and category
    /// objects are available. Only fires when a reference is present but wrong-typed for the kind,
    /// so it defends against a stale reference surviving a kind switch without rejecting empty ones
    /// (those are `validate`'s job).
    public static func validateReferences(
        _ draft: TransactionDraft, accounts: [AccountDTO], categories: [CategoryDTO]
    ) -> String? {
        func account(_ id: UUID?) -> AccountDTO? { id.flatMap { id in accounts.first { $0.id == id } } }
        func category(_ id: UUID?) -> CategoryDTO? {
            id.flatMap { id in categories.first { $0.id == id } }
        }
        switch draft.kind {
        case .expense, .income:
            if let category = category(draft.categoryID), category.direction != categoryDirection(draft.kind) {
                return "所选分类方向与记账类型不一致。"
            }
            if account(draft.accountID)?.kind == .credit {
                return "收支请使用现金或储蓄账户；信用卡消费应选择“信用消费”。"
            }
        case .creditPurchase:
            if let category = category(draft.categoryID), category.direction != .expense {
                return "信用消费只能选择支出分类。"
            }
            if let account = account(draft.accountID), account.kind != .credit {
                return "信用消费必须选择信用账户。"
            }
        case .transfer:
            if account(draft.accountID)?.kind == .credit || account(draft.destinationAccountID)?.kind == .credit {
                return "转账的转出和转入账户都不能是信用账户。"
            }
        case .repayment:
            if account(draft.accountID)?.kind == .credit {
                return "还款的付款账户不能是信用账户。"
            }
            if let destination = account(draft.destinationAccountID), destination.kind != .credit {
                return "还款的目标账户必须是信用账户。"
            }
        case .installmentFee, .installmentRefund, .reimbursementReceipt: break
        }
        return nil
    }
    private static func major(_ minor: Int64) -> String { NSDecimalNumber(decimal: Decimal(minor) / 100).stringValue }
}
