import Foundation
import Testing
@testable import FiscalKit

@Suite("FiscalKit P1")
struct FiscalKitTests {
    @Test("Money uses integer minor units")
    func moneyDecimal() {
        #expect(Money(minorUnits: 12_345).decimal == Decimal(string: "123.45"))
    }

    @Test("Overview derives cash net")
    func derivesCashNet() {
        #expect(OverviewSnapshot.sample.cashNet.minorUnits == 368_670)
    }

    @Test("All required presentation states are available")
    func presentationStates() {
        #expect(Set(OverviewFixture.allCases.map(\.rawValue)) == Set(["normal", "empty", "loading", "offline", "unauthorized", "longContent"]))
    }

    @Test("System status decodes the backend contract")
    func systemStatusContract() throws {
        let data = Data(#"{"service":"fiscal-api","version":"0.1.0","environment":"test","status":"operational","database":"ready","currency":"CNY","business_timezone":"Asia/Shanghai","timestamp":"2026-07-14T08:00:00Z"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let status = try decoder.decode(SystemStatus.self, from: data)
        #expect(status.status == "operational")
        #expect(status.businessTimezone == "Asia/Shanghai")
    }
}
