import Foundation
import Testing
@testable import FiscalKit

@MainActor private final class F3ETickingClock {
    private var tick = 0
    private var offset: TimeInterval = 0
    private let base: Date
    init(base: Date) { self.base = base }
    func now() -> Date { tick += 1; return base.addingTimeInterval(offset + Double(tick) / 1_000) }
    func advance(by interval: TimeInterval) { offset += interval }
}

@Suite("F3-E typed reconciliation facts and keyless writes")
struct F3ETests {
    private let fixedNow = ISO8601DateFormatter().date(from: "2026-08-16T08:00:00Z")!

    @MainActor private func loadedModel(_ transport: F3ETransport = F3ETransport(mode: .normal), offline: Bool = false) async -> V15ReconciliationModel {
        let model = V15ReconciliationModel(services: V15Services(transport: transport), offlineSnapshotAt: offline ? fixedNow : nil, now: { fixedNow })
        await model.load()
        return model
    }

    @MainActor private func fillCheckpoint(_ model: V15ReconciliationModel, amount: String = "1234.56") {
        model.beginEditor()
        model.advanceEditor()
        model.actualBalanceText = amount
        model.asOfDateText = "2026-08-16"
        model.note = "新核对"
        model.advanceEditor()
    }

    @Test("checkpoint diagnosis and attention decode backend facts without amount narrowing")
    func typedFactDecode() throws {
        let checkpoints = try V15FixtureCodec.decoder.decode([V15ReconciliationCheckpoint].self, from: Data(V15F3EFixtures.checkpoints(targetID: V15F3EFixtures.accountA).utf8))
        #expect(checkpoints.map(\.state) == [.open, .reconciled])
        #expect(checkpoints.first?.accountID == V15F3EFixtures.accountA)
        #expect(checkpoints.first?.creditCycleID == nil)
        let future = V15F3EFixtures.checkpoint(id: V15F3EFixtures.createdCheckpoint, state: "future_state")
        #expect(try V15FixtureCodec.decoder.decode(V15ReconciliationCheckpoint.self, from: Data(future.utf8)).state == .unknown("future_state"))

        let diagnosis = try V15FixtureCodec.decoder.decode(V15ReconciliationDiagnosis.self, from: Data(V15F3EFixtures.diagnosis(kind: "credit_cycle", targetID: V15F3EFixtures.cycleA, asOf: "2026-08-16T08:00:00Z").utf8))
        #expect(diagnosis.targetKind == .creditCycle)
        #expect(diagnosis.accountID == nil && diagnosis.creditCycleID == V15F3EFixtures.cycleA)
        #expect(diagnosis.entries.first?.accountImpactMinor == -1_550)

        let attention = try V15FixtureCodec.decoder.decode(V15AttentionPage.self, from: Data(V15F3EFixtures.attention().utf8))
        #expect(attention.items.first { $0.sourceID == V15F3EFixtures.overdueID }?.amountMinor == 922_337_203_685_477)
        #expect(attention.items.first { $0.sourceID == V15F3EFixtures.unknownAttentionID }?.availableActions.first?.action == "review")
    }

    @MainActor @Test("service emits exact account cycle diagnosis create detail and 204 ignore wires")
    func typedServiceWires() async throws {
        let transport = F3ETransport(mode: .normal)
        let service = V15Services(transport: transport).reconciliation
        let account = V15ReconciliationTarget(kind: .account, resourceID: V15F3EFixtures.accountA, label: "账户", accountID: V15F3EFixtures.accountA)
        let cycle = V15ReconciliationTarget(kind: .creditCycle, resourceID: V15F3EFixtures.cycleA, label: "账期", accountID: V15F3EFixtures.creditAccount)
        let asOf = try #require(ISO8601DateFormatter().date(from: "2026-08-16T08:00:00Z"))
        _ = try await service.checkpoints(target: account)
        _ = try await service.checkpoints(target: cycle)
        _ = try await service.checkpoint(id: V15F3EFixtures.openCheckpoint)
        _ = try await service.diagnosis(target: cycle, asOf: asOf)
        _ = try await service.attention()
        let create = V15ReconciliationCheckpointCreate(targetKind: .account, accountID: V15F3EFixtures.accountA, creditCycleID: nil, asOf: asOf, actualBalanceMinor: -12_345, note: nil)
        _ = try await service.createCheckpoint(create)
        let attention = try V15FixtureCodec.decoder.decode(V15AttentionPage.self, from: Data(V15F3EFixtures.attention().utf8))
        let item = try #require(attention.items.first)
        let expiry = try #require(ISO8601DateFormatter().date(from: "2026-08-17T16:00:00Z"))
        try await service.ignoreAttention(sourceType: item.sourceType, sourceID: item.sourceID, request: .init(expiresAt: expiry))

        let requests = await transport.allRequests()
        let checkpointReads = requests.filter { $0.method == "GET" && $0.path == "reconciliation/checkpoints" }
        #expect(checkpointReads.contains { $0.query == [.init(name: "account_id", value: V15F3EFixtures.accountA.uuidString)] })
        #expect(checkpointReads.contains { $0.query == [.init(name: "credit_cycle_id", value: V15F3EFixtures.cycleA.uuidString)] })
        #expect(requests.contains { $0.method == "GET" && $0.path == "reconciliation/checkpoints/\(V15F3EFixtures.openCheckpoint)" })
        let diagnosis = try #require(requests.first { $0.path == "reconciliation/diagnosis" })
        #expect(diagnosis.query == [
            .init(name: "target_kind", value: "credit_cycle"),
            .init(name: "as_of", value: "2026-08-16T08:00:00Z"),
            .init(name: "credit_cycle_id", value: V15F3EFixtures.cycleA.uuidString)
        ])
        #expect(!diagnosis.query.contains { $0.name == "account_id" })

        let wires = await transport.mutationWires()
        let createWire = try #require(wires.first { $0.path == "reconciliation/checkpoints" })
        let createBody = try #require(JSONSerialization.jsonObject(with: Data(createWire.body.utf8)) as? [String: Any])
        #expect(Set(createBody.keys) == ["target_kind", "account_id", "as_of", "actual_balance_minor"])
        #expect(createBody["actual_balance_minor"] as? Int == -12_345)
        let ignoreWire = try #require(wires.first { $0.path.hasSuffix("/ignore") })
        #expect(ignoreWire.path == "reconciliation/attention/\(item.sourceType)/\(item.sourceID)/ignore")
        let ignoreBody = try V15FixtureCodec.decoder.decode(V15AttentionIgnoreRequest.self, from: Data(ignoreWire.body.utf8))
        #expect(ignoreBody.expiresAt == expiry)
        #expect(requests.filter { $0.method == "POST" }.allSatisfy { $0.headers["Idempotency-Key"] == nil })

        do {
            _ = try await service.createCheckpoint(.init(targetKind: .account, accountID: V15F3EFixtures.accountA, creditCycleID: V15F3EFixtures.cycleA, asOf: asOf, actualBalanceMinor: 0, note: nil))
            Issue.record("exact-one target guard must reject mixed identifiers")
        } catch let failure as V15Failure {
            #expect(failure.code == "invalid_reconciliation_target")
        }
        #expect(await transport.mutationWires().filter { $0.path == "reconciliation/checkpoints" }.count == 1)
    }

    @MainActor @Test("CNY Shanghai validation permits negative and zero while future dates share the button guard")
    func validationAndButtonGuard() async {
        let model = await loadedModel()
        fillCheckpoint(model, amount: "-12.34")
        #expect(model.checkpointReasons.isEmpty)
        model.actualBalanceText = "0"
        #expect(model.checkpointIssues.isEmpty)
        model.actualBalanceText = "12.345"
        #expect(model.checkpointReasons.contains { $0.code == "actual_balance_invalid" })
        model.actualBalanceText = "12.34"
        model.asOfDateText = "2026-08-17"
        #expect(model.checkpointReasons.contains { $0.code == "as_of_invalid" })
        model.asOfDateText = "2026-08-16"
        #expect(model.checkpointReasons.isEmpty)
        #expect(ShanghaiBusinessDate.string(for: fixedNow) == "2026-08-16")
    }

    @MainActor @Test("available actions are the sole ignore authority and preserve backend disabled reason")
    func attentionCapabilityAuthority() async throws {
        let model = await loadedModel()
        let enabled = try #require(model.attention.first { $0.sourceID == V15F3EFixtures.openCheckpoint })
        #expect(model.ignoreReasons(for: enabled).isEmpty)
        let disabled = try #require(model.attention.first { $0.sourceID == V15F3EFixtures.statementID })
        #expect(model.ignoreReasons(for: disabled).contains { $0.code == "statement_import_attention_not_dismissible" && $0.message == "Statement import attention cannot be ignored" })
        let future = try #require(model.attention.first { $0.sourceID == V15F3EFixtures.unknownAttentionID })
        #expect(model.ignoreReasons(for: future).contains { $0.code == "attention_action_unknown" })
    }

    @MainActor @Test("checkpoint response unknown performs one POST and fresh GET never auto-attributes")
    func checkpointUnknownFreshReadOnly() async {
        let transport = F3ETransport(mode: .checkpointUnknown)
        let model = await loadedModel(transport)
        fillCheckpoint(model)
        await model.createCheckpoint()
        #expect(model.mutationPhase == .unknown && model.hasUnknownAttempt)
        #expect(await transport.mutationWires().filter { $0.path == "reconciliation/checkpoints" }.count == 1)
        #expect(!model.canAbandonUnknown)
        await model.readFreshFactsForUnknown()
        #expect(model.mutationPhase == .unknown && model.canAbandonUnknown)
        #expect(model.unknownFactsMessage?.contains("仍无法确认是否由本次操作造成") == true)
        #expect(await transport.mutationWires().filter { $0.path == "reconciliation/checkpoints" }.count == 1)
        #expect(await transport.allRequests().contains { $0.method == "GET" && $0.path == "reconciliation/checkpoints" && $0.readCachePolicy == .reloadIgnoringCache })
        model.abandonUnknown()
        #expect(model.mutationPhase == .idle && !model.writeLocked)
    }

    @MainActor @Test("attention response unknown performs one POST and requires explicit abandon after fresh GET")
    func ignoreUnknownFreshReadOnly() async throws {
        let transport = F3ETransport(mode: .ignoreUnknown)
        let model = await loadedModel(transport)
        let item = try #require(model.attention.first { $0.sourceID == V15F3EFixtures.openCheckpoint })
        await model.ignore(item)
        #expect(model.mutationPhase == .unknown && !model.canAbandonUnknown)
        #expect(await transport.mutationWires().filter { $0.path.hasSuffix("/ignore") }.count == 1)
        await model.readFreshFactsForUnknown()
        #expect(model.mutationPhase == .unknown && model.canAbandonUnknown)
        #expect(model.unknownFactsMessage?.contains("仍无法确认是否由本次操作造成") == true)
        #expect(await transport.mutationWires().filter { $0.path.hasSuffix("/ignore") }.count == 1)
        model.abandonUnknown()
        #expect(!model.writeLocked)
    }

    @MainActor @Test("cancelled and invalid checkpoint responses stay owner scoped unknown across reopen and A B navigation")
    func checkpointPossiblyDeliveredFailures() async throws {
        for mode in [F3ETransport.Mode.checkpointCancelled, .checkpointInvalidResponse] {
            let transport = F3ETransport(mode: mode)
            let model = await loadedModel(transport)
            fillCheckpoint(model)
            await model.createCheckpoint()
            #expect(model.mutationPhase == .unknown && model.hasUnknownAttempt)
            #expect(await transport.mutationWires().filter { $0.path == "reconciliation/checkpoints" }.count == 1)

            model.beginEditor()
            #expect(model.hasUnknownAttempt)
            let accountA = try #require(model.accountTargets.first { $0.resourceID == V15F3EFixtures.accountA })
            let accountB = try #require(model.accountTargets.first { $0.resourceID == V15F3EFixtures.accountB })
            await model.selectTarget(accountB)
            #expect(model.selectedTarget?.resourceID == V15F3EFixtures.accountB)
            #expect(!model.hasUnknownAttempt && model.writeLocked)
            await model.selectTarget(accountA)
            #expect(model.hasUnknownAttempt)

            await model.readFreshFactsForUnknown()
            #expect(model.canAbandonUnknown)
            #expect(await transport.mutationWires().filter { $0.path == "reconciliation/checkpoints" }.count == 1)
            #expect(await transport.allRequests().contains { $0.method == "GET" && $0.path == "reconciliation/checkpoints" && $0.readCachePolicy == .reloadIgnoringCache })
            model.abandonUnknown()
            #expect(!model.writeLocked)
        }
    }

    @MainActor @Test("cancelled and invalid 204 ignore responses stay unknown and recover through GET only")
    func ignorePossiblyDeliveredFailures() async throws {
        for mode in [F3ETransport.Mode.ignoreCancelled, .ignoreInvalidResponse] {
            let transport = F3ETransport(mode: mode)
            let model = await loadedModel(transport)
            let item = try #require(model.attention.first { $0.sourceID == V15F3EFixtures.openCheckpoint })
            await model.ignore(item)
            #expect(model.mutationPhase == .unknown && model.hasUnknownAttempt)
            #expect(await transport.mutationWires().filter { $0.path.hasSuffix("/ignore") }.count == 1)
            await model.readFreshFactsForUnknown()
            #expect(model.canAbandonUnknown)
            #expect(await transport.mutationWires().filter { $0.path.hasSuffix("/ignore") }.count == 1)
            #expect(await transport.allRequests().contains { $0.method == "GET" && $0.path == "reconciliation/attention" && $0.readCachePolicy == .reloadIgnoringCache })
            model.abandonUnknown()
        }
    }

    @MainActor @Test("deterministic retry keeps a stable visible fingerprint across a moving today clock and invalidates changed input")
    func deterministicFailureRetry() async throws {
        let retryTransport = F3ETransport(mode: .deterministicOnce)
        let retryClock = F3ETickingClock(base: fixedNow)
        let retry = V15ReconciliationModel(services: V15Services(transport: retryTransport), now: { retryClock.now() })
        await retry.load()
        fillCheckpoint(retry)
        await retry.createCheckpoint()
        #expect(retry.hasFailedMutation && !retry.writeLocked)
        #expect(retry.mutationIntentKind == .checkpoint)
        #expect(retry.failedMutationRetryReasons.isEmpty)
        let firstWire = try #require(await retryTransport.mutationWires().first { $0.path == "reconciliation/checkpoints" })
        retryClock.advance(by: 60)
        #expect(ShanghaiBusinessDate.string(for: retryClock.now()) == retry.asOfDateText)
        await retry.retryDeterministicMutation()
        #expect(retry.mutationPhase == .succeeded)
        let retryWires = await retryTransport.mutationWires().filter { $0.path == "reconciliation/checkpoints" }
        #expect(retryWires.count == 2)
        #expect(retryWires.last?.body == firstWire.body)

        let amountTransport = F3ETransport(mode: .deterministicOnce)
        let amountChanged = await loadedModel(amountTransport)
        fillCheckpoint(amountChanged)
        await amountChanged.createCheckpoint()
        amountChanged.actualBalanceText = "1200.00"
        #expect(amountChanged.hasFailedMutation && amountChanged.editorStep == 2)
        #expect(amountChanged.failedMutationRetryReasons.contains { $0.code == "mutation_intent_changed" })
        await amountChanged.retryDeterministicMutation()
        #expect(amountChanged.hasFailedMutation)
        #expect(await amountTransport.mutationWires().filter { $0.path == "reconciliation/checkpoints" }.count == 1)
        amountChanged.advanceEditor()
        await amountChanged.createCheckpoint()
        #expect(amountChanged.mutationPhase == .succeeded)
        #expect(await amountTransport.mutationWires().filter { $0.path == "reconciliation/checkpoints" }.count == 2)

        let dateTransport = F3ETransport(mode: .deterministicOnce)
        let dateChanged = await loadedModel(dateTransport)
        fillCheckpoint(dateChanged)
        await dateChanged.createCheckpoint()
        dateChanged.asOfDateText = "2026-08-15"
        #expect(dateChanged.hasFailedMutation && dateChanged.editorStep == 2)
        #expect(dateChanged.failedMutationRetryReasons.contains { $0.code == "mutation_intent_changed" })
        await dateChanged.retryDeterministicMutation()
        #expect(dateChanged.hasFailedMutation)
        #expect(await dateTransport.mutationWires().filter { $0.path == "reconciliation/checkpoints" }.count == 1)

        let targetTransport = F3ETransport(mode: .deterministicOnce)
        let targetChanged = await loadedModel(targetTransport)
        fillCheckpoint(targetChanged)
        await targetChanged.createCheckpoint()
        let accountB = try #require(targetChanged.accountTargets.first { $0.resourceID == V15F3EFixtures.accountB })
        await targetChanged.selectTarget(accountB)
        #expect(targetChanged.editorStep == 1 && !targetChanged.hasFailedMutation)
        #expect(targetChanged.failedMutationRetryReasons.contains { $0.code == "mutation_owner_mismatch" })
        await targetChanged.retryDeterministicMutation()
        #expect(await targetTransport.mutationWires().filter { $0.path == "reconciliation/checkpoints" }.count == 1)
    }

    @MainActor @Test("offline mode makes checkpoint and attention writes zero-wire")
    func offlineZeroWire() async throws {
        let transport = F3ETransport(mode: .normal)
        let model = await loadedModel(transport, offline: true)
        fillCheckpoint(model)
        await model.createCheckpoint()
        let item = try #require(model.attention.first { $0.sourceID == V15F3EFixtures.openCheckpoint })
        await model.ignore(item)
        #expect(await transport.mutationWires().isEmpty)
        #expect(model.checkpointReasons.contains { $0.code == "offline_read_only" })
        #expect(model.ignoreReasons(for: item).contains { $0.code == "offline_read_only" })
    }

    @MainActor @Test("accepted checkpoint refreshes list detail diagnosis and attention and partial retry is GET-only")
    func acceptedRefreshGate() async {
        let successTransport = F3ETransport(mode: .normal)
        let success = await loadedModel(successTransport)
        fillCheckpoint(success)
        await success.createCheckpoint()
        #expect(success.mutationPhase == .succeeded)
        #expect(success.selectedCheckpoint?.id == V15F3EFixtures.createdCheckpoint)
        let fresh = await successTransport.allRequests().filter { $0.method == "GET" && $0.readCachePolicy == .reloadIgnoringCache }
        #expect(fresh.contains { $0.path == "reconciliation/checkpoints" })
        #expect(fresh.contains { $0.path == "reconciliation/diagnosis" })
        #expect(fresh.contains { $0.path == "reconciliation/attention" })
        #expect(await successTransport.allRequests().contains { $0.path == "reconciliation/checkpoints/\(V15F3EFixtures.createdCheckpoint)" })

        let partialTransport = F3ETransport(mode: .refreshFailure)
        let partial = await loadedModel(partialTransport)
        fillCheckpoint(partial)
        await partial.createCheckpoint()
        #expect(partial.hasAcceptedRefreshGate)
        #expect(partial.factRefreshRetryReasons.isEmpty)
        let writes = await partialTransport.mutationWires()
        await partial.retryAcceptedRefresh()
        #expect(await partialTransport.mutationWires() == writes)
        #expect(partial.mutationPhase == .succeeded && !partial.hasAcceptedRefreshGate)
    }

    @MainActor @Test("remote field issues remain scoped until input changes and conflicts require fresh reload")
    func fieldIssuesAndConflict() async {
        let field = await loadedModel(F3ETransport(mode: .fieldError))
        fillCheckpoint(field)
        await field.createCheckpoint()
        #expect(Set(field.serverIssues.compactMap(\.fieldPath)) == ["actual_balance_minor", "note"])
        field.actualBalanceText = "1200.00"
        #expect(field.serverIssues.isEmpty)

        let conflict = await loadedModel(F3ETransport(mode: .conflict))
        fillCheckpoint(conflict)
        await conflict.createCheckpoint()
        if case .conflict(let value) = conflict.mutationPhase { #expect(value.latestRevision == 10) }
        else { Issue.record("expected server conflict") }
        await conflict.reloadAfterConflict()
        #expect(await conflict.masterPhase == .loaded)
    }

    @MainActor @Test("target and date generations reject stale A facts after B wins")
    func generationOwners() async throws {
        let transport = F3ETransport(mode: .selectionRace)
        let model = await loadedModel(transport)
        let accountA = try #require(model.accountTargets.first { $0.resourceID == V15F3EFixtures.accountA })
        let accountB = try #require(model.accountTargets.first { $0.resourceID == V15F3EFixtures.accountB })
        let slowA = Task { @MainActor in await model.selectTarget(accountA) }
        try await Task.sleep(for: .milliseconds(20))
        await model.selectTarget(accountB)
        await slowA.value
        #expect(model.selectedTarget?.resourceID == V15F3EFixtures.accountB)
        #expect(model.checkpoints.allSatisfy { $0.accountID == V15F3EFixtures.accountB })
        #expect(model.diagnosis?.accountID == V15F3EFixtures.accountB)

        await model.selectTarget(accountA)
        model.asOfDateText = "2026-08-14"
        try await Task.sleep(for: .milliseconds(20))
        model.asOfDateText = "2026-08-15"
        try await Task.sleep(for: .milliseconds(240))
        #expect(model.diagnosisPhase == .loaded)
        #expect(model.diagnosis.map { ShanghaiBusinessDate.string(for: $0.asOf) } == "2026-08-15")
    }

    @MainActor @Test("today diagnosis guard owns the date input instead of comparing two moving clock instants")
    func movingClockTodayDiagnosis() async {
        let clock = F3ETickingClock(base: fixedNow)
        let model = V15ReconciliationModel(services: V15Services(transport: F3ETransport(mode: .normal)), now: { clock.now() })
        await model.load()
        #expect(model.diagnosisPhase == .loaded)
        fillCheckpoint(model)
        await model.createCheckpoint()
        #expect(model.mutationPhase == .succeeded)
        #expect(!model.hasAcceptedRefreshGate)
    }
}
