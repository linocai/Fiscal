import Foundation
import Testing
@testable import FiscalKit

@Suite("F3-B2 typed installment lifecycle")
struct F3B2Tests {
    private let fixedNow = ISO8601DateFormatter().date(from: "2026-08-15T03:00:00Z")!

    @MainActor private func fillPurchase(_ model: V15InstallmentModel, positiveFee: Bool = false) {
        model.newPurchaseTitle = "工作设备"
        model.newPurchaseAmountText = "3299.00"
        model.newPurchaseAccountID = V15F3B2Fixtures.accountID
        model.newPurchaseCategoryID = V15F3B2Fixtures.categoryID
        model.newPurchaseCountText = "6"
        model.newPurchaseStartStatementDate = "2026-09-10"
        if positiveFee {
            model.newPurchaseFeeText = "99.96"
            model.newPurchaseFeeCategoryID = V15F3B2Fixtures.categoryID
            model.newPurchaseFeeOccurredDateText = "2026-08-15"
        }
    }

    private func waitForWire(_ transport: F3B2Transport, method: String, path: String) async throws {
        for _ in 0..<50 {
            if await transport.recordedWires().contains(where: { $0.method == method && $0.path == path }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for \(method) \(path)")
    }

    @Test("complete five-state page decodes and future state remains display-only")
    func statusesDecode() throws {
        let page = try V15FixtureCodec.decoder.decode(V15InstallmentPlanPage.self, from: Data(V15F3B2Fixtures.page().utf8))
        #expect(page.items.map(\.status) == [.active, .completed, .settledEarly, .partiallyCancelled, .cancelled, .unknown("future_server_state")])
        #expect(page.items.last?.isDisplayOnly == true)
        #expect(page.items.last?.status.displayName == "暂时无法识别")
        #expect(page.items.first?.periods.first?.amountDueMinor == 56_650)
        #expect(page.nextCursor == "opaque-installment-next")
    }

    @Test("all server preview and result shapes retain locked periods cycles warnings and receipts")
    func previewShapesDecode() throws {
        let change = try V15FixtureCodec.decoder.decode(V15InstallmentPlanChangePreview.self, from: Data(V15F3B2Fixtures.planChangePreview.utf8))
        let settlement = try V15FixtureCodec.decoder.decode(V15InstallmentSettlementPreview.self, from: Data(V15F3B2Fixtures.settlementPreview.utf8))
        let reverse = try V15FixtureCodec.decoder.decode(V15InstallmentReverseSettlementPreview.self, from: Data(V15F3B2Fixtures.reversePreview.utf8))
        let cancel = try V15FixtureCodec.decoder.decode(V15InstallmentCancellationPreview.self, from: Data(V15F3B2Fixtures.cancelPreview.utf8))
        #expect(change.lockedPeriods.count == 1 && change.futurePeriods.count == 3 && change.affectedCycles.first?.deltaMinor == -6_665)
        #expect(change.futurePeriods.last?.sequence == 7 && change.affectedCycles.last?.statementDate == "2026-11-10")
        #expect(change.warnings.first?.code == "locked_prefix_preserved")
        #expect(settlement.amountMinor == 283_250 && settlement.paymentBalanceAfterMinor == 516_750 && settlement.affectedCycles.count == 2)
        #expect(reverse.eligible && reverse.restoredPeriods.last?.sequence == 7)
        #expect(cancel.principalRefundMinor == 274_916 && cancel.cancelledPeriods.last?.sequence == 7)
    }

    @MainActor @Test("list detail purchase and liabilities are server facts")
    func loadFacts() async {
        let model = V15InstallmentModel(services: V15F3B2Fixtures.services(), now: { fixedNow })
        await model.load()
        #expect(model.plans.count == 6)
        #expect(model.selectedPlan?.id == V15F3B2Fixtures.activePlanID)
        #expect(model.selectedPurchase?.id == V15F3B2Fixtures.purchaseID)
        #expect(model.liabilities?.totalFutureScheduledGrossMinor == 283_250)
        let unknown = model.plans.last!
        await model.selectPlan(unknown)
        #expect(model.selectedPlan?.status == .unknown("future_server_state"))
        #expect(model.planMutationDisabledReason?.code == "unknown_plan_status")
    }

    @MainActor @Test("fee categories have independent loading empty error retry and generation ownership")
    func feeCategoryStatesAndRace() async throws {
        let failureTransport = F3B2Transport(mode: .categoryFailureThenSuccess)
        let failureModel = V15InstallmentModel(services: V15F3B2Fixtures.services(transport: failureTransport), now: { fixedNow })
        await failureModel.load()
        if case .failed = failureModel.feeCategoryPhase {} else { Issue.record("expected independent fee category failure") }
        #expect(failureModel.plans.count == 6)
        #expect(failureModel.purchasePreviewDisabledReason?.code == "expense_categories_failed")
        #expect(failureModel.purchasePreviewDisabledReason?.message.contains("重试") == true)
        await failureModel.loadFeeCategories()
        #expect(failureModel.feeCategoryPhase == .loaded && failureModel.expenseCategories.map(\.id) == [V15F3B2Fixtures.categoryID])

        let emptyModel = V15InstallmentModel(services: V15F3B2Fixtures.services(route: "installments-category-empty"), now: { fixedNow })
        await emptyModel.load()
        #expect(emptyModel.feeCategoryPhase == .empty && emptyModel.feeCategoryLoadingReason?.code == "expense_categories_empty")
        #expect(emptyModel.purchasePreviewDisabledReason?.message.contains("创建分类") == true)

        let raceTransport = F3B2Transport(mode: .categoryRace)
        let raceModel = V15InstallmentModel(services: V15F3B2Fixtures.services(transport: raceTransport), now: { fixedNow })
        let stale = Task { @MainActor in await raceModel.loadFeeCategories() }
        try await Task.sleep(for: .milliseconds(20))
        await raceModel.loadFeeCategories(); await stale.value
        #expect(raceModel.feeCategoryPhase == .loaded && raceModel.expenseCategories.count == 1)
    }

    @MainActor @Test("all three positive-fee workflows require an authoritative expense category and visible Shanghai date; zero clears both")
    func feeInputsAreReachableAndZeroIsNull() async {
        let transport = F3B2Transport(mode: .normal)
        let model = V15InstallmentModel(services: V15F3B2Fixtures.services(transport: transport), now: { fixedNow })
        await model.load()

        model.newPurchaseTitle = "工作设备"; model.newPurchaseAmountText = "3299.00"; model.newPurchaseAccountID = V15F3B2Fixtures.accountID; model.newPurchaseCategoryID = V15F3B2Fixtures.categoryID; model.newPurchaseStartStatementDate = "2026-09-10"; model.newPurchaseFeeText = "99.96"
        #expect(model.purchasePreviewDisabledReason?.code == "fee_occurred_at_invalid")
        #expect(model.purchasePreviewDisabledReason?.fieldPath == "fee_occurred_at")
        model.newPurchaseFeeCategoryID = V15F3B2Fixtures.categoryID
        #expect(model.purchasePreviewDisabledReason != nil)
        model.newPurchaseFeeOccurredDateText = "2026-08-15"
        #expect(model.purchasePreviewDisabledReason == nil)
        await model.requestPurchasePreview()

        model.purchaseTransactionIDText = V15F3B2Fixtures.purchaseID.uuidString; await model.checkEligibility()
        // Focus changes around the conditional fee controls may make SwiftUI write the
        // same TextField value again; only a semantic ID change may invalidate facts.
        model.purchaseTransactionIDText = V15F3B2Fixtures.purchaseID.uuidString
        #expect(model.eligibility?.eligible == true && !model.cycleOptions.isEmpty)
        model.createFeeText = "99.96"
        #expect(model.createPlanDisabledReason?.code == "fee_occurred_at_invalid")
        #expect(model.createPlanDisabledReason?.fieldPath == "fee_occurred_at")
        model.createFeeCategoryID = V15F3B2Fixtures.categoryID; model.createFeeOccurredDateText = "2026-08-15"
        #expect(model.createPlanDisabledReason == nil)
        await model.createPlan()

        model.editFeeText = "0.00"
        #expect(model.editFeeCategoryID == nil && model.editFeeOccurredDateText.isEmpty)
        model.editFeeText = "99.96"
        #expect(model.planPreviewDisabledReason?.code == "fee_occurred_at_invalid")
        #expect(model.planPreviewDisabledReason?.fieldPath == "fee_occurred_at")
        model.editFeeCategoryID = V15F3B2Fixtures.categoryID; model.editFeeOccurredDateText = "2026-08-15"
        #expect(model.planPreviewDisabledReason == nil)
        await model.requestPlanPreview()

        model.newPurchaseFeeText = "0.00"; model.createFeeText = "0.00"; model.editFeeText = "0.00"
        #expect(model.newPurchaseFeeCategoryID == nil && model.newPurchaseFeeOccurredDateText.isEmpty)
        #expect(model.createFeeCategoryID == nil && model.createFeeOccurredDateText.isEmpty)
        #expect(model.editFeeCategoryID == nil && model.editFeeOccurredDateText.isEmpty)

        let positiveBodies = await transport.recordedWires().filter { $0.method == "POST" && ($0.path == "installment-purchases/preview" || $0.path == "installment-plans" || $0.path.hasSuffix("/preview")) }.map(\.body)
        #expect(positiveBodies.count >= 3)
        #expect(positiveBodies.allSatisfy { $0.contains("fee_category_id") && $0.contains("fee_occurred_at") })

        let beforeZero = await transport.recordedWires().count
        await model.requestPurchasePreview(); await model.createPlan(); await model.requestPlanPreview()
        let zeroBodies = await transport.recordedWires().dropFirst(beforeZero).filter { $0.method == "POST" && ($0.path == "installment-purchases/preview" || $0.path == "installment-plans" || $0.path.hasSuffix("/preview")) }.map(\.body)
        #expect(zeroBodies.count == 3)
        #expect(zeroBodies.allSatisfy { !$0.contains("fee_category_id") && !$0.contains("fee_occurred_at") })
    }

    @MainActor @Test("fee time obeys purchase occurrence and now boundaries for atomic existing and edit paths")
    func feeTimeObeysBothBackendBoundaries() async throws {
        let morning = ISO8601DateFormatter().date(from: "2026-08-15T00:30:00Z")!
        let transport = F3B2Transport(mode: .normal)
        let model = V15InstallmentModel(services: V15F3B2Fixtures.services(transport: transport), now: { morning })
        await model.load(); fillPurchase(model, positiveFee: true)
        #expect(model.purchasePreviewDisabledReason == nil)
        await model.requestPurchasePreview()
        let purchaseWire = await transport.recordedWires().first { $0.path == "installment-purchases/preview" }!
        let purchase = try V15FixtureCodec.decoder.decode(V15InstallmentPurchaseCreateRequest.self, from: Data(purchaseWire.body.utf8))
        #expect(purchase.feeOccurredAt == purchase.purchase.occurredAt)
        #expect(purchase.purchase.occurredAt == morning)
        #expect((purchase.feeOccurredAt ?? .distantFuture) <= morning)

        model.newPurchaseFeeOccurredDateText = "2026-08-14"
        #expect(model.purchasePreviewDisabledReason?.code == "fee_before_purchase")
        model.newPurchaseFeeOccurredDateText = "2026-08-16"
        #expect(model.purchasePreviewDisabledReason?.code == "fee_in_future")

        let editNow = ISO8601DateFormatter().date(from: "2026-08-15T03:00:00Z")!
        let editTransport = F3B2Transport(mode: .normal)
        let editModel = V15InstallmentModel(services: V15F3B2Fixtures.services(transport: editTransport), now: { editNow })
        await editModel.load(); await editModel.requestPlanPreview()
        let updatePreviewWire = await editTransport.recordedWires().last { $0.path.hasSuffix("/preview") && $0.path != "installment-purchases/preview" }!
        let replacement = try V15FixtureCodec.decoder.decode(V15InstallmentReplacementRequest.self, from: Data(updatePreviewWire.body.utf8))
        #expect(replacement.feeOccurredAt == ISO8601DateFormatter().date(from: "2026-08-15T01:00:00Z"))
        #expect(replacement.purchase.occurredAt == ISO8601DateFormatter().date(from: "2026-08-15T00:30:00Z"))
    }

    @MainActor @Test("existing purchase detail drives same-day late and later-day fee instants")
    func existingPurchaseUsesAuthoritativeOccurredAt() async throws {
        let latePurchaseAt = ISO8601DateFormatter().date(from: "2026-08-15T02:30:00Z")!
        let lateTransport = F3B2Transport(mode: .latePurchase)
        let lateModel = V15InstallmentModel(services: V15F3B2Fixtures.services(transport: lateTransport), now: { fixedNow })
        await lateModel.load(); lateModel.purchaseTransactionIDText = V15F3B2Fixtures.purchaseID.uuidString.lowercased(); await lateModel.checkEligibility()
        #expect(lateModel.eligibilityPurchasePhase == .loaded && lateModel.eligibilityPurchase?.occurredAt == latePurchaseAt)
        lateModel.createFeeText = "99.96"; lateModel.createFeeCategoryID = V15F3B2Fixtures.categoryID; lateModel.createFeeOccurredDateText = "2026-08-15"
        #expect(lateModel.createPlanDisabledReason == nil)
        await lateModel.createPlan()
        let lateWire = await lateTransport.recordedWires().last { $0.path == "installment-plans" && $0.method == "POST" }!
        let lateRequest = try V15FixtureCodec.decoder.decode(V15InstallmentCreateRequest.self, from: Data(lateWire.body.utf8))
        #expect(lateRequest.feeOccurredAt == latePurchaseAt)

        let priorTransport = F3B2Transport(mode: .priorDayPurchase)
        let priorModel = V15InstallmentModel(services: V15F3B2Fixtures.services(transport: priorTransport), now: { fixedNow })
        await priorModel.load(); priorModel.purchaseTransactionIDText = V15F3B2Fixtures.purchaseID.uuidString; await priorModel.checkEligibility()
        priorModel.createFeeText = "99.96"; priorModel.createFeeCategoryID = V15F3B2Fixtures.categoryID; priorModel.createFeeOccurredDateText = "2026-08-15"
        await priorModel.createPlan()
        let priorWire = await priorTransport.recordedWires().last { $0.path == "installment-plans" && $0.method == "POST" }!
        let priorRequest = try V15FixtureCodec.decoder.decode(V15InstallmentCreateRequest.self, from: Data(priorWire.body.utf8))
        #expect(priorRequest.feeOccurredAt == ISO8601DateFormatter().date(from: "2026-08-14T16:00:00Z"))
    }

    @MainActor @Test("backend-like fixture rejects fee instants outside purchase and now bounds")
    func backendLikeFixtureRejectsInvalidFeeInstant() async {
        let services = V15F3B2Fixtures.services(transport: F3B2Transport(mode: .normal))
        let purchaseAt = ISO8601DateFormatter().date(from: "2026-08-15T02:30:00Z")!
        let feeAt = ISO8601DateFormatter().date(from: "2026-08-15T01:00:00Z")!
        let draft = V15TransactionCreateRequest(kind: .creditPurchase, amountMinor: 329_900, occurredAt: purchaseAt, title: "工作设备", accountID: V15F3B2Fixtures.accountID, categoryID: V15F3B2Fixtures.categoryID)
        let request = V15InstallmentPurchaseCreateRequest(purchase: draft, installmentCount: 6, totalFeeMinor: 9_996, feeCategoryID: V15F3B2Fixtures.categoryID, feeOccurredAt: feeAt, startStatementDate: "2026-09-10")
        do {
            _ = try await services.installments.previewPurchase(request)
            Issue.record("backend-like fixture should reject fee before purchase")
        } catch let failure as V15Failure {
            #expect(failure.code == "invalid_installment_schedule")
            #expect(failure.fieldIssues.first?.fieldPath == "fee_occurred_at")
        } catch { Issue.record("unexpected error: \(error)") }
    }

    @MainActor @Test("purchase write callback remains owned after dismiss and editor changes for success unknown and failure")
    func purchaseOperationOwnershipRace() async throws {
        for outcome in [F3B2Transport.RaceOutcome.success, .unknown, .failure] {
            let transport = F3B2Transport(mode: .operationRace(.purchase, outcome))
            let model = V15InstallmentModel(services: V15F3B2Fixtures.services(transport: transport), now: { fixedNow })
            await model.load(); fillPurchase(model); await model.requestPurchasePreview()
            let write = Task { @MainActor in await model.commitPurchase() }
            try await waitForWire(transport, method: "POST", path: "installment-purchases")
            let ownerID = model.newPurchaseAccountID!
            let otherOwnerID = UUID(uuidString: "00000000-0000-0000-0000-00000000B499")!
            model.dismissEditor(); model.newPurchaseTitle = "另一个编辑器草稿"; model.newPurchaseAccountID = otherOwnerID
            #expect(model.purchasePhase == .idle && model.purchaseReceipt == nil && !model.hasUnknownPurchase)
            await write.value
            #expect(model.purchasePhase == .idle && model.purchaseReceipt == nil && !model.hasUnknownPurchase)
            model.newPurchaseAccountID = ownerID
            switch outcome {
            case .success: #expect(model.purchasePhase == .succeeded && model.purchaseReceipt != nil)
            case .unknown: #expect(model.purchasePhase == .unknown && model.hasUnknownPurchase)
            case .failure: if case .failed = model.purchasePhase {} else { Issue.record("expected deterministic purchase failure") }
            }
            #expect(await transport.recordedWires().filter { $0.path == "installment-purchases" && $0.method == "POST" }.count == 1)
        }
    }

    @MainActor @Test("existing-purchase create callback remains owned after dismiss and editor changes")
    func createOperationOwnershipRace() async throws {
        for outcome in [F3B2Transport.RaceOutcome.success, .unknown, .failure] {
            let transport = F3B2Transport(mode: .operationRace(.create, outcome))
            let model = V15InstallmentModel(services: V15F3B2Fixtures.services(transport: transport), now: { fixedNow })
            await model.load(); model.purchaseTransactionIDText = V15F3B2Fixtures.purchaseID.uuidString; await model.checkEligibility()
            let write = Task { @MainActor in await model.createPlan() }
            try await waitForWire(transport, method: "POST", path: "installment-plans")
            let ownerID = model.purchaseTransactionIDText
            let otherOwnerID = "00000000-0000-0000-0000-00000000B499"
            model.dismissEditor(); model.createInstallmentCountText = "12"; model.purchaseTransactionIDText = otherOwnerID
            #expect(model.createPlanPhase == .idle && !model.hasUnknownCreatePlan)
            await write.value
            #expect(model.createPlanPhase == .idle && !model.hasUnknownCreatePlan)
            model.purchaseTransactionIDText = ownerID
            switch outcome {
            case .success: #expect(model.createPlanPhase == .succeeded && !model.hasUnknownCreatePlan)
            case .unknown: #expect(model.createPlanPhase == .unknown && model.hasUnknownCreatePlan)
            case .failure: if case .failed = model.createPlanPhase {} else { Issue.record("expected deterministic create failure") }
            }
            #expect(await transport.recordedWires().filter { $0.path == "installment-plans" && $0.method == "POST" }.count == 1)
        }
    }

    @MainActor @Test("no-key PUT callback remains plan-scoped across selection changes and never retransmits")
    func updateOperationOwnershipRace() async throws {
        for outcome in [F3B2Transport.RaceOutcome.success, .unknown, .failure] {
            let transport = F3B2Transport(mode: .operationRace(.update, outcome))
            let model = V15InstallmentModel(services: V15F3B2Fixtures.services(transport: transport), now: { fixedNow })
            await model.load(); model.editTitle = "更新后的设备计划"; model.editAmountText = "3399.00"; model.editCountText = "7"; await model.requestPlanPreview()
            let write = Task { @MainActor in await model.commitPlanUpdate() }
            let path = "installment-plans/\(V15F3B2Fixtures.activePlanID)"
            try await waitForWire(transport, method: "PUT", path: path)
            let other = model.plans.first { $0.id == V15F3B2Fixtures.completedPlanID }!
            await model.selectPlan(other); model.dismissEditor(); model.editTitle = "B 计划独立草稿"
            #expect(model.planMutationDisabledReason == nil)
            await write.value
            #expect(model.selectedPlan?.id == other.id)
            let owner = model.plans.first { $0.id == V15F3B2Fixtures.activePlanID }!
            await model.selectPlan(owner)
            switch outcome {
            case .success: #expect(model.planPhase == .succeeded && !model.hasUnknownPlanUpdate)
            case .unknown: #expect(model.planPhase == .unknown && model.hasUnknownPlanUpdate)
            case .failure: if case .failed = model.planPhase {} else { Issue.record("expected deterministic PUT failure") }
            }
            #expect(await transport.recordedWires().filter { $0.method == "PUT" }.count == 1)
        }
    }

    @MainActor @Test("idempotent command callback remains plan-scoped across selection changes")
    func commandOperationOwnershipRace() async throws {
        for outcome in [F3B2Transport.RaceOutcome.success, .unknown, .failure] {
            let transport = F3B2Transport(mode: .operationRace(.command, outcome))
            let model = V15InstallmentModel(services: V15F3B2Fixtures.services(transport: transport), now: { fixedNow })
            await model.load(); await model.requestCommandPreview()
            let write = Task { @MainActor in await model.commitCommand() }
            let path = "installment-plans/\(V15F3B2Fixtures.activePlanID)/settle-early"
            try await waitForWire(transport, method: "POST", path: path)
            let other = model.plans.first { $0.id == V15F3B2Fixtures.completedPlanID }!
            await model.selectPlan(other); model.dismissEditor(); #expect(model.planMutationDisabledReason == nil)
            await write.value; #expect(model.selectedPlan?.id == other.id)
            let owner = model.plans.first { $0.id == V15F3B2Fixtures.activePlanID }!
            await model.selectPlan(owner)
            switch outcome {
            case .success: #expect(model.commandPhase == .succeeded && model.commandReceipt != nil && !model.hasUnknownCommand)
            case .unknown: #expect(model.commandPhase == .unknown && model.hasUnknownCommand)
            case .failure: if case .failed = model.commandPhase {} else { Issue.record("expected deterministic command failure") }
            }
            let writes = await transport.recordedWires().filter { $0.path == path && $0.method == "POST" }
            #expect(writes.count == 1 && writes.first?.key != nil)
        }
    }

    @MainActor @Test("opaque keyset failure retains the loaded page and exposes retry")
    func pageFailureRetainsFacts() async {
        let model = V15InstallmentModel(services: V15F3B2Fixtures.services(route: "installments-page-error"), now: { fixedNow })
        await model.load(); await model.loadNextPage()
        #expect(model.plans.count == 6)
        if case .failed(let failure) = model.pagePhase { #expect(failure.message.contains("下一页")) } else { Issue.record("expected local page failure") }
    }

    @MainActor @Test("eligibility reason is server-owned and transaction input invalidates derived options")
    func eligibilityAndInvalidation() async {
        let model = V15InstallmentModel(services: V15F3B2Fixtures.services(route: "installments-ineligible"), now: { fixedNow })
        await model.load(); model.purchaseTransactionIDText = V15F3B2Fixtures.purchaseID.uuidString; await model.checkEligibility()
        #expect(model.eligibility?.eligible == false)
        #expect(model.createPlanDisabledReason?.code == "installment_plan_in_use")
        model.purchaseTransactionIDText = UUID().uuidString
        #expect(model.eligibility == nil && model.cycleOptions.isEmpty)
    }

    @MainActor @Test("eligibility UUID ownership is case-insensitive and stale mixed-case response cannot write")
    func eligibilityUUIDValueOwnership() async throws {
        let model = V15InstallmentModel(services: V15F3B2Fixtures.services(), now: { fixedNow })
        await model.load()
        let mixed = String(V15F3B2Fixtures.purchaseID.uuidString.enumerated().map { item in
            item.offset.isMultiple(of: 2) ? Character(String(item.element).lowercased()) : Character(String(item.element).uppercased())
        })
        model.purchaseTransactionIDText = mixed
        await model.checkEligibility()
        #expect(model.eligibilityPhase == .loaded && model.eligibilityPurchasePhase == .loaded)
        #expect(model.eligibility?.purchaseTransactionID == V15F3B2Fixtures.purchaseID)
        #expect(model.eligibilityPurchase?.id == V15F3B2Fixtures.purchaseID)
        #expect(model.createPlanDisabledReason == nil)

        let equivalentCaseTransport = F3B2Transport(mode: .eligibilityRace)
        let equivalentCaseModel = V15InstallmentModel(
            services: V15F3B2Fixtures.services(transport: equivalentCaseTransport),
            now: { fixedNow }
        )
        await equivalentCaseModel.load()
        equivalentCaseModel.purchaseTransactionIDText = V15F3B2Fixtures.purchaseID.uuidString.lowercased()
        let equivalentCaseLoad = Task { @MainActor in await equivalentCaseModel.checkEligibility() }
        try await Task.sleep(for: .milliseconds(20))
        equivalentCaseModel.purchaseTransactionIDText = V15F3B2Fixtures.purchaseID.uuidString.uppercased()
        await equivalentCaseLoad.value
        #expect(equivalentCaseModel.eligibilityPhase == .loaded && equivalentCaseModel.eligibilityPurchasePhase == .loaded)
        #expect(equivalentCaseModel.eligibility?.purchaseTransactionID == V15F3B2Fixtures.purchaseID)
        #expect(equivalentCaseModel.eligibilityPurchase?.id == V15F3B2Fixtures.purchaseID)
        #expect(equivalentCaseModel.createPlanDisabledReason == nil)

        let raceTransport = F3B2Transport(mode: .eligibilityRace)
        let raceModel = V15InstallmentModel(services: V15F3B2Fixtures.services(transport: raceTransport), now: { fixedNow })
        await raceModel.load(); raceModel.purchaseTransactionIDText = V15F3B2Fixtures.purchaseID.uuidString.lowercased()
        let stale = Task { @MainActor in await raceModel.checkEligibility() }
        try await Task.sleep(for: .milliseconds(20))
        raceModel.purchaseTransactionIDText = UUID().uuidString
        await stale.value
        #expect(raceModel.eligibility == nil && raceModel.eligibilityPurchase == nil && raceModel.cycleOptions.isEmpty)
        #expect(raceModel.eligibilityPhase == .idle && raceModel.eligibilityPurchasePhase == .idle)
    }

    @MainActor @Test("existing purchase detail has independent failure and retry state")
    func eligibilityPurchaseDetailFailureRetry() async {
        let transport = F3B2Transport(mode: .transactionDetailFailureThenSuccess)
        let model = V15InstallmentModel(services: V15F3B2Fixtures.services(transport: transport), now: { fixedNow })
        await model.load(); model.purchaseTransactionIDText = V15F3B2Fixtures.purchaseID.uuidString.lowercased(); await model.checkEligibility()
        #expect(model.eligibilityPhase == .loaded && model.eligibility?.eligible == true)
        if case .failed = model.eligibilityPurchasePhase {} else { Issue.record("expected independent purchase detail failure") }
        #expect(model.createPlanDisabledReason?.code == "purchase_detail_failed")
        await model.checkEligibility()
        #expect(model.eligibilityPurchasePhase == .loaded && model.eligibilityPurchase?.occurredAt != nil)
        #expect(model.createPlanDisabledReason == nil)
    }

    @MainActor @Test("purchase preview becomes invalid after valid or invalid input changes")
    func purchasePreviewInvalidation() async {
        let model = V15InstallmentModel(services: V15F3B2Fixtures.services(), now: { fixedNow })
        await model.load()
        model.newPurchaseTitle = "工作设备"; model.newPurchaseAmountText = "3299.00"; model.newPurchaseAccountID = V15F3B2Fixtures.accountID; model.newPurchaseCategoryID = V15F3B2Fixtures.categoryID; model.newPurchaseCountText = "6"; model.newPurchaseFeeText = "99.96"; model.newPurchaseFeeCategoryID = V15F3B2Fixtures.categoryID; model.newPurchaseFeeOccurredDateText = "2026-08-15"; model.newPurchaseStartStatementDate = "2026-09-10"
        await model.requestPurchasePreview()
        #expect(model.purchasePreview != nil && model.purchaseCommitDisabledReason == nil)
        model.newPurchaseAmountText = "invalid"
        #expect(model.purchasePreview == nil)
        #expect(model.purchaseCommitDisabledReason?.code == "amount_invalid")
        #expect(model.purchaseCommitDisabledReason?.fieldPath == "purchase.amount_minor")
    }

    @MainActor @Test("purchase preview and unknown retry preserve one exact body and idempotency key")
    func purchaseUnknownSameRequest() async {
        let transport = F3B2Transport(mode: .purchaseUnknownThenSuccess)
        var tick: TimeInterval = 0
        let model = V15InstallmentModel(services: V15F3B2Fixtures.services(transport: transport), now: { self.fixedNow.addingTimeInterval({ tick += 1; return tick }()) })
        await model.load()
        model.newPurchaseTitle = "工作设备"; model.newPurchaseAmountText = "3299.00"; model.newPurchaseAccountID = V15F3B2Fixtures.accountID; model.newPurchaseCategoryID = V15F3B2Fixtures.categoryID; model.newPurchaseCountText = "6"; model.newPurchaseFeeText = "99.96"; model.newPurchaseFeeCategoryID = V15F3B2Fixtures.categoryID; model.newPurchaseFeeOccurredDateText = "2026-08-15"; model.newPurchaseStartStatementDate = "2026-09-10"
        await model.requestPurchasePreview(); await model.commitPurchase()
        #expect(model.hasUnknownPurchase)
        #expect(model.purchasePreviewDisabledReason?.code == "unknown_purchase_pending")
        await model.retryUnknownPurchase()
        #expect(!model.hasUnknownPurchase && model.purchaseReceipt != nil)
        let wires = await transport.recordedWires()
        let preview = wires.first { $0.path == "installment-purchases/preview" }!
        let writes = wires.filter { $0.path == "installment-purchases" && $0.method == "POST" }
        #expect(writes.count == 2)
        #expect(preview.body == writes[0].body)
        #expect(writes[0].body == writes[1].body && writes[0].key == writes[1].key)
    }

    @MainActor @Test("existing purchase plan creation unknown retries exact body and key")
    func createPlanUnknownSameRequest() async {
        let transport = F3B2Transport(mode: .createUnknownThenSuccess)
        let model = V15InstallmentModel(services: V15F3B2Fixtures.services(transport: transport), now: { fixedNow })
        await model.load(); model.purchaseTransactionIDText = V15F3B2Fixtures.purchaseID.uuidString; await model.checkEligibility()
        await model.createPlan(); #expect(model.hasUnknownCreatePlan)
        model.createInstallmentCountText = "12"
        #expect(model.createPlanDisabledReason?.code == "unknown_create_pending")
        await model.retryUnknownCreatePlan()
        let writes = await transport.recordedWires().filter { $0.path == "installment-plans" && $0.method == "POST" }
        #expect(writes.count == 2)
        #expect(writes[0].body == writes[1].body && writes[0].key == writes[1].key)
        #expect(!model.hasUnknownCreatePlan)
    }

    @MainActor @Test("plan preview input and dismiss invalidation never preserve an actionable preview")
    func planPreviewInvalidation() async {
        let model = V15InstallmentModel(services: V15F3B2Fixtures.services(), now: { fixedNow })
        await model.load(); await model.requestPlanPreview()
        #expect(model.planPreview != nil && model.planCommitDisabledReason == nil)
        model.editCountText = "not-a-number"
        #expect(model.planPreview == nil && model.planCommitDisabledReason?.code == "count_invalid")
        #expect(model.planCommitDisabledReason?.fieldPath == "installment_count")
        model.editCountText = "7"; await model.requestPlanPreview(); #expect(model.planPreview != nil)
        model.dismissEditor(); #expect(model.planPreview == nil)
    }

    @MainActor @Test("no-key PUT response unknown performs only fresh GET plan and purchase and never retransmits PUT")
    func updateUnknownConfirmedByFreshReadback() async {
        let transport = F3B2Transport(mode: .updateUnknownConfirmed)
        let model = V15InstallmentModel(services: V15F3B2Fixtures.services(transport: transport), now: { fixedNow })
        await model.load(); model.editTitle = "更新后的设备计划"; model.editAmountText = "3399.00"; model.editCountText = "7"
        await model.requestPlanPreview(); await model.commitPlanUpdate()
        #expect(model.hasUnknownPlanUpdate)
        await model.readBackUnknownPlanUpdate()
        #expect(model.updateReadbackPhase == .confirmed && !model.hasUnknownPlanUpdate)
        let wires = await transport.recordedWires()
        #expect(wires.filter { $0.method == "PUT" }.count == 1)
        let fresh = wires.filter { $0.method == "GET" && $0.readCachePolicy == .reloadIgnoringCache }
        #expect(fresh.contains { $0.path == "installment-plans/\(V15F3B2Fixtures.activePlanID)" })
        #expect(fresh.contains { $0.path == "transactions/\(V15F3B2Fixtures.purchaseID)" })
    }

    @MainActor @Test("no-key PUT mismatch or readback failure stays unknown without a second PUT")
    func updateUnknownNotConfirmed() async {
        for mode in [F3B2Transport.Mode.updateUnknownNotConfirmed, .updateUnknownFeeDateMismatch, .updateUnknownReadbackFailure] {
            let transport = F3B2Transport(mode: mode)
            let model = V15InstallmentModel(services: V15F3B2Fixtures.services(transport: transport), now: { fixedNow })
            await model.load(); model.editTitle = "更新后的设备计划"; model.editAmountText = "3399.00"; model.editCountText = "7"
            await model.requestPlanPreview(); await model.commitPlanUpdate(); await model.readBackUnknownPlanUpdate()
            #expect(model.hasUnknownPlanUpdate)
            if mode == .updateUnknownNotConfirmed || mode == .updateUnknownFeeDateMismatch { #expect(model.updateReadbackPhase == .notConfirmed) }
            else if case .failed = model.updateReadbackPhase {} else { Issue.record("expected failed fresh readback") }
            #expect(await transport.recordedWires().filter { $0.method == "PUT" }.count == 1)
        }
    }

    @MainActor @Test("unknown command retries exact body and same key then displays operation receipt")
    func commandUnknownSameKey() async {
        let transport = F3B2Transport(mode: .commandUnknownThenSuccess)
        let model = V15InstallmentModel(services: V15F3B2Fixtures.services(transport: transport), now: { fixedNow })
        await model.load(); await model.requestCommandPreview(); await model.commitCommand()
        #expect(model.hasUnknownCommand)
        #expect(model.commandPreviewDisabledReason?.code == "unknown_command_pending")
        await model.readBackUnknownCommand()
        #expect(model.commandReadbackPhase == .notConfirmed)
        #expect(model.hasUnknownCommand && model.commandPhase == .unknown)
        #expect(model.selectedPlan?.status == .settledEarly)
        await model.retryUnknownCommand()
        #expect(!model.hasUnknownCommand)
        #expect(model.commandReceipt?.operationID == V15F3B2Fixtures.operationID)
        #expect(model.commandReceipt?.replayed == true)
        #expect(model.commandReceipt?.systemTransactions.map(\.title) == ["提前结清还款"])
        let commands = await transport.recordedWires().filter { $0.path.hasSuffix("/settle-early") }
        #expect(commands.count == 2)
        #expect(commands[0].key == commands[1].key && commands[0].body == commands[1].body)
    }

    @MainActor @Test("unknown command remains owned by its plan across selection changes")
    func commandOwnership() async {
        let model = V15InstallmentModel(services: V15F3B2Fixtures.services(route: "installments-command-unknown"), now: { fixedNow })
        await model.load(); let first = model.selectedPlan!; await model.requestCommandPreview(); await model.commitCommand(); #expect(model.hasUnknownCommand)
        let second = model.plans.first { $0.id == V15F3B2Fixtures.completedPlanID }!; await model.selectPlan(second)
        #expect(!model.hasUnknownCommand)
        await model.selectPlan(first)
        #expect(model.hasUnknownCommand && model.commandPhase == .unknown)
    }

    @MainActor @Test("offline snapshot dispatches no preview or command writes and shows reasons")
    func offlineZeroWrite() async {
        let transport = F3B2Transport(mode: .normal)
        let model = V15InstallmentModel(services: V15F3B2Fixtures.services(transport: transport), offlineSnapshotAt: fixedNow, now: { fixedNow })
        await model.load(); let before = await transport.recordedWires().count
        await model.requestPlanPreview(); await model.requestCommandPreview(); await model.commitCommand()
        let after = await transport.recordedWires()
        #expect(after.count == before)
        #expect(model.planPreviewDisabledReason?.code == "offline_read_only")
        #expect(model.commandPreviewDisabledReason?.code == "offline_read_only")
    }

    @MainActor @Test("slow detail A cannot overwrite fast selected plan B")
    func detailRace() async throws {
        let transport = F3B2Transport(mode: .detailRace)
        let model = V15InstallmentModel(services: V15F3B2Fixtures.services(transport: transport), now: { fixedNow })
        await model.load()
        let first = model.plans.first { $0.id == V15F3B2Fixtures.activePlanID }!
        let second = model.plans.first { $0.id == V15F3B2Fixtures.completedPlanID }!
        let slow = Task { @MainActor in await model.selectPlan(first) }
        try await Task.sleep(for: .milliseconds(20)); await model.selectPlan(second); await slow.value
        #expect(model.selectedPlan?.id == second.id)
        #expect(model.selectedPlan?.status == .completed)
    }

    @MainActor @Test("all three command services send backend endpoint names and stable idempotency header")
    func commandWireMatrix() async throws {
        let transport = F3B2Transport(mode: .normal); let services = V15F3B2Fixtures.services(transport: transport)
        let action = V15InstallmentActionRequest(expectedVersion: 3, occurredAt: fixedNow)
        let settlement = V15InstallmentSettlementRequest(expectedVersion: 3, occurredAt: fixedNow, paymentAccountID: V15F3B2Fixtures.paymentID, targetStatementDate: "2026-09-10")
        _ = try await services.installments.settleEarly(planID: V15F3B2Fixtures.activePlanID, request: settlement, idempotencyKey: UUID())
        _ = try await services.installments.reverseSettlement(planID: V15F3B2Fixtures.activePlanID, request: action, idempotencyKey: UUID())
        _ = try await services.installments.cancelFuture(planID: V15F3B2Fixtures.activePlanID, request: action, idempotencyKey: UUID())
        let wires = await transport.recordedWires().filter { $0.method == "POST" && $0.key != nil }
        #expect(Set(wires.map(\.path)) == ["installment-plans/\(V15F3B2Fixtures.activePlanID)/settle-early", "installment-plans/\(V15F3B2Fixtures.activePlanID)/reverse-settlement", "installment-plans/\(V15F3B2Fixtures.activePlanID)/cancel-future"])
        #expect(wires.allSatisfy { UUID(uuidString: $0.key ?? "") != nil })
    }
}
