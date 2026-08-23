import Foundation
import Testing

@testable import FiscalKit

@Suite("F1-B typed ledger contracts and race safety")
struct F1BTests {
    @Test("list preserves the backend keyset/filter query and opaque cursor")
    @MainActor func listQuery() async throws {
        let transport = F1BControlledTransport()
        let services = V15Services(transport: transport)
        let filter = V15LedgerFilter(cursor: "opaque+/=cursor", limit: 30, kind: V15LedgerReadKind.installmentFee.rawValue, accountID: V15F1BFixtures.accountID, categoryID: V15F1BFixtures.categoryID, dateFrom: "2026-08-01", dateTo: "2026-08-15", query: "午餐 & coffee", includeVoided: true, classification: "uncategorized", source: V15LedgerReadSource.system.rawValue, amountMinMinor: 1, amountMaxMinor: 9999)
        _ = try await services.ledger.list(filter)
        let request = try #require(await transport.lastRequest())
        #expect(request.path == "transactions" && request.method == "GET")
        #expect(request.query.contains(.init(name: "cursor", value: "opaque+/=cursor")))
        #expect(request.query.contains(.init(name: "include_voided", value: "true")))
        #expect(request.query.contains(.init(name: "amount_max_minor", value: "9999")))
        #expect(request.query.contains(.init(name: "query", value: "午餐 & coffee")))
        #expect(request.query.contains(.init(name: "kind", value: "installment_fee")))
        #expect(request.query.contains(.init(name: "source", value: "system")))
    }

    @Test("detail, revision and provenance decode only backend-shaped fixtures")
    @MainActor func readsDecode() async throws {
        let services = V15Services(transport: F1BControlledTransport())
        let detail = try await services.ledger.get(transactionID: V15F1BFixtures.transactionID)
        #expect(detail.availableActions.first?.action == "void")
        let history = try await services.ledger.revisions(transactionID: detail.id)
        #expect(history.items.map(\.event) == ["updated", "created"])
        let provenance = try await services.ledger.provenance(transactionID: detail.id)
        #expect(provenance.links.contains { $0.targetType == "merchant" })
    }

    @Test("replace, void and restore retain expected version in exact request body")
    @MainActor func mutationBodies() async throws {
        let transport = F1BControlledTransport()
        let services = V15Services(transport: transport)
        let draft = V15TransactionCreateRequest(kind: .expense, amountMinor: 1280, occurredAt: Date(timeIntervalSince1970: 0), title: "午餐", accountID: V15F1BFixtures.accountID)
        _ = try await services.ledger.replace(transactionID: V15F1BFixtures.transactionID, request: .init(draft: draft, expectedVersion: 2))
        var body = try #require(await transport.lastBody())
        #expect(integer("expected_version", in: body) == 2 && integer("amount_minor", in: body) == 1280)
        _ = try await services.ledger.void(transactionID: V15F1BFixtures.transactionID, expectedVersion: 2)
        body = try #require(await transport.lastBody())
        #expect(objectCount(body) == 1 && integer("expected_version", in: body) == 2)
        _ = try await services.ledger.restore(transactionID: V15F1BFixtures.transactionID, expectedVersion: 3)
        body = try #require(await transport.lastBody())
        #expect(objectCount(body) == 1 && integer("expected_version", in: body) == 3)
    }

    @Test("disabled and unknown capabilities cannot become actions")
    func capabilitySafety() {
        let disabled = V15AvailableAction(action: "void", enabled: false, reasonCode: "in_use", reasonMessage: "正在被使用")
        guard case .disabled(_, let reason) = disabled.capability(knownActions: ["void"]) else { Issue.record("expected disabled"); return }
        #expect(reason.code == "in_use")
        let unknown = V15AvailableAction(action: "restore", enabled: true, reasonCode: nil, reasonMessage: nil)
        guard case .disabled(_, let unknownReason) = unknown.capability(knownActions: ["void"]) else { Issue.record("unknown must be safe"); return }
        #expect(unknownReason.code == "unknown_capability")
    }

    @Test("filter generation prevents an old page from replacing new results")
    @MainActor func listRace() async {
        let transport = F1BRaceTransport()
        let model = V15LedgerModel(services: V15Services(transport: transport))
        model.filter.query = "旧"
        let old = Task { await model.load() }
        await Task.yield()
        model.filter.query = "新"
        await model.load()
        _ = await old.result
        #expect(model.items.map(\.id) == [V15F1BFixtures.otherTransactionID])
    }

    @Test("filter amounts use CNY input and local invalid fields block a request")
    @MainActor func amountFilterValidation() async {
        let transport = F1BControlledTransport()
        let model = V15LedgerModel(services: V15Services(transport: transport))
        model.setAmountMin("12.80")
        #expect(model.filter.amountMinMinor == 1280)
        model.setAmountMax("oops")
        #expect(!model.canLoadWithCurrentFilter)
        #expect(model.filterIssues.contains { $0.fieldPath == "amount_max" })
        await model.load()
        #expect(await transport.lastRequest() == nil)
    }

    @Test("unknown write outcomes include lost response, cancellation and invalid response but not request encoding")
    func unknownWriteOutcomes() {
        #expect(V15LedgerCreateService.outcomeMayBeUnknown(.init(kind: .responseUnknown, message: "lost")))
        #expect(V15LedgerCreateService.outcomeMayBeUnknown(.init(kind: .cancelled, message: "cancelled")))
        #expect(V15LedgerCreateService.outcomeMayBeUnknown(.init(kind: .decoding, code: "invalid_response", message: "bad")))
        #expect(!V15LedgerCreateService.outcomeMayBeUnknown(.init(kind: .decoding, code: "request_encode_failed", message: "bad")))
    }

    @Test("offline model exposes snapshot and never authorises a mutation")
    @MainActor func offlineReadOnly() async {
        let snapshot = Date(timeIntervalSince1970: 1_786_464_000)
        let model = V15LedgerModel(services: V15Services(transport: F1BControlledTransport()), offlineSnapshotAt: snapshot)
        #expect(model.offlineSnapshotAt == snapshot && model.isOffline)
        await model.loadDetail(transactionID: V15F1BFixtures.transactionID)
        await model.voidSelected()
        guard case .failed(let failure) = model.mutation else { Issue.record("offline mutation must be rejected"); return }
        #expect(failure.kind == .offlineReadOnly)
    }

    @Test("void and restore unknown responses reconcile by readback without a second write")
    @MainActor func mutationUnknownReconciles() async {
        let cases: [(V15LedgerModel.MutationAction, V15Failure)] = [
            (.void, .init(kind: .responseUnknown, message: "lost")), (.void, .init(kind: .cancelled, message: "cancelled")),
            (.void, .init(kind: .decoding, code: "invalid_response", message: "bad")), (.void, .init(kind: .transport, message: "lost")),
            (.restore, .init(kind: .responseUnknown, message: "lost")), (.restore, .init(kind: .cancelled, message: "cancelled")),
            (.restore, .init(kind: .decoding, code: "invalid_response", message: "bad")), (.restore, .init(kind: .transport, message: "lost"))
        ]
        for (action, failure) in cases {
            let transport = F1BMutationTransport(action: action, failure: failure)
            let model = V15LedgerModel(services: V15Services(transport: transport))
            await model.loadDetail(transactionID: V15F1BFixtures.transactionID); await transport.reset()
            #expect(model.selected?.availableActions.first?.action == action.rawValue)
            if action == .void { await model.voidSelected() } else { await model.restoreSelected() }
            let paths = await transport.paths()
            #expect(paths.filter { $0.hasSuffix("/void") || $0.hasSuffix("/restore") }.count == 1)
            #expect(paths.contains("transactions/\(V15F1BFixtures.transactionID)") && paths.contains("transactions/\(V15F1BFixtures.transactionID)/revisions"))
            #expect(model.lastAction == action)
            guard case .reconciled = model.mutation else { Issue.record("unknown outcome must reconcile"); continue }
        }
    }

    @Test("deterministic write failures never enter unknown-outcome reconciliation")
    @MainActor func deterministicMutationFailuresDoNotReadBack() async {
        let failures: [V15Failure] = [
            .init(kind: .decoding, code: "request_encode_failed", message: "encode"),
            .init(kind: .transport, code: "field_validation", message: "field"),
            .init(kind: .conflict, message: "conflict", conflict: .init(reloadPath: nil, latestRevision: nil, message: "conflict"))
        ]
        for failure in failures {
            let transport = F1BMutationTransport(action: .void, failure: failure)
            let model = V15LedgerModel(services: V15Services(transport: transport))
            await model.loadDetail(transactionID: V15F1BFixtures.transactionID); await transport.reset(); await model.voidSelected()
            let paths = await transport.paths()
            #expect(paths == ["transactions/\(V15F1BFixtures.transactionID)/void"])
            if failure.kind == .conflict { guard case .conflict = model.mutation else { Issue.record("409 must stay conflict"); continue } }
            else { guard case .failed = model.mutation else { Issue.record("deterministic failure must stay failed"); continue } }
        }
    }

    @Test("account-scoped repayment uses the selected posting and explains both accounts")
    func accountScopedRepaymentPresentation() {
        let sourceID = UUID()
        let creditID = UUID()
        let accounts = [
            presentationAccount(id: sourceID, name: "杭联0519", kind: .debit),
            presentationAccount(id: creditID, name: "花呗", kind: .credit)
        ]
        let repayment = presentationTransaction(
            kind: "repayment",
            amountMinor: 159_882,
            accountID: sourceID,
            destinationAccountID: creditID,
            postings: [
                .init(id: UUID(), accountID: sourceID, role: "source", amountMinor: -159_882, position: 0),
                .init(id: UUID(), accountID: creditID, role: "destination", amountMinor: 159_882, position: 1)
            ]
        )

        let creditView = V15AccountTransactionPresenter.present(repayment, scopedAccountID: creditID, accounts: accounts)
        #expect(creditView.accountPath == "杭联0519 → 花呗")
        #expect(creditView.accountEffect == "欠款减少")
        #expect(creditView.amountMinor == 159_882 && creditView.direction == .inflow)
        #expect(creditView.hasAuthoritativePosting)

        let sourceView = V15AccountTransactionPresenter.present(repayment, scopedAccountID: sourceID, accounts: accounts)
        #expect(sourceView.accountPath == "杭联0519 → 花呗")
        #expect(sourceView.accountEffect == "余额减少")
        #expect(sourceView.amountMinor == -159_882 && sourceView.direction == .outflow)
    }

    @Test("credit expense is debt growth while an unscoped ledger keeps transaction direction")
    func creditExpensePresentation() {
        let creditID = UUID()
        let account = presentationAccount(id: creditID, name: "花呗", kind: .credit)
        let expense = presentationTransaction(
            kind: "expense",
            amountMinor: 2_800,
            accountID: creditID,
            postings: [.init(id: UUID(), accountID: creditID, role: "account", amountMinor: -2_800, position: 0)]
        )

        let scoped = V15AccountTransactionPresenter.present(expense, scopedAccountID: creditID, accounts: [account])
        #expect(scoped.accountEffect == "欠款增加")
        #expect(scoped.amountMinor == -2_800 && scoped.direction == .outflow)

        let unscoped = V15AccountTransactionPresenter.present(expense, scopedAccountID: nil, accounts: [account])
        #expect(unscoped.accountEffect == nil && unscoped.amountMinor == 2_800 && unscoped.direction == .outflow)
        #expect(!unscoped.isAccountScoped && !unscoped.hasAuthoritativePosting)
    }

    @Test("income and transfers follow each selected account posting")
    func incomeAndTransferPresentation() {
        let sourceID = UUID()
        let destinationID = UUID()
        let accounts = [
            presentationAccount(id: sourceID, name: "工资卡", kind: .debit),
            presentationAccount(id: destinationID, name: "储蓄卡", kind: .debit)
        ]
        let income = presentationTransaction(
            kind: "income",
            amountMinor: 5_000,
            accountID: sourceID,
            postings: [.init(id: UUID(), accountID: sourceID, role: "account", amountMinor: 5_000, position: 0)]
        )
        let incomeView = V15AccountTransactionPresenter.present(income, scopedAccountID: sourceID, accounts: accounts)
        #expect(incomeView.accountEffect == "余额增加" && incomeView.direction == .inflow)

        let transfer = presentationTransaction(
            kind: "transfer",
            amountMinor: 1_000,
            accountID: sourceID,
            destinationAccountID: destinationID,
            postings: [
                .init(id: UUID(), accountID: sourceID, role: "source", amountMinor: -1_000, position: 0),
                .init(id: UUID(), accountID: destinationID, role: "destination", amountMinor: 1_000, position: 1)
            ]
        )
        let source = V15AccountTransactionPresenter.present(transfer, scopedAccountID: sourceID, accounts: accounts)
        let destination = V15AccountTransactionPresenter.present(transfer, scopedAccountID: destinationID, accounts: accounts)
        #expect(source.accountPath == "工资卡 → 储蓄卡" && source.accountEffect == "余额减少" && source.direction == .outflow)
        #expect(destination.accountPath == "工资卡 → 储蓄卡" && destination.accountEffect == "余额增加" && destination.direction == .inflow)
    }
}

private func presentationAccount(id: UUID, name: String, kind: V15AccountKind) -> V15AccountResponse {
    let now = Date(timeIntervalSince1970: 0)
    return .init(
        id: id, name: name, kind: kind, institution: nil, lastFour: nil,
        openingBalanceMinor: 0, currentBalanceMinor: 0, creditLimitMinor: nil,
        statementDay: nil, dueDay: nil, cycleMode: nil, openingBalanceAsOfDate: nil,
        openingDueDate: nil, sortOrder: 0, archivedAt: nil, usageCount: 0, version: 1,
        createdAt: now, updatedAt: now
    )
}

private func presentationTransaction(
    kind: String,
    amountMinor: V15MinorUnits,
    accountID: UUID?,
    destinationAccountID: UUID? = nil,
    postings: [V15Posting]
) -> V15Transaction {
    let now = Date(timeIntervalSince1970: 0)
    return .init(
        id: UUID(), kind: kind, amountMinor: amountMinor, occurredAt: now,
        businessDate: "2026-08-23", title: "测试账目", note: nil, categoryID: nil,
        accountID: accountID, destinationAccountID: destinationAccountID, creditCycleID: nil,
        source: "manual", postings: postings, version: 1, voidedAt: nil, createdAt: now,
        updatedAt: now, installmentPlanID: nil, installmentRelation: nil,
        reimbursementRelations: [], availableActions: []
    )
}

actor F1BControlledTransport: V15Transporting {
    private var request: V15Request?
    private var body: JSONValue?
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        self.request = request; self.body = body
        let data: Data
        switch request.path {
        case "transactions": data = V15F1BFixtures.page
        case "transactions/\(V15F1BFixtures.transactionID)/revisions": data = V15F1BFixtures.revisions
        case "transactions/\(V15F1BFixtures.transactionID)/provenance": data = V15F1BFixtures.provenance
        default: data = request.method == "POST" && request.path.hasSuffix("/void") ? V15F1BFixtures.voided : V15F1BFixtures.detail
        }
        return try V15FixtureCodec.decoder.decode(Response.self, from: data)
    }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { Data() }
    func lastRequest() -> V15Request? { request }
    func lastBody() -> JSONValue? { body }
}

actor F1BRaceTransport: V15Transporting {
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        let old = request.query.first(where: { $0.name == "query" })?.value == "旧"
        if old { try await Task.sleep(for: .milliseconds(80)); return try V15FixtureCodec.decoder.decode(Response.self, from: V15F1BFixtures.page) }
        return try V15FixtureCodec.decoder.decode(Response.self, from: Data(#"{"items":[#OTHER#],"next_cursor":null}"#.replacingOccurrences(of: "#OTHER#", with: String(decoding: V15F1BFixtures.other, as: UTF8.self)).utf8))
    }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { Data() }
}

actor F1BMutationTransport: V15Transporting {
    private let action: V15LedgerModel.MutationAction; private let failure: V15Failure; private var seen: [String] = []
    init(action: V15LedgerModel.MutationAction, failure: V15Failure) { self.action = action; self.failure = failure }
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        seen.append(request.path)
        if request.method == "POST" { throw failure }
        let data: Data
        if request.path.hasSuffix("/revisions") { data = V15F1BFixtures.revisions }
        else if request.path.hasSuffix("/provenance") { data = V15F1BFixtures.provenance }
        else {
            let source = action == .restore ? V15F1BFixtures.voided : V15F1BFixtures.detail
            var text = String(decoding: source, as: UTF8.self).replacingOccurrences(of: #""action":"void""#, with: "\"action\":\"\(action.rawValue)\"")
            if action == .restore { text = text.replacingOccurrences(of: #""enabled":false"#, with: #""enabled":true"#).replacingOccurrences(of: #""reason_code":"transaction_already_voided""#, with: #""reason_code":null"#).replacingOccurrences(of: #""reason_message":"该账目已经作废。""#, with: #""reason_message":null"#) }
            data = Data(text.utf8)
        }
        return try V15FixtureCodec.decoder.decode(Response.self, from: data)
    }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { Data() }
    func reset() { seen = [] }
    func paths() -> [String] { seen }
}

private func integer(_ key: String, in value: JSONValue) -> Int64? { guard case .object(let object) = value, case .integer(let integer)? = object[key] else { return nil }; return integer }
private func objectCount(_ value: JSONValue) -> Int { guard case .object(let object) = value else { return 0 }; return object.count }
