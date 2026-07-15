import Foundation
import Observation

@MainActor
@Observable
public final class InstallmentModel {
    public private(set) var plans: [InstallmentPlanDTO] = []
    public private(set) var selectedPlan: InstallmentPlanDTO?
    public private(set) var selectedPurchase: TransactionDTO?
    public private(set) var liabilities: InstallmentLiabilities?
    public private(set) var eligibility: InstallmentEligibility?
    public private(set) var cycleOptions: [InstallmentCycleOption] = []
    public private(set) var changePreview: InstallmentPlanChangePreview?
    public private(set) var settlementPreview: InstallmentSettlementPreview?
    public private(set) var cancellationPreview: InstallmentCancellationPreview?
    public private(set) var reversePreview: InstallmentReversePreview?
    public private(set) var phase: MasterDataPhase = .idle
    public private(set) var message: String?
    public private(set) var refreshMessage: String?
    public private(set) var nextCursor: String?
    public private(set) var loadingMore = false
    public private(set) var isMutating = false
    public private(set) var conflictDetected = false
    public private(set) var loadedAccountID: UUID?

    private let repository: any InstallmentRepository
    private let transactions: any TransactionRepository
    private let credit: CreditModel?
    private let transactionList: TransactionsModel?
    private var generation = 0
    private var previewedChangeRequest: InstallmentReplacementRequest?
    private var previewedSettlementRequest: InstallmentSettlementRequest?
    private var previewedCancellationRequest: InstallmentOperationRequest?
    private var previewedReverseRequest: InstallmentOperationRequest?

    public init(repository: any InstallmentRepository, transactions: any TransactionRepository, credit: CreditModel? = nil, transactionList: TransactionsModel? = nil) {
        self.repository = repository; self.transactions = transactions; self.credit = credit; self.transactionList = transactionList
    }

    public func loadAccount(_ accountID: UUID) async {
        generation += 1; let current = generation
        loadedAccountID = accountID; plans = []; liabilities = nil; nextCursor = nil
        phase = .loading; message = nil; refreshMessage = nil; conflictDetected = false
        do {
            async let page = repository.list(accountID: accountID, status: nil, cursor: nil, limit: 20)
            async let projection = repository.liabilities(accountID: accountID)
            let (loadedPage, loadedProjection) = try await (page, projection)
            guard current == generation else { return }
            plans = loadedPage.items; nextCursor = loadedPage.nextCursor; liabilities = loadedProjection
            phase = plans.isEmpty ? .empty : .loaded
        } catch is CancellationError { if current == generation { phase = .idle } }
        catch { guard current == generation else { return }; apply(error, preserving: false) }
    }

    public func loadPlan(_ id: UUID) async {
        generation += 1; let current = generation; phase = .loading; message = nil; refreshMessage = nil; conflictDetected = false
        do {
            let plan = try await repository.get(id: id)
            async let purchase = transactions.get(id: plan.purchaseTransactionID)
            let loadedPurchase = try await purchase
            guard current == generation else { return }
            selectedPlan = plan; selectedPurchase = loadedPurchase; phase = .loaded
        } catch is CancellationError { phase = .idle }
        catch { guard current == generation else { return }; apply(error, preserving: false) }
    }

    public func loadMore(accountID: UUID) async {
        guard loadedAccountID == accountID, let cursor = nextCursor, !loadingMore else { return }
        let current = generation; loadingMore = true; defer { loadingMore = false }
        do {
            let page = try await repository.list(accountID: accountID, status: nil, cursor: cursor, limit: 20)
            guard current == generation else { return }
            let known = Set(plans.map(\.id)); plans += page.items.filter { !known.contains($0.id) }; nextCursor = page.nextCursor
        } catch is CancellationError {} catch { if current == generation { refreshMessage = display(error) } }
    }

    public func checkEligibility(transactionID: UUID) async {
        generation += 1; let current = generation; phase = .loading; message = nil
        do { let value = try await repository.eligibility(transactionID: transactionID); guard current == generation else { return }; eligibility = value; phase = .loaded }
        catch is CancellationError { phase = .idle } catch { guard current == generation else { return }; apply(error, preserving: false) }
    }

    @discardableResult public func loadCycleOptions(transactionID: UUID) async -> Bool {
        message = nil
        do { cycleOptions = try await repository.cycleOptions(transactionID: transactionID, months: 60); return true }
        catch is CancellationError { return false } catch { apply(error, preserving: true); return false }
    }

    public func create(_ request: InstallmentCreateRequest, idempotencyKey: UUID) async -> InstallmentPlanDTO? {
        guard let plan: InstallmentPlanDTO = await mutate({ try await repository.create(request, idempotencyKey: idempotencyKey) }) else { return nil }
        store(plan); await refreshAfterMutation(accountID: plan.creditAccountID); return plan
    }

    public func preview(_ request: InstallmentReplacementRequest) async -> Bool {
        guard let id = selectedPlan?.id else { return false }
        message = nil; changePreview = nil
        do { changePreview = try await repository.preview(id: id, request: request); previewedChangeRequest = request; return true }
        catch is CancellationError { return false } catch { apply(error, preserving: true); return false }
    }

    public func update(_ request: InstallmentReplacementRequest) async -> InstallmentPlanDTO? {
        guard let id = selectedPlan?.id else { return nil }
        guard previewedChangeRequest == request, changePreview != nil else { invalidateChangePreview(message: "输入已变化，请重新预览。"); return nil }
        guard let plan: InstallmentPlanDTO = await mutate({ try await repository.update(id: id, request: request) }) else { return nil }
        store(plan); clearPreviews(); await refreshAfterMutation(accountID: plan.creditAccountID); return plan
    }

    public func previewSettlement(_ request: InstallmentSettlementRequest) async -> Bool {
        guard let plan = selectedPlan, plan.futureCount > 0 else { message = "没有可提前结清的未来期次。"; return false }
        let id = plan.id; message = nil; settlementPreview = nil
        do { settlementPreview = try await repository.settlementPreview(id: id, request: request); previewedSettlementRequest = request; return true }
        catch is CancellationError { return false } catch { apply(error, preserving: true); return false }
    }

    public func settle(_ request: InstallmentSettlementRequest, idempotencyKey: UUID) async -> Bool {
        guard let plan = selectedPlan, plan.futureCount > 0 else { message = "没有可提前结清的未来期次。"; return false }
        let id = plan.id
        guard previewedSettlementRequest == request, settlementPreview != nil else { invalidateSettlementPreview(message: "输入已变化，请重新预览。"); return false }
        guard let result: InstallmentSettlementResult = await mutate({ try await repository.settleEarly(id: id, request: request, idempotencyKey: idempotencyKey) }) else { return false }
        store(result.plan); clearPreviews(); await refreshAfterMutation(accountID: result.plan.creditAccountID); return true
    }

    public func previewCancellation(_ request: InstallmentOperationRequest) async -> Bool {
        guard let plan = selectedPlan, plan.futureCount > 0 else { message = "没有可取消的未来期次。"; return false }
        let id = plan.id; message = nil; cancellationPreview = nil
        do { cancellationPreview = try await repository.cancellationPreview(id: id, request: request); previewedCancellationRequest = request; return true }
        catch is CancellationError { return false } catch { apply(error, preserving: true); return false }
    }

    public func cancelFuture(_ request: InstallmentOperationRequest, idempotencyKey: UUID) async -> Bool {
        guard let plan = selectedPlan, plan.futureCount > 0 else { message = "没有可取消的未来期次。"; return false }
        let id = plan.id
        guard previewedCancellationRequest == request, cancellationPreview != nil else { invalidateCancellationPreview(message: "输入已变化，请重新预览。"); return false }
        guard let result: InstallmentCancellationResult = await mutate({ try await repository.cancelFuture(id: id, request: request, idempotencyKey: idempotencyKey) }) else { return false }
        store(result.plan); clearPreviews(); await refreshAfterMutation(accountID: result.plan.creditAccountID); return true
    }

    public func previewReverse(_ request: InstallmentOperationRequest) async -> Bool {
        guard let id = selectedPlan?.id else { return false }; message = nil; reversePreview = nil
        do { reversePreview = try await repository.reversePreview(id: id, request: request); previewedReverseRequest = request; return true }
        catch is CancellationError { return false } catch { apply(error, preserving: true); return false }
    }

    public func reverseSettlement(_ request: InstallmentOperationRequest, idempotencyKey: UUID) async -> Bool {
        guard let id = selectedPlan?.id else { return false }
        guard previewedReverseRequest == request, reversePreview != nil else { invalidateReversePreview(message: "输入已变化，请重新预览。"); return false }
        guard let result: InstallmentReverseResult = await mutate({ try await repository.reverseSettlement(id: id, request: request, idempotencyKey: idempotencyKey) }) else { return false }
        store(result.plan); clearPreviews(); await refreshAfterMutation(accountID: result.plan.creditAccountID); return true
    }

    public func clearPreviews() {
        changePreview = nil; settlementPreview = nil; cancellationPreview = nil; reversePreview = nil
        previewedChangeRequest = nil; previewedSettlementRequest = nil; previewedCancellationRequest = nil; previewedReverseRequest = nil
    }
    public func invalidateChangePreview(message: String? = nil) { changePreview = nil; previewedChangeRequest = nil; if let message { self.message = message } }
    public func invalidateSettlementPreview(message: String? = nil) { settlementPreview = nil; previewedSettlementRequest = nil; if let message { self.message = message } }
    public func invalidateCancellationPreview(message: String? = nil) { cancellationPreview = nil; previewedCancellationRequest = nil; if let message { self.message = message } }
    public func invalidateReversePreview(message: String? = nil) { reversePreview = nil; previewedReverseRequest = nil; if let message { self.message = message } }
    public func clearConflict() { conflictDetected = false }

    private func mutate<T: Sendable>(_ operation: () async throws -> T) async -> T? {
        guard !isMutating else { return nil }; isMutating = true; message = nil; conflictDetected = false; defer { isMutating = false }
        do { return try await operation() }
        catch is CancellationError { return nil } catch { apply(error, preserving: true); return nil }
    }

    private func store(_ plan: InstallmentPlanDTO) {
        selectedPlan = plan
        guard loadedAccountID == nil || loadedAccountID == plan.creditAccountID else { return }
        if let index = plans.firstIndex(where: { $0.id == plan.id }) { plans[index] = plan }
        else { plans.insert(plan, at: 0) }
    }

    private func refreshAfterMutation(accountID: UUID) async {
        async let page = repository.list(accountID: accountID, status: nil, cursor: nil, limit: 20)
        async let projection = repository.liabilities(accountID: accountID)
        async let creditRefresh: Void = refreshCredit(accountID: accountID)
        async let transactionRefresh: Void = transactionList?.load() ?? ()
        do {
            let (loadedPage, loadedProjection) = try await (page, projection)
            if loadedAccountID == nil || loadedAccountID == accountID {
                loadedAccountID = accountID; plans = loadedPage.items; nextCursor = loadedPage.nextCursor; liabilities = loadedProjection
                if let selectedPlan, let refreshed = plans.first(where: { $0.id == selectedPlan.id }) { self.selectedPlan = refreshed }
                phase = plans.isEmpty ? .empty : .loaded
            }
        } catch { refreshMessage = display(error) }
        _ = await (creditRefresh, transactionRefresh)
    }

    private func refreshCredit(accountID: UUID) async {
        await credit?.loadAccounts(); await credit?.loadAccount(accountID)
    }

    private func apply(_ error: Error, preserving: Bool) {
        let text = display(error); message = text
        if let api = error as? FiscalAPIError, case .domain(_, let detail) = api, Self.isConflictCode(detail.code) {
            conflictDetected = true
        }
        if preserving { refreshMessage = text; phase = plans.isEmpty && selectedPlan == nil ? .failed : .loaded; return }
        guard let api = error as? FiscalAPIError else { phase = .failed; return }
        switch api { case .unauthorized: phase = .unauthorized; case .transport: phase = .offline; default: phase = .failed }
    }
    private func display(_ error: Error) -> String { (error as? FiscalAPIError)?.displayMessage ?? error.localizedDescription }
    public nonisolated static func isConflictCode(_ code: String) -> Bool { code == "version_conflict" || code == "resource_version_conflict" || code == "installment_operation_conflict" }
}
