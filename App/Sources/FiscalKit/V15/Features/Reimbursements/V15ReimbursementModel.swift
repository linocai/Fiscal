import Foundation
import Observation

@MainActor @Observable
public final class V15ReimbursementModel {
    public enum Phase: Equatable { case idle, loading, loaded, empty, failed(V15Failure) }
    public enum PagePhase: Equatable { case idle, loading, failed(V15Failure) }
    public enum EditorPhase: Equatable { case idle, loading, ready, previewing, previewed, committing, succeeded, unknown, conflict(V15Conflict), failed(V15Failure) }
    public enum ClaimAction: String, CaseIterable, Sendable, Equatable { case replace, cancelOutstanding, submit, retractSubmission, reopen, void, restore, archive, unarchive }
    public enum ReceiptAction: String, CaseIterable, Sendable, Equatable { case replace, void, restore }
    public enum DirectClaimAction: String, CaseIterable, Sendable, Equatable { case submit, retractSubmission, reopen, void, restore, archive, unarchive }
    public enum DirectReceiptAction: String, CaseIterable, Sendable, Equatable { case void, restore }

    public private(set) var claims: [V15ReimbursementClaim] = []
    public private(set) var selectedClaim: V15ReimbursementClaim?
    public private(set) var receipts: [V15ReimbursementReceipt] = []
    public private(set) var nextClaimCursor: String?
    public private(set) var nextReceiptCursor: String?
    public private(set) var phase: Phase = .idle
    public private(set) var claimPagePhase: PagePhase = .idle
    public private(set) var receiptPagePhase: PagePhase = .idle

    public private(set) var newClaimSheetVisible = false
    public private(set) var newClaimPhase: EditorPhase = .idle
    public private(set) var candidatesPhase: Phase = .idle
    public private(set) var candidatePagePhase: PagePhase = .idle
    public private(set) var candidates: [V15ReimbursementCandidate] = []
    public private(set) var nextCandidateCursor: String?
    public private(set) var selectedCandidate: V15ReimbursementCandidate?
    public private(set) var newClaimIssues: [V15FieldIssue] = []
    public private(set) var newClaimServerIssues: [V15FieldIssue] = []
    public private(set) var newClaimResult: V15ReimbursementClaim?
    public var claimTitle = "" { didSet { newClaimInputChanged(fieldPath: "title") } }
    public var partyName = "" { didSet { newClaimInputChanged(fieldPath: "parties[0].name") } }
    public var allocationAmountText = "" { didSet { newClaimInputChanged(fieldPath: "parties[0].allocations[0].amount_minor") } }
    public var expectedDateText = "" { didSet { newClaimInputChanged(fieldPath: "parties[0].expected_date") } }
    public var candidateQuery = "" { didSet { candidateFilterChanged() } }
    public var candidateDateFrom = "" { didSet { candidateFilterChanged() } }
    public var candidateDateTo = "" { didSet { candidateFilterChanged() } }

    public private(set) var receiptSheetVisible = false
    public var receiptPhase: EditorPhase { selectedClaim.flatMap { receiptStates[$0.id]?.phase } ?? .idle }
    public var receiptAccountsPhase: Phase { selectedClaim.flatMap { receiptStates[$0.id]?.accountsPhase } ?? .idle }
    public var receiptAccounts: [V15ReceiptAccountOption] { selectedClaim.flatMap { receiptStates[$0.id]?.accounts } ?? [] }
    public var selectedReceiptAccount: V15ReceiptAccountOption? { selectedClaim.flatMap { receiptStates[$0.id]?.selectedAccount } }
    public var selectedPartyID: UUID? { selectedClaim.flatMap { receiptStates[$0.id]?.selectedPartyID } }
    public var receiptPreview: V15ReimbursementReceiptPreview? { selectedClaim.flatMap { receiptStates[$0.id]?.preview } }
    public var receiptIssues: [V15FieldIssue] { selectedClaim.flatMap { receiptStates[$0.id]?.issues } ?? [] }
    public var receiptServerIssues: [V15FieldIssue] { selectedClaim.flatMap { receiptStates[$0.id]?.serverIssues } ?? [] }
    public var receiptResult: V15ReimbursementReceipt? { selectedClaim.flatMap { receiptStates[$0.id]?.result } }
    public var receiptTitle = "" { didSet { receiptInputChanged() } }
    public var receiptAmountText = "" { didSet { receiptInputChanged() } }
    public var receiptDateText = "" { didSet { receiptInputChanged() } }

    public var claimReplacePreview: V15ReimbursementClaimPreview? { selectedClaim.flatMap { secondaryStates[$0.id]?.claimPreview } }
    public var cancellationPreview: V15ReimbursementCancelPreview? { selectedClaim.flatMap { secondaryStates[$0.id]?.cancelPreview } }
    public var replacementReceiptPreview: V15ReimbursementReceiptPreview? { selectedClaim.flatMap { secondaryStates[$0.id]?.receiptPreview } }
    public var secondaryMutationPhase: EditorPhase { selectedClaim.flatMap { secondaryStates[$0.id]?.phase } ?? .idle }
    public var directMutationPhase: EditorPhase { selectedClaim.flatMap { directStates[$0.id]?.phase } ?? .idle }
    public var directReadbackMessage: String? { selectedClaim.flatMap { directStates[$0.id]?.message } }
    public var factRefreshMessage: String? { selectedClaim.flatMap { factRefreshGates[$0.id]?.message } }
    public var hasPendingFactRefresh: Bool { selectedClaim.flatMap { factRefreshGates[$0.id] } != nil }
    public var isFactRefreshInFlight: Bool { selectedClaim.flatMap { factRefreshGates[$0.id]?.phase } == .refreshing }
    public var factRefreshRetryReasons: [V15DisabledReason] {
        guard let gate = selectedClaim.flatMap({ factRefreshGates[$0.id] }) else {
            return [.init(code: "receipt_fact_refresh_not_required", message: "当前没有需要更新的到账数据。", fieldPath: nil)]
        }
        if isOffline { return [.init(code: "offline_read_only", message: "离线时不能读取最新数据。", fieldPath: nil)] }
        if gate.phase == .refreshing { return [.init(code: "receipt_fact_refresh_loading", message: "最新报销单与到账列表正在读取，请稍候。", fieldPath: nil)] }
        return []
    }
    public var claimReplacementTitle: String {
        get { selectedClaim.flatMap { secondaryStates[$0.id]?.claimReplacementTitle } ?? "" }
        set { guard let owner = selectedClaim?.id else { return }; withSecondaryState(owner) { $0.claimReplacementTitle = newValue }; secondaryInputChanged(owner: owner) }
    }
    public var claimReplacementNote: String {
        get { selectedClaim.flatMap { secondaryStates[$0.id]?.claimReplacementNote } ?? "" }
        set { guard let owner = selectedClaim?.id else { return }; withSecondaryState(owner) { $0.claimReplacementNote = newValue }; secondaryInputChanged(owner: owner) }
    }
    public var selectedReplacementReceipt: V15ReimbursementReceipt? { selectedClaim.flatMap { owner in secondaryStates[owner.id]?.replacementReceiptID.flatMap { id in receipts.first { $0.id == id } } } }
    public var receiptReplacementTitle: String {
        get { selectedClaim.flatMap { secondaryStates[$0.id]?.receiptReplacementTitle } ?? "" }
        set { guard let owner = selectedClaim?.id else { return }; withSecondaryState(owner) { $0.receiptReplacementTitle = newValue }; secondaryInputChanged(owner: owner) }
    }
    public var receiptReplacementAmountText: String {
        get { selectedClaim.flatMap { secondaryStates[$0.id]?.receiptReplacementAmountText } ?? "" }
        set { guard let owner = selectedClaim?.id else { return }; withSecondaryState(owner) { $0.receiptReplacementAmountText = newValue }; secondaryInputChanged(owner: owner) }
    }
    public var receiptReplacementDateText: String {
        get { selectedClaim.flatMap { secondaryStates[$0.id]?.receiptReplacementDateText } ?? "" }
        set { guard let owner = selectedClaim?.id else { return }; withSecondaryState(owner) { $0.receiptReplacementDateText = newValue }; secondaryInputChanged(owner: owner) }
    }
    public var secondaryIssues: [V15FieldIssue] { selectedClaim.flatMap { secondaryStates[$0.id]?.issues } ?? [] }

    private let services: V15Services
    private let offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)?
    private let now: () -> Date
    private var listGeneration: UInt64 = 0
    private var claimPageGeneration: UInt64 = 0
    private var detailGeneration: UInt64 = 0
    private var receiptPageGeneration: UInt64 = 0
    private var candidateGeneration: UInt64 = 0
    private var candidatePageGeneration: UInt64 = 0
    private var accountGenerations: [UUID: UInt64] = [:]
    private var newClaimGeneration: UInt64 = 0
    private var receiptPreviewGenerations: [UUID: UInt64] = [:]
    private var secondaryGenerations: [UUID: UInt64] = [:]
    private var directReadbackGenerations: [UUID: UInt64] = [:]
    private var isApplyingNewClaim = false
    private var isApplyingReceipt = false
    private var newClaimTouchedFields = Set<String>()
    private var newClaimSubmissionAttempted = false
    private var newClaimSessionID = UUID()
    private var receiptSessionID = UUID()

    private struct CreateClaimAttempt: Sendable, Equatable { let operationID: UUID; let editorID: UUID; let request: V15ReimbursementClaimDraft; let candidate: V15ReimbursementCandidate; let identity: String; let key: UUID }
    private struct ReceiptAttempt: Sendable, Equatable { let operationID: UUID; let claimID: UUID; let request: V15ReimbursementReceiptCreateCommitRequest; let identity: String; let key: UUID }
    private enum SecondaryAttempt: Sendable, Equatable {
        case claimReplace(operationID: UUID, owner: UUID, request: V15ReimbursementClaimCommitRequest, key: UUID)
        case cancel(operationID: UUID, owner: UUID, request: V15ReimbursementCancelCommitRequest, key: UUID)
        case receiptReplace(operationID: UUID, owner: UUID, receiptID: UUID, request: V15ReimbursementReceiptReplaceCommitRequest, key: UUID)
    }
    private enum DirectIntent: Sendable, Equatable {
        case claim(DirectClaimAction, V15ReimbursementVersionRequest, V15ReimbursementClaim)
        case receipt(UUID, DirectReceiptAction, V15ReimbursementReceiptVersionRequest, V15ReimbursementClaim, V15ReimbursementReceipt)
    }
    private struct DirectAttempt: Sendable, Equatable { let operationID: UUID; let owner: UUID; let intent: DirectIntent }
    private struct ReceiptState {
        var phase: EditorPhase = .idle
        var accountsPhase: Phase = .idle
        var accounts: [V15ReceiptAccountOption] = []
        var selectedAccount: V15ReceiptAccountOption?
        var selectedPartyID: UUID?
        var preview: V15ReimbursementReceiptPreview?
        var preparedDraft: V15ReimbursementReceiptDraft?
        var issues: [V15FieldIssue] = []
        var serverIssues: [V15FieldIssue] = []
        var result: V15ReimbursementReceipt?
    }
    private struct SecondaryState {
        var phase: EditorPhase = .idle
        var claimPreview: V15ReimbursementClaimPreview?
        var cancelPreview: V15ReimbursementCancelPreview?
        var receiptPreview: V15ReimbursementReceiptPreview?
        var claimReplacementTitle = ""
        var claimReplacementNote = ""
        var replacementReceiptID: UUID?
        var receiptReplacementTitle = ""
        var receiptReplacementAmountText = ""
        var receiptReplacementDateText = ""
        var issues: [V15FieldIssue] = []
        var preparedClaimRequest: V15ReimbursementClaimPreviewRequest?
        var preparedReceiptRequest: V15ReimbursementReceiptReplacePreviewRequest?
    }
    private struct DirectState { var phase: EditorPhase = .idle; var message: String?; var didReadback = false }
    private enum FactRefreshSource: Sendable, Equatable { case createReceipt, replaceReceipt, directReceipt }
    private enum FactRefreshPhase: Sendable, Equatable { case refreshing, failed }
    private struct FactRefreshGate: Sendable, Equatable {
        let operationID: UUID
        let owner: UUID
        let source: FactRefreshSource
        var phase: FactRefreshPhase
        var message: String
    }
    private var createAttempt: CreateClaimAttempt?
    private var receiptAttempts: [UUID: ReceiptAttempt] = [:]
    private var secondaryAttempts: [UUID: SecondaryAttempt] = [:]
    private var directAttempts: [UUID: DirectAttempt] = [:]
    private var receiptStates: [UUID: ReceiptState] = [:]
    private var secondaryStates: [UUID: SecondaryState] = [:]
    private var directStates: [UUID: DirectState] = [:]
    private var factRefreshGates: [UUID: FactRefreshGate] = [:]

    public init(services: V15Services, offlineSnapshotAt: Date? = nil, offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)? = nil, now: @escaping () -> Date = { .now }) {
        self.services = services
        self.offlineSnapshotProvider = offlineSnapshotProvider ?? { offlineSnapshotAt ?? services.offlineSnapshotAt }
        self.now = now
    }

    public var offlineSnapshotAt: Date? { offlineSnapshotProvider?() }
    public var isOffline: Bool { offlineSnapshotAt != nil }
    public var canCreateClaim: Bool { createClaimDisabledReasons.isEmpty }
    public var visibleNewClaimIssues: [V15FieldIssue] {
        guard !newClaimSubmissionAttempted else { return newClaimIssues }
        return newClaimIssues.filter { issue in
            guard let fieldPath = issue.fieldPath else { return false }
            return newClaimTouchedFields.contains(fieldPath)
        }
    }
    public var canPreviewReceipt: Bool { receiptPreviewDisabledReasons.isEmpty }
    public var canCommitReceipt: Bool { receiptCommitDisabledReasons.isEmpty }
    public var hasRecoverableCreateAttempt: Bool { createAttempt?.editorID == newClaimSessionID }
    public var hasRecoverableReceiptAttempt: Bool { selectedClaim.flatMap { receiptAttempts[$0.id] } != nil }
    public var hasRecoverableSecondaryAttempt: Bool { selectedClaim.flatMap { secondaryAttempts[$0.id] } != nil }
    public var hasRecoverableDirectAttempt: Bool { selectedClaim.flatMap { directAttempts[$0.id] } != nil }
    public var canAbandonUnknownDirect: Bool {
        guard let owner = selectedClaim?.id, directAttempts[owner] != nil else { return false }
        return directStates[owner]?.phase == .unknown && directStates[owner]?.didReadback == true
    }
    public var createClaimDisabledReasons: [V15DisabledReason] {
        var reasons = newClaimIssues.map(reason)
        if isOffline { reasons.append(.init(code: "offline_read_only", message: "离线时只可查看，无法新建报销单。", fieldPath: nil)) }
        if createAttempt != nil { reasons.append(.init(code: "claim_attempt_in_flight", message: "上一笔新建操作仍在处理中，或结果暂时不明。请先安全检查保存结果。", fieldPath: nil)) }
        if candidatesPhase == .loading { reasons.append(.init(code: "candidates_loading", message: "垫付候选仍在读取，请稍候。", fieldPath: "parties[0].allocations[0].transaction_id")) }
        return uniqueReasons(reasons)
    }
    public var receiptPreviewDisabledReasons: [V15DisabledReason] {
        var reasons = receiptIssues.map(reason)
        if isOffline { reasons.append(.init(code: "offline_read_only", message: "离线时只可查看，无法登记到账。", fieldPath: nil)) }
        if receiptAccountsPhase == .loading { reasons.append(.init(code: "receipt_accounts_loading", message: "收款账户仍在读取，请稍候。", fieldPath: "destination_account_id")) }
        if let id = selectedClaim?.id, receiptAttempts[id] != nil { reasons.append(.init(code: "receipt_attempt_in_flight", message: "上一笔到账操作仍在处理中，或结果暂时不明。请先安全检查保存结果。", fieldPath: nil)) }
        if let id = selectedClaim?.id, factRefreshGates[id] != nil { reasons.append(factRefreshReason) }
        return uniqueReasons(reasons)
    }
    public var receiptCommitDisabledReasons: [V15DisabledReason] {
        var reasons = receiptPreviewDisabledReasons
        guard receiptPreview != nil else { reasons.append(.init(code: "preview_required", message: "请先查看到账预览。", fieldPath: nil)); return uniqueReasons(reasons) }
        guard let owner = selectedClaim?.id, let request = makeReceiptDraft(recordIssues: false), receiptStates[owner]?.preparedDraft == request else { reasons.append(.init(code: "preview_input_changed", message: "到账内容已变化，请重新预览。", fieldPath: nil)); return uniqueReasons(reasons) }
        return uniqueReasons(reasons)
    }

    public func isClaimActionApplicable(_ action: ClaimAction, to claim: V15ReimbursementClaim) -> Bool {
        guard claim.status.isKnown else { return false }
        switch action {
        case .replace: return claim.archivedAt == nil && claim.voidedAt == nil
        case .cancelOutstanding: return claim.archivedAt == nil && claim.voidedAt == nil && claim.submittedAt != nil && claim.cancelledAt == nil && claim.outstandingMinor > 0
        case .submit: return claim.archivedAt == nil && claim.voidedAt == nil && claim.submittedAt == nil && claim.cancelledAt == nil
        case .retractSubmission: return claim.archivedAt == nil && claim.voidedAt == nil && claim.submittedAt != nil && claim.receivedMinor == 0
        case .reopen: return claim.archivedAt == nil && claim.voidedAt == nil && claim.cancelledAt != nil
        case .void: return claim.submittedAt == nil && claim.voidedAt == nil && claim.receiptCount == 0
        case .restore: return claim.voidedAt != nil && claim.archivedAt == nil
        case .archive: return claim.archivedAt == nil && [.received, .cancelled, .partiallyReceivedCancelled].contains(claim.status)
        case .unarchive: return claim.archivedAt != nil
        }
    }

    public func claimActionReasons(for claim: V15ReimbursementClaim, action: ClaimAction) -> [V15DisabledReason] {
        var reasons: [V15DisabledReason] = []
        if isOffline { reasons.append(.init(code: "offline_read_only", message: "离线时只可查看，无法修改报销单。", fieldPath: nil)) }
        if !claim.status.isKnown { reasons.append(.init(code: "unknown_status", message: "未知报销状态只可查看。", fieldPath: "status")) }
        if receiptPagePhase == .loading { reasons.append(.init(code: "claim_facts_loading", message: "报销详情仍在读取，请稍候。", fieldPath: nil)) }
        if case .failed = receiptPagePhase { reasons.append(.init(code: "claim_reload_required", message: "报销详情读取失败，请先刷新。", fieldPath: nil)) }
        if factRefreshGates[claim.id] != nil { reasons.append(factRefreshReason) }
        if secondaryAttempts[claim.id] != nil { reasons.append(.init(code: "secondary_attempt_in_flight", message: "上一笔预览提交仍在恢复，不能开始新的取消。", fieldPath: nil)) }
        if directAttempts[claim.id] != nil { reasons.append(.init(code: "direct_attempt_unknown", message: "上一项操作结果暂时不明，请先检查最新状态。", fieldPath: nil)) }
        guard isClaimActionApplicable(action, to: claim) else {
            reasons.append(claimInapplicableReason(action, claim: claim))
            return uniqueReasons(reasons)
        }
        return uniqueReasons(reasons)
    }
    public func canPerformClaimAction(_ action: ClaimAction, on claim: V15ReimbursementClaim) -> Bool { claimActionReasons(for: claim, action: action).isEmpty }
    public func cancelReasons(for claim: V15ReimbursementClaim) -> [V15DisabledReason] { claimActionReasons(for: claim, action: .cancelOutstanding) }
    public var canPreviewCancel: Bool { selectedClaim.map { cancelReasons(for: $0).isEmpty } ?? false }
    public func receiptOpenReasons(for claim: V15ReimbursementClaim) -> [V15DisabledReason] {
        if receiptAttempts[claim.id] != nil { return [] }
        var reasons: [V15DisabledReason] = []
        if isOffline { reasons.append(.init(code: "offline_read_only", message: "离线时只可查看。", fieldPath: nil)) }
        if !claim.status.isKnown { reasons.append(.init(code: "unknown_status", message: "未知状态只可查看。", fieldPath: "status")) }
        if claim.outstandingMinor <= 0 { reasons.append(.init(code: "nothing_outstanding", message: "该报销单没有未到账金额。", fieldPath: "outstanding_minor")) }
        if claim.archivedAt != nil { reasons.append(.init(code: "claim_archived", message: "归档报销单只读，请先恢复。", fieldPath: "archived_at")) }
        if claim.voidedAt != nil { reasons.append(.init(code: "claim_voided", message: "已作废报销单只读，请先恢复。", fieldPath: "voided_at")) }
        if factRefreshGates[claim.id] != nil { reasons.append(factRefreshReason) }
        if secondaryAttempts[claim.id] != nil { reasons.append(.init(code: "secondary_attempt_in_flight", message: "另一笔预览提交仍在处理。", fieldPath: nil)) }
        if directAttempts[claim.id] != nil { reasons.append(.init(code: "direct_attempt_unknown", message: "上一项操作仍在处理中，或结果暂时不明。", fieldPath: nil)) }
        return uniqueReasons(reasons)
    }
    public func directClaimReasons(for claim: V15ReimbursementClaim, action: DirectClaimAction) -> [V15DisabledReason] {
        claimActionReasons(for: claim, action: claimAction(action))
    }
    public func typedClaimAction(for action: DirectClaimAction) -> ClaimAction { claimAction(action) }

    public func isReceiptActionApplicable(_ action: ReceiptAction, to receipt: V15ReimbursementReceipt, claim: V15ReimbursementClaim) -> Bool {
        guard receipt.claimID == claim.id, claim.status.isKnown else { return false }
        switch action {
        case .replace: return claim.archivedAt == nil && claim.voidedAt == nil && receipt.voidedAt == nil
        case .void: return claim.archivedAt == nil && receipt.voidedAt == nil
        case .restore: return claim.archivedAt == nil && claim.voidedAt == nil && claim.cancelledAt == nil && receipt.voidedAt != nil
        }
    }

    public func receiptActionReasons(for receipt: V15ReimbursementReceipt, claim: V15ReimbursementClaim, action: ReceiptAction) -> [V15DisabledReason] {
        var reasons: [V15DisabledReason] = []
        if isOffline { reasons.append(.init(code: "offline_read_only", message: "离线时只可查看，无法修改到账记录。", fieldPath: nil)) }
        if !claim.status.isKnown { reasons.append(.init(code: "unknown_status", message: "未知报销状态只可查看。", fieldPath: "status")) }
        if receiptPagePhase == .loading { reasons.append(.init(code: "claim_facts_loading", message: "正在读取报销与到账记录。", fieldPath: nil)) }
        if case .failed = receiptPagePhase { reasons.append(.init(code: "claim_reload_required", message: "报销与到账记录读取失败，请先刷新。", fieldPath: nil)) }
        if factRefreshGates[claim.id] != nil { reasons.append(factRefreshReason) }
        if secondaryAttempts[claim.id] != nil { reasons.append(.init(code: "secondary_attempt_in_flight", message: "预览提交仍在处理或结果未知。", fieldPath: nil)) }
        if directAttempts[claim.id] != nil { reasons.append(.init(code: "direct_attempt_unknown", message: "上一项操作仍在处理中，或结果暂时不明。", fieldPath: nil)) }
        if !isReceiptActionApplicable(action, to: receipt, claim: claim) { reasons.append(receiptInapplicableReason(action, receipt: receipt, claim: claim)) }
        return uniqueReasons(reasons)
    }
    public func canPerformReceiptAction(_ action: ReceiptAction, on receipt: V15ReimbursementReceipt, claim: V15ReimbursementClaim) -> Bool { receiptActionReasons(for: receipt, claim: claim, action: action).isEmpty }
    public func directReceiptReasons(for receipt: V15ReimbursementReceipt, claim: V15ReimbursementClaim, action: DirectReceiptAction) -> [V15DisabledReason] { receiptActionReasons(for: receipt, claim: claim, action: action == .void ? .void : .restore) }

    public func load() async {
        invalidateAllReads(); let generation = listGeneration
        phase = .loading; claims = []; selectedClaim = nil; receipts = []; nextClaimCursor = nil; nextReceiptCursor = nil
        do {
            let page = try await services.reimbursements.claims()
            guard generation == listGeneration else { return }
            claims = uniqueClaims(page.items); nextClaimCursor = page.nextCursor
            guard let first = claims.first else { phase = .empty; return }
            phase = .loaded; await selectClaim(first)
        } catch let failure as V15Failure { guard generation == listGeneration else { return }; phase = failure.kind == .cancelled ? .idle : .failed(failure) }
        catch { guard generation == listGeneration else { return }; phase = .failed(.init(kind: .transport, message: "报销单读取失败。")) }
    }

    /// Opens a server-addressed claim without depending on its presence in the
    /// first list page. Today decision cards use this path so an attention item
    /// cannot silently resolve to a different reimbursement claim.
    public func openClaim(_ claim: V15ReimbursementClaim, readCachePolicy: V15ReadCachePolicy = .standard) async {
        invalidateAllReads()
        phase = .loaded
        claims = [claim]
        selectedClaim = nil
        receipts = []
        nextClaimCursor = nil
        nextReceiptCursor = nil
        await selectClaim(claim, readCachePolicy: readCachePolicy)
    }

    public func openClaim(id: UUID, readCachePolicy: V15ReadCachePolicy = .standard) async {
        invalidateAllReads()
        let generation = listGeneration
        phase = .loading
        claims = []
        selectedClaim = nil
        receipts = []
        nextClaimCursor = nil
        nextReceiptCursor = nil
        do {
            let claim = try await services.reimbursements.claim(id: id, readCachePolicy: readCachePolicy)
            guard generation == listGeneration else { return }
            claims = [claim]
            phase = .loaded
            await selectClaim(claim, readCachePolicy: readCachePolicy)
        } catch let failure as V15Failure {
            guard generation == listGeneration else { return }
            phase = failure.kind == .cancelled ? .idle : .failed(failure)
        } catch {
            guard generation == listGeneration else { return }
            phase = .failed(.init(kind: .transport, message: "报销单读取失败。"))
        }
    }

    public func refresh() async {
        invalidateAllReads(); let generation = listGeneration; let previous = selectedClaim?.id
        phase = .loading
        do {
            let page = try await services.reimbursements.claims(readCachePolicy: .reloadIgnoringCache)
            guard generation == listGeneration else { return }
            claims = uniqueClaims(page.items); nextClaimCursor = page.nextCursor; phase = claims.isEmpty ? .empty : .loaded
            if let previous, let match = claims.first(where: { $0.id == previous }) { await selectClaim(match, readCachePolicy: .reloadIgnoringCache) }
            else if let first = claims.first { await selectClaim(first, readCachePolicy: .reloadIgnoringCache) }
        } catch let failure as V15Failure { guard generation == listGeneration else { return }; phase = failure.kind == .cancelled ? .idle : .failed(failure) }
        catch { guard generation == listGeneration else { return }; phase = .failed(.init(kind: .transport, message: "报销单刷新失败。")) }
    }

    public func loadNextClaims() async {
        guard let cursor = nextClaimCursor, claimPagePhase != .loading else { return }
        claimPageGeneration &+= 1; let ownership = claimPageGeneration; let listOwner = listGeneration; claimPagePhase = .loading
        do { let page = try await services.reimbursements.claims(cursor: cursor); guard ownership == claimPageGeneration, listOwner == listGeneration else { return }; claims = uniqueClaims(claims + page.items); nextClaimCursor = page.nextCursor; claimPagePhase = .idle }
        catch let failure as V15Failure { guard ownership == claimPageGeneration, listOwner == listGeneration else { return }; claimPagePhase = failure.kind == .cancelled ? .idle : .failed(failure) }
        catch { guard ownership == claimPageGeneration, listOwner == listGeneration else { return }; claimPagePhase = .failed(.init(kind: .transport, message: "下一页报销单读取失败。")) }
    }

    public func selectClaim(_ summary: V15ReimbursementClaim, readCachePolicy: V15ReadCachePolicy = .standard) async {
        detailGeneration &+= 1; receiptPageGeneration &+= 1; let generation = detailGeneration; let id = summary.id
        if readCachePolicy == .reloadIgnoringCache {
            invalidateSecondaryPreview(owner: id)
            if receiptAttempts[id] == nil { receiptPreviewGenerations[id, default: 0] &+= 1; withReceiptState(id) { $0.preview = nil; $0.preparedDraft = nil; $0.phase = .idle } }
        }
        selectedClaim = summary; receipts = []; nextReceiptCursor = nil; receiptPagePhase = .loading
        resetVisibleReceiptEditor()
        do {
            async let claimRequest = services.reimbursements.claim(id: id, readCachePolicy: readCachePolicy)
            async let receiptRequest = services.reimbursements.receipts(claimID: id, readCachePolicy: readCachePolicy)
            let (claim, page) = try await (claimRequest, receiptRequest)
            guard generation == detailGeneration, selectedClaim?.id == id else { return }
            selectedClaim = claim; replaceClaimInList(claim); receipts = uniqueReceipts(page.items); nextReceiptCursor = page.nextCursor; receiptPagePhase = .idle
        } catch let failure as V15Failure { guard generation == detailGeneration, selectedClaim?.id == id else { return }; receiptPagePhase = failure.kind == .cancelled ? .idle : .failed(failure) }
        catch { guard generation == detailGeneration, selectedClaim?.id == id else { return }; receiptPagePhase = .failed(.init(kind: .transport, message: "报销详情读取失败。")) }
    }

    public func loadNextReceipts() async {
        guard let claim = selectedClaim, let cursor = nextReceiptCursor, receiptPagePhase != .loading else { return }
        receiptPageGeneration &+= 1; let ownership = receiptPageGeneration; let detailOwner = detailGeneration; receiptPagePhase = .loading
        do { let page = try await services.reimbursements.receipts(claimID: claim.id, cursor: cursor); guard ownership == receiptPageGeneration, detailOwner == detailGeneration, selectedClaim?.id == claim.id else { return }; receipts = uniqueReceipts(receipts + page.items); nextReceiptCursor = page.nextCursor; receiptPagePhase = .idle }
        catch let failure as V15Failure { guard ownership == receiptPageGeneration, detailOwner == detailGeneration, selectedClaim?.id == claim.id else { return }; receiptPagePhase = failure.kind == .cancelled ? .idle : .failed(failure) }
        catch { guard ownership == receiptPageGeneration, detailOwner == detailGeneration, selectedClaim?.id == claim.id else { return }; receiptPagePhase = .failed(.init(kind: .transport, message: "下一页到账记录读取失败。")) }
    }

    public func openNewClaim(preselecting transactionID: UUID? = nil) async {
        guard !isOffline else { newClaimPhase = .failed(.init(kind: .offlineReadOnly, message: "离线时只可查看，无法新建报销单。")); return }
        if let attempt = createAttempt {
            newClaimSessionID = attempt.editorID; newClaimSheetVisible = true
            newClaimTouchedFields = []; newClaimSubmissionAttempted = false
            isApplyingNewClaim = true
            claimTitle = attempt.request.title
            partyName = attempt.request.parties.first?.name ?? ""
            expectedDateText = attempt.request.parties.first?.expectedDate ?? ""
            allocationAmountText = attempt.request.parties.first?.allocations.first.map { formatMinor($0.amountMinor) } ?? ""
            selectedCandidate = attempt.candidate
            isApplyingNewClaim = false
            validateNewClaim()
            return
        }
        newClaimSessionID = UUID(); newClaimSheetVisible = true; newClaimPhase = .loading; newClaimIssues = []; newClaimServerIssues = []; newClaimResult = nil
        newClaimTouchedFields = []; newClaimSubmissionAttempted = false
        isApplyingNewClaim = true; claimTitle = ""; partyName = ""; allocationAmountText = ""; expectedDateText = ""; selectedCandidate = nil; isApplyingNewClaim = false
        await loadCandidates(reset: true)
        if let transactionID { await selectInitialCandidate(transactionID: transactionID) }
        validateNewClaim()
    }

    public func dismissNewClaim() { newClaimSheetVisible = false; candidateGeneration &+= 1; candidatePageGeneration &+= 1; if createAttempt == nil { newClaimPhase = .idle; newClaimIssues = []; newClaimServerIssues = []; newClaimTouchedFields = []; newClaimSubmissionAttempted = false } }
    public func retryCandidates() async {
        if createAttempt == nil {
            newClaimServerIssues = []
            newClaimPhase = .loading
        }
        await loadCandidates(reset: true)
    }
    public func loadNextCandidates() async { await loadCandidates(reset: false) }
    public func chooseCandidate(_ candidate: V15ReimbursementCandidate) {
        guard candidate.eligibility.eligible else { newClaimServerIssues = candidate.eligibility.reasonDetails.map { .init(code: $0.code, message: $0.message, fieldPath: $0.fieldPath) }; validateNewClaim(); return }
        newClaimTouchedFields.insert("parties[0].allocations[0].transaction_id")
        selectedCandidate = candidate
        if allocationAmountText.isEmpty { allocationAmountText = formatMinor(candidate.availableMinor) } else { newClaimInputChanged(fieldPath: "parties[0].allocations[0].transaction_id") }
    }

    private func selectInitialCandidate(transactionID: UUID) async {
        let sessionID = newClaimSessionID
        let originalQuery = candidateQuery
        let originalDateFrom = candidateDateFrom
        let originalDateTo = candidateDateTo
        var visitedCursors = Set<String>()

        while newClaimSheetVisible,
              newClaimSessionID == sessionID,
              candidateQuery == originalQuery,
              candidateDateFrom == originalDateFrom,
              candidateDateTo == originalDateTo {
            if let candidate = candidates.first(where: { $0.transactionID == transactionID }) {
                if candidate.eligibility.eligible {
                    chooseCandidate(candidate)
                } else {
                    let issues = candidate.eligibility.reasonDetails.map {
                        V15FieldIssue(code: $0.code, message: $0.message, fieldPath: $0.fieldPath ?? "parties[0].allocations[0].transaction_id")
                    }
                    newClaimServerIssues = issues.isEmpty ? [
                        .init(code: "initial_reimbursement_candidate_ineligible", message: "这笔账目当前不符合报销条件。", fieldPath: "parties[0].allocations[0].transaction_id")
                    ] : issues
                    newClaimPhase = .failed(.init(kind: .decoding, code: "initial_reimbursement_candidate_ineligible", message: "这笔账目当前不符合报销条件，请查看原因。"))
                }
                return
            }

            if case .failed = candidatesPhase { return }
            if case .loading = candidatesPhase { return }
            if case .failed(let failure) = candidatePagePhase {
                newClaimPhase = .failed(.init(kind: failure.kind, code: "initial_reimbursement_candidate_page_failed", message: "查找指定账目时，下一页候选读取失败：\(failure.message)"))
                return
            }
            guard let cursor = nextCandidateCursor else {
                newClaimServerIssues = [
                    .init(code: "initial_reimbursement_candidate_not_found", message: "这笔账目当前不在可报销候选中；它可能已报销、已作废或不符合条件。", fieldPath: "parties[0].allocations[0].transaction_id")
                ]
                newClaimPhase = .failed(.init(kind: .decoding, code: "initial_reimbursement_candidate_not_found", message: "无法在服务器候选中找到这笔账目，没有替换为其他候选。"))
                return
            }
            guard visitedCursors.insert(cursor).inserted else {
                newClaimPhase = .failed(.init(kind: .decoding, code: "reimbursement_candidate_cursor_loop", message: "候选分页没有继续前进，已停止查找以避免选错账目。"))
                return
            }
            await loadCandidates(reset: false)
        }
    }

    public func createClaim() async {
        newClaimSubmissionAttempted = true
        validateNewClaim(); guard createClaimDisabledReasons.isEmpty, let request = makeNewClaimDraft(recordIssues: true), let candidate = selectedCandidate else { return }
        let identity = claimIdentity(request); let attempt = CreateClaimAttempt(operationID: UUID(), editorID: newClaimSessionID, request: request, candidate: candidate, identity: identity, key: UUID())
        createAttempt = attempt; newClaimGeneration &+= 1; newClaimPhase = .committing
        await performCreateClaim(attempt)
    }
    public func retryUnknownCreateClaim() async { guard let attempt = createAttempt, attempt.editorID == newClaimSessionID, !isOffline else { return }; newClaimGeneration &+= 1; newClaimPhase = .committing; await performCreateClaim(attempt) }
    public func abandonUnknownCreateClaim() { guard let attempt = createAttempt, attempt.editorID == newClaimSessionID, newClaimPhase == .unknown else { return }; createAttempt = nil; newClaimPhase = .ready; validateNewClaim() }

    public func openReceipt() async {
        guard let claim = selectedClaim else { return }
        receiptSessionID = UUID(); receiptSheetVisible = true
        if let attempt = receiptAttempts[claim.id] {
            withReceiptState(claim.id) { state in
                state.selectedPartyID = attempt.request.partyID
                state.selectedAccount = state.accounts.first { $0.id == attempt.request.destinationAccountID }
                state.preview = nil; state.preparedDraft = nil
            }
            isApplyingReceipt = true
            receiptTitle = attempt.request.title; receiptAmountText = formatMinor(attempt.request.amountMinor); receiptDateText = ShanghaiBusinessDate.string(for: attempt.request.receivedAt)
            isApplyingReceipt = false
            validateReceipt()
            return
        }
        guard claim.status.isKnown else { withReceiptState(claim.id) { $0.phase = .failed(.init(kind: .decoding, code: "unknown_claim_status", message: "暂时无法识别此状态，只能查看。")) }; receiptSheetVisible = false; return }
        withReceiptState(claim.id) { state in state = ReceiptState(); state.phase = .loading; state.selectedPartyID = claim.parties.first(where: { $0.outstandingMinor > 0 })?.id }
        isApplyingReceipt = true; receiptTitle = "报销到账"; receiptAmountText = ""; receiptDateText = ShanghaiBusinessDate.string(for: now()); isApplyingReceipt = false
        if let party = claim.parties.first(where: { $0.id == selectedPartyID }) { receiptAmountText = formatMinor(party.outstandingMinor) }
        await loadReceiptAccounts()
        validateReceipt()
    }
    public func dismissReceipt() {
        receiptSheetVisible = false
        guard let owner = selectedClaim?.id else { return }
        accountGenerations[owner, default: 0] &+= 1; receiptPreviewGenerations[owner, default: 0] &+= 1
        withReceiptState(owner) { state in state.preparedDraft = nil; state.preview = nil; if receiptAttempts[owner] == nil { state.phase = .idle } }
    }
    public func retryReceiptAccounts() async { await loadReceiptAccounts() }
    public func chooseReceiptAccount(_ account: V15ReceiptAccountOption) { guard let owner = selectedClaim?.id else { return }; withReceiptState(owner) { $0.selectedAccount = account }; receiptInputChanged() }
    public func chooseParty(_ id: UUID) { guard let owner = selectedClaim?.id else { return }; withReceiptState(owner) { $0.selectedPartyID = id }; receiptInputChanged() }

    public func previewReceipt() async {
        validateReceipt(); guard receiptPreviewDisabledReasons.isEmpty, let claim = selectedClaim, let request = makeReceiptDraft(recordIssues: true) else { return }
        let owner = claim.id; receiptPreviewGenerations[owner, default: 0] &+= 1; let generation = receiptPreviewGenerations[owner]!
        withReceiptState(owner) { $0.phase = .previewing; $0.serverIssues = [] }
        do { let value = try await services.reimbursements.previewReceipt(claimID: owner, request: request); guard generation == receiptPreviewGenerations[owner], selectedClaim?.id == owner, receiptIdentity(request) == currentReceiptIdentity() else { return }; withReceiptState(owner) { $0.preparedDraft = request; $0.preview = value; $0.phase = .previewed } }
        catch let failure as V15Failure { guard generation == receiptPreviewGenerations[owner], selectedClaim?.id == owner else { return }; withReceiptState(owner) { $0.serverIssues = failure.fieldIssues; $0.phase = failure.kind == .conflict && failure.conflict != nil ? .conflict(failure.conflict!) : .failed(failure) } }
        catch { guard generation == receiptPreviewGenerations[owner], selectedClaim?.id == owner else { return }; withReceiptState(owner) { $0.phase = .failed(.init(kind: .transport, message: "到账预览失败。")) } }
    }

    public func commitReceipt() async {
        validateReceipt(); guard receiptCommitDisabledReasons.isEmpty, let claim = selectedClaim, let draft = makeReceiptDraft(recordIssues: true), let preview = receiptPreview else { return }
        let request = V15ReimbursementReceiptCreateCommitRequest(expectedClaimVersion: draft.expectedClaimVersion, partyID: draft.partyID, amountMinor: draft.amountMinor, receivedAt: draft.receivedAt, destinationAccountID: draft.destinationAccountID, title: draft.title, note: draft.note, previewToken: preview.previewToken)
        let attempt = ReceiptAttempt(operationID: UUID(), claimID: claim.id, request: request, identity: receiptCommitIdentity(request), key: UUID())
        receiptAttempts[claim.id] = attempt; withReceiptState(claim.id) { $0.phase = .committing }
        await performReceipt(attempt)
    }
    public func retryUnknownReceipt() async { guard let claim = selectedClaim, let attempt = receiptAttempts[claim.id], receiptStates[claim.id]?.phase == .unknown, !isOffline else { return }; withReceiptState(claim.id) { $0.phase = .committing }; await performReceipt(attempt) }
    public func abandonUnknownReceipt() { guard let id = selectedClaim?.id, receiptAttempts[id] != nil, receiptStates[id]?.phase == .unknown else { return }; receiptAttempts[id] = nil; withReceiptState(id) { $0.phase = .ready }; validateReceipt() }

    // The three less frequent preview classes use typed current facts. They
    // share the same owner/key/unknown rules as receipt creation, without
    // exposing a generic raw-path escape hatch to Feature code.
    public func openClaimReplacement() {
        guard let claim = selectedClaim else { return }
        let phase: EditorPhase = claimActionReasons(for: claim, action: .replace).isEmpty ? .ready : .idle
        withSecondaryState(claim.id) { state in
            state.claimReplacementTitle = claim.title
            state.claimReplacementNote = claim.note ?? ""
            state.issues = []
            state.preparedClaimRequest = nil
            state.claimPreview = nil; state.cancelPreview = nil; state.receiptPreview = nil
            state.phase = phase
        }
    }
    public func openReceiptReplacement(_ receipt: V15ReimbursementReceipt) {
        guard let claim = selectedClaim, receipt.claimID == claim.id else { return }
        let phase: EditorPhase = receiptActionReasons(for: receipt, claim: claim, action: .replace).isEmpty ? .ready : .idle
        withSecondaryState(claim.id) { state in
            state.replacementReceiptID = receipt.id
            state.receiptReplacementTitle = receipt.title
            state.receiptReplacementAmountText = formatMinor(receipt.amountMinor)
            state.receiptReplacementDateText = ShanghaiBusinessDate.string(for: receipt.receivedAt)
            state.issues = []
            state.preparedReceiptRequest = nil
            state.claimPreview = nil; state.cancelPreview = nil; state.receiptPreview = nil
            state.phase = phase
        }
    }
    public func claimReplacementPreviewReasons(for claim: V15ReimbursementClaim) -> [V15DisabledReason] {
        var reasons = claimActionReasons(for: claim, action: .replace)
        let title = (secondaryStates[claim.id]?.claimReplacementTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { reasons.append(.init(code: "title_required", message: "请填写报销标题。", fieldPath: "title")) }
        if title.count > 120 { reasons.append(.init(code: "title_too_long", message: "报销标题最多 120 个字符。", fieldPath: "title")) }
        return uniqueReasons(reasons)
    }
    public func claimReplacementCommitReasons(for claim: V15ReimbursementClaim) -> [V15DisabledReason] {
        var reasons = claimActionReasons(for: claim, action: .replace)
        guard let preview = secondaryStates[claim.id]?.claimPreview else {
            reasons.append(.init(code: "preview_required", message: "请先预览报销单修改。", fieldPath: nil)); return uniqueReasons(reasons)
        }
        if preview.claimVersion != claim.version { reasons.append(.init(code: "claim_version_changed", message: "报销单已经更新，请重新预览。", fieldPath: "expected_version")) }
        if secondaryStates[claim.id]?.preparedClaimRequest == nil { reasons.append(.init(code: "preview_input_changed", message: "报销内容已变化，请重新预览。", fieldPath: nil)) }
        return uniqueReasons(reasons)
    }
    public func cancellationCommitReasons(for claim: V15ReimbursementClaim) -> [V15DisabledReason] {
        var reasons = cancelReasons(for: claim)
        guard let preview = secondaryStates[claim.id]?.cancelPreview else {
            reasons.append(.init(code: "preview_required", message: "请先预览取消未到账。", fieldPath: nil)); return uniqueReasons(reasons)
        }
        if preview.claimVersion != claim.version { reasons.append(.init(code: "claim_version_changed", message: "报销单已经更新，请重新预览。", fieldPath: "expected_version")) }
        return uniqueReasons(reasons)
    }
    public func receiptReplacementPreviewReasons(for receipt: V15ReimbursementReceipt, claim: V15ReimbursementClaim) -> [V15DisabledReason] {
        var reasons = receiptActionReasons(for: receipt, claim: claim, action: .replace)
        guard secondaryStates[claim.id]?.replacementReceiptID == receipt.id else {
            reasons.append(.init(code: "receipt_selection_required", message: "请先选择要修改的到账记录。", fieldPath: "receipt_id")); return uniqueReasons(reasons)
        }
        let title = (secondaryStates[claim.id]?.receiptReplacementTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { reasons.append(.init(code: "title_required", message: "请填写到账标题。", fieldPath: "title")) }
        if title.count > 120 { reasons.append(.init(code: "title_too_long", message: "到账标题最多 120 个字符。", fieldPath: "title")) }
        if let amount = CNYAmountParser.minorUnits(secondaryStates[claim.id]?.receiptReplacementAmountText ?? ""), amount > 0 {
            if claim.cancelledAt != nil && amount > receipt.amountMinor { reasons.append(.init(code: "cancelled_claim_increase", message: "已取消报销单只允许减少原到账金额。", fieldPath: "amount_minor")) }
        } else {
            reasons.append(.init(code: "amount_invalid", message: "到账金额须为正数，且最多两位小数。", fieldPath: "amount_minor"))
        }
        if let date = shanghaiStartOfDay(secondaryStates[claim.id]?.receiptReplacementDateText ?? "") {
            if date > now() { reasons.append(.init(code: "future_receipt", message: "到账日期不能晚于现在。", fieldPath: "received_at")) }
        } else {
            reasons.append(.init(code: "date_invalid", message: "到账日期必须为 YYYY-MM-DD。", fieldPath: "received_at"))
        }
        return uniqueReasons(reasons)
    }
    public func receiptReplacementCommitReasons(for receipt: V15ReimbursementReceipt, claim: V15ReimbursementClaim) -> [V15DisabledReason] {
        var reasons = receiptActionReasons(for: receipt, claim: claim, action: .replace)
        guard let preview = secondaryStates[claim.id]?.receiptPreview else {
            reasons.append(.init(code: "preview_required", message: "请先预览到账记录修改。", fieldPath: nil)); return uniqueReasons(reasons)
        }
        if preview.claimVersion != claim.version { reasons.append(.init(code: "claim_version_changed", message: "报销单已经更新，请重新预览。", fieldPath: "expected_claim_version")) }
        if preview.receiptVersion != receipt.version { reasons.append(.init(code: "receipt_version_changed", message: "到账记录已经更新，请重新预览。", fieldPath: "expected_receipt_version")) }
        if secondaryStates[claim.id]?.preparedReceiptRequest == nil { reasons.append(.init(code: "preview_input_changed", message: "到账内容已变化，请重新预览。", fieldPath: nil)) }
        return uniqueReasons(reasons)
    }
    public func previewCurrentClaimReplacement() async {
        guard let claim = selectedClaim else { return }
        if secondaryStates[claim.id]?.claimReplacementTitle.isEmpty != false { openClaimReplacement() }
        guard claimReplacementPreviewReasons(for: claim).isEmpty else { syncSecondaryIssues(claimReplacementPreviewReasons(for: claim)); return }
        let request = V15ReimbursementClaimPreviewRequest(title: claimReplacementTitle.trimmingCharacters(in: .whitespacesAndNewlines), note: claimReplacementNote.nilIfEmpty, parties: claim.parties.map(partyDraft), expectedVersion: claim.version)
        secondaryGenerations[claim.id, default: 0] &+= 1; let generation = secondaryGenerations[claim.id]!
        withSecondaryState(claim.id) { $0.phase = .previewing; $0.claimPreview = nil; $0.cancelPreview = nil; $0.receiptPreview = nil; $0.preparedClaimRequest = request; $0.issues = [] }
        do { let value = try await services.reimbursements.previewClaim(claimID: claim.id, request: request); guard generation == secondaryGenerations[claim.id], secondaryStates[claim.id]?.preparedClaimRequest == request else { return }; withSecondaryState(claim.id) { $0.claimPreview = value; $0.phase = .previewed } }
        catch let failure as V15Failure { guard generation == secondaryGenerations[claim.id] else { return }; withSecondaryState(claim.id) { $0.phase = failure.kind == .conflict && failure.conflict != nil ? .conflict(failure.conflict!) : .failed(failure) } }
        catch { guard generation == secondaryGenerations[claim.id] else { return }; withSecondaryState(claim.id) { $0.phase = .failed(.init(kind: .transport, message: "报销单变更预览失败。")) } }
    }
    public func commitCurrentClaimReplacement() async {
        guard let claim = selectedClaim, let preview = claimReplacePreview, preview.claimVersion == claim.version, !isOffline, secondaryStates[claim.id]?.preparedClaimRequest != nil else { return }
        let request = V15ReimbursementClaimCommitRequest(title: preview.proposed.title, note: preview.proposed.note, parties: preview.proposed.parties.map(partyDraft), expectedVersion: preview.claimVersion, previewToken: preview.previewToken)
        guard claimReplacementCommitReasons(for: claim).isEmpty else { return }
        let attempt = SecondaryAttempt.claimReplace(operationID: UUID(), owner: claim.id, request: request, key: UUID()); secondaryAttempts[claim.id] = attempt; withSecondaryState(claim.id) { $0.phase = .committing }; await performSecondary(attempt)
    }
    public func previewCancellation() async {
        guard let claim = selectedClaim, cancelReasons(for: claim).isEmpty else { return }
        secondaryGenerations[claim.id, default: 0] &+= 1; let generation = secondaryGenerations[claim.id]!
        withSecondaryState(claim.id) { $0.phase = .previewing; $0.claimPreview = nil; $0.cancelPreview = nil; $0.receiptPreview = nil }
        do { let value = try await services.reimbursements.previewCancellation(claimID: claim.id, request: .init(expectedVersion: claim.version)); guard generation == secondaryGenerations[claim.id] else { return }; withSecondaryState(claim.id) { $0.cancelPreview = value; $0.phase = .previewed } }
        catch let failure as V15Failure { guard generation == secondaryGenerations[claim.id] else { return }; withSecondaryState(claim.id) { $0.phase = failure.kind == .conflict && failure.conflict != nil ? .conflict(failure.conflict!) : .failed(failure) } }
        catch { guard generation == secondaryGenerations[claim.id] else { return }; withSecondaryState(claim.id) { $0.phase = .failed(.init(kind: .transport, message: "取消未到账金额预览失败。")) } }
    }
    public func commitCancellation() async {
        guard let claim = selectedClaim, let preview = cancellationPreview, preview.claimVersion == claim.version, !isOffline else { return }
        guard cancellationCommitReasons(for: claim).isEmpty else { return }
        let attempt = SecondaryAttempt.cancel(operationID: UUID(), owner: claim.id, request: .init(expectedVersion: preview.claimVersion, previewToken: preview.previewToken), key: UUID()); secondaryAttempts[claim.id] = attempt; withSecondaryState(claim.id) { $0.phase = .committing }; await performSecondary(attempt)
    }
    public func previewReceiptReplacement(_ receipt: V15ReimbursementReceipt) async {
        guard let claim = selectedClaim else { return }
        if secondaryStates[claim.id]?.replacementReceiptID != receipt.id { openReceiptReplacement(receipt) }
        let reasons = receiptReplacementPreviewReasons(for: receipt, claim: claim)
        guard reasons.isEmpty, let amount = CNYAmountParser.minorUnits(receiptReplacementAmountText), let receivedAt = shanghaiStartOfDay(receiptReplacementDateText) else { syncSecondaryIssues(reasons); return }
        let request = V15ReimbursementReceiptReplacePreviewRequest(expectedClaimVersion: claim.version, partyID: receipt.partyID, amountMinor: amount, receivedAt: receivedAt, destinationAccountID: receipt.destinationAccountID, title: receiptReplacementTitle.trimmingCharacters(in: .whitespacesAndNewlines), note: receipt.note, expectedReceiptVersion: receipt.version)
        secondaryGenerations[claim.id, default: 0] &+= 1; let generation = secondaryGenerations[claim.id]!
        withSecondaryState(claim.id) { $0.phase = .previewing; $0.claimPreview = nil; $0.cancelPreview = nil; $0.receiptPreview = nil; $0.preparedReceiptRequest = request; $0.issues = [] }
        do { let value = try await services.reimbursements.previewReceiptReplacement(receiptID: receipt.id, request: request); guard generation == secondaryGenerations[claim.id], secondaryStates[claim.id]?.preparedReceiptRequest == request else { return }; withSecondaryState(claim.id) { $0.receiptPreview = value; $0.phase = .previewed } }
        catch let failure as V15Failure { guard generation == secondaryGenerations[claim.id] else { return }; withSecondaryState(claim.id) { $0.phase = failure.kind == .conflict && failure.conflict != nil ? .conflict(failure.conflict!) : .failed(failure) } }
        catch { guard generation == secondaryGenerations[claim.id] else { return }; withSecondaryState(claim.id) { $0.phase = .failed(.init(kind: .transport, message: "到账记录变更预览失败。")) } }
    }
    public func commitReceiptReplacement(_ receipt: V15ReimbursementReceipt) async {
        guard let claim = selectedClaim, let preview = replacementReceiptPreview, preview.claimVersion == claim.version, preview.receiptVersion == receipt.version, !isOffline, let prepared = secondaryStates[claim.id]?.preparedReceiptRequest else { return }
        let request = V15ReimbursementReceiptReplaceCommitRequest(expectedClaimVersion: prepared.expectedClaimVersion, partyID: prepared.partyID, amountMinor: prepared.amountMinor, receivedAt: prepared.receivedAt, destinationAccountID: prepared.destinationAccountID, title: prepared.title, note: prepared.note, expectedReceiptVersion: prepared.expectedReceiptVersion, previewToken: preview.previewToken)
        guard receiptReplacementCommitReasons(for: receipt, claim: claim).isEmpty else { return }
        let attempt = SecondaryAttempt.receiptReplace(operationID: UUID(), owner: claim.id, receiptID: receipt.id, request: request, key: UUID()); secondaryAttempts[claim.id] = attempt; withSecondaryState(claim.id) { $0.phase = .committing }; await performSecondary(attempt)
    }
    public func retryUnknownSecondary() async { guard let id = selectedClaim?.id, let attempt = secondaryAttempts[id], secondaryStates[id]?.phase == .unknown, !isOffline else { return }; withSecondaryState(id) { $0.phase = .committing }; await performSecondary(attempt) }
    public func abandonUnknownSecondary() { guard let id = selectedClaim?.id, secondaryAttempts[id] != nil, secondaryStates[id]?.phase == .unknown else { return }; secondaryAttempts[id] = nil; withSecondaryState(id) { $0.phase = .idle }; invalidateSecondaryPreview(owner: id) }

    public func performDirectClaim(_ action: DirectClaimAction) async {
        guard let claim = selectedClaim, directClaimReasons(for: claim, action: action).isEmpty else { return }
        let request = V15ReimbursementVersionRequest(expectedVersion: claim.version)
        let attempt = DirectAttempt(operationID: UUID(), owner: claim.id, intent: .claim(action, request, claim)); directAttempts[claim.id] = attempt
        withDirectState(claim.id) { $0 = DirectState(phase: .committing, message: nil, didReadback: false) }
        do { let result = try await sendDirectClaim(attempt); guard ownsDirect(attempt, owner: claim.id) else { return }; directAttempts[claim.id] = nil; applyClaimSuccess(result); withDirectState(claim.id) { $0.phase = .succeeded } }
        catch let failure as V15Failure { guard ownsDirect(attempt, owner: claim.id) else { return }; if failure.kind == .responseUnknown || failure.kind == .cancelled || failure.kind == .offlineReadOnly { withDirectState(claim.id) { $0.phase = .unknown } } else { directAttempts[claim.id] = nil; withDirectState(claim.id) { $0.phase = failure.kind == .conflict && failure.conflict != nil ? .conflict(failure.conflict!) : .failed(failure) } } }
        catch { guard ownsDirect(attempt, owner: claim.id) else { return }; withDirectState(claim.id) { $0.phase = .unknown } }
    }
    public func performDirectReceipt(_ receipt: V15ReimbursementReceipt, action: DirectReceiptAction) async {
        guard let claim = selectedClaim, directReceiptReasons(for: receipt, claim: claim, action: action).isEmpty else { return }
        let request = V15ReimbursementReceiptVersionRequest(expectedClaimVersion: claim.version, expectedReceiptVersion: receipt.version)
        let attempt = DirectAttempt(operationID: UUID(), owner: claim.id, intent: .receipt(receipt.id, action, request, claim, receipt)); directAttempts[claim.id] = attempt
        withDirectState(claim.id) { $0 = DirectState(phase: .committing, message: nil, didReadback: false) }
        do {
            let result = try await sendDirectReceipt(attempt)
            guard ownsDirect(attempt, owner: claim.id) else { return }
            let refreshGate = beginFactRefresh(owner: claim.id, source: .directReceipt)
            directAttempts[claim.id] = nil; replaceReceipt(result, owner: claim.id)
            withDirectState(claim.id) { $0.phase = .loading; $0.message = "到账已经保存，正在读取最新报销数据。" }
            await convergeFacts(refreshGate)
        }
        catch let failure as V15Failure { guard ownsDirect(attempt, owner: claim.id) else { return }; if failure.kind == .responseUnknown || failure.kind == .cancelled || failure.kind == .offlineReadOnly { withDirectState(claim.id) { $0.phase = .unknown } } else { directAttempts[claim.id] = nil; withDirectState(claim.id) { $0.phase = failure.kind == .conflict && failure.conflict != nil ? .conflict(failure.conflict!) : .failed(failure) } } }
        catch { guard ownsDirect(attempt, owner: claim.id) else { return }; withDirectState(claim.id) { $0.phase = .unknown } }
    }
    public func readBackUnknownDirect() async {
        guard let owner = selectedClaim?.id, let attempt = directAttempts[owner] else { return }
        guard directStates[owner]?.phase == .unknown else { return }
        directReadbackGenerations[owner, default: 0] &+= 1; let generation = directReadbackGenerations[owner]!
        withDirectState(owner) { $0.phase = .loading }
        do {
            let message: String
            var freshClaimResult: V15ReimbursementClaim?
            var freshReceiptResult: V15ReimbursementReceipt?
            switch attempt.intent {
            case .claim(let action, let request, let before):
                let fresh = try await services.reimbursements.claim(id: owner, readCachePolicy: .reloadIgnoringCache)
                message = directClaimReadbackMessage(before: before, fresh: fresh, action: action, expectedVersion: request.expectedVersion)
                freshClaimResult = fresh
            case .receipt(let receiptID, let action, let request, let beforeClaim, let beforeReceipt):
                async let claimRequest = services.reimbursements.claim(id: owner, readCachePolicy: .reloadIgnoringCache)
                async let receiptRequest = services.reimbursements.receipt(id: receiptID, readCachePolicy: .reloadIgnoringCache)
                let (freshClaim, freshReceipt) = try await (claimRequest, receiptRequest)
                message = directReceiptReadbackMessage(beforeClaim: beforeClaim, beforeReceipt: beforeReceipt, freshClaim: freshClaim, freshReceipt: freshReceipt, action: action, request: request)
                freshClaimResult = freshClaim; freshReceiptResult = freshReceipt
            }
            guard generation == directReadbackGenerations[owner], ownsDirect(attempt, owner: owner) else { return }
            if let freshClaimResult { applyClaimSuccess(freshClaimResult) }
            if let freshReceiptResult { replaceReceipt(freshReceiptResult, owner: owner) }
            withDirectState(owner) { $0.phase = .unknown; $0.message = message; $0.didReadback = true }
        } catch let failure as V15Failure { guard generation == directReadbackGenerations[owner], ownsDirect(attempt, owner: owner) else { return }; withDirectState(owner) { $0.phase = .unknown; $0.message = "检查最新状态失败：\(failure.message)。请重试读取，系统不会重复操作。"; $0.didReadback = false } }
        catch { guard generation == directReadbackGenerations[owner], ownsDirect(attempt, owner: owner) else { return }; withDirectState(owner) { $0.phase = .unknown; $0.message = "检查最新状态失败。请重试读取，系统不会重复操作。"; $0.didReadback = false } }
    }
    public func abandonUnknownDirect() {
        guard let owner = selectedClaim?.id, canAbandonUnknownDirect else { return }
        directAttempts[owner] = nil
        withDirectState(owner) { $0.phase = .idle; $0.message = "已结束本次结果恢复；不会把未确认的操作记为成功。"; $0.didReadback = false }
    }

    public func retryFactRefresh() async {
        guard let owner = selectedClaim?.id, let gate = factRefreshGates[owner], gate.phase == .failed, !isOffline else { return }
        factRefreshGates[owner]?.phase = .refreshing
        await convergeFacts(gate)
    }

    private func loadCandidates(reset: Bool) async {
        if let attempt = createAttempt, attempt.editorID == newClaimSessionID { return }
        let query = candidateQuery.trimmingCharacters(in: .whitespacesAndNewlines); let from = candidateDateFrom.nilIfEmpty; let to = candidateDateTo.nilIfEmpty
        guard strictDateOrEmpty(from), strictDateOrEmpty(to) else { candidatesPhase = .failed(.init(kind: .decoding, code: "invalid_business_date", message: "候选日期必须为 YYYY-MM-DD。")); return }
        guard reset || (nextCandidateCursor != nil && candidatePagePhase != .loading) else { return }
        candidateGeneration &+= 1; let generation = candidateGeneration; candidatePageGeneration &+= 1; let pageOwner = candidatePageGeneration; let cursor = reset ? nil : nextCandidateCursor
        if reset { candidatesPhase = .loading; candidates = []; nextCandidateCursor = nil } else { candidatePagePhase = .loading }
        do { let page = try await services.reimbursements.candidates(query: query.isEmpty ? nil : query, dateFrom: from, dateTo: to, cursor: cursor); guard generation == candidateGeneration, pageOwner == candidatePageGeneration else { return }; candidates = uniqueCandidates(reset ? page.items : candidates + page.items); nextCandidateCursor = page.nextCursor; candidatesPhase = candidates.isEmpty ? .empty : .loaded; candidatePagePhase = .idle; if newClaimPhase == .loading { newClaimPhase = .ready } }
        catch let failure as V15Failure { guard generation == candidateGeneration, pageOwner == candidatePageGeneration else { return }; if reset { candidatesPhase = failure.kind == .cancelled ? .idle : .failed(failure) } else { candidatePagePhase = failure.kind == .cancelled ? .idle : .failed(failure) }; newClaimPhase = .ready }
        catch { guard generation == candidateGeneration, pageOwner == candidatePageGeneration else { return }; let failure = V15Failure(kind: .transport, message: "垫付候选读取失败。"); if reset { candidatesPhase = .failed(failure) } else { candidatePagePhase = .failed(failure) }; newClaimPhase = .ready }
    }

    private func loadReceiptAccounts() async {
        guard let owner = selectedClaim?.id else { return }
        if receiptAttempts[owner] != nil { return }
        accountGenerations[owner, default: 0] &+= 1; let generation = accountGenerations[owner]!
        withReceiptState(owner) { $0.accountsPhase = .loading; $0.accounts = []; $0.selectedAccount = nil }
        do { let value = try await services.reimbursements.receiptAccountOptions(); guard generation == accountGenerations[owner], selectedClaim?.id == owner, receiptAttempts[owner] == nil else { return }; let accounts = value.items.filter { $0.kind == "cash" || $0.kind == "debit" }; withReceiptState(owner) { $0.accounts = accounts; $0.accountsPhase = accounts.isEmpty ? .empty : .loaded; if accounts.count == 1 { $0.selectedAccount = accounts[0] }; $0.phase = .ready }; validateReceipt() }
        catch let failure as V15Failure { guard generation == accountGenerations[owner], selectedClaim?.id == owner, receiptAttempts[owner] == nil else { return }; withReceiptState(owner) { $0.accountsPhase = failure.kind == .cancelled ? .idle : .failed(failure); $0.phase = .ready }; validateReceipt() }
        catch { guard generation == accountGenerations[owner], selectedClaim?.id == owner, receiptAttempts[owner] == nil else { return }; withReceiptState(owner) { $0.accountsPhase = .failed(.init(kind: .transport, message: "收款账户读取失败。")); $0.phase = .ready }; validateReceipt() }
    }

    private func performCreateClaim(_ attempt: CreateClaimAttempt) async {
        do { let result = try await services.reimbursements.createClaim(attempt.request, idempotencyKey: attempt.key); guard createAttempt?.operationID == attempt.operationID else { return }; createAttempt = nil; newClaimResult = result; newClaimPhase = .succeeded; claims = uniqueClaims([result] + claims) }
        catch let failure as V15Failure { guard createAttempt?.operationID == attempt.operationID else { return }; newClaimServerIssues = failure.fieldIssues; if failure.kind == .responseUnknown || failure.kind == .cancelled || failure.kind == .offlineReadOnly { newClaimPhase = .unknown } else { createAttempt = nil; newClaimPhase = failure.kind == .conflict && failure.conflict != nil ? .conflict(failure.conflict!) : .failed(failure) } }
        catch { guard createAttempt?.operationID == attempt.operationID else { return }; newClaimPhase = .unknown }
    }
    private func performReceipt(_ attempt: ReceiptAttempt) async {
        do {
            let result = try await services.reimbursements.createReceipt(claimID: attempt.claimID, request: attempt.request, idempotencyKey: attempt.key)
            guard receiptAttempts[attempt.claimID]?.operationID == attempt.operationID else { return }
            let refreshGate = beginFactRefresh(owner: attempt.claimID, source: .createReceipt)
            receiptAttempts[attempt.claimID] = nil
            withReceiptState(attempt.claimID) { $0.result = result; $0.phase = .loading }
            replaceReceipt(result, owner: attempt.claimID)
            await convergeFacts(refreshGate)
        }
        catch let failure as V15Failure { guard receiptAttempts[attempt.claimID]?.operationID == attempt.operationID else { return }; withReceiptState(attempt.claimID) { state in state.serverIssues = failure.fieldIssues; if failure.kind == .responseUnknown || failure.kind == .cancelled || failure.kind == .offlineReadOnly { state.phase = .unknown } else { receiptAttempts[attempt.claimID] = nil; state.phase = failure.kind == .conflict && failure.conflict != nil ? .conflict(failure.conflict!) : .failed(failure) } } }
        catch { guard receiptAttempts[attempt.claimID]?.operationID == attempt.operationID else { return }; withReceiptState(attempt.claimID) { $0.phase = .unknown } }
    }
    private func performSecondary(_ attempt: SecondaryAttempt) async {
        let owner = secondaryOwner(attempt)
        do {
            let claimResult: V15ReimbursementClaim?
            let receiptResult: V15ReimbursementReceipt?
            switch attempt {
            case .claimReplace(_, let id, let request, let key): claimResult = try await services.reimbursements.commitClaimReplacement(claimID: id, request: request, idempotencyKey: key); receiptResult = nil
            case .cancel(_, let id, let request, let key): claimResult = try await services.reimbursements.commitCancellation(claimID: id, request: request, idempotencyKey: key); receiptResult = nil
            case .receiptReplace(_, _, let receiptID, let request, let key): receiptResult = try await services.reimbursements.replaceReceipt(receiptID: receiptID, request: request, idempotencyKey: key); claimResult = nil
            }
            guard secondaryAttempts[owner] == attempt else { return }
            let refreshGate = receiptResult.map { _ in beginFactRefresh(owner: owner, source: .replaceReceipt) }
            secondaryAttempts[owner] = nil; withSecondaryState(owner) { $0.phase = receiptResult == nil ? .succeeded : .loading; $0.claimPreview = nil; $0.cancelPreview = nil; $0.receiptPreview = nil }
            if let claimResult { applyClaimSuccess(claimResult) }
            if let receiptResult, let refreshGate { replaceReceipt(receiptResult, owner: owner); await convergeFacts(refreshGate) }
        } catch let failure as V15Failure { guard secondaryAttempts[owner] == attempt else { return }; if failure.kind == .responseUnknown || failure.kind == .cancelled || failure.kind == .offlineReadOnly { withSecondaryState(owner) { $0.phase = .unknown } } else { secondaryAttempts[owner] = nil; withSecondaryState(owner) { $0.phase = failure.kind == .conflict && failure.conflict != nil ? .conflict(failure.conflict!) : .failed(failure) } } }
        catch { guard secondaryAttempts[owner] == attempt else { return }; withSecondaryState(owner) { $0.phase = .unknown } }
    }

    private func sendDirectClaim(_ attempt: DirectAttempt) async throws -> V15ReimbursementClaim {
        guard case .claim(let action, let request, _) = attempt.intent else { throw V15Failure(kind: .decoding, message: "直接操作类型错误。") }
        let id = attempt.owner
        switch action { case .submit: return try await services.reimbursements.submit(claimID: id, request: request); case .retractSubmission: return try await services.reimbursements.retractSubmission(claimID: id, request: request); case .reopen: return try await services.reimbursements.reopen(claimID: id, request: request); case .void: return try await services.reimbursements.voidClaim(claimID: id, request: request); case .restore: return try await services.reimbursements.restoreClaim(claimID: id, request: request); case .archive: return try await services.reimbursements.archive(claimID: id, request: request); case .unarchive: return try await services.reimbursements.unarchive(claimID: id, request: request) }
    }
    private func sendDirectReceipt(_ attempt: DirectAttempt) async throws -> V15ReimbursementReceipt {
        guard case .receipt(let id, let action, let request, _, _) = attempt.intent else { throw V15Failure(kind: .decoding, message: "到账操作类型错误。") }
        switch action { case .void: return try await services.reimbursements.voidReceipt(receiptID: id, request: request); case .restore: return try await services.reimbursements.restoreReceipt(receiptID: id, request: request) }
    }

    private func newClaimInputChanged(fieldPath: String) { guard !isApplyingNewClaim else { return }; newClaimTouchedFields.insert(fieldPath); newClaimServerIssues = []; if createAttempt == nil, newClaimSheetVisible { newClaimPhase = .ready }; validateNewClaim() }
    private func candidateFilterChanged() { guard newClaimSheetVisible else { return }; newClaimTouchedFields.insert("parties[0].allocations[0].transaction_id"); candidateGeneration &+= 1; candidatePageGeneration &+= 1; selectedCandidate = nil; newClaimServerIssues = []; if createAttempt == nil { newClaimPhase = .ready }; validateNewClaim() }
    private func receiptInputChanged() { guard !isApplyingReceipt, let owner = selectedClaim?.id else { return }; receiptPreviewGenerations[owner, default: 0] &+= 1; withReceiptState(owner) { state in state.preparedDraft = nil; state.preview = nil; state.serverIssues = []; if receiptAttempts[owner] == nil, receiptSheetVisible { state.phase = .ready } }; validateReceipt() }
    private func secondaryInputChanged(owner: UUID) {
        secondaryGenerations[owner, default: 0] &+= 1
        withSecondaryState(owner) { state in
            state.claimPreview = nil; state.receiptPreview = nil; state.cancelPreview = nil
            state.preparedClaimRequest = nil; state.preparedReceiptRequest = nil; state.issues = []
            if secondaryAttempts[owner] == nil { state.phase = .ready }
        }
    }
    private func syncSecondaryIssues(_ reasons: [V15DisabledReason]) {
        guard let owner = selectedClaim?.id else { return }
        withSecondaryState(owner) { $0.issues = reasons.map { .init(code: $0.code, message: $0.message, fieldPath: $0.fieldPath) } }
    }
    private func validateNewClaim() { _ = makeNewClaimDraft(recordIssues: true) }
    private func makeNewClaimDraft(recordIssues: Bool) -> V15ReimbursementClaimDraft? {
        var issues: [V15FieldIssue] = []; let title = claimTitle.trimmingCharacters(in: .whitespacesAndNewlines); let party = partyName.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { issues.append(.init(code: "title_required", message: "请填写报销标题。", fieldPath: "title")) }; if title.count > 120 { issues.append(.init(code: "title_too_long", message: "报销标题最多 120 个字符。", fieldPath: "title")) }
        if party.isEmpty { issues.append(.init(code: "party_required", message: "请填写报销当事人。", fieldPath: "parties[0].name")) }; if party.count > 120 { issues.append(.init(code: "party_too_long", message: "当事人最多 120 个字符。", fieldPath: "parties[0].name")) }
        guard let candidate = selectedCandidate else { issues.append(.init(code: "candidate_required", message: "请选择一笔垫付。", fieldPath: "parties[0].allocations[0].transaction_id")); if recordIssues { newClaimIssues = issues }; return nil }
        if !candidate.eligibility.eligible { issues.append(contentsOf: candidate.eligibility.reasonDetails.map { .init(code: $0.code, message: $0.message, fieldPath: $0.fieldPath ?? "parties[0].allocations[0].transaction_id") }) }
        guard let amount = CNYAmountParser.minorUnits(allocationAmountText), amount > 0 else { issues.append(.init(code: "amount_invalid", message: "分摊金额须为正数，且最多两位小数。", fieldPath: "parties[0].allocations[0].amount_minor")); if recordIssues { newClaimIssues = issues }; return nil }
        if amount > candidate.availableMinor { issues.append(.init(code: "amount_exceeds_available", message: "分摊金额不能超过可报销余额。", fieldPath: "parties[0].allocations[0].amount_minor")) }
        let date = expectedDateText.nilIfEmpty; if !strictDateOrEmpty(date) { issues.append(.init(code: "date_invalid", message: "预计日期必须为 YYYY-MM-DD。", fieldPath: "parties[0].expected_date")) }
        if recordIssues { newClaimIssues = issues }; guard issues.isEmpty else { return nil }
        return .init(title: title, parties: [.init(name: party, expectedDate: date, allocations: [.init(transactionID: candidate.transactionID, amountMinor: amount)])])
    }
    private func validateReceipt() { _ = makeReceiptDraft(recordIssues: true) }
    private func makeReceiptDraft(recordIssues: Bool) -> V15ReimbursementReceiptDraft? {
        var issues: [V15FieldIssue] = []; guard let claim = selectedClaim else { return nil }
        guard claim.status.isKnown else { issues.append(.init(code: "unknown_claim_status", message: "未知报销状态只可查看。", fieldPath: "status")); if recordIssues { withReceiptState(claim.id) { $0.issues = issues } }; return nil }
        let partyID = selectedPartyID
        let party = partyID.flatMap { id in claim.parties.first(where: { $0.id == id }) }
        if let party {
            if party.outstandingMinor <= 0 { issues.append(.init(code: "party_fully_received", message: "该当事人没有未到账金额。", fieldPath: "party_id")) }
        } else {
            issues.append(.init(code: "party_required", message: "请选择到账当事人。", fieldPath: "party_id"))
        }
        let amount = CNYAmountParser.minorUnits(receiptAmountText)
        if let amount, amount > 0 {
            if let party, amount > party.outstandingMinor { issues.append(.init(code: "amount_exceeds_outstanding", message: "到账金额不能超过该当事人未到账金额。", fieldPath: "amount_minor")) }
        } else {
            issues.append(.init(code: "amount_invalid", message: "到账金额须为正数，且最多两位小数。", fieldPath: "amount_minor"))
        }
        let account = selectedReceiptAccount
        if let account {
            if account.kind != "cash" && account.kind != "debit" { issues.append(.init(code: "account_kind_invalid", message: "到账账户必须是现金或借记账户。", fieldPath: "destination_account_id")) }
        } else {
            issues.append(.init(code: "account_required", message: "请选择收款账户。", fieldPath: "destination_account_id"))
        }
        let title = receiptTitle.trimmingCharacters(in: .whitespacesAndNewlines); if title.isEmpty { issues.append(.init(code: "title_required", message: "请填写到账标题。", fieldPath: "title")) }; if title.count > 120 { issues.append(.init(code: "title_too_long", message: "到账标题最多 120 个字符。", fieldPath: "title")) }
        let receivedAt = shanghaiStartOfDay(receiptDateText)
        if let receivedAt {
            if receivedAt > now() { issues.append(.init(code: "future_receipt", message: "到账日期不能晚于现在。", fieldPath: "received_at")) }
        } else {
            issues.append(.init(code: "date_invalid", message: "到账日期必须为 YYYY-MM-DD。", fieldPath: "received_at"))
        }
        if recordIssues { withReceiptState(claim.id) { $0.issues = issues } }
        guard issues.isEmpty, let partyID, let amount, let account, let receivedAt else { return nil }
        return .init(expectedClaimVersion: claim.version, partyID: partyID, amountMinor: amount, receivedAt: receivedAt, destinationAccountID: account.id, title: title)
    }

    private func invalidateAllReads() { listGeneration &+= 1; claimPageGeneration &+= 1; detailGeneration &+= 1; receiptPageGeneration &+= 1 }
    private func invalidateSecondaryPreview(owner: UUID) { secondaryGenerations[owner, default: 0] &+= 1; withSecondaryState(owner) { $0.claimPreview = nil; $0.cancelPreview = nil; $0.receiptPreview = nil; $0.preparedClaimRequest = nil; $0.preparedReceiptRequest = nil; if secondaryAttempts[owner] == nil { $0.phase = .idle } } }
    private func resetVisibleReceiptEditor() { receiptSheetVisible = false }
    private func applyClaimSuccess(_ claim: V15ReimbursementClaim) { guard selectedClaim?.id == claim.id else { replaceClaimInList(claim); return }; selectedClaim = claim; replaceClaimInList(claim) }
    private func replaceClaimInList(_ claim: V15ReimbursementClaim) { if let index = claims.firstIndex(where: { $0.id == claim.id }) { claims[index] = claim } else { claims.insert(claim, at: 0) } }
    private func replaceReceipt(_ receipt: V15ReimbursementReceipt, owner: UUID) { guard selectedClaim?.id == owner else { return }; if let index = receipts.firstIndex(where: { $0.id == receipt.id }) { receipts[index] = receipt } else { receipts.insert(receipt, at: 0) } }
    private func beginFactRefresh(owner: UUID, source: FactRefreshSource) -> FactRefreshGate {
        let gate = FactRefreshGate(operationID: UUID(), owner: owner, source: source, phase: .refreshing, message: "到账已经保存；正在读取最新报销单与到账列表。")
        factRefreshGates[owner] = gate
        return gate
    }
    private func convergeFacts(_ gate: FactRefreshGate) async {
        guard factRefreshGates[gate.owner]?.operationID == gate.operationID else { return }
        factRefreshGates[gate.owner]?.phase = .refreshing
        factRefreshGates[gate.owner]?.message = "到账已经保存；正在读取最新报销单与到账列表。"
        do {
            async let claimRequest = services.reimbursements.claim(id: gate.owner, readCachePolicy: .reloadIgnoringCache)
            async let receiptsRequest = services.reimbursements.receipts(claimID: gate.owner, readCachePolicy: .reloadIgnoringCache)
            let (freshClaim, freshReceipts) = try await (claimRequest, receiptsRequest)
            guard factRefreshGates[gate.owner]?.operationID == gate.operationID else { return }
            replaceClaimInList(freshClaim)
            if selectedClaim?.id == gate.owner {
                selectedClaim = freshClaim
                receipts = uniqueReceipts(freshReceipts.items)
                nextReceiptCursor = freshReceipts.nextCursor
                receiptPagePhase = .idle
            }
            factRefreshGates[gate.owner] = nil
            switch gate.source {
            case .createReceipt: withReceiptState(gate.owner) { $0.phase = .succeeded }
            case .replaceReceipt: withSecondaryState(gate.owner) { $0.phase = .succeeded }
            case .directReceipt: withDirectState(gate.owner) { $0.phase = .succeeded; $0.message = nil }
            }
        } catch let failure as V15Failure {
            guard factRefreshGates[gate.owner]?.operationID == gate.operationID else { return }
            factRefreshGates[gate.owner]?.phase = .failed
            factRefreshGates[gate.owner]?.message = "到账已经保存，但最新报销数据读取失败：\(failure.message)。请重新读取；不会重复登记到账。"
            markFactRefreshFailure(gate.source, owner: gate.owner, failure: failure)
        } catch {
            guard factRefreshGates[gate.owner]?.operationID == gate.operationID else { return }
            let failure = V15Failure(kind: .transport, message: "到账已经保存，但最新报销数据读取失败。")
            factRefreshGates[gate.owner]?.phase = .failed
            factRefreshGates[gate.owner]?.message = "到账已经保存，但最新报销数据读取失败。请重新读取；不会重复登记到账。"
            markFactRefreshFailure(gate.source, owner: gate.owner, failure: failure)
        }
    }
    private func markFactRefreshFailure(_ source: FactRefreshSource, owner: UUID, failure: V15Failure) {
        switch source {
        case .createReceipt: withReceiptState(owner) { $0.phase = .failed(failure) }
        case .replaceReceipt: withSecondaryState(owner) { $0.phase = .failed(failure) }
        case .directReceipt: withDirectState(owner) { $0.phase = .failed(failure); $0.message = factRefreshGates[owner]?.message }
        }
    }
    private func ownsDirect(_ attempt: DirectAttempt, owner: UUID) -> Bool { directAttempts[owner] == attempt }
    private func secondaryOwner(_ attempt: SecondaryAttempt) -> UUID { switch attempt { case .claimReplace(_, let owner, _, _), .cancel(_, let owner, _, _), .receiptReplace(_, let owner, _, _, _): owner } }
    private func withReceiptState(_ owner: UUID, _ update: (inout ReceiptState) -> Void) { var state = receiptStates[owner] ?? ReceiptState(); update(&state); receiptStates[owner] = state }
    private func withSecondaryState(_ owner: UUID, _ update: (inout SecondaryState) -> Void) { var state = secondaryStates[owner] ?? SecondaryState(); update(&state); secondaryStates[owner] = state }
    private func withDirectState(_ owner: UUID, _ update: (inout DirectState) -> Void) { var state = directStates[owner] ?? DirectState(); update(&state); directStates[owner] = state }
    private func directClaimTargetSatisfied(_ claim: V15ReimbursementClaim, action: DirectClaimAction) -> Bool {
        switch action { case .submit: claim.submittedAt != nil; case .retractSubmission: claim.submittedAt == nil && claim.status == .draft; case .reopen: claim.cancelledAt == nil && (claim.status == .pending || claim.status == .partialReceived); case .void: claim.voidedAt != nil; case .restore: claim.voidedAt == nil; case .archive: claim.archivedAt != nil; case .unarchive: claim.archivedAt == nil }
    }
    private func directReceiptTargetSatisfied(_ receipt: V15ReimbursementReceipt, action: DirectReceiptAction) -> Bool { action == .void ? receipt.voidedAt != nil : receipt.voidedAt == nil }
    private var factRefreshReason: V15DisabledReason { .init(code: "receipt_fact_refresh_required", message: "到账已经保存，最新报销数据还没有更新完成；请重新读取后再操作。", fieldPath: nil) }
    private func claimAction(_ action: DirectClaimAction) -> ClaimAction {
        switch action { case .submit: .submit; case .retractSubmission: .retractSubmission; case .reopen: .reopen; case .void: .void; case .restore: .restore; case .archive: .archive; case .unarchive: .unarchive }
    }
    private func claimInapplicableReason(_ action: ClaimAction, claim: V15ReimbursementClaim) -> V15DisabledReason {
        switch action {
        case .replace: return .init(code: "claim_not_replaceable", message: "归档或作废的报销单不可替换。", fieldPath: "status")
        case .cancelOutstanding:
            if claim.archivedAt != nil { return .init(code: "claim_archived", message: "归档报销单只读，请先取消归档。", fieldPath: "archived_at") }
            if claim.voidedAt != nil { return .init(code: "claim_voided", message: "已作废报销单没有可取消的未到账金额。", fieldPath: "voided_at") }
            if claim.submittedAt == nil { return .init(code: "draft_not_cancellable", message: "报销单尚未提交，没有可取消的未到账金额。", fieldPath: "submitted_at") }
            if claim.cancelledAt != nil { return .init(code: "status_not_cancellable", message: "报销单已经取消，不能重复取消。", fieldPath: "cancelled_at") }
            if claim.outstandingMinor <= 0 { return .init(code: "nothing_outstanding", message: "报销单没有可取消的未到账金额。", fieldPath: "outstanding_minor") }
            return .init(code: "claim_not_cancellable", message: "当前状态不允许取消未到账。", fieldPath: "status")
        case .submit: return .init(code: "claim_not_submittable", message: "只有未提交、未取消、未归档且未作废的报销单可提交。", fieldPath: "status")
        case .retractSubmission: return .init(code: "claim_not_retractable", message: "只有已提交且尚无到账金额的报销单可撤回提交。", fieldPath: "status")
        case .reopen: return .init(code: "claim_not_reopenable", message: "只有已取消且未归档、未作废的报销单可重新打开。", fieldPath: "status")
        case .void: return .init(code: "claim_not_voidable", message: "只有未提交、未作废且没有任何到账记录的报销单可作废。", fieldPath: "status")
        case .restore: return .init(code: "claim_not_restorable", message: "只有已作废且未归档的报销单可恢复。", fieldPath: "status")
        case .archive: return .init(code: "claim_not_archivable", message: "只有已到账、已取消或部分到账后取消的终态报销单可归档。", fieldPath: "status")
        case .unarchive: return .init(code: "claim_not_archived", message: "只有已归档报销单可取消归档。", fieldPath: "archived_at")
        }
    }
    private func receiptInapplicableReason(_ action: ReceiptAction, receipt: V15ReimbursementReceipt, claim: V15ReimbursementClaim) -> V15DisabledReason {
        switch action {
        case .replace: return .init(code: "receipt_not_replaceable", message: "只能修改未作废到账记录；所属报销单不可归档或作废。", fieldPath: "status")
        case .void: return .init(code: "receipt_not_voidable", message: "只能作废有效到账记录，且所属报销单不可归档。", fieldPath: "status")
        case .restore: return .init(code: "receipt_not_restorable", message: "只能恢复已作废到账记录，且所属报销单不可归档、作废或取消。", fieldPath: "status")
        }
    }
    private func directClaimReadbackMessage(before: V15ReimbursementClaim, fresh: V15ReimbursementClaim, action: DirectClaimAction, expectedVersion: Int) -> String {
        if directClaimTargetSatisfied(before, action: action) { return "操作前已经是目标状态，仍无法确认本次结果。请核对后继续。" }
        if fresh.version <= expectedVersion { return "数据没有变化，仍无法确认本次结果。请核对后继续。" }
        if fresh.version == expectedVersion + 1, directClaimTargetSatisfied(fresh, action: action) { return "数据已经变化，但仍无法确认是否由本次操作造成。请核对后继续。" }
        return "最新状态与本次操作不完全一致，暂时无法确认结果。请核对后继续。"
    }
    private func directReceiptReadbackMessage(beforeClaim: V15ReimbursementClaim, beforeReceipt: V15ReimbursementReceipt, freshClaim: V15ReimbursementClaim, freshReceipt: V15ReimbursementReceipt, action: DirectReceiptAction, request: V15ReimbursementReceiptVersionRequest) -> String {
        if directReceiptTargetSatisfied(beforeReceipt, action: action) { return "操作前已经是目标状态，仍无法确认本次结果。请核对后继续。" }
        if freshClaim.version <= request.expectedClaimVersion || freshReceipt.version <= request.expectedReceiptVersion { return "报销单或到账记录没有同步变化，仍无法确认本次结果。请核对后继续。" }
        if freshClaim.version == request.expectedClaimVersion + 1, freshReceipt.version == request.expectedReceiptVersion + 1, directReceiptTargetSatisfied(freshReceipt, action: action), beforeClaim.id == freshClaim.id, beforeReceipt.id == freshReceipt.id { return "数据已经变化，但仍无法确认是否由本次操作造成。请核对后继续。" }
        return "最新到账状态与本次操作不完全一致，暂时无法确认结果。请核对后继续。"
    }
    private func partyDraft(_ party: V15ReimbursementParty) -> V15ReimbursementPartyDraft { .init(id: party.id, name: party.name, expectedDate: party.expectedDate, note: party.note, allocations: party.allocations.map { .init(id: $0.id, transactionID: $0.transactionID, amountMinor: $0.amountMinor) }) }
    private func claimIdentity(_ request: V15ReimbursementClaimDraft) -> String { request.parties.flatMap(\.allocations).reduce("\(request.title)|\(request.parties.map(\.name).joined(separator: ","))") { "\($0)|\($1.transactionID)|\($1.amountMinor)" } }
    private func receiptIdentity(_ request: V15ReimbursementReceiptDraft) -> String { "\(request.expectedClaimVersion)|\(request.partyID)|\(request.amountMinor)|\(request.receivedAt.timeIntervalSince1970)|\(request.destinationAccountID)|\(request.title)|\(request.note ?? "")" }
    private func receiptCommitIdentity(_ request: V15ReimbursementReceiptCreateCommitRequest) -> String { "\(request.expectedClaimVersion)|\(request.partyID)|\(request.amountMinor)|\(request.receivedAt.timeIntervalSince1970)|\(request.destinationAccountID)|\(request.title)|\(request.note ?? "")|\(request.previewToken)" }
    private func currentReceiptIdentity() -> String? { makeReceiptDraft(recordIssues: false).map(receiptIdentity) }
    private func reason(_ issue: V15FieldIssue) -> V15DisabledReason { .init(code: issue.code, message: issue.message, fieldPath: issue.fieldPath) }
    private func uniqueReasons(_ values: [V15DisabledReason]) -> [V15DisabledReason] { var seen = Set<String>(); return values.filter { seen.insert("\($0.code)|\($0.fieldPath ?? "")").inserted } }
    private func uniqueClaims(_ values: [V15ReimbursementClaim]) -> [V15ReimbursementClaim] { var ids = Set<UUID>(); return values.filter { ids.insert($0.id).inserted } }
    private func uniqueReceipts(_ values: [V15ReimbursementReceipt]) -> [V15ReimbursementReceipt] { var ids = Set<UUID>(); return values.filter { ids.insert($0.id).inserted } }
    private func uniqueCandidates(_ values: [V15ReimbursementCandidate]) -> [V15ReimbursementCandidate] { var ids = Set<UUID>(); return values.filter { ids.insert($0.transactionID).inserted } }
    private func formatMinor(_ value: V15MinorUnits) -> String { String(format: "%.2f", Double(value) / 100) }
    private func strictDateOrEmpty(_ value: String?) -> Bool { guard let value else { return true }; return value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil && shanghaiStartOfDay(value) != nil }
    private func shanghaiStartOfDay(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.locale = Locale(identifier: "zh_CN"); calendar.timeZone = ShanghaiBusinessDate.timeZone
        guard let date = calendar.date(from: DateComponents(timeZone: ShanghaiBusinessDate.timeZone, year: parts[0], month: parts[1], day: parts[2])), ShanghaiBusinessDate.string(for: date) == trimmed else { return nil }
        return calendar.startOfDay(for: date)
    }
}

private extension String {
    var nilIfEmpty: String? { let value = trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? nil : value }
}
