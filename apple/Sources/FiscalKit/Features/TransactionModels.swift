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

    private let repository: any TransactionRepository
    private let accounts: AccountsModel?
    private let categories: CategoriesModel?
    private let credit: CreditModel?
    private var debounceTask: Task<Void, Never>?
    private var pageTask: Task<TransactionPage, Error>?
    private var moreTask: Task<TransactionPage, Error>?
    private var generation = 0

    public init(repository: any TransactionRepository, accounts: AccountsModel? = nil, categories: CategoriesModel? = nil, credit: CreditModel? = nil) {
        self.repository = repository; self.accounts = accounts; self.categories = categories; self.credit = credit
    }
    public var selected: TransactionDTO? { transactions.first { $0.id == selectedID } }
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
        let snapshot = query()
        let hasData = !transactions.isEmpty
        if !hasData { phase = .loading }
        message = nil; refreshMessage = nil; conflictDetected = false
        let task = Task { try await repository.list(snapshot) }; pageTask = task
        do {
            let page = try await task.value
            guard current == generation, snapshot == query(), !Task.isCancelled else { return }
            transactions = page.items; nextCursor = page.nextCursor
            if let selectedID, !transactions.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
            phase = transactions.isEmpty ? .empty : .loaded
        } catch is CancellationError { if current == generation, !hasData { phase = .idle } }
        catch { guard current == generation else { return }; apply(error, preservingData: hasData) }
        if current == generation { pageTask = nil }
    }

    public func loadMoreIfNeeded(after item: TransactionDTO) async {
        guard item.id == transactions.last?.id, let cursor = nextCursor, !isLoadingMore else { return }
        let current = generation; var snapshot = query(); snapshot.cursor = cursor
        let baseQuery = query(); let knownCursor = nextCursor
        isLoadingMore = true; defer { isLoadingMore = false }
        let task = Task { try await repository.list(snapshot) }; moreTask = task
        do {
            let page = try await task.value
            guard current == generation, baseQuery == query(), knownCursor == nextCursor, !Task.isCancelled else { return }
            let known = Set(transactions.map(\.id)); transactions.append(contentsOf: page.items.filter { !known.contains($0.id) })
            nextCursor = page.nextCursor
        } catch is CancellationError {} catch { if current == generation, baseQuery == query() { refreshMessage = display(error) } }
        if current == generation { moreTask = nil }
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

    public static func shouldPreserveCreateKey(after error: Error) -> Bool {
        guard let api = error as? FiscalAPIError else { return true }
        return switch api { case .transport, .invalidResponse: true; case .unauthorized, .domain: false }
    }

    private func query() -> TransactionQuery { var value = TransactionQuery(); value.kind = kind; value.search = search.trimmingCharacters(in: .whitespacesAndNewlines); return value }
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
        _ = await (accountRefresh, categoryRefresh, creditRefresh)
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
        draft.kind = kind
        switch kind {
        case .transfer: draft.categoryID = nil; draft.creditCycleID = nil
        case .repayment: draft.categoryID = nil
        case .creditPurchase: draft.destinationAccountID = nil; draft.creditCycleID = nil
        case .expense, .income: draft.destinationAccountID = nil; draft.creditCycleID = nil
        }
    }
    public func rotateCreateKey() { if editing == nil { idempotencyKey = UUID() } }
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
        }
        return nil
    }
    private static func major(_ minor: Int64) -> String { NSDecimalNumber(decimal: Decimal(minor) / 100).stringValue }
}
