import Testing

@testable import FiscalKit

@Suite("F2-C macOS Today refresh ownership")
struct F2CMacTodayPolicyTests {
    @Test("refresh reopens only the lens current after its await")
    func refreshPolicyUsesCurrentScopeOnly() {
        #expect(V15TodayMacRefreshPolicy.scopeTypeToReopen(currentScopeType: "credit_cycles") == "credit_cycles")
        #expect(V15TodayMacRefreshPolicy.scopeTypeToReopen(currentScopeType: "cash_accounts") == "cash_accounts")
        #expect(V15TodayMacRefreshPolicy.scopeTypeToReopen(currentScopeType: nil) == nil) // Today
        #expect(V15TodayMacRefreshPolicy.scopeTypeToReopen(currentScopeType: "future_events") == nil)
    }
}
