import Foundation
import Testing

@testable import FiscalKit

@Suite("FiscalKit P21 reconciliation")
struct FiscalKitP21ReconciliationTests {
    @Test("Checkpoint decodes server-owned balances and state")
    func checkpointContract() throws {
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000021001","target_kind":"account","account_id":"00000000-0000-0000-0000-000000021002","credit_cycle_id":null,"as_of":"2026-08-11T04:00:00Z","actual_balance_minor":10000,"book_balance_minor":9500,"difference_minor":500,"state":"open","note":"bank","created_at":"2026-08-11T04:01:00Z"}"#.utf8)
        let item = try p21Decoder().decode(ReconciliationCheckpointDTO.self, from: data)
        #expect(item.state == .open)
        #expect(item.bookBalanceMinor == 9_500)
        #expect(item.differenceMinor == 500)
    }

    @Test("Attention keeps a stable source identity and deep link")
    func attentionContract() throws {
        let data = Data(#"{"items":[{"source_type":"reconciliation_checkpoint","source_id":"00000000-0000-0000-0000-000000021003","severity":"warning","amount_minor":-23,"occurred_at":"2026-08-11T04:00:00Z","explanation":"difference","suggested_action":"review","deep_link":"fiscal://reconciliation/checkpoints/00000000-0000-0000-0000-000000021003"}]}"#.utf8)
        let item = try p21Decoder().decode(AttentionPageDTO.self, from: data).items[0]
        #expect(item.id == "reconciliation_checkpoint:00000000-0000-0000-0000-000000021003")
        #expect(item.deepLink.hasPrefix("fiscal://"))
    }
}

private func p21Decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}
