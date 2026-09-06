import Foundation

/// Gallery-only F2-B data.  It stays deliberately read-only and derives every
/// facts/scope payload from the F2-A contract fixtures, so the Today surface
/// never invents a second facts schema for visual states.
public enum V15F2BFixtures {
    enum Route: String {
        case normal = "today"
        case emptyScopes = "today-empty-scopes"
        case factsError = "today-facts-error"
        case scopeError = "today-scope-error"
        case pageError = "today-page-error"
        case conflict = "today-conflict"
        /// F2-C UI-only race fixture: the conflict refresh remains in flight
        /// until the test has observed the real loading pane and changed lens.
        case refreshLensRace = "today-refresh-lens-race"
        case refreshDelay = "today-refresh-delay"
        case offline = "today-offline"
        case long = "today-long"
        case zeroFuture = "today-zero-future"
        case unknownScope = "today-unknown-scope"
        /// Formal-root normal-state QA uses ordinary business values.
        case rootWorkspace = "today-root-workspace"
        /// This is deliberately a separate root host route: it proves that
        /// the production composition contains F2-A's Int64 boundary values
        /// locally instead of letting them widen the whole screen.
        case rootWorkspaceBoundary = "today-root-workspace-boundary"
    }

    @MainActor public static func services(route: String, accountOverflow: Bool = false, reviewScenario: String = "") -> V15Services {
        let pending = V15PendingWriteStore()
        if reviewScenario == "offline-pending" {
            pending.enqueueCreate(.init(kind: .expense, amountMinor: 100, occurredAt: offlineSnapshotAt,
                                        title: "隔离测试待同步", accountID: V15F1AFixtures.accountID))
        }
        return V15Services(transport: V15F2BFixtureTransport(route: Route(rawValue: route) ?? .normal, accountOverflow: accountOverflow, reviewScenario: reviewScenario),
                           offlineSnapshotProvider: { reviewScenario == "offline-pending" ? offlineSnapshotAt : nil }, pendingWrites: pending)
    }

    static let offlineSnapshotAt = Date(timeIntervalSince1970: 1_786_464_000)

}

actor V15F2BFixtureTransport: V15Transporting {
    private let route: V15F2BFixtures.Route
    private let accountOverflow: Bool
    private var factsReads = 0
    private var accountReads = 0
    private var transactionReads = 0
    private var cycleReads = 0
    private var categoryReads = 0
    private let reviewScenario: String
    private var requests: [V15Request] = []

    init(route: V15F2BFixtures.Route, accountOverflow: Bool = false, reviewScenario: String = "") {
        self.reviewScenario = route == .rootWorkspace ? reviewScenario : ""
        self.route = route
        self.accountOverflow = accountOverflow && route == .rootWorkspace
    }

    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        requests.append(request)
        guard request.method == "GET", body == nil else {
            throw V15Failure(kind: .offlineReadOnly, code: "write_forbidden", message: "F2-B 画廊只允许只读请求。")
        }
        let data: Data
        switch request.path {
        case "accounts":
            accountReads += 1
            if reviewScenario == "accounts-error", accountReads <= 4 {
                throw V15Failure(kind: .transport, message: "测试账户读取暂时失败。")
            }
            if reviewScenario == "accounts-empty" { data = Data("[]".utf8) }
            else if reviewScenario == "refresh", accountReads >= 4 {
                var values = try JSONSerialization.jsonObject(with: V15F1AFixtures.accounts) as! [[String: Any]]
                values[0]["name"] = "复核后现金"
                data = try JSONSerialization.data(withJSONObject: values)
            } else { data = accountOverflow ? V15F2BFixtures.overflowAccounts : V15F1AFixtures.accounts }
        case let path where accountOverflow && path.hasPrefix("accounts/"):
            let id = String(path.dropFirst("accounts/".count))
            let accounts = try JSONSerialization.jsonObject(with: V15F2BFixtures.overflowAccounts) as! [[String: Any]]
            guard let account = accounts.first(where: { ($0["id"] as? String)?.lowercased() == id.lowercased() }) else {
                throw V15Failure(kind: .transport, message: "缺少测试账户。")
            }
            data = try JSONSerialization.data(withJSONObject: account)
        case "categories":
            categoryReads += 1
            if reviewScenario == "categories-error", categoryReads == 1 {
                throw V15Failure(kind: .transport, message: "测试分类暂时不可用。")
            }
            data = V15F1AFixtures.categories
        case "transactions":
            transactionReads += 1
            if reviewScenario == "recent-error", transactionReads == 1 {
                throw V15Failure(kind: .transport, message: "测试最近交易暂时失败。")
            }
            let accountID = request.query.first(where: { $0.name == "account_id" })?.value
            data = reviewScenario == "recent-empty" || (accountOverflow && accountID?.hasSuffix("205") == true)
                ? Data(#"{"items":[],"next_cursor":null}"#.utf8) : V15F1BFixtures.page
        case "reports/future-events" where route == .rootWorkspace || route == .rootWorkspaceBoundary:
            let account = request.query.first(where: { $0.name == "account_id" })?.value
            data = V15F2BFixtures.rootWorkspaceFutureEvents(accountID: account)
        case "reports/facts":
            if route == .factsError { throw V15Failure(kind: .transport, message: "当前事实服务暂时不可用。") }
            factsReads += 1
            if (route == .conflict || route == .refreshLensRace), factsReads > 1 {
                guard request.readCachePolicy == .reloadIgnoringCache else {
                    throw V15Failure(kind: .decoding, code: "facts_reload_not_forced", message: "冲突后应强制重新读取当前事实。")
                }
                if route == .refreshLensRace { try await Task.sleep(for: .seconds(2)) }
                data = V15F2AFixtures.facts(revision: 43)
            } else if route == .refreshDelay, factsReads > 1 {
                try await Task.sleep(for: .seconds(1))
                data = V15F2AFixtures.facts()
            } else if route == .rootWorkspace {
                if reviewScenario == "refresh", factsReads > 1 {
                    var value = try JSONSerialization.jsonObject(with: V15F2BFixtures.rootWorkspaceFacts) as! [String: Any]
                    var cash = value["cash"] as! [String: Any]
                    cash["current_balance_minor"] = 288_650
                    value["cash"] = cash
                    data = try JSONSerialization.data(withJSONObject: value)
                } else { data = V15F2BFixtures.rootWorkspaceFacts }
            } else if route == .rootWorkspaceBoundary {
                data = V15F2AFixtures.facts()
            } else if route == .zeroFuture {
                data = V15F2BFixtures.zeroFutureFacts
            } else {
                data = V15F2AFixtures.facts()
            }
        case "reports/facts/drill-down":
            let scope = request.query.first(where: { $0.name == "scope" })?.value ?? ""
            let hasCursor = request.query.contains(where: { $0.name == "cursor" })
            if route == .scopeError { throw V15Failure(kind: .transport, message: "该事实范围暂时无法读取。") }
            if route == .pageError, hasCursor { throw V15Failure(kind: .transport, message: "下一页暂时无法读取。") }
            if (route == .conflict || route == .refreshLensRace), request.query.contains(where: { $0.name == "expected_data_revision" && $0.value == "42" }) {
                throw V15Failure(kind: .conflict, code: "report_facts_scope_changed", message: "当前事实已变化。", conflict: .init(reloadPath: "/api/v1/reports/facts", latestRevision: 43, expectedDataRevision: 42, currentDataRevision: 43, safeToReload: true, message: "当前事实已变化。"))
            }
            let revision: Int64 = (route == .conflict || route == .refreshLensRace) ? 43 : 42
            if route == .unknownScope, scope == "cash_accounts" {
                data = V15F2BFixtures.unknownScopePage
            } else {
                data = route == .emptyScopes ? V15F2AFixtures.emptyPage : V15F2AFixtures.page(scope: scope, revision: revision, nextCursor: scope == "cash_accounts" && !hasCursor ? "f2b-opaque-cash" : nil)
            }
        case "accounts/\(V15F2AFixtures.accountID)": data = V15F2AFixtures.account
        case "transactions/\(V15F2AFixtures.transactionID)": data = V15F2AFixtures.transaction
        case "transactions/\(V15F1BFixtures.transactionID)" where route == .rootWorkspace || route == .rootWorkspaceBoundary:
            data = V15F1BFixtures.detail
        case "transactions/\(V15F1BFixtures.transactionID)/revisions" where route == .rootWorkspace || route == .rootWorkspaceBoundary:
            data = V15F1BFixtures.revisions
        case "transactions/\(V15F1BFixtures.transactionID)/provenance" where route == .rootWorkspace || route == .rootWorkspaceBoundary:
            data = V15F1BFixtures.provenance
        case "transactions/\(V15F1BFixtures.otherTransactionID)" where route == .rootWorkspace:
            data = V15F1BFixtures.other
        case "transactions/\(V15F1BFixtures.otherTransactionID)/revisions" where route == .rootWorkspace:
            data = Data(#"{"items":[]}"#.utf8)
        case "transactions/\(V15F1BFixtures.otherTransactionID)/provenance" where route == .rootWorkspace:
            data = V15F1BFixtures.provenance
        case "credit-cycles/\(V15F2AFixtures.cycleID)" where reviewScenario == "future-retry":
            cycleReads += 1
            if cycleReads == 1 { throw V15Failure(kind: .transport, message: "测试账期核验暂时失败。") }
            data = Data(V15F3B1Fixtures.cycle(V15F2AFixtures.cycleID, accountID: V15F2AFixtures.accountID, opening: false, overdue: false, status: "open").utf8)
        case let path where path.hasPrefix("reports/v2/monthly/"):
            guard route == .rootWorkspace || route == .rootWorkspaceBoundary else {
                throw V15Failure(kind: .transport, code: "unexpected_path", message: "F2-B fixture 不应请求：\(request.path)")
            }
            let period = String(path.dropFirst("reports/v2/monthly/".count))
            guard period.range(of: "^[0-9]{4}-(0[1-9]|1[0-2])$", options: .regularExpression) != nil else {
                throw V15Failure(kind: .decoding, code: "invalid_month_period", message: "根壳 fixture 收到无效月报 period：\(period)")
            }
            data = V15F2BFixtures.rootWorkspaceMonthlyReport(period: period)
        default: throw V15Failure(kind: .transport, code: "unexpected_path", message: "F2-B fixture 不应请求：\(request.path)")
        }
        return try V15FixtureCodec.decoder.decode(Response.self, from: data)
    }

    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data {
        throw V15Failure(kind: .transport, message: "F2-B Today 不读取工件。")
    }

    func allRequests() -> [V15Request] { requests }
}

extension V15F2BFixtures {
    /// Zero-balance QA accounts exercise the sidebar overflow without changing
    /// the normal fixture or inventing extra aggregate money.
    static var overflowAccounts: Data {
        var accounts = try! JSONSerialization.jsonObject(with: V15F1AFixtures.accounts) as! [[String: Any]]
        for index in 4...5 {
            var account = accounts[0]
            account["id"] = "00000000-0000-0000-0000-00000000020\(index)"
            account["name"] = "测试账户\(index)"
            account["sort_order"] = index
            account["current_balance_minor"] = 0
            account["usage_count"] = 0
            accounts.append(account)
        }
        return try! JSONSerialization.data(withJSONObject: accounts)
    }

    /// The formal Mac timeline requests the full future feed as well as facts.
    /// Reuse the same synthetic events so its normal QA route stays coherent.
    static func rootWorkspaceFutureEvents(accountID: String?) -> Data {
        let facts = try! JSONSerialization.jsonObject(with: rootWorkspaceFacts) as! [String: Any]
        let items = (facts["known_future_events"] as! [[String: Any]]).filter {
            accountID == nil || $0["account_id"] as? String == accountID
        }
        let payload: [String: Any] = [
            "meta": facts["meta"]!, "window": facts["window"]!,
            "account_id": accountID as Any? ?? NSNull(), "items": items, "next_cursor": NSNull()
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    static var rootWorkspaceFacts: Data {
        var payload = try! JSONSerialization.jsonObject(with: V15F2AFixtures.facts()) as! [String: Any]
        var cash = payload["cash"] as! [String: Any]
        cash["current_balance_minor"] = 188_650
        payload["cash"] = cash
        var future = payload["future"] as! [String: Any]
        future["after_confirmed_outflow_minor"] = 6_500
        payload["future"] = future
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    /// A complete monthly V15PeriodReport for the exact requested month.  The
    /// summary and report rows are intentionally ordinary synthetic amounts;
    /// Int64 boundary validation has its own root route above.
    static func rootWorkspaceMonthlyReport(period: String) -> Data {
        var payload = try! JSONSerialization.jsonObject(with: Data(V15F4AFixtures.report(period: period, revision: 42).utf8)) as! [String: Any]
        var meta = payload["meta"] as! [String: Any]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone
        let start = formatter.date(from: "\(period)-01")!
        let next = calendar.date(byAdding: .month, value: 1, to: start)!
        meta["date_to"] = formatter.string(from: calendar.date(byAdding: .day, value: -1, to: next)!)
        payload["meta"] = meta
        var summary = payload["summary"] as! [String: Any]
        summary["income_minor"] = 245_000
        summary["gross_consumption_minor"] = 136_400
        summary["merchant_refund_minor"] = 4_500
        summary["net_consumption_minor"] = 131_900
        summary["expected_reimbursement_minor"] = 21_000
        summary["received_reimbursement_minor"] = 8_000
        summary["personal_expected_minor"] = 110_900
        summary["personal_realized_minor"] = 123_900
        summary["net_income_expense_minor"] = 121_100
        summary["cash_inflow_minor"] = 253_000
        summary["cash_outflow_minor"] = 136_400
        summary["cash_net_minor"] = 116_600
        summary["internal_transfer_inflow_minor"] = 10_000
        summary["internal_transfer_outflow_minor"] = 10_000
        summary["credit_debt_at_period_end_minor"] = 4_567
        summary["reimbursement_outstanding_at_period_end_minor"] = 900
        payload["summary"] = summary
        var accounts = payload["accounts"] as! [[String: Any]]
        accounts[0]["opening_balance_minor"] = 72_050
        accounts[0]["closing_balance_minor"] = 188_650
        accounts[0]["period_inflow_minor"] = 253_000
        accounts[0]["period_outflow_minor"] = 136_400
        payload["accounts"] = accounts
        // Only the isolated normal root fixture supplies this deterministic
        // daily series. Production views never synthesize missing report data.
        let gross = [12_000, 0, 50_000, 18_000, 35_000, 21_400]
        payload["daily"] = gross.enumerated().map { index, amount -> [String: Any] in
            let refund = index == 2 ? 4_500 : 0
            let expected = index == 2 ? 21_000 : 0
            let received = index == 5 ? 8_000 : 0
            return ["date": "\(period)-\(String(format: "%02d", index + 1))",
                    "gross_consumption_minor": amount, "merchant_refund_minor": refund,
                    "net_consumption_minor": amount - refund,
                    "expected_reimbursement_minor": expected, "received_reimbursement_minor": received,
                    "personal_expected_minor": amount - refund - expected,
                    "personal_realized_minor": amount - refund - received]
        }
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    static var zeroFutureFacts: Data {
        var payload = try! JSONSerialization.jsonObject(with: V15F2AFixtures.facts()) as! [String: Any]
        payload["future"] = [
            "exact_due_outflow_minor": 0,
            "confirmed_outflow_minor": 0,
            "expected_outflow_minor": 0,
            "scheduled_outflow_minor": 0,
            "confirmed_inflow_minor": 0,
            "expected_inflow_minor": 0,
            "scheduled_inflow_minor": 0,
            "after_confirmed_outflow_minor": 0
        ]
        payload["known_future_events"] = []
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    static var unknownScopePage: Data {
        let scope = V15F2AFixtures.scope("cash_accounts", 42)
        return Data("{\"meta\":{\"timezone\":\"Asia/Shanghai\",\"currency\":\"CNY\",\"as_of\":\"2026-08-15T16:01:02Z\",\"data_revision\":42,\"schema_version\":\"1\"},\"scope\":\(scope),\"items\":[{\"item_type\":\"future_server_item\",\"deep_link\":\"fiscal://transactions/\(V15F2AFixtures.transactionID)?unsafe=1\"}],\"next_cursor\":null}".utf8)
    }
}
