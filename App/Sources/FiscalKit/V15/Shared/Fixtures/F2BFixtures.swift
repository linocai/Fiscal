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

    @MainActor public static func services(route: String) -> V15Services {
        V15Services(transport: V15F2BFixtureTransport(route: Route(rawValue: route) ?? .normal))
    }

    static let offlineSnapshotAt = Date(timeIntervalSince1970: 1_786_464_000)

}

actor V15F2BFixtureTransport: V15Transporting {
    private let route: V15F2BFixtures.Route
    private var factsReads = 0
    private var requests: [V15Request] = []

    init(route: V15F2BFixtures.Route) { self.route = route }

    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        requests.append(request)
        guard request.method == "GET", body == nil else {
            throw V15Failure(kind: .offlineReadOnly, code: "write_forbidden", message: "F2-B 画廊只允许只读请求。")
        }
        let data: Data
        switch request.path {
        case "accounts": data = V15F1AFixtures.accounts
        case "categories": data = V15F1AFixtures.categories
        case "transactions": data = V15F1BFixtures.page
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
                data = V15F2BFixtures.rootWorkspaceFacts
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
        var payload = try! JSONSerialization.jsonObject(with: Data(V15F4AFixtures.report(period: period).utf8)) as! [String: Any]
        var summary = payload["summary"] as! [String: Any]
        summary["income_minor"] = 245_000
        summary["gross_consumption_minor"] = 136_400
        summary["merchant_refund_minor"] = 4_500
        summary["net_consumption_minor"] = 131_900
        summary["expected_reimbursement_minor"] = 21_000
        summary["received_reimbursement_minor"] = 8_000
        summary["personal_expected_minor"] = 110_900
        summary["personal_realized_minor"] = 123_456
        summary["net_income_expense_minor"] = 121_544
        summary["cash_inflow_minor"] = 253_000
        summary["cash_outflow_minor"] = 136_400
        summary["cash_net_minor"] = 116_600
        summary["internal_transfer_inflow_minor"] = 10_000
        summary["internal_transfer_outflow_minor"] = 10_000
        summary["credit_debt_at_period_end_minor"] = 4_567
        summary["reimbursement_outstanding_at_period_end_minor"] = 900
        payload["summary"] = summary
        var accounts = payload["accounts"] as! [[String: Any]]
        accounts[0]["opening_balance_minor"] = 142_000
        accounts[0]["closing_balance_minor"] = 188_650
        accounts[0]["period_inflow_minor"] = 245_000
        accounts[0]["period_outflow_minor"] = 136_400
        payload["accounts"] = accounts
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
