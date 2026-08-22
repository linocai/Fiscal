import Foundation
import Observation

@MainActor @Observable
public final class V15InstallmentModel {
    public enum Phase: Equatable { case idle, loading, loaded, empty, failed(V15Failure) }
    public enum PagePhase: Equatable { case idle, loading, failed(V15Failure) }
    public enum DetailPhase: Equatable { case idle, loading, loaded, failed(V15Failure) }
    public enum PreviewPhase: Equatable { case idle, previewing, previewed, committing, succeeded, unknown, conflict(V15Conflict), failed(V15Failure) }
    public enum ReadbackPhase: Equatable { case idle, loading, confirmed, notConfirmed, failed(V15Failure) }
    public enum CommandKind: String, Sendable, CaseIterable, Identifiable {
        case settleEarly = "settle_early", reverseSettlement = "reverse_settlement", cancelFuture = "cancel_future"
        public var id: String { rawValue }
        public var title: String { switch self { case .settleEarly: "提前结清"; case .reverseSettlement: "撤销结清"; case .cancelFuture: "取消未来期次" } }
    }
    public enum CommandPreview: Equatable {
        case settlement(V15InstallmentSettlementPreview)
        case reverse(V15InstallmentReverseSettlementPreview)
        case cancellation(V15InstallmentCancellationPreview)
    }
    public enum CommandReceipt: Equatable {
        case settlement(V15InstallmentSettlementResult)
        case reverse(V15InstallmentReverseSettlementResult)
        case cancellation(V15InstallmentCancellationResult)
        public var operationID: UUID { switch self { case .settlement(let value): value.operationID; case .reverse(let value): value.operationID; case .cancellation(let value): value.operationID } }
        public var replayed: Bool { switch self { case .settlement(let value): value.replayed; case .reverse(let value): value.replayed; case .cancellation(let value): value.replayed } }
        public var plan: V15InstallmentPlan { switch self { case .settlement(let value): value.plan; case .reverse(let value): value.plan; case .cancellation(let value): value.plan } }
        public var systemTransactions: [V15Transaction] { switch self { case .settlement(let value): [value.repaymentTransaction]; case .reverse(let value): [value.voidedRepaymentTransaction]; case .cancellation(let value): value.refundTransactions } }
        public var systemTransactionCount: Int { systemTransactions.count }
    }

    public private(set) var plans: [V15InstallmentPlan] = []
    public private(set) var selectedPlan: V15InstallmentPlan?
    public private(set) var selectedPurchase: V15Transaction?
    public private(set) var accounts: [V15AccountResponse] = []
    public private(set) var categories: [V15CategoryResponse] = []
    public private(set) var feeCategoryPhase: Phase = .idle
    public private(set) var liabilities: V15InstallmentLiabilities?
    public private(set) var nextCursor: String?
    public private(set) var phase: Phase = .idle
    public private(set) var pagePhase: PagePhase = .idle
    public private(set) var detailPhase: DetailPhase = .idle
    public private(set) var filterStatus: String?
    public private(set) var filterAccountID: UUID?
    public private(set) var fieldIssues: [V15FieldIssue] = []
    public private(set) var serverFailure: V15Failure?
    public private(set) var reloadRequired = false

    // Create-from-existing-purchase workflow.
    public var purchaseTransactionIDText = "" {
        didSet {
            // SwiftUI can write the current TextField value again while focus moves to a
            // conditionally inserted fee control. A semantic no-op must not discard the
            // server-owned eligibility and cycle options the user just loaded.
            let oldID = UUID(uuidString: oldValue.trimmingCharacters(in: .whitespacesAndNewlines))
            let newID = UUID(uuidString: purchaseTransactionIDText.trimmingCharacters(in: .whitespacesAndNewlines))
            if oldID != newID || (oldID == nil && oldValue != purchaseTransactionIDText) { eligibilityInputChanged() }
        }
    }
    public var createInstallmentCountText = "3" { didSet { createInputChanged() } }
    public var createFeeText = "0.00" { didSet { createFeeInputChanged() } }
    public var createFeeCategoryID: UUID? { didSet { createInputChanged() } }
    public var createFeeOccurredDateText = "" { didSet { createInputChanged() } }
    public var createStartStatementDate = "" { didSet { createInputChanged() } }
    public private(set) var eligibility: V15InstallmentEligibility?
    public private(set) var eligibilityPurchase: V15Transaction?
    public private(set) var cycleOptions: [V15InstallmentCycleOption] = []
    public private(set) var eligibilityPhase: Phase = .idle
    public private(set) var eligibilityPurchasePhase: Phase = .idle
    public var createPlanPhase: PreviewPhase {
        guard let ownerID = currentCreateOwnerID else { return createDraftPhase }
        return createOwnerStates[ownerID]?.phase ?? createDraftPhase
    }

    // Atomic new credit-purchase workflow.
    public var newPurchaseTitle = "" { didSet { purchaseInputChanged() } }
    public var newPurchaseAmountText = "" { didSet { purchaseInputChanged() } }
    public var newPurchaseAccountID: UUID? { didSet { purchaseInputChanged() } }
    public var newPurchaseCategoryID: UUID? { didSet { purchaseInputChanged() } }
    public var newPurchaseCountText = "3" { didSet { purchaseInputChanged() } }
    public var newPurchaseFeeText = "0.00" { didSet { purchaseFeeInputChanged() } }
    public var newPurchaseFeeCategoryID: UUID? { didSet { purchaseInputChanged() } }
    public var newPurchaseFeeOccurredDateText = "" { didSet { purchaseInputChanged() } }
    public var newPurchaseStartStatementDate = "" { didSet { purchaseInputChanged() } }
    public private(set) var purchasePreview: V15InstallmentPurchasePreview?
    public var purchasePhase: PreviewPhase {
        guard let ownerID = newPurchaseAccountID else { return purchaseDraftPhase }
        return purchaseOwnerStates[ownerID]?.phase ?? purchaseDraftPhase
    }
    public var purchaseReceipt: V15InstallmentPurchaseCreateResponse? {
        guard let ownerID = newPurchaseAccountID else { return nil }
        return purchaseOwnerStates[ownerID]?.receipt
    }

    // Existing plan replacement workflow.
    public var editTitle = "" { didSet { planInputChanged() } }
    public var editAmountText = "" { didSet { planInputChanged() } }
    public var editNote = "" { didSet { planInputChanged() } }
    public var editAccountID: UUID? { didSet { planInputChanged() } }
    public var editCategoryID: UUID? { didSet { planInputChanged() } }
    public var editCountText = "" { didSet { planInputChanged() } }
    public var editFeeText = "" { didSet { editFeeInputChanged() } }
    public var editFeeCategoryID: UUID? { didSet { planInputChanged() } }
    public var editFeeOccurredDateText = "" { didSet { planInputChanged() } }
    public var editStartStatementDate = "" { didSet { planInputChanged() } }

    // Settlement/reverse/cancel workflow.
    public var commandKind: CommandKind = .settleEarly { didSet { commandInputChanged() } }
    public var paymentAccountID: UUID? { didSet { commandInputChanged() } }
    public var targetStatementDate = "" { didSet { commandInputChanged() } }

    private let services: V15Services
    private let now: () -> Date
    private let offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)?
    private let idempotency = V15IdempotencyOwner()
    private var listGeneration: UInt64 = 0
    private var pageGeneration: UInt64 = 0
    private var detailGeneration: UInt64 = 0
    private var feeCategoryGeneration: UInt64 = 0
    private var eligibilityGeneration: UInt64 = 0
    private var eligibilityPurchaseGeneration: UInt64 = 0
    private var purchaseGeneration: UInt64 = 0
    private var createGeneration: UInt64 = 0
    private var planGeneration: [UUID: UInt64] = [:]
    private var commandGeneration: [UUID: UInt64] = [:]
    private var readbackGeneration: [UUID: UInt64] = [:]
    private var isApplyingDraft = false
    private var editOriginalFeeOccurredAt: Date?

    private struct UnknownCommandAttempt: Sendable, Equatable {
        enum Request: Sendable, Equatable { case settlement(V15InstallmentSettlementRequest), action(V15InstallmentActionRequest) }
        let operationID: UUID; let planID: UUID; let ownerAccountID: UUID; let kind: CommandKind; let request: Request; let identity: String; let key: UUID
    }
    private struct UnknownPurchaseAttempt: Sendable, Equatable { let operationID: UUID; let ownerAccountID: UUID; let request: V15InstallmentPurchaseCreateRequest; let identity: String; let key: UUID }
    private struct UnknownCreateAttempt: Sendable, Equatable { let operationID: UUID; let ownerPurchaseTransactionID: UUID; let request: V15InstallmentCreateRequest; let identity: String; let key: UUID }
    private struct UnknownUpdateAttempt: Sendable, Equatable { let operationID: UUID; let planID: UUID; let ownerAccountID: UUID; let purchaseTransactionID: UUID; let request: V15InstallmentReplacementRequest }
    private struct PurchaseOwnerState {
        var attempt: UnknownPurchaseAttempt?
        var phase: PreviewPhase = .idle
        var receipt: V15InstallmentPurchaseCreateResponse?
    }
    private struct CreateOwnerState {
        var attempt: UnknownCreateAttempt?
        var phase: PreviewPhase = .idle
    }
    private struct PlanState {
        var planPreview: V15InstallmentPlanChangePreview?
        var planPreviewIdentity: String?
        var planPreparedRequest: V15InstallmentReplacementRequest?
        var planPhase: PreviewPhase = .idle
        var updateAttempt: UnknownUpdateAttempt?
        var updateReadback: ReadbackPhase = .idle
        var commandPreview: CommandPreview?
        var commandPreviewIdentity: String?
        var commandPreparedRequest: UnknownCommandAttempt.Request?
        var commandPhase: PreviewPhase = .idle
        var commandReceipt: CommandReceipt?
        var unknownCommand: UnknownCommandAttempt?
        var commandReadback: ReadbackPhase = .idle
    }
    private var planStates: [UUID: PlanState] = [:]
    private var purchasePreparedRequest: V15InstallmentPurchaseCreateRequest?
    private var purchaseDraftPhase: PreviewPhase = .idle
    private var createDraftPhase: PreviewPhase = .idle
    private var purchaseOwnerStates: [UUID: PurchaseOwnerState] = [:]
    private var createOwnerStates: [UUID: CreateOwnerState] = [:]
    private var currentState: PlanState { selectedPlan.map { planStates[$0.id] ?? .init() } ?? .init() }
    private var currentCreateOwnerID: UUID? { UUID(uuidString: purchaseTransactionIDText.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var currentPurchaseOwnerState: PurchaseOwnerState? { newPurchaseAccountID.flatMap { purchaseOwnerStates[$0] } }
    private var currentCreateOwnerState: CreateOwnerState? { currentCreateOwnerID.flatMap { createOwnerStates[$0] } }

    public init(services: V15Services, offlineSnapshotAt: Date? = nil, offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)? = nil, now: @escaping () -> Date = { .now }) {
        self.services = services
        self.offlineSnapshotProvider = offlineSnapshotProvider ?? { offlineSnapshotAt ?? services.offlineSnapshotAt }
        self.now = now
    }

    public var offlineSnapshotAt: Date? { offlineSnapshotProvider?() }
    public var isOffline: Bool { offlineSnapshotAt != nil }
    public var planPreview: V15InstallmentPlanChangePreview? { currentState.planPreview }
    public var planPhase: PreviewPhase { currentState.planPhase }
    public var updateReadbackPhase: ReadbackPhase { currentState.updateReadback }
    public var commandPreview: CommandPreview? { currentState.commandPreview }
    public var commandPhase: PreviewPhase { currentState.commandPhase }
    public var commandReceipt: CommandReceipt? { currentState.commandReceipt }
    public var commandReadbackPhase: ReadbackPhase { currentState.commandReadback }
    public var hasUnknownCommand: Bool { currentState.unknownCommand != nil && currentState.commandPhase == .unknown }
    public var hasUnknownPlanUpdate: Bool { currentState.updateAttempt != nil && currentState.planPhase == .unknown }
    public var hasUnknownPurchase: Bool { currentPurchaseOwnerState?.attempt != nil && currentPurchaseOwnerState?.phase == .unknown }
    public var hasUnknownCreatePlan: Bool { currentCreateOwnerState?.attempt != nil && currentCreateOwnerState?.phase == .unknown }

    public var activeAccounts: [V15AccountResponse] { accounts.filter { $0.archivedAt == nil } }
    public var paymentAccounts: [V15AccountResponse] { activeAccounts.filter { $0.kind == .cash || $0.kind == .debit } }
    public var creditAccounts: [V15AccountResponse] { activeAccounts.filter { $0.kind == .credit } }
    public var expenseCategories: [V15CategoryResponse] { flattenedCategories(categories).filter { $0.archivedAt == nil && $0.direction == "expense" } }
    public var expenseCategoryLoadingReason: V15DisabledReason? {
        switch feeCategoryPhase {
        case .loaded: return expenseCategories.isEmpty ? reason("expense_categories_empty", "暂无支出分类，请先创建分类。") : nil
        case .loading: return reason("fee_categories_loading", "正在读取服务端支出分类，请稍候。")
        case .empty: return reason("expense_categories_empty", "暂无支出分类，请先创建分类。")
        case .failed: return reason("expense_categories_failed", "支出分类读取失败，请重试。")
        case .idle: return reason("expense_categories_required", "请先读取支出分类。")
        }
    }
    public var feeCategoryLoadingReason: V15DisabledReason? { expenseCategoryLoadingReason }

    public var planMutationDisabledReason: V15DisabledReason? {
        if isOffline { return reason("offline_read_only", "离线快照仅可查看，无法修改分期。") }
        guard let plan = selectedPlan else { return reason("plan_required", "请先选择一项分期计划。") }
        if plan.isDisplayOnly { return reason("unknown_plan_status", "服务端返回了当前版本不认识的状态；本计划仅可查看。") }
        if currentState.unknownCommand != nil { return currentState.commandPhase == .committing ? reason("command_in_flight", "操作请求已经发出，结果将按原计划保存；可切换计划，回到本计划查看结果。") : reason("unknown_command_pending", "上一笔操作结果未知；只有完全相同 body 与 key 的重放回执可以确认。fresh GET 仅刷新计划事实。") }
        if currentState.updateAttempt != nil { return currentState.planPhase == .committing ? reason("update_in_flight", "计划修改请求已经发出，结果将按原计划保存；可切换计划，回到本计划查看结果。") : reason("unknown_update_pending", "计划修改结果未知；该 PUT 不可重发，请先刷新核对。") }
        return nil
    }
    public var purchasePreviewDisabledReason: V15DisabledReason? {
        if isOffline { return reason("offline_read_only", "离线快照仅可查看，无法创建分期消费。") }
        if currentPurchaseOwnerState?.attempt != nil { return purchasePhase == .committing ? reason("purchase_in_flight", "创建请求已经发出；结果只保存到原信用账户，可切换账户并在返回后查看。") : reason("unknown_purchase_pending", "此信用账户上一笔创建结果未知，请使用同一请求凭证重试。") }
        if let value = expenseCategoryLoadingReason { return value }
        if let value = feeBoundaryDisabledReason(totalFeeText: newPurchaseFeeText, occurredDateText: newPurchaseFeeOccurredDateText, purchaseOccurredAt: now(), preserving: nil) { return value }
        var issues: [V15FieldIssue] = []
        guard purchaseRequest(recordIssues: false, issuesSink: { issues = $0 }) == nil else { return nil }
        return issues.first.map(disabledReason(for:)) ?? reason("purchase_fields_invalid", "请补齐有效金额、标题、信用账户、消费分类、期数、账单日期；正手续费还须选择手续费支出分类和发生日期。")
    }
    public var purchaseCommitDisabledReason: V15DisabledReason? {
        if isOffline { return reason("offline_read_only", "离线快照仅可查看，无法创建分期消费。") }
        if currentPurchaseOwnerState?.attempt != nil { return reason("purchase_in_flight", "创建请求已经发出，请返回原账户查看结果。") }
        if let value = purchasePreviewDisabledReason { return value }
        guard purchasePreview != nil, let request = purchasePreparedRequest else { return reason("preview_required", "请先预览服务端拆分结果。") }
        guard purchasePhase == .previewed else { return reason("preview_not_current", "预览不再有效，请重新预览。") }
        if let issue = wireFeeBoundaryIssue(totalFeeMinor: request.totalFeeMinor, feeOccurredAt: request.feeOccurredAt, purchaseOccurredAt: request.purchase.occurredAt) { return .init(code: issue.code, message: issue.message, fieldPath: issue.fieldPath) }
        return nil
    }
    public var createPlanDisabledReason: V15DisabledReason? {
        if isOffline { return reason("offline_read_only", "离线快照仅可查看，无法创建分期计划。") }
        if currentCreateOwnerState?.attempt != nil { return createPlanPhase == .committing ? reason("create_in_flight", "创建请求已经发出；结果只保存到原消费账目，可切换消费并在返回后查看。") : reason("unknown_create_pending", "此消费账目上一笔创建结果未知，请使用同一请求凭证重试。") }
        guard eligibility?.eligible == true else { return reason(eligibility?.reasonCode ?? "eligibility_required", eligibility == nil ? "请先检查消费是否可分期。" : "服务端判定该消费当前不可分期。") }
        switch eligibilityPurchasePhase {
        case .loading: return reason("purchase_detail_loading", "正在读取权威消费发生时间，请稍候。")
        case .failed: return reason("purchase_detail_failed", "消费详情读取失败，请重试分期资格检查。")
        case .empty: return reason("purchase_detail_empty", "服务端未返回消费详情，请重试。")
        case .idle: return reason("purchase_detail_required", "请先读取权威消费详情。")
        case .loaded: break
        }
        guard let requestedID = parsedPurchaseTransactionID(), eligibilityPurchase?.id == requestedID, eligibilityPurchase?.kind == "credit_purchase" else { return reason("purchase_detail_mismatch", "消费详情与当前账目不匹配，请重新检查。") }
        if let value = feeBoundaryDisabledReason(totalFeeText: createFeeText, occurredDateText: createFeeOccurredDateText, purchaseOccurredAt: eligibilityPurchase?.occurredAt, preserving: nil) { return value }
        var issues: [V15FieldIssue] = []
        guard createPlanRequest(recordIssues: false, issuesSink: { issues = $0 }) == nil else { return nil }
        return issues.first.map(disabledReason(for:)) ?? reason("create_fields_invalid", "请选择服务端允许的起始账期并填写 2–60 期；正手续费还须选择手续费支出分类和发生日期。")
    }
    public var planPreviewDisabledReason: V15DisabledReason? {
        if let value = planMutationDisabledReason { return value }
        if let value = expenseCategoryLoadingReason { return value }
        if let value = feeBoundaryDisabledReason(totalFeeText: editFeeText, occurredDateText: editFeeOccurredDateText, purchaseOccurredAt: selectedPurchase?.occurredAt, preserving: editOriginalFeeOccurredAt) { return value }
        var issues: [V15FieldIssue] = []
        guard replacementRequest(recordIssues: false, issuesSink: { issues = $0 }) == nil else { return nil }
        return issues.first.map(disabledReason(for:)) ?? reason("plan_fields_invalid", "请补齐计划、消费、期数与账期字段；正手续费还须选择手续费支出分类和发生日期。")
    }
    public var planCommitDisabledReason: V15DisabledReason? {
        if let value = planMutationDisabledReason { return value }
        if let value = planPreviewDisabledReason { return value }
        guard planPreview != nil, let request = currentState.planPreparedRequest, planPhase == .previewed else { return reason("preview_required", "请先预览服务端锁定期、未来期和账期影响。") }
        if let issue = wireFeeBoundaryIssue(totalFeeMinor: request.totalFeeMinor, feeOccurredAt: request.feeOccurredAt, purchaseOccurredAt: request.purchase.occurredAt) { return .init(code: issue.code, message: issue.message, fieldPath: issue.fieldPath) }
        return nil
    }
    public var commandPreviewDisabledReason: V15DisabledReason? {
        if let value = planMutationDisabledReason { return value }
        return commandRequest(recordIssues: false) == nil ? reason("command_fields_invalid", commandKind == .settleEarly ? "请选择付款账户和服务端账单日期。" : "当前操作缺少有效的计划版本。") : nil
    }
    public var commandCommitDisabledReason: V15DisabledReason? {
        if let value = commandPreviewDisabledReason { return value }
        guard commandPreview != nil, currentState.commandPreparedRequest != nil, commandPhase == .previewed else { return reason("preview_required", "请先预览服务端影响后再确认。") }
        return nil
    }

    public func load() async {
        listGeneration &+= 1; let generation = listGeneration
        pageGeneration &+= 1; detailGeneration &+= 1
        phase = .loading; pagePhase = .idle; serverFailure = nil; reloadRequired = false
        do {
            let loadedAccounts = try await services.masterData.accounts(includeArchived: false)
            guard generation == listGeneration else { return }
            accounts = loadedAccounts
            await loadPlans(reset: true, listGeneration: generation)
        } catch let failure as V15Failure {
            guard generation == listGeneration else { return }; phase = failure.kind == .cancelled ? .idle : .failed(failure)
        } catch { guard generation == listGeneration else { return }; phase = .failed(.init(kind: .transport, message: "分期基础资料读取失败。")) }
        await loadFeeCategories()
    }

    /// Fee categories have their own ownership and error surface. A failure
    /// here never turns the installment spine into a fabricated list failure.
    public func loadFeeCategories() async {
        feeCategoryGeneration &+= 1; let generation = feeCategoryGeneration
        feeCategoryPhase = .loading; categories = []
        do {
            let loaded = try await services.masterData.activeCategories(direction: .expense)
            guard generation == feeCategoryGeneration else { return }
            categories = loaded.filter { $0.archivedAt == nil && $0.direction == "expense" }
            feeCategoryPhase = categories.isEmpty ? .empty : .loaded
        } catch let failure as V15Failure {
            guard generation == feeCategoryGeneration else { return }
            feeCategoryPhase = failure.kind == .cancelled ? .idle : .failed(failure)
        } catch {
            guard generation == feeCategoryGeneration else { return }
            feeCategoryPhase = .failed(.init(kind: .transport, message: "支出分类读取失败。"))
        }
    }

    public func setFilters(status: String?, accountID: UUID?) async {
        listGeneration &+= 1; let generation = listGeneration
        pageGeneration &+= 1; detailGeneration &+= 1
        filterStatus = status; filterAccountID = accountID; selectedPlan = nil; selectedPurchase = nil; liabilities = nil; detailPhase = .idle
        await loadPlans(reset: true, listGeneration: generation)
    }

    public func refresh() async {
        listGeneration &+= 1; let generation = listGeneration
        pageGeneration &+= 1; detailGeneration &+= 1
        reloadRequired = false
        await loadPlans(reset: true, listGeneration: generation, readCachePolicy: .reloadIgnoringCache)
    }

    public func loadNextPage() async { await loadPlans(reset: false, listGeneration: listGeneration) }

    private func loadPlans(reset: Bool, listGeneration generation: UInt64, readCachePolicy: V15ReadCachePolicy = .standard) async {
        guard generation == listGeneration else { return }
        guard reset || (nextCursor != nil && pagePhase != .loading) else { return }
        pageGeneration &+= 1; let ownership = pageGeneration
        let cursor = reset ? nil : nextCursor
        if reset { phase = .loading; plans = []; nextCursor = nil; pagePhase = .idle } else { pagePhase = .loading }
        do {
            let page = try await services.installments.list(accountID: filterAccountID, status: filterStatus, cursor: cursor, limit: 20, readCachePolicy: readCachePolicy)
            guard generation == listGeneration, ownership == pageGeneration else { return }
            plans = unique(reset ? page.items : plans + page.items); nextCursor = page.nextCursor; pagePhase = .idle
            guard let first = plans.first else { selectedPlan = nil; phase = .empty; return }
            phase = .loaded
            if reset || selectedPlan == nil || !plans.contains(where: { $0.id == selectedPlan?.id }) { await selectPlan(first, readCachePolicy: readCachePolicy) }
        } catch let failure as V15Failure {
            guard generation == listGeneration, ownership == pageGeneration else { return }
            if reset { phase = failure.kind == .cancelled ? .idle : .failed(failure) } else { pagePhase = failure.kind == .cancelled ? .idle : .failed(failure) }
        } catch {
            guard generation == listGeneration, ownership == pageGeneration else { return }
            let failure = V15Failure(kind: .transport, message: reset ? "分期计划读取失败。" : "下一页读取失败，已保留当前结果。")
            if reset { phase = .failed(failure) } else { pagePhase = .failed(failure) }
        }
    }

    public func selectPlan(_ plan: V15InstallmentPlan, readCachePolicy: V15ReadCachePolicy = .standard) async {
        detailGeneration &+= 1; let generation = detailGeneration; let planID = plan.id
        selectedPlan = plan; selectedPurchase = nil; liabilities = nil; detailPhase = .loading; fieldIssues = []; serverFailure = nil
        do {
            let detail = try await services.installments.plan(id: planID, readCachePolicy: readCachePolicy)
            guard generation == detailGeneration, selectedPlan?.id == planID else { return }
            let purchase = try await services.ledger.get(transactionID: detail.purchaseTransactionID, readCachePolicy: readCachePolicy)
            guard generation == detailGeneration, selectedPlan?.id == planID else { return }
            let debt = try await services.installments.liabilities(accountID: detail.creditAccountID, readCachePolicy: readCachePolicy)
            guard generation == detailGeneration, selectedPlan?.id == planID else { return }
            selectedPlan = detail; selectedPurchase = purchase; liabilities = debt; applyEditDraft(plan: detail, purchase: purchase); applyCommandDefaults(plan: detail); detailPhase = .loaded
        } catch let failure as V15Failure {
            guard generation == detailGeneration, selectedPlan?.id == planID else { return }; detailPhase = failure.kind == .cancelled ? .idle : .failed(failure)
        } catch { guard generation == detailGeneration, selectedPlan?.id == planID else { return }; detailPhase = .failed(.init(kind: .transport, message: "分期计划详情读取失败。")) }
    }

    public func checkEligibility() async {
        eligibilityGeneration &+= 1; let generation = eligibilityGeneration
        eligibilityPurchaseGeneration &+= 1; let purchaseGeneration = eligibilityPurchaseGeneration
        eligibility = nil; eligibilityPurchase = nil; cycleOptions = []; createDraftPhase = .idle; fieldIssues = []
        guard let id = parsedPurchaseTransactionID() else {
            fieldIssues = [.init(code: "purchase_transaction_id_invalid", message: "请输入有效的消费账目 ID。", fieldPath: "purchase_transaction_id")]
            eligibilityPhase = .idle; eligibilityPurchasePhase = .idle
            return
        }
        eligibilityPhase = .loading; eligibilityPurchasePhase = .loading
        async let eligibilityLoad: (V15InstallmentEligibility, [V15InstallmentCycleOption]) = {
            let result = try await services.installments.eligibility(transactionID: id)
            let options = try await services.installments.cycleOptions(purchaseTransactionID: id, months: 60)
            return (result, options)
        }()
        async let purchaseLoad: V15Transaction = services.ledger.get(transactionID: id)
        do {
            let (result, options) = try await eligibilityLoad
            guard ownsEligibility(generation: generation, transactionID: id) else { return }
            if result.purchaseTransactionID != id {
                eligibilityPhase = .failed(.init(kind: .decoding, code: "eligibility_purchase_mismatch", message: "分期资格响应与当前消费不匹配。"))
            } else {
                eligibility = result; cycleOptions = options
                if createStartStatementDate.isEmpty { isApplyingDraft = true; createStartStatementDate = result.startOptions.first(where: { $0.eligible })?.statementDate ?? ""; isApplyingDraft = false }
                eligibilityPhase = .loaded
            }
        } catch let failure as V15Failure {
            guard ownsEligibility(generation: generation, transactionID: id) else { return }
            eligibilityPhase = failure.kind == .cancelled ? .idle : .failed(failure)
        } catch {
            guard ownsEligibility(generation: generation, transactionID: id) else { return }
            eligibilityPhase = .failed(.init(kind: .transport, message: "分期资格读取失败。"))
        }
        do {
            let purchase = try await purchaseLoad
            guard ownsEligibilityPurchase(generation: purchaseGeneration, transactionID: id) else { return }
            guard purchase.id == id, purchase.kind == "credit_purchase" else {
                eligibilityPurchasePhase = .failed(.init(kind: .decoding, code: "purchase_detail_mismatch", message: "权威消费详情与当前账目不匹配。"))
                return
            }
            eligibilityPurchase = purchase; eligibilityPurchasePhase = .loaded
        } catch let failure as V15Failure {
            guard ownsEligibilityPurchase(generation: purchaseGeneration, transactionID: id) else { return }
            eligibilityPurchasePhase = failure.kind == .cancelled ? .idle : .failed(failure)
        } catch {
            guard ownsEligibilityPurchase(generation: purchaseGeneration, transactionID: id) else { return }
            eligibilityPurchasePhase = .failed(.init(kind: .transport, message: "消费详情读取失败。"))
        }
    }

    public func createPlan() async {
        guard createPlanDisabledReason == nil, let request = createPlanRequest(recordIssues: true) else { return }
        guard let purchaseOccurredAt = eligibilityPurchase?.occurredAt,
              assertWireFeeBoundary(totalFeeMinor: request.totalFeeMinor, feeOccurredAt: request.feeOccurredAt, purchaseOccurredAt: purchaseOccurredAt) else { return }
        let payload = identity(request); let key = idempotency.key(for: "installment-create-plan", payloadIdentity: payload)
        await performCreatePlan(.init(operationID: UUID(), ownerPurchaseTransactionID: request.purchaseTransactionID, request: request, identity: payload, key: key))
    }

    public func retryUnknownCreatePlan() async {
        guard let attempt = currentCreateOwnerState?.attempt, currentCreateOwnerState?.phase == .unknown, !isOffline else { return }
        await performCreatePlan(attempt)
    }

    private func performCreatePlan(_ attempt: UnknownCreateAttempt) async {
        guard !isOffline else { return }
        guard createOwnerStates[attempt.ownerPurchaseTransactionID]?.attempt == nil || createOwnerStates[attempt.ownerPurchaseTransactionID]?.attempt?.operationID == attempt.operationID else { return }
        // Persist the immutable attempt before the first wire. Editor generation,
        // dismiss and plan selection are intentionally not operation ownership.
        mutateCreateOwner(attempt.ownerPurchaseTransactionID) { $0.attempt = attempt; $0.phase = .committing }
        serverFailure = nil
        do {
            let plan = try await services.installments.createPlan(attempt.request, idempotencyKey: attempt.key)
            guard ownsCreateOperation(ownerID: attempt.ownerPurchaseTransactionID, operationID: attempt.operationID) else { return }
            idempotency.succeeded(scope: "installment-create-plan", payloadIdentity: attempt.identity)
            mutateCreateOwner(attempt.ownerPurchaseTransactionID) { $0.attempt = nil; $0.phase = .succeeded }
            replacePlan(plan)
        } catch let failure as V15Failure {
            guard ownsCreateOperation(ownerID: attempt.ownerPurchaseTransactionID, operationID: attempt.operationID) else { return }
            if failure.kind == .responseUnknown || failure.kind == .cancelled || failure.kind == .offlineReadOnly { mutateCreateOwner(attempt.ownerPurchaseTransactionID) { $0.phase = .unknown } }
            else if failure.kind == .conflict, let conflict = failure.conflict { idempotency.abandon(scope: "installment-create-plan", payloadIdentity: attempt.identity); mutateCreateOwner(attempt.ownerPurchaseTransactionID) { $0.attempt = nil; $0.phase = .conflict(conflict) } }
            else { idempotency.abandon(scope: "installment-create-plan", payloadIdentity: attempt.identity); mutateCreateOwner(attempt.ownerPurchaseTransactionID) { $0.attempt = nil; $0.phase = .failed(failure) } }
        } catch { guard ownsCreateOperation(ownerID: attempt.ownerPurchaseTransactionID, operationID: attempt.operationID) else { return }; mutateCreateOwner(attempt.ownerPurchaseTransactionID) { $0.phase = .unknown } }
    }

    public func requestPurchasePreview() async {
        purchaseGeneration &+= 1; let generation = purchaseGeneration
        purchasePreview = nil; purchasePreparedRequest = nil; fieldIssues = []
        let frozenPurchaseOccurredAt = now()
        guard purchasePreviewDisabledReason == nil, let request = purchaseRequest(recordIssues: true, purchaseOccurredAt: frozenPurchaseOccurredAt), let ownerID = request.purchase.accountID else { purchaseDraftPhase = .idle; return }
        if purchaseOwnerStates[ownerID]?.attempt == nil { purchaseOwnerStates.removeValue(forKey: ownerID) }
        purchaseDraftPhase = .previewing
        do { let preview = try await services.installments.previewPurchase(request); guard generation == purchaseGeneration, newPurchaseAccountID == ownerID else { return }; purchasePreparedRequest = request; purchasePreview = preview; purchaseDraftPhase = .previewed }
        catch let failure as V15Failure { guard generation == purchaseGeneration, newPurchaseAccountID == ownerID else { return }; purchaseDraftPhase = failure.kind == .conflict && failure.conflict != nil ? .conflict(failure.conflict!) : .failed(failure); fieldIssues = failure.fieldIssues }
        catch { guard generation == purchaseGeneration, newPurchaseAccountID == ownerID else { return }; purchaseDraftPhase = .failed(.init(kind: .transport, message: "分期消费预览失败。")) }
    }

    public func commitPurchase() async {
        guard purchaseCommitDisabledReason == nil, let request = purchasePreparedRequest, let ownerAccountID = request.purchase.accountID else { return }
        guard assertWireFeeBoundary(totalFeeMinor: request.totalFeeMinor, feeOccurredAt: request.feeOccurredAt, purchaseOccurredAt: request.purchase.occurredAt) else { return }
        let payload = identity(request); let key = idempotency.key(for: "installment-purchase", payloadIdentity: payload)
        await performPurchase(.init(operationID: UUID(), ownerAccountID: ownerAccountID, request: request, identity: payload, key: key))
    }

    public func retryUnknownPurchase() async {
        guard let attempt = currentPurchaseOwnerState?.attempt, currentPurchaseOwnerState?.phase == .unknown, !isOffline else { return }
        await performPurchase(attempt)
    }

    private func performPurchase(_ attempt: UnknownPurchaseAttempt) async {
        guard !isOffline else { return }
        guard purchaseOwnerStates[attempt.ownerAccountID]?.attempt == nil || purchaseOwnerStates[attempt.ownerAccountID]?.attempt?.operationID == attempt.operationID else { return }
        mutatePurchaseOwner(attempt.ownerAccountID) { $0.attempt = attempt; $0.phase = .committing; $0.receipt = nil }
        do {
            let receipt = try await services.installments.createPurchase(attempt.request, idempotencyKey: attempt.key)
            guard ownsPurchaseOperation(ownerID: attempt.ownerAccountID, operationID: attempt.operationID) else { return }
            idempotency.succeeded(scope: "installment-purchase", payloadIdentity: attempt.identity)
            mutatePurchaseOwner(attempt.ownerAccountID) { $0.attempt = nil; $0.receipt = receipt; $0.phase = .succeeded }
            replacePlan(receipt.plan)
        } catch let failure as V15Failure {
            guard ownsPurchaseOperation(ownerID: attempt.ownerAccountID, operationID: attempt.operationID) else { return }
            if failure.kind == .responseUnknown || failure.kind == .cancelled || failure.kind == .offlineReadOnly { mutatePurchaseOwner(attempt.ownerAccountID) { $0.phase = .unknown } }
            else if failure.kind == .conflict, let conflict = failure.conflict { idempotency.abandon(scope: "installment-purchase", payloadIdentity: attempt.identity); mutatePurchaseOwner(attempt.ownerAccountID) { $0.attempt = nil; $0.phase = .conflict(conflict) }; if newPurchaseAccountID == attempt.ownerAccountID { purchasePreview = nil; purchasePreparedRequest = nil } }
            else { idempotency.abandon(scope: "installment-purchase", payloadIdentity: attempt.identity); mutatePurchaseOwner(attempt.ownerAccountID) { $0.attempt = nil; $0.phase = .failed(failure) } }
        } catch { guard ownsPurchaseOperation(ownerID: attempt.ownerAccountID, operationID: attempt.operationID) else { return }; mutatePurchaseOwner(attempt.ownerAccountID) { $0.phase = .unknown } }
    }

    public func requestPlanPreview() async {
        guard let plan = selectedPlan else { return }
        guard planPreviewDisabledReason == nil, let request = replacementRequest(recordIssues: true) else { return }
        let generation = next(&planGeneration, for: plan.id); let payload = identity(request)
        mutate(plan.id) { $0.planPhase = .previewing; $0.planPreview = nil; $0.planPreviewIdentity = nil; $0.planPreparedRequest = nil }
        do {
            let preview = try await services.installments.previewPlan(planID: plan.id, request: request)
            guard isCurrent(generation, in: planGeneration, planID: plan.id) else { return }
            mutate(plan.id) { $0.planPreview = preview; $0.planPreviewIdentity = payload; $0.planPreparedRequest = request; $0.planPhase = .previewed }
        } catch let failure as V15Failure {
            guard isCurrent(generation, in: planGeneration, planID: plan.id) else { return }
            mutate(plan.id) { $0.planPhase = failure.kind == .conflict && failure.conflict != nil ? .conflict(failure.conflict!) : .failed(failure) }; fieldIssues = failure.fieldIssues
        } catch { guard isCurrent(generation, in: planGeneration, planID: plan.id) else { return }; mutate(plan.id) { $0.planPhase = .failed(.init(kind: .transport, message: "计划修改预览失败。")) } }
    }

    public func commitPlanUpdate() async {
        guard let plan = selectedPlan, planCommitDisabledReason == nil, let request = currentState.planPreparedRequest else { return }
        guard currentState.planPreviewIdentity == identity(request) else { invalidatePlanPreview(plan.id); return }
        guard assertWireFeeBoundary(totalFeeMinor: request.totalFeeMinor, feeOccurredAt: request.feeOccurredAt, purchaseOccurredAt: request.purchase.occurredAt) else { return }
        let attempt = UnknownUpdateAttempt(operationID: UUID(), planID: plan.id, ownerAccountID: plan.creditAccountID, purchaseTransactionID: plan.purchaseTransactionID, request: request)
        // PUT has no key and is never retransmitted. Persist the full intent
        // before sending so dismiss/edit/selection cannot erase readback state.
        mutate(plan.id) { $0.updateAttempt = attempt; $0.planPhase = .committing; $0.updateReadback = .idle }
        do {
            let updated = try await services.installments.updatePlan(planID: plan.id, request: request)
            guard ownsUpdateOperation(planID: plan.id, operationID: attempt.operationID) else { return }
            mutate(plan.id) { $0.planPhase = .succeeded; $0.planPreview = nil; $0.planPreviewIdentity = nil; $0.planPreparedRequest = nil; $0.updateAttempt = nil; $0.updateReadback = .idle }
            replacePlan(updated)
            if selectedPlan?.id == plan.id { selectedPlan = updated }
        } catch let failure as V15Failure {
            guard ownsUpdateOperation(planID: plan.id, operationID: attempt.operationID) else { return }
            if failure.kind == .responseUnknown || failure.kind == .cancelled || failure.kind == .offlineReadOnly { mutate(plan.id) { $0.planPhase = .unknown } }
            else if failure.kind == .conflict, let conflict = failure.conflict { mutate(plan.id) { $0.planPhase = .conflict(conflict); $0.planPreview = nil; $0.planPreviewIdentity = nil; $0.planPreparedRequest = nil; $0.updateAttempt = nil }; if selectedPlan?.id == plan.id { reloadRequired = true } }
            else { mutate(plan.id) { $0.planPhase = .failed(failure); $0.updateAttempt = nil } }
        } catch { guard ownsUpdateOperation(planID: plan.id, operationID: attempt.operationID) else { return }; mutate(plan.id) { $0.planPhase = .unknown } }
    }

    /// The no-key PUT is never retransmitted. Only two fresh GETs can confirm
    /// its exact plan and purchase intent.
    public func readBackUnknownPlanUpdate() async {
        guard let planID = selectedPlan?.id, let attempt = currentState.updateAttempt else { return }
        guard !isOffline else { mutate(planID) { $0.updateReadback = .notConfirmed }; return }
        let generation = next(&readbackGeneration, for: planID); mutate(planID) { $0.updateReadback = .loading }
        do {
            let plan = try await services.installments.plan(id: planID, readCachePolicy: .reloadIgnoringCache)
            guard readbackGeneration[planID] == generation, ownsUpdateOperation(planID: planID, operationID: attempt.operationID) else { return }
            let purchase = try await services.ledger.get(transactionID: attempt.purchaseTransactionID, readCachePolicy: .reloadIgnoringCache)
            guard readbackGeneration[planID] == generation, ownsUpdateOperation(planID: planID, operationID: attempt.operationID) else { return }
            if updateMatches(plan: plan, purchase: purchase, attempt: attempt) {
                mutate(planID) { $0.updateReadback = .confirmed; $0.planPhase = .succeeded; $0.updateAttempt = nil; $0.planPreview = nil; $0.planPreviewIdentity = nil; $0.planPreparedRequest = nil }
                replacePlan(plan)
                if selectedPlan?.id == planID { selectedPlan = plan; selectedPurchase = purchase; applyEditDraft(plan: plan, purchase: purchase) }
            } else { mutate(planID) { $0.updateReadback = .notConfirmed } }
        } catch let failure as V15Failure { guard readbackGeneration[planID] == generation, ownsUpdateOperation(planID: planID, operationID: attempt.operationID) else { return }; mutate(planID) { $0.updateReadback = .failed(failure) } }
        catch { guard readbackGeneration[planID] == generation, ownsUpdateOperation(planID: planID, operationID: attempt.operationID) else { return }; mutate(planID) { $0.updateReadback = .failed(.init(kind: .transport, message: "计划事实核对失败。")) } }
    }

    public func requestCommandPreview() async {
        guard let plan = selectedPlan, commandPreviewDisabledReason == nil, let request = commandRequest(recordIssues: true) else { return }
        let generation = next(&commandGeneration, for: plan.id); let payload = commandIdentity(kind: commandKind, request: request)
        mutate(plan.id) { $0.commandPhase = .previewing; $0.commandPreview = nil; $0.commandPreviewIdentity = nil; $0.commandPreparedRequest = nil; $0.commandReceipt = nil }
        do {
            let preview: CommandPreview
            switch request {
            case .settlement(let value): preview = .settlement(try await services.installments.settlementPreview(planID: plan.id, request: value))
            case .action(let value):
                preview = commandKind == .reverseSettlement ? .reverse(try await services.installments.reverseSettlementPreview(planID: plan.id, request: value)) : .cancellation(try await services.installments.cancellationPreview(planID: plan.id, request: value))
            }
            guard isCurrent(generation, in: commandGeneration, planID: plan.id) else { return }
            mutate(plan.id) { $0.commandPreview = preview; $0.commandPreviewIdentity = payload; $0.commandPreparedRequest = request; $0.commandPhase = .previewed }
        } catch let failure as V15Failure {
            guard isCurrent(generation, in: commandGeneration, planID: plan.id) else { return }
            mutate(plan.id) { $0.commandPhase = failure.kind == .conflict && failure.conflict != nil ? .conflict(failure.conflict!) : .failed(failure) }; fieldIssues = failure.fieldIssues
        } catch { guard isCurrent(generation, in: commandGeneration, planID: plan.id) else { return }; mutate(plan.id) { $0.commandPhase = .failed(.init(kind: .transport, message: "操作预览失败。")) } }
    }

    public func commitCommand() async {
        guard let plan = selectedPlan, commandCommitDisabledReason == nil, let request = currentState.commandPreparedRequest else { return }
        let payload = commandIdentity(kind: commandKind, request: request)
        guard currentState.commandPreviewIdentity == payload else { invalidateCommandPreview(plan.id, abandonKey: true); return }
        let key = idempotency.key(for: "installment-command-\(plan.id.uuidString)-\(commandKind.rawValue)", payloadIdentity: payload)
        await performCommand(.init(operationID: UUID(), planID: plan.id, ownerAccountID: plan.creditAccountID, kind: commandKind, request: request, identity: payload, key: key))
    }

    public func retryUnknownCommand() async {
        guard let attempt = currentState.unknownCommand, selectedPlan?.id == attempt.planID, !isOffline else { return }
        await performCommand(attempt)
    }

    private func performCommand(_ attempt: UnknownCommandAttempt) async {
        guard !isOffline else { return }
        guard planStates[attempt.planID]?.unknownCommand == nil || planStates[attempt.planID]?.unknownCommand?.operationID == attempt.operationID else { return }
        // Persist the exact command body, stable key and owner before the first
        // wire. UI generation/selection only owns previews, never this write.
        mutate(attempt.planID) { $0.unknownCommand = attempt; $0.commandPhase = .committing; $0.commandReadback = .idle }
        do {
            let receipt: CommandReceipt
            switch (attempt.kind, attempt.request) {
            case (.settleEarly, .settlement(let request)): receipt = .settlement(try await services.installments.settleEarly(planID: attempt.planID, request: request, idempotencyKey: attempt.key))
            case (.reverseSettlement, .action(let request)): receipt = .reverse(try await services.installments.reverseSettlement(planID: attempt.planID, request: request, idempotencyKey: attempt.key))
            case (.cancelFuture, .action(let request)): receipt = .cancellation(try await services.installments.cancelFuture(planID: attempt.planID, request: request, idempotencyKey: attempt.key))
            default:
                let failure = V15Failure(kind: .decoding, message: "操作类型与请求不匹配。")
                idempotency.abandon(scope: "installment-command-\(attempt.planID.uuidString)-\(attempt.kind.rawValue)", payloadIdentity: attempt.identity)
                mutate(attempt.planID) { $0.commandPhase = .failed(failure); $0.unknownCommand = nil }
                return
            }
            guard ownsCommandOperation(planID: attempt.planID, operationID: attempt.operationID) else { return }
            idempotency.succeeded(scope: "installment-command-\(attempt.planID.uuidString)-\(attempt.kind.rawValue)", payloadIdentity: attempt.identity)
            mutate(attempt.planID) { $0.commandReceipt = receipt; $0.commandPhase = .succeeded; $0.commandPreview = nil; $0.commandPreviewIdentity = nil; $0.commandPreparedRequest = nil; $0.unknownCommand = nil; $0.commandReadback = .idle }
            replacePlan(receipt.plan)
            if selectedPlan?.id == attempt.planID { selectedPlan = receipt.plan; applyCommandDefaults(plan: receipt.plan) }
        } catch let failure as V15Failure {
            guard ownsCommandOperation(planID: attempt.planID, operationID: attempt.operationID) else { return }
            if failure.kind == .responseUnknown || failure.kind == .cancelled || failure.kind == .offlineReadOnly { mutate(attempt.planID) { $0.commandPhase = .unknown } }
            else if failure.kind == .conflict, let conflict = failure.conflict { idempotency.abandon(scope: "installment-command-\(attempt.planID.uuidString)-\(attempt.kind.rawValue)", payloadIdentity: attempt.identity); mutate(attempt.planID) { $0.commandPhase = .conflict(conflict); $0.commandPreview = nil; $0.commandPreviewIdentity = nil; $0.commandPreparedRequest = nil; $0.unknownCommand = nil }; if selectedPlan?.id == attempt.planID { reloadRequired = true } }
            else { idempotency.abandon(scope: "installment-command-\(attempt.planID.uuidString)-\(attempt.kind.rawValue)", payloadIdentity: attempt.identity); mutate(attempt.planID) { $0.commandPhase = .failed(failure); $0.unknownCommand = nil } }
        } catch { guard ownsCommandOperation(planID: attempt.planID, operationID: attempt.operationID) else { return }; mutate(attempt.planID) { $0.commandPhase = .unknown } }
    }

    public func readBackUnknownCommand() async {
        guard let planID = selectedPlan?.id, let attempt = currentState.unknownCommand else { return }
        guard !isOffline else { mutate(planID) { $0.commandReadback = .notConfirmed }; return }
        let generation = next(&readbackGeneration, for: planID); mutate(planID) { $0.commandReadback = .loading }
        do {
            let plan = try await services.installments.plan(id: planID, readCachePolicy: .reloadIgnoringCache)
            guard readbackGeneration[planID] == generation, ownsCommandOperation(planID: planID, operationID: attempt.operationID) else { return }
            // A plan GET cannot prove which payment account, target statement
            // date, occurrence instant or operation receipt produced the fact.
            // Even a matching state/version may be a third-party operation.
            replacePlan(plan); if selectedPlan?.id == planID { selectedPlan = plan }
            mutate(planID) { $0.commandReadback = .notConfirmed; $0.commandPhase = .unknown }
        } catch let failure as V15Failure { guard readbackGeneration[planID] == generation, ownsCommandOperation(planID: planID, operationID: attempt.operationID) else { return }; mutate(planID) { $0.commandReadback = .failed(failure) } }
        catch { guard readbackGeneration[planID] == generation, ownsCommandOperation(planID: planID, operationID: attempt.operationID) else { return }; mutate(planID) { $0.commandReadback = .failed(.init(kind: .transport, message: "操作事实核对失败。")) } }
    }

    public func abandonUnknownCommandAndReload() async {
        guard let planID = selectedPlan?.id, let attempt = currentState.unknownCommand else { return }
        idempotency.abandon(scope: "installment-command-\(planID.uuidString)-\(attempt.kind.rawValue)", payloadIdentity: attempt.identity)
        mutate(planID) { $0.unknownCommand = nil; $0.commandPhase = .idle; $0.commandReadback = .idle; $0.commandPreview = nil; $0.commandPreviewIdentity = nil; $0.commandPreparedRequest = nil }
        if let plan = selectedPlan { await selectPlan(plan, readCachePolicy: .reloadIgnoringCache) }
    }

    public func dismissEditor() {
        purchaseGeneration &+= 1; createGeneration &+= 1
        purchasePreview = nil; purchasePreparedRequest = nil; purchaseDraftPhase = .idle; idempotency.abandon(scope: "installment-purchase")
        createDraftPhase = .idle; idempotency.abandon(scope: "installment-create-plan")
        eligibilityInputChanged()
        guard let planID = selectedPlan?.id else { return }
        next(&planGeneration, for: planID); next(&commandGeneration, for: planID)
        invalidatePlanPreview(planID); invalidateCommandPreview(planID, abandonKey: currentState.unknownCommand == nil)
    }

    private func refreshAndSelect(_ planID: UUID) async {
        listGeneration &+= 1; let generation = listGeneration; pageGeneration &+= 1
        await loadPlans(reset: true, listGeneration: generation, readCachePolicy: .reloadIgnoringCache)
        if let plan = plans.first(where: { $0.id == planID }) { await selectPlan(plan, readCachePolicy: .reloadIgnoringCache) }
    }
    private func replacementRequest(recordIssues: Bool, issuesSink: (([V15FieldIssue]) -> Void)? = nil) -> V15InstallmentReplacementRequest? {
        var issues: [V15FieldIssue] = []
        guard let plan = selectedPlan, let purchase = selectedPurchase else {
            issues = [.init(code: "plan_detail_required", message: "计划详情尚未加载。", fieldPath: nil)]
            if recordIssues { fieldIssues = issues }; issuesSink?(issues)
            return nil
        }
        let amount = CNYAmountParser.minorUnits(editAmountText); if amount == nil || amount! <= 0 { issues.append(.init(code: "amount_invalid", message: "消费金额须为大于 0 的元金额，最多两位小数。", fieldPath: "purchase.amount_minor")) }
        let count = Int(editCountText); if count == nil || !(2...60).contains(count!) { issues.append(.init(code: "count_invalid", message: "分期期数须为 2–60。", fieldPath: "installment_count")) }
        let fee = CNYAmountParser.minorUnits(editFeeText); if fee == nil || fee! < 0 { issues.append(.init(code: "fee_invalid", message: "手续费须为非负元金额，最多两位小数。", fieldPath: "total_fee_minor")) }
        if editTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(.init(code: "title_required", message: "请填写消费标题。", fieldPath: "purchase.title")) }
        if editAccountID == nil { issues.append(.init(code: "account_required", message: "请选择信用账户。", fieldPath: "purchase.account_id")) }
        if let disabled = expenseCategoryLoadingReason { issues.append(.init(code: disabled.code, message: disabled.message, fieldPath: "purchase.category_id")) }
        if editCategoryID == nil || !expenseCategories.contains(where: { $0.id == editCategoryID }) { issues.append(.init(code: "category_required", message: "请选择服务端返回的有效支出分类。", fieldPath: "purchase.category_id")) }
        if !isDate(editStartStatementDate) { issues.append(.init(code: "date_invalid", message: "起始账单日期须为 YYYY-MM-DD。", fieldPath: "start_statement_date")) }
        let feeDetails = validatedFeeDetails(totalFeeMinor: fee, categoryID: editFeeCategoryID, occurredDateText: editFeeOccurredDateText, purchaseOccurredAt: purchase.occurredAt, preserving: editOriginalFeeOccurredAt, issues: &issues)
        if recordIssues { fieldIssues = issues }; issuesSink?(issues)
        guard issues.isEmpty, let amount, let count, let fee, let account = editAccountID, let category = editCategoryID else { return nil }
        return .init(expectedVersion: plan.version, purchase: .init(amountMinor: amount, occurredAt: purchase.occurredAt, title: editTitle.trimmingCharacters(in: .whitespacesAndNewlines), note: editNote.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty, accountID: account, categoryID: category), installmentCount: count, totalFeeMinor: fee, feeCategoryID: feeDetails?.categoryID, feeOccurredAt: feeDetails?.occurredAt, startStatementDate: editStartStatementDate)
    }

    private func purchaseRequest(recordIssues: Bool, purchaseOccurredAt frozenPurchaseOccurredAt: Date? = nil, issuesSink: (([V15FieldIssue]) -> Void)? = nil) -> V15InstallmentPurchaseCreateRequest? {
        var issues: [V15FieldIssue] = []
        let purchaseOccurredAt = frozenPurchaseOccurredAt ?? now()
        let amount = CNYAmountParser.minorUnits(newPurchaseAmountText); if amount == nil || amount! <= 0 { issues.append(.init(code: "amount_invalid", message: "消费金额须为大于 0 的元金额。", fieldPath: "purchase.amount_minor")) }
        let count = Int(newPurchaseCountText); if count == nil || !(2...60).contains(count!) { issues.append(.init(code: "count_invalid", message: "分期期数须为 2–60。", fieldPath: "installment_count")) }
        let fee = CNYAmountParser.minorUnits(newPurchaseFeeText); if fee == nil || fee! < 0 { issues.append(.init(code: "fee_invalid", message: "手续费须为非负元金额。", fieldPath: "total_fee_minor")) }
        if newPurchaseTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(.init(code: "title_required", message: "请填写消费标题。", fieldPath: "purchase.title")) }
        if newPurchaseAccountID == nil { issues.append(.init(code: "account_required", message: "请选择信用账户。", fieldPath: "purchase.account_id")) }
        if let disabled = expenseCategoryLoadingReason { issues.append(.init(code: disabled.code, message: disabled.message, fieldPath: "purchase.category_id")) }
        if newPurchaseCategoryID == nil || !expenseCategories.contains(where: { $0.id == newPurchaseCategoryID }) { issues.append(.init(code: "category_required", message: "请选择服务端返回的有效支出分类。", fieldPath: "purchase.category_id")) }
        if !newPurchaseStartStatementDate.isEmpty && !isDate(newPurchaseStartStatementDate) { issues.append(.init(code: "date_invalid", message: "账单日期须为 YYYY-MM-DD。", fieldPath: "start_statement_date")) }
        let feeDetails = validatedFeeDetails(totalFeeMinor: fee, categoryID: newPurchaseFeeCategoryID, occurredDateText: newPurchaseFeeOccurredDateText, purchaseOccurredAt: purchaseOccurredAt, preserving: nil, issues: &issues)
        if recordIssues { fieldIssues = issues }; issuesSink?(issues)
        guard issues.isEmpty, let amount, let count, let fee, let account = newPurchaseAccountID, let category = newPurchaseCategoryID else { return nil }
        let draft = V15TransactionCreateRequest(kind: .creditPurchase, amountMinor: amount, occurredAt: purchaseOccurredAt, title: newPurchaseTitle.trimmingCharacters(in: .whitespacesAndNewlines), accountID: account, categoryID: category)
        return .init(purchase: draft, installmentCount: count, totalFeeMinor: fee, feeCategoryID: feeDetails?.categoryID, feeOccurredAt: feeDetails?.occurredAt, startStatementDate: newPurchaseStartStatementDate.nilIfEmpty)
    }

    private func createPlanRequest(recordIssues: Bool, issuesSink: (([V15FieldIssue]) -> Void)? = nil) -> V15InstallmentCreateRequest? {
        var issues: [V15FieldIssue] = []
        let id = UUID(uuidString: purchaseTransactionIDText.trimmingCharacters(in: .whitespacesAndNewlines)); let count = Int(createInstallmentCountText); let fee = CNYAmountParser.minorUnits(createFeeText)
        if id == nil { issues.append(.init(code: "purchase_required", message: "请输入有效的消费账目 ID。", fieldPath: "purchase_transaction_id")) }
        if id != eligibilityPurchase?.id || eligibilityPurchase?.kind != "credit_purchase" { issues.append(.init(code: "purchase_detail_required", message: "请先读取与当前 ID 匹配的权威消费详情。", fieldPath: "purchase_transaction_id")) }
        if count == nil || !(2...60).contains(count!) { issues.append(.init(code: "count_invalid", message: "分期期数须为 2–60。", fieldPath: "installment_count")) }
        if fee == nil || fee! < 0 { issues.append(.init(code: "fee_invalid", message: "手续费须为非负元金额。", fieldPath: "total_fee_minor")) }
        if !isDate(createStartStatementDate) || !cycleOptions.contains(where: { $0.statementDate == createStartStatementDate && $0.eligible }) { issues.append(.init(code: "start_not_eligible", message: "请选择服务端返回的可用起始账期。", fieldPath: "start_statement_date")) }
        let feeDetails = validatedFeeDetails(totalFeeMinor: fee, categoryID: createFeeCategoryID, occurredDateText: createFeeOccurredDateText, purchaseOccurredAt: eligibilityPurchase?.occurredAt, preserving: nil, issues: &issues)
        if recordIssues { fieldIssues = issues }; issuesSink?(issues)
        guard issues.isEmpty, let id, let count, let fee else { return nil }
        return .init(purchaseTransactionID: id, installmentCount: count, totalFeeMinor: fee, feeCategoryID: feeDetails?.categoryID, feeOccurredAt: feeDetails?.occurredAt, startStatementDate: createStartStatementDate)
    }

    private func commandRequest(recordIssues: Bool) -> UnknownCommandAttempt.Request? {
        guard let plan = selectedPlan else { return nil }
        var issues: [V15FieldIssue] = []
        let result: UnknownCommandAttempt.Request?
        if commandKind == .settleEarly {
            if paymentAccountID == nil { issues.append(.init(code: "payment_account_required", message: "请选择现金或借记付款账户。", fieldPath: "payment_account_id")) }
            if !isDate(targetStatementDate) { issues.append(.init(code: "target_date_invalid", message: "请选择服务端计划中的账单日期。", fieldPath: "target_statement_date")) }
            result = paymentAccountID.map { .settlement(.init(expectedVersion: plan.version, occurredAt: now(), paymentAccountID: $0, targetStatementDate: targetStatementDate)) }
        } else { result = .action(.init(expectedVersion: plan.version, occurredAt: now())) }
        if recordIssues { fieldIssues = issues }; return issues.isEmpty ? result : nil
    }

    private func updateMatches(plan: V15InstallmentPlan, purchase: V15Transaction, attempt: UnknownUpdateAttempt) -> Bool {
        let request = attempt.request
        return plan.id == attempt.planID
            && plan.version > request.expectedVersion
            && plan.purchaseTransactionID == attempt.purchaseTransactionID
            && purchase.id == attempt.purchaseTransactionID
            && purchase.installmentPlanID == attempt.planID
            && purchase.kind == "credit_purchase"
            && plan.title == request.purchase.title
            && plan.principalMinor == request.purchase.amountMinor
            && plan.creditAccountID == request.purchase.accountID
            && plan.installmentCount == request.installmentCount
            && plan.feeMinor == request.totalFeeMinor
            && plan.totalFinancedMinor == request.purchase.amountMinor + request.totalFeeMinor
            && plan.feeCategoryID == request.feeCategoryID
            && plan.feeOccurredAt == request.feeOccurredAt
            && plan.startStatementDate == request.startStatementDate
            && purchase.amountMinor == request.purchase.amountMinor
            && purchase.occurredAt == request.purchase.occurredAt
            && purchase.title == request.purchase.title
            && purchase.note == request.purchase.note
            && purchase.accountID == request.purchase.accountID
            && purchase.categoryID == request.purchase.categoryID
    }

    private func applyEditDraft(plan: V15InstallmentPlan, purchase: V15Transaction) {
        isApplyingDraft = true
        editOriginalFeeOccurredAt = plan.feeOccurredAt
        editTitle = purchase.title; editAmountText = Self.majorText(purchase.amountMinor); editNote = purchase.note ?? ""; editAccountID = purchase.accountID; editCategoryID = purchase.categoryID
        editCountText = String(plan.installmentCount); editFeeText = Self.majorText(plan.feeMinor); editFeeCategoryID = plan.feeMinor > 0 ? plan.feeCategoryID : nil; editFeeOccurredDateText = plan.feeMinor > 0 ? plan.feeOccurredAt.map(ShanghaiBusinessDate.string(for:)) ?? "" : ""; editStartStatementDate = plan.startStatementDate
        isApplyingDraft = false
    }
    private func applyCommandDefaults(plan: V15InstallmentPlan) {
        isApplyingDraft = true
        paymentAccountID = paymentAccounts.first?.id
        targetStatementDate = plan.periods.first(where: { !$0.locked })?.effectiveStatementDate ?? plan.nextPeriod?.effectiveStatementDate ?? plan.startStatementDate
        isApplyingDraft = false
    }
    private func eligibilityInputChanged() {
        guard !isApplyingDraft else { return }
        eligibilityGeneration &+= 1; eligibilityPurchaseGeneration &+= 1
        eligibility = nil; eligibilityPurchase = nil; cycleOptions = []
        eligibilityPhase = .idle; eligibilityPurchasePhase = .idle; createDraftPhase = .idle
        idempotency.abandon(scope: "installment-create-plan")
    }
    private func createInputChanged() { guard !isApplyingDraft else { return }; createGeneration &+= 1; createDraftPhase = .idle; idempotency.abandon(scope: "installment-create-plan") }
    private func createFeeInputChanged() {
        guard !isApplyingDraft else { return }
        if CNYAmountParser.minorUnits(createFeeText) == 0 { isApplyingDraft = true; createFeeCategoryID = nil; createFeeOccurredDateText = ""; isApplyingDraft = false }
        createInputChanged()
    }
    private func purchaseInputChanged() { guard !isApplyingDraft else { return }; purchaseGeneration &+= 1; purchasePreview = nil; purchasePreparedRequest = nil; purchaseDraftPhase = .idle; idempotency.abandon(scope: "installment-purchase") }
    private func purchaseFeeInputChanged() {
        guard !isApplyingDraft else { return }
        if CNYAmountParser.minorUnits(newPurchaseFeeText) == 0 { isApplyingDraft = true; newPurchaseFeeCategoryID = nil; newPurchaseFeeOccurredDateText = ""; isApplyingDraft = false }
        purchaseInputChanged()
    }
    private func planInputChanged() { guard !isApplyingDraft, let id = selectedPlan?.id, planStates[id]?.updateAttempt == nil else { return }; next(&planGeneration, for: id); invalidatePlanPreview(id) }
    private func editFeeInputChanged() {
        guard !isApplyingDraft else { return }
        if CNYAmountParser.minorUnits(editFeeText) == 0 { isApplyingDraft = true; editFeeCategoryID = nil; editFeeOccurredDateText = ""; isApplyingDraft = false }
        planInputChanged()
    }
    private func commandInputChanged() { guard !isApplyingDraft, let id = selectedPlan?.id, planStates[id]?.unknownCommand == nil else { return }; next(&commandGeneration, for: id); invalidateCommandPreview(id, abandonKey: true) }
    private func invalidatePlanPreview(_ id: UUID) { mutate(id) { $0.planPreview = nil; $0.planPreviewIdentity = nil; $0.planPreparedRequest = nil; if $0.updateAttempt == nil { $0.planPhase = .idle; $0.updateReadback = .idle } } }
    private func invalidateCommandPreview(_ id: UUID, abandonKey: Bool) {
        if abandonKey { for kind in CommandKind.allCases { idempotency.abandon(scope: "installment-command-\(id.uuidString)-\(kind.rawValue)") } }
        mutate(id) { $0.commandPreview = nil; $0.commandPreviewIdentity = nil; $0.commandPreparedRequest = nil; $0.commandReceipt = nil; if $0.unknownCommand == nil { $0.commandPhase = .idle; $0.commandReadback = .idle } }
    }
    private func mutatePurchaseOwner(_ id: UUID, _ change: (inout PurchaseOwnerState) -> Void) { var value = purchaseOwnerStates[id] ?? .init(); change(&value); purchaseOwnerStates[id] = value }
    private func mutateCreateOwner(_ id: UUID, _ change: (inout CreateOwnerState) -> Void) { var value = createOwnerStates[id] ?? .init(); change(&value); createOwnerStates[id] = value }
    private func ownsPurchaseOperation(ownerID: UUID, operationID: UUID) -> Bool { purchaseOwnerStates[ownerID]?.attempt?.operationID == operationID }
    private func ownsCreateOperation(ownerID: UUID, operationID: UUID) -> Bool { createOwnerStates[ownerID]?.attempt?.operationID == operationID }
    private func parsedPurchaseTransactionID() -> UUID? { UUID(uuidString: purchaseTransactionIDText.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private func ownsEligibility(generation: UInt64, transactionID: UUID) -> Bool { generation == eligibilityGeneration && parsedPurchaseTransactionID() == transactionID }
    private func ownsEligibilityPurchase(generation: UInt64, transactionID: UUID) -> Bool { generation == eligibilityPurchaseGeneration && parsedPurchaseTransactionID() == transactionID }
    private func mutate(_ id: UUID, _ change: (inout PlanState) -> Void) { var value = planStates[id] ?? .init(); change(&value); planStates[id] = value }
    private func ownsUpdateOperation(planID: UUID, operationID: UUID) -> Bool { planStates[planID]?.updateAttempt?.operationID == operationID }
    private func ownsCommandOperation(planID: UUID, operationID: UUID) -> Bool { planStates[planID]?.unknownCommand?.operationID == operationID }
    @discardableResult private func next(_ values: inout [UUID: UInt64], for id: UUID) -> UInt64 { let value = (values[id] ?? 0) &+ 1; values[id] = value; return value }
    private func isCurrent(_ value: UInt64, in values: [UUID: UInt64], planID: UUID) -> Bool { values[planID] == value && selectedPlan?.id == planID }
    private func replacePlan(_ plan: V15InstallmentPlan) {
        if let index = plans.firstIndex(where: { $0.id == plan.id }) { plans[index] = plan }
        else if filterAccountID == nil || filterAccountID == plan.creditAccountID { plans.append(plan) }
    }
    private func unique(_ values: [V15InstallmentPlan]) -> [V15InstallmentPlan] { var seen = Set<UUID>(); return values.filter { seen.insert($0.id).inserted } }
    private func flattenedCategories(_ values: [V15CategoryResponse]) -> [V15CategoryResponse] { values.flatMap { [$0] + flattenedCategories($0.children) } }
    private func identity<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(data: encoder.encode(value), encoding: .utf8)) ?? "invalid"
    }
    private func commandIdentity(kind: CommandKind, request: UnknownCommandAttempt.Request) -> String { switch request { case .settlement(let value): "\(kind.rawValue):\(identity(value))"; case .action(let value): "\(kind.rawValue):\(identity(value))" } }
    private func reason(_ code: String, _ message: String) -> V15DisabledReason { .init(code: code, message: message, fieldPath: nil) }
    private func disabledReason(for issue: V15FieldIssue) -> V15DisabledReason { .init(code: issue.code, message: issue.message, fieldPath: issue.fieldPath) }
    private func validatedFeeDetails(totalFeeMinor: V15MinorUnits?, categoryID: UUID?, occurredDateText: String, purchaseOccurredAt: Date?, preserving original: Date?, issues: inout [V15FieldIssue]) -> (categoryID: UUID, occurredAt: Date)? {
        guard let totalFeeMinor, totalFeeMinor > 0 else { return nil }
        if let disabled = feeCategoryLoadingReason { issues.append(.init(code: disabled.code, message: disabled.message, fieldPath: "fee_category_id")) }
        let occurrence = feeOccurrence(occurredDateText, purchaseOccurredAt: purchaseOccurredAt, preserving: original)
        if let issue = occurrence.issue { issues.append(issue) }
        guard let categoryID, expenseCategories.contains(where: { $0.id == categoryID }) else {
            issues.append(.init(code: "fee_category_required", message: "正手续费必须选择服务端返回的有效支出分类。", fieldPath: "fee_category_id"))
            return nil
        }
        guard let occurredAt = occurrence.date else { return nil }
        return (categoryID, occurredAt)
    }
    private func feeOccurrence(_ value: String, purchaseOccurredAt: Date?, preserving original: Date?) -> (date: Date?, issue: V15FieldIssue?) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let purchaseOccurredAt else {
            return (nil, .init(code: "purchase_occurred_at_required", message: "必须先读取权威消费发生时间，才能确定手续费时间。", fieldPath: "fee_occurred_at"))
        }
        let referenceNow = now()
        let purchaseBusinessDate = ShanghaiBusinessDate.string(for: purchaseOccurredAt)
        let today = ShanghaiBusinessDate.string(for: referenceNow)
        let occurredAt: Date
        if let original, ShanghaiBusinessDate.string(for: original) == trimmed {
            occurredAt = original
        } else {
            guard let startOfDay = businessDate(trimmed) else {
                return (nil, .init(code: "fee_occurred_at_invalid", message: "手续费发生日期须为有效的 YYYY-MM-DD（Asia/Shanghai）。", fieldPath: "fee_occurred_at"))
            }
            if trimmed < purchaseBusinessDate {
                return (nil, .init(code: "fee_before_purchase", message: "手续费发生日期不能早于消费发生日期 \(purchaseBusinessDate)。", fieldPath: "fee_occurred_at"))
            }
            if trimmed > today {
                return (nil, .init(code: "fee_in_future", message: "手续费发生日期不能晚于今天 \(today)。", fieldPath: "fee_occurred_at"))
            }
            if trimmed == purchaseBusinessDate {
                occurredAt = purchaseOccurredAt
            } else if trimmed == today {
                occurredAt = min(startOfDay, referenceNow)
            } else {
                occurredAt = startOfDay
            }
        }
        guard occurredAt >= purchaseOccurredAt, occurredAt <= referenceNow else {
            return (nil, .init(code: "fee_time_out_of_bounds", message: "手续费时间必须不早于消费发生时间，且不得晚于当前时间。", fieldPath: "fee_occurred_at"))
        }
        return (occurredAt, nil)
    }
    private func feeBoundaryDisabledReason(totalFeeText: String, occurredDateText: String, purchaseOccurredAt: Date?, preserving original: Date?) -> V15DisabledReason? {
        guard let fee = CNYAmountParser.minorUnits(totalFeeText), fee > 0 else { return nil }
        guard let issue = feeOccurrence(occurredDateText, purchaseOccurredAt: purchaseOccurredAt, preserving: original).issue else { return nil }
        return .init(code: issue.code, message: issue.message, fieldPath: issue.fieldPath)
    }
    private func assertWireFeeBoundary(totalFeeMinor: V15MinorUnits, feeOccurredAt: Date?, purchaseOccurredAt: Date) -> Bool {
        if let issue = wireFeeBoundaryIssue(totalFeeMinor: totalFeeMinor, feeOccurredAt: feeOccurredAt, purchaseOccurredAt: purchaseOccurredAt) { fieldIssues = [issue]; return false }
        return true
    }
    private func wireFeeBoundaryIssue(totalFeeMinor: V15MinorUnits, feeOccurredAt: Date?, purchaseOccurredAt: Date) -> V15FieldIssue? {
        if totalFeeMinor == 0 {
            return feeOccurredAt == nil ? nil : .init(code: "zero_fee_forbids_time", message: "零手续费不能携带手续费发生时间。", fieldPath: "fee_occurred_at")
        } else if let feeOccurredAt, feeOccurredAt >= purchaseOccurredAt, feeOccurredAt <= now() {
            return nil
        } else {
            return .init(code: "fee_time_out_of_bounds", message: "手续费时间必须不早于消费发生时间，且不得晚于当前时间。", fieldPath: "fee_occurred_at")
        }
    }
    private func businessDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.locale = Locale(identifier: "zh_CN"); calendar.timeZone = ShanghaiBusinessDate.timeZone
        guard let date = calendar.date(from: DateComponents(timeZone: ShanghaiBusinessDate.timeZone, year: parts[0], month: parts[1], day: parts[2])), ShanghaiBusinessDate.string(for: date) == trimmed else { return nil }
        return calendar.startOfDay(for: date)
    }
    private func isDate(_ value: String) -> Bool { businessDate(value) != nil }
    private static func majorText(_ minor: Int64) -> String { let sign = minor < 0 ? "-" : ""; let absolute = minor == .min ? UInt64(Int64.max) + 1 : UInt64(Swift.abs(minor)); return "\(sign)\(absolute / 100).\(String(format: "%02llu", absolute % 100))" }
}

private extension String {
    var nilIfEmpty: String? { let value = trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? nil : value }
}
