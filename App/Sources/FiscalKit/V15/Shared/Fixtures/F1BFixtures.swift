import Foundation

enum V15F1BFixtures {
    static let transactionID = UUID(uuidString: "00000000-0000-0000-0000-00000000B101")!
    static let otherTransactionID = UUID(uuidString: "00000000-0000-0000-0000-00000000B102")!
    static let accountID = V15F1AFixtures.accountID
    static let categoryID = V15F1AFixtures.categoryID

    static let detail = Data(#"{"id":"00000000-0000-0000-0000-00000000B101","kind":"expense","amount_minor":1280,"occurred_at":"2026-08-15T04:00:00Z","business_date":"2026-08-15","title":"午餐与一段很长的中文说明用于验证账目脊柱不会压缩金额","note":"服务端事实","category_id":"00000000-0000-0000-0000-000000000104","account_id":"00000000-0000-0000-0000-000000000101","destination_account_id":null,"credit_cycle_id":null,"source":"manual","postings":[{"id":"00000000-0000-0000-0000-00000000B201","account_id":"00000000-0000-0000-0000-000000000101","role":"account","amount_minor":-1280,"position":0}],"version":2,"voided_at":null,"created_at":"2026-08-15T04:00:00Z","updated_at":"2026-08-15T04:00:00Z","installment_plan_id":null,"installment_relation":null,"reimbursement_relations":[],"available_actions":[{"action":"void","enabled":true,"reason_code":null,"reason_message":null}]}"#.utf8)
    static let other = Data(#"{"id":"00000000-0000-0000-0000-00000000B102","kind":"income","amount_minor":999999999999,"occurred_at":"2026-08-14T04:00:00Z","business_date":"2026-08-14","title":"工资","note":null,"category_id":null,"account_id":"00000000-0000-0000-0000-000000000102","destination_account_id":null,"credit_cycle_id":null,"source":"manual","postings":[{"id":"00000000-0000-0000-0000-00000000B202","account_id":"00000000-0000-0000-0000-000000000102","role":"account","amount_minor":999999999999,"position":0}],"version":1,"voided_at":null,"created_at":"2026-08-14T04:00:00Z","updated_at":"2026-08-14T04:00:00Z","installment_plan_id":null,"installment_relation":null,"reimbursement_relations":[],"available_actions":[{"action":"void","enabled":false,"reason_code":"installment_plan_in_use","reason_message":"请使用分期计划操作。"}]}"#.utf8)
    static let page = Data(#"{"items":[#DETAIL#,#OTHER#],"next_cursor":"opaque-cursor-B"}"#.replacingOccurrences(of: "#DETAIL#", with: String(decoding: detail, as: UTF8.self)).replacingOccurrences(of: "#OTHER#", with: String(decoding: other, as: UTF8.self)).utf8)
    static let revisions = Data(#"{"items":[{"id":"00000000-0000-0000-0000-00000000B301","version":2,"event":"updated","snapshot":{"id":"00000000-0000-0000-0000-00000000B101","title":"午餐","amount_minor":1280},"created_at":"2026-08-15T04:00:00Z"},{"id":"00000000-0000-0000-0000-00000000B302","version":1,"event":"created","snapshot":{"id":"00000000-0000-0000-0000-00000000B101","title":"午餐","amount_minor":1200},"created_at":"2026-08-14T04:00:00Z"}],"next_cursor":null}"#.utf8)
    static let provenance = Data(#"{"transaction_id":"00000000-0000-0000-0000-00000000B101","source":"manual","links":[{"source_type":"manual","target_type":"transaction_source","target_id":null,"deep_link":null,"recorded_at":"2026-08-15T04:00:00Z"},{"source_type":"merchant_mapping","target_type":"merchant","target_id":"00000000-0000-0000-0000-00000000B401","deep_link":"fiscal://merchants/00000000-0000-0000-0000-00000000B401","recorded_at":"2026-08-15T04:00:01Z"}]}"#.utf8)
    static let voided = Data(#"{"id":"00000000-0000-0000-0000-00000000B101","kind":"expense","amount_minor":1280,"occurred_at":"2026-08-15T04:00:00Z","business_date":"2026-08-15","title":"午餐与一段很长的中文说明用于验证账目脊柱不会压缩金额","note":"服务端事实","category_id":"00000000-0000-0000-0000-000000000104","account_id":"00000000-0000-0000-0000-000000000101","destination_account_id":null,"credit_cycle_id":null,"source":"manual","postings":[{"id":"00000000-0000-0000-0000-00000000B201","account_id":"00000000-0000-0000-0000-000000000101","role":"account","amount_minor":-1280,"position":0}],"version":3,"voided_at":"2026-08-15T05:00:00Z","created_at":"2026-08-15T04:00:00Z","updated_at":"2026-08-15T05:00:00Z","installment_plan_id":null,"installment_relation":null,"reimbursement_relations":[],"available_actions":[{"action":"void","enabled":false,"reason_code":"transaction_already_voided","reason_message":"该账目已经作废。"}]}"#.utf8)
    @MainActor static func services(pageFailure: Bool = false) -> V15Services { V15Services(transport: V15F1BFixtureTransport(failNextPage: pageFailure)) }
}

actor V15F1BFixtureTransport: V15Transporting {
    private var requests: [V15Request] = []
    private var current = V15F1BFixtures.detail
    private let failNextPage: Bool
    init(failNextPage: Bool = false) { self.failNextPage = failNextPage }
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        requests.append(request)
        let data: Data
        switch (request.path, request.method) {
        case ("accounts", "GET"): data = V15F1AFixtures.accounts
        case ("categories", "GET"): data = V15F1AFixtures.categories
        case ("credit-accounts/\(V15F1AFixtures.creditID)/cycles", "GET"): data = V15F1AFixtures.creditCycles
        case ("transactions", "GET"):
            if failNextPage, request.query.contains(where: { $0.name == "cursor" }) { throw V15Failure(kind: .transport, code: "fixture_page_failed", message: "下一页读取失败（夹具）。") }
            data = V15F1BFixtures.page
        case ("transactions/\(V15F1BFixtures.transactionID)", "GET"): data = current
        case ("transactions/\(V15F1BFixtures.transactionID)/revisions", "GET"): data = V15F1BFixtures.revisions
        case ("transactions/\(V15F1BFixtures.transactionID)/provenance", "GET"): data = V15F1BFixtures.provenance
        case ("transactions/\(V15F1BFixtures.transactionID)/void", "POST"): current = V15F1BFixtures.voided; data = current
        case ("transactions/\(V15F1BFixtures.transactionID)/restore", "POST"): current = V15F1BFixtures.detail; data = current
        case ("transactions/\(V15F1BFixtures.transactionID)", "PUT"): data = current
        default: throw V15Failure(kind: .transport, code: "fixture_missing", message: "缺少 F1-B 夹具。")
        }
        do { return try V15FixtureCodec.decoder.decode(Response.self, from: data) }
        catch { throw V15Failure(kind: .decoding, code: "fixture_decode_failed", message: "F1-B 夹具不符合接口契约。") }
    }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { throw V15Failure(kind: .transport, code: "fixture_missing", message: "F1-B 不提供导出。") }
    func lastRequest() -> V15Request? { requests.last }
}
