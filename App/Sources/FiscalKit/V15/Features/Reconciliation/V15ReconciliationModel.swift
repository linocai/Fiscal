import Foundation
import Observation

/// F3-E is a derived-fact workbench. Checkpoint and attention writes do not
/// have idempotency keys, so an unknown response is never replayed or inferred
/// as success from a later matching row.
@MainActor @Observable
public final class V15ReconciliationModel {
    public enum Phase: Equatable { case idle, loading, loaded, empty, failed(V15Failure) }
    public enum MutationPhase: Equatable { case idle, loading, unknown, conflict(V15Conflict), failed(V15Failure), succeeded }
    public enum MutationIntentKind: Sendable, Equatable { case checkpoint, attentionIgnore }

    public private(set) var masterPhase: Phase = .idle
    public private(set) var checkpointPhase: Phase = .idle
    public private(set) var detailPhase: Phase = .idle
    public private(set) var diagnosisPhase: Phase = .idle
    public private(set) var attentionPhase: Phase = .idle
    public private(set) var mutationPhase: MutationPhase = .idle
    public private(set) var accountTargets: [V15ReconciliationTarget] = []
    public private(set) var cycleTargets: [V15ReconciliationTarget] = []
    public private(set) var selectedTarget: V15ReconciliationTarget?
    public private(set) var checkpoints: [V15ReconciliationCheckpoint] = []
    public private(set) var selectedCheckpoint: V15ReconciliationCheckpoint?
    public private(set) var diagnosis: V15ReconciliationDiagnosis?
    public private(set) var attention: [V15AttentionItem] = []
    public private(set) var serverIssues: [V15FieldIssue] = []
    public private(set) var editorStep = 1
    public private(set) var successMessage: String?
    public private(set) var unknownFactsMessage: String?
    public private(set) var unknownFreshFactsLoaded = false
    public private(set) var acceptedRefreshMessage: String?

    public private(set) var targetKind: V15ReconciliationTargetKind = .account
    public var actualBalanceText = "" { didSet { if oldValue != actualBalanceText { inputChanged(kind: .checkpoint) } } }
    public var asOfDateText = "" { didSet { if oldValue != asOfDateText { inputChanged(kind: .checkpoint, loadDiagnosis: true) } } }
    public var note = "" { didSet { if oldValue != note { inputChanged(kind: .checkpoint) } } }
    public var ignoreUntilDateText = "" { didSet { if oldValue != ignoreUntilDateText { inputChanged(kind: .attentionIgnore) } } }

    private let services: V15Services
    private let now: () -> Date
    private let offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)?
    private var masterGeneration: UInt64 = 0
    private var selectionGeneration: UInt64 = 0
    private var checkpointGeneration: UInt64 = 0
    private var detailGeneration: UInt64 = 0
    private var diagnosisGeneration: UInt64 = 0
    private var attentionGeneration: UInt64 = 0
    private var applyingInput = false

    private struct UnknownAttempt: Sendable, Equatable {
        enum Intent: Sendable, Equatable {
            case checkpoint(target: V15ReconciliationTarget, request: V15ReconciliationCheckpointCreate, prestateIDs: Set<UUID>)
            case ignore(item: V15AttentionItem, request: V15AttentionIgnoreRequest, prestateIDs: Set<String>)
        }
        let operationID: UUID
        let owner: String
        let intent: Intent
        let fingerprint: MutationFormFingerprint
    }
    private enum MutationFormFingerprint: Sendable, Equatable {
        case checkpoint(targetKind: V15ReconciliationTargetKind, targetID: UUID, actualBalanceMinor: Int64, asOfDateText: String, note: String?)
        case ignore(itemID: String, sourceType: String, sourceID: UUID, ignoreUntilDateText: String)
    }
    private struct FailedMutationIntent: Sendable, Equatable {
        let intent: UnknownAttempt.Intent
        let fingerprint: MutationFormFingerprint
        var invalidated: Bool
    }
    private struct AcceptedRefreshGate: Sendable, Equatable {
        enum Intent: Sendable, Equatable { case checkpoint(V15ReconciliationTarget, UUID); case ignore(String) }
        let operationID: UUID
        let intent: Intent
    }
    private var unknownAttempt: UnknownAttempt?
    private var failedMutationIntent: FailedMutationIntent?
    private var acceptedRefreshGate: AcceptedRefreshGate?
    private var activeUnknownAttempt: UnknownAttempt? {
        guard let attempt = unknownAttempt else { return nil }
        switch attempt.intent {
        case .checkpoint(let target, _, _): return selectedTarget?.id == target.id ? attempt : nil
        case .ignore: return attempt
        }
    }
    private var activeFailedMutation: FailedMutationIntent? {
        guard let failed = failedMutationIntent else { return nil }
        switch failed.intent {
        case .checkpoint(let target, _, _): return selectedTarget?.id == target.id ? failed : nil
        case .ignore: return failed
        }
    }
    private var activeFailedIntent: UnknownAttempt.Intent? { activeFailedMutation?.intent }

    public init(services: V15Services, offlineSnapshotAt: Date? = nil, offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)? = nil, now: @escaping () -> Date = { .now }) {
        self.services = services
        self.offlineSnapshotProvider = offlineSnapshotProvider ?? { offlineSnapshotAt ?? services.offlineSnapshotAt }
        self.now = now
        applyingInput = true
        asOfDateText = ShanghaiBusinessDate.string(for: now())
        ignoreUntilDateText = Self.businessDateString(daysFromNow: 1, now: now())
        applyingInput = false
    }

    public var offlineSnapshotAt: Date? { offlineSnapshotProvider?() }
    public var isOffline: Bool { offlineSnapshotAt != nil }
    public var visibleTargets: [V15ReconciliationTarget] { targetKind == .account ? accountTargets : cycleTargets }
    public var writeLocked: Bool { unknownAttempt != nil || acceptedRefreshGate != nil || mutationPhase == .loading }
    public var hasUnknownAttempt: Bool { activeUnknownAttempt != nil && mutationPhase == .unknown }
    public var hasFailedMutation: Bool { activeFailedIntent != nil && mutationPhase.isFailed }
    public var hasAcceptedRefreshGate: Bool { acceptedRefreshGate != nil }
    public var canAbandonUnknown: Bool { hasUnknownAttempt && unknownFreshFactsLoaded }
    public var mutationIntentKind: MutationIntentKind? {
        if let attempt = activeUnknownAttempt { return Self.kind(of: attempt.intent) }
        if let intent = activeFailedIntent { return Self.kind(of: intent) }
        if let gate = acceptedRefreshGate { switch gate.intent { case .checkpoint: return .checkpoint; case .ignore: return .attentionIgnore } }
        return nil
    }
    public var mutationIntentLabel: String {
        switch mutationIntentKind { case .checkpoint: "核对锚点"; case .attentionIgnore: "忽略关注事项"; case nil: "对账写入" }
    }
    public var factRefreshRetryReasons: [V15DisabledReason] {
        var reasons: [V15DisabledReason] = []
        if isOffline { reasons.append(.init(code: "offline_read_only", message: "离线不能刷新最新事实。", fieldPath: nil)) }
        if mutationPhase == .loading { reasons.append(.init(code: "fact_refresh_in_progress", message: "最新事实正在刷新，请勿重复发起。", fieldPath: nil)) }
        return Self.unique(reasons)
    }
    public var failedMutationRetryReasons: [V15DisabledReason] {
        var reasons: [V15DisabledReason] = []
        if isOffline { reasons.append(.init(code: "offline_read_only", message: "离线不能重试写入。", fieldPath: nil)) }
        if acceptedRefreshGate != nil { reasons.append(.init(code: "accepted_refresh_pending", message: "上一笔已接受写入仍在刷新事实，不能开始另一笔写入。", fieldPath: nil)) }
        if mutationPhase == .loading { reasons.append(.init(code: "write_in_progress", message: "操作正在进行。", fieldPath: nil)) }
        guard let failed = activeFailedMutation else {
            reasons.append(.init(code: "mutation_owner_mismatch", message: "请返回该操作所属目标后重试。", fieldPath: nil))
            return Self.unique(reasons)
        }
        if failed.invalidated || currentFingerprint(for: failed.intent) != failed.fingerprint {
            reasons.append(.init(code: "mutation_intent_changed", message: "表单内容已改变；这是新意图，请重新确认后提交。", fieldPath: nil))
        }
        if case .ignore(let item, _, _) = failed.intent, let current = attention.first(where: { $0.id == item.id }) {
            reasons += ignoreReasons(for: current)
        }
        return Self.unique(reasons)
    }

    public var checkpointIssues: [V15FieldIssue] { makeCheckpoint(recording: false).issues }
    public var checkpointReasons: [V15DisabledReason] {
        var reasons = baseWriteReasons()
        reasons += checkpointIssues.map(Self.reason)
        if editorStep < 3 { reasons.append(.init(code: "review_required", message: "请完成目标、余额与确认三个步骤。", fieldPath: nil)) }
        return Self.unique(reasons)
    }
    public var advanceReasons: [V15DisabledReason] {
        if editorStep == 1 { return selectedTarget == nil ? [.init(code: "target_required", message: "请选择账户或信用账期。", fieldPath: "target")] : [] }
        if editorStep == 2 { return checkpointIssues.map(Self.reason) }
        return []
    }
    public var targetChangeReasons: [V15DisabledReason] {
        if acceptedRefreshGate != nil || mutationPhase == .loading { return [.init(code: "write_locked", message: "当前操作尚未完成，请稍候。", fieldPath: nil)] }
        return []
    }
    public var editorOpenReasons: [V15DisabledReason] {
        var reasons: [V15DisabledReason] = []
        if selectedTarget == nil { reasons.append(.init(code: "target_required", message: "请先选择核对目标。", fieldPath: "target")) }
        if isOffline { reasons.append(.init(code: "offline_read_only", message: "离线快照只可查看。", fieldPath: nil)) }
        if acceptedRefreshGate != nil || mutationPhase == .loading { reasons.append(.init(code: "write_locked", message: "当前操作尚未完成，请稍候。", fieldPath: nil)) }
        if unknownAttempt != nil && activeUnknownAttempt == nil { reasons.append(.init(code: "unknown_write_other_owner", message: "另一核对目标有结果未知的写入；请返回原目标处理。", fieldPath: nil)) }
        return Self.unique(reasons)
    }
    public var editorDismissReasons: [V15DisabledReason] {
        mutationPhase == .loading ? [.init(code: "write_in_progress", message: "当前网络操作完成前不能关闭。", fieldPath: nil)] : []
    }

    public func ignoreReasons(for item: V15AttentionItem) -> [V15DisabledReason] {
        var reasons = baseWriteReasons()
        guard let action = item.availableActions.first(where: { $0.action == "ignore" }) else {
            reasons.append(.init(code: "attention_action_unknown", message: "服务端没有提供可安全忽略此事项的能力。", fieldPath: "available_actions"))
            return Self.unique(reasons)
        }
        if !action.enabled {
            reasons.append(.init(code: action.reasonCode ?? "attention_action_unavailable", message: action.reasonMessage ?? "此关注事项当前不可忽略。", fieldPath: "available_actions"))
        }
        if ignoreExpiry() == nil { reasons.append(.init(code: "invalid_attention_expiry", message: "忽略截止日期必须晚于今天，格式为 YYYY-MM-DD。", fieldPath: "expires_at")) }
        return Self.unique(reasons)
    }

    public func load() async {
        masterGeneration &+= 1; let token = masterGeneration
        masterPhase = .loading
        attentionGeneration &+= 1
        async let attentionLoad: Bool = loadAttention(policy: .standard)
        do {
            async let accountsRequest = services.masterData.activeAccounts()
            async let creditRequest = services.credit.accounts()
            let (accounts, creditAccounts) = try await (accountsRequest, creditRequest)
            var cycles: [(V15CreditAccountSummary, V15CreditCycle)] = []
            for account in creditAccounts {
                let page = try await services.credit.cycles(accountID: account.accountID, limit: 100)
                cycles += page.items.map { (account, $0) }
            }
            guard token == masterGeneration else { _ = await attentionLoad; return }
            accountTargets = accounts.filter(\.isActive).map { .init(kind: .account, resourceID: $0.id, label: $0.name, accountID: $0.id) }
            cycleTargets = cycles.map { account, cycle in .init(kind: .creditCycle, resourceID: cycle.id, label: "\(account.name) · \(cycle.statementDate)", accountID: account.accountID) }
            masterPhase = accountTargets.isEmpty && cycleTargets.isEmpty ? .empty : .loaded
            if selectedTarget == nil || !(accountTargets + cycleTargets).contains(where: { $0.id == selectedTarget?.id }) {
                targetKind = accountTargets.isEmpty ? .creditCycle : .account
                if let first = visibleTargets.first { await selectTarget(first) }
            }
        } catch let failure as V15Failure {
            guard token == masterGeneration else { _ = await attentionLoad; return }
            masterPhase = failure.kind == .cancelled ? .idle : .failed(failure)
        } catch {
            guard token == masterGeneration else { _ = await attentionLoad; return }
            masterPhase = .failed(.init(kind: .transport, message: "对账目标读取失败。"))
        }
        _ = await attentionLoad
    }

    public func refresh() async {
        guard !writeLocked else { return }
        await load()
    }

    public func setTargetKind(_ kind: V15ReconciliationTargetKind) async {
        guard targetChangeReasons.isEmpty, targetKind != kind else { return }
        invalidateFailedMutation(kind: .checkpoint)
        targetKind = kind
        invalidateSelection()
        if let first = visibleTargets.first { await selectTarget(first) }
    }

    public func selectTarget(_ target: V15ReconciliationTarget) async {
        guard targetChangeReasons.isEmpty, visibleTargets.contains(where: { $0.id == target.id }) else { return }
        if selectedTarget?.id != target.id { invalidateFailedMutation(kind: .checkpoint) }
        selectionGeneration &+= 1; let owner = selectionGeneration
        selectedTarget = target; selectedCheckpoint = nil; diagnosis = nil; checkpoints = []
        detailPhase = .idle; checkpointPhase = .loading; diagnosisPhase = .loading
        editorStep = 1; successMessage = nil; serverIssues = []
        async let checkpointsLoaded = loadCheckpoints(target: target, selection: owner, policy: .standard)
        async let diagnosisLoaded = loadDiagnosis(target: target, selection: owner, policy: .standard)
        _ = await (checkpointsLoaded, diagnosisLoaded)
    }

    public func selectCheckpoint(_ checkpoint: V15ReconciliationCheckpoint) async {
        guard selectedTarget.map({ Self.checkpoint($0, belongsTo: checkpoint) }) == true else { return }
        selectedCheckpoint = checkpoint
        detailGeneration &+= 1; let token = detailGeneration; let owner = selectedTarget?.id
        detailPhase = .loading
        do {
            let value = try await services.reconciliation.checkpoint(id: checkpoint.id)
            guard token == detailGeneration, owner == selectedTarget?.id else { return }
            selectedCheckpoint = value; detailPhase = .loaded
        } catch let failure as V15Failure {
            guard token == detailGeneration, owner == selectedTarget?.id else { return }
            detailPhase = failure.kind == .cancelled ? .idle : .failed(failure)
        } catch {
            guard token == detailGeneration, owner == selectedTarget?.id else { return }
            detailPhase = .failed(.init(kind: .transport, message: "核对记录详情读取失败。"))
        }
    }

    public func advanceEditor() {
        guard !writeLocked else { return }
        if editorStep == 1, selectedTarget != nil { editorStep = 2 }
        else if editorStep == 2, checkpointIssues.isEmpty { editorStep = 3 }
    }

    public func beginEditor() {
        guard editorOpenReasons.isEmpty else { return }
        // Reopening the sheet for its owner must preserve unresolved recovery.
        if hasUnknownAttempt || hasFailedMutation { return }
        editorStep = 1; serverIssues = []; successMessage = nil; failedMutationIntent = nil
        if case .conflict = mutationPhase {} else { mutationPhase = .idle }
    }

    public func backEditor() { guard !writeLocked else { return }; editorStep = max(1, editorStep - 1) }

    public func createCheckpoint() async {
        let built = makeCheckpoint(recording: true)
        guard checkpointReasons.isEmpty, let request = built.value, let target = selectedTarget, let fingerprint = checkpointFingerprint(), !isOffline else { return }
        let attempt = UnknownAttempt(operationID: UUID(), owner: target.id, intent: .checkpoint(target: target, request: request, prestateIDs: Set(checkpoints.map(\.id))), fingerprint: fingerprint)
        await performCheckpointAttempt(attempt, target: target, request: request)
    }

    private func performCheckpointAttempt(_ attempt: UnknownAttempt, target: V15ReconciliationTarget, request: V15ReconciliationCheckpointCreate) async {
        failedMutationIntent = nil; unknownAttempt = attempt; mutationPhase = .loading; successMessage = nil; unknownFactsMessage = nil; unknownFreshFactsLoaded = false
        do {
            let created = try await services.reconciliation.createCheckpoint(request)
            guard owns(attempt) else { return }
            unknownAttempt = nil; selectedCheckpoint = created; checkpoints.removeAll { $0.id == created.id }; checkpoints.insert(created, at: 0)
            acceptedRefreshGate = .init(operationID: attempt.operationID, intent: .checkpoint(target, created.id))
            await refreshAcceptedFacts()
        } catch let failure as V15Failure {
            guard owns(attempt) else { return }
            serverIssues = failure.fieldIssues
            if V15LedgerCreateService.outcomeMayBeUnknown(failure) {
                mutationPhase = .unknown; unknownFactsMessage = "服务器确认前连接中断或响应不可用。此无键写入不会重发；请只读取最新事实后决定是否解除锁。"
            } else if failure.kind == .conflict {
                unknownAttempt = nil; failedMutationIntent = nil; mutationPhase = .conflict(failure.conflict ?? .init(reloadPath: nil, latestRevision: nil, message: failure.message))
            } else {
                unknownAttempt = nil; failedMutationIntent = .init(intent: attempt.intent, fingerprint: attempt.fingerprint, invalidated: false); mutationPhase = .failed(failure)
            }
        } catch is CancellationError {
            guard owns(attempt) else { return }
            mutationPhase = .unknown; unknownFactsMessage = "任务在服务器响应前取消。写入可能已到达服务器；不会重发，请只读取最新事实。"
        } catch {
            guard owns(attempt) else { return }
            mutationPhase = .unknown; unknownFactsMessage = "写入后的响应不可用。为避免重复提交，本次结果保持未知，只允许fresh GET。"
        }
    }

    public func ignore(_ item: V15AttentionItem) async {
        guard ignoreReasons(for: item).isEmpty, let expiresAt = ignoreExpiry(), !isOffline else { return }
        let fingerprint = ignoreFingerprint(item)
        let request = V15AttentionIgnoreRequest(expiresAt: expiresAt)
        let attempt = UnknownAttempt(operationID: UUID(), owner: item.id, intent: .ignore(item: item, request: request, prestateIDs: Set(attention.map(\.id))), fingerprint: fingerprint)
        await performIgnoreAttempt(attempt, item: item, request: request)
    }

    private func performIgnoreAttempt(_ attempt: UnknownAttempt, item: V15AttentionItem, request: V15AttentionIgnoreRequest) async {
        failedMutationIntent = nil; unknownAttempt = attempt; mutationPhase = .loading; successMessage = nil; unknownFactsMessage = nil; unknownFreshFactsLoaded = false
        do {
            try await services.reconciliation.ignoreAttention(sourceType: item.sourceType, sourceID: item.sourceID, request: request)
            guard owns(attempt) else { return }
            unknownAttempt = nil; acceptedRefreshGate = .init(operationID: attempt.operationID, intent: .ignore(item.id))
            await refreshAcceptedFacts()
        } catch let failure as V15Failure {
            guard owns(attempt) else { return }
            serverIssues = failure.fieldIssues
            if V15LedgerCreateService.outcomeMayBeUnknown(failure) {
                mutationPhase = .unknown; unknownFactsMessage = "忽略请求的响应丢失、取消或不可解析。不会重发；fresh GET 也不能证明是哪次操作造成当前事实。"
            } else if failure.kind == .conflict {
                unknownAttempt = nil; failedMutationIntent = nil; mutationPhase = .conflict(failure.conflict ?? .init(reloadPath: nil, latestRevision: nil, message: failure.message))
            } else {
                unknownAttempt = nil; failedMutationIntent = .init(intent: attempt.intent, fingerprint: attempt.fingerprint, invalidated: false); mutationPhase = .failed(failure)
            }
        } catch is CancellationError {
            guard owns(attempt) else { return }
            mutationPhase = .unknown; unknownFactsMessage = "忽略任务在服务器响应前取消，结果可能已生效。不会重发，只允许fresh GET。"
        } catch {
            guard owns(attempt) else { return }
            mutationPhase = .unknown; unknownFactsMessage = "忽略写入后的响应不可用。为避免重复提交，本次结果保持未知，只允许fresh GET。"
        }
    }

    public func readFreshFactsForUnknown() async {
        guard let attempt = activeUnknownAttempt, mutationPhase == .unknown, !isOffline else { return }
        mutationPhase = .loading; unknownFreshFactsLoaded = false
        do {
            switch attempt.intent {
            case .checkpoint(let target, let request, let before):
                let latest = try await services.reconciliation.checkpoints(target: target, readCachePolicy: .reloadIgnoringCache)
                guard unknownAttempt == attempt else { return }
                if selectedTarget?.id == target.id { checkpoints = latest; checkpointPhase = latest.isEmpty ? .empty : .loaded }
                let newRows = latest.filter { !before.contains($0.id) }
                let matching = newRows.contains { Self.matches($0, request: request) }
                unknownFactsMessage = matching
                    ? "fresh GET 看到了相同的新事实，但响应没有 operation marker，不能归因为本次写入。请人工核对后解除锁。"
                    : "fresh GET 未找到可唯一归因的结果。本次写入仍为未知；解除锁不会重发。"
            case .ignore(let item, _, let before):
                let latest = try await services.reconciliation.attention(readCachePolicy: .reloadIgnoringCache)
                guard unknownAttempt == attempt else { return }
                attention = latest.items; attentionPhase = latest.items.isEmpty ? .empty : .loaded
                let wasPresent = before.contains(item.id); let isPresent = latest.items.contains { $0.id == item.id }
                unknownFactsMessage = wasPresent && !isPresent
                    ? "fresh GET 中该事项已不可见，但没有 operation marker，不能归因为本次忽略。请核对后解除锁。"
                    : "fresh GET 仍显示该事项或无法证明本次结果；不会自动重发。"
            }
            guard unknownAttempt == attempt else { return }
            unknownFreshFactsLoaded = true; mutationPhase = .unknown
        } catch let failure as V15Failure {
            guard unknownAttempt == attempt else { return }
            mutationPhase = .unknown; unknownFactsMessage = "fresh GET 失败：\(failure.message)；写入仍保持锁定。"
        } catch {
            guard unknownAttempt == attempt else { return }
            mutationPhase = .unknown; unknownFactsMessage = "fresh GET 失败；写入仍保持锁定。"
        }
    }

    public func abandonUnknown() {
        guard canAbandonUnknown else { return }
        guard let attempt = activeUnknownAttempt, owns(attempt) else { return }
        unknownAttempt = nil; unknownFreshFactsLoaded = false; unknownFactsMessage = nil; mutationPhase = .idle; serverIssues = []
    }

    public func retryDeterministicMutation() async {
        guard case .failed = mutationPhase, let failed = activeFailedMutation, failedMutationRetryReasons.isEmpty else { return }
        guard currentFingerprint(for: failed.intent) == failed.fingerprint else {
            invalidateFailedMutation(kind: Self.kind(of: failed.intent))
            return
        }
        switch failed.intent {
        case .checkpoint(let target, let request, _):
            guard selectedTarget?.id == target.id else { return }
            let attempt = UnknownAttempt(operationID: UUID(), owner: target.id, intent: .checkpoint(target: target, request: request, prestateIDs: Set(checkpoints.map(\.id))), fingerprint: failed.fingerprint)
            await performCheckpointAttempt(attempt, target: target, request: request)
        case .ignore(let item, let request, _):
            guard let current = attention.first(where: { $0.id == item.id }) else { return }
            let attempt = UnknownAttempt(operationID: UUID(), owner: current.id, intent: .ignore(item: current, request: request, prestateIDs: Set(attention.map(\.id))), fingerprint: failed.fingerprint)
            await performIgnoreAttempt(attempt, item: current, request: request)
        }
    }

    public func retryAcceptedRefresh() async {
        guard acceptedRefreshGate != nil, factRefreshRetryReasons.isEmpty else { return }
        await refreshAcceptedFacts()
    }

    public func reloadAfterConflict() async {
        guard case .conflict = mutationPhase else { return }
        mutationPhase = .idle; failedMutationIntent = nil; serverIssues = []
        if let target = selectedTarget { selectionGeneration &+= 1; let owner = selectionGeneration; async let a = loadCheckpoints(target: target, selection: owner, policy: .reloadIgnoringCache); async let b = loadDiagnosis(target: target, selection: owner, policy: .reloadIgnoringCache); async let c = loadAttention(policy: .reloadIgnoringCache); _ = await (a, b, c) }
    }

    public func refreshAttention() async { attentionGeneration &+= 1; _ = await loadAttention(policy: .standard) }

    private func refreshAcceptedFacts() async {
        guard let gate = acceptedRefreshGate else { return }
        mutationPhase = .loading; acceptedRefreshMessage = nil
        let ok: Bool
        switch gate.intent {
        case .checkpoint(let target, let checkpointID):
            selectionGeneration &+= 1; let owner = selectionGeneration
            async let checkpointsOK = loadCheckpoints(target: target, selection: owner, policy: .reloadIgnoringCache)
            async let diagnosisOK = loadDiagnosis(target: target, selection: owner, policy: .reloadIgnoringCache)
            async let attentionOK = loadAttention(policy: .reloadIgnoringCache)
            let values = await (checkpointsOK, diagnosisOK, attentionOK)
            var detailOK = false
            if let refreshed = checkpoints.first(where: { $0.id == checkpointID }) { await selectCheckpoint(refreshed); detailOK = detailPhase == .loaded }
            ok = values.0 && values.1 && values.2 && detailOK
        case .ignore:
            ok = await loadAttention(policy: .reloadIgnoringCache)
        }
        guard acceptedRefreshGate == gate else { return }
        if ok {
            acceptedRefreshGate = nil; mutationPhase = .succeeded
            switch gate.intent { case .checkpoint: successMessage = "核对记录已保存，详情、差额诊断与关注事项均已刷新。"; case .ignore: successMessage = "关注事项已按指定截止时间忽略，列表已刷新。" }
        } else {
            mutationPhase = .failed(.init(kind: .transport, code: "accepted_refresh_failed", message: "写入已被服务器接受，但最新事实尚未全部刷新。"))
            acceptedRefreshMessage = "只会重试 GET；不会再次提交刚才的写入。"
        }
    }

    private func loadCheckpoints(target: V15ReconciliationTarget, selection: UInt64, policy: V15ReadCachePolicy) async -> Bool {
        checkpointGeneration &+= 1; let token = checkpointGeneration
        guard selectedTarget?.id == target.id, selection == selectionGeneration else { return false }
        checkpointPhase = .loading
        do {
            let values = try await services.reconciliation.checkpoints(target: target, readCachePolicy: policy)
            guard token == checkpointGeneration, selection == selectionGeneration, selectedTarget?.id == target.id else { return false }
            checkpoints = values; checkpointPhase = values.isEmpty ? .empty : .loaded
            if let selectedCheckpoint, !values.contains(where: { $0.id == selectedCheckpoint.id }) { self.selectedCheckpoint = nil; detailPhase = .idle }
            return true
        } catch let failure as V15Failure {
            guard token == checkpointGeneration, selection == selectionGeneration, selectedTarget?.id == target.id else { return false }
            checkpointPhase = failure.kind == .cancelled ? .idle : .failed(failure); return false
        } catch {
            guard token == checkpointGeneration, selection == selectionGeneration, selectedTarget?.id == target.id else { return false }
            checkpointPhase = .failed(.init(kind: .transport, message: "核对记录读取失败。")); return false
        }
    }

    private func loadDiagnosis(target: V15ReconciliationTarget, selection: UInt64, policy: V15ReadCachePolicy) async -> Bool {
        diagnosisGeneration &+= 1; let token = diagnosisGeneration
        guard selectedTarget?.id == target.id, selection == selectionGeneration else { return false }
        let dateInputOwner = asOfDateText
        guard let asOf = asOfInstant() else { diagnosis = nil; diagnosisPhase = .empty; return false }
        diagnosisPhase = .loading
        do {
            let value = try await services.reconciliation.diagnosis(target: target, asOf: asOf, readCachePolicy: policy)
            guard token == diagnosisGeneration, selection == selectionGeneration, selectedTarget?.id == target.id, dateInputOwner == asOfDateText else { return false }
            diagnosis = value; diagnosisPhase = .loaded; return true
        } catch let failure as V15Failure {
            guard token == diagnosisGeneration, selection == selectionGeneration, selectedTarget?.id == target.id else { return false }
            if failure.kind == .conflict { diagnosisPhase = .failed(failure); mutationPhase = .conflict(failure.conflict ?? .init(reloadPath: nil, latestRevision: nil, message: failure.message)) }
            else { diagnosisPhase = failure.kind == .cancelled ? .idle : .failed(failure) }
            return false
        } catch {
            guard token == diagnosisGeneration, selection == selectionGeneration, selectedTarget?.id == target.id else { return false }
            diagnosisPhase = .failed(.init(kind: .transport, message: "差额诊断读取失败。")); return false
        }
    }

    private func loadAttention(policy: V15ReadCachePolicy) async -> Bool {
        attentionGeneration &+= 1; let token = attentionGeneration
        attentionPhase = .loading
        do {
            let value = try await services.reconciliation.attention(readCachePolicy: policy)
            guard token == attentionGeneration else { return false }
            attention = value.items; attentionPhase = value.items.isEmpty ? .empty : .loaded; return true
        } catch let failure as V15Failure {
            guard token == attentionGeneration else { return false }
            attentionPhase = failure.kind == .cancelled ? .idle : .failed(failure); return false
        } catch {
            guard token == attentionGeneration else { return false }
            attentionPhase = .failed(.init(kind: .transport, message: "关注事项读取失败。")); return false
        }
    }

    private func inputChanged(kind: MutationIntentKind, loadDiagnosis shouldReloadDiagnosis: Bool = false) {
        guard !applyingInput else { return }
        serverIssues = []
        if mutationPhase == .succeeded { mutationPhase = .idle; successMessage = nil }
        invalidateFailedMutation(kind: kind)
        if shouldReloadDiagnosis, let target = selectedTarget, unknownAttempt == nil, acceptedRefreshGate == nil {
            let owner = selectionGeneration
            Task { await self.loadDiagnosis(target: target, selection: owner, policy: .standard) }
        }
    }

    private func makeCheckpoint(recording: Bool) -> (value: V15ReconciliationCheckpointCreate?, issues: [V15FieldIssue]) {
        var issues: [V15FieldIssue] = []
        guard let target = selectedTarget else { return (nil, [.init(code: "target_required", message: "请选择账户或信用账期。", fieldPath: "target")]) }
        guard let amount = CNYAmountParser.minorUnits(actualBalanceText) else { return (nil, [.init(code: "actual_balance_invalid", message: "实际余额须为最多两位小数的人民币金额，可为负数或零。", fieldPath: "actual_balance_minor")]) }
        guard let asOf = asOfInstant() else { return (nil, [.init(code: "as_of_invalid", message: "核对日期须为今天或更早的有效 YYYY-MM-DD。", fieldPath: "as_of")]) }
        if note.count > 500 { issues.append(.init(code: "note_too_long", message: "备注最多 500 个字符。", fieldPath: "note")) }
        if !issues.isEmpty { return (nil, issues) }
        let request = V15ReconciliationCheckpointCreate(targetKind: target.kind, accountID: target.kind == .account ? target.resourceID : nil, creditCycleID: target.kind == .creditCycle ? target.resourceID : nil, asOf: asOf, actualBalanceMinor: amount, note: note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        return (request, [])
    }

    private func checkpointFingerprint() -> MutationFormFingerprint? {
        guard let target = selectedTarget, let amount = CNYAmountParser.minorUnits(actualBalanceText) else { return nil }
        return .checkpoint(
            targetKind: target.kind,
            targetID: target.resourceID,
            actualBalanceMinor: amount,
            asOfDateText: asOfDateText,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    private func ignoreFingerprint(_ item: V15AttentionItem) -> MutationFormFingerprint {
        .ignore(itemID: item.id, sourceType: item.sourceType, sourceID: item.sourceID, ignoreUntilDateText: ignoreUntilDateText)
    }

    private func currentFingerprint(for intent: UnknownAttempt.Intent) -> MutationFormFingerprint? {
        switch intent {
        case .checkpoint: return checkpointFingerprint()
        case .ignore(let item, _, _):
            guard let current = attention.first(where: { $0.id == item.id }) else { return nil }
            return ignoreFingerprint(current)
        }
    }

    private func invalidateFailedMutation(kind: MutationIntentKind) {
        guard var failed = failedMutationIntent, Self.kind(of: failed.intent) == kind else { return }
        failed.invalidated = true
        failedMutationIntent = failed
        if kind == .checkpoint { editorStep = min(editorStep, 2) }
    }

    private func asOfInstant() -> Date? { Self.asOfInstant(asOfDateText, now: now()) }
    private func ignoreExpiry() -> Date? { Self.ignoreExpiry(ignoreUntilDateText, now: now()) }
    private func baseWriteReasons() -> [V15DisabledReason] {
        var reasons: [V15DisabledReason] = []
        if isOffline { reasons.append(.init(code: "offline_read_only", message: "离线快照仅可查看，不能写入。", fieldPath: nil)) }
        if unknownAttempt != nil { reasons.append(.init(code: "unknown_write_locked", message: "上一笔无键写入结果未知，请先核对并解除锁。", fieldPath: nil)) }
        if acceptedRefreshGate != nil { reasons.append(.init(code: "accepted_refresh_pending", message: "上一笔写入已接受，最新事实尚未刷新完成。", fieldPath: nil)) }
        if mutationPhase == .loading { reasons.append(.init(code: "write_in_progress", message: "操作正在进行。", fieldPath: nil)) }
        return Self.unique(reasons)
    }

    private func invalidateSelection() {
        selectionGeneration &+= 1; checkpointGeneration &+= 1; detailGeneration &+= 1; diagnosisGeneration &+= 1
        selectedTarget = nil; checkpoints = []; selectedCheckpoint = nil; diagnosis = nil
        checkpointPhase = .idle; detailPhase = .idle; diagnosisPhase = .idle; editorStep = 1; serverIssues = []
    }

    private static func checkpoint(_ target: V15ReconciliationTarget, belongsTo checkpoint: V15ReconciliationCheckpoint) -> Bool {
        target.kind == checkpoint.targetKind && (target.kind == .account ? checkpoint.accountID == target.resourceID : checkpoint.creditCycleID == target.resourceID)
    }

    private static func matches(_ checkpoint: V15ReconciliationCheckpoint, request: V15ReconciliationCheckpointCreate) -> Bool {
        checkpoint.targetKind == request.targetKind && checkpoint.accountID == request.accountID && checkpoint.creditCycleID == request.creditCycleID && checkpoint.asOf == request.asOf && checkpoint.actualBalanceMinor == request.actualBalanceMinor && checkpoint.note == request.note
    }

    private func owns(_ attempt: UnknownAttempt) -> Bool {
        unknownAttempt?.operationID == attempt.operationID && unknownAttempt?.owner == attempt.owner
    }

    private static func kind(of intent: UnknownAttempt.Intent) -> MutationIntentKind {
        switch intent { case .checkpoint: .checkpoint; case .ignore: .attentionIgnore }
    }

    private static func reason(_ issue: V15FieldIssue) -> V15DisabledReason { .init(code: issue.code, message: issue.message, fieldPath: issue.fieldPath) }
    private static func unique(_ values: [V15DisabledReason]) -> [V15DisabledReason] { values.reduce(into: []) { result, value in if !result.contains(where: { $0.code == value.code && $0.fieldPath == value.fieldPath }) { result.append(value) } } }

    private static func calendar() -> Calendar { var value = Calendar(identifier: .gregorian); value.locale = Locale(identifier: "zh_CN"); value.timeZone = ShanghaiBusinessDate.timeZone; return value }
    private static func parsedBusinessDate(_ text: String) -> Date? {
        guard text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = ShanghaiBusinessDate.timeZone; formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        return formatter.date(from: text)
    }
    private static func asOfInstant(_ text: String, now: Date) -> Date? {
        guard let day = parsedBusinessDate(text) else { return nil }
        let calendar = calendar(); let today = calendar.startOfDay(for: now)
        guard day <= today else { return nil }
        if day == today { return now }
        return calendar.date(byAdding: .second, value: -1, to: calendar.date(byAdding: .day, value: 1, to: day)!)
    }
    private static func ignoreExpiry(_ text: String, now: Date) -> Date? {
        guard let day = parsedBusinessDate(text) else { return nil }
        let expiry = calendar().date(byAdding: .day, value: 1, to: day)!
        return expiry > now ? expiry : nil
    }
    private static func businessDateString(daysFromNow: Int, now: Date) -> String { ShanghaiBusinessDate.string(for: calendar().date(byAdding: .day, value: daysFromNow, to: now) ?? now) }
}

private extension V15ReconciliationModel.MutationPhase {
    var isFailed: Bool { if case .failed = self { true } else { false } }
}

private extension String {
    var nilIfEmpty: String? { let value = trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? nil : value }
}
