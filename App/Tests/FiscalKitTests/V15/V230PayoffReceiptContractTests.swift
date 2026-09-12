import Foundation
import Testing
@testable import FiscalKit

/// JSON captured from real isolated PostgreSQL HTTP responses by
/// test_payoff_receipts_match_real_debt_and_permanent_replays.
@Suite("2.3.0 payoff real API receipt contract")
struct V230PayoffReceiptContractTests {
    @Test func realCompletedAndReversedResponsesDescribeTheirActualTransitions() throws {
        let completed = try receipt("payoff_completed")
        let reversed = try receipt("payoff_reversed")
        #expect(completed.operationID == reversed.operationID)
        #expect(completed.transactionIDs == reversed.transactionIDs)
        #expect(completed.allocations == reversed.allocations)
        #expect(completed.status == "completed" && reversed.status == "reversed")
        #expect(completed.debtBeforeMinor == 20000 && completed.debtAfterMinor == 0)
        #expect(reversed.debtBeforeMinor == 0 && reversed.debtAfterMinor == 20000)
        #expect(reversed.actualAmountMinor == completed.actualAmountMinor)
    }

    @Test @MainActor func modelLoadsRealReversedHTTPPayloadWithoutFlippingItsAmounts() async throws {
        let data = try payload("payoff_reversed")
        let expected = try receipt("payoff_reversed")
        let services = V15Services(transport: ReceiptResponseTransport(data: data, operationID: expected.operationID))
        let model = V15CreditPayoffModel(services: services, accountID: expected.accountID)
        await model.loadReceipt(operationID: expected.operationID)
        #expect(model.receipt == expected)
        #expect(model.receipt?.debtBeforeMinor == 0)
        #expect(model.receipt?.debtAfterMinor == 20000)
    }

    private func receipt(_ name: String) throws -> V15CreditPayoffReceipt {
        try V15FixtureCodec.decoder.decode(V15CreditPayoffReceipt.self, from: payload(name))
    }
    private func payload(_ name: String) throws -> Data {
        let url = try #require(Bundle(for: ReceiptContractBundle.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
}
private final class ReceiptContractBundle: NSObject {}
private struct ReceiptResponseTransport: V15Transporting {
    let data: Data
    let operationID: UUID
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        guard request.method == "GET", request.path == "credit-payoffs/\(operationID)" else {
            throw V15Failure(kind: .transport, message: "Unexpected contract-test request")
        }
        return try V15FixtureCodec.decoder.decode(Response.self, from: data)
    }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { throw CocoaError(.fileReadUnsupportedScheme) }
}
