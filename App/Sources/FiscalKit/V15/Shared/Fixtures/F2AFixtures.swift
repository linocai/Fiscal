import Foundation

enum V15F2AFixtures {
    static let accountID = UUID(uuidString: "00000000-0000-0000-0000-00000000F201")!
    static let transactionID = UUID(uuidString: "00000000-0000-0000-0000-00000000F202")!
    static let cycleID = UUID(uuidString: "00000000-0000-0000-0000-00000000F203")!
    static let claimID = UUID(uuidString: "00000000-0000-0000-0000-00000000F204")!
    static let partyID = UUID(uuidString: "00000000-0000-0000-0000-00000000F205")!
    static let proposalID = UUID(uuidString: "00000000-0000-0000-0000-00000000F208")!
    static let migrationID = UUID(uuidString: "00000000-0000-0000-0000-00000000F209")!
    static let cashFlowID = UUID(uuidString: "00000000-0000-0000-0000-00000000F210")!
    static let importID = UUID(uuidString: "00000000-0000-0000-0000-00000000F211")!

    static func facts(revision: Int64 = 42) -> Data {
        Data("""
        {"meta":{"timezone":"Asia/Shanghai","currency":"CNY","as_of":"2026-08-15T16:01:02Z","data_revision":\(revision),"schema_version":"1"},"window":{"date_from":"2026-08-16","date_to":"2026-09-14"},"cash":{"current_balance_minor":9223372036854775807,"scope":\(scope("cash_accounts", revision))},"credit":{"current_debt_minor":-4567,"scope":\(scope("credit_cycles", revision))},"reimbursements":{"outstanding_minor":900,"scope":\(scope("reimbursement_outstanding", revision))},"completeness":{"unresolved_import_count":1,"failed_import_count":2,"uncategorized_transaction_count":3,"uncategorized_transaction_amount_minor":500,"scope":\(scope("completeness_issues", revision))},"future":{"exact_due_outflow_minor":200,"confirmed_outflow_minor":100,"expected_outflow_minor":300,"scheduled_outflow_minor":400,"confirmed_inflow_minor":50,"expected_inflow_minor":500,"scheduled_inflow_minor":0,"after_confirmed_outflow_minor":9223372036854775707},"known_future_events":[{"source_type":"credit_cycle","source_id":"\(cycleID)","date":"2026-08-20","direction":"outflow","amount_minor":200,"certainty":"exact_due","title":"信用卡还款","deep_link":"fiscal://credit/cycles/\(cycleID)","account_id":"\(accountID)","claim_id":null,"party_id":null,"cycle_id":"\(cycleID)"}]}
        """.utf8)
    }
    static func invalidFacts(revision: Int64 = 42) -> Data {
        Data(String(decoding: facts(revision: revision), as: UTF8.self).replacingOccurrences(of: "Asia/Shanghai", with: "UTC").utf8)
    }

    static func scope(_ type: String, _ revision: Int64) -> String {
        "{\"scope_type\":\"\(type)\",\"schema_version\":\"1\",\"expected_data_revision\":\(revision),\"read_path\":\"/api/v1/reports/facts/drill-down?scope=\(type)&expected_data_revision=\(revision)\",\"deep_link\":\"fiscal://reports/facts/\(type)\"}"
    }

    static func page(scope type: String, revision: Int64 = 42, nextCursor: String? = nil) -> Data {
        let item: String
        switch type {
        case "cash_accounts": item = "{\"item_type\":\"cash_account\",\"account_id\":\"\(accountID)\",\"name\":\"日常现金\",\"current_balance_minor\":9223372036854775807,\"read_path\":\"/api/v1/accounts/\(accountID)\",\"deep_link\":\"fiscal://accounts/\(accountID)\"}"
        case "credit_cycles": item = "{\"item_type\":\"credit_cycle\",\"cycle_id\":\"\(cycleID)\",\"account_id\":\"\(accountID)\",\"account_name\":\"信用账户\",\"due_date\":\"2026-08-20\",\"amount_due_minor\":1000,\"repaid_minor\":200,\"remaining_minor\":800,\"read_path\":\"/api/v1/credit-cycles/\(cycleID)\",\"deep_link\":\"fiscal://credit/cycles/\(cycleID)\"}"
        case "reimbursement_outstanding": item = "{\"item_type\":\"reimbursement_outstanding\",\"claim_id\":\"\(claimID)\",\"party_id\":\"\(partyID)\",\"party_name\":\"同事\",\"expected_date\":\"2026-08-25\",\"expected_minor\":1200,\"received_minor\":200,\"outstanding_minor\":1000,\"read_path\":\"/api/v1/reimbursement-claims/\(claimID)\",\"deep_link\":\"fiscal://reimbursements/\(claimID)\"}"
        default: item = "{\"item_type\":\"completeness_issue\",\"issue_type\":\"uncategorized_transactions\",\"count\":3,\"amount_minor\":500,\"read_path\":\"/api/v1/transactions?classification=uncategorized\",\"deep_link\":\"fiscal://transactions?classification=uncategorized\"}"
        }
        let cursor = nextCursor.map { "\"\($0)\"" } ?? "null"
        return Data("{\"meta\":{\"timezone\":\"Asia/Shanghai\",\"currency\":\"CNY\",\"as_of\":\"2026-08-15T16:01:02Z\",\"data_revision\":\(revision),\"schema_version\":\"1\"},\"scope\":\(scope(type, revision)),\"items\":[\(item)],\"next_cursor\":\(cursor)}".utf8)
    }

    static let emptyPage = Data("{\"meta\":{\"timezone\":\"Asia/Shanghai\",\"currency\":\"CNY\",\"as_of\":\"2026-08-15T16:01:02Z\",\"data_revision\":42,\"schema_version\":\"1\"},\"scope\":\(scope("completeness_issues", 42)),\"items\":[],\"next_cursor\":null}".utf8)
    static let account = Data("{\"id\":\"\(accountID)\",\"name\":\"日常现金\",\"kind\":\"cash\",\"institution\":null,\"last_four\":null,\"opening_balance_minor\":0,\"current_balance_minor\":100000,\"credit_limit_minor\":null,\"statement_day\":null,\"due_day\":null,\"cycle_mode\":null,\"opening_balance_as_of_date\":null,\"opening_due_date\":null,\"sort_order\":1,\"archived_at\":null,\"usage_count\":3,\"version\":2,\"created_at\":\"2026-08-01T00:00:00Z\",\"updated_at\":\"2026-08-15T00:00:00Z\"}".utf8)
    static let transaction = Data("{\"id\":\"\(transactionID)\",\"kind\":\"expense\",\"amount_minor\":1280,\"occurred_at\":\"2026-08-15T04:00:00Z\",\"business_date\":\"2026-08-15\",\"title\":\"午餐\",\"note\":null,\"category_id\":null,\"account_id\":\"\(accountID)\",\"destination_account_id\":null,\"credit_cycle_id\":null,\"source\":\"manual\",\"postings\":[{\"id\":\"00000000-0000-0000-0000-00000000F206\",\"account_id\":\"\(accountID)\",\"role\":\"account\",\"amount_minor\":-1280,\"position\":0}],\"version\":1,\"voided_at\":null,\"created_at\":\"2026-08-15T04:00:00Z\",\"updated_at\":\"2026-08-15T04:00:00Z\",\"installment_plan_id\":null,\"installment_relation\":null,\"reimbursement_relations\":[],\"available_actions\":[]}".utf8)
    static let unknownItem = Data("{\"item_type\":\"new_server_type\",\"deep_link\":\"fiscal://transactions/\(transactionID)\"}".utf8)
}

actor V15F2ATransport: V15Transporting {
    enum Mode { case normal, scopeConflict, scopeConflictThenRefreshFailure, scopeConflictThenNewRevision, scopeConflictForceRefreshSequence, scopeConflictForceRefreshInvalidFacts, pageFailure, refreshRace, emptyScope, factsFailure, slowScope, linkedReadFailsThenSucceeds, slowLinkedRead }
    private let mode: Mode
    private var requests: [V15Request] = []
    private var factsReads = 0
    init(mode: Mode = .normal) { self.mode = mode }

    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        requests.append(request)
        guard request.method == "GET", body == nil else { throw V15Failure(kind: .offlineReadOnly, code: "write_forbidden", message: "F2-A 夹具不允许写入。") }
        let data: Data
        switch request.path {
        case "reports/facts":
            if mode == .factsFailure { throw V15Failure(kind: .transport, message: "事实服务不可用。") }
            factsReads += 1
            if mode == .scopeConflictThenRefreshFailure, factsReads > 1 {
                throw V15Failure(kind: .transport, message: "重载事实失败。")
            } else if mode == .scopeConflictThenNewRevision, factsReads > 1 {
                data = V15F2AFixtures.facts(revision: 43)
            } else if usesForcedRecoverySequence, factsReads > 1 {
                guard request.readCachePolicy == .reloadIgnoringCache else { throw V15Failure(kind: .decoding, code: "facts_reload_not_forced", message: "409 后必须绕过缓存读取 facts。") }
                data = factsReads == 2 && mode == .scopeConflictForceRefreshInvalidFacts ? V15F2AFixtures.invalidFacts() : V15F2AFixtures.facts(revision: factsReads == 2 ? 42 : 43)
            } else if mode == .refreshRace, factsReads == 1 {
                try await Task.sleep(for: .milliseconds(80)); data = V15F2AFixtures.facts(revision: 41)
            } else {
                data = V15F2AFixtures.facts()
            }
        case "reports/facts/drill-down":
            let scope = request.query.first(where: { $0.name == "scope" })?.value ?? ""
            if mode == .scopeConflict || mode == .scopeConflictThenRefreshFailure || ((mode == .scopeConflictThenNewRevision || usesForcedRecoverySequence) && request.query.contains(where: { $0.name == "expected_data_revision" && $0.value == "42" })) { throw V15Failure(kind: .conflict, code: "report_facts_scope_changed", message: "事实已变化。", conflict: .init(reloadPath: "/api/v1/reports/facts", latestRevision: 43, expectedDataRevision: 42, currentDataRevision: 43, safeToReload: true, message: "事实已变化。")) }
            if mode == .pageFailure, request.query.contains(where: { $0.name == "cursor" }) { throw V15Failure(kind: .transport, message: "下一页失败。") }
            if mode == .slowScope { try await Task.sleep(for: .milliseconds(80)) }
            let revision: Int64 = (mode == .scopeConflictThenNewRevision || usesForcedRecoverySequence) ? 43 : 42
            data = mode == .emptyScope ? V15F2AFixtures.emptyPage : V15F2AFixtures.page(scope: scope, revision: revision, nextCursor: scope == "cash_accounts" && !request.query.contains(where: { $0.name == "cursor" }) ? "opaque-cash" : nil)
        case "accounts/\(V15F2AFixtures.accountID)": data = V15F2AFixtures.account
        case "transactions/\(V15F2AFixtures.transactionID)":
            let linkedReadCount = requests.filter { $0.path == request.path }.count
            if mode == .linkedReadFailsThenSucceeds, linkedReadCount == 1 {
                throw V15Failure(kind: .transport, message: "账目只读信息暂时无法读取。")
            }
            if mode == .slowLinkedRead { try await Task.sleep(for: .milliseconds(80)) }
            data = V15F2AFixtures.transaction
        default: throw V15Failure(kind: .transport, code: "unexpected_path", message: "不应请求：\(request.path)")
        }
        return try V15FixtureCodec.decoder.decode(Response.self, from: data)
    }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { throw V15Failure(kind: .transport, message: "无工件夹具。") }
    func allRequests() -> [V15Request] { requests }
    private var usesForcedRecoverySequence: Bool {
        switch mode {
        case .scopeConflictForceRefreshSequence, .scopeConflictForceRefreshInvalidFacts: true
        default: false
        }
    }
}

/// Mirrors production's timing: the revision store only learns it is reading
/// a persisted snapshot after an awaited transport fallback, not at model init.
actor V15F2AOfflineSnapshotTransport: V15Transporting {
    private let revisionStore: DataRevisionStore
    private let snapshotAt: Date
    private var requests: [V15Request] = []
    init(revisionStore: DataRevisionStore, snapshotAt: Date) { self.revisionStore = revisionStore; self.snapshotAt = snapshotAt }

    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        requests.append(request)
        guard request.method == "GET", body == nil else { throw V15Failure(kind: .offlineReadOnly, code: "write_forbidden", message: "F2-A 夹具不允许写入。") }
        let data: Data
        switch request.path {
        case "reports/facts":
            await Task.yield()
            await revisionStore.markOfflineSnapshot(at: snapshotAt)
            data = V15F2AFixtures.facts()
        default: throw V15Failure(kind: .transport, code: "unexpected_path", message: "不应请求：\(request.path)")
        }
        return try V15FixtureCodec.decoder.decode(Response.self, from: data)
    }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { throw V15Failure(kind: .transport, message: "无工件夹具。") }
    func allRequests() -> [V15Request] { requests }
}
