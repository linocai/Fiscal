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

@Suite("v1.5.2 macOS main-ledger scope")
struct V151MacLedgerScopeTests {
  @Test("The formal workspace opens on all transactions, not uncategorized")
  @MainActor func defaultScopeIsAllTransactions() async throws {
    #expect(V151MacLedgerScopePolicy.defaultLens == .all)
    #expect(V151MacLedgerScopePolicy.classification(for: .all) == "all")
    #expect(V151MacLedgerScopePolicy.loadsTransactions(for: .all))

    let transport = V151MacLedgerScopeTransport()
    let model = V15LedgerModel(services: V15Services(transport: transport))
    let july = try #require(Calendar(identifier: .gregorian).date(from: .init(year: 2026, month: 7, day: 15)))
    let range = try #require(V151MacLedgerScopePolicy.monthDateRange(containing: july))
    model.setDateFrom(range.from)
    model.setDateTo(range.to)
    model.setClassification(V151MacLedgerScopePolicy.classification(for: .all))
    await model.load()

    #expect(range == .init(from: "2026-07-01", to: "2026-07-31"))
    #expect(model.items.map(\.id) == [V15F1BFixtures.transactionID])
    let allRequest = try #require(await transport.lastRequest())
    #expect(allRequest.query.contains(.init(name: "classification", value: "all")))
    #expect(allRequest.query.contains(.init(name: "date_from", value: "2026-07-01")))
    #expect(allRequest.query.contains(.init(name: "date_to", value: "2026-07-31")))

    model.setClassification(V151MacLedgerScopePolicy.classification(for: .uncategorized))
    await model.load()
    #expect(model.items.isEmpty)
  }

  @Test("Choosing a month returns to the all-transactions scope")
  func monthSelectionResetsIndependentFilters() {
    #expect(V151MacLedgerScopePolicy.monthSelectionLens == .all)
    #expect(V151MacLedgerScopePolicy.classification(for: .uncategorized) == "uncategorized")
    #expect(!V151MacLedgerScopePolicy.includesVoided(for: .all))
    #expect(V151MacLedgerScopePolicy.includesVoided(for: .archive))
  }

  @Test("Today and future events appear only in the current all-transactions view")
  func currentAndFutureVisibilityMatchesPrototype() {
    #expect(V151MacLedgerScopePolicy.showsCurrentAndFuture(lens: .all, isCurrentMonth: true))
    #expect(!V151MacLedgerScopePolicy.showsCurrentAndFuture(lens: .all, isCurrentMonth: false))
    #expect(!V151MacLedgerScopePolicy.showsCurrentAndFuture(lens: .uncategorized, isCurrentMonth: true))
    #expect(!V151MacLedgerScopePolicy.showsCurrentAndFuture(lens: .archive, isCurrentMonth: true))
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
