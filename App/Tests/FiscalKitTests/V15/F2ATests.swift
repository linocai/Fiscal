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
}
