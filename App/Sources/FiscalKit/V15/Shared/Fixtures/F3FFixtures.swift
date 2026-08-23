import Foundation

/// Synthetic F3-F evidence only. No provider secret, production narrative or
/// financial chat transcript is represented in these fixtures.
public enum V15F3FFixtures {
    public static let pendingID = UUID(uuidString: "00000000-0000-0000-0000-00000000F301")!
    public static let failedID = UUID(uuidString: "00000000-0000-0000-0000-00000000F302")!
    public static let executedID = UUID(uuidString: "00000000-0000-0000-0000-00000000F303")!
    public static let unknownID = UUID(uuidString: "00000000-0000-0000-0000-00000000F304")!
    public static let createdID = UUID(uuidString: "00000000-0000-0000-0000-00000000F305")!
    public static let processingID = UUID(uuidString: "00000000-0000-0000-0000-00000000F306")!
    public static let ignoredID = UUID(uuidString: "00000000-0000-0000-0000-00000000F307")!
    public static let undoneID = UUID(uuidString: "00000000-0000-0000-0000-00000000F308")!
    public static let transactionID = UUID(uuidString: "00000000-0000-0000-0000-00000000F311")!
    public static let cashFlowItemID = UUID(uuidString: "00000000-0000-0000-0000-00000000F312")!
    public static let cashFlowProposalID = UUID(uuidString: "00000000-0000-0000-0000-00000000F309")!
    public static let cashAccountID = UUID(uuidString: "00000000-0000-0000-0000-00000000F321")!
    public static let creditAccountID = UUID(uuidString: "00000000-0000-0000-0000-00000000F322")!
    public static let destinationID = UUID(uuidString: "00000000-0000-0000-0000-00000000F323")!
    public static let expenseCategoryID = UUID(uuidString: "00000000-0000-0000-0000-00000000F331")!
    public static let incomeCategoryID = UUID(uuidString: "00000000-0000-0000-0000-00000000F332")!
    public static let cycleID = UUID(uuidString: "00000000-0000-0000-0000-00000000F341")!

    @MainActor public static func services(route: String = "ai-proposals") -> V15Services { .init(transport: F3FTransport(mode: .route(route))) }

    static func settings(autoExecute: Bool = false, effectiveAutoExecute: Bool = false) -> String {
        "{\"auto_execute_enabled\":\(autoExecute),\"ocr_source_enabled\":true,\"shortcut_text_source_enabled\":true,\"auto_execute_limit_minor\":10000,\"minimum_confidence_bps\":9500,\"version\":4,\"provider_configured\":true,\"effective_auto_execute\":\(effectiveAutoExecute),\"created_at\":\"2026-08-01T00:00:00Z\",\"updated_at\":\"2026-08-16T00:00:00Z\"}"
    }

    static let accounts = """
    [
      {"id":"\(cashAccountID)","name":"日常借记","kind":"debit","institution":null,"last_four":null,"opening_balance_minor":500000,"current_balance_minor":486800,"credit_limit_minor":null,"statement_day":null,"due_day":null,"cycle_mode":null,"opening_balance_as_of_date":null,"opening_due_date":null,"sort_order":1,"archived_at":null,"usage_count":12,"version":2,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-16T00:00:00Z"},
      {"id":"\(destinationID)","name":"储备现金","kind":"cash","institution":null,"last_four":null,"opening_balance_minor":800000,"current_balance_minor":800000,"credit_limit_minor":null,"statement_day":null,"due_day":null,"cycle_mode":null,"opening_balance_as_of_date":null,"opening_due_date":null,"sort_order":2,"archived_at":null,"usage_count":4,"version":1,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-16T00:00:00Z"},
      {"id":"\(creditAccountID)","name":"示例信用账户","kind":"credit","institution":null,"last_four":null,"opening_balance_minor":0,"current_balance_minor":-26800,"credit_limit_minor":1000000,"statement_day":20,"due_day":5,"cycle_mode":"previous_calendar_month","opening_balance_as_of_date":null,"opening_due_date":null,"sort_order":3,"archived_at":null,"usage_count":6,"version":2,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-16T00:00:00Z"}
    ]
    """

    static func categories(direction: String) -> String {
        let id = direction == "income" ? incomeCategoryID : expenseCategoryID
        let name = direction == "income" ? "示例收入" : "工作餐"
        return "[{\"id\":\"\(id)\",\"name\":\"\(name)\",\"direction\":\"\(direction)\",\"parent_id\":null,\"icon\":\"circle\",\"color_hex\":\"#4D766E\",\"aliases\":[],\"examples\":[],\"is_balance_adjustment\":false,\"sort_order\":1,\"archived_at\":null,\"usage_count\":5,\"version\":1,\"created_at\":\"2026-08-01T00:00:00Z\",\"updated_at\":\"2026-08-16T00:00:00Z\",\"children\":[]}]"
    }

    static var creditCycles: String {
        "{\"items\":[{\"id\":\"\(cycleID)\",\"account_id\":\"\(creditAccountID)\",\"period_start\":\"2026-07-01\",\"period_end\":\"2026-07-31\",\"statement_date\":\"2026-08-20\",\"due_date\":\"2026-09-05\",\"is_opening_cycle\":false,\"purchase_minor\":26800,\"opening_minor\":0,\"amount_due_minor\":26800,\"repaid_minor\":0,\"remaining_minor\":26800,\"status\":\"open\",\"is_overdue\":false,\"version\":2,\"created_at\":\"2026-08-01T00:00:00Z\",\"updated_at\":\"2026-08-16T00:00:00Z\",\"installment_principal_minor\":0,\"installment_fee_minor\":0,\"installment_periods\":[]}],\"next_cursor\":null}"
    }

    static func proposal(
        id: UUID,
        status: String,
        version: Int = 2,
        title: String? = "很长但可完整检查的离线合成工作餐提案",
        amount: Int64? = 13_200,
        confidence: Int? = 7_200,
        missing: [String] = ["category_id"],
        errorCode: String? = nil,
        errorMessage: String? = nil,
        transaction: Bool = false,
        target: String = "transaction",
        kind: String = "expense",
        occurredAt: String = "2026-09-16T04:30:00Z",
        note: String? = "离线合成内容",
        accountID: UUID? = cashAccountID,
        categoryID: UUID? = nil,
        destinationAccountID: UUID? = nil,
        creditCycleID: UUID? = nil
    ) -> String {
        func string(_ value: String?) -> String { value.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" } ?? "null" }
        let missingJSON = missing.map { "\"\($0)\"" }.joined(separator: ",")
        let titleJSON = string(title)
        let amountJSON = amount.map(String.init) ?? "null"
        let confidenceJSON = confidence.map(String.init) ?? "null"
        let transactionIDJSON = transaction ? "\"\(transactionID)\"" : "null"
        let accountIDJSON = accountID.map { "\"\($0)\"" } ?? "null"
        let categoryIDJSON = categoryID.map { "\"\($0)\"" } ?? "null"
        let destinationIDJSON = destinationAccountID.map { "\"\($0)\"" } ?? "null"
        let cycleIDJSON = creditCycleID.map { "\"\($0)\"" } ?? "null"
        let noteJSON = string(note)
        let transactionVersionJSON = transaction ? "3" : "null"
        let cashFlowIDJSON = target == "cash_flow" && status == "executed" ? "\"\(cashFlowItemID)\"" : "null"
        let cashFlowVersionJSON = target == "cash_flow" && status == "executed" ? "3" : "null"
        let executed = status == "executed" ? "\"2026-08-16T06:10:00Z\"" : "null"
        let ignored = status == "ignored" ? "\"2026-08-16T06:10:00Z\"" : "null"
        let undone = status == "undone" ? "\"2026-08-16T06:20:00Z\"" : "null"
        let reviewed = title == "人工确认后的工作餐"
        let finalSnapshot = reviewed ? "{\"kind\":\"expense\",\"amount_minor\":13200,\"title\":\"人工确认后的工作餐\",\"category_id\":\"\(expenseCategoryID)\"}" : "null"
        let finalDiff = reviewed ? "{\"title\":{\"from\":\"合成工作餐\",\"to\":\"人工确认后的工作餐\"},\"category_id\":{\"from\":null,\"to\":\"\(expenseCategoryID)\"}}" : "null"
        return """
        {"id":"\(id)","source":"text","text":"下个月计划支付房租 132 元","content_fingerprint":"fixture-\(id.uuidString)","provider":"openai_compatible","model":"fixture-model","target":"\(target)","kind":"\(kind)","amount_minor":\(amountJSON),"occurred_at":"\(occurredAt)","title":\(titleJSON),"note":\(noteJSON),"account_id":\(accountIDJSON),"category_id":\(categoryIDJSON),"destination_account_id":\(destinationIDJSON),"credit_cycle_id":\(cycleIDJSON),"field_confidences":{"kind":9800,"amount_minor":9900,"occurred_at":8400,"title":7600,"note":5000,"account_id":9100,"category_id":2100,"destination_account_id":0},"overall_confidence_bps":\(confidenceJSON),"missing_fields":[\(missingJSON)],"reason_codes":["low_confidence:category_id"],"explanation":"金额较明确；分类仍需人工决定。","status":"\(status)","error_code":\(string(errorCode)),"error_message":\(string(errorMessage)),"transaction_id":\(transactionIDJSON),"transaction_version":\(transactionVersionJSON),"cash_flow_item_id":\(cashFlowIDJSON),"cash_flow_item_version":\(cashFlowVersionJSON),"version":\(version),"created_at":"2026-08-16T04:31:00Z","updated_at":"2026-08-16T04:32:00Z","executed_at":\(executed),"ignored_at":\(ignored),"undone_at":\(undone),"initial_parse_snapshot":{"kind":"expense","amount_minor":13200,"title":"合成工作餐","category_id":null,"currency":"CNY","target":"\(target)"},"final_confirmed_snapshot":\(finalSnapshot),"final_field_diff":\(finalDiff),"quality_status":"available"}
        """
    }

    static func cashFlowPage(missing: Bool = false) -> String {
        let item = proposal(id: cashFlowProposalID, status: "pending", title: "下个月房租现金流提案", missing: missing ? ["account_id"] : [], target: "cash_flow")
        return "{\"items\":[\(item)],\"next_cursor\":\"f3f-next\",\"pending_count\":1}"
    }

    static func page(includeUnknown: Bool = true, empty: Bool = false, created: Bool = false, long: Bool = false, excluding deleted: Set<UUID> = []) -> String {
        if empty { return "{\"items\":[],\"next_cursor\":null,\"pending_count\":0}" }
        var rows: [(UUID, String)] = [
            (pendingID, proposal(id: pendingID, status: "pending")),
            (failedID, proposal(id: failedID, status: "failed", errorCode: "ai_provider_timeout", errorMessage: "AI 响应超时。请稍后重试。")),
            (executedID, proposal(id: executedID, status: "executed", version: 5, missing: [], transaction: true))
        ]
        if long {
            rows.append((processingID, proposal(id: processingID, status: "processing", title: "正在解析的离线合成提案", confidence: nil, missing: [])))
            rows.append((ignoredID, proposal(id: ignoredID, status: "ignored", version: 4, title: "已忽略的离线合成提案", missing: [])))
            rows.append((undoneID, proposal(id: undoneID, status: "undone", version: 6, title: "已撤销的离线合成提案", missing: [], transaction: true)))
        }
        if includeUnknown { rows.append((unknownID, proposal(id: unknownID, status: "future_review", missing: []))) }
        if created { rows.insert((createdID, proposal(id: createdID, status: "pending", version: 1, title: "新建合成提案", confidence: 9300, missing: [])), at: 0) }
        rows.removeAll { deleted.contains($0.0) }
        let pending = (created && !deleted.contains(createdID) ? 1 : 0) + (deleted.contains(pendingID) ? 0 : 1)
        return "{\"items\":[\(rows.map(\.1).joined(separator: ","))],\"next_cursor\":\"f3f-next\",\"pending_count\":\(pending)}"
    }

    static func events(_ id: UUID) -> String {
        let failed = id == failedID
        let eventType = failed ? "final_failure" : "parsed"
        let reason = failed ? "\"ai_provider_timeout\"" : "null"
        return "[{\"id\":\"00000000-0000-0000-0000-00000000F351\",\"proposal_id\":\"\(id)\",\"event_type\":\"\(eventType)\",\"reason\":\(reason),\"details\":{\"prompt_version\":\"fixture-v1\"},\"occurred_at\":\"2026-08-16T04:32:00Z\"}]"
    }
}

actor F3FTransport: V15Transporting {
    enum Mode: Equatable {
        case normal, empty, initialError, fieldError, conflict, conflictReloadFailure, createUnknown, directUnknown, directUnknownReadFailure, directUnknownReadDelayed, deleteUnknown, deleteUnknownStillPresent, deleteUnknownReadFailure, settingsViolation, settingsViolationAfterSafe, settingsViolationAutoOnlyAfterSafe, settingsViolationEffectiveOnlyAfterSafe, settingsTransportAfterSafe, settingsViolationRace, createUnknownSettingsViolationAfterSafe, createUnknownSettingsTransportAfterSafe, directUnknownSettingsViolationAfterSafe, selectionRace, pageRace, pageError, cashFlow, cashFlowMissing, serverChanged, long
        static func route(_ route: String) -> Mode {
            switch route {
            case "ai-empty": .empty
            case "ai-error": .initialError
            case "ai-field-error": .fieldError
            case "ai-conflict": .conflict
            case "ai-create-unknown": .createUnknown
            case "ai-create-unknown-settings-transport-after-safe": .createUnknownSettingsTransportAfterSafe
            case "ai-response-unknown": .directUnknown
            case "ai-response-unknown-read-failure": .directUnknownReadFailure
            case "ai-response-unknown-read-delayed": .directUnknownReadDelayed
            case "ai-delete-unknown": .deleteUnknown
            case "ai-delete-unknown-still-present": .deleteUnknownStillPresent
            case "ai-delete-unknown-read-failure": .deleteUnknownReadFailure
            case "ai-conflict-read-failure": .conflictReloadFailure
            case "ai-page-error": .pageError
            case "ai-cash-flow": .cashFlow
            case "ai-cash-flow-missing": .cashFlowMissing
            case "ai-server-changed": .serverChanged
            case "ai-settings-violation": .settingsViolation
            case "ai-settings-violation-after-safe": .settingsViolationAfterSafe
            case "ai-selection-race": .selectionRace
            case "ai-page-race": .pageRace
            case "ai-long": .long
            default: .normal
            }
        }
    }
    struct Wire: Sendable, Equatable { let method, path, body: String; let headers: [String: String]; let query: [String: String] }
    let mode: Mode
    private var requests: [V15Request] = []
    private var wires: [Wire] = []
    private var created = false
    private var createCount = 0
    private var directCount = 0
    private var settingsReads = 0
    private var recoveryReadFailures = 0
    private var current: [UUID: String] = [:]
    private var deleted: Set<UUID> = []
    init(mode: Mode) { self.mode = mode }
    func allRequests() -> [V15Request] { requests }
    func mutationWires() -> [Wire] { wires }

    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        requests.append(request)
        let decode: (String) throws -> Response = { try V15FixtureCodec.decoder.decode(Response.self, from: Data($0.utf8)) }
        let bodyText: String
        if let body {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            bodyText = (try? String(data: encoder.encode(body), encoding: .utf8)) ?? ""
        } else {
            bodyText = ""
        }
        if request.method != "GET" { wires.append(.init(method: request.method, path: request.path, body: bodyText, headers: request.headers, query: Dictionary(uniqueKeysWithValues: request.query.compactMap { item in item.value.map { (item.name, $0) } }))) }
        if mode == .initialError, request.path == "ai/proposals" { throw V15Failure(kind: .transport, message: "AI 队列读取失败。") }
        switch (request.path, request.method) {
        case ("ai/settings", "GET"):
            settingsReads += 1
            if mode == .settingsViolationRace, settingsReads == 1 { try await Task.sleep(for: .milliseconds(180)) }
            if mode == .settingsTransportAfterSafe, settingsReads > 1 { throw V15Failure(kind: .transport, message: "AI 安全设置读取失败。") }
            if mode == .createUnknownSettingsTransportAfterSafe, settingsReads == 2 { throw V15Failure(kind: .transport, message: "AI 安全设置读取失败。") }
            let autoOnly = mode == .settingsViolationAutoOnlyAfterSafe && settingsReads == 2
            let effectiveOnly = mode == .settingsViolationEffectiveOnlyAfterSafe && settingsReads == 2
            let both = mode == .settingsViolation ||
                ((mode == .settingsViolationAfterSafe || mode == .settingsViolationRace || mode == .createUnknownSettingsViolationAfterSafe || mode == .directUnknownSettingsViolationAfterSafe) && settingsReads == 2)
            do {
                return try decode(V15F3FFixtures.settings(autoExecute: both || autoOnly, effectiveAutoExecute: both || effectiveOnly))
            } catch let failure as V15Failure {
                throw failure
            } catch {
                throw V15Failure(kind: .decoding, code: "invalid_response", message: "D3 设置契约无效。")
            }
        case ("accounts", "GET"):
            return try decode(V15F3FFixtures.accounts)
        case ("categories", "GET"):
            let direction = request.query.first(where: { $0.name == "direction" })?.value ?? "expense"
            return try decode(V15F3FFixtures.categories(direction: direction))
        case ("credit-accounts/\(V15F3FFixtures.creditAccountID)/cycles", "GET"):
            return try decode(V15F3FFixtures.creditCycles)
        case ("ai/proposals", "GET"):
            if request.query.contains(where: { $0.name == "cursor" }) {
                if mode == .pageRace { try await Task.sleep(for: .milliseconds(180)) }
                if mode == .pageError { throw V15Failure(kind: .transport, message: "下一页读取失败。") }
                return try decode("{\"items\":[],\"next_cursor\":null,\"pending_count\":1}")
            }
            if mode == .cashFlow || mode == .cashFlowMissing { return try decode(V15F3FFixtures.cashFlowPage(missing: mode == .cashFlowMissing)) }
            return try decode(V15F3FFixtures.page(includeUnknown: true, empty: mode == .empty, created: created, long: mode == .long, excluding: deleted))
        case ("ai/proposals", "POST"):
            createCount += 1; created = true
            if (mode == .createUnknown || mode == .createUnknownSettingsViolationAfterSafe || mode == .createUnknownSettingsTransportAfterSafe) && createCount == 1 { throw V15Failure(kind: .responseUnknown, message: "新建响应未知。") }
            return try decode(V15F3FFixtures.proposal(id: V15F3FFixtures.createdID, status: "pending", version: 1, title: "新建合成提案", confidence: 9300, missing: []))
        default:
            break
        }

        guard request.path.hasPrefix("ai/proposals/"), let id = request.path.split(separator: "/").dropFirst(2).first.flatMap({ UUID(uuidString: String($0)) }) else {
            throw V15Failure(kind: .transport, message: "F3-F fixture 不支持 \(request.method) \(request.path)。")
        }
        let suffix = request.path.split(separator: "/").count > 3 ? String(request.path.split(separator: "/").last!) : nil
        if request.method == "GET", suffix == "quality-events" { return try decode(V15F3FFixtures.events(id)) }
        if request.method == "GET" {
            if mode == .deleteUnknownReadFailure, directCount > 0, id == V15F3FFixtures.pendingID, recoveryReadFailures == 0 {
                recoveryReadFailures += 1
                throw V15Failure(kind: .transport, message: "网络暂时不可用。")
            }
            if deleted.contains(id) { throw V15Failure(kind: .transport, code: "ai_proposal_not_found", message: "这项内容不存在或已经删除。") }
            if mode == .directUnknownReadDelayed, directCount > 0, id == V15F3FFixtures.pendingID { try await Task.sleep(for: .seconds(5)) }
            if (mode == .directUnknownReadFailure || mode == .conflictReloadFailure), directCount > 0, id == V15F3FFixtures.pendingID, recoveryReadFailures == 0 {
                recoveryReadFailures += 1
                throw V15Failure(kind: .transport, message: "网络暂时不可用。")
            }
            if mode == .selectionRace, id == V15F3FFixtures.pendingID { try await Task.sleep(for: .milliseconds(180)) }
            if mode == .serverChanged, directCount > 0, id == V15F3FFixtures.pendingID { return try decode(V15F3FFixtures.proposal(id: id, status: "pending", version: 9, title: "第三方已更新审核草案", confidence: 9_800, missing: [], categoryID: V15F3FFixtures.expenseCategoryID)) }
            if let value = current[id] { return try decode(value) }
            if id == V15F3FFixtures.failedID { return try decode(V15F3FFixtures.proposal(id: id, status: "failed", errorCode: "ai_provider_timeout", errorMessage: "AI 响应超时。请稍后重试。")) }
            if id == V15F3FFixtures.executedID { return try decode(V15F3FFixtures.proposal(id: id, status: "executed", version: 5, missing: [], transaction: true)) }
            if id == V15F3FFixtures.cashFlowProposalID { return try decode(V15F3FFixtures.proposal(id: id, status: "pending", title: "下个月房租现金流提案", missing: [], target: "cash_flow")) }
            if id == V15F3FFixtures.unknownID { return try decode(V15F3FFixtures.proposal(id: id, status: "future_review", missing: [])) }
            return try decode(V15F3FFixtures.proposal(id: id, status: "pending"))
        }
        directCount += 1
        if mode == .fieldError, request.method == "PUT" { throw V15Failure(kind: .transport, code: "validation_error", message: "请修正审核字段。", fieldIssues: [.init(code: "category_required", message: "请选择支出分类。", fieldPath: "draft.category_id")]) }
        if mode == .conflict || mode == .conflictReloadFailure { throw V15Failure(kind: .conflict, code: "ai_proposal_version_conflict", message: "提案版本已变化。", conflict: .init(reloadPath: "/api/v1/ai/proposals/\(id)", latestRevision: nil, currentVersion: 9, expectedVersion: 2, message: "提案版本已变化。")) }
        if (mode == .directUnknown || mode == .directUnknownReadFailure || mode == .directUnknownReadDelayed || mode == .directUnknownSettingsViolationAfterSafe) && directCount == 1 { throw V15Failure(kind: .responseUnknown, message: "提案写入响应未知。") }
        if request.method == "PUT" {
            let cashFlow = id == V15F3FFixtures.cashFlowProposalID
            let payload = (try? JSONSerialization.jsonObject(with: Data(bodyText.utf8))) as? [String: Any]
            let draft = payload?["draft"] as? [String: Any]
            func identifier(_ key: String) -> UUID? { (draft?[key] as? String).flatMap(UUID.init(uuidString:)) }
            let canonicalTitle = (draft?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let canonicalNote = (draft?["note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let value = V15F3FFixtures.proposal(
                id: id,
                status: "pending",
                version: 3,
                title: canonicalTitle,
                amount: (draft?["amount_minor"] as? NSNumber)?.int64Value,
                confidence: 9_800,
                missing: [],
                target: cashFlow ? "cash_flow" : "transaction",
                kind: draft?["kind"] as? String ?? "expense",
                occurredAt: draft?["occurred_at"] as? String ?? "2026-09-16T04:30:00Z",
                note: canonicalNote,
                accountID: identifier("account_id"),
                categoryID: identifier("category_id"),
                destinationAccountID: identifier("destination_account_id"),
                creditCycleID: identifier("credit_cycle_id")
            )
            current[id] = value; return try decode(value)
        }
        let status: String = switch suffix { case "execute": "executed"; case "ignore": "ignored"; case "retry": "pending"; case "undo": "undone"; default: "pending" }
        let target = id == V15F3FFixtures.cashFlowProposalID ? "cash_flow" : "transaction"
        let value = V15F3FFixtures.proposal(id: id, status: status, version: 4, title: "人工确认后的工作餐", confidence: 9_800, missing: [], transaction: status == "executed" && target == "transaction", target: target, categoryID: V15F3FFixtures.expenseCategoryID)
        current[id] = value
        if suffix == "execute" || suffix == "undo" { return try decode("{\"proposal\":\(value),\"transaction\":null,\"cash_flow_item\":null}") }
        return try decode(value)
    }

    func sendNoContent(_ request: V15Request, body: JSONValue?) async throws {
        requests.append(request)
        let bodyText = body.flatMap { try? String(data: V15BodyEncoder.data($0), encoding: .utf8) } ?? ""
        if request.method != "GET" { wires.append(.init(method: request.method, path: request.path, body: bodyText, headers: request.headers, query: Dictionary(uniqueKeysWithValues: request.query.compactMap { item in item.value.map { (item.name, $0) } }))) }
        guard request.method == "DELETE",
              request.path.hasPrefix("ai/proposals/"),
              let id = request.path.split(separator: "/").last.flatMap({ UUID(uuidString: String($0)) })
        else { throw V15Failure(kind: .transport, message: "F3-F fixture 不支持 \(request.method) \(request.path)。") }
        directCount += 1
        if mode == .conflict || mode == .conflictReloadFailure {
            throw V15Failure(kind: .conflict, code: "resource_version_conflict", message: "内容版本已变化。", conflict: .init(reloadPath: "/api/v1/ai/proposals/\(id)", latestRevision: nil, currentVersion: 9, expectedVersion: 2, message: "内容版本已变化。"))
        }
        if mode == .deleteUnknownStillPresent, directCount == 1 {
            throw V15Failure(kind: .responseUnknown, message: "删除响应未知。")
        }
        deleted.insert(id)
        if (mode == .deleteUnknown || mode == .deleteUnknownReadFailure), directCount == 1 {
            throw V15Failure(kind: .responseUnknown, message: "删除响应未知。")
        }
    }

    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { throw V15Failure(kind: .transport, message: "F3-F 无文件读取。") }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
