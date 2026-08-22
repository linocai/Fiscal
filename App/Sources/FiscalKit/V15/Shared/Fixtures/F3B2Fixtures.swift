import Foundation

public enum V15F3B2Fixtures {
    public static let activePlanID = UUID(uuidString: "00000000-0000-0000-0000-00000000B401")!
    public static let completedPlanID = UUID(uuidString: "00000000-0000-0000-0000-00000000B402")!
    public static let settledPlanID = UUID(uuidString: "00000000-0000-0000-0000-00000000B403")!
    public static let partialPlanID = UUID(uuidString: "00000000-0000-0000-0000-00000000B404")!
    public static let cancelledPlanID = UUID(uuidString: "00000000-0000-0000-0000-00000000B405")!
    public static let unknownPlanID = UUID(uuidString: "00000000-0000-0000-0000-00000000B406")!
    public static let purchaseID = UUID(uuidString: "00000000-0000-0000-0000-00000000B410")!
    public static let accountID = UUID(uuidString: "00000000-0000-0000-0000-00000000B411")!
    public static let paymentID = UUID(uuidString: "00000000-0000-0000-0000-00000000B412")!
    public static let categoryID = UUID(uuidString: "00000000-0000-0000-0000-00000000B413")!
    public static let cycleID = UUID(uuidString: "00000000-0000-0000-0000-00000000B414")!
    public static let cycle2ID = UUID(uuidString: "00000000-0000-0000-0000-00000000B417")!
    public static let periodID = UUID(uuidString: "00000000-0000-0000-0000-00000000B415")!
    public static let operationID = UUID(uuidString: "00000000-0000-0000-0000-00000000B416")!

    @MainActor public static func services(route: String = "installments") -> V15Services { .init(transport: F3B2Transport(mode: .route(route))) }
    @MainActor static func services(transport: F3B2Transport) -> V15Services { .init(transport: transport) }

    static let accounts = """
    [{"id":"\(paymentID)","name":"日常付款账户","kind":"debit","institution":"示例机构","last_four":null,"opening_balance_minor":0,"current_balance_minor":800000,"credit_limit_minor":null,"statement_day":null,"due_day":null,"cycle_mode":null,"opening_balance_as_of_date":null,"opening_due_date":null,"sort_order":1,"archived_at":null,"usage_count":2,"version":2,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-15T00:00:00Z"},{"id":"\(accountID)","name":"日常信用账户","kind":"credit","institution":"示例机构","last_four":null,"opening_balance_minor":0,"current_balance_minor":-329900,"credit_limit_minor":1000000,"statement_day":10,"due_day":20,"cycle_mode":"statement_day_cutoff","opening_balance_as_of_date":null,"opening_due_date":null,"sort_order":2,"archived_at":null,"usage_count":3,"version":4,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-15T00:00:00Z"}]
    """
    static let categories = """
    [{"id":"\(categoryID)","name":"数码设备","direction":"expense","parent_id":null,"icon":"laptopcomputer","color_hex":"#167D86","aliases":[],"examples":[],"is_balance_adjustment":false,"sort_order":1,"archived_at":null,"usage_count":2,"version":2,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-15T00:00:00Z","children":[]}]
    """

    static func period(planID: UUID, sequence: Int = 1, locked: Bool = false, status: String = "scheduled") -> String { """
    {"id":"\(periodID)","plan_id":"\(planID)","sequence":\(sequence),"scheduled_cycle_id":"\(cycleID)","effective_cycle_id":"\(cycleID)","scheduled_statement_date":"2026-09-10","effective_statement_date":"2026-09-10","due_date":"2026-09-20","principal_minor":54984,"fee_minor":1666,"amount_due_minor":56650,"locked":\(locked),"status":"\(status)","cycle_status":"open","cancelled_at":null,"settled_early_at":null,"version":2,"created_at":"2026-08-15T00:00:00Z","updated_at":"2026-08-15T00:00:00Z"}
    """ }
    static func previewPeriod(sequence: Int = 1, locked: Bool = false, status: String = "scheduled") -> String {
        let statement = sequence <= 1 ? "2026-09-10" : sequence <= 3 ? "2026-10-10" : "2026-11-10"
        let due = sequence <= 1 ? "2026-09-20" : sequence <= 3 ? "2026-10-20" : "2026-11-20"
        let cycle = sequence <= 1 ? cycleID : cycle2ID
        return """
    {"sequence":\(sequence),"scheduled_cycle_id":"\(cycle)","effective_cycle_id":"\(cycle)","scheduled_statement_date":"\(statement)","effective_statement_date":"\(statement)","due_date":"\(due)","principal_minor":54984,"fee_minor":1666,"amount_due_minor":56650,"locked":\(locked),"status":"\(status)"}
    """ }
    static func plan(_ id: UUID = activePlanID, status: String = "active", version: Int = 3, updated: Bool = false, long: Bool = false, feeOccurredAt: String = "2026-08-15T01:00:00Z") -> String {
        let title = updated ? "更新后的设备计划" : (long ? "一段很长的中文分期计划标题，用于验证辅助功能字号和窄窗口下仍完整展示服务端事实" : "工作设备分期")
        let amount = updated ? 339900 : 329900; let count = updated ? 7 : 6; let fee = 9996
        let locked = status == "completed" || status == "settled_early"; let future = ["active", "partially_cancelled", "future_server_state"].contains(status) ? 5 : 0
        return """
        {"id":"\(id)","purchase_transaction_id":"\(purchaseID)","credit_account_id":"\(accountID)","fee_transaction_id":null,"fee_category_id":"\(categoryID)","fee_occurred_at":"\(feeOccurredAt)","title":"\(title)","status":"\(status)","principal_minor":\(amount),"fee_minor":\(fee),"total_financed_minor":\(amount + fee),"installment_count":\(count),"start_statement_date":"2026-09-10","locked_count":\(locked ? count : 1),"future_count":\(future),"cancelled_count":\(status.contains("cancelled") ? 2 : 0),"cycle_settled_count":\(locked ? count : 1),"scheduled_gross_minor":\(amount + fee),"future_scheduled_gross_minor":\(future > 0 ? 283250 : 0),"next_period":\(future > 0 ? period(planID: id) : "null"),"periods":[\(period(planID: id, locked: false))],"version":\(version),"created_at":"2026-08-15T00:00:00Z","updated_at":"2026-08-15T02:00:00Z"}
        """
    }
    static func previewPlan(status: String = "active") -> String { """
    {"id":"\(activePlanID)","purchase_transaction_id":"\(purchaseID)","credit_account_id":"\(accountID)","fee_transaction_id":null,"fee_category_id":"\(categoryID)","fee_occurred_at":"2026-08-15T01:00:00Z","title":"更新后的设备计划","status":"\(status)","principal_minor":339900,"fee_minor":9996,"total_financed_minor":349896,"installment_count":7,"start_statement_date":"2026-09-10","locked_count":1,"future_count":6,"cancelled_count":0,"cycle_settled_count":1,"scheduled_gross_minor":349896,"future_scheduled_gross_minor":299910,"next_period":\(previewPeriod()),"periods":[\(previewPeriod()),\(previewPeriod(sequence: 3)),\(previewPeriod(sequence: 7))]}
    """ }
    static func transaction(updated: Bool = false, id: UUID = purchaseID, kind: String = "credit_purchase", title: String? = nil, occurredAt: String = "2026-08-15T00:30:00Z", businessDate: String = "2026-08-15") -> String {
        let value = updated ? 339900 : 329900; let name = title ?? (updated ? "更新后的设备计划" : "工作设备")
        return """
        {"id":"\(id)","kind":"\(kind)","amount_minor":\(value),"occurred_at":"\(occurredAt)","business_date":"\(businessDate)","title":"\(name)","note":null,"category_id":"\(categoryID)","account_id":"\(kind == "repayment" ? paymentID : accountID)","destination_account_id":\(kind == "repayment" ? "\"\(accountID)\"" : "null"),"credit_cycle_id":\(kind == "repayment" ? "\"\(cycleID)\"" : "null"),"source":"\(kind == "credit_purchase" ? "manual" : "system")","postings":[],"version":\(updated ? 2 : 1),"voided_at":null,"created_at":"\(occurredAt)","updated_at":"2026-08-15T02:00:00Z","installment_plan_id":"\(activePlanID)","installment_relation":null,"reimbursement_relations":[],"available_actions":[]}
        """
    }
    static func page(next: String? = "opaque-installment-next") -> String {
        let cursor = next.map { "\"\($0)\"" } ?? "null"
        return """
        {"items":[\(plan()),\(plan(completedPlanID, status: "completed")),\(plan(settledPlanID, status: "settled_early")),\(plan(partialPlanID, status: "partially_cancelled")),\(plan(cancelledPlanID, status: "cancelled")),\(plan(unknownPlanID, status: "future_server_state", long: true))],"next_cursor":\(cursor)}
        """
    }
    static let eligibility = """
    {"purchase_transaction_id":"\(purchaseID)","eligible":true,"reason_code":null,"credit_account_id":"\(accountID)","principal_minor":329900,"natural_statement_date":"2026-09-10","start_options":[{"cycle_id":"\(cycleID)","statement_date":"2026-09-10","due_date":"2026-09-20","existing":true,"eligible":true},{"cycle_id":null,"statement_date":"2026-10-10","due_date":"2026-10-20","existing":false,"eligible":true}]}
    """
    static let ineligible = """
    {"purchase_transaction_id":"\(purchaseID)","eligible":false,"reason_code":"installment_plan_in_use","credit_account_id":"\(accountID)","principal_minor":329900,"natural_statement_date":"2026-09-10","start_options":[]}
    """
    static let options = """
    [{"cycle_id":"\(cycleID)","statement_date":"2026-09-10","due_date":"2026-09-20","existing":true,"eligible":true},{"cycle_id":null,"statement_date":"2026-10-10","due_date":"2026-10-20","existing":false,"eligible":true}]
    """
    static let liabilities = """
    {"account_id":"\(accountID)","total_future_scheduled_gross_minor":283250,"groups":[{"month":"2026-09","principal_scheduled_gross_minor":54984,"fee_scheduled_gross_minor":1666,"total_scheduled_gross_minor":56650,"period_count":1,"plans":[{"plan_id":"\(activePlanID)","title":"工作设备分期","status":"active","installment_count":6,"future_count":5,"future_scheduled_gross_minor":283250,"next_period":\(period(planID: activePlanID))}]}]}
    """
    static let purchasePreview = """
    {"purchase_amount_minor":329900,"total_fee_minor":9996,"total_financed_minor":339896,"start_statement_date":"2026-09-10","periods":[\(previewPeriod()),\(previewPeriod(sequence: 2)),\(previewPeriod(sequence: 3))]}
    """
    static let planChangePreview = """
    {"current_plan":\(plan()),"proposed_plan":\(previewPlan()),"locked_periods":[\(period(planID: activePlanID, locked: true, status: "cycle_settled"))],"future_periods":[\(previewPeriod(sequence: 2)),\(previewPeriod(sequence: 6)),\(previewPeriod(sequence: 7))],"affected_cycles":[{"statement_date":"2026-09-10","cycle_id":"\(cycleID)","before_due_minor":56650,"after_due_minor":49985,"delta_minor":-6665},{"statement_date":"2026-11-10","cycle_id":"\(cycle2ID)","before_due_minor":56650,"after_due_minor":49984,"delta_minor":-6666}],"warnings":[{"code":"locked_prefix_preserved","message":"已锁定期次保持不变。"},{"code":"future_cycles_shifted","message":"未来账期将按服务器方案顺延；请核对首末账单日期和每期金额。"}]}
    """
    static let settlementPreview = """
    {"amount_minor":283250,"current_plan":\(plan()),"proposed_plan":\(previewPlan(status: "settled_early")),"affected_cycles":[{"statement_date":"2026-09-10","cycle_id":"\(cycleID)","before_due_minor":56650,"after_due_minor":0,"delta_minor":-56650},{"statement_date":"2026-11-10","cycle_id":"\(cycle2ID)","before_due_minor":56650,"after_due_minor":0,"delta_minor":-56650}],"payment_balance_before_minor":800000,"payment_balance_after_minor":516750,"debt_before_minor":329900,"debt_after_minor":46650,"warnings":[{"code":"system_repayment","message":"将生成系统还款流水。"},{"code":"locked_periods_retained","message":"已锁定期次保持服务端原值，未来期次在结清后标记完成。"}]}
    """
    static let reversePreview = """
    {"eligible":true,"repayment_transaction":\(transaction(id: operationID, kind: "repayment", title: "提前结清还款")),"restored_periods":[\(previewPeriod()),\(previewPeriod(sequence: 7))],"affected_cycles":[{"statement_date":"2026-09-10","cycle_id":"\(cycleID)","before_due_minor":0,"after_due_minor":56650,"delta_minor":56650},{"statement_date":"2026-11-10","cycle_id":"\(cycle2ID)","before_due_minor":0,"after_due_minor":56650,"delta_minor":56650}],"payment_balance_before_minor":516750,"payment_balance_after_minor":800000,"debt_before_minor":46650,"debt_after_minor":329900,"warnings":[{"code":"reopen_future","message":"将恢复未来期次。"},{"code":"repayment_void","message":"原系统还款流水将由服务端作废。"}]}
    """
    static let cancelPreview = """
    {"principal_refund_minor":274916,"fee_refund_minor":8330,"cancelled_periods":[\(previewPeriod(sequence: 2, status: "cancelled")),\(previewPeriod(sequence: 7, status: "cancelled"))],"current_plan":\(plan()),"proposed_plan":\(previewPlan(status: "partially_cancelled")),"affected_cycles":[{"statement_date":"2026-09-10","cycle_id":"\(cycleID)","before_due_minor":56650,"after_due_minor":0,"delta_minor":-56650},{"statement_date":"2026-11-10","cycle_id":"\(cycle2ID)","before_due_minor":56650,"after_due_minor":0,"delta_minor":-56650}],"debt_before_minor":329900,"debt_after_minor":54984,"expense_before_minor":339896,"expense_after_minor":56650,"warnings":[{"code":"system_refund","message":"将生成系统退款流水。"},{"code":"future_only","message":"仅取消服务器返回的未来期次；已锁定期不会被客户端改写。"}]}
    """
}

actor F3B2Transport: V15Transporting {
    enum RaceOperation: Equatable { case purchase, create, update, command }
    enum RaceOutcome: Equatable { case success, unknown, failure }
    enum Mode: Equatable {
        case normal, pageFailure, ineligible, previewConflict, purchaseUnknownThenSuccess, createUnknownThenSuccess, commandUnknownThenSuccess, commandConflict, updateUnknownConfirmed, updateUnknownNotConfirmed, updateUnknownFeeDateMismatch, updateUnknownReadbackFailure, categoryFailureThenSuccess, categoryEmpty, categoryRace, listRace, detailRace, eligibilityRace, transactionDetailFailureThenSuccess, latePurchase, priorDayPurchase
        case operationRace(RaceOperation, RaceOutcome)
        static func route(_ route: String) -> Mode { switch route { case "installments-page-error": .pageFailure; case "installments-ineligible": .ineligible; case "installments-conflict": .previewConflict; case "installments-purchase-unknown": .purchaseUnknownThenSuccess; case "installments-create-unknown": .createUnknownThenSuccess; case "installments-command-unknown": .commandUnknownThenSuccess; case "installments-command-conflict": .commandConflict; case "installments-update-unknown-confirmed": .updateUnknownConfirmed; case "installments-update-unknown-not-confirmed": .updateUnknownNotConfirmed; case "installments-update-fee-date-mismatch": .updateUnknownFeeDateMismatch; case "installments-update-readback-error": .updateUnknownReadbackFailure; case "installments-category-error": .categoryFailureThenSuccess; case "installments-category-empty": .categoryEmpty; case "installments-category-race": .categoryRace; case "installments-list-race": .listRace; case "installments-detail-race": .detailRace; default: .normal } }
    }
    struct Wire: Sendable, Equatable { let method: String; let path: String; let key: String?; let body: String; let readCachePolicy: V15ReadCachePolicy }
    let mode: Mode
    private var wires: [Wire] = []
    private var commandAttempts = 0
    private var purchaseAttempts = 0
    private var createAttempts = 0
    private var putAttempts = 0
    private var listRequests = 0
    private var categoryRequests = 0
    private var purchaseDetailRequests = 0
    init(mode: Mode) { self.mode = mode }
    func recordedWires() -> [Wire] { wires }

    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        let bodyText = body.flatMap { try? String(data: V15BodyEncoder.data($0), encoding: .utf8) } ?? ""
        wires.append(.init(method: request.method, path: request.path, key: request.headers["Idempotency-Key"], body: bodyText, readCachePolicy: request.readCachePolicy))
        try validateBackendFeeBoundary(path: request.path, method: request.method, body: bodyText)
        let decode: (String) throws -> Response = { try V15FixtureCodec.decoder.decode(Response.self, from: Data($0.utf8)) }
        switch (request.path, request.method) {
        case ("accounts", "GET"): return try decode(V15F3B2Fixtures.accounts)
        case ("categories", "GET"):
            categoryRequests += 1
            if mode == .categoryEmpty { return try decode("[]") }
            if mode == .categoryFailureThenSuccess, categoryRequests == 1 { throw V15Failure(kind: .transport, message: "手续费分类读取失败。") }
            if mode == .categoryRace, categoryRequests == 1 { try await Task.sleep(for: .milliseconds(150)); throw V15Failure(kind: .transport, message: "过期的手续费分类请求失败。") }
            return try decode(V15F3B2Fixtures.categories)
        case ("installment-plans", "GET"):
            listRequests += 1
            if mode == .listRace, listRequests == 1 { try await Task.sleep(for: .milliseconds(150)) }
            if mode == .pageFailure, request.query.contains(where: { $0.name == "cursor" }) { throw V15Failure(kind: .transport, message: "下一页读取失败。") }
            return try decode(V15F3B2Fixtures.page(next: request.query.contains(where: { $0.name == "cursor" }) ? nil : "opaque-installment-next"))
        case (let path, "GET") where path.hasPrefix("installment-plans/"):
            if mode == .updateUnknownReadbackFailure, request.readCachePolicy == .reloadIgnoringCache, putAttempts > 0 { throw V15Failure(kind: .transport, message: "fresh plan readback failed") }
            let id = UUID(uuidString: String(path.dropFirst("installment-plans/".count))) ?? V15F3B2Fixtures.activePlanID
            if mode == .detailRace, id == V15F3B2Fixtures.activePlanID { try await Task.sleep(for: .milliseconds(150)) }
            let applied = [.updateUnknownConfirmed, .updateUnknownFeeDateMismatch].contains(mode) && putAttempts > 0 && request.readCachePolicy == .reloadIgnoringCache
            let thirdPartyCommand = mode == .commandUnknownThenSuccess && commandAttempts > 0 && request.readCachePolicy == .reloadIgnoringCache
            let status: String = thirdPartyCommand ? "settled_early" : id == V15F3B2Fixtures.completedPlanID ? "completed" : id == V15F3B2Fixtures.settledPlanID ? "settled_early" : id == V15F3B2Fixtures.partialPlanID ? "partially_cancelled" : id == V15F3B2Fixtures.cancelledPlanID ? "cancelled" : id == V15F3B2Fixtures.unknownPlanID ? "future_server_state" : "active"
            let feeOccurredAt = mode == .updateUnknownFeeDateMismatch && applied ? "2026-08-16T01:00:00Z" : "2026-08-15T01:00:00Z"
            return try decode(V15F3B2Fixtures.plan(id, status: status, version: applied || thirdPartyCommand ? 4 : 3, updated: applied, long: id == V15F3B2Fixtures.unknownPlanID, feeOccurredAt: feeOccurredAt))
        case ("transactions/\(V15F3B2Fixtures.purchaseID)", "GET"):
            purchaseDetailRequests += 1
            if mode == .eligibilityRace { try await Task.sleep(for: .milliseconds(150)) }
            if mode == .transactionDetailFailureThenSuccess, purchaseDetailRequests == 2 { throw V15Failure(kind: .transport, message: "消费详情读取失败。") }
            let applied = [.updateUnknownConfirmed, .updateUnknownFeeDateMismatch].contains(mode) && putAttempts > 0 && request.readCachePolicy == .reloadIgnoringCache
            if mode == .latePurchase { return try decode(V15F3B2Fixtures.transaction(updated: applied, occurredAt: "2026-08-15T02:30:00Z")) }
            if mode == .priorDayPurchase { return try decode(V15F3B2Fixtures.transaction(updated: applied, occurredAt: "2026-08-13T17:30:00Z", businessDate: "2026-08-14")) }
            return try decode(V15F3B2Fixtures.transaction(updated: applied))
        case ("installment-liabilities", "GET"): return try decode(V15F3B2Fixtures.liabilities)
        case ("transactions/\(V15F3B2Fixtures.purchaseID)/installment-eligibility", "GET"):
            if mode == .eligibilityRace { try await Task.sleep(for: .milliseconds(150)) }
            return try decode(mode == .ineligible ? V15F3B2Fixtures.ineligible : V15F3B2Fixtures.eligibility)
        case ("installment-cycle-options", "GET"): return try decode(mode == .ineligible ? "[]" : V15F3B2Fixtures.options)
        case ("installment-purchases/preview", "POST"): return try decode(V15F3B2Fixtures.purchasePreview)
        case ("installment-purchases", "POST"):
            purchaseAttempts += 1
            if case .operationRace(.purchase, let outcome) = mode { try await finishRace(outcome) }
            if mode == .purchaseUnknownThenSuccess, purchaseAttempts == 1 { throw V15Failure(kind: .responseUnknown, message: "分期消费创建结果未知。") }
            return try decode("{\"purchase\":\(V15F3B2Fixtures.transaction()),\"plan\":\(V15F3B2Fixtures.plan())}")
        case ("installment-plans", "POST"):
            createAttempts += 1
            if case .operationRace(.create, let outcome) = mode { try await finishRace(outcome) }
            if mode == .createUnknownThenSuccess, createAttempts == 1 { throw V15Failure(kind: .responseUnknown, message: "计划创建结果未知。") }
            return try decode(V15F3B2Fixtures.plan())
        case ("installment-plans/\(V15F3B2Fixtures.activePlanID)/preview", "POST"):
            if mode == .previewConflict { throw V15Failure(kind: .conflict, code: "version_conflict", message: "计划版本已变化。", conflict: .init(reloadPath: "/api/v1/installment-plans/\(V15F3B2Fixtures.activePlanID)", latestRevision: nil, currentVersion: 4, expectedVersion: 3, safeToReload: true, message: "计划版本已变化。")) }
            return try decode(V15F3B2Fixtures.planChangePreview)
        case ("installment-plans/\(V15F3B2Fixtures.activePlanID)", "PUT"):
            putAttempts += 1
            if case .operationRace(.update, let outcome) = mode { try await finishRace(outcome) }
            if [.updateUnknownConfirmed, .updateUnknownNotConfirmed, .updateUnknownFeeDateMismatch, .updateUnknownReadbackFailure].contains(mode) { throw V15Failure(kind: .responseUnknown, message: "计划修改结果未知。") }
            return try decode(V15F3B2Fixtures.plan(version: 4, updated: true))
        case ("installment-plans/\(V15F3B2Fixtures.activePlanID)/settlement-preview", "POST"): return try decode(V15F3B2Fixtures.settlementPreview)
        case ("installment-plans/\(V15F3B2Fixtures.activePlanID)/reverse-settlement-preview", "POST"): return try decode(V15F3B2Fixtures.reversePreview)
        case ("installment-plans/\(V15F3B2Fixtures.activePlanID)/cancel-preview", "POST"): return try decode(V15F3B2Fixtures.cancelPreview)
        case ("installment-plans/\(V15F3B2Fixtures.activePlanID)/settle-early", "POST"):
            commandAttempts += 1
            if case .operationRace(.command, let outcome) = mode { try await finishRace(outcome) }
            if mode == .commandUnknownThenSuccess, commandAttempts == 1 { throw V15Failure(kind: .responseUnknown, message: "结清结果未知。") }
            if mode == .commandConflict { throw V15Failure(kind: .conflict, code: "version_conflict", message: "计划版本已变化。", conflict: .init(reloadPath: nil, latestRevision: nil, currentVersion: 4, expectedVersion: 3, message: "计划版本已变化。")) }
            return try decode("{\"operation_id\":\"\(V15F3B2Fixtures.operationID)\",\"plan\":\(V15F3B2Fixtures.plan(status: "settled_early", version: 4)),\"repayment_transaction\":\(V15F3B2Fixtures.transaction(id: V15F3B2Fixtures.operationID, kind: "repayment", title: "提前结清还款")),\"replayed\":\(commandAttempts > 1)}")
        case ("installment-plans/\(V15F3B2Fixtures.activePlanID)/reverse-settlement", "POST"):
            commandAttempts += 1
            if case .operationRace(.command, let outcome) = mode { try await finishRace(outcome) }
            return try decode("{\"operation_id\":\"\(V15F3B2Fixtures.operationID)\",\"plan\":\(V15F3B2Fixtures.plan(version: 5)),\"voided_repayment_transaction\":\(V15F3B2Fixtures.transaction(id: V15F3B2Fixtures.operationID, kind: "repayment", title: "已作废结清还款")),\"replayed\":false}")
        case ("installment-plans/\(V15F3B2Fixtures.activePlanID)/cancel-future", "POST"):
            commandAttempts += 1
            if case .operationRace(.command, let outcome) = mode { try await finishRace(outcome) }
            return try decode("{\"operation_id\":\"\(V15F3B2Fixtures.operationID)\",\"plan\":\(V15F3B2Fixtures.plan(status: "partially_cancelled", version: 4)),\"refund_transactions\":[\(V15F3B2Fixtures.transaction(id: V15F3B2Fixtures.operationID, kind: "installment_refund", title: "分期退款"))],\"replayed\":false}")
        default: throw V15Failure(kind: .transport, message: "F3-B2 fixture unsupported: \(request.method) \(request.path)")
        }
    }
    private func finishRace(_ outcome: RaceOutcome) async throws {
        try await Task.sleep(for: .milliseconds(180))
        switch outcome {
        case .success: return
        case .unknown: throw V15Failure(kind: .responseUnknown, message: "服务器已收到请求，但响应在确认前中断。")
        case .failure: throw V15Failure(kind: .decoding, message: "服务端明确拒绝了该请求。")
        }
    }
    private func validateBackendFeeBoundary(path: String, method: String, body: String) throws {
        guard method == "POST" || method == "PUT" else { return }
        let totalFeeMinor: V15MinorUnits
        let feeOccurredAt: Date?
        let purchaseOccurredAt: Date
        if path == "installment-purchases/preview" || path == "installment-purchases" {
            guard let value = try? V15FixtureCodec.decoder.decode(V15InstallmentPurchaseCreateRequest.self, from: Data(body.utf8)) else { return }
            totalFeeMinor = value.totalFeeMinor; feeOccurredAt = value.feeOccurredAt; purchaseOccurredAt = value.purchase.occurredAt
        } else if path == "installment-plans" {
            guard let value = try? V15FixtureCodec.decoder.decode(V15InstallmentCreateRequest.self, from: Data(body.utf8)) else { return }
            totalFeeMinor = value.totalFeeMinor; feeOccurredAt = value.feeOccurredAt
            purchaseOccurredAt = mode == .latePurchase ? ISO8601DateFormatter().date(from: "2026-08-15T02:30:00Z")! : mode == .priorDayPurchase ? ISO8601DateFormatter().date(from: "2026-08-13T17:30:00Z")! : ISO8601DateFormatter().date(from: "2026-08-15T00:30:00Z")!
        } else if path.hasSuffix("/preview") || (path.hasPrefix("installment-plans/") && method == "PUT") {
            guard let value = try? V15FixtureCodec.decoder.decode(V15InstallmentReplacementRequest.self, from: Data(body.utf8)) else { return }
            totalFeeMinor = value.totalFeeMinor; feeOccurredAt = value.feeOccurredAt; purchaseOccurredAt = value.purchase.occurredAt
        } else { return }
        let backendNow = ISO8601DateFormatter().date(from: "2026-08-15T15:59:59Z")!
        let valid = totalFeeMinor == 0 ? feeOccurredAt == nil : feeOccurredAt.map { $0 >= purchaseOccurredAt && $0 <= backendNow } == true
        guard valid else {
            throw V15Failure(kind: .transport, code: "invalid_installment_schedule", message: "Backend-like fixture rejected fee occurrence time.", fieldIssues: [.init(code: "fee_time_out_of_bounds", message: "手续费时间必须不早于消费且不得晚于当前时间。", fieldPath: "fee_occurred_at")])
        }
    }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { throw V15Failure(kind: .transport, message: "F3-B2 has no artifacts") }
}
