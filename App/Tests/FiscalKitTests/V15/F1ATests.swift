import Foundation
import Testing

@testable import FiscalKit

@Suite("F1-A clean-room contracts and record model")
struct F1ATests {
    @Test("session, readiness, master-data, cycle read and create preserve exact backend paths")
    @MainActor func routesAndJSON() async throws {
        let transport = F1AControlledTransport()
        let services = V15Services(transport: transport)
        _ = try await services.session.unlock(passphrase: "12345678")
        #expect((await transport.lastRequest())?.path == "auth/session")
        #expect((await transport.lastRequest())?.method == "POST")
        _ = try await services.system.status()
        #expect((await transport.lastRequest())?.path == "system/status")
        _ = try await services.masterData.activeAccounts()
        #expect((await transport.lastRequest())?.query == [.init(name: "include_archived", value: "false")])
        _ = try await services.creditCycles.list(accountID: V15F1AFixtures.creditID)
        let cycleRequest = try #require(await transport.lastRequest())
        #expect(cycleRequest.path == "credit-accounts/\(V15F1AFixtures.creditID)/cycles")
        #expect(cycleRequest.query == [.init(name: "limit", value: "100")])
        let request = V15TransactionCreateRequest(kind: .expense, amountMinor: 1280, occurredAt: Date(timeIntervalSince1970: 0), title: "午餐", accountID: V15F1AFixtures.accountID)
        _ = try await services.ledger.create(request, idempotencyKey: UUID(uuidString: "00000000-0000-0000-0000-000000000999")!)
        let sent = try #require(await transport.lastRequest())
        #expect(sent.path == "transactions" && sent.method == "POST")
        #expect(sent.headers["Idempotency-Key"] == "00000000-0000-0000-0000-000000000999")
        let encoded = try V15FixtureCodec.encoder.encode(request)
        let wire = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(wire?["amount_minor"] as? Int == 1280)
        #expect(wire?["account_id"] as? String == V15F1AFixtures.accountID.uuidString)
    }

    @Test("CNY conversion, overflow and Shanghai day instant are deterministic")
    @MainActor func moneyAndDate() async {
        #expect(CNYAmountParser.minorUnits("12.80") == 1280)
        #expect(CNYAmountParser.minorUnits("12.801") == nil)
        #expect(CNYAmountParser.minorUnits("92233720368547759") == nil)
        let model = V15RecordModel(services: V15Services(transport: F1AControlledTransport()))
        model.title = "月末"; model.amountText = "1.00"
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = ShanghaiBusinessDate.timeZone
        model.occurredOn = calendar.date(from: .init(timeZone: ShanghaiBusinessDate.timeZone, year: 2026, month: 8, day: 31, hour: 23))!
        await model.loadReferences()
        model.accountID = V15F1AFixtures.accountID
        await model.submit()
        guard case .success(let transaction) = model.submission else { Issue.record("expected create success"); return }
        #expect(transaction.businessDate == "2026-08-15") // authoritative fixture response, not locally fabricated date
    }

    @Test("kind transitions clear every incompatible reference and reload direction-correct categories")
    @MainActor func transitionsAndValidation() async {
        let model = V15RecordModel(services: V15Services(transport: F1AControlledTransport()))
        await model.loadReferences()
        model.title = "测试"; model.amountText = "3.00"; model.accountID = V15F1AFixtures.creditID; model.categoryID = V15F1AFixtures.categoryID
        model.kind = .creditPurchase
        #expect(model.categoryID == nil && model.destinationAccountID == nil && model.creditCycleID == nil)
        model.categoryID = V15F1AFixtures.categoryID
        model.kind = .expense
        #expect(model.categoryID == nil && model.accountID == nil)
        #expect(model.localIssues.contains { $0.code == "cash_or_debit_account_required" })
        model.accountID = V15F1AFixtures.accountID
        model.kind = .income
        #expect(model.accountID == V15F1AFixtures.accountID) // cash/debit is legal across income/expense
        await model.loadCategories()
        await Task.yield(); await Task.yield()
        #expect(model.categoryPhase == .loaded)
        #expect(model.categories.map(\.id) == [V15F1AFixtures.incomeCategoryID])
        model.categoryID = V15F1AFixtures.incomeCategoryID
        #expect(!model.localIssues.contains { $0.code == "category_unavailable" })
        model.kind = .transfer
        #expect(model.categoryID == nil && model.creditCycleID == nil)
        model.accountID = V15F1AFixtures.accountID; model.destinationAccountID = V15F1AFixtures.accountID
        #expect(model.localIssues.contains { $0.code == "transfer_same_account" })
        model.destinationAccountID = V15F1AFixtures.debitID
        #expect(!model.localIssues.contains { $0.code == "transfer_same_account" })
        model.kind = .repayment
        model.destinationAccountID = V15F1AFixtures.creditID
        await model.loadCreditCycles()
        await Task.yield(); await Task.yield()
        #expect(model.creditCyclePhase == .loaded)
        #expect(model.creditCycles.map(\.id) == [V15F1AFixtures.creditCycleID])
        model.creditCycleID = V15F1AFixtures.creditCycleID
        #expect(!model.localIssues.contains { $0.code == "credit_cycle_required" })
        model.kind = .transfer
        #expect(model.destinationAccountID == nil) // credit target cannot survive repayment → transfer
    }

    @Test("credit-cycle loads cannot overwrite a newer kind, destination, or cancellation")
    @MainActor func creditCycleRaces() async {
        for outcome in [F1ACycleRaceTransport.Outcome.success, .failure, .cancellation] {
            let model = V15RecordModel(services: V15Services(transport: F1ACycleRaceTransport(outcome: outcome)))
            await model.loadReferences()
            model.kind = .repayment
            model.accountID = V15F1AFixtures.accountID
            model.destinationAccountID = V15F1AFixtures.creditID
            let pending = Task { await model.loadCreditCycles() }
            await Task.yield()
            model.kind = .expense
            if outcome == .cancellation { pending.cancel() }
            await pending.value
            #expect(model.creditCycles.isEmpty)
            #expect(model.creditCyclePhase == .idle)
            #expect(model.creditCycleID == nil)
        }
    }

    @Test("response-unknown retains only its payload key; edits and deterministic outcomes rotate it")
    @MainActor func payloadBoundIdempotency() async throws {
        let outcomes: [F1AControlledTransport.CreateOutcome] = [.responseUnknown, .success, .responseUnknown, .success, .validation, .success, .conflict, .success, .success, .success]
        let transport = F1AControlledTransport(outcomes: outcomes)
        let model = V15RecordModel(services: V15Services(transport: transport))
        await model.loadReferences()
        configureValidExpense(model)

        await model.submit(); let unknownKey = try #require(await transport.createKeys().last)
        await model.submit(); let retryKey = try #require(await transport.createKeys().last)
        #expect(unknownKey == retryKey)

        model.title = "编辑后新请求"
        await model.submit(); let editedUnknownKey = try #require(await transport.createKeys().last)
        #expect(editedUnknownKey != unknownKey)
        await model.submit(); let editedRetryKey = try #require(await transport.createKeys().last)
        #expect(editedRetryKey == editedUnknownKey)

        model.title = "422 后新请求"
        await model.submit(); let validationKey = try #require(await transport.createKeys().last)
        await model.submit(); let validationRetryKey = try #require(await transport.createKeys().last)
        #expect(validationRetryKey != validationKey)

        model.title = "409 后新请求"
        await model.submit(); let conflictKey = try #require(await transport.createKeys().last)
        await model.submit(); let conflictRetryKey = try #require(await transport.createKeys().last)
        #expect(conflictRetryKey != conflictKey)

        model.title = "成功后下一笔"
        await model.submit(); let successKey = try #require(await transport.createKeys().last)
        model.newEntry(); configureValidExpense(model, title: "下一笔")
        await model.submit(); let nextKey = try #require(await transport.createKeys().last)
        #expect(nextKey != successKey)
    }
}

@MainActor private func configureValidExpense(_ model: V15RecordModel, title: String = "午餐") {
    model.kind = .expense; model.title = title; model.amountText = "12.80"; model.accountID = V15F1AFixtures.accountID; model.categoryID = V15F1AFixtures.categoryID
}

actor F1AControlledTransport: V15Transporting {
    enum CreateOutcome: Sendable { case responseUnknown, validation, conflict, success }
    private var outcomes: [CreateOutcome]
    private var requests: [V15Request] = []
    private var transactionKeys: [String] = []

    init(outcomes: [CreateOutcome] = []) { self.outcomes = outcomes }

    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        requests.append(request)
        if request.path == "transactions" {
            transactionKeys.append(request.headers["Idempotency-Key"] ?? "")
            switch outcomes.isEmpty ? .success : outcomes.removeFirst() {
            case .responseUnknown: throw V15Failure(kind: .responseUnknown, code: "response_unknown", message: "unknown")
            case .validation: throw V15Failure(kind: .transport, code: "validation_failed", message: "invalid", fieldIssues: [.init(code: "invalid", message: "invalid", fieldPath: "title")])
            case .conflict: throw V15Failure(kind: .conflict, code: "version_conflict", message: "conflict", conflict: .init(reloadPath: "/api/v1/transactions/x", latestRevision: 2, message: "conflict"))
            case .success: return try decode(V15F1AFixtures.transaction)
            }
        }
        switch request.path {
        case "auth/session": return try decode(V15F1AFixtures.session)
        case "system/status": return try decode(V15F1AFixtures.system)
        case "accounts": return try decode(V15F1AFixtures.accounts)
        case "categories": return try decode(request.query.first(where: { $0.name == "direction" })?.value == "income" ? V15F1AFixtures.incomeCategories : V15F1AFixtures.categories)
        case "credit-accounts/\(V15F1AFixtures.creditID)/cycles": return try decode(V15F1AFixtures.creditCycles)
        default: throw V15Failure(kind: .transport, message: "fixture")
        }
    }

    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { Data() }
    func lastRequest() -> V15Request? { requests.last }
    func createKeys() -> [String] { transactionKeys }
    private func decode<Response: Decodable>(_ data: Data) throws -> Response { try V15FixtureCodec.decoder.decode(Response.self, from: data) }
}

actor F1ACycleRaceTransport: V15Transporting {
    enum Outcome: Sendable, Equatable { case success, failure, cancellation }
    private let outcome: Outcome

    init(outcome: Outcome) { self.outcome = outcome }

    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        if request.path == "credit-accounts/\(V15F1AFixtures.creditID)/cycles" {
            try await Task.sleep(for: .milliseconds(80))
            if outcome == .failure { throw V15Failure(kind: .transport, code: "cycle_read_failed", message: "账期读取失败") }
            return try decode(V15F1AFixtures.creditCycles)
        }
        switch request.path {
        case "accounts": return try decode(V15F1AFixtures.accounts)
        case "categories": return try decode(V15F1AFixtures.categories)
        default: throw V15Failure(kind: .transport, message: "fixture")
        }
    }

    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { Data() }
    private func decode<Response: Decodable>(_ data: Data) throws -> Response { try V15FixtureCodec.decoder.decode(Response.self, from: data) }
}
