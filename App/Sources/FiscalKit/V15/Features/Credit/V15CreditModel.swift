import Foundation
import Observation

/// F3-B1 keeps credit reading and the P33 schedule command in one isolated
/// model.  It intentionally has no installment lifecycle operations: nested
/// installment periods are facts only until F3-B2 is unlocked.
@MainActor @Observable
public final class V15CreditModel {
    public enum Phase: Equatable { case idle, loading, loaded, empty, failed(V15Failure) }
    public enum DetailPhase: Equatable { case idle, loading, loaded, failed(V15Failure) }
    public enum PagePhase: Equatable { case idle, loading, failed(V15Failure) }
    public enum SchedulePhase: Equatable { case idle, previewing, previewed, committing, succeeded(V15CreditSchedulePreview), unknown, readbackConfirmed, conflict(V15Conflict), failed(V15Failure) }
    /// Readback is deliberately separate from the schedule command phase: an
    /// ambiguous command remains replayable until facts prove its exact intent.
    public enum UnknownReadbackPhase: Equatable { case idle, loading, notConfirmed, confirmed, failed(V15Failure) }

    public private(set) var accounts: [V15CreditAccountSummary] = []
    public private(set) var selectedAccount: V15CreditAccountSummary?
    /// Credit-account summaries deliberately do not leak a generic account
    /// version. P33 requires that version for the mutation, so this is read
    /// from the already typed `/accounts/{id}` fact before previewing.
    public private(set) var selectedAccountVersion: Int?
    public private(set) var cycles: [V15CreditCycle] = []
    public private(set) var selectedCycle: V15CreditCycle?
    public private(set) var cycleTransactions: [V15Transaction] = []
    public private(set) var nextCycleCursor: String?
    public private(set) var nextTransactionCursor: String?
    public private(set) var phase: Phase = .idle
    public private(set) var cycleDetailPhase: DetailPhase = .idle
    public private(set) var cyclePagePhase: PagePhase = .idle
    public private(set) var transactionPagePhase: PagePhase = .idle
    // Command state belongs to the account that created it.  In particular an
    // ambiguous A write must remain recoverable on A without ever becoming B's
    // visible phase, retry key or receipt.
    public var schedulePhase: SchedulePhase { scheduleState.phase }
    public var schedulePreview: V15CreditSchedulePreview? { scheduleState.preview }
    public var scheduleIssues: [V15FieldIssue] { scheduleState.issues }
    public var scheduleServerFieldIssues: [V15FieldIssue] { scheduleState.serverFieldIssues }
    public var scheduleServerReasons: [String] { scheduleState.serverReasons }
    public var scheduleReloadRequired: Bool { scheduleState.reloadRequired }
    public var scheduleReloadError: V15Failure? { scheduleState.reloadError }
    public var unknownReadbackPhase: UnknownReadbackPhase { scheduleState.readbackPhase }
    public var unknownReadbackNotice: String? { scheduleState.readbackNotice }
    /// Kept separate from readback copy: a replay can be blocked by a current
    /// offline snapshot without changing the immutable retry attempt.
    public var unknownRetryNotice: String? { scheduleState.retryNotice }
    public var lastCommitKey: UUID? { scheduleState.lastCommitKey }
    public private(set) var scheduleSheetVisible = false
    public var cycleMode: V15CreditCycleMode = .statementDayCutoff { didSet { scheduleInputChanged() } }
    public var statementDayText = "" { didSet { scheduleInputChanged() } }
    public var dueDayText = "" { didSet { scheduleInputChanged() } }

    private let services: V15Services
    private let now: () -> Date
    private let offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)?
    private let idempotency = V15IdempotencyOwner()
    private var listGeneration: UInt64 = 0
    private var cycleGeneration: UInt64 = 0
    private var cyclePageGeneration: UInt64 = 0
    private var transactionGeneration: UInt64 = 0
    private var transactionPageGeneration: UInt64 = 0
    private var previewGeneration: [UUID: UInt64] = [:]
    private var commitGeneration: [UUID: UInt64] = [:]
    private var unknownReadbackGeneration: [UUID: UInt64] = [:]
    private var isApplyingDraft = false
    private struct UnknownScheduleAttempt: Sendable {
        let accountID: UUID
        let request: V15CreditScheduleChangeCommitRequest
        let payloadIdentity: String
        let idempotencyKey: UUID
    }
    private struct AccountScheduleState {
        var phase: SchedulePhase = .idle
        var preview: V15CreditSchedulePreview?
        var issues: [V15FieldIssue] = []
        var serverFieldIssues: [V15FieldIssue] = []
        var serverReasons: [String] = []
        var reloadRequired = false
        var reloadError: V15Failure?
        var readbackPhase: UnknownReadbackPhase = .idle
        var readbackNotice: String?
        var retryNotice: String?
        var lastCommitKey: UUID?
        var unknownAttempt: UnknownScheduleAttempt?
    }
    private var scheduleStates: [UUID: AccountScheduleState] = [:]
    private var scheduleState: AccountScheduleState { state(for: selectedAccount?.id) }

    public init(services: V15Services, offlineSnapshotAt: Date? = nil, offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)? = nil, now: @escaping () -> Date = { .now }) {
        self.services = services
        self.offlineSnapshotProvider = offlineSnapshotProvider ?? { offlineSnapshotAt ?? services.offlineSnapshotAt }
        self.now = now
    }

    /// Readback must observe a snapshot fallback that occurs after model
    /// creation, not only the value that happened to exist at launch.
    public var offlineSnapshotAt: Date? { offlineSnapshotProvider?() }
    public var isOffline: Bool { offlineSnapshotAt != nil }
    /// A command that is still in flight or response-unknown is not a normal
    /// preview state.  The commit attempt is deliberately cleared once the
    /// server succeeds, before the post-commit fact refresh finishes, so this
    /// gate must inspect the phase as well as any retained unknown attempt.
    public var scheduleCommandDisabledReason: V15DisabledReason? {
        if isCommitting {
            return .init(code: "schedule_command_in_flight", message: "账期变更正在提交/刷新结果，请稍候；此时不能重新预览或重复提交。", fieldPath: nil)
        }
        guard scheduleState.unknownAttempt != nil else { return nil }
        return .init(code: "unknown_schedule_recovery_required", message: "上一笔账期变更结果尚未确认；请安全重试相同操作、刷新账户后核对，或停止检查后刷新账户。", fieldPath: nil)
    }
    /// Preview has a deliberately narrow enablement predicate so ordinary
    /// field validation can still surface its inline reasons.  An unresolved
    /// command and offline mode are the only states that must not dispatch it.
    public var schedulePreviewDisabledReason: V15DisabledReason? {
        if let command = scheduleCommandDisabledReason { return command }
        if isOffline { return .init(code: "offline_read_only", message: "离线时只可查看，无法修改账期。", fieldPath: nil) }
        return nil
    }
    public var canRequestSchedulePreview: Bool { schedulePreviewDisabledReason == nil }
    public var scheduleDisabledReason: V15DisabledReason? {
        if let command = scheduleCommandDisabledReason { return command }
        if isOffline { return .init(code: "offline_read_only", message: "离线时只可查看，无法修改账期。", fieldPath: nil) }
        if scheduleReloadRequired { return .init(code: "reload_required", message: "账期已经更新，请先刷新账户后重新预览。", fieldPath: nil) }
        if let issue = scheduleIssues.first { return .init(code: issue.code, message: issue.message, fieldPath: issue.fieldPath) }
        guard let preview = schedulePreview else { return .init(code: "preview_required", message: "请先查看账期预览后再提交。", fieldPath: nil) }
        guard let token = preview.previewToken else { return .init(code: "preview_token_missing", message: "这个预览暂时不能提交，请重新预览。", fieldPath: nil) }
        guard preview.previewExpiresAt.map({ $0 > now() }) ?? false else { return .init(code: "preview_expired", message: "预览已过期，请重新预览。", fieldPath: nil) }
        guard preview.availableActions.contains("commit_schedule_change") else {
            return .init(code: "server_action_unavailable", message: "本次预览暂时不能提交账期变更。", fieldPath: nil)
        }
        _ = token
        return nil
    }
    public var canCommitSchedule: Bool { scheduleDisabledReason == nil }
    public var isCommitting: Bool { if case .committing = schedulePhase { return true }; return false }
    public var unknownRetryDisabledReason: V15DisabledReason? {
        guard case .unknown = schedulePhase, isOffline else { return nil }
        return .init(code: "offline_read_only", message: "离线时无法检查保存结果。", fieldPath: nil)
    }

    public func load() async {
        listGeneration &+= 1; let current = listGeneration
        invalidateAccountDependentReads()
        let previousAccountID = selectedAccount?.id
        selectedAccountVersion = nil; invalidatePreview(for: previousAccountID, abandonKey: state(for: previousAccountID).unknownAttempt == nil)
        phase = .loading; selectedAccount = nil; cycles = []; selectedCycle = nil; cycleTransactions = []; nextCycleCursor = nil; nextTransactionCursor = nil
        do {
            let values = try await services.credit.accounts()
            guard current == listGeneration else { return }
            accounts = values
            guard let first = values.first else { phase = .empty; return }
            selectedAccount = first
            let master = try await services.masterData.account(id: first.id)
            guard isCurrentList(current, accountID: first.id) else { return }
            selectedAccountVersion = master.version; applyDraft(from: first); phase = .loaded
            await loadCycles(reset: true, generation: current)
        } catch let failure as V15Failure {
            guard current == listGeneration else { return }; phase = failure.kind == .cancelled ? .idle : .failed(failure)
        } catch { guard current == listGeneration else { return }; phase = .failed(.init(kind: .transport, message: "信用账户读取失败。")) }
    }

    public func selectAccount(_ account: V15CreditAccountSummary) async {
        listGeneration &+= 1; let current = listGeneration
        invalidateAccountDependentReads()
        let previousAccountID = selectedAccount?.id
        selectedAccountVersion = nil; invalidatePreview(for: previousAccountID, abandonKey: state(for: previousAccountID).unknownAttempt == nil)
        selectedAccount = account; cycles = []; nextCycleCursor = nil; cyclePagePhase = .idle; selectedCycle = nil; cycleDetailPhase = .idle; cycleTransactions = []; nextTransactionCursor = nil; transactionPagePhase = .idle; applyDraft(from: account)
        do { let master = try await services.masterData.account(id: account.id); guard isCurrentList(current, accountID: account.id) else { return }; selectedAccountVersion = master.version } catch { guard isCurrentList(current, accountID: account.id) else { return }; phase = .failed(.init(kind: .transport, message: "信用账户数据读取失败。")); return }
        await loadCycles(reset: true, generation: current)
    }

    @discardableResult public func reloadSelectedAccount(preservingConflict: Bool = false) async -> Bool {
        guard let id = selectedAccount?.id else { await load(); return !accounts.isEmpty }
        listGeneration &+= 1; let current = listGeneration
        invalidateAccountDependentReads()
        selectedAccountVersion = nil; invalidatePreview(for: id, abandonKey: state(for: id).unknownAttempt == nil, retainPhase: preservingConflict)
        do {
            let account = try await services.credit.account(id: id)
            guard isCurrentList(current, accountID: id) else { return false }
            let master = try await services.masterData.account(id: id)
            guard isCurrentList(current, accountID: id) else { return false }
            selectedAccount = account; selectedAccountVersion = master.version
            if let index = accounts.firstIndex(where: { $0.id == id }) { accounts[index] = account }
            applyDraft(from: account)
            await loadCycles(reset: true, generation: current)
            guard isCurrentList(current, accountID: id) else { return false }
            if state(for: id).reloadRequired {
                mutateScheduleState(for: id) { state in
                    state.reloadRequired = false; state.reloadError = nil
                    if case .conflict = state.phase { state.phase = .idle }
                }
            }
            return current == listGeneration
        } catch let failure as V15Failure {
            guard isCurrentList(current, accountID: id) else { return false }
            if preservingConflict { mutateScheduleState(for: id) { $0.reloadRequired = true; $0.reloadError = failure } }
            else { phase = .failed(failure) }
            return false
        } catch {
            guard isCurrentList(current, accountID: id) else { return false }
            let failure = V15Failure(kind: .transport, message: "信用账户刷新失败。")
            if preservingConflict { mutateScheduleState(for: id) { $0.reloadRequired = true; $0.reloadError = failure } }
            else { phase = .failed(failure) }
            return false
        }
    }

    public func selectAccount(id: UUID) async {
        guard let account = accounts.first(where: { $0.id == id }) else {
            await load()
            return
        }
        await selectAccount(account)
    }

    public func loadNextCycles() async { await loadCycles(reset: false, generation: listGeneration) }
    private func loadCycles(reset: Bool, generation: UInt64) async {
        guard let account = selectedAccount else { return }
        guard isCurrentList(generation, accountID: account.id) else { return }
        guard reset || (nextCycleCursor != nil && cyclePagePhase != .loading) else { return }
        let cursor = reset ? nil : nextCycleCursor
        cyclePageGeneration &+= 1; let ownership = cyclePageGeneration
        guard isCurrentCyclePage(ownership, listGeneration: generation, accountID: account.id) else { return }
        if reset { cycles = []; nextCycleCursor = nil; cyclePagePhase = .idle } else { cyclePagePhase = .loading }
        do {
            let page = try await services.credit.cycles(accountID: account.id, cursor: cursor)
            guard isCurrentCyclePage(ownership, listGeneration: generation, accountID: account.id) else { return }
            cycles = unique(reset ? page.items : cycles + page.items); nextCycleCursor = page.nextCursor; cyclePagePhase = .idle
        } catch let failure as V15Failure {
            guard isCurrentCyclePage(ownership, listGeneration: generation, accountID: account.id) else { return }
            cyclePagePhase = failure.kind == .cancelled ? .idle : .failed(failure)
        } catch { guard isCurrentCyclePage(ownership, listGeneration: generation, accountID: account.id) else { return }; cyclePagePhase = .failed(.init(kind: .transport, message: "下一页账期读取失败。")) }
    }

    public func selectCycle(_ cycle: V15CreditCycle) async {
        guard selectedAccount?.id == cycle.accountID else { return }
        cycleGeneration &+= 1; transactionGeneration &+= 1
        cyclePageGeneration &+= 1; transactionPageGeneration &+= 1
        let current = cycleGeneration; let accountID = cycle.accountID; selectedCycle = nil; cycleTransactions = []; nextTransactionCursor = nil; cycleDetailPhase = .loading; transactionPagePhase = .idle
        do {
            let value = try await services.credit.cycle(id: cycle.id)
            guard current == cycleGeneration, selectedAccount?.id == accountID else { return }
            selectedCycle = value; cycleDetailPhase = .loaded
            await loadNextTransactions(reset: true, generation: transactionGeneration)
        } catch let failure as V15Failure { guard current == cycleGeneration, selectedAccount?.id == accountID else { return }; cycleDetailPhase = failure.kind == .cancelled ? .idle : .failed(failure) }
        catch { guard current == cycleGeneration, selectedAccount?.id == accountID else { return }; cycleDetailPhase = .failed(.init(kind: .transport, message: "账期详情读取失败。")) }
    }

    public func loadNextTransactions() async { await loadNextTransactions(reset: false, generation: transactionGeneration) }
    private func loadNextTransactions(reset: Bool, generation: UInt64) async {
        guard let cycle = selectedCycle else { return }
        guard generation == transactionGeneration, selectedAccount?.id == cycle.accountID else { return }
        guard reset || (nextTransactionCursor != nil && transactionPagePhase != .loading) else { return }
        let cursor = reset ? nil : nextTransactionCursor
        transactionPageGeneration &+= 1; let ownership = transactionPageGeneration
        guard isCurrentTransactionPage(ownership, transactionGeneration: generation, cycleID: cycle.id, accountID: cycle.accountID) else { return }
        if reset { cycleTransactions = []; nextTransactionCursor = nil; transactionPagePhase = .idle } else { transactionPagePhase = .loading }
        do {
            let page = try await services.credit.transactions(cycleID: cycle.id, cursor: cursor)
            guard isCurrentTransactionPage(ownership, transactionGeneration: generation, cycleID: cycle.id, accountID: cycle.accountID) else { return }
            cycleTransactions = uniqueTransactions(reset ? page.items : cycleTransactions + page.items); nextTransactionCursor = page.nextCursor; transactionPagePhase = .idle
        } catch let failure as V15Failure { guard isCurrentTransactionPage(ownership, transactionGeneration: generation, cycleID: cycle.id, accountID: cycle.accountID) else { return }; transactionPagePhase = failure.kind == .cancelled ? .idle : .failed(failure) }
        catch { guard isCurrentTransactionPage(ownership, transactionGeneration: generation, cycleID: cycle.id, accountID: cycle.accountID) else { return }; transactionPagePhase = .failed(.init(kind: .transport, message: "下一页账目读取失败。")) }
    }

    public func openScheduleSheet() {
        guard !isOffline, let accountID = selectedAccount?.id else { return }
        scheduleSheetVisible = true
        mutateScheduleState(for: accountID) { $0.serverReasons = []; $0.serverFieldIssues = [] }
    }
    public func dismissScheduleSheet() {
        scheduleSheetVisible = false
        invalidatePreview(for: selectedAccount?.id, abandonKey: true)
    }
    public func requestSchedulePreview() async {
        guard let account = selectedAccount else { return }
        // This is intentionally before validation and all local mutations:
        // recovery state must stay byte-for-byte visible while a prior command
        // is unresolved, and it must produce zero preview wire traffic.
        guard scheduleCommandDisabledReason == nil else { return }
        guard !isOffline else { mutateScheduleState(for: account.id) { $0.phase = .failed(.init(kind: .offlineReadOnly, code: "offline_read_only", message: "离线时只可查看，无法修改账期。")) }; return }
        guard let request = validRequest(account: account) else { mutateScheduleState(for: account.id) { $0.phase = .idle }; return }
        let current = nextPreviewGeneration(for: account.id)
        mutateScheduleState(for: account.id) { state in state.phase = .previewing; state.preview = nil; state.serverReasons = []; state.serverFieldIssues = [] }
        do {
            let preview = try await services.credit.schedulePreview(accountID: account.id, request: request)
            guard isCurrentPreview(current, accountID: account.id), selectedAccount?.id == account.id, requestIdentity(request) == currentRequestIdentity(account: account) else { return }
            mutateScheduleState(for: account.id) { state in state.preview = preview; state.serverReasons = preview.conflicts + preview.warnings; state.phase = .previewed }
        } catch let failure as V15Failure {
            guard isCurrentPreview(current, accountID: account.id) else { return }
            if failure.kind == .conflict, let conflict = failure.conflict { enterScheduleConflict(conflict, accountID: account.id) }
            else { mutateScheduleState(for: account.id) { state in state.serverFieldIssues = failure.fieldIssues; state.phase = failure.kind == .cancelled ? .idle : .failed(failure) } }
        } catch { guard isCurrentPreview(current, accountID: account.id) else { return }; mutateScheduleState(for: account.id) { $0.phase = .failed(.init(kind: .transport, message: "账期影响预览失败。")) } }
    }

    public func commitSchedule() async {
        guard let account = selectedAccount,
              scheduleDisabledReason == nil,
              let preview = schedulePreview,
              let token = preview.previewToken,
              let request = validRequest(account: account) else { return }
        let identity = requestIdentity(request) + ":" + token.uuidString
        let key = idempotency.key(for: "credit-schedule:\(account.id.uuidString)", payloadIdentity: identity)
        let body = V15CreditScheduleChangeCommitRequest(expectedVersion: request.expectedVersion, cycleMode: request.cycleMode, statementDay: request.statementDay, dueDay: request.dueDay, previewToken: token)
        let attempt = UnknownScheduleAttempt(accountID: account.id, request: body, payloadIdentity: identity, idempotencyKey: key)
        let current = nextCommitGeneration(for: account.id)
        mutateScheduleState(for: account.id) { state in state.lastCommitKey = key; state.phase = .committing; state.unknownAttempt = attempt }
        do {
            let result = try await services.credit.commitSchedule(accountID: account.id, request: body, idempotencyKey: key)
            guard isCurrentCommit(current, accountID: account.id, attempt: attempt) else { return }
            finishScheduleSuccess(result, attempt: attempt)
            if selectedAccount?.id == account.id { _ = await reloadSelectedAccount() }
            guard isCurrentCommit(current, accountID: account.id, attempt: nil) else { return }
            mutateScheduleState(for: account.id) { $0.phase = .succeeded(result) }
        } catch let failure as V15Failure {
            guard isCurrentCommit(current, accountID: account.id, attempt: attempt) else { return }
            if failure.kind == .conflict, let conflict = failure.conflict { mutateScheduleState(for: account.id) { $0.unknownAttempt = nil }; enterScheduleConflict(conflict, accountID: account.id) }
            else if V15LedgerCreateService.outcomeMayBeUnknown(failure) { mutateScheduleState(for: account.id) { $0.preview = nil; $0.phase = .unknown } }
            else { mutateScheduleState(for: account.id) { $0.unknownAttempt = nil; $0.phase = .failed(failure) } }
        } catch { guard isCurrentCommit(current, accountID: account.id, attempt: attempt) else { return }; mutateScheduleState(for: account.id) { $0.preview = nil; $0.phase = .unknown } }
    }

    /// The only legal response-unknown recovery is the same request with the
    /// same idempotency key.  The backend replays its stored P33 result.
    public func retryUnknownCommit() async {
        guard let accountID = selectedAccount?.id,
              case .unknown = schedulePhase,
              !isCommitting,
              let attempt = scheduleState.unknownAttempt,
              attempt.accountID == accountID else { return }
        guard !isOffline else {
            mutateScheduleState(for: accountID) { $0.retryNotice = "离线时无法检查保存结果。" }
            return
        }
        let current = nextCommitGeneration(for: accountID)
        mutateScheduleState(for: accountID) { state in state.phase = .committing; state.lastCommitKey = attempt.idempotencyKey; state.retryNotice = nil }
        do {
            let result = try await services.credit.commitSchedule(accountID: attempt.accountID, request: attempt.request, idempotencyKey: attempt.idempotencyKey)
            guard isCurrentCommit(current, accountID: accountID, attempt: attempt) else { return }
            finishScheduleSuccess(result, attempt: attempt)
            if selectedAccount?.id == attempt.accountID { _ = await reloadSelectedAccount() }
            guard isCurrentCommit(current, accountID: accountID, attempt: nil) else { return }
            mutateScheduleState(for: accountID) { $0.phase = .succeeded(result) }
        } catch let failure as V15Failure {
            guard isCurrentCommit(current, accountID: accountID, attempt: attempt) else { return }
            if failure.kind == .conflict, let conflict = failure.conflict { mutateScheduleState(for: accountID) { $0.unknownAttempt = nil }; enterScheduleConflict(conflict, accountID: accountID) }
            else if V15LedgerCreateService.outcomeMayBeUnknown(failure) { mutateScheduleState(for: accountID) { $0.preview = nil; $0.phase = .unknown } }
            else if failure.kind == .offlineReadOnly {
                mutateScheduleState(for: accountID) { $0.retryNotice = "离线时无法检查保存结果。"; $0.phase = .unknown }
            }
            else { mutateScheduleState(for: accountID) { $0.unknownAttempt = nil; $0.serverFieldIssues = failure.fieldIssues; $0.phase = .failed(failure) } }
        } catch { guard isCurrentCommit(current, accountID: accountID, attempt: attempt) else { return }; mutateScheduleState(for: accountID) { $0.preview = nil; $0.phase = .unknown } }
    }
    /// Deliberately abandoning an ambiguous command is account-scoped and
    /// forces a fresh account read before any new preview/write can begin.
    /// It never turns a response-unknown into a blind new mutation.
    public func abandonUnknownAttempt() {
        guard let accountID = selectedAccount?.id,
              case .unknown = schedulePhase,
              let attempt = scheduleState.unknownAttempt,
              attempt.accountID == accountID else { return }
        idempotency.abandon(scope: "credit-schedule:\(accountID.uuidString)")
        mutateScheduleState(for: accountID) { state in
            state.unknownAttempt = nil; state.preview = nil; state.readbackPhase = .idle
            state.readbackNotice = nil; state.retryNotice = nil; state.reloadRequired = true
            state.reloadError = nil; state.phase = .idle
        }
    }
    /// A response-unknown command may only be resolved by replaying the exact
    /// request or by independently proving that its intended schedule is now
    /// present.  This readback never mutates the displayed draft or abandons
    /// the stored body/key while its GET chain is in flight.
    public func resolveUnknownByReadback() async {
        guard let accountID = selectedAccount?.id,
              case .unknown = schedulePhase,
              let attempt = scheduleState.unknownAttempt,
              attempt.accountID == accountID,
              unknownReadbackPhase != .loading else { return }
        guard offlineSnapshotAt == nil else {
            mutateScheduleState(for: accountID) { $0.readbackNotice = "离线时无法检查最新状态。"; $0.readbackPhase = .notConfirmed }
            return
        }
        let current = nextReadbackGeneration(for: accountID)
        mutateScheduleState(for: accountID) { $0.readbackPhase = .loading; $0.readbackNotice = nil }
        do {
            let account = try await services.credit.account(id: attempt.accountID, readCachePolicy: .reloadIgnoringCache)
            guard isCurrentReadback(current, accountID: accountID, attempt: attempt) else { return }
            let master = try await services.masterData.account(id: attempt.accountID, readCachePolicy: .reloadIgnoringCache)
            guard isCurrentReadback(current, accountID: accountID, attempt: attempt) else { return }
            let cyclePage = try await services.credit.cycles(accountID: attempt.accountID, cursor: nil, readCachePolicy: .reloadIgnoringCache)
            guard isCurrentReadback(current, accountID: accountID, attempt: attempt) else { return }
            let ids = Array(Set([account.currentCycle.id, account.nextDueCycle?.id].compactMap { $0 }))
            let details = try await withThrowingTaskGroup(of: V15CreditCycle.self, returning: [V15CreditCycle].self) { group in
                for id in ids { group.addTask { try await self.services.credit.cycle(id: id, readCachePolicy: .reloadIgnoringCache) } }
                var values: [V15CreditCycle] = []
                for try await value in group { values.append(value) }
                return values
            }
            guard isCurrentReadback(current, accountID: accountID, attempt: attempt) else { return }
            let listedVersions = Dictionary(uniqueKeysWithValues: cyclePage.items.map { ($0.id, $0.version) })
            let detailsAreConsistent = details.count == ids.count && details.allSatisfy {
                $0.accountID == attempt.accountID && listedVersions[$0.id] == $0.version
            }
            // Backend increments account.version exactly once when P33 applies
            // its plan. `>` also remains safe if another server-side change
            // followed before the user could read back.
            let intended = account.cycleMode.rawValue == attempt.request.cycleMode
                && account.statementDay == attempt.request.statementDay
                && account.dueDay == attempt.request.dueDay
                && master.cycleMode == attempt.request.cycleMode
                && master.statementDay == attempt.request.statementDay
                && master.dueDay == attempt.request.dueDay
                && master.version > attempt.request.expectedVersion
                && detailsAreConsistent
            // A successful decode can still be an offline fallback. The
            // snapshot marker is checked after the full fresh-read chain so
            // no snapshot fact can ever confirm an ambiguous write.
            if offlineSnapshotAt != nil {
                mutateScheduleState(for: accountID) { $0.readbackNotice = "离线时无法检查最新状态。"; $0.readbackPhase = .notConfirmed; $0.phase = .unknown }
            } else if intended {
                idempotency.succeeded(scope: "credit-schedule:\(attempt.accountID.uuidString)", payloadIdentity: attempt.payloadIdentity)
                mutateScheduleState(for: accountID) { $0.preview = nil; $0.unknownAttempt = nil; $0.readbackPhase = .confirmed; $0.phase = .readbackConfirmed }
            } else {
                mutateScheduleState(for: accountID) { $0.readbackNotice = nil; $0.readbackPhase = .notConfirmed; $0.phase = .unknown }
            }
        } catch let failure as V15Failure {
            guard isCurrentReadback(current, accountID: accountID, attempt: attempt) else { return }
            mutateScheduleState(for: accountID) { $0.readbackPhase = .failed(failure); $0.phase = .unknown }
        } catch is CancellationError {
            guard isCurrentReadback(current, accountID: accountID, attempt: attempt) else { return }
            mutateScheduleState(for: accountID) { $0.readbackPhase = .failed(.init(kind: .cancelled, message: "账期核对已取消。")); $0.phase = .unknown }
        } catch {
            guard isCurrentReadback(current, accountID: accountID, attempt: attempt) else { return }
            mutateScheduleState(for: accountID) { $0.readbackPhase = .failed(.init(kind: .transport, message: "账期核对失败。")); $0.phase = .unknown }
        }
    }
    public func reloadAfterConflict() async {
        guard let accountID = selectedAccount?.id,
              scheduleReloadRequired || ({ if case .conflict = schedulePhase { return true }; return false }()) else { return }
        let succeeded = await reloadSelectedAccount(preservingConflict: true)
        guard succeeded, selectedAccount?.id == accountID else { return }
        mutateScheduleState(for: accountID) { $0.reloadRequired = false; $0.reloadError = nil; $0.phase = .idle }
    }

    private func scheduleInputChanged() {
        guard !isApplyingDraft else { return }
        validateScheduleInput(); invalidatePreview(for: selectedAccount?.id, abandonKey: true)
    }
    private func validateScheduleInput() {
        var issues: [V15FieldIssue] = []
        if cycleMode == .unknown { issues.append(.init(code: "cycle_mode_invalid", message: "请选择可用的账期方式。", fieldPath: "cycle_mode")) }
        for (text, field, label) in [(statementDayText, "statement_day", "账单日"), (dueDayText, "due_day", "还款日")] {
            guard let day = Int(text), (1...28).contains(day) else { issues.append(.init(code: "day_invalid", message: "\(label)须为 1 到 28 的整数。", fieldPath: field)); continue }
        }
        guard let accountID = selectedAccount?.id else { return }
        mutateScheduleState(for: accountID) { $0.issues = issues }
    }
    private func validRequest(account: V15CreditAccountSummary) -> V15CreditScheduleChangeRequest? {
        validateScheduleInput(); guard scheduleIssues.isEmpty, let statement = Int(statementDayText), let due = Int(dueDayText), cycleMode != .unknown else { return nil }
        guard let accountVersion = selectedAccountVersion else { mutateScheduleState(for: account.id) { $0.issues = [.init(code: "account_version_loading", message: "正在读取账户数据，暂时不能预览。", fieldPath: "expected_version")] }; return nil }
        return .init(expectedVersion: accountVersion, cycleMode: cycleMode.rawValue, statementDay: statement, dueDay: due)
    }
    private func currentRequestIdentity(account: V15CreditAccountSummary) -> String { requestIdentity(.init(expectedVersion: selectedAccountVersion ?? -1, cycleMode: cycleMode.rawValue, statementDay: Int(statementDayText) ?? 0, dueDay: Int(dueDayText) ?? 0)) }
    private func requestIdentity(_ request: V15CreditScheduleChangeRequest) -> String { "\(request.expectedVersion)|\(request.cycleMode)|\(request.statementDay)|\(request.dueDay)" }
    private func applyDraft(from account: V15CreditAccountSummary) { isApplyingDraft = true; cycleMode = account.cycleMode; statementDayText = String(account.statementDay); dueDayText = String(account.dueDay); isApplyingDraft = false; validateScheduleInput() }
    private func finishScheduleSuccess(_ result: V15CreditSchedulePreview, attempt: UnknownScheduleAttempt) {
        idempotency.succeeded(scope: "credit-schedule:\(attempt.accountID.uuidString)", payloadIdentity: attempt.payloadIdentity)
        mutateScheduleState(for: attempt.accountID) { state in
            state.preview = nil; state.unknownAttempt = nil; state.reloadRequired = false; state.reloadError = nil
            state.readbackPhase = .idle; state.readbackNotice = nil; state.retryNotice = nil
        }
    }
    private func enterScheduleConflict(_ conflict: V15Conflict, accountID: UUID) {
        mutateScheduleState(for: accountID) { $0.reloadRequired = true; $0.reloadError = nil; $0.phase = .conflict(conflict) }
        invalidatePreview(for: accountID, abandonKey: true, retainPhase: true)
    }
    private func invalidatePreview(for accountID: UUID?, abandonKey: Bool, retainPhase: Bool = false) {
        guard let accountID else { return }
        _ = nextPreviewGeneration(for: accountID)
        let state = state(for: accountID)
        if abandonKey, state.unknownAttempt == nil { idempotency.abandon(scope: "credit-schedule:\(accountID.uuidString)") }
        mutateScheduleState(for: accountID) { value in
            value.preview = nil; value.serverReasons = []; value.serverFieldIssues = []
            if !retainPhase && !isCommitting(value.phase) { value.phase = value.unknownAttempt == nil ? .idle : .unknown }
        }
    }
    /// An account transition invalidates every nested read before it can clear
    /// or replace state.  The counters are intentionally independent from the
    /// list generation so a next-page request cannot settle over a newer reset.
    private func invalidateAccountDependentReads() {
        cycleGeneration &+= 1
        cyclePageGeneration &+= 1
        transactionGeneration &+= 1
        transactionPageGeneration &+= 1
    }
    private func isCurrentList(_ generation: UInt64, accountID: UUID) -> Bool {
        generation == listGeneration && selectedAccount?.id == accountID
    }
    private func isCurrentCyclePage(_ ownership: UInt64, listGeneration: UInt64, accountID: UUID) -> Bool {
        ownership == cyclePageGeneration && isCurrentList(listGeneration, accountID: accountID)
    }
    private func isCurrentTransactionPage(_ ownership: UInt64, transactionGeneration: UInt64, cycleID: UUID, accountID: UUID) -> Bool {
        ownership == transactionPageGeneration
            && transactionGeneration == self.transactionGeneration
            && selectedAccount?.id == accountID
            && selectedCycle?.id == cycleID
    }
    private func state(for accountID: UUID?) -> AccountScheduleState {
        guard let accountID else { return .init() }
        return scheduleStates[accountID] ?? .init()
    }
    private func mutateScheduleState(for accountID: UUID, _ change: (inout AccountScheduleState) -> Void) {
        var value = state(for: accountID)
        change(&value)
        scheduleStates[accountID] = value
    }
    private func isCommitting(_ phase: SchedulePhase) -> Bool { if case .committing = phase { return true }; return false }
    private func nextPreviewGeneration(for accountID: UUID) -> UInt64 {
        previewGeneration[accountID, default: 0] &+= 1
        return previewGeneration[accountID]!
    }
    private func nextCommitGeneration(for accountID: UUID) -> UInt64 {
        commitGeneration[accountID, default: 0] &+= 1
        return commitGeneration[accountID]!
    }
    private func nextReadbackGeneration(for accountID: UUID) -> UInt64 {
        unknownReadbackGeneration[accountID, default: 0] &+= 1
        return unknownReadbackGeneration[accountID]!
    }
    private func isCurrentPreview(_ generation: UInt64, accountID: UUID) -> Bool {
        previewGeneration[accountID] == generation
    }
    private func isCurrentCommit(_ generation: UInt64, accountID: UUID, attempt: UnknownScheduleAttempt?) -> Bool {
        guard commitGeneration[accountID] == generation else { return false }
        guard let attempt else { return true }
        return state(for: accountID).unknownAttempt?.idempotencyKey == attempt.idempotencyKey
    }
    private func isCurrentReadback(_ generation: UInt64, accountID: UUID, attempt: UnknownScheduleAttempt) -> Bool {
        unknownReadbackGeneration[accountID] == generation
            && state(for: accountID).unknownAttempt?.idempotencyKey == attempt.idempotencyKey
            && ({ if case .unknown = state(for: accountID).phase { return true }; return false }())
    }
    private func unique(_ values: [V15CreditCycle]) -> [V15CreditCycle] { Array(Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }).values).sorted { $0.periodEnd > $1.periodEnd } }
    private func uniqueTransactions(_ values: [V15Transaction]) -> [V15Transaction] { Array(Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }).values) }
}
