import Foundation
import Testing
@testable import FiscalKit

@Suite("2.3.0 client financial contracts")
struct V230ClientTests {
    @Test @MainActor func onDemandSummaryHasNoInventedCycleOrLimit() async throws {
        let services = V230Fixtures.services()
        let summary = try await services.credit.account(id: V230Fixtures.accountID)
        #expect(summary.cycleMode == .onDemand)
        #expect(summary.currentCycle == nil && summary.creditLimitMinor == nil && summary.availableCreditMinor == nil)
        let credit = V15CreditModel(services: services); await credit.load()
        #expect(credit.scheduleCommandDisabledReason?.code == "on_demand_no_schedule")
    }
    @Test @MainActor func borrowingUsesCreditSourceAndCashDestinationWithoutCategory() async {
        let model = V15RecordModel(services: V230Fixtures.services())
        await model.loadReferences(); model.kind = .borrowing; model.amountText = "100"; model.title = "测试借入"
        model.accountID = V230Fixtures.accountID; model.destinationAccountID = V15F1AFixtures.accountID
        #expect(model.localIssues.isEmpty)
        model.kind = .expense
        #expect(model.accountID == nil && model.destinationAccountID == nil)
    }
    @Test @MainActor func borrowingAndRepaymentCommitOppositePostings() async throws {
        let services = V230Fixtures.services()
        let model = V15RecordModel(services: services)
        await model.loadReferences(); model.kind = .borrowing; model.title = "合成借入"; model.amountText = "100"; model.accountID = V230Fixtures.accountID; model.destinationAccountID = V15F1AFixtures.accountID
        guard case .confirmed(let borrowed) = await model.submit() else { Issue.record("Borrowing should commit"); return }
        #expect(borrowed.kind == "borrowing" && borrowed.postings.map(\.amountMinor) == [-10000, 10000])
        await model.loadReferences(); model.kind = .repayment; model.title = "合成还款"; model.amountText = "40"; model.accountID = V15F1AFixtures.accountID; model.destinationAccountID = V230Fixtures.accountID
        await model.loadCreditCycles(); await model.previewRepayment()
        guard case .confirmed(let repaid) = await model.submit() else { Issue.record("Repayment should commit"); return }
        #expect(repaid.kind == "repayment" && repaid.creditCycleID == nil && repaid.postings.map(\.amountMinor) == [-4000, 4000])
        #expect(try await services.credit.account(id: V230Fixtures.accountID).currentDebtMinor == 134000)
    }
    @Test @MainActor func onDemandRepaymentShowsPositiveDebtAndExactExcess() async {
        let model = V15RecordModel(services: V230Fixtures.services())
        await model.loadReferences(); model.kind = .repayment; model.title = "还款"; model.accountID = V15F1AFixtures.accountID; model.destinationAccountID = V230Fixtures.accountID
        model.amountText = "1280"; await model.loadCreditCycles()
        #expect(model.isOnDemandRepayment && model.repaymentRemainingMinor == 128000 && model.localIssues.isEmpty)
        model.amountText = "1300"
        #expect(model.localIssues.contains { $0.message == "剩余应还 ¥1280，输入 ¥1300，超出 ¥20" })
    }
    @Test func absentDisposableRemainsUnavailableAndOverflowFailsConsistency() throws {
        let legacy = try V15FixtureCodec.decoder.decode(V15Facts.self, from: V15FixtureLibrary.factsSuccess)
        #expect(legacy.disposable == nil)
        let value = V15Disposable(dateFrom: "2026-09-12", dateTo: "2026-10-11", currentCashMinor: .max, expectedInflowMinor: 1, expectedOutflowMinor: 0, projectedBalanceMinor: .min, undatedInflowMinor: 0, unscheduledCreditDebtMinor: 0, overdueOutflowMinor: 0)
        #expect(!value.isConsistent)
    }
    @Test @MainActor func disposableDetailsBindFactsRevision() async {
        let model = V15TodayReadModel(services: V230Fixtures.services())
        await model.refresh(); await model.openDisposableEvents(direction: .inflow)
        #expect(model.disposableEvents.count == 1)
        #expect(model.disposableEvents.first?.amountMinor == model.facts?.disposable?.expectedInflowMinor)
        await model.refresh()
        #expect(model.disposableEvents.isEmpty)
    }
    @Test @MainActor func payoffInputChangeInvalidatesEvenWhenTextInvalid() async {
        let model = await payoffModel(services: V230Fixtures.services())
        await model.previewPayoff(); #expect(model.canCommit)
        model.additionalFeeText = "?"
        #expect(model.preview == nil && !model.canCommit)
    }
    @Test @MainActor func lostPayoffResponseRestartsWithOriginalPayloadAndKey() async throws {
        let transport = V230FixtureTransport(scenario: "v230-payoff-unknown")
        let store = V15PendingWriteStore()
        let services = V15Services(transport: transport, pendingWrites: store)
        let model = await payoffModel(services: services)
        await model.previewPayoff(); await model.commit()
        #expect(model.phase == .unknown)
        let original = try #require(store.items.first)
        let restarted = V15CreditPayoffModel(services: services, accountID: V230Fixtures.accountID)
        restarted.actualAmountText = "999999"; restarted.note = "不能改写已发送请求"
        await restarted.recoverPending()
        #expect(restarted.phase == .succeeded)
        #expect(restarted.receipt?.actualAmountMinor == 128000 && store.items.isEmpty)
        #expect(restarted.operations.count == 1)
        #expect(original.kind == .creditPayoff)
    }
    @Test @MainActor func payoffReverseRestoresDebtAndRetainsSingleReceipt() async throws {
        let services = V230Fixtures.services()
        let model = await payoffModel(services: services)
        await model.previewPayoff(); await model.commit(); await model.previewReverse(); await model.reverse()
        #expect(model.receipt?.status == "reversed" && model.operations.count == 1)
        #expect(try await services.credit.account(id: V230Fixtures.accountID).currentDebtMinor == 128000)
    }
    @Test @MainActor func strictAccountDatesAndZeroLimitAreLocallyRejected() async {
        let transport = V230MasterTestTransport(); let model = V15MasterDataModel(services: V15Services(transport: transport))
        model.accountKind = .credit; model.accountName = "随借随还"; model.cycleMode = "on_demand"; model.openingBalance = "100"; model.openingBalanceAsOfDate = "2026-02-30"
        await model.saveAccount()
        #expect(!model.fieldIssues.isEmpty && model.receiptStatus == .validation)
        #expect(await transport.creates == 0)
        model.openingBalanceAsOfDate = "2026-02-28"; model.cycleMode = "statement_day_cutoff"; model.creditLimit = "0"; model.statementDay = "20"; model.dueDay = "5"; model.openingDueDate = "2026-03-05"
        await model.saveAccount(); #expect(await transport.creates == 0)
    }
    @Test @MainActor func createBindsReturnedIDAndCannotCreateTwiceEvenWhenRefreshFails() async {
        let transport = V230MasterTestTransport(); let model = V15MasterDataModel(services: V15Services(transport: transport))
        model.accountName = "新账户"; model.openingBalance = "0"
        await model.saveAccount()
        #expect(model.selectedAccountID != nil && model.receiptStatus == .success)
        #expect(model.receipt?.contains("刷新失败") == true)
        await model.saveAccount(); #expect(await transport.creates == 1)
    }
    @Test @MainActor func cashFlowPartialAndExistingUseRemainingWithoutCreatingAgain() async throws {
        let services = V230Fixtures.services()
        let first = try await services.cashFlow.item(id: V15F3DFixtures.itemID)
        let partial = try await services.cashFlow.settle(itemID: V15F3DFixtures.itemID, request: .init(expectedVersion: first.version, actualAmountMinor: 10000, occurredAt: Date(), accountID: V15F1AFixtures.accountID), idempotencyKey: UUID())
        #expect(partial.plannedAmountMinor == 30000 && partial.remainingAmountMinor == 20000 && partial.status == .confirmed)
        let transaction = try V15FixtureCodec.decoder.decode(V15Transaction.self, from: V15F1AFixtures.transaction)
        let key = UUID()
        let request = V15CashFlowSettleExistingRequest(expectedVersion: partial.version, transactionID: transaction.id, transactionExpectedVersion: transaction.version, completeRemaining: false)
        let linked = try await services.cashFlow.settleExisting(itemID: V15F3DFixtures.itemID, request: request, idempotencyKey: key)
        let replay = try await services.cashFlow.settleExisting(itemID: V15F3DFixtures.itemID, request: request, idempotencyKey: key)
        #expect(linked.remainingAmountMinor == 18720 && replay == linked)
        #expect(linked.settlementTransactionIDs?.count == 2)
    }
    @Test func switchingEmptyAccountToOnDemandExplicitlyClearsCreditFields() throws {
        let body = try V15BodyEncoder.encode(V15AccountPatch(expectedVersion: 1, cycleMode: "on_demand"))
        guard case .object(let fields) = body else { Issue.record("Expected JSON object"); return }
        #expect(fields["credit_limit_minor"] == .null && fields["statement_day"] == .null && fields["due_day"] == .null)
    }
    @Test func excessErrorIsFieldValidationAndTemporalErrorIsDistinct() {
        let error = V15ErrorMapper.map(.domain(status: 422, detail: .init(code: "repayment_exceeds_cycle_remaining", message: "english", details: .object(["remaining_minor": .integer(100), "input_minor": .integer(150), "difference_minor": .integer(50)]), requestID: "test")))
        #expect(error.message == "剩余应还 ¥1，输入 ¥1.5，超出 ¥0.5" && error.isDefinitiveRejection)
        let temporal = V15ErrorMapper.map(.domain(status: 422, detail: .init(code: "credit_liability_predates_repayment", message: "english", details: nil, requestID: "test")))
        #expect(temporal.fieldIssues.first?.fieldPath == "occurred_at")
    }
    @MainActor private func payoffModel(services: V15Services) async -> V15CreditPayoffModel {
        let model = V15CreditPayoffModel(services: services, accountID: V230Fixtures.accountID)
        await model.load(); model.paymentAccountID = V15F1AFixtures.accountID; model.actualAmountText = "1280"; model.bankConfirmedSettled = true
        return model
    }
}

private actor V230MasterTestTransport: V15Transporting {
    private(set) var creates = 0
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        if request.path == "accounts" && request.method == "POST", let body {
            creates += 1
            var value = (try JSONSerialization.jsonObject(with: V15F1AFixtures.accounts) as! [[String: Any]])[0]
            let data = try V15BodyEncoder.data(body)
            let fields = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            for (key, field) in fields { value[key] = field }
            value["id"] = UUID().uuidString; value["version"] = 1; value["current_balance_minor"] = fields["opening_balance_minor"]
            return try V15FixtureCodec.decoder.decode(Response.self, from: JSONSerialization.data(withJSONObject: value))
        }
        throw V15Failure(kind: .transport, message: "模拟读取失败")
    }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { throw CocoaError(.fileReadUnsupportedScheme) }
}
