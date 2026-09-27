@testable import FiscalKit
import Foundation

/// Deterministic data for the production workspaces in RootSmoke and Gallery.
public enum V15F2BFixtures {
    enum Route: String {
        case rootWorkspace = "today-root-workspace"
        /// This is deliberately a separate root host route: it proves that
        /// the production composition contains F2-A's Int64 boundary values
        /// locally instead of letting them widen the whole screen.
        case rootWorkspaceBoundary = "today-root-workspace-boundary"
    }

    @MainActor public static func services(route: String, accountOverflow: Bool = false, reviewScenario: String = "") -> V15Services {
        if reviewScenario.hasPrefix("v230") { return V230Fixtures.services(scenario: reviewScenario) }
        let pending = V15PendingWriteStore()
        if reviewScenario == "offline-pending" {
            pending.enqueueCreate(.init(kind: .expense, amountMinor: 100, occurredAt: offlineSnapshotAt,
                                        title: "隔离测试待同步", accountID: V15F1AFixtures.accountID))
        }
        return V15Services(transport: V15F2BFixtureTransport(route: Route(rawValue: route) ?? .rootWorkspace, accountOverflow: accountOverflow, reviewScenario: reviewScenario),
                           offlineSnapshotProvider: { reviewScenario == "offline-pending" ? offlineSnapshotAt : nil }, pendingWrites: pending)
    }

    static let offlineSnapshotAt = Date(timeIntervalSince1970: 1_786_464_000)

}

actor V15F2BFixtureTransport: V15Transporting {
    private let route: V15F2BFixtures.Route
    private let accountOverflow: Bool
    private var factsReads = 0
    private var authReads = 0
    private var accountReads = 0
    private var transactionReads = 0
    private var cycleReads = 0
    private var categoryReads = 0
    private var ocrSourceEnabled = true
    private var merchantMapping: V15MerchantMapping?
    private let reviewScenario: String
    private var requests: [V15Request] = []

    init(route: V15F2BFixtures.Route, accountOverflow: Bool = false, reviewScenario: String = "") {
        self.reviewScenario = route == .rootWorkspace ? reviewScenario : ""
        self.route = route
        self.accountOverflow = accountOverflow && route == .rootWorkspace
    }

    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        requests.append(request)
        if request.path == "transactions/\(V15F1BFixtures.transactionID)/merchant-mapping", reviewScenario == "merchant-confirmation" {
            let merchant = V15Merchant(id: UUID(uuidString: "00000000-0000-0000-0000-00000000B401")!, name: "工作餐商户", aliases: ["午餐"])
            if request.method == "GET" {
                return try V15BodyEncoder.decode(Response.self, from: V15BodyEncoder.encode(V15MerchantMappingState(mapping: merchantMapping, suggestedMerchant: merchantMapping == nil ? merchant : nil)))
            }
            guard request.method == "PUT", let body,
                  let input = try? V15BodyEncoder.decode(V15MerchantMappingRequest.self, from: body),
                  input.merchantName == merchant.name, input.expectedMappingVersion == nil,
                  request.headers["Idempotency-Key"] != nil else {
                throw V15Failure(kind: .decoding, code: "fixture_input_invalid", message: "商户确认请求不符合契约。")
            }
            merchantMapping = .init(merchant: merchant, mappingVersion: 1)
            return try V15BodyEncoder.decode(Response.self, from: V15BodyEncoder.encode(V15MerchantMappingReceipt(action: "confirmed", mapping: merchantMapping)))
        }
        if request.path == "ai/settings", request.method == "PUT", reviewScenario == "ai-source-update" {
            guard case let .object(fields)? = body,
                  case .bool(let ocr)? = fields["ocr_source_enabled"],
                  case .integer(4)? = fields["expected_version"] else {
                throw V15Failure(kind: .decoding, code: "fixture_input_invalid", message: "来源设置请求与夹具契约不符。")
            }
            ocrSourceEnabled = ocr
            return try V15FixtureCodec.decoder.decode(Response.self, from: Data(aiSettings(version: 5).utf8))
        }
        guard request.method == "GET", body == nil else {
            throw V15Failure(kind: .offlineReadOnly, code: "write_forbidden", message: "工作区夹具只允许指定写入请求。")
        }
        let data: Data
        switch request.path {
        case "ai/proposals":
            let pending = V15F3FFixtures.proposal(id: V15F3FFixtures.pendingID, status: "pending", accountID: V15F1AFixtures.accountID)
            data = Data("{\"items\":[\(pending)],\"next_cursor\":null,\"pending_count\":1}".utf8)
        case "ai/proposals/\(V15F3FFixtures.createdID)":
            let proposal = V15F3FFixtures.proposal(id: V15F3FFixtures.createdID, status: "pending", title: "截图待确认专用提案", accountID: V15F1AFixtures.accountID)
                .replacingOccurrences(of: "\"source\":\"text\"", with: "\"source\":\"ocr\"")
            data = Data(proposal.utf8)
        case "ai/proposals/\(V15F3FFixtures.pendingID)":
            data = Data(V15F3FFixtures.proposal(id: V15F3FFixtures.pendingID, status: "pending", accountID: V15F1AFixtures.accountID).utf8)
        case "ai/settings": data = Data(aiSettings(version: ocrSourceEnabled ? 4 : 5).utf8)
        case "ai/provider-settings": data = Data(#"{"provider":"openai_compatible","base_url":"https://example.invalid","model":"fixture","api_key_configured":true,"version":1,"updated_at":"2026-08-16T00:00:00Z"}"#.utf8)
        case "auth/status":
            authReads += 1
            if reviewScenario == "proposal-bootstrap-delay", authReads == 1 { try await Task.sleep(for: .seconds(2)) }
            if reviewScenario == "bootstrap-retry", authReads == 1 { throw V15Failure(kind: .transport, message: "测试首次连接失败。") }
            data = V15F1AFixtures.auth
        case "system/status": data = V15F1AFixtures.system
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
        case let path where (route == .rootWorkspace || route == .rootWorkspaceBoundary) && path.hasPrefix("accounts/"):
            let id = String(path.dropFirst("accounts/".count))
            let accounts = try JSONSerialization.jsonObject(with: V15F1AFixtures.accounts) as! [[String: Any]]
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
        case let path where path.hasPrefix("credit-accounts/") && path.hasSuffix("/cycles"):
            data = Data("{\"items\":[],\"next_cursor\":null}".utf8)
        case "transactions":
            transactionReads += 1
            if reviewScenario == "recent-error", transactionReads == 1 {
                throw V15Failure(kind: .transport, message: "测试最近交易暂时失败。")
            }
            let accountID = request.query.first(where: { $0.name == "account_id" })?.value
            data = reviewScenario == "recent-empty" || (accountOverflow && accountID?.hasSuffix("205") == true)
                ? Data(#"{"items":[],"next_cursor":null}"#.utf8) : V15F1BFixtures.page
        case "reports/future-events":
            let account = request.query.first(where: { $0.name == "account_id" })?.value
            data = V15F2BFixtures.rootWorkspaceFutureEvents(accountID: account)
        case "reports/facts":
            factsReads += 1
            if route == .rootWorkspace {
                if reviewScenario == "refresh", factsReads > 1 {
                    var value = try JSONSerialization.jsonObject(with: V15F2BFixtures.rootWorkspaceFacts) as! [String: Any]
                    var cash = value["cash"] as! [String: Any]
                    cash["current_balance_minor"] = 288_650
                    value["cash"] = cash
                    data = try JSONSerialization.data(withJSONObject: value)
                } else { data = V15F2BFixtures.rootWorkspaceFacts }
            } else { data = V15F2AFixtures.facts() }
        case "reports/facts/drill-down":
            let scope = request.query.first(where: { $0.name == "scope" })?.value ?? ""
            let hasCursor = request.query.contains(where: { $0.name == "cursor" })
            data = V15F2AFixtures.page(scope: scope, nextCursor: scope == "cash_accounts" && !hasCursor ? "f2b-opaque-cash" : nil)
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

    private func aiSettings(version: Int) -> String {
        "{\"ocr_source_enabled\":\(ocrSourceEnabled),\"shortcut_text_source_enabled\":true,\"provider_configured\":true,\"version\":\(version),\"created_at\":\"2026-08-01T00:00:00Z\",\"updated_at\":\"2026-08-16T00:00:00Z\"}"
    }

    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data {
        throw V15Failure(kind: .transport, message: "工作区夹具不读取工件。")
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
        // Include every day so overview QA catches crowded monthly date axes.
        let dayCount = calendar.range(of: .day, in: .month, for: start)!.count
        let gross = [12_000, 0, 50_000, 18_000, 35_000, 21_400]
            + Array(repeating: 0, count: dayCount - 6)
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

}
