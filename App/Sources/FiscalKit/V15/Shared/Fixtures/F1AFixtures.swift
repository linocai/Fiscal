import Foundation

enum V15F1AFixtures {
    static let businessDate = ISO8601DateFormatter().date(from: "2026-08-15T04:00:00Z")!
    static let accountID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    static let debitID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    static let creditID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
    static let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000104")!
    static let incomeCategoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000107")!
    static let creditCycleID = UUID(uuidString: "00000000-0000-0000-0000-000000000108")!
    static let transactionID = UUID(uuidString: "00000000-0000-0000-0000-000000000105")!
    static let session = Data(#"{"access_key":"fixture-access-key","credential_generation":1}"#.utf8)
    static let auth = Data(#"{"authentication_mode":"passphrase","passphrase_set":true,"credential_generation":1,"last_rotated_at":null,"active_access_key_count":1,"server_time":"2026-08-15T04:00:00Z"}"#.utf8)
    static let system = Data(#"{"service":"Fiscal","version":"1.5.0","environment":"fixture","status":"operational","database":"ready","currency":"CNY","business_timezone":"Asia/Shanghai","timestamp":"2026-08-15T04:00:00Z"}"#.utf8)
    static let accounts = Data(#"[{"id":"00000000-0000-0000-0000-000000000101","name":"日常现金","kind":"cash","institution":null,"last_four":null,"opening_balance_minor":0,"current_balance_minor":100000,"credit_limit_minor":null,"statement_day":null,"due_day":null,"cycle_mode":null,"opening_balance_as_of_date":null,"opening_due_date":null,"sort_order":1,"archived_at":null,"usage_count":1,"version":2,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-15T00:00:00Z"},{"id":"00000000-0000-0000-0000-000000000102","name":"工资借记卡","kind":"debit","institution":null,"last_four":null,"opening_balance_minor":0,"current_balance_minor":200000,"credit_limit_minor":null,"statement_day":null,"due_day":null,"cycle_mode":null,"opening_balance_as_of_date":null,"opening_due_date":null,"sort_order":2,"archived_at":null,"usage_count":1,"version":2,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-15T00:00:00Z"},{"id":"00000000-0000-0000-0000-000000000103","name":"信用账户","kind":"credit","institution":null,"last_four":null,"opening_balance_minor":0,"current_balance_minor":3000,"credit_limit_minor":100000,"statement_day":20,"due_day":5,"cycle_mode":"statement_day_cutoff","opening_balance_as_of_date":null,"opening_due_date":null,"sort_order":3,"archived_at":null,"usage_count":1,"version":2,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-15T00:00:00Z"}]"#.utf8)
    static let categories = Data(##"[{"id":"00000000-0000-0000-0000-000000000104","name":"餐饮","direction":"expense","parent_id":null,"icon":"fork.knife","color_hex":"#008C8A","aliases":[],"examples":[],"is_balance_adjustment":false,"sort_order":1,"archived_at":null,"usage_count":1,"version":1,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-15T00:00:00Z","children":[]}]"##.utf8)
    static let incomeCategories = Data(##"[{"id":"00000000-0000-0000-0000-000000000107","name":"工资","direction":"income","parent_id":null,"icon":"banknote","color_hex":"#008C8A","aliases":[],"examples":[],"is_balance_adjustment":false,"sort_order":1,"archived_at":null,"usage_count":1,"version":1,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-15T00:00:00Z","children":[]}]"##.utf8)
    static let creditCycles = Data(#"{"items":[{"id":"00000000-0000-0000-0000-000000000108","account_id":"00000000-0000-0000-0000-000000000103","period_start":"2026-07-21","period_end":"2026-08-20","statement_date":"2026-08-20","due_date":"2026-09-05","is_opening_cycle":false,"purchase_minor":3000,"opening_minor":0,"amount_due_minor":3000,"repaid_minor":0,"remaining_minor":3000,"status":"unpaid","is_overdue":false,"version":2,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-15T00:00:00Z","installment_principal_minor":0,"installment_fee_minor":0,"installment_periods":[]}],"next_cursor":null}"#.utf8)
    static let transaction = Data(#"{"id":"00000000-0000-0000-0000-000000000105","kind":"expense","amount_minor":1280,"occurred_at":"2026-08-15T04:00:00Z","business_date":"2026-08-15","title":"午餐","note":null,"category_id":"00000000-0000-0000-0000-000000000104","account_id":"00000000-0000-0000-0000-000000000101","destination_account_id":null,"credit_cycle_id":null,"source":"manual","postings":[{"id":"00000000-0000-0000-0000-000000000106","account_id":"00000000-0000-0000-0000-000000000101","role":"account","amount_minor":-1280,"position":0}],"version":1,"voided_at":null,"created_at":"2026-08-15T04:00:00Z","updated_at":"2026-08-15T04:00:00Z","installment_plan_id":null,"installment_relation":null,"reimbursement_relations":[],"available_actions":[]}"#.utf8)
    static let repaymentTransaction = Data(#"{"id":"00000000-0000-0000-0000-000000000109","kind":"repayment","amount_minor":1280,"occurred_at":"2026-08-15T04:00:00Z","business_date":"2026-08-15","title":"信用卡还款","note":null,"category_id":null,"account_id":"00000000-0000-0000-0000-000000000101","destination_account_id":"00000000-0000-0000-0000-000000000103","credit_cycle_id":"00000000-0000-0000-0000-000000000108","source":"manual","postings":[{"id":"00000000-0000-0000-0000-000000000110","account_id":"00000000-0000-0000-0000-000000000101","role":"account","amount_minor":-1280,"position":0},{"id":"00000000-0000-0000-0000-000000000111","account_id":"00000000-0000-0000-0000-000000000103","role":"credit_cycle","amount_minor":1280,"position":1}],"version":1,"voided_at":null,"created_at":"2026-08-15T04:00:00Z","updated_at":"2026-08-15T04:00:00Z","installment_plan_id":null,"installment_relation":null,"reimbursement_relations":[],"available_actions":[]}"#.utf8)
    static let repaymentPreview = Data("""
    {"meta":{"preview_token":"00000000-0000-0000-0000-00000000A001","action":"repayment","data_revision":7,"expires_at":"2026-09-01T14:00:00Z"},"amount_minor":1280,"payment_account_id":"\(accountID)","payment_account_name":"日常现金","payment_balance_before_minor":100000,"payment_balance_after_minor":98720,"credit_account_id":"\(creditID)","credit_account_name":"信用账户","credit_debt_before_minor":3000,"credit_debt_after_minor":1720,"credit_cycle_id":"\(creditCycleID)","cycle_remaining_before_minor":3000,"cycle_remaining_after_minor":1720}
    """.utf8)
    static let repaymentReceipt = Data("""
    {"operation_id":"00000000-0000-0000-0000-00000000A004","preview_token":"00000000-0000-0000-0000-00000000A001","action":"repayment","data_revision":8,"result":\(String(decoding: repaymentTransaction, as: UTF8.self)),"replay":false}
    """.utf8)
    @MainActor static func services() -> V15Services { V15Services(transport: V15F1AFixtureTransport()) }
}

actor V15F1AFixtureTransport: V15Transporting {
    private var requests: [V15Request] = []
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        requests.append(request)
        let value: Data
        switch (request.path, request.method) {
        case ("auth/session", "POST"): value = V15F1AFixtures.session
        case ("auth/status", "GET"): value = V15F1AFixtures.auth
        case ("system/status", "GET"): value = V15F1AFixtures.system
        case ("accounts", "GET"): value = V15F1AFixtures.accounts
        case ("categories", "GET"):
            value = request.query.first(where: { $0.name == "direction" })?.value == "income" ? V15F1AFixtures.incomeCategories : V15F1AFixtures.categories
        case ("credit-accounts/\(V15F1AFixtures.creditID)/cycles", "GET"): value = V15F1AFixtures.creditCycles
        case ("transactions/repayment-preview", "POST"): value = V15F1AFixtures.repaymentPreview
        case ("transactions/repayment-commit", "POST"): value = V15F1AFixtures.repaymentReceipt
        case ("transactions", "POST"):
            if case .object(let object)? = body, case .string("repayment")? = object["kind"] { value = V15F1AFixtures.repaymentTransaction }
            else { value = V15F1AFixtures.transaction }
        default: throw V15Failure(kind: .transport, code: "fixture_missing", message: "缺少 F1-A 夹具。")
        }
        do { return try V15FixtureCodec.decoder.decode(Response.self, from: value) }
        catch { throw V15Failure(kind: .decoding, code: "fixture_decode_failed", message: "F1-A 夹具不符合接口契约。") }
    }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { throw V15Failure(kind: .transport, code: "fixture_missing", message: "F1-A 不提供文件导出。") }
    func lastRequest() -> V15Request? { requests.last }
}
