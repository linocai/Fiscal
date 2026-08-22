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
