import Foundation
import Observation

@MainActor @Observable
public final class V15AIProposalModel {
    public enum Phase: Equatable { case idle, loading, loaded, empty, failed(V15Failure) }
    public enum MutationPhase: Equatable { case idle, loading, unknown, conflict(V15Conflict), failed(V15Failure), succeeded(String) }
    public enum EditorMode: Equatable { case closed, reviewing(UUID) }
    public enum DirectAction: Sendable, Equatable { case replace, execute, ignore, retry, undo }

    public private(set) var phase: Phase = .idle
    public private(set) var detailPhase: Phase = .idle
    public private(set) var pagePhase: Phase = .idle
    public private(set) var mutationPhase: MutationPhase = .idle
    public private(set) var proposals: [V15AIProposal] = []
    public private(set) var pendingCount = 0
    public private(set) var nextCursor: String?
    public private(set) var selectedProposal: V15AIProposal?
    public private(set) var qualityEvents: [V15AIQualityEvent] = []
    public private(set) var settings: V15AISettings?
    public private(set) var accounts: [V15AccountResponse] = []
    public private(set) var expenseCategories: [V15CategoryResponse] = []
    public private(set) var incomeCategories: [V15CategoryResponse] = []
    public private(set) var creditCycles: [V15CreditCycle] = []
    public private(set) var editorMode: EditorMode = .closed
    public private(set) var serverIssues: [V15FieldIssue] = []
    public private(set) var reviewConfirmed = false
    public private(set) var readbackCompleted = false
    public private(set) var recoveryMessage: String?
    public private(set) var settingsContractViolation: V15Failure?

    public var source: V15AIProposalSource = .text { didSet { createInputChanged() } }
    public var inputText = "" { didSet { createInputChanged() } }
    public var kind: V15ManualTransactionKind = .expense { didSet { guard oldValue != kind else { return }; changeKind(from: oldValue) } }
    public var amountText = "" { didSet { editorInputChanged() } }
    public var occurredAt = Date() { didSet { editorInputChanged() } }
    public var title = "" { didSet { editorInputChanged() } }
    public var note = "" { didSet { editorInputChanged() } }
    public var accountID: UUID? { didSet { editorInputChanged() } }
    public var categoryID: UUID? { didSet { editorInputChanged() } }
    public var destinationAccountID: UUID? { didSet { editorInputChanged() } }
    public var creditCycleID: UUID? { didSet { editorInputChanged() } }

    private let services: V15Services
    private let offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)?
    private var listGeneration: UInt64 = 0
    private var pageGeneration: UInt64 = 0
    private var selectionGeneration: UInt64 = 0
    private var editorGeneration: UInt64 = 0
    private var mutationGeneration: UInt64 = 0
    private var applyingDraft = false

    private struct StableAttempt: Sendable, Equatable {
        let operationID: UUID
        let request: V15AIProposalCreate
        let key: UUID
        let mutationGeneration: UInt64

        func rebased(to mutationGeneration: UInt64) -> StableAttempt {
            .init(operationID: operationID, request: request, key: key, mutationGeneration: mutationGeneration)
        }
    }
    private enum StableRecoveryPhase: Equatable { case loading, unknown }
    private struct DirectAttempt: Sendable, Equatable {
        enum Intent: Sendable, Equatable {
            case replace(UUID, V15AIProposalReplace)
            case execute(UUID, V15AIProposalVersionRequest)
            case ignore(UUID, V15AIProposalVersionRequest)
            case retry(UUID, V15AIProposalVersionRequest)
            case undo(UUID, V15AIProposalUndoRequest)
        }
        let operationID: UUID
        let proposalID: UUID
        let intent: Intent
        let editorGeneration: UInt64
        let editorFingerprint: String?
        let mutationGeneration: UInt64
    }
    private struct DirectState: Equatable {
        var phase: MutationPhase = .idle
        var readbackCompleted = false
        var isReadbackLoading = false
        var message: String?
        var issues: [V15FieldIssue] = []
    }
    private struct ConfirmedReview: Equatable {
        let proposalID: UUID
        let proposalVersion: Int
        let serverFingerprint: String
        let draftFingerprint: String
    }
    private var stableAttempt: StableAttempt?
    private var stableRecoveryPhase: StableRecoveryPhase?
    private var directAttempts: [UUID: DirectAttempt] = [:]
    private var directStates: [UUID: DirectState] = [:]
    private var confirmedReviews: [UUID: ConfirmedReview] = [:]
    private var recoveryGenerations: [UUID: UInt64] = [:]
    private var settingsLoadFailure: V15Failure?
    private var isSettingsLoading = false

    public init(services: V15Services, offlineSnapshotAt: Date? = nil, offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)? = nil) {
        self.services = services
        self.offlineSnapshotProvider = offlineSnapshotProvider ?? { offlineSnapshotAt ?? services.offlineSnapshotAt }
    }

    public var offlineSnapshotAt: Date? { offlineSnapshotProvider?() }
    public var isOffline: Bool { offlineSnapshotAt != nil }
    public var hasStableCreateRecovery: Bool { stableAttempt != nil && stableRecoveryPhase != nil }
    public var hasUnknownCreate: Bool { stableAttempt != nil && stableRecoveryPhase == .unknown }
    public var hasUnknownDirect: Bool { selectedProposal.flatMap { directStates[$0.id] }.map { if case .unknown = $0.phase { true } else { false } } ?? false }
    public var isDirectReadbackLoading: Bool { selectedProposal.flatMap { directStates[$0.id] }?.isReadbackLoading ?? false }
    public var directReadbackDisabledReason: V15DisabledReason? {
        if isDirectReadbackLoading { return .init(code: "ai_readback_in_flight", message: "正在读取最新数据，请稍候。", fieldPath: nil) }
        if isOffline { return .init(code: "offline_read_only", message: "离线时无法读取最新数据。", fieldPath: nil) }
        return nil
    }
    public var writeLocked: Bool { stableAttempt != nil || !directAttempts.isEmpty || mutationPhase == .loading }
    public var effectiveAutoExecute: Bool { settings?.effectiveAutoExecute ?? false }
    public var settingsSafetyReason: V15DisabledReason? {
        guard settingsContractViolation != nil else { return nil }
        return .init(code: "ai_d3_contract_violation", message: "AI 安全设置异常；本页已停止所有保存操作。请重新打开此页面。", fieldPath: "effective_auto_execute")
    }
    public var unknownCreateRetryReasons: [V15DisabledReason] {
        guard let attempt = stableAttempt else {
            return [.init(code: "ai_create_recovery_missing", message: "没有可安全重试的创建操作。", fieldPath: nil)]
        }
        var reasons: [V15DisabledReason] = []
        if stableRecoveryPhase != .unknown { reasons.append(.init(code: "ai_create_recovery_in_flight", message: "正在等待本次创建结果，请稍候。", fieldPath: nil)) }
        if isOffline { reasons.append(.init(code: "offline_read_only", message: "离线时不能创建。", fieldPath: nil)) }
        if let reason = settingsSafetyReason { reasons.append(reason) }
        else if isSettingsLoading { reasons.append(.init(code: "ai_settings_loading", message: "正在读取 AI 安全设置，请稍候。", fieldPath: nil)) }
        else if settings == nil { reasons.append(.init(code: "ai_settings_unavailable", message: settingsLoadFailure?.message ?? "AI 安全设置尚未读取完成。", fieldPath: nil)) }
        if attempt.mutationGeneration != mutationGeneration { reasons.append(.init(code: "ai_create_recovery_generation_mismatch", message: "安全设置已经变化；请先重新读取设置，再安全检查原内容。", fieldPath: nil)) }
        if !directAttempts.isEmpty { reasons.append(.init(code: "ai_write_in_flight", message: "另一项写操作仍在进行或结果未知。", fieldPath: nil)) }
        return Self.unique(reasons)
    }
    public var unknownCreateAbandonReasons: [V15DisabledReason] {
        guard stableAttempt != nil else { return [.init(code: "ai_create_recovery_missing", message: "没有可停止检查的创建操作。", fieldPath: nil)] }
        guard stableRecoveryPhase == .unknown else { return [.init(code: "ai_create_recovery_in_flight", message: "正在等待本次创建结果，暂时不能停止。", fieldPath: nil)] }
        return []
    }
    public var activeAccounts: [V15AccountResponse] { accounts.filter(\.isActive) }
    public var visibleCategories: [V15CategoryResponse] { kind == .income ? incomeCategories : expenseCategories }
    public var isCashFlowReview: Bool { selectedProposal?.target == .cashFlow }
    public var reviewKinds: [V15ManualTransactionKind] { isCashFlowReview ? [.income, .expense, .transfer] : V15ManualTransactionKind.allCases }

    public var createReasons: [V15DisabledReason] {
        var reasons = baseWriteReasons()
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { reasons.append(.init(code: "ai_text_required", message: "请输入要解析的记账文字。", fieldPath: "text")) }
        if inputText.count > 2_000 { reasons.append(.init(code: "ai_text_too_long", message: "记账文字最多 2000 个字符。", fieldPath: "text")) }
        if source == .ocr && settings?.ocrSourceEnabled == false { reasons.append(.init(code: "ai_ocr_disabled", message: "当前未启用 OCR 来源。", fieldPath: "source")) }
        if source == .shortcutText && settings?.shortcutTextSourceEnabled == false { reasons.append(.init(code: "ai_shortcut_disabled", message: "当前未启用快捷指令来源。", fieldPath: "source")) }
        return Self.unique(reasons)
    }

    public var editorIssues: [V15FieldIssue] { makeDraft().issues }
    public var confirmReasons: [V15DisabledReason] {
        var reasons = baseWriteReasons() + editorIssues.map(Self.reason)
        guard case .reviewing(let owner) = editorMode, selectedProposal?.id == owner else {
            reasons.append(.init(code: "ai_editor_owner_changed", message: "当前内容已变化，请重新打开编辑页面。", fieldPath: nil))
            return Self.unique(reasons)
        }
        guard selectedProposal?.status == .pending else { reasons.append(.init(code: "ai_pending_required", message: "只有待确认内容可以保存修改。", fieldPath: "status")); return Self.unique(reasons) }
        if selectedProposal?.target.isDisplayOnly == true { reasons.append(.init(code: "ai_target_read_only", message: "未知目标只可查看，不能人工确认。", fieldPath: "target")) }
        if selectedProposal?.isDisplayOnly == true { reasons.append(.init(code: "ai_unknown_read_only", message: "暂时无法识别这项内容的状态，当前只供查看。", fieldPath: "status")) }
        return Self.unique(reasons)
    }

    public func actionReasons(_ action: DirectAction, proposal: V15AIProposal) -> [V15DisabledReason] {
        var reasons = baseWriteReasons()
        if proposal.isDisplayOnly { reasons.append(.init(code: "ai_unknown_read_only", message: "未知状态、目标或交易类型只可查看。", fieldPath: "status")) }
        switch action {
        case .replace:
            if proposal.status != .pending { reasons.append(.init(code: "ai_pending_required", message: "只有待确认内容可以修改。", fieldPath: "status")) }
        case .execute:
            if proposal.status != .pending { reasons.append(.init(code: "ai_pending_required", message: "只有待确认内容可以记账。", fieldPath: "status")) }
            if !matchesConfirmedReview(proposal) { reasons.append(.init(code: "ai_human_confirmation_required", message: "内容已经更新，请重新检查并保存后再记账。", fieldPath: "draft")) }
        case .ignore:
            if proposal.status != .pending { reasons.append(.init(code: "ai_pending_required", message: "只有待确认内容可以忽略。", fieldPath: "status")) }
        case .retry:
            if proposal.status != .failed { reasons.append(.init(code: "ai_failed_required", message: "只有解析失败的内容可以重试。", fieldPath: "status")) }
        case .undo:
            if proposal.status != .executed { reasons.append(.init(code: "ai_executed_required", message: "只有已记账内容可以撤销。", fieldPath: "status")) }
            if proposal.transactionID != nil && proposal.transactionVersion == nil { reasons.append(.init(code: "ai_transaction_version_required", message: "交易数据不完整，暂时不能安全撤销。", fieldPath: "transaction_version")) }
        }
        return Self.unique(reasons)
    }

    public func load() async {
        listGeneration &+= 1; let generation = listGeneration
        pageGeneration &+= 1; pagePhase = .idle
        settings = nil
        isSettingsLoading = true
        phase = .loading
        do {
            async let settingsLoad = services.ai.settings()
            async let pageLoad = services.ai.proposals(limit: 50)
            async let accountLoad = services.masterData.activeAccounts()
            async let expenseLoad = services.masterData.activeCategories(direction: .expense)
            async let incomeLoad = services.masterData.activeCategories(direction: .income)
            let (newSettings, page, newAccounts, newExpense, newIncome) = try await (settingsLoad, pageLoad, accountLoad, expenseLoad, incomeLoad)
            let newCycles = try await loadCreditCycles(accounts: newAccounts)
            guard generation == listGeneration else { return }
            isSettingsLoading = false
            if settingsContractViolation == nil {
                settings = newSettings
                settingsLoadFailure = nil
                authorizeStableCreateRecoveryAfterSafeSettings()
            }
            proposals = page.items
            for proposal in proposals { invalidateConfirmationIfStale(proposal) }
            pendingCount = page.pendingCount; nextCursor = page.nextCursor
            accounts = newAccounts; expenseCategories = newExpense; incomeCategories = newIncome
            creditCycles = newCycles
            phase = proposals.isEmpty ? .empty : .loaded
            if let selected = selectedProposal, let fresh = proposals.first(where: { $0.id == selected.id }) { selectedProposal = fresh; restoreOwnerState(for: fresh.id) }
            else if let first = proposals.first { await select(first) }
        } catch let failure as V15Failure {
            guard generation == listGeneration else { return }
            isSettingsLoading = false
            if Self.isSettingsContractViolation(failure) { enterSettingsContractViolation(failure) }
            else { enterSettingsUnavailable(failure) }
            phase = failure.kind == .cancelled ? .idle : phaseAfterSettingsFailure(failure)
        } catch {
            guard generation == listGeneration else { return }
            isSettingsLoading = false
            let failure = V15Failure(kind: .transport, message: "AI 内容读取失败。")
            enterSettingsUnavailable(failure)
            phase = phaseAfterSettingsFailure(failure)
        }
    }

    public func loadNextPage() async {
        guard let cursor = nextCursor, pagePhase != .loading else { return }
        pageGeneration &+= 1; let generation = pageGeneration
        let ownerCursor = cursor
        pagePhase = .loading
        do {
            let page = try await services.ai.proposals(cursor: ownerCursor, limit: 50)
            guard generation == pageGeneration, nextCursor == ownerCursor else { return }
            let existing = Set(proposals.map(\.id))
            proposals.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            nextCursor = page.nextCursor; pendingCount = page.pendingCount; pagePhase = .loaded
        } catch let failure as V15Failure {
            guard generation == pageGeneration else { return }
            pagePhase = failure.kind == .cancelled ? .idle : .failed(failure)
        } catch {
            guard generation == pageGeneration else { return }
            pagePhase = .failed(.init(kind: .transport, message: "下一页读取失败。"))
        }
    }

    public func select(_ proposal: V15AIProposal) async {
        selectionGeneration &+= 1; let generation = selectionGeneration
        selectedProposal = proposal; syncConfirmation(for: proposal); qualityEvents = []; detailPhase = .loading
        dismissEditor()
        restoreOwnerState(for: proposal.id)
        do {
            async let proposalLoad = services.ai.proposal(id: proposal.id)
            async let eventLoad = services.ai.qualityEvents(proposalID: proposal.id)
            let (fresh, events) = try await (proposalLoad, eventLoad)
            guard generation == selectionGeneration, selectedProposal?.id == proposal.id else { return }
            selectedProposal = fresh; syncConfirmation(for: fresh); qualityEvents = events; detailPhase = .loaded
            replaceListFact(fresh)
            restoreOwnerState(for: fresh.id)
        } catch let failure as V15Failure {
            guard generation == selectionGeneration, selectedProposal?.id == proposal.id else { return }
            detailPhase = failure.kind == .cancelled ? .idle : .failed(failure)
        } catch {
            guard generation == selectionGeneration, selectedProposal?.id == proposal.id else { return }
            detailPhase = .failed(.init(kind: .transport, message: "AI 内容详情读取失败。"))
        }
    }

    public func create() async {
        guard createReasons.isEmpty else { return }
        let request = V15AIProposalCreate(source: source, text: inputText)
        let attempt = StableAttempt(operationID: UUID(), request: request, key: UUID(), mutationGeneration: mutationGeneration)
        stableAttempt = attempt; stableRecoveryPhase = .loading; mutationPhase = .idle; recoveryMessage = nil
        await performCreate(attempt)
    }

    public func retryUnknownCreate() async {
        guard unknownCreateRetryReasons.isEmpty, let attempt = stableAttempt else { return }
        stableRecoveryPhase = .loading
        await performCreate(attempt)
    }

    public func abandonUnknownCreate() {
        guard unknownCreateAbandonReasons.isEmpty else { return }
        stableAttempt = nil; stableRecoveryPhase = nil
        recoveryMessage = "已停止检查这次操作；不会把其他内容误认为本次结果。"
    }

    public func openReview(_ proposal: V15AIProposal) {
        guard actionReasons(.replace, proposal: proposal).isEmpty else { return }
        applyingDraft = true
        kind = proposal.kind.flatMap { if case .known(let value) = $0 { value } else { nil } } ?? .expense
        amountText = proposal.amountMinor.map(Self.amountText) ?? ""
        occurredAt = proposal.occurredAt ?? .now
        title = proposal.title ?? ""; note = proposal.note ?? ""
        accountID = proposal.accountID; categoryID = proposal.categoryID; destinationAccountID = proposal.destinationAccountID; creditCycleID = proposal.creditCycleID
        applyingDraft = false
        editorGeneration &+= 1; editorMode = .reviewing(proposal.id); serverIssues = []; confirmedReviews.removeValue(forKey: proposal.id); reviewConfirmed = false
        if directAttempts[proposal.id] == nil { mutationPhase = .idle }
    }

    public func dismissEditor() {
        let wasOpen = editorMode != .closed
        let owner: UUID?
        if case .reviewing(let reviewingOwner) = editorMode { owner = reviewingOwner } else { owner = nil }
        if let owner { confirmedReviews.removeValue(forKey: owner) }
        editorGeneration &+= 1; editorMode = .closed; serverIssues = []
        if wasOpen, selectedProposal.map({ directAttempts[$0.id] == nil }) == true, stableAttempt == nil, mutationPhase != .loading { mutationPhase = .idle }
    }

    public func confirmDraft() async {
        let built = makeDraft()
        guard confirmReasons.isEmpty, let draft = built.value, let proposal = selectedProposal else { serverIssues = built.issues; return }
        let request = V15AIProposalReplace(draft: draft.wireDraft, expectedVersion: proposal.version)
        let attempt = DirectAttempt(operationID: UUID(), proposalID: proposal.id, intent: .replace(proposal.id, request), editorGeneration: editorGeneration, editorFingerprint: editorFingerprint(), mutationGeneration: mutationGeneration)
        directAttempts[proposal.id] = attempt; setDirectState(.init(phase: .loading), for: proposal.id); serverIssues = []
        await performDirect(attempt)
    }

    public func execute() async { guard let proposal = selectedProposal, actionReasons(.execute, proposal: proposal).isEmpty else { return }; await start(.execute(proposal.id, .init(expectedVersion: proposal.version)), proposalID: proposal.id) }
    public func ignore() async { guard let proposal = selectedProposal, actionReasons(.ignore, proposal: proposal).isEmpty else { return }; await start(.ignore(proposal.id, .init(expectedVersion: proposal.version)), proposalID: proposal.id) }
    public func retryParsing() async { guard let proposal = selectedProposal, actionReasons(.retry, proposal: proposal).isEmpty else { return }; await start(.retry(proposal.id, .init(expectedVersion: proposal.version)), proposalID: proposal.id) }
    public func undo() async {
        guard let proposal = selectedProposal, actionReasons(.undo, proposal: proposal).isEmpty else { return }
        await start(.undo(proposal.id, .init(expectedVersion: proposal.version, expectedTransactionVersion: proposal.transactionVersion)), proposalID: proposal.id)
    }

    public func recoverUnknownDirect() async {
        guard let proposal = selectedProposal, let attempt = directAttempts[proposal.id], case .unknown = directStates[proposal.id]?.phase, directStates[proposal.id]?.isReadbackLoading != true else { return }
        let generation = beginReadback(owner: proposal.id, phase: .unknown, message: "正在读取最新数据；不会重复保存。")
        do {
            let fresh = try await services.ai.proposal(id: attempt.proposalID, readCachePolicy: .reloadIgnoringCache)
            guard ownsReadback(owner: attempt.proposalID, attempt: attempt, generation: generation) else { return }
            replaceListFact(fresh); updateSelectionIfOwned(fresh, owner: attempt.proposalID)
            setDirectState(.init(phase: .unknown, readbackCompleted: true, message: "数据已经变化，但仍无法确认是否由本次操作造成。系统不会自动重复操作。"), for: attempt.proposalID)
        } catch let failure as V15Failure {
            guard ownsReadback(owner: attempt.proposalID, attempt: attempt, generation: generation) else { return }
            let message = failure.kind == .cancelled ? "检查最新状态已取消，请重试读取。" : "检查最新状态失败：\(failure.message)。请重试读取。"
            setDirectState(.init(phase: .unknown, readbackCompleted: false, message: message, issues: failure.fieldIssues), for: attempt.proposalID)
        } catch {
            guard ownsReadback(owner: attempt.proposalID, attempt: attempt, generation: generation) else { return }
            setDirectState(.init(phase: .unknown, readbackCompleted: false, message: "检查最新状态失败，请重试读取。"), for: attempt.proposalID)
        }
    }

    public func abandonUnknownDirect() {
        guard let owner = selectedProposal?.id, directAttempts[owner] != nil, case .unknown = directStates[owner]?.phase, directStates[owner]?.readbackCompleted == true else { return }
        directAttempts[owner] = nil; directStates[owner] = nil; mutationPhase = .idle; readbackCompleted = false
        recoveryMessage = "已结束本次结果恢复；不会把最新数据误认为本次操作结果。"
    }

    public func reloadConflict() async {
        guard let proposal = selectedProposal, case .conflict = directStates[proposal.id]?.phase, let attempt = directAttempts[proposal.id], directStates[proposal.id]?.isReadbackLoading != true else { return }
        let generation = beginReadback(owner: proposal.id, phase: directStates[proposal.id]?.phase ?? .conflict(.init(reloadPath: nil, latestRevision: nil, message: "数据已更新，需要重新读取。")), message: "正在读取最新数据；不会重复保存。")
        do {
            let fresh = try await services.ai.proposal(id: attempt.proposalID, readCachePolicy: .reloadIgnoringCache)
            guard ownsReadback(owner: attempt.proposalID, attempt: attempt, generation: generation) else { return }
            replaceListFact(fresh); updateSelectionIfOwned(fresh, owner: attempt.proposalID)
            directAttempts[attempt.proposalID] = nil; directStates[attempt.proposalID] = nil; confirmedReviews.removeValue(forKey: attempt.proposalID)
            if selectedProposal?.id == attempt.proposalID { mutationPhase = .idle; reviewConfirmed = false; if case .reviewing(let owner) = editorMode, owner == attempt.proposalID { dismissEditor() } }
        } catch let failure as V15Failure {
            guard ownsReadback(owner: attempt.proposalID, attempt: attempt, generation: generation) else { return }
            setDirectState(.init(phase: .conflict(failure.conflict ?? .init(reloadPath: nil, latestRevision: nil, message: "数据已更新，需要重新读取。")), message: "读取最新数据失败：\(failure.message)。请重试读取。", issues: failure.fieldIssues), for: attempt.proposalID)
        } catch {
            guard ownsReadback(owner: attempt.proposalID, attempt: attempt, generation: generation) else { return }
            if case .conflict(let conflict) = directStates[attempt.proposalID]?.phase { setDirectState(.init(phase: .conflict(conflict), message: "读取最新数据失败；请重试读取。"), for: attempt.proposalID) }
        }
    }

    private func performCreate(_ attempt: StableAttempt) async {
        do {
            let proposal = try await services.ai.create(attempt.request, idempotencyKey: attempt.key)
            guard stableAttempt == attempt, attempt.mutationGeneration == mutationGeneration else { return }
            stableAttempt = nil; stableRecoveryPhase = nil
            inputText = ""; proposals.removeAll { $0.id == proposal.id }; proposals.insert(proposal, at: 0); pendingCount += proposal.status == .pending ? 1 : 0
            await select(proposal)
            mutationPhase = .succeeded("待确认内容已建立。")
        } catch let failure as V15Failure {
            guard stableAttempt == attempt, attempt.mutationGeneration == mutationGeneration else { return }
            if Self.outcomeMayBeUnknown(failure) {
                stableRecoveryPhase = .unknown
                recoveryMessage = "结果暂时不明；可以安全检查相同内容，或停止恢复。"
            } else {
                stableAttempt = nil; stableRecoveryPhase = nil
                mutationPhase = failure.kind == .conflict ? .conflict(failure.conflict ?? .init(reloadPath: nil, latestRevision: nil, message: failure.message)) : .failed(failure)
            }
        } catch {
            guard stableAttempt == attempt, attempt.mutationGeneration == mutationGeneration else { return }
            stableRecoveryPhase = .unknown
            recoveryMessage = "结果暂时不明；可以安全检查相同内容，或停止恢复。"
        }
    }

    private func start(_ intent: DirectAttempt.Intent, proposalID: UUID) async {
        guard directAttempts.isEmpty, baseWriteReasons().isEmpty else { return }
        let attempt = DirectAttempt(operationID: UUID(), proposalID: proposalID, intent: intent, editorGeneration: editorGeneration, editorFingerprint: editorFingerprint(), mutationGeneration: mutationGeneration)
        directAttempts[proposalID] = attempt; setDirectState(.init(phase: .loading), for: proposalID)
        await performDirect(attempt)
    }

    private func performDirect(_ attempt: DirectAttempt) async {
        do {
            let result: V15AIProposal
            let message: String
            switch attempt.intent {
            case .replace(let id, let request): result = try await services.ai.replace(id: id, request: request); message = "修改已保存；现在可以确认记账。"
            case .execute(let id, let request): result = try await services.ai.execute(id: id, expectedVersion: request.expectedVersion).proposal; message = "已按人工确认内容执行。"
            case .ignore(let id, let request): result = try await services.ai.ignore(id: id, expectedVersion: request.expectedVersion); message = "已忽略。"
            case .retry(let id, let request): result = try await services.ai.retry(id: id, expectedVersion: request.expectedVersion); message = "已重新解析并回到待确认列表。"
            case .undo(let id, let request): result = try await services.ai.undo(id: id, expectedVersion: request.expectedVersion, expectedTransactionVersion: request.expectedTransactionVersion).proposal; message = "已撤销对应账目。"
            }
            guard directAttempts[attempt.proposalID] == attempt, attempt.mutationGeneration == mutationGeneration else { return }
            directAttempts[attempt.proposalID] = nil; directStates[attempt.proposalID] = nil; replaceListFact(result)
            let editorStillOwnsAttempt = selectedProposal?.id == attempt.proposalID && editorGeneration == attempt.editorGeneration && editorFingerprint() == attempt.editorFingerprint
            if selectedProposal?.id == attempt.proposalID { selectedProposal = result; mutationPhase = .succeeded(message); serverIssues = [] }
            if case .replace = attempt.intent {
                if editorStillOwnsAttempt, let draftFingerprint = draftFingerprint(for: attempt) {
                    confirmedReviews[attempt.proposalID] = .init(proposalID: result.id, proposalVersion: result.version, serverFingerprint: serverFingerprint(result), draftFingerprint: draftFingerprint)
                    adoptDraft(result); syncConfirmation(for: result)
                }
            } else if selectedProposal?.id == attempt.proposalID {
                editorGeneration &+= 1; editorMode = .closed; confirmedReviews.removeValue(forKey: attempt.proposalID); reviewConfirmed = false
            }
            let freshEvents = try? await services.ai.qualityEvents(proposalID: result.id, readCachePolicy: .reloadIgnoringCache)
            if selectedProposal?.id == result.id, let freshEvents { qualityEvents = freshEvents }
        } catch let failure as V15Failure {
            guard directAttempts[attempt.proposalID] == attempt, attempt.mutationGeneration == mutationGeneration else { return }
            if failure.kind == .conflict {
                setDirectState(.init(phase: .conflict(failure.conflict ?? .init(reloadPath: nil, latestRevision: nil, message: failure.message)), message: "数据已经更新；请读取最新内容后再决定。", issues: failure.fieldIssues), for: attempt.proposalID)
            } else if Self.outcomeMayBeUnknown(failure) {
                setDirectState(.init(phase: .unknown, message: "暂时无法确认操作结果；请先检查最新状态。系统不会重复操作。", issues: failure.fieldIssues), for: attempt.proposalID)
            } else {
                directAttempts[attempt.proposalID] = nil; directStates[attempt.proposalID] = nil
                setDirectState(.init(phase: .failed(failure), message: failure.message, issues: failure.fieldIssues), for: attempt.proposalID)
            }
            confirmedReviews.removeValue(forKey: attempt.proposalID)
        } catch {
            guard directAttempts[attempt.proposalID] == attempt, attempt.mutationGeneration == mutationGeneration else { return }
            setDirectState(.init(phase: .unknown, message: "暂时无法确认操作结果；请先检查最新状态。系统不会重复操作。"), for: attempt.proposalID)
            confirmedReviews.removeValue(forKey: attempt.proposalID)
        }
    }

    private func adoptDraft(_ proposal: V15AIProposal) {
        applyingDraft = true
        amountText = proposal.amountMinor.map(Self.amountText) ?? amountText; occurredAt = proposal.occurredAt ?? occurredAt
        title = proposal.title ?? title; note = proposal.note ?? note; accountID = proposal.accountID; categoryID = proposal.categoryID; destinationAccountID = proposal.destinationAccountID; creditCycleID = proposal.creditCycleID
        if case .known(let value)? = proposal.kind { kind = value }
        applyingDraft = false
    }

    private func makeDraft() -> (value: V15AIProposalReviewDraft?, issues: [V15FieldIssue]) {
        var issues: [V15FieldIssue] = []
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = Self.canonicalNote(note)
        let amount = CNYAmountParser.minorUnits(amountText)
        if amount == nil || amount ?? 0 <= 0 { issues.append(.init(code: "amount_invalid", message: "金额必须大于 0，且最多两位小数。", fieldPath: "draft.amount_minor")) }
        if trimmedTitle.isEmpty { issues.append(.init(code: "title_required", message: "请填写标题。", fieldPath: "draft.title")) }
        if trimmedTitle.count > 120 { issues.append(.init(code: "title_too_long", message: "标题最多 120 个字符。", fieldPath: "draft.title")) }
        if (trimmedNote?.count ?? 0) > 500 { issues.append(.init(code: "note_too_long", message: "备注最多 500 个字符。", fieldPath: "draft.note")) }
        let cash = activeAccounts.filter { $0.kind == .cash || $0.kind == .debit }
        let credit = activeAccounts.filter { $0.kind == .credit }
        let target = selectedProposal?.target
        if target == .cashFlow, ![V15ManualTransactionKind.income, .expense, .transfer].contains(kind) {
            issues.append(.init(code: "cash_flow_kind_invalid", message: "未来现金流只支持收入、支出或转账。", fieldPath: "draft.kind"))
        }
        switch kind {
        case .expense, .income:
            if accountID == nil || !cash.contains(where: { $0.id == accountID }) { issues.append(.init(code: "account_required", message: "请选择现金或借记账户。", fieldPath: "draft.account_id")) }
            if destinationAccountID != nil { issues.append(.init(code: "destination_not_allowed", message: "收入或支出不能保留目标账户。", fieldPath: "draft.destination_account_id")) }
            if creditCycleID != nil { issues.append(.init(code: "credit_cycle_not_allowed", message: "收入或支出不能保留信用账期。", fieldPath: "draft.credit_cycle_id")) }
        case .transfer:
            if accountID == nil || destinationAccountID == nil { issues.append(.init(code: "transfer_accounts_required", message: "请选择转出与转入账户。", fieldPath: "draft.destination_account_id")) }
            if accountID == destinationAccountID { issues.append(.init(code: "transfer_accounts_same", message: "转出与转入账户不能相同。", fieldPath: "draft.destination_account_id")) }
            if categoryID != nil { issues.append(.init(code: "category_not_allowed", message: "转账不能保留分类。", fieldPath: "draft.category_id")) }
            if creditCycleID != nil { issues.append(.init(code: "credit_cycle_not_allowed", message: "转账不能保留信用账期。", fieldPath: "draft.credit_cycle_id")) }
        case .creditPurchase:
            if accountID == nil || !credit.contains(where: { $0.id == accountID }) { issues.append(.init(code: "credit_account_required", message: "请选择信用账户。", fieldPath: "draft.account_id")) }
            if destinationAccountID != nil { issues.append(.init(code: "destination_not_allowed", message: "信用消费不能保留目标账户。", fieldPath: "draft.destination_account_id")) }
            if creditCycleID != nil { issues.append(.init(code: "credit_cycle_not_allowed", message: "信用消费不能保留信用账期。", fieldPath: "draft.credit_cycle_id")) }
        case .repayment:
            if accountID == nil || !cash.contains(where: { $0.id == accountID }) { issues.append(.init(code: "repayment_source_required", message: "请选择还款来源账户。", fieldPath: "draft.account_id")) }
            if destinationAccountID == nil || !credit.contains(where: { $0.id == destinationAccountID }) { issues.append(.init(code: "repayment_destination_required", message: "请选择信用还款账户。", fieldPath: "draft.destination_account_id")) }
            if creditCycleID == nil { issues.append(.init(code: "credit_cycle_required", message: "还款必须保留或选择账期。", fieldPath: "draft.credit_cycle_id")) }
            if categoryID != nil { issues.append(.init(code: "category_not_allowed", message: "还款不能保留分类。", fieldPath: "draft.category_id")) }
        }
        if kind == .expense || kind == .creditPurchase, categoryID != nil, !expenseCategories.contains(where: { $0.id == categoryID }) { issues.append(.init(code: "expense_category_mismatch", message: "请选择支出分类。", fieldPath: "draft.category_id")) }
        if kind == .income, categoryID != nil, !incomeCategories.contains(where: { $0.id == categoryID }) { issues.append(.init(code: "income_category_mismatch", message: "请选择收入分类。", fieldPath: "draft.category_id")) }
        if kind == .transfer {
            if !allowedSource(accountID, for: .transfer) { issues.append(.init(code: "transfer_source_invalid", message: "请选择现金或借记转出账户。", fieldPath: "draft.account_id")) }
            if !allowedDestination(destinationAccountID, for: .transfer, sourceID: accountID) { issues.append(.init(code: "transfer_destination_invalid", message: "请选择现金或借记转入账户。", fieldPath: "draft.destination_account_id")) }
        }
        if kind == .repayment, let cycleID = creditCycleID, let destinationAccountID, !creditCycles.contains(where: { $0.id == cycleID && $0.accountID == destinationAccountID }) { issues.append(.init(code: "credit_cycle_account_mismatch", message: "账期必须属于目标信用账户。", fieldPath: "draft.credit_cycle_id")) }
        guard issues.isEmpty, let amount else { return (nil, issues) }
        let wire = V15TransactionCreateRequest(kind: kind, amountMinor: amount, occurredAt: occurredAt, title: trimmedTitle, note: trimmedNote, accountID: accountID, categoryID: categoryID, destinationAccountID: destinationAccountID, creditCycleID: creditCycleID)
        return (target == .cashFlow ? .cashFlow(.init(wireDraft: wire)) : .transaction(wire), [])
    }

    private func loadCreditCycles(accounts: [V15AccountResponse]) async throws -> [V15CreditCycle] {
        var result: [V15CreditCycle] = []
        for account in accounts where account.isActive && account.kind == .credit {
            var cursor: String?
            repeat {
                let page = try await services.creditCycles.list(accountID: account.id, cursor: cursor)
                result.append(contentsOf: page.items)
                cursor = page.nextCursor
            } while cursor != nil
        }
        return result
    }

    private func phaseAfterSettingsFailure(_ failure: V15Failure) -> Phase {
        proposals.isEmpty ? .failed(failure) : .loaded
    }

    private func enterSettingsUnavailable(_ failure: V15Failure) {
        guard settingsContractViolation == nil else { return }
        settings = nil
        settingsLoadFailure = failure
        invalidateMutationsForSettingsGate(failure, recoveryMessage: "无法读取安全设置；为保护数据，已暂停更改。你仍可以查看现有内容，并刷新后重试。")
    }

    private func enterSettingsContractViolation(_ failure: V15Failure) {
        settingsContractViolation = failure
        settings = nil
        settingsLoadFailure = nil
        invalidateMutationsForSettingsGate(failure, recoveryMessage: "AI 安全设置异常；暂时无法确认操作结果。检查最新状态不会重复保存。")
    }

    private func authorizeStableCreateRecoveryAfterSafeSettings() {
        guard settingsContractViolation == nil,
              stableRecoveryPhase == .unknown,
              let attempt = stableAttempt,
              attempt.mutationGeneration != mutationGeneration
        else { return }
        stableAttempt = attempt.rebased(to: mutationGeneration)
        recoveryMessage = "安全设置已更新；现在可以安全检查完全相同的文本。"
    }

    private func invalidateMutationsForSettingsGate(_ failure: V15Failure, recoveryMessage message: String) {
        mutationGeneration &+= 1
        confirmedReviews.removeAll()
        reviewConfirmed = false
        editorGeneration &+= 1
        editorMode = .closed
        serverIssues = []
        if stableAttempt != nil { stableRecoveryPhase = .unknown }
        for owner in directAttempts.keys {
            let prior = directStates[owner] ?? .init()
            let phase: MutationPhase
            switch prior.phase {
            case .unknown, .conflict: phase = prior.phase
            default: phase = .unknown
            }
            directStates[owner] = .init(phase: phase, readbackCompleted: prior.readbackCompleted, isReadbackLoading: false, message: message, issues: prior.issues)
        }
        if let owner = selectedProposal?.id, let state = directStates[owner] {
            mutationPhase = state.phase
            readbackCompleted = state.readbackCompleted
            recoveryMessage = state.message
        } else if stableAttempt != nil {
            mutationPhase = .idle
            readbackCompleted = false
            recoveryMessage = message
        } else {
            mutationPhase = settingsContractViolation == nil ? .failed(failure) : .idle
            readbackCompleted = false
            recoveryMessage = message
        }
    }

    private func baseWriteReasons() -> [V15DisabledReason] {
        var reasons: [V15DisabledReason] = []
        if isOffline { reasons.append(.init(code: "offline_read_only", message: "离线时只可查看，不能修改。", fieldPath: nil)) }
        if writeLocked { reasons.append(.init(code: "ai_write_in_flight", message: "上一项写操作仍在进行或结果未知。", fieldPath: nil)) }
        if let reason = settingsSafetyReason { reasons.append(reason) }
        else if settings == nil { reasons.append(.init(code: "ai_settings_unavailable", message: settingsLoadFailure?.message ?? "AI 安全设置尚未读取完成。", fieldPath: nil)) }
        return Self.unique(reasons)
    }

    private func createInputChanged() { if stableAttempt == nil { recoveryMessage = nil } }
    private func changeKind(from old: V15ManualTransactionKind) {
        guard !applyingDraft else { return }
        applyingDraft = true
        categoryID = nil
        if !allowedSource(accountID, for: kind) { accountID = nil }
        if !allowedDestination(destinationAccountID, for: kind, sourceID: accountID) { destinationAccountID = nil }
        if kind != .repayment { creditCycleID = nil }
        applyingDraft = false
        editorInputChanged()
    }
    private func editorInputChanged() {
        guard !applyingDraft else { return }
        editorGeneration &+= 1
        if case .reviewing(let owner) = editorMode { confirmedReviews.removeValue(forKey: owner) }
        reviewConfirmed = false; serverIssues = []
    }
    private func allowedSource(_ id: UUID?, for kind: V15ManualTransactionKind) -> Bool {
        guard let id else { return true }; guard let account = activeAccounts.first(where: { $0.id == id }) else { return false }
        switch kind { case .expense, .income, .transfer, .repayment: return account.kind == .cash || account.kind == .debit; case .creditPurchase: return account.kind == .credit }
    }
    private func allowedDestination(_ id: UUID?, for kind: V15ManualTransactionKind, sourceID: UUID?) -> Bool {
        guard let id else { return true }; guard let account = activeAccounts.first(where: { $0.id == id }) else { return false }
        switch kind { case .transfer: return (account.kind == .cash || account.kind == .debit) && id != sourceID; case .repayment: return account.kind == .credit; case .expense, .income, .creditPurchase: return false }
    }
    private func editorFingerprint() -> String? {
        guard case .reviewing = editorMode, let target = selectedProposal?.target, let draft = makeDraft().value?.wireDraft else { return nil }
        return wireFingerprint(target: target, draft: draft)
    }
    private func draftFingerprint(for attempt: DirectAttempt) -> String? {
        guard case .replace(_, let request) = attempt.intent, let proposal = selectedProposal, proposal.id == attempt.proposalID else { return nil }
        return wireFingerprint(target: proposal.target, draft: request.draft)
    }
    private func wireFingerprint(target: V15AIProposalTarget, draft: V15TransactionCreateRequest) -> String {
        "\(target.rawValue)|\(draft.kind.rawValue)|\(draft.amountMinor)|\(draft.occurredAt.timeIntervalSince1970)|\(draft.title)|\(draft.note ?? "")|\(draft.accountID?.uuidString ?? "")|\(draft.categoryID?.uuidString ?? "")|\(draft.destinationAccountID?.uuidString ?? "")|\(draft.creditCycleID?.uuidString ?? "")"
    }
    private func serverFingerprint(_ proposal: V15AIProposal) -> String {
        "\(proposal.target.rawValue)|\(proposal.kind?.rawValue ?? "")|\(proposal.amountMinor ?? -1)|\(proposal.occurredAt?.timeIntervalSince1970 ?? -1)|\(proposal.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")|\(Self.canonicalNote(proposal.note) ?? "")|\(proposal.accountID?.uuidString ?? "")|\(proposal.categoryID?.uuidString ?? "")|\(proposal.destinationAccountID?.uuidString ?? "")|\(proposal.creditCycleID?.uuidString ?? "")"
    }
    private func currentDraftFingerprint(for proposal: V15AIProposal) -> String? {
        guard case .reviewing(let owner) = editorMode, owner == proposal.id, let draft = makeDraft().value?.wireDraft else { return nil }
        return wireFingerprint(target: proposal.target, draft: draft)
    }
    private func matchesConfirmedReview(_ proposal: V15AIProposal) -> Bool {
        guard let confirmed = confirmedReviews[proposal.id], confirmed.proposalID == proposal.id, confirmed.proposalVersion == proposal.version, confirmed.serverFingerprint == serverFingerprint(proposal), confirmed.draftFingerprint == currentDraftFingerprint(for: proposal) else { return false }
        return true
    }
    private func invalidateConfirmationIfStale(_ proposal: V15AIProposal) {
        guard confirmedReviews[proposal.id] != nil, !matchesStoredConfirmation(proposal) else { return }
        confirmedReviews.removeValue(forKey: proposal.id)
        if selectedProposal?.id == proposal.id { reviewConfirmed = false }
    }
    private func matchesStoredConfirmation(_ proposal: V15AIProposal) -> Bool {
        guard let confirmed = confirmedReviews[proposal.id] else { return false }
        return confirmed.proposalID == proposal.id && confirmed.proposalVersion == proposal.version && confirmed.serverFingerprint == serverFingerprint(proposal)
    }
    private func syncConfirmation(for proposal: V15AIProposal) {
        invalidateConfirmationIfStale(proposal)
        if selectedProposal?.id == proposal.id { reviewConfirmed = matchesConfirmedReview(proposal) }
    }
    @discardableResult private func beginReadback(owner: UUID, phase: MutationPhase, message: String) -> UInt64 {
        recoveryGenerations[owner, default: 0] &+= 1
        let generation = recoveryGenerations[owner] ?? 0
        setDirectState(.init(phase: phase, readbackCompleted: false, isReadbackLoading: true, message: message), for: owner)
        return generation
    }
    private func ownsReadback(owner: UUID, attempt: DirectAttempt, generation: UInt64) -> Bool {
        directAttempts[owner] == attempt && recoveryGenerations[owner] == generation
    }
    private func setDirectState(_ state: DirectState, for owner: UUID) {
        directStates[owner] = state
        guard selectedProposal?.id == owner else { return }
        mutationPhase = state.phase; readbackCompleted = state.readbackCompleted; recoveryMessage = state.message; serverIssues = state.issues
    }
    private func restoreOwnerState(for owner: UUID) {
        let state = directStates[owner] ?? .init()
        mutationPhase = state.phase; readbackCompleted = state.readbackCompleted; recoveryMessage = state.message; serverIssues = state.issues; reviewConfirmed = selectedProposal.map(matchesConfirmedReview) ?? false
    }
    private func updateSelectionIfOwned(_ proposal: V15AIProposal, owner: UUID) { if selectedProposal?.id == owner { selectedProposal = proposal; syncConfirmation(for: proposal) } }
    private func replaceListFact(_ proposal: V15AIProposal) { invalidateConfirmationIfStale(proposal); if let index = proposals.firstIndex(where: { $0.id == proposal.id }) { proposals[index] = proposal } else { proposals.insert(proposal, at: 0) } }
    private static func amountText(_ minor: Int64) -> String { String(format: "%.2f", Double(minor) / 100) }
    private static func canonicalNote(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    private static func isSettingsContractViolation(_ failure: V15Failure) -> Bool { failure.code == "ai_settings_contract_violation" }
    private static func reason(_ issue: V15FieldIssue) -> V15DisabledReason { .init(code: issue.code, message: issue.message, fieldPath: issue.fieldPath) }
    private static func unique(_ values: [V15DisabledReason]) -> [V15DisabledReason] { var seen = Set<String>(); return values.filter { seen.insert("\($0.code)|\($0.fieldPath ?? "")").inserted } }
    private static func outcomeMayBeUnknown(_ failure: V15Failure) -> Bool { V15LedgerCreateService.outcomeMayBeUnknown(failure) }
}
