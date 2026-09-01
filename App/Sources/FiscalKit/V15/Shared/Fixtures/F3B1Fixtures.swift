import Foundation
import Observation

/// Synthetic P33 facts only.  They intentionally contain no account tail,
/// receipt, provider or production identifiers.
public enum V15F3B1Fixtures {
    public static let accountID = UUID(uuidString: "00000000-0000-0000-0000-00000000B311")!
    public static let secondAccountID = UUID(uuidString: "00000000-0000-0000-0000-00000000B312")!
    public static let cycleID = UUID(uuidString: "00000000-0000-0000-0000-00000000B321")!
    public static let openingCycleID = UUID(uuidString: "00000000-0000-0000-0000-00000000B322")!
    public static let secondCycleID = UUID(uuidString: "00000000-0000-0000-0000-00000000B323")!
    public static let secondOpeningCycleID = UUID(uuidString: "00000000-0000-0000-0000-00000000B324")!
    public static let token = UUID(uuidString: "00000000-0000-0000-0000-00000000B331")!
    @MainActor public static func services(route: String = "credit", offlineSnapshotMarker: F3B1OfflineSnapshotMarker? = nil) -> V15Services {
        let offlineMarker = offlineSnapshotMarker ?? F3B1OfflineSnapshotMarker()
        return .init(
            transport: F3B1Transport(mode: .route(route), offlineSnapshotMarker: offlineMarker),
            offlineSnapshotProvider: { offlineMarker.snapshotAt }
        )
    }

    static func account(_ id: UUID = accountID, name: String = "日常信用账户", scheduleApplied: Bool = false) -> String {
        let isSecond = id == secondAccountID
        let statementDay = scheduleApplied ? 25 : (isSecond ? 18 : 20); let dueDay = scheduleApplied ? 10 : (isSecond ? 3 : 5); let cycleMode = scheduleApplied ? "statement_day_cutoff" : "previous_calendar_month"
        return """
    {"account_id":"\(id.uuidString)","name":"\(name)","institution":"示例机构","last_four":null,"credit_limit_minor":500000,"current_debt_minor":128000,"available_credit_minor":372000,"over_limit_minor":0,"opening_configuration_required":false,"statement_day":\(statementDay),"due_day":\(dueDay),"cycle_mode":"\(cycleMode)","current_cycle":\(cycle(currentCycleID(for: id), accountID: id, opening: false, overdue: false, status: "open")),"next_due_cycle":\(cycle(openingCycleID(for: id), accountID: id, opening: true, overdue: true, status: "overdue")),"has_overdue_cycle":true,"active_installment_count":1,"future_scheduled_gross_minor":12000,"next_installment":null}
    """ }
    static func currentCycleID(for accountID: UUID) -> UUID { accountID == secondAccountID ? secondCycleID : cycleID }
    static func openingCycleID(for accountID: UUID) -> UUID { accountID == secondAccountID ? secondOpeningCycleID : openingCycleID }
    static func cycle(_ id: UUID, accountID: UUID = V15F3B1Fixtures.accountID, opening: Bool, overdue: Bool, status: String) -> String { """
    {"id":"\(id.uuidString)","account_id":"\(accountID.uuidString)","period_start":"2026-08-01","period_end":"2026-08-31","statement_date":"2026-08-20","due_date":"2026-09-05","is_opening_cycle":\(opening),"purchase_minor":125000,"opening_minor":\(opening ? 3000 : 0),"amount_due_minor":128000,"repaid_minor":0,"remaining_minor":128000,"status":"\(status)","is_overdue":\(overdue),"version":2,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-15T00:00:00Z","installment_principal_minor":10000,"installment_fee_minor":2000,"installment_periods":[]}
    """ }
    static func masterAccount(_ id: UUID = accountID, version: Int = 4, scheduleApplied: Bool = false) -> String {
        let isSecond = id == secondAccountID
        let statementDay = scheduleApplied ? 25 : (isSecond ? 18 : 20); let dueDay = scheduleApplied ? 10 : (isSecond ? 3 : 5); let cycleMode = scheduleApplied ? "statement_day_cutoff" : "previous_calendar_month"
        return """
    {"id":"\(id.uuidString)","name":"日常信用账户","kind":"credit","institution":"示例机构","last_four":null,"opening_balance_minor":0,"current_balance_minor":-128000,"credit_limit_minor":500000,"statement_day":\(statementDay),"due_day":\(dueDay),"cycle_mode":"\(cycleMode)","opening_balance_as_of_date":null,"opening_due_date":null,"sort_order":0,"archived_at":null,"usage_count":2,"version":\(version),"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-15T00:00:00Z"}
    """ }
    static func cyclePage(accountID: UUID, cursor: String? = "opaque-credit-next") -> String {
        let encodedCursor = cursor.map { "\"\($0)\"" } ?? "null"
        let current = cycle(currentCycleID(for: accountID), accountID: accountID, opening: false, overdue: false, status: "open")
        let opening = cycle(openingCycleID(for: accountID), accountID: accountID, opening: true, overdue: true, status: "overdue")
        return "{\"items\":[\(current),\(opening)],\"next_cursor\":\(encodedCursor)}"
    }
    static func preview(accountID: UUID = V15F3B1Fixtures.accountID, expires: String = "2030-08-15T16:10:00Z", actions: String = "[\"commit_schedule_change\"]") -> String { """
    {"account_id":"\(accountID.uuidString)","cycle_mode":"statement_day_cutoff","statement_day":25,"due_day":10,"old_cycle_mode":"previous_calendar_month","old_statement_day":20,"old_due_day":5,"affected_cycle_count":2,"purchase_count":2,"repayment_count":1,"installment_period_count":1,"affected_cycles":[{"cycle_id":"\(currentCycleID(for: accountID).uuidString)","current_version":2,"expected_version":2,"old_statement_date":"2026-08-20","old_due_date":"2026-09-05","new_statement_date":"2026-08-25","new_due_date":"2026-09-10","remaining_minor":128000,"old_is_overdue":false,"new_is_overdue":false}],"old_overdue_cycle_count":1,"new_overdue_cycle_count":0,"conflicts":[],"preview_token":"\(token.uuidString)","preview_expires_at":"\(expires)","current_account_version":\(accountID == secondAccountID ? 7 : 4),"expected_account_version":\(accountID == secondAccountID ? 7 : 4),"warnings":["账期将重新分配。"],"available_actions":\(actions),"data_revision":8}
    """ }
}

/// A fixture transport can set this during an awaited GET to model a decoded
/// offline fallback. It intentionally follows the production model's dynamic
/// snapshot-provider shape instead of baking a launch-time boolean into views.
@MainActor @Observable public final class F3B1OfflineSnapshotMarker {
    var snapshotAt: Date?
}

actor F3B1Transport: V15Transporting {
    enum Mode: Equatable { case normal, previewExpired, previewDisabled, previewFieldError, previewConflict, commitConflict, commitConflictThenSuccess, commitUnknownThenSuccess, commitUnknownThenExpired, commitUnknownReadbackFails, commitUnknownReadbackOldState, commitUnknownReadbackMatches, commitUnknownReadbackFresh, commitUnknownReadbackOfflineFallback, commitUnknownReadbackDelayed, commitUnknownOfflineRecovery, commitUnknownRetryOffline, commitUnknownReplayDelayed, commitDelayedSuccess, commitDelayedConflict, commitDelayedFailure, commitDelayedUnknown, commitSuccessPostReloadDelayed, commitUnknownReplayPostReloadDelayed, reloadFailsOnceAfterConflict, cyclePageFailure, transactionPageFailure, masterSelectionRace, cyclesSelectionRace, refreshLoadSelectionRace
        static func route(_ route: String) -> Mode { switch route { case "credit-expired": .previewExpired; case "credit-disabled": .previewDisabled; case "credit-field-error": .previewFieldError; case "credit-preview-conflict": .previewConflict; case "credit-conflict": .commitConflict; case "credit-conflict-once": .commitConflictThenSuccess; case "credit-reload-fails": .reloadFailsOnceAfterConflict; case "credit-post-success-reload": .commitSuccessPostReloadDelayed; case "credit-unknown", "credit-account-unknown": .commitUnknownThenSuccess; case "credit-unknown-post-success-reload": .commitUnknownReplayPostReloadDelayed; case "credit-unknown-readback-fails": .commitUnknownReadbackFails; case "credit-unknown-readback-old": .commitUnknownReadbackOldState; case "credit-unknown-readback-match": .commitUnknownReadbackMatches; case "credit-unknown-readback-offline": .commitUnknownReadbackOfflineFallback; case "credit-unknown-offline-recovery": .commitUnknownOfflineRecovery; case "credit-account-race": .masterSelectionRace; case "credit-page-error": .cyclePageFailure; case "credit-transaction-error": .transactionPageFailure; default: .normal } }
    }
    struct CommitWire: Sendable, Equatable { let idempotencyKey: String; let body: String }
    let mode: Mode; private let offlineSnapshotMarker: F3B1OfflineSnapshotMarker?; private var requests: [V15Request] = []; private var commits: [CommitWire] = []; private var commitAttempts = 0; private var reloadAttempts = 0; private var unknownReadbackRequests = 0; private var accountListRequests = 0; private var cycleListRequests = 0
    init(mode: Mode, offlineSnapshotMarker: F3B1OfflineSnapshotMarker? = nil) { self.mode = mode; self.offlineSnapshotMarker = offlineSnapshotMarker }
    func allRequests() -> [V15Request] { requests }
    func commitWires() -> [CommitWire] { commits }
    func readbackRequestCount() -> Int { unknownReadbackRequests }
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        requests.append(request)
        let decode: (String) throws -> Response = { try V15FixtureCodec.decoder.decode(Response.self, from: Data($0.utf8)) }
        switch (request.path, request.method) {
        case ("credit-accounts", "GET"):
            accountListRequests += 1
            if mode == .refreshLoadSelectionRace, accountListRequests > 1 { try await Task.sleep(for: .milliseconds(120)) }
            let secondary = V15F3B1Fixtures.account(V15F3B1Fixtures.secondAccountID, name: "旅行信用账户")
            // The matching-readback route starts from the same client intent
            // shape while the master version still advances only after its
            // ambiguous command. This lets the UI exercise confirmation
            // without relying on a picker-control implementation detail.
            let primary = V15F3B1Fixtures.account(scheduleApplied: mode == .commitUnknownReadbackMatches)
            return try decode("[\(primary),\(secondary)]")
        case ("accounts/\(V15F3B1Fixtures.accountID)", "GET"):
            if mode == .masterSelectionRace { try await Task.sleep(for: .milliseconds(120)) }
            reloadAttempts += 1
            if mode == .reloadFailsOnceAfterConflict, reloadAttempts == 2 { throw V15Failure(kind: .transport, message: "账户版本刷新失败。") }
            let freshServerRead = request.readCachePolicy == .reloadIgnoringCache
            let applied = (mode == .commitUnknownReadbackMatches || ((mode == .commitUnknownReadbackFresh || mode == .commitUnknownReadbackOfflineFallback) && freshServerRead)) && commitAttempts > 0
            return try decode(V15F3B1Fixtures.masterAccount(version: applied ? 5 : 4, scheduleApplied: applied))
        case ("accounts/\(V15F3B1Fixtures.secondAccountID)", "GET"): return try decode(V15F3B1Fixtures.masterAccount(V15F3B1Fixtures.secondAccountID, version: 7))
        case ("credit-accounts/\(V15F3B1Fixtures.accountID)", "GET"):
            if mode == .refreshLoadSelectionRace { try await Task.sleep(for: .milliseconds(120)) }
            unknownReadbackRequests += 1
            if mode == .commitUnknownReadbackFails { throw V15Failure(kind: .transport, message: "账户核对读取失败。") }
            if mode == .commitUnknownReadbackDelayed { try await Task.sleep(for: .milliseconds(120)) }
            if mode == .commitUnknownReadbackOfflineFallback, commitAttempts > 0 {
                await MainActor.run { self.offlineSnapshotMarker?.snapshotAt = Date(timeIntervalSince1970: 1_786_464_000) }
            }
            let freshServerRead = request.readCachePolicy == .reloadIgnoringCache
            let applied = (mode == .commitUnknownReadbackMatches || ((mode == .commitUnknownReadbackFresh || mode == .commitUnknownReadbackOfflineFallback) && freshServerRead)) && commitAttempts > 0
            return try decode(V15F3B1Fixtures.account(scheduleApplied: applied))
        case ("credit-accounts/\(V15F3B1Fixtures.secondAccountID)", "GET"): return try decode(V15F3B1Fixtures.account(V15F3B1Fixtures.secondAccountID, name: "旅行信用账户"))
        case ("credit-accounts/\(V15F3B1Fixtures.accountID)/cycles", "GET"), ("credit-accounts/\(V15F3B1Fixtures.secondAccountID)/cycles", "GET"):
            cycleListRequests += 1
            if mode == .cyclesSelectionRace, request.path.contains(V15F3B1Fixtures.accountID.uuidString), cycleListRequests > 1 { try await Task.sleep(for: .milliseconds(120)) }
            if [Mode.commitSuccessPostReloadDelayed, .commitUnknownReplayPostReloadDelayed].contains(mode), commitAttempts > 0, cycleListRequests > 1 { try await Task.sleep(for: .seconds(8)) }
            if request.query.contains(where: { $0.name == "cursor" }), mode == .cyclePageFailure { throw V15Failure(kind: .transport, message: "下一页账期读取失败。") }
            let accountID = request.path.contains(V15F3B1Fixtures.secondAccountID.uuidString) ? V15F3B1Fixtures.secondAccountID : V15F3B1Fixtures.accountID
            return try decode(V15F3B1Fixtures.cyclePage(accountID: accountID, cursor: request.query.contains(where: { $0.name == "cursor" }) ? nil : "opaque-credit-next"))
        case ("credit-cycles/\(V15F3B1Fixtures.cycleID)", "GET"): return try decode(V15F3B1Fixtures.cycle(V15F3B1Fixtures.cycleID, opening: false, overdue: false, status: "open"))
        case ("credit-cycles/\(V15F3B1Fixtures.openingCycleID)", "GET"): return try decode(V15F3B1Fixtures.cycle(V15F3B1Fixtures.openingCycleID, opening: true, overdue: true, status: "overdue"))
        case ("credit-cycles/\(V15F3B1Fixtures.secondCycleID)", "GET"): return try decode(V15F3B1Fixtures.cycle(V15F3B1Fixtures.secondCycleID, accountID: V15F3B1Fixtures.secondAccountID, opening: false, overdue: false, status: "open"))
        case ("credit-cycles/\(V15F3B1Fixtures.secondOpeningCycleID)", "GET"): return try decode(V15F3B1Fixtures.cycle(V15F3B1Fixtures.secondOpeningCycleID, accountID: V15F3B1Fixtures.secondAccountID, opening: true, overdue: true, status: "overdue"))
        case ("credit-cycles/\(V15F3B1Fixtures.cycleID)/transactions", "GET"), ("credit-cycles/\(V15F3B1Fixtures.openingCycleID)/transactions", "GET"), ("credit-cycles/\(V15F3B1Fixtures.secondCycleID)/transactions", "GET"), ("credit-cycles/\(V15F3B1Fixtures.secondOpeningCycleID)/transactions", "GET"):
            if request.query.contains(where: { $0.name == "cursor" }), mode == .transactionPageFailure { throw V15Failure(kind: .transport, message: "下一页账目读取失败。") }
            return try decode("{\"items\":[],\"next_cursor\":null}")
        case ("credit-accounts/\(V15F3B1Fixtures.accountID)/schedule-change-preview", "POST"), ("credit-accounts/\(V15F3B1Fixtures.secondAccountID)/schedule-change-preview", "POST"):
            let accountID = request.path.contains(V15F3B1Fixtures.secondAccountID.uuidString) ? V15F3B1Fixtures.secondAccountID : V15F3B1Fixtures.accountID
            if mode == .previewConflict { throw V15Failure(kind: .conflict, code: "credit_schedule_preview_stale", message: "账期数据已变化。", conflict: .init(reloadPath: "/api/v1/credit-accounts/\(V15F3B1Fixtures.accountID)", latestRevision: 9, currentVersion: 5, expectedVersion: 4, safeToReload: true, message: "账期数据已变化。")) }
            if mode == .previewFieldError { throw V15Failure(kind: .transport, code: "validation_failed", message: "请检查账期设置。", fieldIssues: [.init(code: "due_day_invalid", message: "还款日不符合当前账期规则。", fieldPath: "due_day")]) }
            if mode == .previewExpired { return try decode(V15F3B1Fixtures.preview(accountID: accountID, expires: "2020-08-15T16:10:00Z")) }
            if mode == .previewDisabled { return try decode(V15F3B1Fixtures.preview(accountID: accountID, actions: "[]")) }
            return try decode(V15F3B1Fixtures.preview(accountID: accountID))
        case ("credit-accounts/\(V15F3B1Fixtures.accountID)/schedule-change", "POST"), ("credit-accounts/\(V15F3B1Fixtures.secondAccountID)/schedule-change", "POST"):
            let accountID = request.path.contains(V15F3B1Fixtures.secondAccountID.uuidString) ? V15F3B1Fixtures.secondAccountID : V15F3B1Fixtures.accountID
            let bodyText = body.flatMap { try? String(data: V15BodyEncoder.data($0), encoding: .utf8) } ?? ""
            commits.append(.init(idempotencyKey: request.headers["Idempotency-Key"] ?? "", body: bodyText))
            commitAttempts += 1
            if [Mode.commitDelayedSuccess, .commitDelayedConflict, .commitDelayedFailure, .commitDelayedUnknown].contains(mode), accountID == V15F3B1Fixtures.accountID { try await Task.sleep(for: .milliseconds(120)) }
            if mode == .commitUnknownReplayDelayed, commitAttempts == 2 { try await Task.sleep(for: .milliseconds(120)) }
            if mode == .commitDelayedConflict, accountID == V15F3B1Fixtures.accountID { throw V15Failure(kind: .conflict, code: "credit_schedule_preview_stale", message: "账期数据已变化。", conflict: .init(reloadPath: "/api/v1/credit-accounts/\(V15F3B1Fixtures.accountID)", latestRevision: 9, currentVersion: 5, expectedVersion: 4, safeToReload: true, message: "账期数据已变化。")) }
            if mode == .commitDelayedFailure, accountID == V15F3B1Fixtures.accountID { throw V15Failure(kind: .transport, code: "schedule_write_failed", message: "账期写入失败。") }
            if mode == .commitDelayedUnknown, accountID == V15F3B1Fixtures.accountID { throw V15Failure(kind: .responseUnknown, message: "提交结果暂时未知。") }
            if mode == .commitConflict || (mode == .commitConflictThenSuccess && commitAttempts == 1) || (mode == .reloadFailsOnceAfterConflict && commitAttempts == 1) { throw V15Failure(kind: .conflict, code: "credit_schedule_preview_stale", message: "账期数据已变化。", conflict: .init(reloadPath: "/api/v1/credit-accounts/\(V15F3B1Fixtures.accountID)", latestRevision: 9, currentVersion: 5, expectedVersion: 4, safeToReload: true, message: "账期数据已变化。")) }
            if mode == .commitUnknownOfflineRecovery, commitAttempts == 1 {
                await MainActor.run { self.offlineSnapshotMarker?.snapshotAt = Date(timeIntervalSince1970: 1_786_464_000) }
                throw V15Failure(kind: .responseUnknown, message: "提交结果暂时未知。")
            }
            if [Mode.commitUnknownThenSuccess, .commitUnknownReadbackFails, .commitUnknownReadbackOldState, .commitUnknownReadbackMatches, .commitUnknownReadbackFresh, .commitUnknownReadbackOfflineFallback, .commitUnknownReadbackDelayed, .commitUnknownRetryOffline, .commitUnknownReplayDelayed, .commitUnknownReplayPostReloadDelayed].contains(mode), commitAttempts == 1 { throw V15Failure(kind: .responseUnknown, message: "提交结果暂时未知。") }
            if mode == .commitUnknownRetryOffline, commitAttempts == 2 { throw V15Failure(kind: .offlineReadOnly, code: "offline_read_only", message: "离线快照仅可查看，无法提交更改。") }
            if mode == .commitUnknownThenExpired, commitAttempts == 1 { throw V15Failure(kind: .responseUnknown, message: "提交结果暂时未知。") }
            if mode == .commitUnknownThenExpired { throw V15Failure(kind: .transport, code: "preview_expired", message: "服务器确认预览已过期，未执行账期变更。") }
            return try decode(V15F3B1Fixtures.preview(accountID: accountID))
        default: throw V15Failure(kind: .transport, message: "F3-B1 fixture received an unsupported request: \(request.method) \(request.path)")
        }
    }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { throw V15Failure(kind: .transport, message: "F3-B1 has no artifact endpoint.") }
}
