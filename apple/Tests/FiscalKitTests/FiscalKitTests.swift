import Foundation
import Testing
@testable import FiscalKit

@Suite("FiscalKit P1")
struct FiscalKitTests {
    @Test("Money uses integer minor units")
    func moneyDecimal() {
        #expect(Money(minorUnits: 12_345).decimal == Decimal(string: "123.45"))
    }

    @Test("Overview derives cash net")
    func derivesCashNet() {
        #expect(OverviewSnapshot.sample.cashNet.minorUnits == 368_670)
    }

    @Test("All required presentation states are available")
    func presentationStates() {
        #expect(Set(OverviewFixture.allCases.map(\.rawValue)) == Set(["normal", "empty", "loading", "offline", "unauthorized", "longContent"]))
    }

    @Test("System status decodes the backend contract")
    func systemStatusContract() throws {
        let data = Data(#"{"service":"fiscal-api","version":"0.1.0","environment":"test","status":"operational","database":"ready","currency":"CNY","business_timezone":"Asia/Shanghai","timestamp":"2026-07-14T08:00:00Z"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let status = try decoder.decode(SystemStatus.self, from: data)
        #expect(status.status == "operational")
        #expect(status.businessTimezone == "Asia/Shanghai")
    }
}

@Suite("FiscalKit P2 contracts")
struct FiscalKitP2Tests {
    @Test("Account draft uses snake case and excludes ordering")
    func accountPayload() throws {
        var draft = AccountDraft(); draft.name = "招行信用卡"; draft.kind = .credit; draft.openingBalanceMinor = 6_842_30
        draft.creditLimitMinor = 50_000_00; draft.statementDay = 10; draft.dueDay = 22
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        #expect(object["opening_balance_minor"] as? Int == 6_842_30)
        #expect(object["credit_limit_minor"] as? Int == 50_000_00)
        #expect(object["sort_order"] == nil)
        var emptyOptional = AccountDraft(); emptyOptional.name = "现金"; emptyOptional.kind = .cash
        let emptyObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(emptyOptional)) as? [String: Any])
        #expect(emptyObject["institution"] is NSNull)
        #expect(emptyObject["last_four"] is NSNull)
    }

    @Test("Optimistic update sends expected_version")
    func optimisticPayload() throws {
        var draft = AccountDraft(); draft.name = "现金"; draft.kind = .cash
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(VersionedAccountDraft(version: 7, draft: draft))) as? [String: Any])
        #expect(object["expected_version"] as? Int == 7)
        #expect(object["version"] == nil)
    }

    @Test("Category local validation enforces color and duplicates") @MainActor
    func categoryValidation() {
        var draft = CategoryDraft(); draft.name = "餐饮"; draft.colorHex = "orange"
        #expect(CategoriesModel.validate(draft) != nil)
        draft.colorHex = "#C0784A"; draft.aliases = ["午饭", "午饭"]
        #expect(CategoriesModel.validate(draft) == "别名和示例不能重复。")
    }

    @Test("API error envelope decodes stable code")
    func errorEnvelope() throws {
        let data = Data(#"{"error":{"code":"resource_version_conflict","message":"stale","details":null,"request_id":"req-1"}}"#.utf8)
        let envelope = try JSONDecoder().decode(APIErrorEnvelope.self, from: data)
        #expect(envelope.error.code == "resource_version_conflict")
    }

    @Test("CNY parser accepts exact cents and rejects truncation or overflow")
    func exactMinorUnits() {
        #expect(CNYAmountParser.minorUnits("123.45") == 12_345)
        #expect(CNYAmountParser.minorUnits("-0.01") == -1)
        #expect(CNYAmountParser.minorUnits("1.234") == nil)
        #expect(CNYAmountParser.minorUnits("999999999999999999999") == nil)
    }
}

@Suite("FiscalKit P3 contracts")
struct FiscalKitP3Tests {
    @Test("Transfer payload uses account_id as source and no source alias")
    func transferPayload() throws {
        let source = UUID(), destination = UUID()
        var draft = TransactionDraft(); draft.kind = .transfer; draft.amountMinor = 1_280
        draft.occurredAt = Date(timeIntervalSince1970: 0); draft.title = "转入储蓄"; draft.note = "  "
        draft.accountID = source; draft.destinationAccountID = destination
        let object = try #require(JSONSerialization.jsonObject(with: encoded(draft)) as? [String: Any])
        #expect(object["account_id"] as? String == source.uuidString)
        #expect(object["destination_account_id"] as? String == destination.uuidString)
        #expect(object["source_account_id"] == nil)
        #expect(object["category_id"] is NSNull)
        #expect(object["note"] is NSNull)
        #expect(Set(object.keys) == Set(["kind", "amount_minor", "occurred_at", "title", "note", "account_id", "destination_account_id", "category_id", "credit_cycle_id"]))
    }

    @Test("Versioned update is a full semantic replacement")
    func updatePayload() throws {
        var draft = TransactionDraft(); draft.kind = .expense; draft.amountMinor = 500; draft.title = "咖啡"
        draft.accountID = UUID(); draft.categoryID = UUID()
        let object = try #require(JSONSerialization.jsonObject(with: encoded(VersionedTransactionDraft(draft: draft, expectedVersion: 7))) as? [String: Any])
        #expect(object["expected_version"] as? Int == 7)
        #expect(object["amount_minor"] as? Int == 500)
        #expect(object["source"] == nil)
    }

    @Test("Canonical response decodes account impacts without internal transaction IDs")
    func responsePayload() throws {
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","kind":"expense","amount_minor":1280,"occurred_at":"2026-07-15T12:00:00Z","business_date":"2026-07-15","title":"午餐","note":null,"category_id":"00000000-0000-0000-0000-000000000002","account_id":"00000000-0000-0000-0000-000000000003","destination_account_id":null,"source":"manual","postings":[{"id":"00000000-0000-0000-0000-000000000004","account_id":"00000000-0000-0000-0000-000000000003","role":"account","amount_minor":-1280,"position":0}],"version":1,"voided_at":null,"created_at":"2026-07-15T12:00:00Z","updated_at":"2026-07-15T12:00:00Z"}"#.utf8)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let transaction = try decoder.decode(TransactionDTO.self, from: data)
        #expect(transaction.businessDate == "2026-07-15")
        #expect(transaction.postings.first?.amountMinor == -1_280)
    }

    @Test("Editor validates all three semantic shapes") @MainActor
    func semanticValidation() {
        var draft = TransactionDraft(); draft.title = "午餐"; draft.amountMinor = 1
        #expect(TransactionEditorModel.validate(draft) != nil)
        draft.accountID = UUID(); draft.categoryID = UUID()
        #expect(TransactionEditorModel.validate(draft) == nil)
        draft.kind = .transfer; draft.categoryID = nil; draft.destinationAccountID = draft.accountID
        #expect(TransactionEditorModel.validate(draft) == "转出和转入账户不能相同。")
        draft.destinationAccountID = UUID()
        #expect(TransactionEditorModel.validate(draft) == nil)
    }

    @Test("Create key is retained only for ambiguous failures") @MainActor
    func idempotencyDisposition() {
        #expect(TransactionsModel.shouldPreserveCreateKey(after: FiscalAPIError.transport("offline")))
        #expect(TransactionsModel.shouldPreserveCreateKey(after: FiscalAPIError.invalidResponse))
        let detail = APIErrorDetail(code: "idempotency_key_reused", message: "reused", details: nil, requestID: "req")
        #expect(!TransactionsModel.shouldPreserveCreateKey(after: FiscalAPIError.domain(status: 409, detail: detail)))
    }

    @Test("A cancelled old search cannot replace the current query") @MainActor
    func staleSearchIsIgnored() async throws {
        let model = TransactionsModel(repository: RaceTransactionRepository())
        model.search = "old"
        let old = Task { await model.load() }
        try await Task.sleep(for: .milliseconds(10))
        model.search = "new"; await model.load(); await old.value
        #expect(model.transactions.map(\.title) == ["new"])
    }

    @Test("Pagination is bound to its filter and cursor snapshot") @MainActor
    func stalePageIsIgnored() async throws {
        let model = TransactionsModel(repository: RaceTransactionRepository())
        await model.load()
        let last = try #require(model.transactions.last)
        let more = Task { await model.loadMoreIfNeeded(after: last) }
        try await Task.sleep(for: .milliseconds(10))
        model.kind = .expense; await model.load(); await more.value
        #expect(model.transactions.map(\.title) == ["expense"])
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return try encoder.encode(value)
    }
}

@Suite("FiscalKit P4 contracts")
struct FiscalKitP4Tests {
    @Test("Credit cycle and account summary decode the frozen schema")
    func creditResponsePayload() throws {
        let cycle = #"{"id":"00000000-0000-0000-0000-000000000010","account_id":"00000000-0000-0000-0000-000000000011","period_start":"2026-06-11","period_end":"2026-07-10","statement_date":"2026-07-10","due_date":"2026-07-22","is_opening_cycle":false,"purchase_minor":50000,"opening_minor":0,"amount_due_minor":50000,"repaid_minor":12000,"remaining_minor":38000,"status":"partial","is_overdue":false,"version":2,"created_at":"2026-07-10T00:00:00Z","updated_at":"2026-07-15T00:00:00Z"}"#
        let json = #"{"account_id":"00000000-0000-0000-0000-000000000011","name":"信用卡","institution":"银行","last_four":"1234","credit_limit_minor":1000000,"current_debt_minor":38000,"available_credit_minor":962000,"over_limit_minor":0,"opening_configuration_required":false,"statement_day":10,"due_day":22,"current_cycle":"# + cycle + #", "next_due_cycle":"# + cycle + #", "has_overdue_cycle":false}"#
        let data = Data(json.utf8)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let summary = try decoder.decode(CreditAccountSummaryDTO.self, from: data)
        #expect(summary.currentCycle?.amountDueMinor == 50_000)
        #expect(summary.nextDueCycle?.status == .partial)
        #expect(summary.availableCreditMinor == 962_000)
        #expect(summary.overLimitMinor == 0)
    }

    @Test("Credit purchase and repayment use exact transaction fields")
    func creditTransactionPayloads() throws {
        let creditAccount = UUID(), category = UUID(), paymentAccount = UUID(), cycle = UUID()
        var purchase = TransactionDraft(); purchase.kind = .creditPurchase; purchase.amountMinor = 12_345; purchase.title = "消费"; purchase.accountID = creditAccount; purchase.categoryID = category
        var repayment = TransactionDraft(); repayment.kind = .repayment; repayment.amountMinor = 5_000; repayment.title = "还款"; repayment.accountID = paymentAccount; repayment.destinationAccountID = creditAccount; repayment.creditCycleID = cycle
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let purchaseJSON = try #require(JSONSerialization.jsonObject(with: encoder.encode(purchase)) as? [String: Any])
        let repaymentJSON = try #require(JSONSerialization.jsonObject(with: encoder.encode(repayment)) as? [String: Any])
        #expect(purchaseJSON["credit_cycle_id"] is NSNull)
        #expect(purchaseJSON["account_id"] as? String == creditAccount.uuidString)
        #expect(repaymentJSON["category_id"] is NSNull)
        #expect(repaymentJSON["credit_cycle_id"] as? String == cycle.uuidString)
    }

    @Test("Credit opening debt requires valid explicit dates") @MainActor
    func openingDebtValidation() {
        var draft = AccountDraft(); draft.name = "信用卡"; draft.kind = .credit; draft.creditLimitMinor = 100_000; draft.statementDay = 10; draft.dueDay = 22; draft.openingBalanceMinor = 5_000
        #expect(AccountsModel.validate(draft) == "正数期初欠款需要确认余额日期和到期日。")
        draft.openingBalanceAsOfDate = "2026-07-10"; draft.openingDueDate = "2026-07-09"
        #expect(AccountsModel.validate(draft) == "期初到期日不能早于余额日期。")
        draft.openingDueDate = "2026-07-22"
        #expect(AccountsModel.validate(draft) == nil)
    }

    @Test("Credit dashboard aggregation reports Int64 overflow")
    func creditDashboardOverflow() {
        let now = Date(timeIntervalSince1970: 0)
        let first = AccountDTO(id: UUID(), name: "A", kind: .cash, institution: nil, lastFour: nil, openingBalanceMinor: 0, currentBalanceMinor: .max, openingBalanceAsOfDate: nil, openingDueDate: nil, creditLimitMinor: nil, statementDay: nil, dueDay: nil, sortOrder: 0, archivedAt: nil, usageCount: 0, version: 1, createdAt: now, updatedAt: now)
        let second = AccountDTO(id: UUID(), name: "B", kind: .debit, institution: nil, lastFour: nil, openingBalanceMinor: 0, currentBalanceMinor: 1, openingBalanceAsOfDate: nil, openingDueDate: nil, creditLimitMinor: nil, statementDay: nil, dueDay: nil, sortOrder: 1, archivedAt: nil, usageCount: 0, version: 1, createdAt: now, updatedAt: now)
        #expect(CreditDashboardTotals.checked(accounts: [first, second], credit: []) == nil)
    }

    @Test("Editing a settled repayment retains its canonical cycle") @MainActor
    func settledRepaymentCycleRetention() async throws {
        let cycle = CreditCycleDTO(id: UUID(), accountID: UUID(), periodStart: "2026-06-11", periodEnd: "2026-07-10", statementDate: "2026-07-10", dueDate: "2026-07-22", isOpeningCycle: false, purchaseMinor: 5_000, openingMinor: 0, amountDueMinor: 5_000, repaidMinor: 5_000, remainingMinor: 0, status: .settled, isOverdue: false, version: 1, createdAt: Date(), updatedAt: Date())
        let model = CreditModel(repository: SettledCycleRepository(cycle: cycle))
        #expect(try await model.cyclesForRepayment(accountID: cycle.accountID).isEmpty)
        #expect(try await model.cyclesForRepayment(accountID: cycle.accountID, retaining: cycle.id).map(\.id) == [cycle.id])
    }
}

private actor SettledCycleRepository: CreditRepository {
    let value: CreditCycleDTO
    init(cycle: CreditCycleDTO) { value = cycle }
    func listAccounts() async throws -> [CreditAccountSummaryDTO] { [] }
    func account(id: UUID) async throws -> CreditAccountSummaryDTO { throw RaceRepositoryError.unsupported }
    func cycles(accountID: UUID, cursor: String?, limit: Int) async throws -> CreditCyclePage { .init(items: [value], nextCursor: nil) }
    func cycle(id: UUID) async throws -> CreditCycleDTO { value }
    func transactions(cycleID: UUID, cursor: String?, limit: Int) async throws -> TransactionPage { .init(items: [], nextCursor: nil) }
}

private enum RaceRepositoryError: Error { case unsupported }
private actor RaceTransactionRepository: TransactionRepository {
    func list(_ query: TransactionQuery) async throws -> TransactionPage {
        if query.cursor != nil { try? await Task.sleep(for: .milliseconds(120)); return .init(items: [item("stale-more", .income)], nextCursor: nil) }
        if query.search == "old" { try? await Task.sleep(for: .milliseconds(100)); return .init(items: [item("old", .income)], nextCursor: nil) }
        if query.search == "new" { return .init(items: [item("new", .income)], nextCursor: nil) }
        if query.kind == .expense { return .init(items: [item("expense", .expense)], nextCursor: nil) }
        return .init(items: [item("first", .income)], nextCursor: "next")
    }
    func get(id: UUID) async throws -> TransactionDTO { throw RaceRepositoryError.unsupported }
    func create(_ draft: TransactionDraft, idempotencyKey: UUID) async throws -> TransactionDTO { throw RaceRepositoryError.unsupported }
    func update(id: UUID, version: Int, draft: TransactionDraft) async throws -> TransactionDTO { throw RaceRepositoryError.unsupported }
    func void(_ transaction: TransactionDTO) async throws -> TransactionDTO { throw RaceRepositoryError.unsupported }
    func restore(_ transaction: TransactionDTO) async throws -> TransactionDTO { throw RaceRepositoryError.unsupported }

    private func item(_ title: String, _ kind: TransactionKind) -> TransactionDTO {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return TransactionDTO(id: UUID(), kind: kind, occurredAt: now, businessDate: "2026-07-15", title: title, note: nil, amountMinor: 100, categoryID: nil, accountID: nil, destinationAccountID: nil, creditCycleID: nil, source: "manual", postings: [], version: 1, voidedAt: nil, createdAt: now, updatedAt: now)
    }
}
