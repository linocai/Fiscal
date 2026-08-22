import Foundation
import Testing
@testable import FiscalKit

@Suite("F3-D typed cash-flow facts and mutations")
struct F3DTests {
    private let fixedNow = ISO8601DateFormatter().date(from: "2026-08-16T08:00:00Z")!

    @MainActor private func loadedModel(_ transport: F3DTransport = F3DTransport(mode: .normal), offline: Bool = false) async -> V15CashFlowModel {
        let services = V15Services(transport: transport)
        let model = V15CashFlowModel(services: services, offlineSnapshotAt: offline ? fixedNow : nil, now: { fixedNow })
        await model.load()
        return model
    }

    @MainActor private func fillCreate(_ model: V15CashFlowModel) {
        model.openCreate()
        model.title = "新建现金流"
        model.amountText = "123.45"
        model.expectedDateText = "2026-08-28"
        model.selectedAccountID = V15F3DFixtures.cashAccountID
    }

    @Test("server status direction action and 64-bit amounts decode without inference")
    func typedFactDecode() throws {
        let active = try V15FixtureCodec.decoder.decode(V15CashFlowActiveResponse.self, from: Data(V15F3DFixtures.active().utf8))
        let item = try #require(active.items.first)
        #expect(item.seriesID == V15F3DFixtures.seriesID)
        #expect(item.status == .expected)
        #expect(item.actions == [.confirm, .edit, .cancel])
        #expect(active.items.first { $0.systemKind == .creditCycle }?.accountID == V15F3DFixtures.creditAccountID)

        let history = try V15FixtureCodec.decoder.decode(V15CashFlowHistoryResponse.self, from: Data(V15F3DFixtures.history().utf8))
        #expect(history.items.first?.plannedAmountMinor == 922_337_203_685_477)
        #expect(history.items.first?.status == .settled)

        let future = V15F3DFixtures.item(direction: "sideways", status: "future_state", actions: "[\"future_action\"]")
        let unknown = try V15FixtureCodec.decoder.decode(V15CashFlowItem.self, from: Data(future.utf8))
        #expect(unknown.direction == .unknown("sideways"))
        #expect(unknown.status == .unknown("future_state"))
        #expect(unknown.actions == [.unknown("future_action")])
        #expect(unknown.isDisplayOnly)
    }

    @MainActor @Test("typed service emits exact routes keys scopes and settlement body")
    func typedServiceWires() async throws {
        let transport = F3DTransport(mode: .normal)
        let service = V15Services(transport: transport).cashFlow
        _ = try await service.active(accountID: V15F3DFixtures.cashAccountID)
        _ = try await service.history(month: "2026-08")
        _ = try await service.item(id: V15F3DFixtures.itemID)

        let draft = V15CashFlowDraft(title: "新建现金流", direction: .outflow, plannedAmountMinor: 12_345, expectedDate: "2026-08-28", accountID: V15F3DFixtures.cashAccountID)
        let createKey = UUID()
        _ = try await service.create(draft, idempotencyKey: createKey)
        _ = try await service.update(itemID: V15F3DFixtures.itemID, request: .init(draft: draft, expectedVersion: 3, scope: .thisAndFuture))
        _ = try await service.confirm(itemID: V15F3DFixtures.itemID, request: .init(expectedVersion: 3))
        _ = try await service.cancel(itemID: V15F3DFixtures.transferID, request: .init(expectedVersion: 2))
        let occurredAt = try #require(ISO8601DateFormatter().date(from: "2026-08-16T04:00:00Z"))
        let settleKey = UUID()
        let settlement = V15CashFlowSettlementDraft(expectedVersion: 2, actualAmountMinor: 80_000, occurredAt: occurredAt, accountID: V15F3DFixtures.cashAccountID, destinationAccountID: V15F3DFixtures.debitAccountID, title: "储蓄调拨", note: "落账")
        _ = try await service.settle(itemID: V15F3DFixtures.transferID, request: settlement, idempotencyKey: settleKey)
        _ = try await service.updateSystem(kind: .reimbursement, referenceID: V15F3DFixtures.reimbursementID, request: .init(title: "报销展示标题", note: nil, expectedDate: "2026-08-23", status: .confirmed, expectedVersion: 1))

        let requests = await transport.allRequests()
        #expect(requests.first { $0.path == "cash-flow-items" && $0.method == "GET" }?.query == [.init(name: "account_id", value: V15F3DFixtures.cashAccountID.uuidString)])
        #expect(requests.first { $0.path == "cash-flow-items/history" }?.query == [.init(name: "month", value: "2026-08")])
        #expect(requests.contains { $0.path == "cash-flow-items/\(V15F3DFixtures.itemID)" && $0.method == "GET" })
        let wires = await transport.mutationWires()
        #expect(wires.first { $0.path == "cash-flow-items" }?.key == createKey.uuidString)
        #expect(wires.first { $0.path.hasSuffix("/settle") }?.key == settleKey.uuidString)
        #expect(wires.filter { !$0.path.hasSuffix("/settle") && $0.path != "cash-flow-items" }.allSatisfy { $0.key == nil })
        let settleWire = try #require(wires.first { $0.path.hasSuffix("/settle") })
        let decoded = try V15FixtureCodec.decoder.decode(V15CashFlowSettlementDraft.self, from: Data(settleWire.body.utf8))
        #expect(decoded == settlement)
        let updateWire = try #require(wires.first { $0.method == "PUT" && $0.path.hasPrefix("cash-flow-items/") })
        #expect(updateWire.body.contains("\"scope\":\"this_and_future\""))
        #expect(!updateWire.body.contains("\"recurrence\""))
        #expect(!updateWire.body.contains("\"recurrence_end_date\""))
        let systemWire = try #require(wires.first { $0.path.hasPrefix("cash-flow-system-items/") })
        #expect(!systemWire.body.contains("\"planned_amount_minor\""))
        #expect(wires.first { $0.path.hasSuffix("/confirm") }?.body.contains("expected_version") == true)
    }

    @MainActor @Test("active history and manual detail remain independently retriable")
    func independentReadsAndDetail() async throws {
        let historyFailure = await loadedModel(F3DTransport(mode: .historyError))
        #expect(historyFailure.phase == .loaded)
        if case .failed = historyFailure.historyPhase {} else { Issue.record("expected independent history failure") }

        let initialFailureTransport = F3DTransport(mode: .initialError)
        let initialFailure = await loadedModel(initialFailureTransport)
        if case .failed = initialFailure.phase {} else { Issue.record("expected active failure") }
        #expect(initialFailure.historyPhase == .loaded)
        await initialFailure.refresh()
        #expect(initialFailure.phase == .loaded)

        let item = try #require(initialFailure.active?.items.first)
        await initialFailure.selectItem(item)
        #expect(initialFailure.detailPhase == .loaded)
        #expect(initialFailure.selectedItem?.manualItemID == V15F3DFixtures.itemID)
    }

    @MainActor @Test("CNY Shanghai and transfer account constraints share submit guards")
    func validationAndSettlement() async throws {
        let transport = F3DTransport(mode: .normal)
        let model = await loadedModel(transport)
        fillCreate(model)
        model.amountText = "12.345"
        #expect(model.createReasons.contains { $0.fieldPath == "planned_amount_minor" })
        model.amountText = "123.45"
        model.direction = .transfer
        model.selectedDestinationAccountID = V15F3DFixtures.cashAccountID
        #expect(model.createReasons.contains { $0.code == "transfer_same_account" })
        model.selectedDestinationAccountID = V15F3DFixtures.debitAccountID
        #expect(model.createReasons.isEmpty)

        let transfer = try #require(model.active?.items.first { $0.id == V15F3DFixtures.transferID.uuidString })
        await model.selectItem(transfer)
        model.openSettle(try #require(model.selectedItem))
        model.settleAmountText = "800.00"
        model.settleDateText = "2026-08-16"
        model.settleAccountID = V15F3DFixtures.cashAccountID
        model.settleDestinationAccountID = V15F3DFixtures.cashAccountID
        #expect(model.settleReasons.contains { $0.code == "transfer_same_account" })
        model.settleDestinationAccountID = V15F3DFixtures.creditAccountID
        #expect(model.settleReasons.contains { $0.code == "destination_kind_invalid" })
        model.settleDestinationAccountID = V15F3DFixtures.debitAccountID
        #expect(model.settleReasons.isEmpty)
        await model.settle()
        #expect(model.mutationPhase == .succeeded)
        let wire = try #require(await transport.mutationWires().first { $0.path.hasSuffix("/settle") })
        let body = try V15FixtureCodec.decoder.decode(V15CashFlowSettlementDraft.self, from: Data(wire.body.utf8))
        #expect(body.actualAmountMinor == 80_000)
        #expect(ShanghaiBusinessDate.string(for: body.occurredAt) == "2026-08-16")
        #expect(model.selectedItem?.status == .settled)

        let beforeNoon = try #require(ISO8601DateFormatter().date(from: "2026-08-16T00:30:00Z"))
        let morning = V15CashFlowModel(services: V15F3DFixtures.services(), now: { beforeNoon })
        await morning.load()
        let morningTransfer = try #require(morning.active?.items.first { $0.id == V15F3DFixtures.transferID.uuidString })
        await morning.selectItem(morningTransfer)
        morning.openSettle(try #require(morning.selectedItem))
        morning.settleDateText = "2026-08-16"
        #expect(!morning.settleReasons.contains { $0.code == "future_settlement" })
        morning.settleDateText = "2026-08-17"
        #expect(morning.settleReasons.contains { $0.code == "future_settlement" })
    }

    @MainActor @Test("create and settle unknown recover with the identical immutable key and body")
    func stableSameKeyRecovery() async throws {
        let createTransport = F3DTransport(mode: .createUnknown)
        let createModel = await loadedModel(createTransport)
        fillCreate(createModel)
        await createModel.create()
        #expect(createModel.mutationPhase == .unknown && createModel.hasUnknownStableAttempt)
        createModel.title = "输入变化不能改写已封存请求"
        await createModel.retryUnknownStable()
        #expect(createModel.mutationPhase == .succeeded)
        let createWires = await createTransport.mutationWires().filter { $0.path == "cash-flow-items" }
        #expect(createWires.count == 2)
        #expect(createWires[0].key == createWires[1].key && createWires[0].body == createWires[1].body)

        let settleTransport = F3DTransport(mode: .settleUnknown)
        let settleModel = await loadedModel(settleTransport)
        let transfer = try #require(settleModel.active?.items.first { $0.id == V15F3DFixtures.transferID.uuidString })
        await settleModel.selectItem(transfer); settleModel.openSettle(try #require(settleModel.selectedItem))
        settleModel.settleDateText = "2026-08-16"; settleModel.settleAmountText = "800.00"
        await settleModel.settle()
        #expect(settleModel.mutationPhase == .unknown && settleModel.hasUnknownStableAttempt)
        settleModel.settleAmountText = "900.00"
        await settleModel.retryUnknownStable()
        #expect(settleModel.mutationPhase == .succeeded)
        let settleWires = await settleTransport.mutationWires().filter { $0.path.hasSuffix("/settle") }
        #expect(settleWires.count == 2)
        #expect(settleWires[0].key == settleWires[1].key && settleWires[0].body == settleWires[1].body)
    }

    @MainActor @Test("keyless unknown does zero resend and only fresh GET permits explicit abandon")
    func directUnknownReadback() async throws {
        let transport = F3DTransport(mode: .directUnknown)
        let model = await loadedModel(transport)
        let item = try #require(model.active?.items.first)
        await model.selectItem(item); model.openEdit(try #require(model.selectedItem)); model.title = "结果未知修改"
        await model.update()
        #expect(model.mutationPhase == .unknown && model.hasUnknownDirectAttempt)
        #expect(await transport.mutationWires().count == 1)
        #expect(!model.canAbandonUnknownDirect)
        await model.readBackUnknownDirect()
        #expect(model.mutationPhase == .unknown && model.canAbandonUnknownDirect)
        #expect(await transport.mutationWires().count == 1)
        #expect(await transport.allRequests().contains { $0.method == "GET" && $0.path == "cash-flow-items/\(V15F3DFixtures.itemID)" && $0.readCachePolicy == .reloadIgnoringCache })
        model.abandonUnknownDirect()
        #expect(!model.writeLocked && model.mutationPhase == .idle)
    }

    @MainActor @Test("409 and field issues remain truthful and scoped to their editor")
    func conflictAndFieldIssues() async throws {
        let conflictModel = await loadedModel(F3DTransport(mode: .conflict))
        let conflictItem = try #require(conflictModel.active?.items.first)
        await conflictModel.selectItem(conflictItem); conflictModel.openEdit(try #require(conflictModel.selectedItem))
        await conflictModel.update()
        if case .conflict(let value) = conflictModel.mutationPhase { #expect(value.currentVersion == 4 && value.expectedVersion == 3) } else { Issue.record("expected conflict") }
        await conflictModel.reloadAfterConflict()
        #expect(conflictModel.phase == .loaded && conflictModel.historyPhase == .loaded)

        let fieldModel = await loadedModel(F3DTransport(mode: .fieldError))
        fillCreate(fieldModel); await fieldModel.create()
        #expect(Set(fieldModel.serverIssues.compactMap(\.fieldPath)) == ["title", "account_id"])
        fieldModel.title = "修正输入"
        #expect(fieldModel.serverIssues.isEmpty)
    }

    @MainActor @Test("offline blocks every write and system override wire omits D5 amount")
    func offlineAndSystemD5() async throws {
        let offlineTransport = F3DTransport(mode: .normal)
        let offline = await loadedModel(offlineTransport, offline: true)
        fillCreate(offline); await offline.create()
        let item = try #require(offline.active?.items.first)
        await offline.perform(.cancel, on: item)
        #expect(await offlineTransport.mutationWires().isEmpty)
        #expect(offline.createReasons.contains { $0.code == "offline_read_only" })

        let transport = F3DTransport(mode: .normal)
        let model = await loadedModel(transport)
        let reimbursement = try #require(model.active?.items.first { $0.systemKind == .reimbursement })
        model.openEdit(reimbursement); model.title = "报销展示标题"; model.expectedDateText = "2026-08-23"; model.amountText = "0.01"
        await model.updateSystem()
        let wire = try #require(await transport.mutationWires().first { $0.path.hasPrefix("cash-flow-system-items/") })
        let body = try V15FixtureCodec.decoder.decode(V15CashFlowSystemReplace.self, from: Data(wire.body.utf8))
        #expect(body.status == .confirmed)
        #expect(!wire.body.contains("planned_amount_minor"))
        let credit = try #require(model.active?.items.first { $0.systemKind == .creditCycle })
        model.openEdit(credit)
        #expect(model.systemUpdateReasons.contains { $0.code == "credit_projection_read_only" })
    }

    @MainActor @Test("accepted write partial refresh retries GET only")
    func partialRefreshGate() async throws {
        let transport = F3DTransport(mode: .refreshFailure)
        let model = await loadedModel(transport)
        fillCreate(model); await model.create()
        #expect(model.hasFactRefreshGate)
        if case .failed = model.mutationPhase {} else { Issue.record("expected refresh failure after accepted write") }
        let mutations = await transport.mutationWires()
        let requestCount = await transport.allRequests().count
        await model.retryFactRefresh()
        #expect(await transport.mutationWires() == mutations)
        #expect(await transport.allRequests().count > requestCount)
        #expect(model.hasFactRefreshGate)
    }

    @MainActor @Test("generation and operation owner guards reject stale selection and list writes")
    func ownerAndGenerationGuards() async throws {
        let transport = F3DTransport(mode: .selectionRace)
        let services = V15Services(transport: transport)
        let loadModel = V15CashFlowModel(services: services, now: { fixedNow })
        let oldLoad = Task { @MainActor in await loadModel.load() }
        try await Task.sleep(for: .milliseconds(20))
        await loadModel.setAccountFilter(V15F3DFixtures.cashAccountID)
        await oldLoad.value
        #expect(loadModel.accountFilterID == V15F3DFixtures.cashAccountID)
        #expect(loadModel.phase == .loaded)

        let item = try #require(loadModel.active?.items.first { $0.id == V15F3DFixtures.itemID.uuidString })
        await loadModel.selectItem(item); loadModel.openEdit(try #require(loadModel.selectedItem)); loadModel.title = "慢速修改"
        let update = Task { @MainActor in await loadModel.update() }
        try await Task.sleep(for: .milliseconds(20))
        let transfer = try #require(loadModel.active?.items.first { $0.id == V15F3DFixtures.transferID.uuidString })
        await loadModel.selectItem(transfer)
        await update.value
        #expect(loadModel.selectedItem?.id == V15F3DFixtures.transferID.uuidString)
        #expect(loadModel.mutationPhase == .succeeded)
    }

    @MainActor @Test("A to B account filter race clears old detail editor and actions")
    func accountSelectionScopeRace() async throws {
        let model = await loadedModel(F3DTransport(mode: .selectionRace))
        let oldItem = try #require(model.active?.items.first)
        await model.selectItem(oldItem)
        model.openEdit(try #require(model.selectedItem))
        #expect(model.editorMode != .none)

        let slowA = Task { @MainActor in
            await model.setAccountFilter(V15F3DFixtures.cashAccountID)
        }
        try await Task.sleep(for: .milliseconds(20))
        await model.setAccountFilter(V15F3DFixtures.debitAccountID)
        await slowA.value

        #expect(model.accountFilterID == V15F3DFixtures.debitAccountID)
        #expect(model.phase == .empty)
        #expect(model.selectedItem == nil)
        #expect(model.editorMode == .none)
        #expect(model.detailPhase == .idle)
    }

    @MainActor @Test("history month race auto-selects only the current month token")
    func historySelectionScopeRace() async throws {
        let model = await loadedModel(F3DTransport(mode: .selectionRace))
        await model.setVisibleList(.history)
        let august = try #require(model.selectedItem)
        #expect(august.id == V15F3DFixtures.historyID.uuidString)
        model.openEdit(august)

        let slowAugust = Task { @MainActor in await model.setHistoryMonth("2026-08") }
        try await Task.sleep(for: .milliseconds(20))
        await model.setHistoryMonth("2026-07")
        await slowAugust.value

        #expect(model.historyMonth == "2026-07")
        #expect(model.history?.month == "2026-07")
        #expect(model.selectedItem?.id == V15F3DFixtures.julyHistoryID.uuidString)
        #expect(model.editorMode == .none)
        #expect(model.detailPhase == .loaded)
    }

    @MainActor @Test("server action and scope are the only command authority")
    func actionGuards() async throws {
        let model = await loadedModel()
        let item = try #require(model.active?.items.first)
        #expect(model.actionReasons(.confirm, for: item).isEmpty)
        model.mutationScope = .thisAndFuture
        #expect(model.actionReasons(.cancel, for: item).isEmpty)
        let transfer = try #require(model.active?.items.first { $0.id == V15F3DFixtures.transferID.uuidString })
        #expect(model.actionReasons(.confirm, for: transfer).contains { $0.code == "server_action_unavailable" })
        #expect(model.actionReasons(.cancel, for: transfer).contains { $0.code == "scope_unavailable" })
        let credit = try #require(model.active?.items.first { $0.systemKind == .creditCycle })
        #expect(model.actionReasons(.confirm, for: credit).contains { $0.code == "manual_item_required" })
    }
}
