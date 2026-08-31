import Foundation

/// Offline-only F3-A pages. Values are intentionally synthetic and locators
/// are source-shaped so screenshots cannot disclose a real account or receipt.
public enum V15F3AFixtures {
    public static let creditID = UUID(uuidString: "00000000-0000-0000-0000-00000000F301")!
    public static let partyID = UUID(uuidString: "00000000-0000-0000-0000-00000000F302")!
    public static let cashID = UUID(uuidString: "00000000-0000-0000-0000-00000000F303")!
    public static let accountID = UUID(uuidString: "00000000-0000-0000-0000-00000000F304")!
    public static let emptyAccountID = UUID(uuidString: "00000000-0000-0000-0000-00000000F307")!
    public static let claimID = UUID(uuidString: "00000000-0000-0000-0000-00000000F308")!
    @MainActor public static func services(route: String = "timeline") -> V15Services { .init(transport: F3ATransport(mode: .route(route))) }
    static func page(revision: Int64 = 77, items: String = itemsJSON, cursor: String? = "opaque-f3a-next", account: UUID? = nil) -> Data {
        let accountJSON = account.map { "\"\($0.uuidString)\"" } ?? "null"
        let cursorJSON = cursor.map { "\"\($0)\"" } ?? "null"
        return Data("{\"meta\":{\"timezone\":\"Asia/Shanghai\",\"currency\":\"CNY\",\"as_of\":\"2026-08-15T16:01:02Z\",\"data_revision\":\(revision),\"schema_version\":\"1\"},\"window\":{\"date_from\":\"2026-08-16\",\"date_to\":\"2026-09-14\"},\"account_id\":\(accountJSON),\"items\":\(items),\"next_cursor\":\(cursorJSON)}".utf8)
    }
    static let itemsJSON = """
    [
      {"source_type":"credit_cycle","source_id":"\(creditID.uuidString)","date":"2026-08-20","direction":"outflow","amount_minor":922337203685477580,"certainty":"exact_due","title":"超长中文信用账期到期事项，用于确认无截断展示","deep_link":"fiscal://credit/cycles/\(creditID.uuidString)","account_id":"\(accountID.uuidString)","claim_id":null,"party_id":null,"cycle_id":"\(creditID.uuidString)"},
      {"source_type":"reimbursement_party","source_id":"\(partyID.uuidString)","date":"2026-08-22","direction":"inflow","amount_minor":123456,"certainty":"confirmed","title":"报销回款","deep_link":"fiscal://reimbursements/\(claimID.uuidString)/parties/\(partyID.uuidString)","account_id":null,"claim_id":"\(claimID.uuidString)","party_id":"\(partyID.uuidString)","cycle_id":null},
      {"source_type":"cash_flow_item","source_id":"\(cashID.uuidString)","date":"2026-08-25","direction":"outflow","amount_minor":4500,"certainty":"expected","title":"预计订阅扣款","deep_link":"fiscal://cash-flow/items/\(cashID.uuidString)","account_id":null,"claim_id":null,"party_id":null,"cycle_id":null},
      {"source_type":"cash_flow_item","source_id":"00000000-0000-0000-0000-00000000F305","date":"2026-08-27","direction":"outflow","amount_minor":8800,"certainty":"scheduled","title":"已排期现金流事项","deep_link":"fiscal://cash-flow/items/00000000-0000-0000-0000-00000000F305","account_id":null,"claim_id":null,"party_id":null,"cycle_id":null}
    ]
    """
    static let nextItemsJSON = """
    [{"source_type":"cash_flow_item","source_id":"00000000-0000-0000-0000-00000000F306","date":"2026-08-30","direction":"outflow","amount_minor":1200,"certainty":"scheduled","title":"第二页事项","deep_link":"fiscal://cash-flow/items/00000000-0000-0000-0000-00000000F306","account_id":null,"claim_id":null,"party_id":null,"cycle_id":null}]
    """
    static let emptyItemsJSON = "[]"
    static func creditCycle(accountID: UUID = accountID) -> Data {
        Data("""
        {"id":"\(creditID)","account_id":"\(accountID)","period_start":"2026-07-21","period_end":"2026-08-20","statement_date":"2026-08-20","due_date":"2026-09-05","is_opening_cycle":false,"purchase_minor":3000,"opening_minor":0,"amount_due_minor":3000,"repaid_minor":0,"remaining_minor":3000,"status":"unpaid","is_overdue":false,"version":2,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-15T00:00:00Z","installment_principal_minor":0,"installment_fee_minor":0,"installment_periods":[]}
        """.utf8)
    }
    static let claim = Data("""
    {"id":"\(claimID)","title":"未来报销","note":null,"status":"pending","total_claimed_minor":123456,"received_minor":0,"outstanding_minor":123456,"expense_count":0,"party_count":1,"receipt_count":0,"parties":[{"id":"\(partyID)","name":"示例公司","expected_date":"2026-08-22","note":null,"claimed_minor":123456,"received_minor":0,"outstanding_minor":123456,"status":"pending","position":0,"allocations":[]}],"latest_receipt":null,"version":2,"submitted_at":"2026-08-10T00:00:00Z","cancelled_at":null,"voided_at":null,"archived_at":null,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-15T00:00:00Z"}
    """.utf8)
    static let cashFlowItem = Data("""
    {"id":"\(cashID)","manual_item_id":"\(cashID)","system_kind":null,"system_reference_id":null,"series_id":null,"title":"预计订阅扣款","note":null,"direction":"outflow","planned_amount_minor":4500,"expected_date":"2026-08-25","account_id":null,"destination_account_id":null,"category_id":null,"status":"expected","source":"manual","version":1,"linked_transaction_id":null,"actual_amount_minor":null,"actual_date":null,"is_overdue":false,"actions":["confirm"],"credit_cycle_parts":[],"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-15T00:00:00Z"}
    """.utf8)
    static let accountsJSON = """
    [
      {"id":"\(accountID.uuidString)","name":"日常现金","kind":"cash","institution":null,"last_four":null,"opening_balance_minor":0,"current_balance_minor":100000,"credit_limit_minor":null,"statement_day":null,"due_day":null,"cycle_mode":null,"opening_balance_as_of_date":null,"opening_due_date":null,"sort_order":1,"archived_at":null,"usage_count":3,"version":2,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-15T00:00:00Z"},
      {"id":"\(emptyAccountID.uuidString)","name":"旅行现金","kind":"cash","institution":null,"last_four":null,"opening_balance_minor":0,"current_balance_minor":2000,"credit_limit_minor":null,"statement_day":null,"due_day":null,"cycle_mode":null,"opening_balance_as_of_date":null,"opening_due_date":null,"sort_order":2,"archived_at":null,"usage_count":0,"version":1,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-15T00:00:00Z"}
    ]
    """
}

actor F3ATransport: V15Transporting {
    enum Mode: Equatable { case normal, empty, pageFailure, conflictThenFresh, refreshRace, firstFailure, accountFailure, accountRace, ownerMismatch, openRace
        static func route(_ value: String) -> Mode { switch value { case "timeline-empty": .empty; case "timeline-page-error": .pageFailure; case "timeline-conflict": .conflictThenFresh; case "timeline-race": .refreshRace; case "timeline-error": .firstFailure; case "timeline-account-error": .accountFailure; case "timeline-account-race": .accountRace; default: .normal } }
    }
    let mode: Mode; private var requests: [V15Request] = []; private var futureEventReads = 0; private var accountReads = 0
    init(mode: Mode) { self.mode = mode }
    func allRequests() -> [V15Request] { requests }
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        requests.append(request)
        if request.path == "accounts", request.method == "GET" {
            accountReads += 1
            if mode == .accountFailure { throw V15Failure(kind: .transport, message: "可筛选账户读取失败。") }
            if mode == .accountRace, accountReads == 1 { try await Task.sleep(for: .milliseconds(120)) }
            return try V15FixtureCodec.decoder.decode(Response.self, from: Data(V15F3AFixtures.accountsJSON.utf8))
        }
        if request.path == "credit-cycles/\(V15F3AFixtures.creditID)", request.method == "GET" {
            if mode == .openRace { try await Task.sleep(for: .milliseconds(120)) }
            let accountID = mode == .ownerMismatch ? V15F3AFixtures.emptyAccountID : V15F3AFixtures.accountID
            return try V15FixtureCodec.decoder.decode(Response.self, from: V15F3AFixtures.creditCycle(accountID: accountID))
        }
        if request.path == "reimbursement-claims/\(V15F3AFixtures.claimID)", request.method == "GET" {
            return try V15FixtureCodec.decoder.decode(Response.self, from: V15F3AFixtures.claim)
        }
        if request.path == "cash-flow-items/\(V15F3AFixtures.cashID)", request.method == "GET" {
            return try V15FixtureCodec.decoder.decode(Response.self, from: V15F3AFixtures.cashFlowItem)
        }
        guard request.path == "reports/future-events", request.method == "GET" else { throw V15Failure(kind: .transport, message: "F3-A fixture only supports future-events and active-account reads.") }
        futureEventReads += 1
        if mode == .refreshRace, futureEventReads == 1 { try await Task.sleep(for: .milliseconds(120)) }
        let cursor = request.query.first(where: { $0.name == "cursor" })?.value
        if mode == .firstFailure { throw V15Failure(kind: .transport, message: "未来时间线读取失败。") }
        if mode == .pageFailure, cursor != nil { throw V15Failure(kind: .transport, message: "下一页未来事项读取失败。") }
        if mode == .conflictThenFresh, futureEventReads == 1 { throw V15Failure(kind: .conflict, code: "future_events_scope_changed", message: "未来事项范围已变化，请重新读取。", conflict: .init(reloadPath: "/api/v1/reports/future-events", latestRevision: 78, currentDataRevision: 78, safeToReload: true, message: "future conflict")) }
        let account = request.query.first(where: { $0.name == "account_id" })?.value.flatMap(UUID.init(uuidString:))
        let data: Data
        if mode == .empty || account == V15F3AFixtures.emptyAccountID { data = V15F3AFixtures.page(items: V15F3AFixtures.emptyItemsJSON, cursor: nil, account: account) }
        else if cursor != nil { data = V15F3AFixtures.page(revision: mode == .conflictThenFresh ? 78 : 77, items: V15F3AFixtures.nextItemsJSON, cursor: nil, account: account) }
        else { data = V15F3AFixtures.page(revision: mode == .conflictThenFresh ? 78 : 77, account: account) }
        return try V15FixtureCodec.decoder.decode(Response.self, from: data)
    }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { throw V15Failure(kind: .transport, message: "F3-A has no artifact endpoint.") }
}
