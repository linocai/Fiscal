import Foundation
import Testing
@testable import FiscalKit

@Suite("F3-C typed reimbursement lifecycle")
struct F3CTests {
    private let fixedNow = ISO8601DateFormatter().date(from: "2026-08-15T15:00:00Z")!

    @MainActor private func loadedModel(_ transport: F3CTransport = F3CTransport(mode: .normal), offline: Bool = false) async -> V15ReimbursementModel {
        let services = V15Services(transport: transport)
        let model = V15ReimbursementModel(services: services, offlineSnapshotAt: offline ? fixedNow : nil, now: { fixedNow })
        await model.load()
        return model
    }

    @MainActor private func fillClaim(_ model: V15ReimbursementModel) {
        model.claimTitle = "八月差旅报销"
        model.partyName = "示例公司"
        if let candidate = model.candidates.first(where: { $0.transactionID == V15F3CFixtures.candidateID }) { model.chooseCandidate(candidate) }
        model.expectedDateText = "2026-08-20"
    }

    @Test("candidate preserves nullable category and every authoritative eligibility amount")
    func candidateDecode() throws {
        let page = try V15FixtureCodec.decoder.decode(V15Page<V15ReimbursementCandidate>.self, from: Data(V15F3CFixtures.candidates.utf8))
        let candidate = try #require(page.items.first)
        #expect(candidate.categoryID == nil)
        #expect(candidate.eligibility.eligible)
        #expect(candidate.eligibility.transactionID == candidate.transactionID)
        #expect(candidate.canonicalAmountMinor == 30_000)
        #expect(candidate.allocatedMinor == 0)
        #expect(candidate.availableMinor == 30_000)
        let disabled = try #require(page.items.last)
        #expect(!disabled.eligibility.eligible)
        #expect(disabled.eligibility.reasons == ["fully_allocated"])
        #expect(disabled.eligibility.reasonDetails.first?.fieldPath == "amount_minor")
    }

    @Test("six closed claim states decode and a future state remains display-only")
    func claimStatuses() throws {
        let raws = ["draft", "pending", "partial_received", "received", "cancelled", "partially_received_cancelled", "future_server_state"]
        let expected: [V15ReimbursementClaimStatus] = [.draft, .pending, .partialReceived, .received, .cancelled, .partiallyReceivedCancelled, .unknown("future_server_state")]
        let decoded = try raws.map { raw in
            try V15FixtureCodec.decoder.decode(V15ReimbursementClaim.self, from: Data(V15F3CFixtures.claim(status: raw).utf8)).status
        }
        #expect(decoded == expected)
        #expect(decoded.last?.isKnown == false)
        #expect(decoded.last?.displayName == "暂时无法识别")
    }

    @Test("validation arrays and domain reason objects preserve exact field paths")
    func fieldPathMapping() {
        let array = APIErrorDetail(code: "validation_error", message: "字段错误", details: .array([
            .object(["loc": .array([.string("body"), .string("parties"), .integer(0), .string("allocations"), .integer(0), .string("amount_minor")]), "msg": .string("金额不可用")])
        ]), requestID: "f3c-a")
        #expect(V15ErrorMapper.map(.domain(status: 422, detail: array)).fieldIssues.first?.fieldPath == "parties[0].allocations[0].amount_minor")
        let object = APIErrorDetail(code: "account_inactive", message: "账户不可用", details: .object(["reason": .string("account_inactive"), "field_path": .string("destination_account_id")]), requestID: "f3c-b")
        let issue = V15ErrorMapper.map(.domain(status: 422, detail: object)).fieldIssues.first
        #expect(issue == .init(code: "account_inactive", message: "账户不可用", fieldPath: "destination_account_id"))
    }

    @MainActor @Test("typed service emits exact filters, four preview-commit pairs, keys, tokens and keyless direct bodies")
    func typedServiceWires() async throws {
        let transport = F3CTransport(mode: .normal)
        let service = V15Services(transport: transport).reimbursements
        _ = try await service.claims(status: .partialReceived, query: "差旅", expenseTransactionID: V15F3CFixtures.candidateID, includeArchived: true, includeVoided: true, cursor: "opaque", limit: 44)
        _ = try await service.candidates(query: "酒店", dateFrom: "2026-08-01", dateTo: "2026-08-15", cursor: "candidate-opaque", limit: 31)

        let claim = try V15FixtureCodec.decoder.decode(V15ReimbursementClaim.self, from: Data(V15F3CFixtures.claim().utf8))
        let receipt = try V15FixtureCodec.decoder.decode(V15ReimbursementReceipt.self, from: Data(V15F3CFixtures.receipt().utf8))
        let parties = claim.parties.map { party in V15ReimbursementPartyDraft(id: party.id, name: party.name, expectedDate: party.expectedDate, note: party.note, allocations: party.allocations.map { .init(id: $0.id, transactionID: $0.transactionID, amountMinor: $0.amountMinor) }) }
        let receiptDate = try #require(ISO8601DateFormatter().date(from: "2026-08-15T04:00:00Z"))
        let claimPreviewRequest = V15ReimbursementClaimPreviewRequest(title: claim.title, note: claim.note, parties: parties, expectedVersion: 3)
        _ = try await service.previewClaim(claimID: claim.id, request: claimPreviewRequest)
        _ = try await service.commitClaimReplacement(claimID: claim.id, request: .init(title: claim.title, note: claim.note, parties: parties, expectedVersion: 3, previewToken: V15F3CFixtures.previewID), idempotencyKey: UUID())
        _ = try await service.previewCancellation(claimID: claim.id, request: .init(expectedVersion: 3))
        _ = try await service.commitCancellation(claimID: claim.id, request: .init(expectedVersion: 3, previewToken: V15F3CFixtures.previewID), idempotencyKey: UUID())
        let receiptDraft = V15ReimbursementReceiptDraft(expectedClaimVersion: 3, partyID: V15F3CFixtures.partyID, amountMinor: 18_000, receivedAt: receiptDate, destinationAccountID: V15F3CFixtures.accountID, title: "公司回款")
        _ = try await service.previewReceipt(claimID: claim.id, request: receiptDraft)
        _ = try await service.createReceipt(claimID: claim.id, request: .init(expectedClaimVersion: 3, partyID: V15F3CFixtures.partyID, amountMinor: 18_000, receivedAt: receiptDate, destinationAccountID: V15F3CFixtures.accountID, title: "公司回款", previewToken: V15F3CFixtures.previewID), idempotencyKey: UUID())
        let replacement = V15ReimbursementReceiptReplacePreviewRequest(expectedClaimVersion: 3, partyID: receipt.partyID, amountMinor: receipt.amountMinor, receivedAt: receipt.receivedAt, destinationAccountID: receipt.destinationAccountID, title: receipt.title, note: receipt.note, expectedReceiptVersion: 1)
        _ = try await service.previewReceiptReplacement(receiptID: receipt.id, request: replacement)
        _ = try await service.replaceReceipt(receiptID: receipt.id, request: .init(expectedClaimVersion: 3, partyID: receipt.partyID, amountMinor: receipt.amountMinor, receivedAt: receipt.receivedAt, destinationAccountID: receipt.destinationAccountID, title: receipt.title, note: receipt.note, expectedReceiptVersion: 1, previewToken: V15F3CFixtures.previewID), idempotencyKey: UUID())
        _ = try await service.submit(claimID: claim.id, request: .init(expectedVersion: 3))
        _ = try await service.voidReceipt(receiptID: receipt.id, request: .init(expectedClaimVersion: 3, expectedReceiptVersion: 1))

        let wires = await transport.recordedWires()
        let claimQuery = try #require(wires.first { $0.path == "reimbursement-claims" && $0.method == "GET" })
        #expect(claimQuery.query.contains("status=partial_received") && claimQuery.query.contains("expense_transaction_id=\(V15F3CFixtures.candidateID.uuidString)"))
        #expect(claimQuery.query.contains("include_archived=true") && claimQuery.query.contains("include_voided=true") && claimQuery.query.contains("cursor=opaque"))
        let candidateQuery = try #require(wires.first { $0.path == "reimbursement-expense-candidates" })
        #expect(candidateQuery.query.contains("query=酒店") && candidateQuery.query.contains("date_from=2026-08-01") && candidateQuery.query.contains("date_to=2026-08-15") && candidateQuery.query.contains("cursor=candidate-opaque"))
        let commits = wires.filter { ($0.path.hasPrefix("reimbursement-claims/") || $0.path.hasPrefix("reimbursement-receipts/")) && ($0.path.hasSuffix("cancel-outstanding") || $0.method == "PUT" || $0.path.hasSuffix("/receipts")) }
        #expect(commits.count == 4)
        #expect(commits.allSatisfy { $0.key != nil && $0.body.contains("preview_token") })
        #expect(wires.first { $0.path.hasSuffix("/submit") }?.key == nil)
        #expect(wires.first { $0.path.hasSuffix("/submit") }?.body.contains("expected_version") == true)
        #expect(wires.first { $0.path.hasSuffix("/void") && $0.path.hasPrefix("reimbursement-receipts/") }?.body.contains("expected_claim_version") == true)
    }

    @MainActor @Test("new claim explains every local blocker and accepts an eligible uncategorized candidate")
    func newClaimGreyButtonRegression() async throws {
        let transport = F3CTransport(mode: .normal)
        let model = await loadedModel(transport)
        await model.openNewClaim()
        #expect(Set(model.createClaimDisabledReasons.compactMap(\.fieldPath)).isSuperset(of: ["title", "parties[0].name", "parties[0].allocations[0].transaction_id"]))
        #expect(model.visibleNewClaimIssues.isEmpty)
        model.claimTitle = "临时标题"; model.claimTitle = ""
        #expect(model.visibleNewClaimIssues.contains { $0.fieldPath == "title" })
        #expect(!model.visibleNewClaimIssues.contains { $0.fieldPath == "parties[0].name" })
        fillClaim(model)
        #expect(model.selectedCandidate?.categoryID == nil)
        #expect(model.allocationAmountText == "300.00")
        model.expectedDateText = "2026/08/20"
        #expect(model.createClaimDisabledReasons.contains { $0.fieldPath == "parties[0].expected_date" })
        model.expectedDateText = "2026-08-20"
        #expect(model.canCreateClaim)
        await model.createClaim()
        #expect(model.newClaimPhase == .succeeded)
        let wire = try #require(await transport.recordedWires().last { $0.method == "POST" && $0.path == "reimbursement-claims" })
        let body = try V15FixtureCodec.decoder.decode(V15ReimbursementClaimDraft.self, from: Data(wire.body.utf8))
        #expect(body.parties.first?.allocations.first?.transactionID == V15F3CFixtures.candidateID)
        #expect(body.parties.first?.allocations.first?.amountMinor == 30_000)
        #expect(body.parties.first?.expectedDate == "2026-08-20")
    }

    @MainActor @Test("candidate and receipt-account loading empty error retry stay independently actionable")
    func independentReadStates() async {
        let candidateFailure = await loadedModel(F3CTransport(mode: .candidateErrorThenSuccess))
        await candidateFailure.openNewClaim()
        if case .failed = candidateFailure.candidatesPhase {} else { Issue.record("expected candidate failure") }
        #expect(candidateFailure.createClaimDisabledReasons.contains { $0.fieldPath == "parties[0].allocations[0].transaction_id" })
        await candidateFailure.retryCandidates()
        #expect(candidateFailure.candidatesPhase == .loaded)

        let candidateEmpty = await loadedModel(F3CTransport(mode: .candidateEmpty))
        await candidateEmpty.openNewClaim()
        #expect(candidateEmpty.candidatesPhase == .empty)

        let accountFailure = await loadedModel(F3CTransport(mode: .accountErrorThenSuccess))
        await accountFailure.openReceipt()
        if case .failed = accountFailure.receiptAccountsPhase {} else { Issue.record("expected account failure") }
        #expect(accountFailure.receiptPreviewDisabledReasons.contains { $0.fieldPath == "destination_account_id" })
        await accountFailure.retryReceiptAccounts()
        #expect(accountFailure.receiptAccountsPhase == .loaded && accountFailure.selectedReceiptAccount?.id == V15F3CFixtures.accountID)

        let accountEmpty = await loadedModel(F3CTransport(mode: .accountEmpty))
        await accountEmpty.openReceipt()
        #expect(accountEmpty.receiptAccountsPhase == .empty)
        #expect(accountEmpty.receiptPreviewDisabledReasons.contains { $0.fieldPath == "destination_account_id" })
    }

    @MainActor @Test("candidate filter generation rejects a late stale page")
    func candidateGenerationRace() async throws {
        let model = await loadedModel(F3CTransport(mode: .candidateRace))
        let old = Task { @MainActor in await model.openNewClaim() }
        try await Task.sleep(for: .milliseconds(20))
        model.candidateQuery = "酒店"
        await model.retryCandidates()
        await old.value
        #expect(model.candidatesPhase == .loaded)
        #expect(model.candidates.first?.transactionID == V15F3CFixtures.candidateID)
    }

    @MainActor @Test("receipt invalid-valid-preview-edit-repreview-commit uses CNY and Shanghai date")
    func receiptGreyButtonRegression() async throws {
        let transport = F3CTransport(mode: .normal)
        let model = await loadedModel(transport)
        await model.openReceipt()
        #expect(model.receiptDateText == "2026-08-15")
        #expect(model.selectedReceiptAccount?.id == V15F3CFixtures.accountID)
        model.receiptTitle = ""
        model.receiptAmountText = "180.001"
        model.receiptDateText = "2026-08-16"
        #expect(Set(model.receiptPreviewDisabledReasons.compactMap(\.fieldPath)).isSuperset(of: ["title", "amount_minor", "received_at"]))
        model.receiptTitle = "公司回款"
        model.receiptAmountText = "180.00"
        model.receiptDateText = "2026-08-15"
        #expect(model.canPreviewReceipt)
        await model.previewReceipt()
        #expect(model.receiptPreview != nil && model.canCommitReceipt)
        model.receiptAmountText = "invalid"
        #expect(model.receiptPreview == nil && !model.canCommitReceipt)
        model.receiptAmountText = "180.00"
        await model.previewReceipt()
        await model.commitReceipt()
        #expect(model.receiptPhase == .succeeded && model.receiptResult?.amountMinor == 18_000)
        let previewWire = try #require(await transport.recordedWires().last { $0.path.hasSuffix("receipt-preview") })
        let previewBody = try V15FixtureCodec.decoder.decode(V15ReimbursementReceiptDraft.self, from: Data(previewWire.body.utf8))
        #expect(previewBody.amountMinor == 18_000)
        #expect(ShanghaiBusinessDate.string(for: previewBody.receivedAt) == "2026-08-15")
    }

    @MainActor @Test("Shanghai today remains writable before local noon")
    func receiptTodayBeforeNoon() async throws {
        let morning = try #require(ISO8601DateFormatter().date(from: "2026-08-15T00:05:00Z"))
        let transport = F3CTransport(mode: .normal)
        let model = V15ReimbursementModel(services: V15Services(transport: transport), now: { morning })
        await model.load(); await model.openReceipt()
        #expect(model.receiptDateText == "2026-08-15")
        #expect(model.canPreviewReceipt)
        await model.previewReceipt()
        let wire = try #require(await transport.recordedWires().last { $0.path.hasSuffix("receipt-preview") })
        let body = try V15FixtureCodec.decoder.decode(V15ReimbursementReceiptDraft.self, from: Data(wire.body.utf8))
        #expect(body.receivedAt == ISO8601DateFormatter().date(from: "2026-08-14T16:00:00Z"))
        #expect(body.receivedAt <= morning)
    }

    @MainActor @Test("receipt 409 requires fresh reload and repreview before success")
    func conflictRecovery() async {
        let transport = F3CTransport(mode: .receiptConflictThenSuccess)
        let model = await loadedModel(transport)
        await model.openReceipt(); await model.previewReceipt()
        if case .conflict = model.receiptPhase {} else { Issue.record("expected conflict") }
        #expect(!model.canCommitReceipt)
        await model.refresh()
        #expect(await transport.recordedWires().contains { $0.method == "GET" && $0.cache == .reloadIgnoringCache })
        await model.openReceipt(); await model.previewReceipt(); await model.commitReceipt()
        #expect(model.receiptPhase == .succeeded)
        #expect(await transport.recordedWires().filter { $0.path.hasSuffix("receipt-preview") }.count == 2)
    }

    @MainActor @Test("remote receipt reasons stay in the editor and clear only after input changes")
    func remoteReasons() async {
        let model = await loadedModel(F3CTransport(mode: .receiptRemoteFieldThenSuccess))
        await model.openReceipt(); await model.previewReceipt()
        #expect(Set(model.receiptServerIssues.compactMap(\.fieldPath)) == ["destination_account_id", "title"])
        model.receiptTitle = "修正后的到账标题"
        #expect(model.receiptServerIssues.isEmpty)
        await model.previewReceipt()
        #expect(model.receiptPreview != nil)
    }

    @MainActor @Test("response-unknown create and receipt replay identical body and key exactly once")
    func sameKeyReplay() async throws {
        let claimTransport = F3CTransport(mode: .claimUnknownThenSuccess)
        let claimModel = await loadedModel(claimTransport)
        await claimModel.openNewClaim(); fillClaim(claimModel); await claimModel.createClaim()
        #expect(claimModel.newClaimPhase == .unknown)
        await claimModel.retryUnknownCreateClaim()
        #expect(claimModel.newClaimPhase == .succeeded)
        let claimWires = await claimTransport.recordedWires().filter { $0.method == "POST" && $0.path == "reimbursement-claims" }
        #expect(claimWires.count == 2 && claimWires[0].key == claimWires[1].key && claimWires[0].body == claimWires[1].body)

        let receiptTransport = F3CTransport(mode: .receiptUnknownThenSuccess)
        let receiptModel = await loadedModel(receiptTransport)
        await receiptModel.openReceipt(); await receiptModel.previewReceipt(); await receiptModel.commitReceipt()
        #expect(receiptModel.receiptPhase == .unknown)
        await receiptModel.retryUnknownReceipt()
        #expect(receiptModel.receiptPhase == .succeeded)
        let receiptWires = await receiptTransport.recordedWires().filter { $0.method == "POST" && $0.path.hasSuffix("/receipts") }
        #expect(receiptWires.count == 2 && receiptWires[0].key == receiptWires[1].key && receiptWires[0].body == receiptWires[1].body)
    }

    @MainActor @Test("offline blocks create and receipt before any write wire")
    func offlineZeroWire() async {
        let transport = F3CTransport(mode: .normal)
        let model = await loadedModel(transport, offline: true)
        await model.openNewClaim(); await model.createClaim(); await model.openReceipt(); await model.previewReceipt(); await model.commitReceipt()
        let wires = await transport.recordedWires()
        #expect(wires.allSatisfy { $0.method == "GET" })
        #expect(model.createClaimDisabledReasons.contains { $0.code == "offline_read_only" })
        #expect(model.receiptPreviewDisabledReasons.contains { $0.code == "offline_read_only" })
    }

    @MainActor @Test("keyless direct exact-looking fresh facts remain unattributed and never resend")
    func directUnknownReadback() async {
        let transport = F3CTransport(mode: .directClaimUnknownConfirmed)
        let model = await loadedModel(transport)
        await model.performDirectClaim(.void)
        #expect(model.directMutationPhase == .unknown)
        await model.readBackUnknownDirect()
        #expect(model.directMutationPhase == .unknown)
        #expect(model.directReadbackMessage?.contains("数据已经变化") == true)
        #expect(model.directReadbackMessage?.contains("仍无法确认是否由本次操作造成") == true)
        #expect(model.canAbandonUnknownDirect)
        let wires = await transport.recordedWires()
        #expect(wires.filter { $0.method == "POST" && $0.path.hasSuffix("/void") }.count == 1)
        #expect(wires.contains { $0.method == "GET" && $0.path == "reimbursement-claims/\(V15F3CFixtures.claimID)" && $0.cache == .reloadIgnoringCache })
        model.abandonUnknownDirect()
        #expect(model.directMutationPhase == .idle && !model.hasRecoverableDirectAttempt)
    }

    @MainActor @Test("unknown create and receipt survive close reopen without replacing owner body or key")
    func unknownCloseReopenRecovery() async {
        let claimTransport = F3CTransport(mode: .claimUnknownThenSuccess)
        let claimModel = await loadedModel(claimTransport)
        await claimModel.openNewClaim(); fillClaim(claimModel); await claimModel.createClaim()
        let candidateReads = await claimTransport.recordedWires().filter { $0.path == "reimbursement-expense-candidates" }.count
        claimModel.dismissNewClaim(); await claimModel.openNewClaim()
        #expect(claimModel.newClaimPhase == .unknown && claimModel.hasRecoverableCreateAttempt)
        #expect(claimModel.createClaimDisabledReasons.contains { $0.code == "claim_attempt_in_flight" })
        #expect(await claimTransport.recordedWires().filter { $0.path == "reimbursement-expense-candidates" }.count == candidateReads)
        await claimModel.retryUnknownCreateClaim()
        let claimWires = await claimTransport.recordedWires().filter { $0.method == "POST" && $0.path == "reimbursement-claims" }
        #expect(claimModel.newClaimPhase == .succeeded && claimWires.count == 2 && claimWires[0].key == claimWires[1].key && claimWires[0].body == claimWires[1].body)

        let receiptTransport = F3CTransport(mode: .receiptUnknownThenSuccess)
        let receiptModel = await loadedModel(receiptTransport)
        await receiptModel.openReceipt(); await receiptModel.previewReceipt(); await receiptModel.commitReceipt()
        let accountReads = await receiptTransport.recordedWires().filter { $0.path == "reimbursement-receipt-account-options" }.count
        receiptModel.dismissReceipt(); await receiptModel.openReceipt()
        #expect(receiptModel.receiptPhase == .unknown && receiptModel.hasRecoverableReceiptAttempt)
        #expect(receiptModel.receiptPreviewDisabledReasons.contains { $0.code == "receipt_attempt_in_flight" })
        #expect(await receiptTransport.recordedWires().filter { $0.path == "reimbursement-receipt-account-options" }.count == accountReads)
        await receiptModel.retryUnknownReceipt()
        let receiptWires = await receiptTransport.recordedWires().filter { $0.method == "POST" && $0.path.hasSuffix("/receipts") }
        #expect(receiptModel.receiptPhase == .succeeded && receiptWires.count == 2 && receiptWires[0].key == receiptWires[1].key && receiptWires[0].body == receiptWires[1].body)
    }

    @MainActor @Test("owner A recovery never projects onto B and restores when A returns")
    func ownerScopedRecovery() async throws {
        let transport = F3CTransport(mode: .receiptUnknownThenSuccess)
        let model = await loadedModel(transport)
        let ownerA = try #require(model.selectedClaim)
        await model.openReceipt(); await model.previewReceipt(); await model.commitReceipt(); model.dismissReceipt()
        let ownerB = try #require(model.claims.first { $0.id == V15F3CFixtures.unknownClaimID })
        await model.selectClaim(ownerB)
        #expect(model.receiptPhase == .idle && !model.hasRecoverableReceiptAttempt)
        await model.selectClaim(ownerA)
        #expect(model.receiptPhase == .unknown && model.hasRecoverableReceiptAttempt)
        await model.openReceipt(); await model.retryUnknownReceipt()
        #expect(model.receiptPhase == .succeeded)
    }

    @MainActor @Test("delayed owner A receipt success or failure cannot contaminate selected B")
    func receiptOwnerRace() async throws {
        for mode in [F3CTransport.Mode.receiptDelayedSuccess, .receiptDelayedFailure] {
            let model = await loadedModel(F3CTransport(mode: mode))
            let ownerA = try #require(model.selectedClaim)
            await model.openReceipt(); await model.previewReceipt()
            let commit = Task { @MainActor in await model.commitReceipt() }
            try await Task.sleep(for: .milliseconds(25))
            model.dismissReceipt()
            let ownerB = try #require(model.claims.first { $0.id == V15F3CFixtures.unknownClaimID })
            await model.selectClaim(ownerB)
            await commit.value
            #expect(model.receiptPhase == .idle && model.receiptResult == nil)
            await model.selectClaim(ownerA)
            if mode == .receiptDelayedSuccess { #expect(model.receiptPhase == .succeeded && model.receiptResult != nil) }
            else if case .failed = model.receiptPhase {} else { Issue.record("owner A deterministic failure must restore only on A") }
        }
    }

    @MainActor @Test("direct no-key prealready no-advance mismatch and read failure never clear unknown lock")
    func directProofBoundaries() async {
        let prealreadyTransport = F3CTransport(mode: .directClaimUnknownPrealready)
        let prealready = await loadedModel(prealreadyTransport)
        await prealready.performDirectClaim(.void)
        #expect(await prealreadyTransport.recordedWires().filter { $0.method == "POST" && $0.path.hasSuffix("/void") }.isEmpty)
        #expect(prealready.directClaimReasons(for: prealready.selectedClaim!, action: .void).contains { $0.code == "claim_not_voidable" })

        for (mode, expectedCopy) in [(F3CTransport.Mode.directClaimUnknownNoAdvance, "数据没有变化"), (.directClaimUnknownMismatch, "不完全一致")] {
            let transport = F3CTransport(mode: mode); let model = await loadedModel(transport)
            await model.performDirectClaim(.void); await model.readBackUnknownDirect()
            #expect(model.directMutationPhase == .unknown && model.hasRecoverableDirectAttempt)
            #expect(model.directReadbackMessage?.contains(expectedCopy) == true)
            #expect(await transport.recordedWires().filter { $0.method == "POST" && $0.path.hasSuffix("/void") }.count == 1)
        }
        let failedTransport = F3CTransport(mode: .directClaimReadbackFailure); let failed = await loadedModel(failedTransport)
        await failed.performDirectClaim(.void); await failed.readBackUnknownDirect()
        #expect(failed.directMutationPhase == .unknown && failed.hasRecoverableDirectAttempt && !failed.canAbandonUnknownDirect)
        #expect(await failedTransport.recordedWires().filter { $0.method == "POST" && $0.path.hasSuffix("/void") }.count == 1)
    }

    @MainActor @Test("keyless receipt direct readback requires both fresh versions and still cannot attribute")
    func directReceiptProofBoundary() async throws {
        let transport = F3CTransport(mode: .directReceiptUnknownConfirmed)
        let model = await loadedModel(transport)
        let receipt = try #require(model.receipts.first)
        await model.performDirectReceipt(receipt, action: .void)
        #expect(model.directMutationPhase == .unknown && model.hasRecoverableDirectAttempt)
        await model.readBackUnknownDirect()
        #expect(model.directMutationPhase == .unknown && model.hasRecoverableDirectAttempt)
        #expect(model.directReadbackMessage?.contains("数据已经变化") == true)
        #expect(model.directReadbackMessage?.contains("仍无法确认是否由本次操作造成") == true)
        let wires = await transport.recordedWires()
        #expect(wires.filter { $0.method == "POST" && $0.path == "reimbursement-receipts/\(V15F3CFixtures.receiptID)/void" }.count == 1)
        #expect(wires.filter { $0.method == "GET" && $0.cache == .reloadIgnoringCache }.contains { $0.path == "reimbursement-receipts/\(V15F3CFixtures.receiptID)" })
        #expect(wires.filter { $0.method == "GET" && $0.cache == .reloadIgnoringCache }.contains { $0.path == "reimbursement-claims/\(V15F3CFixtures.claimID)" })
    }

    @MainActor @Test("cancel outstanding uses one model reason matrix for every status and hard gate")
    func cancelReasonMatrix() async throws {
        let model = await loadedModel()
        let valid = try #require(model.selectedClaim)
        #expect(model.cancelReasons(for: valid).isEmpty && model.canPreviewCancel)
        let cases: [(String, Int64, Bool, Bool, String)] = [
            ("draft", 0, false, false, "draft_not_cancellable"),
            ("received", 30_000, false, false, "nothing_outstanding"),
            ("cancelled", 0, false, false, "status_not_cancellable"),
            ("partial_received", 12_000, true, false, "claim_archived"),
            ("partial_received", 12_000, false, true, "claim_voided")
        ]
        for (status, received, archived, voided, code) in cases {
            let claim = try V15FixtureCodec.decoder.decode(V15ReimbursementClaim.self, from: Data(V15F3CFixtures.claim(status: status, received: received, archived: archived, voided: voided).utf8))
            #expect(model.cancelReasons(for: claim).contains { $0.code == code })
        }
        let offline = await loadedModel(F3CTransport(mode: .normal), offline: true)
        #expect(offline.cancelReasons(for: offline.selectedClaim!).contains { $0.code == "offline_read_only" })
    }

    @MainActor @Test("all four model previews commit exact typed versions and tokens")
    func fourPreviewCommitModels() async {
        let transports = (0..<4).map { _ in F3CTransport(mode: .normal) }
        let claimReplace = await loadedModel(transports[0]); claimReplace.openClaimReplacement(); await claimReplace.previewCurrentClaimReplacement(); await claimReplace.commitCurrentClaimReplacement()
        let cancellation = await loadedModel(transports[1]); await cancellation.previewCancellation(); await cancellation.commitCancellation()
        let creation = await loadedModel(transports[2]); await creation.openReceipt(); await creation.previewReceipt(); await creation.commitReceipt()
        let replacement = await loadedModel(transports[3]); let receipt = replacement.receipts.first!; replacement.openReceiptReplacement(receipt); await replacement.previewReceiptReplacement(receipt); await replacement.commitReceiptReplacement(receipt)
        var commits: [F3CTransport.Wire] = []
        for transport in transports { commits += await transport.recordedWires().filter { $0.key != nil && $0.body.contains("preview_token") } }
        #expect(commits.count == 4)
        #expect(commits.allSatisfy { $0.body.contains("expected_") })
    }

    @MainActor @Test("typed claim and receipt action applicability matches Backend field matrix")
    func actionMatrix() async throws {
        let model = await loadedModel()
        func decode(_ json: String) throws -> V15ReimbursementClaim { try V15FixtureCodec.decoder.decode(V15ReimbursementClaim.self, from: Data(json.utf8)) }
        let draft = try decode(V15F3CFixtures.claim(status: "draft", received: 0, receiptCount: 0, submitted: false))
        #expect(model.isClaimActionApplicable(.replace, to: draft))
        #expect(model.isClaimActionApplicable(.submit, to: draft))
        #expect(model.isClaimActionApplicable(.void, to: draft))
        #expect(!model.isClaimActionApplicable(.retractSubmission, to: draft))

        let pending = try decode(V15F3CFixtures.claim(status: "pending", received: 0, receiptCount: 0, submitted: true))
        #expect(model.isClaimActionApplicable(.cancelOutstanding, to: pending))
        #expect(model.isClaimActionApplicable(.retractSubmission, to: pending))
        #expect(!model.isClaimActionApplicable(.submit, to: pending))

        let cancelled = try decode(V15F3CFixtures.claim(status: "cancelled", received: 0, receiptCount: 0, submitted: true))
        #expect(model.isClaimActionApplicable(.reopen, to: cancelled))
        #expect(model.isClaimActionApplicable(.archive, to: cancelled))
        let voided = try decode(V15F3CFixtures.claim(status: "draft", received: 0, voided: true, receiptCount: 0, submitted: false))
        #expect(model.isClaimActionApplicable(.restore, to: voided))
        let archived = try decode(V15F3CFixtures.claim(status: "received", received: 30_000, archived: true, receiptCount: 1, submitted: true))
        #expect(model.isClaimActionApplicable(.unarchive, to: archived))

        let activeReceipt = try V15FixtureCodec.decoder.decode(V15ReimbursementReceipt.self, from: Data(V15F3CFixtures.receipt().utf8))
        let voidReceipt = try V15FixtureCodec.decoder.decode(V15ReimbursementReceipt.self, from: Data(V15F3CFixtures.receipt(voided: true).utf8))
        let activeClaim = try #require(model.selectedClaim)
        #expect(model.isReceiptActionApplicable(.replace, to: activeReceipt, claim: activeClaim))
        #expect(model.isReceiptActionApplicable(.void, to: activeReceipt, claim: activeClaim))
        #expect(model.isReceiptActionApplicable(.restore, to: voidReceipt, claim: activeClaim))
        #expect(!model.isReceiptActionApplicable(.restore, to: activeReceipt, claim: activeClaim))
    }

    @MainActor @Test("receipt replacement aggregates every local blocker and invalid input sends no preview wire")
    func receiptReplacementGreyButtonRegression() async throws {
        let transport = F3CTransport(mode: .normal)
        let model = await loadedModel(transport)
        let claim = try #require(model.selectedClaim)
        let receipt = try #require(model.receipts.first)
        model.openReceiptReplacement(receipt)
        model.receiptReplacementTitle = ""
        model.receiptReplacementAmountText = "180.001"
        model.receiptReplacementDateText = "bad-date"

        let reasons = model.receiptReplacementPreviewReasons(for: receipt, claim: claim)
        #expect(Set(reasons.compactMap(\.fieldPath)).isSuperset(of: ["title", "amount_minor", "received_at"]))

        await model.previewReceiptReplacement(receipt)
        #expect(await transport.recordedWires().filter {
            $0.method == "POST" && $0.path == "reimbursement-receipts/\(V15F3CFixtures.receiptID)/preview"
        }.isEmpty)
    }

    @MainActor @Test("receipt replace void restore converge claim and receipt facts before next versioned wire")
    func receiptMutationFactConvergence() async throws {
        let transport = F3CTransport(mode: .receiptReplaceRefresh)
        let model = await loadedModel(transport)
        let original = try #require(model.receipts.first)
        model.openReceiptReplacement(original)
        model.receiptReplacementTitle = "修正后的回款"
        model.receiptReplacementAmountText = "100.00"
        await model.previewReceiptReplacement(original)
        await model.commitReceiptReplacement(original)
        #expect(model.secondaryMutationPhase == .succeeded)
        #expect(model.selectedClaim?.version == 4 && model.selectedClaim?.receivedMinor == 10_000)
        let replaced = try #require(model.receipts.first)
        #expect(replaced.version == 2 && replaced.amountMinor == 10_000)

        await model.performDirectReceipt(replaced, action: .void)
        #expect(model.directMutationPhase == .succeeded)
        #expect(model.selectedClaim?.version == 5 && model.selectedClaim?.receivedMinor == 0 && model.selectedClaim?.receiptCount == 1)
        let voided = try #require(model.receipts.first)
        #expect(voided.version == 3 && voided.voidedAt != nil)
        await model.performDirectReceipt(voided, action: .restore)
        #expect(model.directMutationPhase == .succeeded)
        #expect(model.selectedClaim?.version == 6 && model.selectedClaim?.receivedMinor == 10_000)
        #expect(model.receipts.first?.version == 4 && model.receipts.first?.voidedAt == nil)

        let wires = await transport.recordedWires()
        let replacementPreviewWire = try #require(wires.first { $0.method == "POST" && $0.path == "reimbursement-receipts/\(V15F3CFixtures.receiptID)/preview" })
        let replacementPreviewBody = try V15FixtureCodec.decoder.decode(V15ReimbursementReceiptReplacePreviewRequest.self, from: Data(replacementPreviewWire.body.utf8))
        #expect(replacementPreviewBody.expectedClaimVersion == 3 && replacementPreviewBody.expectedReceiptVersion == 1)
        let directBodies = try wires.filter {
            $0.method == "POST" && ($0.path.hasSuffix("/void") || $0.path.hasSuffix("/restore"))
        }.map { try V15FixtureCodec.decoder.decode(V15ReimbursementReceiptVersionRequest.self, from: Data($0.body.utf8)) }
        #expect(directBodies.map(\.expectedClaimVersion) == [4, 5])
        #expect(directBodies.map(\.expectedReceiptVersion) == [2, 3])
        #expect(wires.filter { $0.method == "GET" && $0.cache == .reloadIgnoringCache && $0.path == "reimbursement-claims/\(V15F3CFixtures.claimID)" }.count == 3)
        #expect(wires.filter { $0.method == "GET" && $0.cache == .reloadIgnoringCache && $0.path.hasSuffix("/receipts") }.count == 3)
    }

    @MainActor @Test("receipt mutation refresh failure is partial success with GET-only retry and write lock")
    func receiptMutationRefreshFailure() async throws {
        let transport = F3CTransport(mode: .receiptFactRefreshFailure)
        let model = await loadedModel(transport)
        let receipt = try #require(model.receipts.first)
        model.openReceiptReplacement(receipt)
        model.receiptReplacementAmountText = "100.00"
        await model.previewReceiptReplacement(receipt)
        await model.commitReceiptReplacement(receipt)
        #expect(model.hasPendingFactRefresh)
        #expect(!model.isFactRefreshInFlight)
        #expect(model.factRefreshRetryReasons.isEmpty)
        #expect(model.factRefreshMessage?.contains("到账已经保存") == true)
        #expect(model.factRefreshMessage?.contains("最新报销数据读取失败") == true)
        #expect(model.receiptActionReasons(for: receipt, claim: model.selectedClaim!, action: .void).contains { $0.code == "receipt_fact_refresh_required" })
        #expect(await transport.recordedWires().filter { $0.method == "PUT" }.count == 1)
        await model.retryFactRefresh()
        #expect(!model.hasPendingFactRefresh && model.secondaryMutationPhase == .succeeded)
        #expect(model.selectedClaim?.version == 4 && model.receipts.first?.version == 2)
        #expect(await transport.recordedWires().filter { $0.method == "PUT" }.count == 1)

        let createTransport = F3CTransport(mode: .receiptFactRefreshFailure)
        let create = await loadedModel(createTransport)
        await create.openReceipt(); await create.previewReceipt(); await create.commitReceipt()
        #expect(create.hasPendingFactRefresh && create.factRefreshMessage?.contains("请重新读取") == true)
        #expect(await createTransport.recordedWires().filter { $0.method == "POST" && $0.path.hasSuffix("/receipts") }.count == 1)
        create.dismissReceipt()
        #expect(create.hasPendingFactRefresh && !create.isFactRefreshInFlight && create.factRefreshRetryReasons.isEmpty)
        await create.retryFactRefresh()
        #expect(!create.hasPendingFactRefresh && create.receiptPhase == .succeeded && create.selectedClaim?.version == 4)
        #expect(await createTransport.recordedWires().filter { $0.method == "POST" && $0.path.hasSuffix("/receipts") }.count == 1)

        let directTransport = F3CTransport(mode: .receiptFactRefreshFailure)
        let direct = await loadedModel(directTransport)
        let directReceipt = try #require(direct.receipts.first)
        await direct.performDirectReceipt(directReceipt, action: .void)
        #expect(direct.hasPendingFactRefresh && direct.factRefreshMessage?.contains("请重新读取") == true)
        #expect(await directTransport.recordedWires().filter { $0.method == "POST" && $0.path.hasSuffix("/void") }.count == 1)
        await direct.retryFactRefresh()
        #expect(!direct.hasPendingFactRefresh && direct.directMutationPhase == .succeeded && direct.selectedClaim?.version == 4)
        #expect(await directTransport.recordedWires().filter { $0.method == "POST" && $0.path.hasSuffix("/void") }.count == 1)
    }

    @MainActor @Test("initial expense transaction is found across server candidate pages and selected exactly")
    func initialTransactionPagesToExactCandidate() async {
        let transport = InitialCandidatePagingTransport(outcome: .foundOnSecondPage)
        let model = V15ReimbursementModel(services: V15Services(transport: transport))
        await model.openNewClaim(preselecting: V15F3CFixtures.candidateID)

        #expect(model.newClaimSheetVisible)
        #expect(model.selectedCandidate?.transactionID == V15F3CFixtures.candidateID)
        #expect(model.allocationAmountText == "300.00")
        #expect(model.newClaimPhase == .ready)
        #expect(await transport.requestedCursors() == [nil, "candidate-page-2"])
    }

    @MainActor @Test("missing initial expense transaction reports an explicit error and never selects another candidate")
    func missingInitialTransactionDoesNotFallback() async {
        let transport = InitialCandidatePagingTransport(outcome: .missing)
        let model = V15ReimbursementModel(services: V15Services(transport: transport))
        await model.openNewClaim(preselecting: V15F3CFixtures.candidateID)

        #expect(model.selectedCandidate == nil)
        #expect(model.newClaimServerIssues.contains { $0.code == "initial_reimbursement_candidate_not_found" })
        if case .failed(let failure) = model.newClaimPhase {
            #expect(failure.code == "initial_reimbursement_candidate_not_found")
        } else {
            Issue.record("expected an explicit missing-candidate failure")
        }
        #expect(await transport.requestedCursors() == [nil, "candidate-page-2"])
    }
}

private actor InitialCandidatePagingTransport: V15Transporting {
    enum Outcome { case foundOnSecondPage, missing }

    private let outcome: Outcome
    private var cursors: [String?] = []

    init(outcome: Outcome) { self.outcome = outcome }

    func requestedCursors() -> [String?] { cursors }

    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        guard request.path == "reimbursement-expense-candidates", request.method == "GET" else {
            throw V15Failure(kind: .transport, code: "fixture_missing", message: "Unexpected request: \(request.method) \(request.path)")
        }
        let cursor = request.query.first(where: { $0.name == "cursor" })?.value
        cursors.append(cursor)
        let payload: String
        if cursor == nil {
            payload = #"{"items":[],"next_cursor":"candidate-page-2"}"#
        } else if outcome == .foundOnSecondPage {
            payload = V15F3CFixtures.candidates
        } else {
            payload = #"{"items":[],"next_cursor":null}"#
        }
        return try V15FixtureCodec.decoder.decode(Response.self, from: Data(payload.utf8))
    }

    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data {
        throw V15Failure(kind: .transport, code: "fixture_missing", message: "No artifact fixture.")
    }
}
