import Foundation

enum V15F1CFixtures {
    static let accountID = UUID(uuidString: "00000000-0000-0000-0000-00000000C101")!
    static let accountTwoID = UUID(uuidString: "00000000-0000-0000-0000-00000000C102")!
    static let categoryID = UUID(uuidString: "00000000-0000-0000-0000-00000000C201")!
    static let categoryTargetID = UUID(uuidString: "00000000-0000-0000-0000-00000000C202")!
    static let merchantID = UUID(uuidString: "00000000-0000-0000-0000-00000000C301")!
    static let transactionID = UUID(uuidString: "00000000-0000-0000-0000-00000000C401")!
    static let account = ##"{"id":"00000000-0000-0000-0000-00000000C101","name":"日常现金","kind":"cash","institution":null,"last_four":null,"opening_balance_minor":0,"current_balance_minor":100000,"credit_limit_minor":null,"statement_day":null,"due_day":null,"cycle_mode":null,"opening_balance_as_of_date":null,"opening_due_date":null,"sort_order":1,"archived_at":null,"usage_count":3,"version":2,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-15T00:00:00Z"}"##
    static let accountTwo = ##"{"id":"00000000-0000-0000-0000-00000000C102","name":"旅行现金","kind":"cash","institution":null,"last_four":null,"opening_balance_minor":0,"current_balance_minor":2000,"credit_limit_minor":null,"statement_day":null,"due_day":null,"cycle_mode":null,"opening_balance_as_of_date":null,"opening_due_date":null,"sort_order":2,"archived_at":null,"usage_count":0,"version":1,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-15T00:00:00Z"}"##
    static let archivedAccount = account.replacingOccurrences(of: "\"archived_at\":null", with: "\"archived_at\":\"2026-08-15T00:00:00Z\"")
    static let category = ##"{"id":"00000000-0000-0000-0000-00000000C201","name":"餐饮","direction":"expense","parent_id":null,"icon":"fork.knife","color_hex":"#008C8A","aliases":[],"examples":[],"is_balance_adjustment":false,"sort_order":1,"archived_at":null,"usage_count":4,"version":2,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-15T00:00:00Z","children":[]}"##
    static let targetCategory = ##"{"id":"00000000-0000-0000-0000-00000000C202","name":"日用","direction":"expense","parent_id":null,"icon":"bag","color_hex":"#008C8A","aliases":[],"examples":[],"is_balance_adjustment":false,"sort_order":2,"archived_at":null,"usage_count":1,"version":1,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-15T00:00:00Z","children":[]}"##
    static let archivedCategory = category.replacingOccurrences(of: "\"archived_at\":null", with: "\"archived_at\":\"2026-08-15T00:00:00Z\"")
    static let merchant = ##"{"id":"00000000-0000-0000-0000-00000000C301","name":"一段很长的咖啡店商户名称，用来确认辅助文字可以自然换行","aliases":["Coffee House"],"version":2,"archived_at":null,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-15T00:00:00Z"}"##
    static let revision = String(repeating: "a", count: 64)
    static let accountState = Data(##"{"items":[__A__,__B__],"list_revision":"__R__"}"##.replacingOccurrences(of: "__A__", with: account).replacingOccurrences(of: "__B__", with: accountTwo).replacingOccurrences(of: "__R__", with: revision).utf8)
    static let categories = Data("[\(category),\(targetCategory)]".utf8)
    static let merchantPage = Data(##"{"items":[__M__],"next_cursor":null}"##.replacingOccurrences(of: "__M__", with: merchant).utf8)
    static let merchantFirstPage = Data(##"{"items":[__M__],"next_cursor":"next"}"##.replacingOccurrences(of: "__M__", with: merchant).utf8)
    static let preview = Data(##"{"preview_token":"00000000-0000-0000-0000-00000000C501","source":{"category_id":"00000000-0000-0000-0000-00000000C201","transaction_count":4,"amount_minor":12800},"target_id":"00000000-0000-0000-0000-00000000C202","child_mapping_requirements":[],"atomic":true}"##.utf8)
    static let multiChildPreview = Data(##"{"preview_token":"00000000-0000-0000-0000-00000000C503","source":{"category_id":"00000000-0000-0000-0000-00000000C201","transaction_count":4,"amount_minor":12800},"target_id":"00000000-0000-0000-0000-00000000C202","child_mapping_requirements":[{"source_child_id":"00000000-0000-0000-0000-00000000C211","source_child_name":"来源子类一","target_child_ids":["00000000-0000-0000-0000-00000000C221","00000000-0000-0000-0000-00000000C222"]},{"source_child_id":"00000000-0000-0000-0000-00000000C212","source_child_name":"来源子类二","target_child_ids":["00000000-0000-0000-0000-00000000C223"]}],"atomic":true}"##.utf8)
    static let emptyChildTargetPreview = Data(##"{"preview_token":"00000000-0000-0000-0000-00000000C504","source":{"category_id":"00000000-0000-0000-0000-00000000C201","transaction_count":4,"amount_minor":12800},"target_id":"00000000-0000-0000-0000-00000000C202","child_mapping_requirements":[{"source_child_id":"00000000-0000-0000-0000-00000000C213","source_child_name":"无目标子类","target_child_ids":[]}],"atomic":true}"##.utf8)
    static let transformReceipt = Data(##"{"action":"merge","categories":[__TARGET__],"reclassified_transaction_count":4}"##.replacingOccurrences(of: "__TARGET__", with: targetCategory).utf8)
    static let splitReceipt = Data(##"{"action":"split","categories":[__TARGET__],"reclassified_transaction_count":4}"##.replacingOccurrences(of: "__TARGET__", with: targetCategory).utf8)
    static let splitPreview = Data(##"{"preview_token":"00000000-0000-0000-0000-00000000C502","root":{"category_id":"00000000-0000-0000-0000-00000000C201","transaction_count":4,"amount_minor":12800},"required_transaction_ids":["00000000-0000-0000-0000-00000000C401"],"child_names":["子分类一","子分类二"],"atomic":true}"##.utf8)
    static let mapping = Data(##"{"transaction_id":"00000000-0000-0000-0000-00000000C401","merchant":__M__,"mapping_version":2,"confirmed_at":"2026-08-15T04:00:00Z","provenance":"user_confirmed"}"##.replacingOccurrences(of: "__M__", with: merchant).utf8)
    static let mappingReceipt = Data(##"{"action":"confirm","mapping":__MAP__,"transaction_version":3}"##.replacingOccurrences(of: "__MAP__", with: String(decoding: mapping, as: UTF8.self)).utf8)
    @MainActor static func services(conflict: Bool = false) -> V15Services { V15Services(transport: V15F1CFixtureTransport(conflict: conflict)) }
}

actor V15F1CFixtureTransport: V15Transporting {
    private let conflict: Bool; private let unknownTransform: Bool; private let unknownMapping: Bool; private let merchantPageFailure: Bool; private let mergePreviewData: Data; private var requests: [V15Request] = []; private var bodies: [JSONValue?] = []
    init(conflict: Bool = false, unknownTransform: Bool = false, unknownMapping: Bool = false, merchantPageFailure: Bool = false, mergePreviewData: Data = V15F1CFixtures.preview) { self.conflict = conflict; self.unknownTransform = unknownTransform; self.unknownMapping = unknownMapping; self.merchantPageFailure = merchantPageFailure; self.mergePreviewData = mergePreviewData }
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        requests.append(request); bodies.append(body)
        if conflict && request.path.hasSuffix("/order") { throw V15Failure(kind: .conflict, code: "list_revision_conflict", message: "列表已变化。", conflict: .init(reloadPath: "/api/v1/accounts/order-state", latestRevision: nil, message: "列表已变化。")) }
        let data: Data
        switch (request.path, request.method) {
        case ("accounts/order-state", "GET"): data = V15F1CFixtures.accountState
        case ("accounts", "GET"), ("accounts/order", "PUT"): data = request.method == "PUT" ? Data("[\(V15F1CFixtures.account),\(V15F1CFixtures.accountTwo)]".utf8) : Data("[\(V15F1CFixtures.account),\(V15F1CFixtures.accountTwo)]".utf8)
        case ("accounts", "POST"), ("accounts/\(V15F1CFixtures.accountID)", "PATCH"), ("accounts/\(V15F1CFixtures.accountID)/archive", "POST"), ("accounts/\(V15F1CFixtures.accountID)/restore", "POST"), ("accounts/\(V15F1CFixtures.accountID)", "GET"): data = Data(V15F1CFixtures.account.utf8)
        case ("categories", "GET"), ("categories/order", "PUT"): data = V15F1CFixtures.categories
        case ("categories/order-state", "GET"): data = Data(##"{"parent_id":null,"direction":"expense","items":[__A__,__B__],"list_revision":"__R__"}"##.replacingOccurrences(of: "__A__", with: V15F1CFixtures.category).replacingOccurrences(of: "__B__", with: V15F1CFixtures.targetCategory).replacingOccurrences(of: "__R__", with: V15F1CFixtures.revision).utf8)
        case ("categories", "POST"), ("categories/\(V15F1CFixtures.categoryID)", "PATCH"), ("categories/\(V15F1CFixtures.categoryID)/archive", "POST"), ("categories/\(V15F1CFixtures.categoryID)/restore", "POST"), ("categories/\(V15F1CFixtures.categoryID)", "GET"): data = Data(V15F1CFixtures.category.utf8)
        case ("categories/\(V15F1CFixtures.categoryID)/merge-preview", "POST"): data = mergePreviewData
        case ("categories/\(V15F1CFixtures.categoryID)/merge-commit", "POST"):
            if unknownTransform { throw V15Failure(kind: .responseUnknown, message: "lost") }; data = V15F1CFixtures.transformReceipt
        case ("categories/\(V15F1CFixtures.categoryID)/split-preview", "POST"): data = V15F1CFixtures.splitPreview
        case ("categories/\(V15F1CFixtures.categoryID)/split-commit", "POST"):
            if unknownTransform { throw V15Failure(kind: .responseUnknown, message: "lost") }; data = V15F1CFixtures.splitReceipt
        case ("merchants", "GET"):
            if merchantPageFailure, request.query.contains(where: { $0.name == "cursor" }) { throw V15Failure(kind: .transport, message: "next failed") }; data = merchantPageFailure ? V15F1CFixtures.merchantFirstPage : V15F1CFixtures.merchantPage
        case ("merchants", "POST"), ("merchants/\(V15F1CFixtures.merchantID)", "PATCH"), ("merchants/\(V15F1CFixtures.merchantID)", "GET"): data = Data(V15F1CFixtures.merchant.utf8)
        case ("transactions/\(V15F1CFixtures.transactionID)/merchant-mapping", "GET"): data = V15F1CFixtures.mapping
        case ("transactions/\(V15F1CFixtures.transactionID)/merchant-mapping", "PUT"), ("transactions/\(V15F1CFixtures.transactionID)/merchant-mapping", "DELETE"):
            if unknownMapping { throw V15Failure(kind: .responseUnknown, message: "lost") }; data = V15F1CFixtures.mappingReceipt
        default: throw V15Failure(kind: .transport, code: "fixture_missing", message: "缺少 F1-C 夹具：\(request.path)")
        }
        return try V15FixtureCodec.decoder.decode(Response.self, from: data)
    }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { throw V15Failure(kind: .transport, code: "fixture_missing", message: "无导出夹具") }
    func lastRequest() -> V15Request? { requests.last }; func lastBody() -> JSONValue? { bodies.last ?? nil }; func paths() -> [String] { requests.map(\.path) }
    func idempotencyKeys(path: String) -> [String] { requests.filter { $0.path == path }.compactMap { $0.headers["Idempotency-Key"] } }
    func mergeCommitMappings() -> [(UUID, UUID)] {
        guard let index = requests.lastIndex(where: { $0.path.hasSuffix("/merge-commit") }), case let .object(object)? = bodies[index], case let .array(values)? = object["child_mappings"] else { return [] }
        return values.compactMap { value in
            guard case let .object(mapping) = value, case let .string(source)? = mapping["source_child_id"], case let .string(target)? = mapping["target_child_id"], let sourceID = UUID(uuidString: source), let targetID = UUID(uuidString: target) else { return nil }
            return (sourceID, targetID)
        }
    }
}
