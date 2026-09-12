import Foundation

/// Explicit synthetic scenario: all mutations remain inside this actor.
public enum V230Fixtures {
    public static let accountID = UUID(uuidString: "00000000-0000-0000-0000-000000002301")!
    @MainActor public static func services(scenario: String = "v230") -> V15Services {
        V15Services(transport: V230FixtureTransport(scenario: scenario))
    }
}
actor V230FixtureTransport: V15Transporting {
    private let fallback = V15F2BFixtureTransport(route: .rootWorkspace)
    private let scenario: String
    private var transactionResults: [String: Data] = [:]
    private var repaymentDrafts: [UUID: V15TransactionCreateRequest] = [:]
    private var actionResults: [String: Data] = [:]
    private var records: [UUID: V15CreditPayoffReceipt] = [:]
    private var commits: [String: V15CreditPayoffReceipt] = [:]
    private var previews: [UUID: V15CreditPayoffRequest] = [:]
    private var settledAmount: Int64 = 0
    private var closedRemainder = false
    private var settlementIDs: [String] = []
    private var cashFlowKeys: Set<String> = []
    private var cashFlowVersion = 1
    private var debt: Int64 = 128000
    private var cash: Int64 = 600000
    private var revision: Int64 = 42
    private var didLoseResponse = false
    init(scenario: String = "v230") { self.scenario = scenario }
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        let id = V230Fixtures.accountID
        let path = request.path.lowercased()
        if path == "accounts", request.method == "GET" {
            var values = try JSONSerialization.jsonObject(with: V15F1AFixtures.accounts) as! [[String: Any]]
            values[0]["current_balance_minor"] = cash - 200000; values[2] = try accountObject(); values += try overflowAccounts(); return try decode(values)
        }
        if path == "accounts/\(id.uuidString.lowercased())" { return try decode(accountObject()) }
        if path == "accounts/order-state", request.method == "GET" {
            var values = try JSONSerialization.jsonObject(with: V15F1AFixtures.accounts) as! [[String: Any]]; values[0]["current_balance_minor"] = cash - 200000; values[2] = try accountObject(); values += try overflowAccounts()
            return try decode(["items": values, "list_revision": "v230-\(revision)"])
        }
        if scenario == "v230-many-accounts", path.hasPrefix("accounts/"), request.method == "GET",
           let account = try overflowAccounts().first(where: { ($0["id"] as? String)?.lowercased() == String(path.dropFirst("accounts/".count)) }) {
            return try decode(account)
        }
        if path == "credit-accounts" { return try decode([summaryObject()]) }
        if path == "credit-accounts/\(id.uuidString.lowercased())" { return try decode(summaryObject()) }
        if path.contains("/cycles") && path.contains(id.uuidString.lowercased()) { return try decode(["items": [], "next_cursor": NSNull()]) }
        if path.hasSuffix("/payoffs") { return try encode(Array(records.values)) }
        if path.hasSuffix("/payoff-preview"), let body {
            let input = try V15BodyEncoder.decode(V15CreditPayoffRequest.self, from: body)
            guard input.waivedPrincipalMinor <= debt, input.waivedFeeMinor == 0 else { throw V15Failure(kind: .transport, message: "减免超出可核对的本金或费用。", fieldIssues: [.init(code: "waiver_invalid", message: "此示例没有可减免费用，本金减免不能超过欠款。", fieldPath: "waived_fee_minor")], isDefinitiveRejection: true) }
            let expected = try checkedAdd(checkedSubtract(checkedSubtract(debt, input.waivedPrincipalMinor), input.waivedFeeMinor), input.additionalFeeMinor)
            guard input.actualAmountMinor == expected else { throw V15Failure(kind: .transport, code: "payoff_amount_mismatch", message: "银行实扣与账面欠款及减免不符，请核对差额。", fieldIssues: [.init(code: "payoff_amount_mismatch", message: "应扣 ¥\(V15RepaymentAmountMessage.amount(expected))", fieldPath: "actual_amount_minor")], isDefinitiveRejection: true) }
            let token = UUID(); previews[token] = input
            return try encode(V15CreditPayoffPreview(accountID: id, paymentAccountID: input.paymentAccountID, previewToken: token, previewExpiresAt: Date().addingTimeInterval(600), dataRevision: revision, paymentBalanceBeforeMinor: cash - 200000, paymentBalanceAfterMinor: try checkedSubtract(cash - 200000, input.actualAmountMinor), debtBeforeMinor: debt, debtAfterMinor: 0, actualAmountMinor: input.actualAmountMinor, principalMinor: debt, feeMinor: 0, additionalFeeMinor: input.additionalFeeMinor, waivedPrincipalMinor: input.waivedPrincipalMinor, waivedFeeMinor: input.waivedFeeMinor, allocations: [allocation(input)], closingInstallmentPlanIDs: [], warnings: ["合成数据：请核对银行实扣与减免。"], executable: debt > 0))
        }
        if path.hasSuffix("/payoff"), let body {
            let key = request.headers["Idempotency-Key"] ?? ""
            if let receipt = commits[key] { return try encode(records[receipt.operationID] ?? receipt) }
            let input = try V15BodyEncoder.decode(V15CreditPayoffCommitRequest.self, from: body)
            guard let original = previews[input.previewToken], debt > 0 else { throw V15Failure(kind: .conflict, message: "预览已失效，请重新核对。", isDefinitiveRejection: true) }
            revision += 1
            let receipt = V15CreditPayoffReceipt(operationID: UUID(), accountID: id, paymentAccountID: input.paymentAccountID, occurredAt: input.occurredAt, status: "completed", dataRevision: revision, actualAmountMinor: input.actualAmountMinor, debtBeforeMinor: debt, debtAfterMinor: 0, transactionIDs: [UUID()], allocations: [allocation(original)], reversedAt: nil)
            records[receipt.operationID] = receipt; commits[key] = receipt; debt = 0; cash = try checkedSubtract(cash, input.actualAmountMinor)
            if scenario == "v230-payoff-unknown" && !didLoseResponse { didLoseResponse = true; throw V15Failure(kind: .responseUnknown, message: "模拟响应丢失，原请求已保留。") }
            return try encode(receipt)
        }
        if path.hasPrefix("credit-payoffs/") {
            let parts = request.path.split(separator: "/"); guard parts.count >= 2, let operationID = UUID(uuidString: String(parts[1])), let original = records[operationID] else { throw V15Failure(kind: .transport, message: "没有此回执。") }
            if path.hasSuffix("/reverse-preview") { return try encode(V15CreditPayoffReversePreview(operationID: operationID, previewToken: UUID(), previewExpiresAt: Date().addingTimeInterval(600), dataRevision: revision, executable: original.status != "reversed", warnings: ["仅恢复记账，不执行银行退款。 "])) }
            if path.hasSuffix("/reverse") {
                let key = request.headers["Idempotency-Key"] ?? ""
                if let saved = commits[key] { return try encode(records[saved.operationID] ?? saved) }
                guard original.status != "reversed" else { throw V15Failure(kind: .conflict, code: "payoff_already_reversed", message: "此结清已撤销", isDefinitiveRejection: true) }
                let debtBeforeReverse = debt
                revision += 1; debt = original.debtBeforeMinor; cash += original.actualAmountMinor
                let reversed = V15CreditPayoffReceipt(operationID: operationID, accountID: id, paymentAccountID: original.paymentAccountID, occurredAt: original.occurredAt, status: "reversed", dataRevision: revision, actualAmountMinor: original.actualAmountMinor, debtBeforeMinor: debtBeforeReverse, debtAfterMinor: debt, transactionIDs: original.transactionIDs, allocations: original.allocations, reversedAt: Date())
                records[operationID] = reversed; commits[key] = reversed; return try encode(reversed)
            }
            return try encode(original)
        }
        if path == "transactions/repayment-preview", let body {
            let input = try V15BodyEncoder.decode(V15RepaymentPreviewRequest.self, from: body).draft
            guard input.amountMinor <= debt else { throw V15Failure(kind: .transport, code: "repayment_exceeds_cycle_remaining", message: V15RepaymentAmountMessage.exceeded(remaining: debt, input: input.amountMinor), fieldIssues: [.init(code: "repayment_exceeds_cycle_remaining", message: V15RepaymentAmountMessage.exceeded(remaining: debt, input: input.amountMinor), fieldPath: "amount_minor")], isDefinitiveRejection: true) }
            let token = UUID(); repaymentDrafts[token] = input
            return try decode(["meta": ["preview_token": token.uuidString, "action": "repayment", "data_revision": revision, "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(600))], "amount_minor": input.amountMinor, "payment_account_id": input.accountID!.uuidString, "payment_account_name": "日常现金", "payment_balance_before_minor": cash - 200000, "payment_balance_after_minor": cash - 200000 - input.amountMinor, "credit_account_id": id.uuidString, "credit_account_name": "随借随还示例", "credit_debt_before_minor": debt, "credit_debt_after_minor": debt - input.amountMinor, "credit_cycle_id": NSNull(), "cycle_remaining_before_minor": debt, "cycle_remaining_after_minor": debt - input.amountMinor])
        }
        if path == "transactions/repayment-commit", let body {
            let key = request.headers["Idempotency-Key"] ?? ""
            if let saved = actionResults[key] { return try V15FixtureCodec.decoder.decode(Response.self, from: saved) }
            let token = try V15BodyEncoder.decode(V15JournalRepayment.self, from: body).previewToken
            guard let draft = repaymentDrafts[token] else { throw V15Failure(kind: .conflict, message: "预览已失效。", isDefinitiveRejection: true) }
            let transaction = try createTransaction(draft)
            let result: [String: Any] = ["operation_id": UUID().uuidString, "preview_token": token.uuidString, "action": "repayment", "data_revision": revision, "result": transaction, "replay": false]
            let data = try JSONSerialization.data(withJSONObject: result); actionResults[key] = data
            return try V15FixtureCodec.decoder.decode(Response.self, from: data)
        }
        if path.hasPrefix("action-operations/"), let data = actionResults[String(request.path.split(separator: "/").last!)] { return try V15FixtureCodec.decoder.decode(Response.self, from: data) }
        if path == "transactions" && request.method == "POST", let body {
            let key = request.headers["Idempotency-Key"] ?? ""
            if let saved = transactionResults[key] { return try V15FixtureCodec.decoder.decode(Response.self, from: saved) }
            let draft = try V15BodyEncoder.decode(V15TransactionCreateRequest.self, from: body)
            let data = try JSONSerialization.data(withJSONObject: createTransaction(draft)); transactionResults[key] = data
            return try V15FixtureCodec.decoder.decode(Response.self, from: data)
        }
        if path == "cash-flow-items" {
            let remaining = closedRemainder ? 0 : max(30000 - settledAmount, 0)
            let today = ShanghaiBusinessDate.string(for: Date())
            return try decode(["summary": ["date_from": today, "date_to": today, "inflow_minor": 0, "outflow_minor": remaining, "net_minor": -remaining], "items": remaining > 0 ? [cashFlowObject()] : []])
        }
        if path == "cash-flow-items/history" { return try decode(["month": String(ShanghaiBusinessDate.string(for: Date()).prefix(7)), "items": closedRemainder || settledAmount >= 30000 ? [cashFlowObject()] : []]) }
        if path.hasPrefix("cash-flow-items/") {
            if path.hasSuffix("/settle") || path.hasSuffix("/settle-existing") {
                let key = request.headers["Idempotency-Key"] ?? ""
                if !cashFlowKeys.contains(key), let body {
                    if path.hasSuffix("/settle-existing") {
                        let input = try V15BodyEncoder.decode(V15CashFlowSettleExistingRequest.self, from: body)
                        guard !settlementIDs.contains(input.transactionID.uuidString) else { throw V15Failure(kind: .conflict, message: "这笔账目已关联。", isDefinitiveRejection: true) }
                        settlementIDs.append(input.transactionID.uuidString); settledAmount += 1280; closedRemainder = input.completeRemaining
                    } else {
                        let input = try V15BodyEncoder.decode(V15CashFlowSettlementDraft.self, from: body)
                        settledAmount = try checkedAdd(settledAmount, input.actualAmountMinor); closedRemainder = input.completeRemaining ?? true; settlementIDs.append(UUID().uuidString); cash = try checkedSubtract(cash, input.actualAmountMinor)
                    }
                    cashFlowKeys.insert(key); cashFlowVersion += 1; revision += 1
                }
            }
            return try decode(cashFlowObject())
        }
        if path == "transactions" {
            if scenario == "v230-many-accounts", let selected = request.query.first(where: { $0.name == "account_id" })?.value,
               try overflowAccounts().contains(where: { ($0["id"] as? String)?.lowercased() == selected.lowercased() }) {
                return try decode(["items": [], "next_cursor": NSNull()])
            }
            let transaction = try JSONSerialization.jsonObject(with: V15F1AFixtures.transaction)
            return try decode(["items": [transaction], "next_cursor": NSNull()])
        }
        if path == "reports/facts" {
            var value = try JSONSerialization.jsonObject(with: V15F2BFixtures.rootWorkspaceFacts) as! [String: Any]
            let today = ShanghaiBusinessDate.string(for: Date()); var calendar = Calendar(identifier: .gregorian); calendar.timeZone = ShanghaiBusinessDate.timeZone
            let end = ShanghaiBusinessDate.string(for: calendar.date(byAdding: .day, value: 29, to: Date())!)
            var cashFacts = value["cash"] as! [String: Any]; cashFacts["current_balance_minor"] = cash; value["cash"] = cashFacts
            var creditFacts = value["credit"] as! [String: Any]; creditFacts["current_debt_minor"] = debt; value["credit"] = creditFacts
            value["disposable"] = ["date_from": today, "date_to": end, "current_cash_minor": cash, "expected_inflow_minor": 250000, "expected_outflow_minor": (closedRemainder ? 0 : max(30000 - settledAmount, 0)), "projected_balance_minor": cash + 250000 - (closedRemainder ? 0 : max(30000 - settledAmount, 0)), "undated_inflow_minor": 10000, "unscheduled_credit_debt_minor": debt, "overdue_outflow_minor": 0] as [String: Any]
            var meta = value["meta"] as! [String: Any]; meta["data_revision"] = revision; value["meta"] = meta
            return try decode(value)
        }
        if path == "reports/future-events" {
            let today = ShanghaiBusinessDate.string(for: Date())
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = ShanghaiBusinessDate.timeZone
            let end = ShanghaiBusinessDate.string(for: calendar.date(byAdding: .day, value: 29, to: Date())!)
            let items: [[String: Any]] = [("工资到账", "inflow", 250000), ("租金", "outflow", closedRemainder ? 0 : max(30000 - settledAmount, 0))].map { title, direction, amount in ["source_type": "cash_flow_item", "source_id": UUID().uuidString, "date": today, "direction": direction, "amount_minor": amount, "certainty": "expected", "title": title, "deep_link": "fiscal://cash-flow", "account_id": V15F1AFixtures.accountID.uuidString] }
            return try decode(["meta": ["timezone": "Asia/Shanghai", "currency": "CNY", "as_of": ISO8601DateFormatter().string(from: Date()), "data_revision": revision, "schema_version": "1"], "window": ["date_from": today, "date_to": end], "account_id": NSNull(), "items": items, "next_cursor": NSNull()])
        }
        return try await fallback.send(request, body: body)
    }
    private func createTransaction(_ draft: V15TransactionCreateRequest) throws -> [String: Any] {
        var value = try JSONSerialization.jsonObject(with: V15F1AFixtures.transaction) as! [String: Any]
        let fields = try JSONSerialization.jsonObject(with: V15BodyEncoder.data(draft)) as! [String: Any]
        for (key, field) in fields { value[key] = field }
        value["id"] = UUID().uuidString; value["category_id"] = draft.categoryID?.uuidString as Any? ?? NSNull(); value["credit_cycle_id"] = draft.creditCycleID?.uuidString as Any? ?? NSNull(); value["business_date"] = ShanghaiBusinessDate.string(for: draft.occurredAt)
        if draft.kind == .borrowing { debt = try checkedAdd(debt, draft.amountMinor); cash = try checkedAdd(cash, draft.amountMinor) }
        if draft.kind == .repayment { debt = try checkedSubtract(debt, draft.amountMinor); cash = try checkedSubtract(cash, draft.amountMinor) }
        let sourceSign: Int64 = -draft.amountMinor
        var postings: [[String: Any]] = [["id": UUID().uuidString, "account_id": draft.accountID!.uuidString, "role": "account", "amount_minor": sourceSign, "position": 0]]
        if let destination = draft.destinationAccountID { postings.append(["id": UUID().uuidString, "account_id": destination.uuidString, "role": "destination", "amount_minor": draft.amountMinor, "position": 1]) }
        value["postings"] = postings; revision += 1
        return value
    }
    private func checkedAdd(_ left: Int64, _ right: Int64) throws -> Int64 { let (value, overflow) = left.addingReportingOverflow(right); guard !overflow else { throw V15Failure(kind: .transport, message: "金额超出范围。", isDefinitiveRejection: true) }; return value }
    private func checkedSubtract(_ left: Int64, _ right: Int64) throws -> Int64 { let (value, overflow) = left.subtractingReportingOverflow(right); guard !overflow else { throw V15Failure(kind: .transport, message: "金额超出范围。", isDefinitiveRejection: true) }; return value }
    private func cashFlowObject() -> [String: Any] {
        ["id": V15F3DFixtures.itemID.uuidString, "manual_item_id": V15F3DFixtures.itemID.uuidString, "system_kind": NSNull(), "system_reference_id": NSNull(), "series_id": NSNull(), "title": "租金示例", "note": NSNull(), "direction": "outflow", "planned_amount_minor": 30000, "expected_date": ShanghaiBusinessDate.string(for: Date()), "account_id": V15F1AFixtures.accountID.uuidString, "destination_account_id": NSNull(), "category_id": NSNull(), "status": closedRemainder || settledAmount >= 30000 ? "settled" : "confirmed", "source": "manual", "version": cashFlowVersion, "linked_transaction_id": settlementIDs.last as Any? ?? NSNull(), "actual_amount_minor": settledAmount, "actual_date": NSNull(), "is_overdue": false, "actions": closedRemainder || settledAmount >= 30000 ? [] : ["settle", "edit", "cancel"], "credit_cycle_parts": [], "created_at": NSNull(), "updated_at": NSNull(), "settled_amount_minor": settledAmount, "remaining_amount_minor": closedRemainder ? 0 : max(30000 - settledAmount, 0), "settlement_transaction_ids": settlementIDs]
    }
    private func allocation(_ input: V15CreditPayoffRequest) -> V15CreditPayoffAllocation { .init(cycleID: nil, remainingMinor: debt, principalMinor: debt, feeMinor: 0, repaidMinor: debt - input.waivedPrincipalMinor, waivedPrincipalMinor: input.waivedPrincipalMinor, waivedFeeMinor: 0, installmentPlanIDs: []) }
    /// Zero-balance accounts exercise layout overflow without changing any financial totals.
    private func overflowAccounts() throws -> [[String: Any]] {
        guard scenario == "v230-many-accounts" else { return [] }
        let template = (try JSONSerialization.jsonObject(with: V15F1AFixtures.accounts) as! [[String: Any]])[0]
        return (1...20).map { index in
            var account = template
            account["id"] = String(format: "00000000-0000-0000-0000-%012d", 2400 + index)
            account["name"] = String(format: "零余额示例账户 %02d", index)
            account["opening_balance_minor"] = 0
            account["current_balance_minor"] = 0
            account["usage_count"] = 0
            account["sort_order"] = index + 3
            return account
        }
    }
    private func accountObject() throws -> [String: Any] {
        var value = (try JSONSerialization.jsonObject(with: V15F1AFixtures.accounts) as! [[String: Any]])[2]
        value["id"] = V230Fixtures.accountID.uuidString; value["name"] = "随借随还示例"; value["current_balance_minor"] = debt; value["cycle_mode"] = "on_demand"
        for key in ["credit_limit_minor", "statement_day", "due_day"] { value[key] = NSNull() }
        return value
    }
    private func summaryObject() -> [String: Any] { ["account_id": V230Fixtures.accountID.uuidString, "name": "随借随还示例", "institution": NSNull(), "last_four": NSNull(), "credit_limit_minor": NSNull(), "current_debt_minor": debt, "available_credit_minor": NSNull(), "over_limit_minor": NSNull(), "opening_configuration_required": false, "statement_day": NSNull(), "due_day": NSNull(), "cycle_mode": "on_demand", "current_cycle": NSNull(), "next_due_cycle": NSNull(), "has_overdue_cycle": false, "active_installment_count": 0, "future_scheduled_gross_minor": 0, "next_installment": NSNull()] }
    private func decode<T: Decodable>(_ object: Any) throws -> T { try V15FixtureCodec.decoder.decode(T.self, from: JSONSerialization.data(withJSONObject: object)) }
    private func encode<T: Encodable, R: Decodable>(_ value: T) throws -> R { try V15FixtureCodec.decoder.decode(R.self, from: V15FixtureCodec.encoder.encode(value)) }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { try await fallback.fetchArtifact(request, accept: accept) }
}
