@testable import FiscalPreviewSupportmacOS
import Testing
@testable import FiscalKit

@Suite("v1.7 facts read boundary")
struct F2ATests {
    @Test("Facts decode without reconciliation fields and retain known future facts")
    func factsDecode() throws {
        let facts = try V15FixtureCodec.decoder.decode(V15Facts.self, from: V15F2AFixtures.facts())
        #expect(facts.completeness.uncategorizedTransactionCount == 3)
        #expect(facts.knownFutureEvents.first?.cycleID == V15F2AFixtures.cycleID)
    }

    @Test("Today refresh reads facts only")
    @MainActor func refreshUsesOnlyFactsReadModelEndpoints() async {
        let transport = V15F2ATransport()
        let model = V15TodayReadModel(services: V15Services(transport: transport))
        await model.refresh()
        #expect((await transport.allRequests()).allSatisfy { $0.path.hasPrefix("reports/") })
    }

    @Test("Every facts scope opens from the same revision; a failed next page preserves its first page")
    @MainActor func revisionBoundScopesAndPageFailure() async throws {
        let transport = V15F2ATransport(mode: .pageFailure)
        let model = V15TodayReadModel(services: V15Services(transport: transport))
        await model.refresh()
        for type in ["cash_accounts", "credit_cycles", "reimbursement_outstanding", "completeness_issues"] {
            await model.openScope(type: type)
            #expect(model.selectedScope?.scopeType == type)
            #expect(model.scopeItems.count == 1)
            model.closeScopeInspector()
        }
        await model.openScope(type: "cash_accounts")
        #expect(model.hasNextPage)
        await model.loadNextPage()
        #expect(model.scopeItems.count == 1 && model.hasNextPage)
        #expect(model.nextPageFailure?.kind == .transport)
        let requests = await transport.allRequests().filter { $0.path == "reports/facts/drill-down" }
        #expect(requests.allSatisfy { $0.query.contains(.init(name: "expected_data_revision", value: "42")) })
        #expect(requests.last?.query.contains(.init(name: "cursor", value: "opaque-cash")) == true)
    }

    @Test("A scope conflict blocks linked reads until fresh facts reach the required revision")
    @MainActor func scopeConflictRequiresFreshFacts() async {
        let transport = V15F2ATransport(mode: .scopeConflictForceRefreshSequence)
        let model = V15TodayReadModel(services: V15Services(transport: transport))
        await model.refresh()
        await model.openScope(type: "cash_accounts")
        #expect(model.requiresFactsReload && model.facts == nil)
        #expect(model.factsReloadRequiredReason?.code == "facts_reload_required")
        await model.openLinkedRead("fiscal://accounts/\(V15F2AFixtures.accountID)")
        #expect(!(await transport.allRequests()).contains { $0.path.hasPrefix("accounts/") })
        await model.refresh() // A valid but still old revision cannot release the gate.
        #expect(model.requiresFactsReload && model.facts == nil)
        await model.refresh()
        #expect(!model.requiresFactsReload && model.facts?.meta.dataRevision == 43)
        await model.openScope(type: "cash_accounts")
        #expect(model.scopeItems.count == 1)
        let factsReads = await transport.allRequests().filter { $0.path == "reports/facts" }
        #expect(factsReads.count == 3)
        #expect(factsReads.dropFirst().allSatisfy { $0.readCachePolicy == .reloadIgnoringCache })
    }

    @Test("Unknown drill-down items are read-only, and a closed slow scope cannot reappear")
    @MainActor func unknownItemAndScopeGeneration() async throws {
        let transport = V15F2ATransport(mode: .slowScope)
        let model = V15TodayReadModel(services: V15Services(transport: transport))
        await model.refresh()
        let unknown = try V15FixtureCodec.decoder.decode(V15FactDrillDownItem.self, from: V15F2AFixtures.unknownItem)
        await model.openFactItem(unknown)
        guard case .unavailable = model.linkedReadPhase else { Issue.record("unknown item must remain read-only"); return }
        #expect((await transport.allRequests()).allSatisfy { $0.path.hasPrefix("reports/") })

        let slow = Task { await model.openScope(type: "cash_accounts") }
        for _ in 0..<100 where model.selectedScope == nil { await Task.yield() }
        #expect(model.selectedScope?.scopeType == "cash_accounts")
        model.closeScopeInspector()
        await slow.value
        #expect(model.selectedScope == nil && model.scopeItems.isEmpty && !model.hasNextPage)
    }

    @Test("A superseded facts refresh cannot overwrite the newer revision")
    @MainActor func refreshGeneration() async {
        let transport = V15F2ATransport(mode: .refreshRace)
        let model = V15TodayReadModel(services: V15Services(transport: transport))
        let stale = Task { await model.refresh() }
        for _ in 0..<100 {
            if !(await transport.allRequests()).isEmpty { break }
            await Task.yield()
        }
        await model.refresh()
        await stale.value
        #expect(model.facts?.meta.dataRevision == 42)
    }
}
