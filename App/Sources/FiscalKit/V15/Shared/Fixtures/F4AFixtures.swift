import Foundation

/// F4-A only uses synthetic aggregates. It deliberately contains neither
/// transaction titles/notes nor account identifiers beyond stable test UUIDs.
public enum V15F4AFixtures {
    public static let accountID = UUID(uuidString: "00000000-0000-0000-0000-00000000F401")!
    public static let categoryID = UUID(uuidString: "00000000-0000-0000-0000-00000000F402")!
    public static let merchantID = UUID(uuidString: "00000000-0000-0000-0000-00000000F403")!
    public static let transactionID = UUID(uuidString: "00000000-0000-0000-0000-00000000F404")!

    @MainActor public static func services(route: String = "reports") -> V15Services { .init(transport: F4ATransport(mode: .route(route))) }
    static func artifactSaver(route: String) -> F4AArtifactSaveService { .init(mode: .route(route)) }

    static func report(period: String = "2026-08", kind: String = "month", revision: Int64 = 77, empty: Bool = false, summaryOnly: Bool = false, completenessOnly: Bool = false, unknown: Bool = false, unknownAccount: Bool = false) -> String {
        let accountKind = unknownAccount ? "future_report_account_kind" : "cash"
        let rows = (empty || summaryOnly || completenessOnly) ? "\"accounts\":[],\"categories\":[],\"merchants\":[],\"sources\":[]" : "\"accounts\":[{\"account_id\":\"\(accountID)\",\"account_name\":\"合成账户\",\"account_kind\":\"\(accountKind)\",\"opening_balance_minor\":922337203685477,\"closing_balance_minor\":922337203685477,\"period_inflow_minor\":100000,\"period_outflow_minor\":30000,\"internal_transfer_inflow_minor\":5000,\"internal_transfer_outflow_minor\":5000}],\"categories\":[{\"category_id\":\"\(categoryID)\",\"category_name\":\"合成分类（可定位）\",\"gross_consumption_minor\":30000,\"merchant_refund_minor\":2000,\"net_consumption_minor\":28000,\"transaction_count\":121},{\"category_id\":null,\"category_name\":\"未分类汇总\",\"gross_consumption_minor\":1000,\"merchant_refund_minor\":0,\"net_consumption_minor\":1000,\"transaction_count\":1}],\"merchants\":[{\"merchant_id\":\"\(merchantID)\",\"merchant_name\":\"合成商户（可定位）\",\"net_consumption_minor\":28000,\"transaction_count\":121},{\"merchant_id\":null,\"merchant_name\":\"未匹配商户汇总\",\"net_consumption_minor\":1000,\"transaction_count\":1}],\"sources\":[{\"source\":\"manual\",\"transaction_count\":121},{\"source\":\"future_server_source\",\"transaction_count\":1}]"
        let actualKind = unknown ? "future_period_kind" : kind
        let completeness = empty ? "0,\"failed_import_count\":0,\"uncategorized_transaction_count\":0,\"open_reconciliation_difference_count\":0" : completenessOnly ? "1,\"failed_import_count\":2,\"uncategorized_transaction_count\":3,\"open_reconciliation_difference_count\":4" : "1,\"failed_import_count\":0,\"uncategorized_transaction_count\":1,\"open_reconciliation_difference_count\":0"
        let summary = empty
            ? "\"income_minor\":0,\"gross_consumption_minor\":0,\"merchant_refund_minor\":0,\"net_consumption_minor\":0,\"expected_reimbursement_minor\":0,\"received_reimbursement_minor\":0,\"personal_expected_minor\":0,\"personal_realized_minor\":0,\"net_income_expense_minor\":0,\"cash_inflow_minor\":0,\"cash_outflow_minor\":0,\"cash_net_minor\":0,\"internal_transfer_inflow_minor\":0,\"internal_transfer_outflow_minor\":0,\"credit_debt_at_period_end_minor\":0,\"reimbursement_outstanding_at_period_end_minor\":0"
            : "\"income_minor\":100000,\"gross_consumption_minor\":31000,\"merchant_refund_minor\":2000,\"net_consumption_minor\":29000,\"expected_reimbursement_minor\":3000,\"received_reimbursement_minor\":1000,\"personal_expected_minor\":26000,\"personal_realized_minor\":28000,\"net_income_expense_minor\":71000,\"cash_inflow_minor\":101000,\"cash_outflow_minor\":31000,\"cash_net_minor\":70000,\"internal_transfer_inflow_minor\":5000,\"internal_transfer_outflow_minor\":5000,\"credit_debt_at_period_end_minor\":8000,\"reimbursement_outstanding_at_period_end_minor\":2000"
        return "{\"meta\":{\"period_kind\":\"\(actualKind)\",\"period\":\"\(period)\",\"date_from\":\"\(period)-01\",\"date_to\":\"\(period)-31\",\"timezone\":\"Asia/Shanghai\",\"currency\":\"CNY\",\"as_of\":\"2026-08-20T00:00:00Z\",\"data_revision\":\(revision),\"report_schema_version\":\"2\",\"generated_at\":\"2026-08-20T00:00:01Z\"},\"summary\":{\(summary)},\(rows),\"completeness\":{\"unresolved_import_count\":\(completeness)},\"daily\":[],\"known_future_events\":[],\"debt_cycles\":[],\"installments\":[],\"drill_down_path\":\"/api/v1/reports/v2/period-drill-down\"}"
    }

    static func drill(period: String = "2026-08", kind: String = "month", filter: String = "category_id", revision: Int64 = 77, next: String? = "next", emptyItems: Bool = false) -> String {
        let category = filter == "category_id" ? "\"\(categoryID)\"" : "null"
        let account = filter == "account_id" ? "\"\(accountID)\"" : "null"
        let merchant = filter == "merchant_id" ? "\"\(merchantID)\"" : "null"
        let source = filter == "source" ? "\"manual\"" : "null"
        let items = emptyItems ? "[]" : "[{\"transaction_id\":\"\(transactionID)\",\"occurred_at\":\"2026-08-19T00:00:00Z\",\"business_date\":\"2026-08-19\",\"kind\":\"expense\",\"source\":\"manual\",\"category_id\":\"\(categoryID)\",\"category_name\":\"合成分类\",\"merchant_id\":\"\(merchantID)\",\"merchant_name\":\"合成商户\",\"external_cash_amount_minor\":28000,\"gross_consumption_minor\":30000,\"merchant_refund_minor\":2000,\"net_consumption_minor\":28000}]"
        let response = "{\"meta\":{\"period_kind\":\"\(kind)\",\"period\":\"\(period)\",\"date_from\":\"\(period)-01\",\"date_to\":\"\(period)-31\",\"timezone\":\"Asia/Shanghai\",\"currency\":\"CNY\",\"as_of\":\"2026-08-20T00:00:00Z\",\"data_revision\":\(revision),\"report_schema_version\":\"2\",\"generated_at\":\"2026-08-20T00:00:01Z\"},\"dimension\":\"ledger\",\"category_id\":\(category),\"account_id\":\(account),\"merchant_id\":\(merchant),\"source\":\(source),\"items\":\(items),\"next_cursor\":\(next.map { "\"\($0)\"" } ?? "null")}"
        return response
    }
}

actor F4AArtifactSaveService: V15ReportArtifactSaving {
    enum Mode: Equatable { case success, cancelled, failThenSuccess
        static func route(_ route: String) -> Mode { switch route { case "reports-export-save-cancel": .cancelled; case "reports-export-save-retry": .failThenSuccess; default: .success } }
    }
    private let mode: Mode
    private var attempts = 0
    init(mode: Mode) { self.mode = mode }
    func save(temporaryURL: URL, suggestedFilename: String) async throws -> V15ReportArtifactSaveResult {
        attempts += 1
        guard temporaryURL.lastPathComponent == suggestedFilename else { throw V15Failure(kind: .decoding, message: "fixture filename mismatch") }
        if mode == .cancelled { return .cancelled }
        if mode == .failThenSuccess, attempts == 1 { throw V15Failure(kind: .transport, message: "fixture save failure") }
        return .saved
    }
}

actor F4ATransport: V15Transporting {
    enum Mode: Equatable { case normal, empty, summaryOnly, completenessOnly, error, offline, conflict, pageFailure, drillFirstFailure, drillEmpty, drillLoading, loading, unknown, unknownAccount, exportStale, exportMissingHeader, exportBadFilename, exportConflict, exportConflictThenFresh, exportUnknown
        static func route(_ route: String) -> Mode { switch route { case "reports-empty": .empty; case "reports-summary-only": .summaryOnly; case "reports-completeness-only": .completenessOnly; case "reports-error": .error; case "reports-offline": .offline; case "reports-conflict": .conflict; case "reports-page-error": .pageFailure; case "reports-drill-first-error": .drillFirstFailure; case "reports-drill-empty": .drillEmpty; case "reports-drill-loading": .drillLoading; case "reports-unknown": .unknown; case "reports-unknown-account": .unknownAccount; case "reports-export-stale": .exportStale; case "reports-export-missing-header": .exportMissingHeader; case "reports-export-bad-filename": .exportBadFilename; case "reports-export-conflict": .exportConflict; case "reports-export-conflict-then-fresh": .exportConflictThenFresh; case "reports-export-unknown": .exportUnknown; default: .normal } }
    }
    let mode: Mode
    private var requests: [V15Request] = []
    private var pageRequests = 0
    init(mode: Mode) { self.mode = mode }
    func allRequests() -> [V15Request] { requests }
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        requests.append(request)
        if mode == .offline { throw V15Failure(kind: .offlineReadOnly, code: "offline_read_only", message: "离线快照仅可查看。") }
        if mode == .loading { try await Task.sleep(for: .seconds(3)) }
        if mode == .error { throw V15Failure(kind: .transport, message: "报告读取失败。") }
        if request.path == "reports/v2/period-drill-down" {
            pageRequests += 1
            if mode == .drillLoading { try await Task.sleep(for: .seconds(1)) }
            if mode == .conflict { throw V15Failure(kind: .conflict, code: "period_report_changed", message: "报告版本已变化。") }
            if mode == .pageFailure, pageRequests == 2 { throw V15Failure(kind: .transport, message: "下一页报告明细读取失败。") }
            if mode == .drillFirstFailure, pageRequests == 1 { throw V15Failure(kind: .transport, message: "报告明细读取失败。") }
            let cursor = request.query.first(where: { $0.name == "cursor" })?.value
            let filter = request.query.first(where: { ["category_id", "account_id", "merchant_id", "source"].contains($0.name) })?.name ?? "category_id"
            let period = request.query.first(where: { $0.name == "period" })?.value ?? "2026-08"
            let kind = request.query.first(where: { $0.name == "period_kind" })?.value ?? "month"
            return try V15FixtureCodec.decoder.decode(Response.self, from: Data(V15F4AFixtures.drill(period: period, kind: kind, filter: filter, next: mode == .drillEmpty ? nil : (cursor == nil ? "next" : nil), emptyItems: mode == .drillEmpty).utf8))
        }
        let isYear = request.path.contains("yearly")
        let period = request.path.split(separator: "/").last.map(String.init) ?? (isYear ? "2026" : "2026-08")
        let revision: Int64 = mode == .exportConflictThenFresh && request.readCachePolicy == .reloadIgnoringCache ? 78 : 77
        let report = V15F4AFixtures.report(period: period, kind: isYear ? "year" : "month", revision: revision, empty: mode == .empty, summaryOnly: mode == .summaryOnly, completenessOnly: mode == .completenessOnly, unknown: mode == .unknown, unknownAccount: mode == .unknownAccount)
        return try V15FixtureCodec.decoder.decode(Response.self, from: Data(report.utf8))
    }
    func sendNoContent(_ request: V15Request, body: JSONValue?) async throws { requests.append(request) }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { throw V15Failure(kind: .transport, message: "F4-A 不下载导出文件。") }
    func fetchArtifactResponse(_ request: V15Request, accept: String) async throws -> V15ArtifactTransfer {
        requests.append(request)
        let expected = request.query.first(where: { $0.name == "expected_data_revision" })?.value ?? "77"
        if mode == .offline { throw V15Failure(kind: .offlineReadOnly, code: "offline_read_only", message: "离线快照仅可查看。") }
        if mode == .conflict || mode == .exportConflict || (mode == .exportConflictThenFresh && expected == "77") { throw V15Failure(kind: .conflict, code: "period_report_changed", message: "报告版本已变化。") }
        if mode == .exportUnknown { throw V15Failure(kind: .responseUnknown, code: "response_unknown", message: "文件结果未知。") }
        let revision = mode == .exportStale ? "78" : expected
        let fileExtension = accept == "application/pdf" ? "pdf" : "csv"
        var headers = ["Content-Type": accept, "Content-Disposition": "attachment; filename=\"fiscal-report-2026-08-r\(revision).\(fileExtension)\"", "X-Fiscal-Data-Revision": revision]
        if mode == .exportMissingHeader { headers.removeValue(forKey: "X-Fiscal-Data-Revision") }
        if mode == .exportBadFilename { headers["Content-Disposition"] = "attachment; filename=\"../../unsafe.csv\"" }
        return .init(data: Data("synthetic export".utf8), headers: headers)
    }
}
