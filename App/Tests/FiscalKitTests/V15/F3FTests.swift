import Foundation
import Testing
@testable import FiscalKit

@Suite("F3-F typed AI proposals")
struct F3FTests {
    @MainActor private func loaded(_ transport: F3FTransport = F3FTransport(mode: .normal), offline: Bool = false) async -> V15AIProposalModel {
        let model = V15AIProposalModel(services: V15Services(transport: transport), offlineSnapshotAt: offline ? Date(timeIntervalSince1970: 1_786_464_000) : nil)
        await model.load()
        return model
    }

    @Test("D3 settings are false-only and provider configuration cannot change the effective result")
    func settingsContract() throws {
        let decoder = V15FixtureCodec.decoder
        let safe = try decoder.decode(V15AISettings.self, from: Data(V15F3FFixtures.settings().utf8))
        #expect(safe.providerConfigured)
        #expect(!safe.autoExecuteEnabled)
        #expect(!safe.effectiveAutoExecute)
        do {
            _ = try decoder.decode(V15AISettings.self, from: Data(V15F3FFixtures.settings(autoExecute: true, effectiveAutoExecute: true).utf8))
            Issue.record("A D3 true response must be rejected as a typed contract violation")
        } catch let failure as V15Failure {
            #expect(failure.code == "ai_settings_contract_violation")
        }
    }

    @Test("Status, snapshots and quality events remain forward-readable but unknown state is display-only")
    @MainActor func forwardFacts() async throws {
        let proposal = try V15FixtureCodec.decoder.decode(V15AIProposal.self, from: Data(V15F3FFixtures.proposal(id: V15F3FFixtures.unknownID, status: "future_review").utf8))
        #expect(proposal.status == .unknown("future_review"))
        #expect(proposal.isDisplayOnly)
        #expect(proposal.initialParseSnapshot?["amount_minor"] == .integer(13_200))
        let model = await loaded()
        let reasons = model.actionReasons(.execute, proposal: proposal)
        #expect(reasons.contains { $0.code == "ai_unknown_read_only" })

        for status in ["processing", "pending", "executed", "failed", "ignored", "undone"] {
            let value = try V15FixtureCodec.decoder.decode(
                V15AIProposal.self,
                from: Data(V15F3FFixtures.proposal(id: UUID(), status: status, missing: []).utf8)
            )
            #expect(!value.status.rawValue.isEmpty)
            #expect(!value.isDisplayOnly)
        }
    }

    @Test("Service wires use the authoritative page, nested draft and undo version shapes")
    @MainActor func authoritativeWires() async throws {
        let transport = F3FTransport(mode: .normal)
        let services = V15Services(transport: transport)
        _ = try await services.ai.proposals(status: .pending, cursor: "opaque", limit: 20)
        _ = try await services.ai.qualityEvents(proposalID: V15F3FFixtures.pendingID)
        let draft = V15TransactionCreateRequest(kind: .expense, amountMinor: 13_200, occurredAt: Date(timeIntervalSince1970: 1_786_854_600), title: "人工确认", accountID: V15F3FFixtures.cashAccountID)
        _ = try await services.ai.replace(id: V15F3FFixtures.pendingID, request: .init(draft: draft, expectedVersion: 2))
        _ = try await services.ai.undo(id: V15F3FFixtures.executedID, expectedVersion: 5, expectedTransactionVersion: 3)
        try await services.ai.delete(id: V15F3FFixtures.failedID, expectedVersion: 2)
        let requests = await transport.allRequests()
        let page = try #require(requests.first)
        #expect(page.query.contains(.init(name: "status", value: "pending")))
        #expect(page.query.contains(.init(name: "cursor", value: "opaque")))
        let wires = await transport.mutationWires()
        let replace = try #require(wires.first { $0.method == "PUT" })
        let body = try #require(try JSONSerialization.jsonObject(with: Data(replace.body.utf8)) as? [String: Any])
        #expect(body["expected_version"] as? Int == 2)
        #expect((body["draft"] as? [String: Any])?["amount_minor"] as? Int == 13_200)
        let undo = try #require(wires.first { $0.path.hasSuffix("/undo") })
        let undoBody = try #require(try JSONSerialization.jsonObject(with: Data(undo.body.utf8)) as? [String: Any])
        #expect(undoBody["expected_version"] as? Int == 5)
        #expect(undoBody["expected_transaction_version"] as? Int == 3)
        let delete = try #require(wires.first { $0.method == "DELETE" })
        #expect(delete.path == "ai/proposals/\(V15F3FFixtures.failedID)")
        #expect(delete.query == ["expected_version": "2"])
        #expect(delete.body.isEmpty)
    }

    @Test("Create installs one immutable key and unknown recovery reuses that exact key and body")
    @MainActor func stableCreateRecovery() async {
        let transport = F3FTransport(mode: .createUnknown)
        let model = await loaded(transport)
        model.inputText = "午餐 132 元"
        await model.create()
        #expect(model.hasUnknownCreate)
        model.inputText = "这段新文字不得替换已发送请求"
        await model.retryUnknownCreate()
        let wires = await transport.mutationWires().filter { $0.path == "ai/proposals" }
        #expect(wires.count == 2)
        #expect(wires[0].headers["Idempotency-Key"] == wires[1].headers["Idempotency-Key"])
        #expect(wires[0].body == wires[1].body)
        #expect(model.selectedProposal?.id == V15F3FFixtures.createdID)
    }

    @Test("Stable create recovery survives owner restoration and only replays after a fresh safe settings read")
    @MainActor func stableCreateRecoverySettingsGateAndOwnerIsolation() async throws {
        let transport = F3FTransport(mode: .createUnknownSettingsTransportAfterSafe)
        let model = await loaded(transport)
        let ownerA = try #require(model.selectedProposal)
        let ownerB = try #require(model.proposals.first { $0.id == V15F3FFixtures.failedID })
        model.inputText = "午餐 132 元"
        await model.create()
        #expect(model.hasStableCreateRecovery)
        #expect(model.hasUnknownCreate)
        let firstWire = try #require((await transport.mutationWires()).first)

        await model.select(ownerB)
        #expect(model.selectedProposal?.id == ownerB.id)
        #expect(model.hasStableCreateRecovery)
        await model.select(ownerA)
        #expect(model.selectedProposal?.id == ownerA.id)
        #expect(model.hasUnknownCreate)

        await model.load()
        #expect(model.hasStableCreateRecovery)
        #expect(model.unknownCreateRetryReasons.contains { $0.code == "ai_settings_unavailable" })
        let wiresBeforeBlockedRetry = await transport.mutationWires().count
        await model.retryUnknownCreate()
        #expect((await transport.mutationWires()).count == wiresBeforeBlockedRetry)

        await model.load()
        #expect(model.unknownCreateRetryReasons.isEmpty)
        async let firstRetry: Void = model.retryUnknownCreate()
        async let duplicateRetry: Void = model.retryUnknownCreate()
        _ = await (firstRetry, duplicateRetry)
        let wires = await transport.mutationWires()
        #expect(wires.count == 2)
        #expect(firstWire.headers["Idempotency-Key"] == wires[1].headers["Idempotency-Key"])
        #expect(firstWire.body == wires[1].body)
        #expect(!model.hasStableCreateRecovery)
    }

    @Test("D3-sticky settings never authorize stable replay and abandon only clears the local attempt")
    @MainActor func stableCreateRecoveryD3StickyAbandon() async {
        let transport = F3FTransport(mode: .createUnknownSettingsViolationAfterSafe)
        let model = await loaded(transport)
        model.inputText = "午餐 132 元"
        await model.create()
        let writesBefore = await transport.mutationWires().count
        await model.load()
        await model.load()
        #expect(model.hasStableCreateRecovery)
        #expect(model.unknownCreateRetryReasons.contains { $0.code == "ai_d3_contract_violation" })
        await model.retryUnknownCreate()
        #expect((await transport.mutationWires()).count == writesBefore)
        #expect(model.unknownCreateAbandonReasons.isEmpty)
        model.abandonUnknownCreate()
        #expect(!model.hasStableCreateRecovery)
        #expect(model.settingsSafetyReason?.code == "ai_d3_contract_violation")
        #expect(model.createReasons.contains { $0.code == "ai_d3_contract_violation" })
        #expect((await transport.mutationWires()).count == writesBefore)
    }

    @Test("Human save is required before execute and the server version advances between writes")
    @MainActor func editThenExecute() async throws {
        let transport = F3FTransport(mode: .normal)
        let model = await loaded(transport)
        let proposal = try #require(model.selectedProposal)
        #expect(model.actionReasons(.execute, proposal: proposal).contains { $0.code == "ai_human_confirmation_required" })
        model.openReview(proposal)
        model.categoryID = V15F3FFixtures.expenseCategoryID
        await model.confirmDraft()
        #expect(model.reviewConfirmed)
        #expect(model.selectedProposal?.version == 3)
        await model.execute()
        #expect(model.selectedProposal?.status == .executed)
        let wires = await transport.mutationWires()
        #expect(wires.map(\.method) == ["PUT", "POST"])
        let executeBody = try #require(try JSONSerialization.jsonObject(with: Data(wires[1].body.utf8)) as? [String: Any])
        #expect(executeBody["expected_version"] as? Int == 3)
        #expect(wires[1].headers["Idempotency-Key"] == nil)
    }

    @Test("Ignore, retry and undo use status-specific exact versions")
    @MainActor func lifecycleActions() async throws {
        let ignoreTransport = F3FTransport(mode: .normal)
        let ignoreModel = await loaded(ignoreTransport)
        await ignoreModel.ignore()
        #expect(ignoreModel.selectedProposal?.status == .ignored)

        let retryTransport = F3FTransport(mode: .normal)
        let retryModel = await loaded(retryTransport)
        let failed = try #require(retryModel.proposals.first { $0.id == V15F3FFixtures.failedID })
        await retryModel.select(failed); await retryModel.retryParsing()
        #expect(retryModel.selectedProposal?.status == .pending)

        let undoTransport = F3FTransport(mode: .normal)
        let undoModel = await loaded(undoTransport)
        let executed = try #require(undoModel.proposals.first { $0.id == V15F3FFixtures.executedID })
        await undoModel.select(executed); await undoModel.undo()
        #expect(undoModel.selectedProposal?.status == .undone)
        let body = try #require(await undoTransport.mutationWires().last?.body)
        #expect(body.contains("expected_transaction_version"))
    }

    @Test("Only unposted pending, failed and ignored proposals allow permanent deletion")
    @MainActor func deletionPolicy() async throws {
        let model = await loaded()
        for status in ["pending", "failed", "ignored"] {
            let proposal = try V15FixtureCodec.decoder.decode(V15AIProposal.self, from: Data(V15F3FFixtures.proposal(id: UUID(), status: status, missing: []).utf8))
            #expect(model.actionReasons(.delete, proposal: proposal).isEmpty)
        }
        for status in ["processing", "executed", "undone", "future_review"] {
            let proposal = try V15FixtureCodec.decoder.decode(V15AIProposal.self, from: Data(V15F3FFixtures.proposal(id: UUID(), status: status, missing: [], transaction: status == "executed").utf8))
            #expect(!model.actionReasons(.delete, proposal: proposal).isEmpty)
        }
    }

    @Test("Confirmed deletion sends once, updates the queue and selects the adjacent item")
    @MainActor func deleteUpdatesQueueExactlyOnce() async throws {
        let transport = F3FTransport(mode: .normal)
        let model = await loaded(transport)
        let deletedID = try #require(model.selectedProposal?.id)
        let initialCount = model.proposals.count
        let initialPendingCount = model.pendingCount

        async let first: Void = model.deleteSelected()
        async let duplicate: Void = model.deleteSelected()
        _ = await (first, duplicate)

        #expect(!model.proposals.contains { $0.id == deletedID })
        #expect(model.proposals.count == initialCount - 1)
        #expect(model.pendingCount == initialPendingCount - 1)
        #expect(model.selectedProposal?.id == V15F3FFixtures.failedID)
        #expect(model.mutationPhase == .succeeded("这项未记账内容已删除。"))
        #expect(await transport.mutationWires().filter { $0.method == "DELETE" }.count == 1)
    }

    @Test("Unknown delete outcome is confirmed by a fresh not-found read without resending")
    @MainActor func unknownDeleteReadback() async throws {
        let transport = F3FTransport(mode: .deleteUnknown)
        let model = await loaded(transport)
        let deletedID = try #require(model.selectedProposal?.id)
        await model.deleteSelected()
        #expect(model.hasUnknownDirect)
        #expect(model.writeLocked)
        await model.recoverUnknownDirect()
        #expect(!model.proposals.contains { $0.id == deletedID })
        #expect(!model.hasUnknownDirect)
        #expect(await transport.mutationWires().filter { $0.method == "DELETE" }.count == 1)
    }

    @Test("Ordinary refresh resolves an unknown completed delete without orphaning its write lock")
    @MainActor func unknownDeleteOrdinaryRefreshConfirmsAbsence() async throws {
        let transport = F3FTransport(mode: .deleteUnknown)
        let model = await loaded(transport)
        let deletedID = try #require(model.selectedProposal?.id)
        await model.deleteSelected()
        #expect(model.hasUnknownDirect)

        await model.load()

        #expect(!model.proposals.contains { $0.id == deletedID })
        #expect(!model.writeLocked)
        #expect(!model.hasUnknownDirect)
        #expect(model.selectedProposal?.id == V15F3FFixtures.failedID)
        #expect(await transport.mutationWires().filter { $0.method == "DELETE" }.count == 1)
    }

    @Test("Ordinary refresh keeps the unknown owner visible when the delete did not arrive")
    @MainActor func unknownDeleteOrdinaryRefreshStillPresent() async throws {
        let transport = F3FTransport(mode: .deleteUnknownStillPresent)
        let model = await loaded(transport)
        let owner = try #require(model.selectedProposal)
        await model.deleteSelected()

        await model.load()

        #expect(model.selectedProposal?.id == owner.id)
        #expect(model.proposals.contains { $0.id == owner.id })
        #expect(model.writeLocked)
        #expect(model.hasUnknownDirect)
        #expect(model.readbackCompleted)
        #expect(model.recoveryMessage?.contains("仍然存在") == true)
        #expect(await transport.mutationWires().filter { $0.method == "DELETE" }.count == 1)
    }

    @Test("Ordinary refresh keeps a retryable recovery surface when delete readback fails")
    @MainActor func unknownDeleteOrdinaryRefreshReadFailure() async throws {
        let transport = F3FTransport(mode: .deleteUnknownReadFailure)
        let model = await loaded(transport)
        let owner = try #require(model.selectedProposal)
        await model.deleteSelected()

        await model.load()

        #expect(model.selectedProposal?.id == owner.id)
        #expect(model.writeLocked)
        #expect(model.hasUnknownDirect)
        #expect(!model.readbackCompleted)
        #expect(model.recoveryMessage?.contains("检查最新状态失败") == true)
        #expect(await transport.mutationWires().filter { $0.method == "DELETE" }.count == 1)

        await model.load()
        #expect(!model.writeLocked)
        #expect(!model.hasUnknownDirect)
        #expect(await transport.mutationWires().filter { $0.method == "DELETE" }.count == 1)
    }

    @Test("Failed delete readback keeps the lock until a later fresh read confirms deletion")
    @MainActor func unknownDeleteReadbackFailureRetainsLock() async throws {
        let transport = F3FTransport(mode: .deleteUnknownReadFailure)
        let model = await loaded(transport)
        let deletedID = try #require(model.selectedProposal?.id)
        await model.deleteSelected()
        await model.recoverUnknownDirect()
        #expect(model.hasUnknownDirect)
        #expect(model.writeLocked)
        #expect(!model.readbackCompleted)
        await model.recoverUnknownDirect()
        #expect(!model.proposals.contains { $0.id == deletedID })
        #expect(!model.hasUnknownDirect)
        #expect(await transport.mutationWires().filter { $0.method == "DELETE" }.count == 1)
    }

    @Test("Delete conflict requires a fresh read and never automatically retries the mutation")
    @MainActor func deleteConflictReadback() async throws {
        let transport = F3FTransport(mode: .conflict)
        let model = await loaded(transport)
        await model.deleteSelected()
        guard case .conflict = model.mutationPhase else { Issue.record("Expected conflict"); return }
        await model.reloadConflict()
        #expect(model.mutationPhase == .idle)
        #expect(model.selectedProposal?.id == V15F3FFixtures.pendingID)
        #expect(await transport.mutationWires().filter { $0.method == "DELETE" }.count == 1)
    }

    @Test("No-key response unknown requires fresh GET and never resends or claims attribution")
    @MainActor func unknownDirectReadback() async throws {
        let transport = F3FTransport(mode: .directUnknown)
        let model = await loaded(transport)
        let proposal = try #require(model.selectedProposal)
        model.openReview(proposal)
        model.categoryID = V15F3FFixtures.expenseCategoryID
        await model.confirmDraft()
        #expect(model.hasUnknownDirect)
        #expect(!model.readbackCompleted)
        await model.recoverUnknownDirect()
        #expect(model.readbackCompleted)
        #expect(model.recoveryMessage?.contains("仍无法确认是否由本次操作造成") == true)
        #expect(await transport.mutationWires().count == 1)
        model.abandonUnknownDirect()
        #expect(!model.hasUnknownDirect)
        #expect(await transport.mutationWires().count == 1)
    }

    @Test("No-key fresh GET failure retains the owner-scoped unknown lock until a successful retry")
    @MainActor func unknownDirectReadbackFailureRetainsLock() async throws {
        let transport = F3FTransport(mode: .directUnknownReadFailure)
        let model = await loaded(transport)
        let a = try #require(model.selectedProposal)
        model.openReview(a); model.categoryID = V15F3FFixtures.expenseCategoryID
        await model.confirmDraft()
        #expect(model.hasUnknownDirect)
        await model.recoverUnknownDirect()
        #expect(model.hasUnknownDirect)
        #expect(!model.readbackCompleted)
        #expect(model.recoveryMessage?.contains("检查最新状态失败") == true)
        #expect(model.writeLocked)
        await model.recoverUnknownDirect()
        #expect(model.readbackCompleted)
        #expect(await transport.mutationWires().count == 1)
    }

    @Test("Conflict reload failure remains a conflict and can retry its GET-only gate")
    @MainActor func conflictReloadFailureRetainsGate() async throws {
        let transport = F3FTransport(mode: .conflictReloadFailure)
        let model = await loaded(transport)
        let proposal = try #require(model.selectedProposal)
        model.openReview(proposal); model.categoryID = V15F3FFixtures.expenseCategoryID
        await model.confirmDraft(); await model.reloadConflict()
        guard case .conflict = model.mutationPhase else { Issue.record("conflict gate must survive failed reload"); return }
        #expect(model.writeLocked)
        await model.reloadConflict()
        #expect(model.mutationPhase == .idle)
        #expect(await transport.mutationWires().count == 1)
    }

    @Test("Cash-flow target uses the p8 replacement wire but reviews a planned cash-flow fact")
    @MainActor func cashFlowTargetReviewAndExecute() async throws {
        let transport = F3FTransport(mode: .cashFlow)
        let model = await loaded(transport)
        let proposal = try #require(model.selectedProposal)
        #expect(proposal.target == .cashFlow)
        model.openReview(proposal); model.categoryID = V15F3FFixtures.expenseCategoryID
        await model.confirmDraft()
        #expect(model.reviewConfirmed)
        await model.execute()
        #expect(model.selectedProposal?.status == .executed)
        #expect(model.selectedProposal?.cashFlowItemID == V15F3FFixtures.cashFlowItemID)
        let replace = try #require(await transport.mutationWires().first)
        #expect(replace.method == "PUT")
        #expect(replace.body.contains("\"draft\""))
        #expect(!replace.body.contains("planned_amount_minor"))
    }

    @Test("Kind changes clear incompatible references and owner state restores after A to B to A")
    @MainActor func kindAndOwnerIsolation() async throws {
        let transport = F3FTransport(mode: .directUnknown)
        let model = await loaded(transport)
        let a = try #require(model.selectedProposal)
        let b = try #require(model.proposals.first { $0.id == V15F3FFixtures.failedID })
        model.openReview(a); model.categoryID = V15F3FFixtures.expenseCategoryID
        model.kind = .transfer
        #expect(model.categoryID == nil)
        #expect(model.destinationAccountID == nil)
        model.kind = .repayment
        #expect(model.creditCycleID == nil)
        model.kind = .expense; model.categoryID = V15F3FFixtures.expenseCategoryID
        await model.confirmDraft()
        #expect(model.hasUnknownDirect)
        await model.select(b)
        #expect(model.selectedProposal?.id == b.id)
        #expect(!model.hasUnknownDirect)
        await model.select(a)
        #expect(model.hasUnknownDirect)
        #expect(model.writeLocked)
    }

    @Test("Confirmation is the exact returned server version and draft, not merely the proposal ID")
    @MainActor func confirmationIdentityInvalidatesOnFreshServerChange() async throws {
        let transport = F3FTransport(mode: .serverChanged)
        let model = await loaded(transport)
        let original = try #require(model.selectedProposal)
        model.openReview(original); model.categoryID = V15F3FFixtures.expenseCategoryID
        await model.confirmDraft()
        #expect(model.reviewConfirmed)
        #expect(model.actionReasons(.execute, proposal: try #require(model.selectedProposal)).isEmpty)

        await model.select(try #require(model.selectedProposal))
        let changed = try #require(model.selectedProposal)
        #expect(changed.version == 9)
        #expect(model.actionReasons(.execute, proposal: changed).contains { $0.code == "ai_human_confirmation_required" })
        await model.execute()
        #expect((await transport.mutationWires()).count == 1)
    }

    @Test("Fresh selection and dismissal invalidate confirmation even when the server fact is unchanged")
    @MainActor func confirmationIdentityInvalidatesOnSelectionAndDismissal() async throws {
        let transport = F3FTransport(mode: .normal)
        let model = await loaded(transport)
        let proposal = try #require(model.selectedProposal)
        model.openReview(proposal); model.categoryID = V15F3FFixtures.expenseCategoryID
        await model.confirmDraft()
        await model.select(try #require(model.selectedProposal))
        #expect(!model.reviewConfirmed)
        #expect(model.actionReasons(.execute, proposal: try #require(model.selectedProposal)).contains { $0.code == "ai_human_confirmation_required" })
        await model.execute()
        #expect((await transport.mutationWires()).count == 1)
        model.openReview(try #require(model.selectedProposal)); model.categoryID = V15F3FFixtures.expenseCategoryID
        await model.confirmDraft()
        model.dismissEditor()
        #expect(model.actionReasons(.execute, proposal: try #require(model.selectedProposal)).contains { $0.code == "ai_human_confirmation_required" })
    }

    @Test("Exact unchanged server response can execute without selection, but canonical title and note own the wire identity")
    @MainActor func canonicalDraftConfirmationAndExecution() async throws {
        let transport = F3FTransport(mode: .normal)
        let model = await loaded(transport)
        let proposal = try #require(model.selectedProposal)
        model.openReview(proposal)
        model.title = "  人工确认工作餐  "
        model.note = "  保留这条备注  "
        await model.confirmDraft()
        #expect(model.reviewConfirmed)
        #expect(model.actionReasons(.execute, proposal: try #require(model.selectedProposal)).isEmpty)
        let replace = try #require((await transport.mutationWires()).first)
        #expect(replace.body.contains("\"title\":\"人工确认工作餐\""))
        #expect(replace.body.contains("\"note\":\"保留这条备注\""))
        await model.execute()
        #expect((await transport.mutationWires()).count == 2)
    }

    @Test("Whitespace-only notes canonicalize to nil and never produce a different confirmation wire")
    @MainActor func whitespaceNoteCanonicalizesToNil() async throws {
        let transport = F3FTransport(mode: .normal)
        let model = await loaded(transport)
        let proposal = try #require(model.selectedProposal)
        model.openReview(proposal)
        model.note = " \n\t "
        await model.confirmDraft()
        #expect(model.reviewConfirmed)
        let replace = try #require((await transport.mutationWires()).first)
        #expect(!replace.body.contains("\"note\":"))
    }

    @Test("Readback is owner single-flight and a deterministic failure remains on its owner")
    @MainActor func ownerReadbackAndFailureIsolation() async throws {
        let unknownTransport = F3FTransport(mode: .directUnknownReadDelayed)
        let unknown = await loaded(unknownTransport)
        let a = try #require(unknown.selectedProposal)
        unknown.openReview(a); unknown.categoryID = V15F3FFixtures.expenseCategoryID
        await unknown.confirmDraft()
        let getsBefore = await unknownTransport.allRequests().filter { $0.method == "GET" && $0.path == "ai/proposals/\(a.id)" }.count
        async let first: Void = unknown.recoverUnknownDirect()
        try await Task.sleep(for: .milliseconds(20))
        async let second: Void = unknown.recoverUnknownDirect()
        await first; await second
        let getsAfter = await unknownTransport.allRequests().filter { $0.method == "GET" && $0.path == "ai/proposals/\(a.id)" }.count
        #expect(getsAfter == getsBefore + 1)
        #expect(unknown.readbackCompleted)

        let failureTransport = F3FTransport(mode: .fieldError)
        let failure = await loaded(failureTransport)
        let ownerA = try #require(failure.selectedProposal)
        let ownerB = try #require(failure.proposals.first { $0.id == V15F3FFixtures.failedID })
        failure.openReview(ownerA); failure.categoryID = V15F3FFixtures.expenseCategoryID
        await failure.confirmDraft()
        guard case .failed = failure.mutationPhase else { Issue.record("owner A must retain its deterministic failure"); return }
        await failure.select(ownerB)
        #expect(failure.serverIssues.isEmpty)
        await failure.select(ownerA)
        guard case .failed = failure.mutationPhase else { Issue.record("A failure must restore after B selection"); return }
        #expect(failure.serverIssues.contains { $0.code == "category_required" })
        failure.openReview(ownerA)
        #expect(!failure.writeLocked)
    }

    @Test("Hidden stale shape fields block every invalid transaction wire, including cash-flow compatibility drafts")
    @MainActor func staleShapeFieldsEmitZeroMutationWires() async throws {
        let transactionTransport = F3FTransport(mode: .normal)
        let transaction = await loaded(transactionTransport)
        let proposal = try #require(transaction.selectedProposal)
        transaction.openReview(proposal)
        transaction.destinationAccountID = V15F3FFixtures.destinationID
        transaction.creditCycleID = V15F3FFixtures.cycleID
        #expect(transaction.confirmReasons.contains { $0.code == "destination_not_allowed" })
        #expect(transaction.confirmReasons.contains { $0.code == "credit_cycle_not_allowed" })
        await transaction.confirmDraft()
        #expect((await transactionTransport.mutationWires()).isEmpty)

        let cashTransport = F3FTransport(mode: .cashFlow)
        let cash = await loaded(cashTransport)
        let cashProposal = try #require(cash.selectedProposal)
        cash.openReview(cashProposal)
        cash.kind = .transfer
        cash.categoryID = V15F3FFixtures.expenseCategoryID
        cash.creditCycleID = V15F3FFixtures.cycleID
        #expect(cash.confirmReasons.contains { $0.code == "category_not_allowed" })
        #expect(cash.confirmReasons.contains { $0.code == "credit_cycle_not_allowed" })
        await cash.confirmDraft()
        #expect((await cashTransport.mutationWires()).isEmpty)
    }

    @Test("Offline state emits zero writes and every button exposes the same model reasons")
    @MainActor func offlineZeroWire() async {
        let transport = F3FTransport(mode: .normal)
        let model = await loaded(transport, offline: true)
        model.inputText = "午餐 132 元"
        #expect(model.createReasons.contains { $0.code == "offline_read_only" })
        await model.create()
        if let proposal = model.selectedProposal {
            #expect(model.actionReasons(.ignore, proposal: proposal).contains { $0.code == "offline_read_only" })
            #expect(model.actionReasons(.delete, proposal: proposal).contains { $0.code == "offline_read_only" })
            await model.ignore()
            await model.deleteSelected()
        }
        #expect(await transport.mutationWires().isEmpty)
    }

    @Test("Conflict retains the immutable attempt until a cache-bypassing reload")
    @MainActor func conflictReloadGate() async throws {
        let transport = F3FTransport(mode: .conflict)
        let model = await loaded(transport)
        let proposal = try #require(model.selectedProposal)
        model.openReview(proposal); model.categoryID = V15F3FFixtures.expenseCategoryID
        await model.confirmDraft()
        guard case .conflict = model.mutationPhase else { Issue.record("Expected conflict"); return }
        await model.reloadConflict()
        #expect(model.mutationPhase == .idle)
        let request = await transport.allRequests().last
        #expect(request?.readCachePolicy == .reloadIgnoringCache)
    }

    @Test("Selection A/B and page reload races cannot restore stale ownership")
    @MainActor func generationRaces() async throws {
        let selectionTransport = F3FTransport(mode: .selectionRace)
        let selectionModel = await loaded(selectionTransport)
        let a = try #require(selectionModel.proposals.first { $0.id == V15F3FFixtures.pendingID })
        let b = try #require(selectionModel.proposals.first { $0.id == V15F3FFixtures.failedID })
        async let selectA: Void = selectionModel.select(a)
        try await Task.sleep(for: .milliseconds(20))
        await selectionModel.select(b)
        _ = await selectA
        #expect(selectionModel.selectedProposal?.id == b.id)

        let pageTransport = F3FTransport(mode: .pageRace)
        let pageModel = await loaded(pageTransport)
        async let oldPage: Void = pageModel.loadNextPage()
        try await Task.sleep(for: .milliseconds(20))
        await pageModel.load()
        _ = await oldPage
        #expect(pageModel.nextCursor == "f3f-next")
        #expect(pageModel.proposals.count == 4)
    }

    @Test("A later D3 settings violation clears trusted review state and locks every mutation for this session")
    @MainActor func laterSettingsViolationFailsClosed() async throws {
        let transport = F3FTransport(mode: .settingsViolationAfterSafe)
        let model = await loaded(transport)
        let pending = try #require(model.selectedProposal)
        model.openReview(pending); model.categoryID = V15F3FFixtures.expenseCategoryID
        await model.confirmDraft()
        #expect(model.reviewConfirmed)
        let writesBeforeViolation = await transport.mutationWires().count

        await model.load()
        #expect(model.settings == nil)
        #expect(model.settingsContractViolation?.code == "ai_settings_contract_violation")
        #expect(!model.reviewConfirmed)
        #expect(model.settingsSafetyReason?.code == "ai_d3_contract_violation")
        #expect(model.confirmReasons.contains { $0.code == "ai_d3_contract_violation" })
        #expect(model.actionReasons(.execute, proposal: try #require(model.selectedProposal)).contains { $0.code == "ai_d3_contract_violation" })

        model.inputText = "不得建立"
        await model.create()
        await model.confirmDraft()
        await model.execute()
        await model.ignore()
        let failed = try #require(model.proposals.first { $0.id == V15F3FFixtures.failedID })
        await model.select(failed); await model.retryParsing()
        let executed = try #require(model.proposals.first { $0.id == V15F3FFixtures.executedID })
        await model.select(executed); await model.undo()
        #expect((await transport.mutationWires()).count == writesBeforeViolation)

        await model.load()
        #expect(model.settings == nil)
        #expect(model.settingsContractViolation?.code == "ai_settings_contract_violation")
        #expect((await transport.mutationWires()).count == writesBeforeViolation)
    }

    @Test("Settings transport failure also clears stale settings, while only typed D3 errors become sticky violations")
    @MainActor func settingsFailureAndTypedViolationClassification() async throws {
        let transport = F3FTransport(mode: .settingsTransportAfterSafe)
        let model = await loaded(transport)
        await model.load()
        #expect(model.settings == nil)
        #expect(model.settingsContractViolation == nil)
        #expect(model.createReasons.contains { $0.code == "ai_settings_unavailable" })
        model.inputText = "不得建立"
        await model.create()
        #expect(await transport.mutationWires().isEmpty)

        for settings in [
            V15F3FFixtures.settings(autoExecute: true),
            V15F3FFixtures.settings(effectiveAutoExecute: true)
        ] {
            do {
                _ = try V15FixtureCodec.decoder.decode(V15AISettings.self, from: Data(settings.utf8))
                Issue.record("false-only settings must reject either true field")
            } catch let failure as V15Failure {
                #expect(failure.code == "ai_settings_contract_violation")
            }
        }
        do {
            _ = try V15FixtureCodec.decoder.decode(V15AISettings.self, from: Data("{\"auto_execute_enabled\":false}".utf8))
            Issue.record("ordinary malformed JSON must still fail")
        } catch let failure as V15Failure {
            Issue.record("ordinary JSON decode must not be labelled D3: \(failure)")
        } catch { }
    }

    @Test("Unknown attempts survive the D3 gate only for GET recovery and old safe loads cannot unlock it")
    @MainActor func settingsViolationPreservesReadOnlyRecoveryAndWinsRaces() async throws {
        let directTransport = F3FTransport(mode: .directUnknownSettingsViolationAfterSafe)
        let direct = await loaded(directTransport)
        let proposal = try #require(direct.selectedProposal)
        direct.openReview(proposal); direct.categoryID = V15F3FFixtures.expenseCategoryID
        await direct.confirmDraft()
        #expect(direct.hasUnknownDirect)
        let writesBefore = await directTransport.mutationWires().count
        await direct.load()
        #expect(direct.hasUnknownDirect)
        #expect(direct.settingsSafetyReason?.code == "ai_d3_contract_violation")
        let readsBefore = await directTransport.allRequests().filter { $0.method == "GET" && $0.path == "ai/proposals/\(proposal.id)" }.count
        await direct.recoverUnknownDirect()
        let readsAfter = await directTransport.allRequests().filter { $0.method == "GET" && $0.path == "ai/proposals/\(proposal.id)" }.count
        #expect(readsAfter == readsBefore + 1)
        #expect((await directTransport.mutationWires()).count == writesBefore)

        let createTransport = F3FTransport(mode: .createUnknownSettingsViolationAfterSafe)
        let create = await loaded(createTransport)
        create.inputText = "未知新建"
        await create.create()
        #expect(create.hasUnknownCreate)
        let createWrites = await createTransport.mutationWires().count
        await create.load()
        await create.retryUnknownCreate()
        #expect((await createTransport.mutationWires()).count == createWrites)

        let raceTransport = F3FTransport(mode: .settingsViolationRace)
        let race = V15AIProposalModel(services: V15Services(transport: raceTransport))
        async let oldSafe: Void = race.load()
        try await Task.sleep(for: .milliseconds(20))
        await race.load()
        _ = await oldSafe
        #expect(race.settings == nil)
        #expect(race.settingsContractViolation?.code == "ai_settings_contract_violation")
    }

    @Test("Settings contract violation fails the whole surface and leaves writes locked")
    @MainActor func settingsViolation() async {
        let transport = F3FTransport(mode: .settingsViolation)
        let model = await loaded(transport)
        guard case .failed(let failure) = model.phase else { Issue.record("Expected typed D3 failure"); return }
        #expect(failure.kind == .decoding)
        model.inputText = "不得发送"
        #expect(model.createReasons.contains { $0.code == "ai_d3_contract_violation" })
        await model.create()
        #expect(await transport.mutationWires().isEmpty)
    }
}
