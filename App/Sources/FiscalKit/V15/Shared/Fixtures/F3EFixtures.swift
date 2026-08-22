import Foundation

/// Fully synthetic reconciliation evidence. It contains no production account
/// tail, bank statement, provider text or transaction narrative.
public enum V15F3EFixtures {
    public static let accountA = UUID(uuidString: "00000000-0000-0000-0000-00000000E301")!
    public static let accountB = UUID(uuidString: "00000000-0000-0000-0000-00000000E302")!
    public static let creditAccount = UUID(uuidString: "00000000-0000-0000-0000-00000000E303")!
    public static let cycleA = UUID(uuidString: "00000000-0000-0000-0000-00000000E311")!
    public static let cycleB = UUID(uuidString: "00000000-0000-0000-0000-00000000E312")!
    public static let openCheckpoint = UUID(uuidString: "00000000-0000-0000-0000-00000000E321")!
    public static let reconciledCheckpoint = UUID(uuidString: "00000000-0000-0000-0000-00000000E322")!
    public static let createdCheckpoint = UUID(uuidString: "00000000-0000-0000-0000-00000000E323")!
    public static let transactionID = UUID(uuidString: "00000000-0000-0000-0000-00000000E331")!
    public static let overdueID = UUID(uuidString: "00000000-0000-0000-0000-00000000E341")!
    public static let statementID = UUID(uuidString: "00000000-0000-0000-0000-00000000E342")!
    public static let unknownAttentionID = UUID(uuidString: "00000000-0000-0000-0000-00000000E343")!

    @MainActor public static func services(route: String = "reconciliation") -> V15Services { .init(transport: F3ETransport(mode: .route(route))) }

    static let accounts = """
    [
      {"id":"\(accountA)","name":"日常账户","kind":"debit","institution":null,"last_four":null,"opening_balance_minor":100000,"current_balance_minor":98450,"credit_limit_minor":null,"statement_day":null,"due_day":null,"cycle_mode":null,"opening_balance_as_of_date":null,"opening_due_date":null,"sort_order":1,"archived_at":null,"usage_count":8,"version":3,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-15T00:00:00Z"},
      {"id":"\(accountB)","name":"储备账户","kind":"cash","institution":null,"last_four":null,"opening_balance_minor":800000,"current_balance_minor":800000,"credit_limit_minor":null,"statement_day":null,"due_day":null,"cycle_mode":null,"opening_balance_as_of_date":null,"opening_due_date":null,"sort_order":2,"archived_at":null,"usage_count":2,"version":1,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-15T00:00:00Z"},
      {"id":"\(creditAccount)","name":"示例信用账户","kind":"credit","institution":null,"last_four":null,"opening_balance_minor":0,"current_balance_minor":-328800,"credit_limit_minor":1000000,"statement_day":20,"due_day":5,"cycle_mode":"previous_calendar_month","opening_balance_as_of_date":null,"opening_due_date":null,"sort_order":3,"archived_at":null,"usage_count":5,"version":2,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-15T00:00:00Z"}
    ]
    """

    static func cycle(_ id: UUID, statementDate: String, dueDate: String, remaining: Int64, status: String) -> String {
        let response = "{\"id\":\"\(id)\",\"account_id\":\"\(creditAccount)\",\"period_start\":\"2026-07-01\",\"period_end\":\"2026-07-31\",\"statement_date\":\"\(statementDate)\",\"due_date\":\"\(dueDate)\",\"is_opening_cycle\":false,\"purchase_minor\":\(remaining),\"opening_minor\":0,\"amount_due_minor\":\(remaining),\"repaid_minor\":0,\"remaining_minor\":\(remaining),\"status\":\"\(status)\",\"is_overdue\":false,\"version\":2,\"created_at\":\"2026-08-01T00:00:00Z\",\"updated_at\":\"2026-08-15T00:00:00Z\",\"installment_principal_minor\":0,\"installment_fee_minor\":0,\"installment_periods\":[]}"
        return response
    }

    static var creditAccounts: String {
        let current = cycle(cycleA, statementDate: "2026-08-20", dueDate: "2026-09-05", remaining: 328800, status: "open")
        return "[{\"account_id\":\"\(creditAccount)\",\"name\":\"示例信用账户\",\"institution\":null,\"last_four\":null,\"credit_limit_minor\":1000000,\"current_debt_minor\":328800,\"available_credit_minor\":671200,\"over_limit_minor\":0,\"opening_configuration_required\":false,\"statement_day\":20,\"due_day\":5,\"cycle_mode\":\"previous_calendar_month\",\"current_cycle\":\(current),\"next_due_cycle\":\(current),\"has_overdue_cycle\":false,\"active_installment_count\":0,\"future_scheduled_gross_minor\":0,\"next_installment\":null}]"
    }

    static var cyclePage: String { "{\"items\":[\(cycle(cycleA, statementDate: "2026-08-20", dueDate: "2026-09-05", remaining: 328800, status: "open")),\(cycle(cycleB, statementDate: "2026-07-20", dueDate: "2026-08-05", remaining: 0, status: "settled"))],\"next_cursor\":null}" }

    static func checkpoint(id: UUID, kind: String = "account", account: UUID? = accountA, cycle: UUID? = nil, asOf: String = "2026-08-15T08:00:00Z", actual: Int64 = 100000, book: Int64 = 98450, state: String = "open", note: String? = "离线合成核对") -> String {
        let uuid: (UUID?) -> String = { $0.map { "\"\($0)\"" } ?? "null" }
        let noteJSON = note.map { "\"\($0)\"" } ?? "null"
        return "{\"id\":\"\(id)\",\"target_kind\":\"\(kind)\",\"account_id\":\(uuid(account)),\"credit_cycle_id\":\(uuid(cycle)),\"as_of\":\"\(asOf)\",\"actual_balance_minor\":\(actual),\"book_balance_minor\":\(book),\"difference_minor\":\(actual - book),\"state\":\"\(state)\",\"note\":\(noteJSON),\"created_at\":\"2026-08-15T08:01:00Z\"}"
    }

    static func checkpoints(targetID: UUID, created: Bool = false, empty: Bool = false) -> String {
        if empty { return "[]" }
        if targetID == accountA {
            var rows = [checkpoint(id: openCheckpoint)]
            if created { rows.insert(checkpoint(id: createdCheckpoint, asOf: "2026-08-16T08:00:00Z", actual: 123456, book: 98450, note: "新核对"), at: 0) }
            rows.append(checkpoint(id: reconciledCheckpoint, asOf: "2026-08-01T08:00:00Z", actual: 100000, book: 100000, state: "reconciled", note: nil))
            return "[\(rows.joined(separator: ","))]"
        }
        if targetID == accountB { return "[\(checkpoint(id: reconciledCheckpoint, account: accountB, actual: 800000, book: 800000, state: "reconciled", note: nil))]" }
        return "[\(checkpoint(id: openCheckpoint, kind: "credit_cycle", account: nil, cycle: targetID, actual: 330000, book: 328800, state: "open"))]"
    }

    static func diagnosis(kind: String, targetID: UUID, asOf: String) -> String {
        let account = kind == "account" ? "\"\(targetID)\"" : "null"
        let cycle = kind == "credit_cycle" ? "\"\(targetID)\"" : "null"
        let book: Int64 = targetID == accountB ? 800000 : targetID == cycleA || targetID == cycleB ? 328800 : 98450
        return "{\"target_kind\":\"\(kind)\",\"account_id\":\(account),\"credit_cycle_id\":\(cycle),\"as_of\":\"\(asOf)\",\"from_as_of\":\"2026-08-01T08:00:00Z\",\"opening_balance_minor\":100000,\"book_balance_minor\":\(book),\"actual_balance_minor\":100000,\"difference_minor\":\(100000 - book),\"entries\":[{\"transaction_id\":\"\(transactionID)\",\"occurred_at\":\"2026-08-12T04:00:00Z\",\"title\":\"离线合成账目\",\"amount_minor\":1550,\"account_impact_minor\":-1550}]}"
    }

    static func attention(includeUnknown: Bool = true, ignored: Set<String> = [], disabledOnly: Bool = false) -> String {
        func item(type: String, id: UUID, severity: String, amount: Int64?, explanation: String, action: String) -> String {
            let amountJSON = amount.map(String.init) ?? "null"
            return "{\"source_type\":\"\(type)\",\"source_id\":\"\(id)\",\"severity\":\"\(severity)\",\"amount_minor\":\(amountJSON),\"occurred_at\":\"2026-08-15T08:00:00Z\",\"explanation\":\"\(explanation)\",\"suggested_action\":\"核对后处理。\",\"deep_link\":\"fiscal://reconciliation/attention\",\"available_actions\":[\(action)]}"
        }
        let enabled = "{\"action\":\"ignore\",\"enabled\":true,\"reason_code\":null,\"reason_message\":null}"
        let disabled = "{\"action\":\"ignore\",\"enabled\":false,\"reason_code\":\"statement_import_attention_not_dismissible\",\"reason_message\":\"Statement import attention cannot be ignored\"}"
        let unknown = "{\"action\":\"review\",\"enabled\":true,\"reason_code\":null,\"reason_message\":null}"
        var rows = disabledOnly ? [item(type: "statement_import_failed", id: statementID, severity: "warning", amount: nil, explanation: "账单导入失败。", action: disabled)] : [
            item(type: "reconciliation_checkpoint", id: openCheckpoint, severity: "warning", amount: 1550, explanation: "实际余额与账面余额不一致。", action: enabled),
            item(type: "reconciliation_missing", id: accountB, severity: "info", amount: nil, explanation: "储备账户尚无核对锚点。", action: enabled),
            item(type: "cash_flow_overdue", id: overdueID, severity: "critical", amount: 922337203685477, explanation: "现金流事项已逾期。", action: enabled),
            item(type: "statement_import_failed", id: statementID, severity: "warning", amount: nil, explanation: "账单导入失败。", action: disabled)
        ]
        if includeUnknown && !disabledOnly { rows.append(item(type: "future_attention", id: unknownAttentionID, severity: "info", amount: nil, explanation: "未来关注类型只读。", action: unknown)) }
        rows.removeAll { row in ignored.contains(where: row.contains) }
        return "{\"items\":[\(rows.joined(separator: ","))]}"
    }
}

actor F3ETransport: V15Transporting {
    enum Mode: Equatable {
        case normal, empty, initialError, diagnosisError, fieldError, conflict
        case checkpointUnknown, checkpointCancelled, checkpointInvalidResponse
        case ignoreUnknown, ignoreCancelled, ignoreInvalidResponse
        case deterministicOnce, refreshFailure, attentionDisabled, selectionRace, long
        static func route(_ route: String) -> Mode {
            switch route {
            case "reconciliation-empty": .empty
            case "reconciliation-error": .initialError
            case "reconciliation-diagnosis-error": .diagnosisError
            case "reconciliation-field-error": .fieldError
            case "reconciliation-conflict": .conflict
            case "reconciliation-unknown": .checkpointUnknown
            case "reconciliation-cancelled-unknown": .checkpointCancelled
            case "reconciliation-invalid-response": .checkpointInvalidResponse
            case "reconciliation-attention-unknown": .ignoreUnknown
            case "reconciliation-attention-cancelled": .ignoreCancelled
            case "reconciliation-attention-invalid-response": .ignoreInvalidResponse
            case "reconciliation-mutation-error": .deterministicOnce
            case "reconciliation-partial-refresh": .refreshFailure
            case "reconciliation-attention-disabled": .attentionDisabled
            case "reconciliation-race": .selectionRace
            case "reconciliation-long": .long
            default: .normal
            }
        }
    }
    struct Wire: Sendable, Equatable { let method: String; let path: String; let body: String }
    let mode: Mode
    private var requests: [V15Request] = []
    private var wires: [Wire] = []
    private var created = false
    private var ignored = Set<String>()
    private var createCount = 0
    private var ignoreCount = 0
    private var postWriteReadCount = 0
    init(mode: Mode) { self.mode = mode }
    func allRequests() -> [V15Request] { requests }
    func mutationWires() -> [Wire] { wires }

    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        requests.append(request)
        let decode: (String) throws -> Response = { try V15FixtureCodec.decoder.decode(Response.self, from: Data($0.utf8)) }
        let bodyText = body.flatMap { try? String(data: V15BodyEncoder.data($0), encoding: .utf8) } ?? ""
        if request.method != "GET" { wires.append(.init(method: request.method, path: request.path, body: bodyText)) }
        switch (request.path, request.method) {
        case ("accounts", "GET"):
            if mode == .initialError { throw V15Failure(kind: .transport, message: "目标读取失败。") }
            return try decode(V15F3EFixtures.accounts)
        case ("credit-accounts", "GET"): return try decode(V15F3EFixtures.creditAccounts)
        case ("credit-accounts/\(V15F3EFixtures.creditAccount)/cycles", "GET"): return try decode(V15F3EFixtures.cyclePage)
        case ("reconciliation/checkpoints", "GET"):
            if created { postWriteReadCount += 1 }
            if mode == .refreshFailure && created && postWriteReadCount == 1 { throw V15Failure(kind: .transport, message: "写后核对列表读取失败。") }
            let id = request.query.first(where: { $0.name == "account_id" || $0.name == "credit_cycle_id" })?.value.flatMap(UUID.init(uuidString:)) ?? V15F3EFixtures.accountA
            if mode == .selectionRace && id == V15F3EFixtures.accountA { try await Task.sleep(for: .milliseconds(160)) }
            return try decode(V15F3EFixtures.checkpoints(targetID: id, created: created, empty: mode == .empty))
        case ("reconciliation/checkpoints/\(V15F3EFixtures.openCheckpoint)", "GET"): return try decode(V15F3EFixtures.checkpoint(id: V15F3EFixtures.openCheckpoint))
        case ("reconciliation/checkpoints/\(V15F3EFixtures.reconciledCheckpoint)", "GET"): return try decode(V15F3EFixtures.checkpoint(id: V15F3EFixtures.reconciledCheckpoint, actual: 100000, book: 100000, state: "reconciled", note: nil))
        case ("reconciliation/checkpoints/\(V15F3EFixtures.createdCheckpoint)", "GET"): return try decode(V15F3EFixtures.checkpoint(id: V15F3EFixtures.createdCheckpoint, asOf: "2026-08-16T08:00:00Z", actual: 123456, book: 98450, note: "新核对"))
        case ("reconciliation/diagnosis", "GET"):
            if mode == .diagnosisError { throw V15Failure(kind: .transport, message: "诊断读取失败。") }
            let kind = request.query.first(where: { $0.name == "target_kind" })?.value ?? "account"
            let id = request.query.first(where: { $0.name == "account_id" || $0.name == "credit_cycle_id" })?.value.flatMap(UUID.init(uuidString:)) ?? V15F3EFixtures.accountA
            if mode == .selectionRace && id == V15F3EFixtures.accountA { try await Task.sleep(for: .milliseconds(160)) }
            if mode == .conflict { throw V15Failure(kind: .conflict, code: "revision_conflict", message: "对账事实已变化。", conflict: .init(reloadPath: "/api/v1/reconciliation/diagnosis", latestRevision: 9, message: "对账事实已变化。")) }
            let asOf = request.query.first(where: { $0.name == "as_of" })?.value ?? "2026-08-16T08:00:00Z"
            return try decode(V15F3EFixtures.diagnosis(kind: kind, targetID: id, asOf: asOf))
        case ("reconciliation/attention", "GET"):
            return try decode(V15F3EFixtures.attention(includeUnknown: mode == .long || mode == .normal, ignored: ignored, disabledOnly: mode == .attentionDisabled))
        case ("reconciliation/checkpoints", "POST"):
            createCount += 1
            if mode == .fieldError {
                throw V15Failure(kind: .transport, code: "validation_error", message: "请修正核对字段。", fieldIssues: [
                    .init(code: "actual_balance_out_of_range", message: "实际余额超出服务端允许范围。", fieldPath: "actual_balance_minor"),
                    .init(code: "note_rejected", message: "备注不符合服务端规则。", fieldPath: "note")
                ])
            }
            if mode == .deterministicOnce && createCount == 1 {
                throw V15Failure(kind: .transport, code: "validation_error", message: "服务器明确拒绝了本次核对请求。")
            }
            if mode == .conflict { throw V15Failure(kind: .conflict, code: "revision_conflict", message: "核对事实已变化。", conflict: .init(reloadPath: "/api/v1/reconciliation/checkpoints", latestRevision: 10, message: "核对事实已变化。")) }
            created = true
            if mode == .checkpointUnknown && createCount == 1 { throw V15Failure(kind: .responseUnknown, message: "核对写入结果未知。") }
            if mode == .checkpointCancelled && createCount == 1 { throw V15Failure(kind: .cancelled, message: "核对写入响应前任务取消。") }
            if mode == .checkpointInvalidResponse && createCount == 1 { throw V15Failure(kind: .decoding, code: "invalid_response", message: "核对写入响应无法解析。") }
            return try decode(V15F3EFixtures.checkpoint(id: V15F3EFixtures.createdCheckpoint, asOf: "2026-08-16T08:00:00Z", actual: 123456, book: 98450, note: "新核对"))
        default: throw V15Failure(kind: .transport, message: "F3-E fixture不支持 \(request.method) \(request.path)。")
        }
    }

    func sendNoContent(_ request: V15Request, body: JSONValue?) async throws {
        requests.append(request)
        let bodyText = body.flatMap { try? String(data: V15BodyEncoder.data($0), encoding: .utf8) } ?? ""
        wires.append(.init(method: request.method, path: request.path, body: bodyText))
        ignoreCount += 1
        let owner = request.path.split(separator: "/").dropLast().last.map(String.init) ?? ""
        ignored.insert(owner)
        if mode == .ignoreUnknown && ignoreCount == 1 { throw V15Failure(kind: .responseUnknown, message: "忽略结果未知。") }
        if mode == .ignoreCancelled && ignoreCount == 1 { throw V15Failure(kind: .cancelled, message: "忽略响应前任务取消。") }
        if mode == .ignoreInvalidResponse && ignoreCount == 1 { throw V15Failure(kind: .decoding, code: "invalid_response", message: "忽略响应无法解析。") }
    }

    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { throw V15Failure(kind: .transport, message: "F3-E无文件读取。") }
}
