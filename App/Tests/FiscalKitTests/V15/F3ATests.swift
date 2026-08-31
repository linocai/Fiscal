import Foundation
import Testing

@testable import FiscalKit

@Suite("F3-A server-owned future timeline")
struct F3ATests {
    @Test("exact future-events query retains bounded server scope and opaque cursor")
    @MainActor func contractAndPagination() async throws {
        let transport = F3ATransport(mode: .normal)
        let model = V15FutureTimelineModel(services: V15Services(transport: transport))
        await model.reload()
        #expect(model.events.count == 4 && model.events.map(\.certainty) == [.exactDue, .confirmed, .expected, .scheduled])
        #expect(Set(model.events.map(\.sourceType)) == Set(V15FutureEventSource.allCases))
        await model.loadNextPage()
        #expect(model.events.count == 5 && !model.hasNextPage)
        let requests = await transport.allRequests()
        #expect(requests[0].query.contains(.init(name: "window_days", value: "30")))
        #expect(requests[1].query.contains(.init(name: "cursor", value: "opaque-f3a-next")))
    }

    @Test("window account and invalid service arguments stay in the typed boundary")
    @MainActor func filtersAndValidation() async throws {
        let transport = F3ATransport(mode: .normal)
        let services = V15Services(transport: transport)
        let model = V15FutureTimelineModel(services: services)
        await model.setWindowDays(90); await model.setAccount(V15F3AFixtures.accountID)
        let last = try #require((await transport.allRequests()).last)
        #expect(last.query.contains(.init(name: "window_days", value: "90")) && last.query.contains(.init(name: "account_id", value: V15F3AFixtures.accountID.uuidString)))
        await #expect(throws: V15Failure.self) { _ = try await services.reports.futureEvents(windowDays: 8) }
        await #expect(throws: V15Failure.self) { _ = try await services.reports.futureEvents(windowDays: 7, limit: 101) }
    }

    @Test("next-page failure keeps first page and conflict can only fresh-reload")
    @MainActor func localPageFailureAndConflictGate() async {
        let failure = V15FutureTimelineModel(services: V15Services(transport: F3ATransport(mode: .pageFailure)))
        await failure.reload(); await failure.loadNextPage()
        #expect(failure.events.count == 4 && failure.hasNextPage && !failure.isLoadingNextPage)
        guard case .failed = failure.pagePhase else { Issue.record("page error must remain local"); return }
        let conflict = V15FutureTimelineModel(services: V15Services(transport: F3ATransport(mode: .conflictThenFresh)))
        await conflict.reload()
        #expect(conflict.events.isEmpty && conflict.requiresFreshReload && conflict.requiredRevision == 78)
        guard case .requiresReload = conflict.phase else { Issue.record("409 must gate the timeline"); return }
        await conflict.reload()
        #expect(!conflict.requiresFreshReload && conflict.meta?.dataRevision == 78)
    }

    @Test("event-aware locators and authoritative account filters stay local and race-safe")
    @MainActor func strictLocatorsAndAccountOptionRaces() async throws {
        let transport = F3ATransport(mode: .normal); let model = V15FutureTimelineModel(services: V15Services(transport: transport))
        await model.reload(); let credit = try #require(model.events.first(where: { $0.sourceType == .creditCycle })); let party = try #require(model.events.first(where: { $0.sourceType == .reimbursementParty })); let cash = try #require(model.events.first(where: { $0.sourceType == .cashFlowItem }))
        #expect(V15FutureTimelineModel.isSafeLocator(credit.deepLink.lowercased(), event: credit))
        #expect(V15FutureTimelineModel.isSafeLocator(party.deepLink.lowercased(), event: party))
        #expect(V15FutureTimelineModel.isSafeLocator(cash.deepLink.lowercased(), event: cash))
        for raw in ["fiscal://reimbursements/\(V15F3AFixtures.creditID)/parties/\(V15F3AFixtures.partyID)", "fiscal://reimbursements/\(V15F3AFixtures.claimID)/parties/\(V15F3AFixtures.creditID)", "fiscal://reimbursements/\(V15F3AFixtures.claimID)/parties/\(V15F3AFixtures.partyID)?x=1", "fiscal://reimbursements/\(V15F3AFixtures.claimID)/parties/\(V15F3AFixtures.partyID)#x", "fiscal://reimbursements/parties/\(V15F3AFixtures.partyID)"] { #expect(!V15FutureTimelineModel.isSafeLocator(raw, event: party)) }
        let count = (await transport.allRequests()).count
        var unsafe = model.events[0]; unsafe = try! V15FixtureCodec.decoder.decode(V15FutureEvent.self, from: Data("{\"source_type\":\"credit_cycle\",\"source_id\":\"\(V15F3AFixtures.creditID.uuidString)\",\"date\":\"2026-08-20\",\"direction\":\"outflow\",\"amount_minor\":1,\"certainty\":\"exact_due\",\"title\":\"x\",\"deep_link\":\"fiscal://credit/cycles/\(V15F3AFixtures.creditID.uuidString)?unsafe=1\"}".utf8))
        model.openInspector(unsafe)
        #expect((await transport.allRequests()).count == count)
        let racing = V15FutureTimelineModel(services: V15Services(transport: F3ATransport(mode: .refreshRace)))
        let old = Task { await racing.reload() }; await Task.yield(); await racing.setWindowDays(7); _ = await old.result
        #expect(racing.selectedWindowDays == 7 && racing.events.count == 4)
        await model.loadAccountOptions()
        #expect(model.accountOptions.map(\.id) == [V15F3AFixtures.accountID, V15F3AFixtures.emptyAccountID])
        await model.setAccount(V15F3AFixtures.emptyAccountID)
        let showsEmpty: Bool; if case .empty = model.phase { showsEmpty = true } else { showsEmpty = false }
        #expect(model.selectedAccountID == V15F3AFixtures.emptyAccountID && showsEmpty)
        #expect((await transport.allRequests()).last?.query.contains(.init(name: "account_id", value: V15F3AFixtures.emptyAccountID.uuidString)) == true)
        let failed = V15FutureTimelineModel(services: V15Services(transport: F3ATransport(mode: .accountFailure))); await failed.loadAccountOptions()
        guard case .failed = failed.accountOptionsPhase else { Issue.record("account read failure must not become an empty option list"); return }
        let optionRace = V15FutureTimelineModel(services: V15Services(transport: F3ATransport(mode: .accountRace)))
        let oldOptions = Task { await optionRace.loadAccountOptions() }; await Task.yield(); await optionRace.loadAccountOptions(); _ = await oldOptions.result
        #expect(optionRace.accountOptions.count == 2)
        let refreshWhileAccountsLoad = V15FutureTimelineModel(services: V15Services(transport: F3ATransport(mode: .accountRace)))
        let optionsWhileRefresh = Task { await refreshWhileAccountsLoad.loadAccountOptions() }; await Task.yield(); await refreshWhileAccountsLoad.reload(); _ = await optionsWhileRefresh.result
        #expect(refreshWhileAccountsLoad.accountOptions.count == 2 && refreshWhileAccountsLoad.events.count == 4)
        let cancelled = V15FutureTimelineModel(services: V15Services(transport: F3ATransport(mode: .accountRace)))
        let cancellation = Task { await cancelled.loadAccountOptions() }; await Task.yield(); cancellation.cancel(); _ = await cancellation.result
        guard case .idle = cancelled.accountOptionsPhase else { Issue.record("cancelled account read must not overwrite a later state"); return }
    }

    @Test("opening a future event requires a fresh owner read and rejects stale ownership")
    @MainActor func freshOwnerReadBeforeNavigation() async throws {
        let transport = F3ATransport(mode: .normal)
        let model = V15FutureTimelineModel(services: V15Services(transport: transport))
        await model.reload()
        let credit = try #require(model.events.first(where: { $0.sourceType == .creditCycle }))
        let party = try #require(model.events.first(where: { $0.sourceType == .reimbursementParty }))
        let cash = try #require(model.events.first(where: { $0.sourceType == .cashFlowItem }))

        guard case .creditCycle(let cycle) = await model.resolveOpenTarget(credit) else { Issue.record("credit owner read must produce a cycle"); return }
        #expect(cycle.id == credit.sourceID && cycle.accountID == credit.accountID)
        guard case .reimbursementParty(let claim, let partyID) = await model.resolveOpenTarget(party) else { Issue.record("reimbursement owner read must produce a claim party"); return }
        #expect(claim.id == party.claimID && partyID == party.sourceID)
        guard case .cashFlowItem(let item) = await model.resolveOpenTarget(cash) else { Issue.record("cash-flow owner read must produce a manual item"); return }
        #expect(item.manualItemID == cash.sourceID)

        let freshReads = await transport.allRequests().filter { request in
            request.path.hasPrefix("credit-cycles/") || request.path.hasPrefix("reimbursement-claims/") || request.path.hasPrefix("cash-flow-items/")
        }
        #expect(freshReads.count == 3)
        #expect(freshReads.allSatisfy { $0.readCachePolicy == .reloadIgnoringCache })

        let mismatch = V15FutureTimelineModel(services: V15Services(transport: F3ATransport(mode: .ownerMismatch)))
        await mismatch.reload()
        let staleCredit = try #require(mismatch.events.first(where: { $0.sourceType == .creditCycle }))
        #expect(await mismatch.resolveOpenTarget(staleCredit) == nil)
        guard case .failed(let mismatchMessage) = mismatch.openPhase else { Issue.record("changed ownership must block navigation"); return }
        #expect(mismatchMessage.contains("归属已经变化"))
    }

    @Test("offline and superseded owner reads cannot navigate")
    @MainActor func offlineAndSupersededOwnerRead() async throws {
        let offlineTransport = F3ATransport(mode: .normal)
        let offline = V15FutureTimelineModel(services: V15Services(transport: offlineTransport), offlineSnapshotProvider: { Date() })
        await offline.reload()
        let offlineCredit = try #require(offline.events.first(where: { $0.sourceType == .creditCycle }))
        let before = await offlineTransport.allRequests().count
        #expect(await offline.resolveOpenTarget(offlineCredit) == nil)
        #expect(await offlineTransport.allRequests().count == before)
        guard case .failed(let offlineMessage) = offline.openPhase else { Issue.record("offline navigation must be blocked"); return }
        #expect(offlineMessage.contains("离线"))

        let race = V15FutureTimelineModel(services: V15Services(transport: F3ATransport(mode: .openRace)))
        await race.reload()
        let raceCredit = try #require(race.events.first(where: { $0.sourceType == .creditCycle }))
        let oldRead = Task { await race.resolveOpenTarget(raceCredit) }
        try await Task.sleep(for: .milliseconds(20))
        race.closeInspector()
        #expect(await oldRead.value == nil)
        #expect(race.openPhase == .idle)
    }
}
