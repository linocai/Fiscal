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

@Suite("FiscalKit P2 contracts")
struct FiscalKitP2Tests {
    @Test("Account draft uses snake case and excludes ordering")
    func accountPayload() throws {
        var draft = AccountDraft(); draft.name = "招行信用卡"; draft.kind = .credit; draft.openingBalanceMinor = 6_842_30
        draft.creditLimitMinor = 50_000_00; draft.statementDay = 10; draft.dueDay = 22
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        #expect(object["opening_balance_minor"] as? Int == 6_842_30)
        #expect(object["credit_limit_minor"] as? Int == 50_000_00)
        #expect(object["sort_order"] == nil)
        var emptyOptional = AccountDraft(); emptyOptional.name = "现金"; emptyOptional.kind = .cash
        let emptyObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(emptyOptional)) as? [String: Any])
        #expect(emptyObject["institution"] is NSNull)
        #expect(emptyObject["last_four"] is NSNull)
    }

    @Test("Optimistic update sends expected_version")
    func optimisticPayload() throws {
        var draft = AccountDraft(); draft.name = "现金"; draft.kind = .cash
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(VersionedAccountDraft(version: 7, draft: draft))) as? [String: Any])
        #expect(object["expected_version"] as? Int == 7)
        #expect(object["version"] == nil)
    }

    @Test("Category local validation enforces color and duplicates") @MainActor
    func categoryValidation() {
        var draft = CategoryDraft(); draft.name = "餐饮"; draft.colorHex = "orange"
        #expect(CategoriesModel.validate(draft) != nil)
        draft.colorHex = "#C0784A"; draft.aliases = ["午饭", "午饭"]
        #expect(CategoriesModel.validate(draft) == "别名和示例不能重复。")
    }

    @Test("API error envelope decodes stable code")
    func errorEnvelope() throws {
        let data = Data(#"{"error":{"code":"resource_version_conflict","message":"stale","details":null,"request_id":"req-1"}}"#.utf8)
        let envelope = try JSONDecoder().decode(APIErrorEnvelope.self, from: data)
        #expect(envelope.error.code == "resource_version_conflict")
    }

    @Test("CNY parser accepts exact cents and rejects truncation or overflow")
    func exactMinorUnits() {
        #expect(CNYAmountParser.minorUnits("123.45") == 12_345)
        #expect(CNYAmountParser.minorUnits("-0.01") == -1)
        #expect(CNYAmountParser.minorUnits("1.234") == nil)
        #expect(CNYAmountParser.minorUnits("999999999999999999999") == nil)
    }
}
