import Foundation
import Observation

@MainActor @Observable
public final class V15RecordModel {
    public enum LoadPhase: Equatable { case idle, loading, loaded, empty, failed(String) }
    public enum Submission: Equatable { case idle, submitting, success(V15Transaction), conflict(V15Conflict), failed(V15Failure) }

    public var kind: V15ManualTransactionKind = .expense { didSet { guard oldValue != kind else { return }; changeKind(from: oldValue) } }
    public var amountText = "" { didSet { guard oldValue != amountText else { return }; inputChanged() } }
    public var title = "" { didSet { guard oldValue != title else { return }; inputChanged() } }
    public var note = "" { didSet { guard oldValue != note else { return }; inputChanged() } }
    public var occurredOn = Date() { didSet { guard oldValue != occurredOn else { return }; inputChanged() } }
    public var accountID: UUID? { didSet { guard oldValue != accountID, !isReconcilingReferences else { return }; inputChanged() } }
    public var destinationAccountID: UUID? { didSet { guard oldValue != destinationAccountID, !isReconcilingReferences else { return }; destinationChanged() } }
    public var categoryID: UUID? { didSet { guard oldValue != categoryID, !isReconcilingReferences else { return }; inputChanged() } }
    public var creditCycleID: UUID? { didSet { guard oldValue != creditCycleID, !isReconcilingReferences else { return }; inputChanged() } }
    public private(set) var accounts: [V15AccountResponse] = []
    public private(set) var categories: [V15CategoryResponse] = []
    public private(set) var creditCycles: [V15CreditCycle] = []
    public private(set) var accountPhase: LoadPhase = .idle
    public private(set) var categoryPhase: LoadPhase = .idle
    public private(set) var creditCyclePhase: LoadPhase = .idle
    public private(set) var submission: Submission = .idle
    public private(set) var fieldIssues: [V15FieldIssue] = []
    public private(set) var localIssues: [V15FieldIssue] = []

    private var accountsGeneration: UInt64 = 0
    private var categoriesGeneration: UInt64 = 0
    private var creditCyclesGeneration: UInt64 = 0
    private var submitGeneration: UInt64 = 0
    private var draftRevision: UInt64 = 0
    private var activePayloadIdentity: String?
    private var isReconcilingReferences = false
    private let idempotency = V15IdempotencyOwner()
    private let services: V15Services
    private let createScope = "transaction-create"

    public init(services: V15Services, occurredOn: Date = Date()) {
        self.services = services
        self.occurredOn = occurredOn
        validate()
    }
    public var allIssues: [V15FieldIssue] { localIssues + fieldIssues }
    public var isOffline: Bool { services.offlineSnapshotAt != nil }

    public func loadReferences() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadAccounts() }
            group.addTask { await self.loadCategories() }
        }
    }

    public func loadAccounts() async {
        accountsGeneration &+= 1; let current = accountsGeneration; accountPhase = .loading
        do {
            let value = try await services.masterData.activeAccounts()
            guard current == accountsGeneration else { return }
            accounts = value.filter(\.isActive)
            accountPhase = accounts.isEmpty ? .empty : .loaded
            reconcileReferencesForCurrentKind()
            validate()
        } catch is CancellationError {
            guard current == accountsGeneration else { return }; accountPhase = .idle
        } catch {
            guard current == accountsGeneration else { return }; accountPhase = .failed(message(for: error)); validate()
        }
    }

    public func loadCategories() async {
        categoriesGeneration &+= 1; let current = categoriesGeneration
        guard let direction = categoryDirection else {
            categories = []; categoryPhase = .idle; validate(); return
        }
        categoryPhase = .loading
        do {
            let value = try await services.masterData.activeCategories(direction: direction)
            guard current == categoriesGeneration else { return }
            categories = flatten(value).filter { $0.archivedAt == nil && $0.direction == direction.rawValue }
            categoryPhase = categories.isEmpty ? .empty : .loaded
            validate()
        } catch is CancellationError {
            guard current == categoriesGeneration else { return }; categoryPhase = .idle
        } catch {
            guard current == categoriesGeneration else { return }; categoryPhase = .failed(message(for: error)); validate()
        }
    }

    public func loadCreditCycles(for accountID: UUID? = nil) async {
        creditCyclesGeneration &+= 1; let current = creditCyclesGeneration
        guard kind == .repayment, let accountID = accountID ?? destinationAccountID, destinationAccountID == accountID else {
            creditCycles = []; creditCyclePhase = .idle; validate(); return
        }
        creditCyclePhase = .loading
        do {
            let page = try await services.creditCycles.list(accountID: accountID)
            guard isCurrentCreditCycleLoad(current, accountID: accountID) else { return }
            creditCycles = page.items.filter { $0.accountID == accountID && $0.status != .settled && $0.status != .unknown }
            creditCyclePhase = creditCycles.isEmpty ? .empty : .loaded
            validate()
        } catch is CancellationError {
            guard isCurrentCreditCycleLoad(current, accountID: accountID) else { return }; creditCyclePhase = .idle
        } catch {
            guard isCurrentCreditCycleLoad(current, accountID: accountID) else { return }; creditCyclePhase = .failed(message(for: error)); validate()
        }
    }

    public func retryReferences() async { await loadReferences() }
    public func retryCreditCycles() async { await loadCreditCycles() }

    public func submit() async {
        validate(); guard localIssues.isEmpty else { return }
        if isOffline {
            submission = .failed(.init(kind: .offlineReadOnly, code: "offline_read_only", message: "离线快照仅可查看，无法提交更改。")); return
        }
        guard let request = request(), let identity = payloadIdentity(for: request) else { validate(); return }
        submitGeneration &+= 1; let current = submitGeneration; submission = .submitting; fieldIssues = []
        activePayloadIdentity = identity
        let key = idempotency.key(for: createScope, payloadIdentity: identity)
        do {
            let created = try await services.ledger.create(request, idempotencyKey: key)
            guard current == submitGeneration else { return }
            releaseActiveKey(); submission = .success(created)
        } catch is CancellationError {
            guard current == submitGeneration else { return }; submission = .idle
        } catch let failure as V15Failure {
            guard current == submitGeneration else { return }
            if releasesKey(after: failure) { releaseActiveKey() }
            if failure.kind == .conflict, let conflict = failure.conflict { submission = .conflict(conflict) }
            else { fieldIssues = failure.fieldIssues; submission = .failed(failure) }
        } catch {
            // A non-classified transport exception has unknown server outcome.
            // Keep its payload-bound key so explicit retry cannot duplicate it.
            guard current == submitGeneration else { return }
            submission = .failed(.init(kind: .responseUnknown, code: "response_unknown", message: "连接在服务器确认前中断；请使用同一请求凭证重试。"))
        }
    }

    /// A 409 never replays blindly. Reload the authoritative references, then
    /// puts the user back in the decision state with the same visible inputs.
    public func reloadAfterConflict() async { submission = .idle; await loadReferences(); if kind == .repayment { await loadCreditCycles() } }
    public func dismiss() { submitGeneration &+= 1; releaseActiveKey(); submission = .idle; fieldIssues = [] }

    public func newEntry() {
        dismiss()
        amountText = ""; title = ""; note = ""; accountID = nil; destinationAccountID = nil; categoryID = nil; creditCycleID = nil
        kind = .expense
    }

    private var categoryDirection: V15CategoryDirection? {
        switch kind { case .income: .income; case .expense, .creditPurchase: .expense; case .transfer, .repayment: nil }
    }

    private func inputChanged() {
        draftRevision &+= 1; submitGeneration &+= 1; releaseActiveKey(); fieldIssues = []
        if case .idle = submission {} else { submission = .idle }
        validate()
    }

    private func destinationChanged() {
        invalidateCreditCycles()
        inputChanged()
    }

    private func changeKind(from old: V15ManualTransactionKind) {
        let previousDirection = categoryDirection(for: old)
        let nextDirection = categoryDirection
        invalidateCreditCycles()
        isReconcilingReferences = true
        categoryID = nil
        if !isAllowedSource(accountID, for: kind) { accountID = nil }
        if !isAllowedDestination(destinationAccountID, for: kind, sourceID: accountID) { destinationAccountID = nil }
        isReconcilingReferences = false
        categoriesGeneration &+= 1
        if previousDirection != nextDirection {
            categories = []; categoryPhase = .idle
        }
        inputChanged()
    }

    private func reconcileReferencesForCurrentKind() {
        let sourceIsAllowed = isAllowedSource(accountID, for: kind)
        let destinationIsAllowed = isAllowedDestination(destinationAccountID, for: kind, sourceID: accountID)
        guard !sourceIsAllowed || !destinationIsAllowed else { return }
        invalidateCreditCycles()
        isReconcilingReferences = true
        if !sourceIsAllowed { accountID = nil }
        if !isAllowedDestination(destinationAccountID, for: kind, sourceID: accountID) { destinationAccountID = nil }
        isReconcilingReferences = false
        inputChanged()
    }

    private func isAllowedSource(_ id: UUID?, for kind: V15ManualTransactionKind) -> Bool {
        guard let id else { return true }
        guard let account = accounts.first(where: { $0.id == id }) else { return false }
        switch kind {
        case .expense, .income, .transfer, .repayment: return account.kind == .cash || account.kind == .debit
        case .creditPurchase: return account.kind == .credit
        }
    }

    private func isAllowedDestination(_ id: UUID?, for kind: V15ManualTransactionKind, sourceID: UUID?) -> Bool {
        guard let id else { return true }
        guard let account = accounts.first(where: { $0.id == id }) else { return false }
        switch kind {
        case .transfer: return (account.kind == .cash || account.kind == .debit) && id != sourceID
        case .repayment: return account.kind == .credit
        case .expense, .income, .creditPurchase: return false
        }
    }

    private func invalidateCreditCycles() {
        creditCyclesGeneration &+= 1
        isReconcilingReferences = true
        creditCycleID = nil
        isReconcilingReferences = false
        creditCycles = []
        creditCyclePhase = .idle
    }

    private func isCurrentCreditCycleLoad(_ generation: UInt64, accountID: UUID) -> Bool {
        generation == creditCyclesGeneration && kind == .repayment && destinationAccountID == accountID
    }

    private func categoryDirection(for kind: V15ManualTransactionKind) -> V15CategoryDirection? {
        switch kind { case .income: .income; case .expense, .creditPurchase: .expense; case .transfer, .repayment: nil }
    }

    private func flatten(_ source: [V15CategoryResponse]) -> [V15CategoryResponse] { source + source.flatMap { flatten($0.children) } }

    private func request() -> V15TransactionCreateRequest? {
        guard let amount = CNYAmountParser.minorUnits(amountText), amount > 0 else { return nil }
        return .init(kind: kind, amountMinor: amount, occurredAt: shanghaiInstant(occurredOn), title: title.trimmingCharacters(in: .whitespacesAndNewlines), note: note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty, accountID: accountID, categoryID: categoryID, destinationAccountID: destinationAccountID, creditCycleID: creditCycleID)
    }

    private func payloadIdentity(for request: V15TransactionCreateRequest) -> String? {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(request) else { return nil }
        // Revision preserves the invariant that editing then restoring text is
        // still a new user decision and must receive a fresh create key.
        return "\(draftRevision):\(data.base64EncodedString())"
    }

    private func releaseActiveKey() {
        guard let activePayloadIdentity else { return }
        idempotency.abandon(scope: createScope, payloadIdentity: activePayloadIdentity)
        self.activePayloadIdentity = nil
    }

    private func releasesKey(after failure: V15Failure) -> Bool {
        switch failure.kind {
        case .conflict, .offlineReadOnly: true
        case .transport: failure.code != nil // HTTP response was received (validation/auth/rate limit).
        case .responseUnknown, .decoding, .cancelled: false
        }
    }

    private func validate() {
        var issues: [V15FieldIssue] = []
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(.init(code: "title_required", message: "请填写账目名称。", fieldPath: "title")) }
        guard let amount = CNYAmountParser.minorUnits(amountText), amount > 0 else {
            issues.append(.init(code: "amount_invalid", message: "金额须为大于 0 的元金额，且最多两位小数。", fieldPath: "amount_minor")); localIssues = issues; return
        }
        _ = amount
        let selected = accounts.first { $0.id == accountID }
        let destination = accounts.first { $0.id == destinationAccountID }
        let category = categories.first { $0.id == categoryID }
        switch kind {
        case .expense, .income:
            if selected?.kind != .cash && selected?.kind != .debit { issues.append(.init(code: "cash_or_debit_account_required", message: "收支需要选择现金或借记账户。", fieldPath: "account_id")) }
            if destinationAccountID != nil { issues.append(.init(code: "destination_not_allowed", message: "此类型不使用目标账户。", fieldPath: "destination_account_id")) }
            if creditCycleID != nil { issues.append(.init(code: "credit_cycle_not_allowed", message: "此类型不使用信用账期。", fieldPath: "credit_cycle_id")) }
            validateCategory(category, expected: categoryDirection, issues: &issues)
        case .creditPurchase:
            if selected?.kind != .credit { issues.append(.init(code: "credit_account_required", message: "信用卡消费需要选择信用账户。", fieldPath: "account_id")) }
            if destinationAccountID != nil { issues.append(.init(code: "destination_not_allowed", message: "信用卡消费不使用目标账户。", fieldPath: "destination_account_id")) }
            if creditCycleID != nil { issues.append(.init(code: "credit_cycle_server_owned", message: "信用卡消费账期由服务器按业务日期确定。", fieldPath: "credit_cycle_id")) }
            validateCategory(category, expected: .expense, issues: &issues)
        case .transfer:
            if selected?.kind != .cash && selected?.kind != .debit { issues.append(.init(code: "source_account_type", message: "转出账户必须是现金或借记账户。", fieldPath: "account_id")) }
            if destination?.kind != .cash && destination?.kind != .debit { issues.append(.init(code: "destination_account_type", message: "转入账户必须是现金或借记账户。", fieldPath: "destination_account_id")) }
            if accountID != nil && accountID == destinationAccountID { issues.append(.init(code: "transfer_same_account", message: "转出与转入账户不能相同。", fieldPath: "destination_account_id")) }
            validateNoCategoryOrCycle(&issues)
        case .repayment:
            if selected?.kind != .cash && selected?.kind != .debit { issues.append(.init(code: "repayment_source_type", message: "还款账户必须是现金或借记账户。", fieldPath: "account_id")) }
            if destination?.kind != .credit { issues.append(.init(code: "repayment_destination_type", message: "还款目标必须是信用账户。", fieldPath: "destination_account_id")) }
            if creditCyclePhase == .loading { issues.append(.init(code: "credit_cycles_loading", message: "正在加载可用信用账期。", fieldPath: "credit_cycle_id")) }
            else if creditCycleID == nil { issues.append(.init(code: "credit_cycle_required", message: "请选择可用的信用账期。", fieldPath: "credit_cycle_id")) }
            else if creditCycles.first(where: { $0.id == creditCycleID && $0.accountID == destinationAccountID }) == nil { issues.append(.init(code: "credit_cycle_unavailable", message: "所选信用账期不可用，请重新选择。", fieldPath: "credit_cycle_id")) }
            validateNoCategoryOrCycle(&issues, allowsCycle: true)
        }
        if isOffline { issues.append(.init(code: "offline_read_only", message: "离线快照仅可查看，无法提交更改。", fieldPath: nil)) }
        localIssues = issues
    }

    private func validateCategory(_ category: V15CategoryResponse?, expected: V15CategoryDirection?, issues: inout [V15FieldIssue]) {
        guard categoryID != nil else { return }
        guard let expected, let category, category.direction == expected.rawValue else {
            issues.append(.init(code: "category_unavailable", message: "所选分类不可用于此类型，请重新选择。", fieldPath: "category_id")); return
        }
    }

    private func validateNoCategoryOrCycle(_ issues: inout [V15FieldIssue], allowsCycle: Bool = false) {
        if categoryID != nil { issues.append(.init(code: "category_not_allowed", message: "此类型不使用分类。", fieldPath: "category_id")) }
        if !allowsCycle && creditCycleID != nil { issues.append(.init(code: "credit_cycle_not_allowed", message: "此类型不使用信用账期。", fieldPath: "credit_cycle_id")) }
    }

    private func shanghaiInstant(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.locale = Locale(identifier: "zh_CN"); calendar.timeZone = ShanghaiBusinessDate.timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return calendar.date(from: DateComponents(timeZone: ShanghaiBusinessDate.timeZone, year: parts.year, month: parts.month, day: parts.day, hour: 12)) ?? date
    }

    private func message(for error: Error) -> String { (error as? V15Failure)?.message ?? "暂时无法取得数据。" }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
