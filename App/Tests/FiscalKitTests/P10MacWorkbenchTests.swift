import Foundation
import Testing
@testable import FiscalKit

@Suite("FiscalKit P10 macOS workbench contracts")
struct P10MacWorkbenchTests {
  @Test("Batch classification encodes the frozen atomic request shape")
  func batchClassificationEncoding() throws {
    let transactionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let categoryID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let request = TransactionBatchClassificationRequest(
      items: [
        TransactionBatchClassificationItem(
          transactionID: transactionID,
          expectedVersion: 7)
      ],
      categoryID: categoryID)

    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    let items = try #require(object["items"] as? [[String: Any]])

    #expect(object["category_id"] as? String == categoryID.uuidString)
    #expect(items.count == 1)
    #expect(items[0]["transaction_id"] as? String == transactionID.uuidString)
    #expect(items[0]["expected_version"] as? Int == 7)
  }

  @Test("Classification filters keep the frozen raw query values")
  func classificationRawValues() {
    #expect(TransactionClassificationFilter.all.rawValue == "all")
    #expect(TransactionClassificationFilter.categorized.rawValue == "categorized")
    #expect(TransactionClassificationFilter.uncategorized.rawValue == "uncategorized")
  }
}

@Suite("v1.7 macOS ledger context")
struct V151MacLedgerScopeTests {
  @Test("Month context uses the Shanghai business-month range")
  func monthContextUsesShanghaiRange() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let july = try #require(calendar.date(from: .init(year: 2026, month: 7, day: 15)))
    let range = try #require(V151MacBusinessDateRange.monthDateRange(containing: july))
    #expect(range == .init(from: "2026-07-01", to: "2026-07-31"))
  }

  @Test("Ledger account filter survives detail changes and clears only after references remove it")
  func accountFilterAndDetailOwnershipStaySeparate() {
    let retained = V15F1BFixtures.accountID
    let other = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let accounts = [
      V15AccountResponse(
        id: retained,
        name: "保留账户",
        kind: .cash,
        institution: nil,
        lastFour: nil,
        openingBalanceMinor: 0,
        currentBalanceMinor: 100,
        creditLimitMinor: nil,
        statementDay: nil,
        dueDay: nil,
        cycleMode: nil,
        openingBalanceAsOfDate: nil,
        openingDueDate: nil,
        sortOrder: 0,
        archivedAt: nil,
        usageCount: 0,
        version: 1,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
      )
    ]

    var context = V151MacLedgerAccountContext(filterID: nil, detailID: nil)
    context.selectAccount(retained)
    context.selectTransaction()
    #expect(context.filterID == retained)
    #expect(context.detailID == nil)
    context.selectDetailAccount(retained)
    context.showFilteredLedger()
    #expect(context.filterID == retained)
    #expect(context.detailID == nil)
    #expect(context.clearMissingFilter(availableAccounts: accounts) == nil)
    #expect(context.filterID == retained)
    context.selectDetailAccount(retained)
    #expect(context.clearMissingFilter(availableAccounts: []) == retained)
    #expect(context.filterID == nil)
    #expect(context.detailID == nil)
    #expect(V151MacLedgerAccountFilter.retainedAccountID(other, availableAccounts: accounts) == nil)
  }

  @Test("Ledger search draft changes only on explicit confirmation")
  func searchDraftRequiresConfirmation() {
    #expect(V151MacLedgerSearch.committedQuery(from: "午餐") == "午餐")
    #expect(V151MacLedgerSearch.committedQuery(from: "") == nil)
  }
}

private actor V151MacLedgerScopeTransport: V15Transporting {
  private var request: V15Request?

  func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
    self.request = request
    guard request.path == "transactions", request.method == "GET" else {
      throw V15Failure(kind: .transport, code: "unexpected_request", message: "Unexpected quick-fix fixture request.")
    }
    let isUncategorized = request.query.contains(.init(name: "classification", value: "uncategorized"))
    let data: Data
    if isUncategorized {
      data = Data(#"{"items":[],"next_cursor":null}"#.utf8)
    } else {
      data = Data(
        #"{"items":[#DETAIL#],"next_cursor":null}"#
          .replacingOccurrences(of: "#DETAIL#", with: String(decoding: V15F1BFixtures.detail, as: UTF8.self))
          .utf8)
    }
    return try V15FixtureCodec.decoder.decode(Response.self, from: data)
  }

  func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data {
    throw V15Failure(kind: .transport, code: "unexpected_artifact", message: "No artifact in quick-fix fixture.")
  }

  func lastRequest() -> V15Request? { request }
}
