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

    @Test("system, passphrase, provider, and quality facts use their exact backend contracts")
    @MainActor func settingsAndSystemRoutes() async throws {
        let transport = F1AControlledTransport()
        let services = V15Services(transport: transport)

        let session = try await services.session.changePassphrase(oldPassphrase: "old-passphrase", newPassphrase: "new-passphrase")
        #expect(session.credentialGeneration == 3)
        #expect((await transport.lastRequest())?.path == "auth/passphrase/change")
        #expect((await transport.lastRequest())?.method == "POST")
        #expect(await transport.lastBody() == .object(["old_passphrase": .string("old-passphrase"), "new_passphrase": .string("new-passphrase")]))

        let operations = try await services.system.operationsStatus()
        #expect(operations.schemaState == "current" && operations.backup.state == "verified")
        #expect((await transport.lastRequest())?.path == "system/operations-status")

        let revision = try await services.system.dataRevision()
        #expect(revision.revision == 52)
        #expect((await transport.lastRequest())?.path == "data-revision")
        #expect((await transport.lastRequest())?.readCachePolicy == .reloadIgnoringCache)

        let provider = try await services.ai.providerSettings()
        #expect(provider.apiKeyConfigured && provider.baseURL == "https://ai.example.test/v1")
        #expect((await transport.lastRequest())?.path == "ai/provider-settings")

        let quality = try await services.ai.qualityMetrics()
        #expect(quality.rows.first?.pending == 1 && quality.rows.first?.total == 8)
        #expect((await transport.lastRequest())?.path == "ai/quality/metrics")
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

        configureValidExpense(model, title: "编辑后新请求")
        await model.submit(); let editedUnknownKey = try #require(await transport.createKeys().last)
        #expect(editedUnknownKey != unknownKey)
        await model.submit(); let editedRetryKey = try #require(await transport.createKeys().last)
        #expect(editedRetryKey == editedUnknownKey)

        configureValidExpense(model, title: "422 后新请求")
        await model.submit(); let validationKey = try #require(await transport.createKeys().last)
        await model.submit(); let validationRetryKey = try #require(await transport.createKeys().last)
        #expect(validationRetryKey != validationKey)

        configureValidExpense(model, title: "409 后新请求")
        await model.submit(); let conflictKey = try #require(await transport.createKeys().last)
        await model.reloadAfterConflict()
        await model.submit(); let conflictRetryKey = try #require(await transport.createKeys().last)
        #expect(conflictRetryKey != conflictKey)

        configureValidExpense(model, title: "成功后下一笔")
        await model.submit(); let successKey = try #require(await transport.createKeys().last)
        configureValidExpense(model, title: "下一笔")
        await model.submit(); let nextKey = try #require(await transport.createKeys().last)
        #expect(nextKey != successKey)
    }

    @Test("one confirmed save clears the draft and concurrent taps create only once")
    @MainActor func confirmedSaveClearsAndDeduplicates() async throws {
        let transport = F1AControlledTransport(createDelayMilliseconds: 80)
        let model = V15RecordModel(services: V15Services(transport: transport))
        await model.loadReferences()
        configureValidExpense(model, title: "只应保存一次")

        let first = Task { @MainActor in await model.submit() }
        while await transport.createCount() == 0 { await Task.yield() }
        let second = await model.submit()
        let firstOutcome = await first.value

        guard case .confirmed = firstOutcome else { Issue.record("first submit should be confirmed"); return }
        #expect(second == nil)
        #expect(await transport.createCount() == 1)
        #expect(model.title.isEmpty && model.amountText.isEmpty && model.note.isEmpty)
        #expect(model.accountID == nil && model.destinationAccountID == nil && model.categoryID == nil && model.creditCycleID == nil)
        guard case .success = model.submission else { Issue.record("receipt should remain visible"); return }

        let accidentalThirdTap = await model.submit()
        #expect(accidentalThirdTap == nil)
        #expect(await transport.createCount() == 1)
    }

    @Test("queued saves clear once while deterministic failures preserve the draft")
    @MainActor func queuedAndFailedDraftLifecycle() async {
        let offlineTransport = F1AControlledTransport()
        let pendingWrites = V15PendingWriteStore()
        let offlineServices = V15Services(
            transport: offlineTransport,
            offlineSnapshotProvider: { Date(timeIntervalSince1970: 1_700_000_000) },
            pendingWrites: pendingWrites
        )
        let offlineModel = V15RecordModel(services: offlineServices)
        await offlineModel.loadReferences()
        configureValidExpense(offlineModel, title: "离线一笔")
        let queued = await offlineModel.submit()
        guard case .queued = queued else { Issue.record("offline save should queue"); return }
        #expect(offlineModel.title.isEmpty && offlineModel.amountText.isEmpty)
        #expect(pendingWrites.count == 1)
        #expect(await offlineTransport.createCount() == 0)

        let failureTransport = F1AControlledTransport(outcomes: [.validation])
        let failureModel = V15RecordModel(services: V15Services(transport: failureTransport))
        await failureModel.loadReferences()
        configureValidExpense(failureModel, title: "失败后保留")
        let failed = await failureModel.submit()
        #expect(failed == nil)
        #expect(failureModel.title == "失败后保留" && failureModel.amountText == "12.80")
        #expect(failureModel.accountID == V15F1AFixtures.accountID)
        guard case .failed = failureModel.submission else { Issue.record("deterministic failure should remain visible"); return }
    }
}

@MainActor private func configureValidExpense(_ model: V15RecordModel, title: String = "午餐") {
    model.kind = .expense; model.title = title; model.amountText = "12.80"; model.accountID = V15F1AFixtures.accountID; model.categoryID = V15F1AFixtures.categoryID
}

actor F1AControlledTransport: V15Transporting {
    enum CreateOutcome: Sendable { case responseUnknown, validation, conflict, success }
    private var outcomes: [CreateOutcome]
    private var requests: [V15Request] = []
    private var bodies: [JSONValue?] = []
    private var transactionKeys: [String] = []
    private let createDelayMilliseconds: Int

    init(outcomes: [CreateOutcome] = [], createDelayMilliseconds: Int = 0) {
        self.outcomes = outcomes
        self.createDelayMilliseconds = createDelayMilliseconds
    }

    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        requests.append(request)
        bodies.append(body)
        if request.path == "transactions" {
            transactionKeys.append(request.headers["Idempotency-Key"] ?? "")
            if createDelayMilliseconds > 0 { try await Task.sleep(for: .milliseconds(createDelayMilliseconds)) }
            switch outcomes.isEmpty ? .success : outcomes.removeFirst() {
            case .responseUnknown: throw V15Failure(kind: .responseUnknown, code: "response_unknown", message: "unknown")
            case .validation: throw V15Failure(kind: .transport, code: "validation_failed", message: "invalid", fieldIssues: [.init(code: "invalid", message: "invalid", fieldPath: "title")])
            case .conflict: throw V15Failure(kind: .conflict, code: "version_conflict", message: "conflict", conflict: .init(reloadPath: "/api/v1/transactions/x", latestRevision: 2, message: "conflict"))
            case .success: return try decode(V15F1AFixtures.transaction)
            }
        }
        switch request.path {
        case "auth/session": return try decode(V15F1AFixtures.session)
        case "auth/passphrase/change": return try decode(Data(#"{"access_key":"replacement-access-key","credential_generation":3}"#.utf8))
        case "system/status": return try decode(V15F1AFixtures.system)
        case "system/operations-status":
            return try decode(Data(#"{"service_version":"1.5.2","release_revision":"release-26","database":"ready","alembic_revision":"schema-26","release_alembic_revision":"schema-26","schema_state":"current","backup":{"state":"verified","created_at":"2026-08-22T10:00:00Z","age_hours":2,"duration_seconds":4,"size_bytes":4096},"restore":{"state":"verified","checked_at":"2026-08-22T09:00:00Z","age_hours":3,"duration_seconds":9},"disk":{"state":"healthy","checked_at":"2026-08-22T12:00:00Z","used_percent":41,"warning_percent":75,"failure_percent":90}}"#.utf8))
        case "data-revision": return try decode(Data(#"{"revision":52}"#.utf8))
        case "ai/provider-settings":
            return try decode(Data(#"{"provider":"openai_compatible","base_url":"https://ai.example.test/v1","model":"fiscal-test","api_key_configured":true,"version":2,"updated_at":"2026-08-22T12:00:00Z"}"#.utf8))
        case "ai/quality/metrics":
            return try decode(Data(#"{"rows":[{"source":"text","provider":"openai_compatible","model":"fiscal-test","prompt_version":"p23-v1","transaction_kind":"expense","amount_band":"small","total":8,"parse_succeeded":7,"historical_unavailable":0,"confirm_unchanged":4,"confirm_edited":2,"ignored":0,"execute_failed":0,"automatic_execute":0,"manual_execute":6,"undone":0,"provider_retry":1,"final_failure":1,"pending":1,"terminal_outcomes":7}]}"#.utf8))
        case "accounts": return try decode(V15F1AFixtures.accounts)
        case "categories": return try decode(request.query.first(where: { $0.name == "direction" })?.value == "income" ? V15F1AFixtures.incomeCategories : V15F1AFixtures.categories)
        case "credit-accounts/\(V15F1AFixtures.creditID)/cycles": return try decode(V15F1AFixtures.creditCycles)
        default: throw V15Failure(kind: .transport, message: "fixture")
        }
    }

    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { Data() }
    func lastRequest() -> V15Request? { requests.last }
    func lastBody() -> JSONValue? { bodies.last ?? nil }
    func createKeys() -> [String] { transactionKeys }
    func createCount() -> Int { transactionKeys.count }
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
