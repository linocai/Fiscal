import Foundation

/// Offline-synthetic F3-D facts. No production account tail, receipt, provider
/// payload or transaction evidence is embedded in these fixtures.
public enum V15F3DFixtures {
    public static let itemID = UUID(uuidString: "00000000-0000-0000-0000-00000000D311")!
    public static let transferID = UUID(uuidString: "00000000-0000-0000-0000-00000000D312")!
    public static let historyID = UUID(uuidString: "00000000-0000-0000-0000-00000000D313")!
    public static let createdID = UUID(uuidString: "00000000-0000-0000-0000-00000000D314")!
    public static let julyHistoryID = UUID(uuidString: "00000000-0000-0000-0000-00000000D316")!
    public static let seriesID = UUID(uuidString: "00000000-0000-0000-0000-00000000D315")!
    public static let cashAccountID = UUID(uuidString: "00000000-0000-0000-0000-00000000D321")!
    public static let debitAccountID = UUID(uuidString: "00000000-0000-0000-0000-00000000D322")!
    public static let creditAccountID = UUID(uuidString: "00000000-0000-0000-0000-00000000D323")!
    public static let expenseCategoryID = UUID(uuidString: "00000000-0000-0000-0000-00000000D331")!
    public static let incomeCategoryID = UUID(uuidString: "00000000-0000-0000-0000-00000000D332")!
    public static let reimbursementID = UUID(uuidString: "00000000-0000-0000-0000-00000000D341")!
    public static let creditCycleID = UUID(uuidString: "00000000-0000-0000-0000-00000000D342")!

    @MainActor public static func services(route: String = "cash-flow") -> V15Services { .init(transport: F3DTransport(mode: .route(route))) }

    static let accounts = """
    [
      {"id":"\(cashAccountID)","name":"日常现金","kind":"cash","institution":null,"last_four":null,"opening_balance_minor":0,"current_balance_minor":286400,"credit_limit_minor":null,"statement_day":null,"due_day":null,"cycle_mode":null,"opening_balance_as_of_date":null,"opening_due_date":null,"sort_order":1,"archived_at":null,"usage_count":3,"version":2,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-15T00:00:00Z"},
      {"id":"\(debitAccountID)","name":"旅行借记账户","kind":"debit","institution":"示例机构","last_four":null,"opening_balance_minor":0,"current_balance_minor":900000,"credit_limit_minor":null,"statement_day":null,"due_day":null,"cycle_mode":null,"opening_balance_as_of_date":null,"opening_due_date":null,"sort_order":2,"archived_at":null,"usage_count":2,"version":4,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-15T00:00:00Z"},
      {"id":"\(creditAccountID)","name":"示例信用账户","kind":"credit","institution":null,"last_four":null,"opening_balance_minor":0,"current_balance_minor":-128000,"credit_limit_minor":500000,"statement_day":20,"due_day":5,"cycle_mode":"previous_calendar_month","opening_balance_as_of_date":null,"opening_due_date":null,"sort_order":3,"archived_at":null,"usage_count":1,"version":2,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-15T00:00:00Z"}
    ]
    """
    static func categories(direction: String) -> String {
        let id = direction == "income" ? incomeCategoryID : expenseCategoryID
        let name = direction == "income" ? "收入示例" : "生活服务"
        return "[{\"id\":\"\(id)\",\"name\":\"\(name)\",\"direction\":\"\(direction)\",\"parent_id\":null,\"icon\":\"circle\",\"color_hex\":\"#1F766E\",\"aliases\":[],\"examples\":[],\"is_balance_adjustment\":false,\"sort_order\":1,\"archived_at\":null,\"usage_count\":2,\"version\":1,\"created_at\":\"2026-08-01T00:00:00Z\",\"updated_at\":\"2026-08-15T00:00:00Z\",\"children\":[]}]"
    }
    static func item(id: UUID = itemID, title: String = "每月工作室租金", direction: String = "outflow", amount: Int64 = 253_300, date: String = "2026-08-22", account: UUID? = cashAccountID, destination: UUID? = nil, category: UUID? = expenseCategoryID, status: String = "expected", version: Int = 3, series: UUID? = seriesID, linked: UUID? = nil, actual: Int64? = nil, actualDate: String? = nil, actions: String = "[\"confirm\",\"edit\",\"cancel\"]", source: String = "manual") -> String {
        let uuid: (UUID?) -> String = { $0.map { "\"\($0.uuidString)\"" } ?? "null" }
        let int: (Int64?) -> String = { $0.map(String.init) ?? "null" }
        let str: (String?) -> String = { $0.map { "\"\($0)\"" } ?? "null" }
        return "{\"id\":\"\(id.uuidString)\",\"manual_item_id\":\"\(id.uuidString)\",\"system_kind\":null,\"system_reference_id\":null,\"series_id\":\(uuid(series)),\"title\":\"\(title)\",\"note\":\"离线合成说明\",\"direction\":\"\(direction)\",\"planned_amount_minor\":\(amount),\"expected_date\":\"\(date)\",\"account_id\":\(uuid(account)),\"destination_account_id\":\(uuid(destination)),\"category_id\":\(uuid(category)),\"status\":\"\(status)\",\"source\":\"\(source)\",\"version\":\(version),\"linked_transaction_id\":\(uuid(linked)),\"actual_amount_minor\":\(int(actual)),\"actual_date\":\(str(actualDate)),\"is_overdue\":false,\"actions\":\(actions),\"credit_cycle_parts\":[],\"created_at\":\"2026-08-01T00:00:00Z\",\"updated_at\":\"2026-08-15T00:00:00Z\"}"
    }
    static func system(kind: String, reference: UUID, title: String, direction: String, amount: Int64, date: String, account: UUID?, actions: String, version: Int = 1) -> String {
        let accountJSON = account.map { "\"\($0.uuidString)\"" } ?? "null"
        return "{\"id\":\"\(kind):\(reference.uuidString)\",\"manual_item_id\":null,\"system_kind\":\"\(kind)\",\"system_reference_id\":\"\(reference.uuidString)\",\"series_id\":null,\"title\":\"\(title)\",\"note\":null,\"direction\":\"\(direction)\",\"planned_amount_minor\":\(amount),\"expected_date\":\"\(date)\",\"account_id\":\(accountJSON),\"destination_account_id\":null,\"category_id\":null,\"status\":\"confirmed\",\"source\":\"system\",\"version\":\(version),\"linked_transaction_id\":null,\"actual_amount_minor\":null,\"actual_date\":null,\"is_overdue\":false,\"actions\":\(actions),\"credit_cycle_parts\":[],\"created_at\":null,\"updated_at\":null}"
    }
    static func active(items: String? = nil) -> String {
        let values = items ?? "[\(item()),\(item(id: transferID, title: "储蓄调拨", direction: "transfer", amount: 80_000, date: "2026-08-25", account: cashAccountID, destination: debitAccountID, category: nil, status: "confirmed", version: 2, series: nil, actions: "[\"settle\",\"edit\",\"cancel\"]")),\(system(kind: "reimbursement", reference: reimbursementID, title: "示例公司 报销待到账", direction: "inflow", amount: 188_888, date: "2026-08-20", account: nil, actions: "[\"mark_received\",\"edit\"]")),\(system(kind: "credit_cycle", reference: creditCycleID, title: "示例信用账户 账单应还", direction: "outflow", amount: 128_000, date: "2026-08-21", account: creditAccountID, actions: "[\"confirm_repayment\"]"))]"
        return "{\"summary\":{\"date_from\":\"2026-08-16\",\"date_to\":\"2026-09-14\",\"inflow_minor\":188888,\"outflow_minor\":461300,\"net_minor\":-272412},\"items\":\(values)}"
    }
    static func history(month: String = "2026-08", items: String? = nil) -> String {
        let historyItem = item(id: historyID, title: "已兑现顾问费", direction: "inflow", amount: 922_337_203_685_477, date: "2026-08-09", account: debitAccountID, category: incomeCategoryID, status: "settled", version: 5, series: nil, linked: UUID(uuidString: "00000000-0000-0000-0000-00000000D351"), actual: 922_337_203_685_477, actualDate: "2026-08-09", actions: "[\"edit\"]")
        let response = "{\"month\":\"\(month)\",\"items\":\(items ?? "[\(historyItem)]")}"
        return response
    }
}

actor F3DTransport: V15Transporting {
    enum Mode: Equatable {
        case normal, empty, initialError, historyError, fieldError, createUnknown, settleUnknown, directUnknown, conflict, refreshFailure, selectionRace, long
        static func route(_ route: String) -> Mode { switch route { case "cash-flow-empty": .empty; case "cash-flow-error": .initialError; case "cash-flow-history-error": .historyError; case "cash-flow-field-error": .fieldError; case "cash-flow-create-unknown": .createUnknown; case "cash-flow-settle-unknown", "cash-flow-unknown": .settleUnknown; case "cash-flow-direct-unknown": .directUnknown; case "cash-flow-conflict": .conflict; case "cash-flow-partial-refresh": .refreshFailure; case "cash-flow-long": .long; default: .normal } }
    }
    struct Wire: Sendable, Equatable { let method: String; let path: String; let key: String?; let body: String }
    let mode: Mode
    private var requests: [V15Request] = []
    private var wires: [Wire] = []
    private var createCount = 0
    private var settleCount = 0
    private var directCount = 0
    private var activeCount = 0
    private var createdApplied = false
    private var settledApplied = false
    private var updatedApplied = false
    private var confirmedApplied = false
    private var cancelledIDs = Set<UUID>()
    private var systemApplied = false
    init(mode: Mode) { self.mode = mode }
    func allRequests() -> [V15Request] { requests }
    func mutationWires() -> [Wire] { wires }

    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        requests.append(request)
        let decode: (String) throws -> Response = { try V15FixtureCodec.decoder.decode(Response.self, from: Data($0.utf8)) }
        let bodyText = body.flatMap { try? String(data: V15BodyEncoder.data($0), encoding: .utf8) } ?? ""
        if request.method != "GET" { wires.append(.init(method: request.method, path: request.path, key: request.headers["Idempotency-Key"], body: bodyText)) }
        switch (request.path, request.method) {
        case ("accounts", "GET"): return try decode(V15F3DFixtures.accounts)
        case ("categories", "GET"):
            let direction = request.query.first(where: { $0.name == "direction" })?.value ?? "expense"
            return try decode(V15F3DFixtures.categories(direction: direction))
        case ("cash-flow-items", "GET"):
            activeCount += 1
            if mode == .initialError && activeCount == 1 { throw V15Failure(kind: .transport, message: "现金流读取失败。") }
            if mode == .refreshFailure && activeCount > 1 { throw V15Failure(kind: .transport, message: "写后事实读取失败。") }
            let requestedAccount = request.query.first(where: { $0.name == "account_id" })?.value
            if mode == .selectionRace && requestedAccount != V15F3DFixtures.debitAccountID.uuidString { try await Task.sleep(for: .milliseconds(140)) }
            if mode == .selectionRace && requestedAccount == V15F3DFixtures.debitAccountID.uuidString { return try decode(V15F3DFixtures.active(items: "[]")) }
            if mode == .empty { return try decode(V15F3DFixtures.active(items: "[]")) }
            if mode == .long { let unknown = V15F3DFixtures.item(title: "一条用于辅助功能字号和超长中文换行检查的现金流事项名称，仍然只呈现服务端事实", amount: 9_223_372_036_854_775, status: "future_state", actions: "[\"future_action\"]"); return try decode(V15F3DFixtures.active(items: "[\(unknown)]")) }
            var items = [currentItem(), currentTransfer(), currentSystem(), V15F3DFixtures.system(kind: "credit_cycle", reference: V15F3DFixtures.creditCycleID, title: "示例信用账户 账单应还", direction: "outflow", amount: 128_000, date: "2026-08-21", account: V15F3DFixtures.creditAccountID, actions: "[\"confirm_repayment\"]")]
            if createdApplied { items.append(V15F3DFixtures.item(id: V15F3DFixtures.createdID, title: "新建现金流", direction: "outflow", amount: 12_345, date: "2026-08-28", version: 1, series: nil)) }
            return try decode(V15F3DFixtures.active(items: "[\(items.joined(separator: ","))]"))
        case ("cash-flow-items/history", "GET"):
            if mode == .historyError { throw V15Failure(kind: .transport, message: "历史读取失败。") }
            if mode == .refreshFailure && (createCount + settleCount + directCount) > 0 { throw V15Failure(kind: .transport, message: "写后历史读取失败。") }
            let requestedMonth = request.query.first(where: { $0.name == "month" })?.value ?? "2026-08"
            if mode == .selectionRace && requestedMonth == "2026-08" { try await Task.sleep(for: .milliseconds(140)) }
            if mode == .selectionRace && requestedMonth == "2026-07" {
                let july = V15F3DFixtures.item(id: V15F3DFixtures.julyHistoryID, title: "七月已兑现奖金", direction: "inflow", amount: 66_000, date: "2026-07-12", account: V15F3DFixtures.debitAccountID, category: V15F3DFixtures.incomeCategoryID, status: "settled", version: 2, series: nil, actual: 66_000, actualDate: "2026-07-12", actions: "[\"edit\"]")
                return try decode(V15F3DFixtures.history(month: "2026-07", items: "[\(july)]"))
            }
            return try decode(mode == .empty ? V15F3DFixtures.history(items: "[]") : V15F3DFixtures.history())
        case ("cash-flow-items/\(V15F3DFixtures.itemID)", "GET"):
            if mode == .selectionRace { try await Task.sleep(for: .milliseconds(140)) }
            if mode == .long { return try decode(V15F3DFixtures.item(title: "一条用于辅助功能字号和超长中文换行检查的现金流事项名称，仍然只呈现服务端事实", amount: 9_223_372_036_854_775, status: "future_state", actions: "[\"future_action\"]")) }
            return try decode(currentItem())
        case ("cash-flow-items/\(V15F3DFixtures.transferID)", "GET"): return try decode(currentTransfer())
        case ("cash-flow-items/\(V15F3DFixtures.historyID)", "GET"): return try decode(V15F3DFixtures.item(id: V15F3DFixtures.historyID, title: "已兑现顾问费", direction: "inflow", amount: 922_337_203_685_477, date: "2026-08-09", account: V15F3DFixtures.debitAccountID, category: V15F3DFixtures.incomeCategoryID, status: "settled", version: 5, series: nil, actual: 922_337_203_685_477, actualDate: "2026-08-09", actions: "[\"edit\"]"))
        case ("cash-flow-items/\(V15F3DFixtures.julyHistoryID)", "GET"): return try decode(V15F3DFixtures.item(id: V15F3DFixtures.julyHistoryID, title: "七月已兑现奖金", direction: "inflow", amount: 66_000, date: "2026-07-12", account: V15F3DFixtures.debitAccountID, category: V15F3DFixtures.incomeCategoryID, status: "settled", version: 2, series: nil, actual: 66_000, actualDate: "2026-07-12", actions: "[\"edit\"]"))
        case ("cash-flow-items/\(V15F3DFixtures.createdID)", "GET"): return try decode(V15F3DFixtures.item(id: V15F3DFixtures.createdID, title: "新建现金流", direction: "outflow", amount: 12_345, date: "2026-08-28", version: 1, series: nil))
        case ("cash-flow-items", "POST"):
            createCount += 1
            if mode == .fieldError { throw V15Failure(kind: .transport, code: "validation_error", message: "字段校验失败。", fieldIssues: [.init(code: "title_reserved", message: "标题不可用。", fieldPath: "title"), .init(code: "account_inactive", message: "账户已停用。", fieldPath: "account_id")]) }
            if mode == .createUnknown && createCount == 1 { throw V15Failure(kind: .responseUnknown, message: "新建结果未知。") }
            createdApplied = true
            return try decode("{\"items\":[\(V15F3DFixtures.item(id: V15F3DFixtures.createdID, title: "新建现金流", direction: "outflow", amount: 12_345, date: "2026-08-28", version: 1, series: nil))]}")
        case ("cash-flow-items/\(V15F3DFixtures.transferID)/settle", "POST"):
            settleCount += 1
            if mode == .settleUnknown && settleCount == 1 { throw V15Failure(kind: .responseUnknown, message: "入账结果未知。") }
            settledApplied = true
            return try decode(V15F3DFixtures.item(id: V15F3DFixtures.transferID, title: "储蓄调拨", direction: "transfer", amount: 80_000, date: "2026-08-25", account: V15F3DFixtures.cashAccountID, destination: V15F3DFixtures.debitAccountID, category: nil, status: "settled", version: 3, series: nil, linked: UUID(uuidString: "00000000-0000-0000-0000-00000000D352"), actual: 80_000, actualDate: "2026-08-16", actions: "[\"edit\"]"))
        case ("cash-flow-items/\(V15F3DFixtures.itemID)", "PUT"):
            directCount += 1
            if mode == .selectionRace { try await Task.sleep(for: .milliseconds(140)) }
            if mode == .directUnknown { throw V15Failure(kind: .responseUnknown, message: "修改结果未知。") }
            if mode == .conflict { throw V15Failure(kind: .conflict, code: "version_conflict", message: "现金流已变化。", conflict: .init(reloadPath: "/api/v1/cash-flow-items/\(V15F3DFixtures.itemID)", latestRevision: nil, currentVersion: 4, expectedVersion: 3, safeToReload: true, message: "现金流已变化。")) }
            updatedApplied = true
            return try decode("{\"items\":[\(V15F3DFixtures.item(title: "已更新租金", amount: 260_000, version: 4))]}")
        case ("cash-flow-items/\(V15F3DFixtures.itemID)/confirm", "POST"):
            directCount += 1
            if mode == .directUnknown { throw V15Failure(kind: .responseUnknown, message: "确认结果未知。") }
            confirmedApplied = true
            return try decode(V15F3DFixtures.item(status: "confirmed", version: 4, actions: "[\"settle\",\"edit\",\"cancel\"]"))
        case ("cash-flow-items/\(V15F3DFixtures.itemID)/cancel", "POST"), ("cash-flow-items/\(V15F3DFixtures.transferID)/cancel", "POST"):
            directCount += 1
            if mode == .directUnknown { throw V15Failure(kind: .responseUnknown, message: "取消结果未知。") }
            let id = request.path.contains(V15F3DFixtures.transferID.uuidString) ? V15F3DFixtures.transferID : V15F3DFixtures.itemID
            cancelledIDs.insert(id)
            return try decode("{\"items\":[\(V15F3DFixtures.item(id: id, status: "cancelled", version: 4, series: id == V15F3DFixtures.itemID ? V15F3DFixtures.seriesID : nil, actions: "[\"edit\"]"))]}")
        case ("cash-flow-system-items/reimbursement/\(V15F3DFixtures.reimbursementID)", "PUT"):
            directCount += 1
            if mode == .directUnknown { throw V15Failure(kind: .responseUnknown, message: "系统事项修改结果未知。") }
            systemApplied = true
            return try decode(V15F3DFixtures.system(kind: "reimbursement", reference: V15F3DFixtures.reimbursementID, title: "报销展示标题", direction: "inflow", amount: 188_888, date: "2026-08-23", account: nil, actions: "[\"mark_received\",\"edit\"]", version: 2))
        default: throw V15Failure(kind: .transport, message: "F3-D fixture does not support \(request.method) \(request.path).")
        }
    }

    private func currentItem() -> String {
        if cancelledIDs.contains(V15F3DFixtures.itemID) { return V15F3DFixtures.item(status: "cancelled", version: 4, actions: "[\"edit\"]") }
        if confirmedApplied { return V15F3DFixtures.item(status: "confirmed", version: 4, actions: "[\"settle\",\"edit\",\"cancel\"]") }
        if updatedApplied { return V15F3DFixtures.item(title: "已更新租金", amount: 260_000, version: 4) }
        return V15F3DFixtures.item()
    }

    private func currentTransfer() -> String {
        if settledApplied { return V15F3DFixtures.item(id: V15F3DFixtures.transferID, title: "储蓄调拨", direction: "transfer", amount: 80_000, date: "2026-08-25", account: V15F3DFixtures.cashAccountID, destination: V15F3DFixtures.debitAccountID, category: nil, status: "settled", version: 3, series: nil, linked: UUID(uuidString: "00000000-0000-0000-0000-00000000D352"), actual: 80_000, actualDate: "2026-08-16", actions: "[\"edit\"]") }
        if cancelledIDs.contains(V15F3DFixtures.transferID) { return V15F3DFixtures.item(id: V15F3DFixtures.transferID, title: "储蓄调拨", direction: "transfer", amount: 80_000, date: "2026-08-25", account: V15F3DFixtures.cashAccountID, destination: V15F3DFixtures.debitAccountID, category: nil, status: "cancelled", version: 4, series: nil, actions: "[\"edit\"]") }
        return V15F3DFixtures.item(id: V15F3DFixtures.transferID, title: "储蓄调拨", direction: "transfer", amount: 80_000, date: "2026-08-25", account: V15F3DFixtures.cashAccountID, destination: V15F3DFixtures.debitAccountID, category: nil, status: "confirmed", version: 2, series: nil, actions: "[\"settle\",\"edit\",\"cancel\"]")
    }

    private func currentSystem() -> String {
        V15F3DFixtures.system(kind: "reimbursement", reference: V15F3DFixtures.reimbursementID, title: systemApplied ? "报销展示标题" : "示例公司 报销待到账", direction: "inflow", amount: 188_888, date: systemApplied ? "2026-08-23" : "2026-08-20", account: nil, actions: "[\"mark_received\",\"edit\"]", version: systemApplied ? 2 : 1)
    }

    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { throw V15Failure(kind: .transport, message: "F3-D has no artifact endpoint.") }
}
