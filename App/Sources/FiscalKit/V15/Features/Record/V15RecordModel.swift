import Foundation
import Observation

@MainActor @Observable
public final class V15RecordModel {
    public enum LoadPhase: Equatable { case idle, loading, loaded, empty, failed(String) }
    public enum PreviewPhase: Equatable { case idle, loading, ready(V15RepaymentPreview), failed(V15Failure) }
    public enum Submission: Equatable { case idle, submitting, queued(UUID), success(V15Transaction), conflict(V15Conflict), failed(V15Failure) }
    public enum CommitOutcome: Equatable, Sendable { case confirmed(V15Transaction), queued(UUID) }

    public var kind: V15ManualTransactionKind = .expense { didSet { guard oldValue != kind, !isResettingDraft else { return }; changeKind(from: oldValue) } }
    public var amountText = "" { didSet { guard oldValue != amountText else { return }; inputChanged() } }
    public var title = "" { didSet { guard oldValue != title else { return }; inputChanged() } }
    public var note = "" { didSet { guard oldValue != note else { return }; inputChanged() } }
    public var occurredOn = Date() { didSet { guard oldValue != occurredOn else { return }; inputChanged() } }
    public var accountID: UUID? { didSet { guard oldValue != accountID, !isReconcilingReferences, !isResettingDraft else { return }; inputChanged() } }
    public var destinationAccountID: UUID? { didSet { guard oldValue != destinationAccountID, !isReconcilingReferences, !isResettingDraft else { return }; destinationChanged() } }
    public var categoryID: UUID? { didSet { guard oldValue != categoryID, !isReconcilingReferences, !isResettingDraft else { return }; inputChanged() } }
    public var creditCycleID: UUID? { didSet { guard oldValue != creditCycleID, !isReconcilingReferences, !isResettingDraft else { return }; inputChanged() } }
    public private(set) var accounts: [V15AccountResponse] = []
    public private(set) var categories: [V15CategoryResponse] = []
    public private(set) var creditCycles: [V15CreditCycle] = []
    public private(set) var accountPhase: LoadPhase = .idle
    public private(set) var categoryPhase: LoadPhase = .idle
    public private(set) var creditCyclePhase: LoadPhase = .idle
    public private(set) var submission: Submission = .idle
    public private(set) var repaymentPreviewPhase: PreviewPhase = .idle
    public private(set) var fieldIssues: [V15FieldIssue] = []
    public private(set) var localIssues: [V15FieldIssue] = []

    private var isPresented = true
    private var activeJournalID: UUID?
    private var activeJournalKind: V15PendingWriteStore.Kind?
    public var hasUnresolvedSubmission: Bool { activeJournalID != nil }
    private var accountsGeneration: UInt64 = 0
    private var categoriesGeneration: UInt64 = 0
    private var creditCyclesGeneration: UInt64 = 0
    private var previewGeneration: UInt64 = 0
    private var draftRevision: UInt64 = 0
    private var previewPayloadIdentity: String?
    private var isReconcilingReferences = false
    private var isResettingDraft = false
    private let services: V15Services

    public init(services: V15Services, occurredOn: Date = Date()) {
        self.services = services
        self.occurredOn = occurredOn
        validate()
    }
    public var isOnDemandRepayment: Bool { kind == .repayment && accounts.first(where: { $0.id == destinationAccountID })?.cycleMode == "on_demand" }
    public var repaymentRemainingMinor: Int64? {
        guard kind == .repayment else { return nil }
        if isOnDemandRepayment {
            guard let balance = accounts.first(where: { $0.id == destinationAccountID })?.currentBalanceMinor else { return nil }
            return max(balance, 0)
        }
        return creditCycles.first(where: { $0.id == creditCycleID })?.remainingMinor
    }
    public var allIssues: [V15FieldIssue] { localIssues + fieldIssues }
    public var isOffline: Bool { services.offlineSnapshotAt != nil }

    public func loadReferences() async {
        isPresented = true
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
        if isOnDemandRepayment { creditCycles = []; creditCycleID = nil; creditCyclePhase = .loaded; validate(); return }
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

    public func previewRepayment() async {
        validate()
        guard kind == .repayment, localIssues.isEmpty, let request = request(), let identity = payloadIdentity(for: request), !isOffline else { return }
        previewGeneration &+= 1; let current = previewGeneration
        repaymentPreviewPhase = .loading; fieldIssues = []
        do {
            let preview = try await services.actions.repaymentPreview(request)
            guard current == previewGeneration, identity == payloadIdentity(for: request) else { return }
            previewPayloadIdentity = identity
            repaymentPreviewPhase = .ready(preview)
        } catch let failure as V15Failure {
            guard current == previewGeneration else { return }
            repaymentPreviewPhase = failure.kind == .cancelled ? .idle : .failed(failure)
        } catch {
            guard current == previewGeneration else { return }
            repaymentPreviewPhase = .failed(.init(kind: .transport, message: "暂时无法取得还款影响。"))
        }
    }

    public func submit() async -> CommitOutcome? {
        if case .submitting = submission { return nil }
        if let id = activeJournalID {
            if let item = services.pendingWrites.item(id) { return await sendJournalItem(item, receiptFirst: true) }
            // Another window may have completed this operation. A missing local
            // item never authorizes a new write from the same draft.
            submission = .submitting
            do {
                let transaction: V15Transaction
                if activeJournalKind == .repayment { transaction = try decodeTransaction(from: await services.actions.receipt(idempotencyKey: id)) }
                else { transaction = try await services.ledger.receipt(idempotencyKey: id) }
                return try finish(transaction, id: id)
            } catch {
                submission = .failed((error as? V15Failure) ?? .init(kind: .responseUnknown, message: "原请求结果尚未确认，请稍后恢复。"))
                return nil
            }
        }
        switch submission { case .queued, .success, .conflict: return nil; default: break }
        validate(); guard localIssues.isEmpty, let request = request(), let identity = payloadIdentity(for: request) else { return nil }
        do {
            try services.pendingWrites.ensureStorage()
            if isOffline {
                guard kind != .repayment else { throw V15Failure(kind: .offlineReadOnly, code: "preview_requires_network", message: "还款需要联网预览。") }
                let id = services.pendingWrites.enqueueCreate(request)
                try services.pendingWrites.ensureStorage()
                submission = .queued(id); resetDraftForNextEntry(); return .queued(id)
            }
            let key = UUID()
            let id: UUID
            if kind == .repayment {
                guard case .ready(let preview) = repaymentPreviewPhase, previewPayloadIdentity == identity else {
                    repaymentPreviewPhase = .failed(.init(kind: .conflict, code: "repayment_preview_required", message: "输入已变化，请重新查看还款影响。")); return nil
                }
                id = try services.pendingWrites.prepare(kind: .repayment, title: request.title, request: V15JournalRepayment(previewToken: preview.meta.previewToken), idempotencyKey: key)
            } else { id = try services.pendingWrites.prepare(kind: .transactionCreate, title: request.title, request: request, idempotencyKey: key) }
            activeJournalID = id
            activeJournalKind = kind == .repayment ? .repayment : .transactionCreate
            guard let item = services.pendingWrites.item(id) else { return nil }
            return await sendJournalItem(item, receiptFirst: false)
        } catch {
            submission = .failed((error as? V15Failure) ?? .init(kind: .transport, code: "write_journal_unavailable", message: "无法安全保存请求，本次没有发送。"))
            return nil
        }
    }

    private func sendJournalItem(_ item: V15PendingWriteStore.Item, receiptFirst: Bool) async -> CommitOutcome? {
        guard !isOffline else { submission = .failed(.init(kind: .offlineReadOnly, code: "recovery_requires_network", message: "原请求已保留，请联网后恢复。")); return nil }
        submission = .submitting; fieldIssues = []
        let id = item.id
        if receiptFirst {
            do {
                let transaction: V15Transaction
                if item.kind == .repayment { transaction = try decodeTransaction(from: await services.actions.receipt(idempotencyKey: id)) }
                else { transaction = try await services.ledger.receipt(idempotencyKey: id) }
                return try finish(transaction, id: id)
            } catch {
                // A lookup failure is not proof of non-execution. This explicit
                // retry may replay only the exact original payload and key.
            }
        }
        do {
            try services.pendingWrites.markInFlight(id)
            guard let payload = item.payload else { throw V15Failure(kind: .decoding, code: "pending_write_invalid", message: "原请求无法读取。") }
            let transaction: V15Transaction
            if item.kind == .repayment {
                let original = try V15BodyEncoder.decode(V15JournalRepayment.self, from: payload)
                transaction = try decodeTransaction(from: await services.actions.commitRepayment(previewToken: original.previewToken, idempotencyKey: id))
            } else {
                let original = try V15BodyEncoder.decode(V15TransactionCreateRequest.self, from: payload)
                transaction = try await services.ledger.create(original, idempotencyKey: id)
            }
            return try finish(transaction, id: id)
        } catch {
            let failure = (error as? V15Failure) ?? .init(kind: .responseUnknown, code: "response_unknown", message: "连接中断，原请求已保留，可安全恢复。")
            let unknown = receiptFirst || !(error is V15Failure) || V15LedgerCreateService.outcomeMayBeUnknown(failure)
            if unknown { services.pendingWrites.markUnknown(id) }
            else {
                do { try services.pendingWrites.complete(id) } catch { services.pendingWrites.markUnknown(id) }
            }
            guard activeJournalID == id else { return nil }
            if !unknown && services.pendingWrites.item(id) == nil { activeJournalID = nil }
            fieldIssues = failure.fieldIssues
            if failure.kind == .conflict, let conflict = failure.conflict { submission = .conflict(conflict) }
            else { submission = .failed(failure) }
            return nil
        }
    }

    private func finish(_ transaction: V15Transaction, id: UUID) throws -> CommitOutcome? {
        try services.pendingWrites.complete(id)
        services.notifyConfirmedWrite()
        let ownsDraft = activeJournalID == id
        if ownsDraft {
            activeJournalID = nil; submission = .success(transaction); resetDraftForNextEntry()
        }
        return ownsDraft && isPresented ? .confirmed(transaction) : nil
    }

    private func decodeTransaction(from receipt: V15ActionCommitReceipt) throws -> V15Transaction {
        guard receipt.action == .repayment else { throw V15Failure(kind: .decoding, code: "invalid_action_receipt", message: "还款结果无法识别。") }
        return try V15BodyEncoder.decode(V15Transaction.self, from: receipt.result.values)
    }

    /// A 409 never replays blindly. Reload the authoritative references, then
    /// puts the user back in the decision state with the same visible inputs.
    public func reloadAfterConflict() async { submission = .idle; await loadReferences(); if kind == .repayment { await loadCreditCycles() } }
    public func dismiss() { isPresented = false; previewGeneration &+= 1; repaymentPreviewPhase = .idle; previewPayloadIdentity = nil; fieldIssues = [] }

    public func newEntry() {
        dismiss()
        activeJournalID = nil
        isPresented = true
        submission = .idle
        resetDraftForNextEntry()
    }

    private var categoryDirection: V15CategoryDirection? {
        switch kind { case .income: .income; case .expense, .creditPurchase: .expense; case .transfer, .repayment, .borrowing: nil }
    }

    private func inputChanged() {
        guard !isResettingDraft else { return }
        // Programmatic edits cannot release a submitted request or its lock.
        guard activeJournalID == nil else { validate(); return }
        draftRevision &+= 1; fieldIssues = []
        previewGeneration &+= 1; repaymentPreviewPhase = .idle; previewPayloadIdentity = nil
        if case .idle = submission {} else { submission = .idle }
        validate()
    }

    private func resetDraftForNextEntry() {
        isResettingDraft = true
        kind = .expense
        amountText = ""
        title = ""
        note = ""
        accountID = nil
        destinationAccountID = nil
        categoryID = nil
        creditCycleID = nil
        isResettingDraft = false
        creditCyclesGeneration &+= 1
        creditCycles = []
        creditCyclePhase = .idle
        draftRevision &+= 1
        fieldIssues = []
        previewGeneration &+= 1
        repaymentPreviewPhase = .idle
        previewPayloadIdentity = nil
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
        V15TransactionReferenceRules.allowsSource(id, kind: kind, accounts: accounts)
    }

    private func isAllowedDestination(_ id: UUID?, for kind: V15ManualTransactionKind, sourceID: UUID?) -> Bool {
        V15TransactionReferenceRules.allowsDestination(id, kind: kind, sourceID: sourceID, accounts: accounts)
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
        switch kind { case .income: .income; case .expense, .creditPurchase: .expense; case .transfer, .repayment, .borrowing: nil }
    }

    private func flatten(_ source: [V15CategoryResponse]) -> [V15CategoryResponse] { source + source.flatMap { flatten($0.children) } }

    private func request() -> V15TransactionCreateRequest? {
        let draft = sharedDraftValidation()
        guard draft.issues.isEmpty, let amount = draft.amountMinor else { return nil }
        return .init(kind: kind, amountMinor: amount, occurredAt: shanghaiInstant(occurredOn), title: draft.title, note: draft.note, accountID: accountID, categoryID: categoryID, destinationAccountID: destinationAccountID, creditCycleID: creditCycleID)
    }

    private func payloadIdentity(for request: V15TransactionCreateRequest) -> String? {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(request) else { return nil }
        // Revision preserves the invariant that editing then restoring text is
        // still a new user decision and must receive a fresh create key.
        return "\(draftRevision):\(data.base64EncodedString())"
    }

    private func validate() {
        var issues = sharedDraftValidation().issues
        if isOffline && kind == .repayment {
            issues.append(.init(code: "preview_requires_network", message: "需要联网：还款前必须先读取最新账期。", fieldPath: nil))
        }
        localIssues = issues
    }

    private func sharedDraftValidation() -> V15TransactionDraftRules.Result {
        V15TransactionDraftRules.validate(
            kind: kind, amountText: amountText, title: title, note: note,
            accountID: accountID, categoryID: categoryID, destinationAccountID: destinationAccountID, creditCycleID: creditCycleID,
            accounts: accounts, categories: categories, creditCycles: creditCycles,
            creditCyclesLoading: creditCyclePhase == .loading)
    }

    private func shanghaiInstant(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.locale = Locale(identifier: "zh_CN"); calendar.timeZone = ShanghaiBusinessDate.timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return calendar.date(from: DateComponents(timeZone: ShanghaiBusinessDate.timeZone, year: parts.year, month: parts.month, day: parts.day, hour: 12)) ?? date
    }

    private func message(for error: Error) -> String { (error as? V15Failure)?.message ?? "暂时无法取得数据。" }
}
