import Foundation
import Testing

@testable import FiscalKit

@Suite("FiscalKit P8 contracts")
struct FiscalKitP8Tests {
  @Test("AI proposal decodes strict integer confidence and authoritative pending count")
  func proposalContract() throws {
    let data = Data(#"{"items":[{"id":"00000000-0000-0000-0000-000000000081","source":"text","text":"午餐 28 元","content_fingerprint":"abc","provider":"fake","model":"fixture","kind":"expense","amount_minor":2800,"occurred_at":"2026-07-16T04:00:00Z","title":"午餐","note":null,"account_id":"00000000-0000-0000-0000-000000000082","category_id":"00000000-0000-0000-0000-000000000083","destination_account_id":null,"credit_cycle_id":null,"field_confidences":{"kind":9500,"amount_minor":9600,"occurred_at":9300,"title":9400,"note":9000,"account_id":9200,"category_id":9100,"destination_account_id":9000},"overall_confidence_bps":9300,"missing_fields":[],"reason_codes":["manual_confirmation_required"],"explanation":"匹配现有账户和分类","status":"pending","error_code":null,"error_message":null,"transaction_id":null,"transaction_version":null,"version":2,"created_at":"2026-07-16T04:00:00Z","updated_at":"2026-07-16T04:00:00Z","executed_at":null,"ignored_at":null,"undone_at":null}],"next_cursor":null,"pending_count":7}"#.utf8)
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let page = try decoder.decode(AIProposalPage.self, from: data)
    #expect(page.pendingCount == 7)
    #expect(page.items.first?.fieldConfidences["amount_minor"] == 9_600)
    #expect(page.items.first?.confidenceTitle == "93%")
    #expect(page.items.first?.reviewWarnings == ["需要人工确认"])
  }

  @Test("AI proposal replacement keeps draft nested beside expected version")
  func nestedReplacement() throws {
    var draft = TransactionDraft(); draft.kind = .expense; draft.title = "午餐"
    draft.amountMinor = 2_800; draft.accountID = UUID(); draft.categoryID = UUID()
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let object = try #require(JSONSerialization.jsonObject(with: encoder.encode(
      AIProposalReplacementRequest(draft: draft, expectedVersion: 4))) as? [String: Any])
    #expect(object["expected_version"] as? Int == 4)
    #expect((object["draft"] as? [String: Any])?["amount_minor"] as? Int == 2_800)
    #expect(object["amount_minor"] == nil)
  }

  @Test("AI settings payload cannot disguise confidence or money as floating point")
  func settingsPayload() throws {
    let request = AISettingsUpdateRequest(autoExecuteEnabled: true, autoExecuteLimitMinor: 100_000, minimumConfidenceBps: 9_500, expectedVersion: 3)
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    #expect(object["auto_execute_limit_minor"] as? Int == 100_000)
    #expect(object["minimum_confidence_bps"] as? Int == 9_500)
    #expect(object["expected_version"] as? Int == 3)
  }

  @Test("AI text transactions remain ordinary user editable rows")
  func aiTextEditable() throws {
    let data = Data(#"{"id":"00000000-0000-0000-0000-000000000091","kind":"expense","amount_minor":1280,"occurred_at":"2026-07-16T04:00:00Z","business_date":"2026-07-16","title":"午餐","note":null,"category_id":"00000000-0000-0000-0000-000000000092","account_id":"00000000-0000-0000-0000-000000000093","destination_account_id":null,"credit_cycle_id":null,"installment_plan_id":null,"installment_relation":null,"reimbursement_relations":[],"source":"ai_text","postings":[],"version":1,"voided_at":null,"created_at":"2026-07-16T04:00:00Z","updated_at":"2026-07-16T04:00:00Z"}"#.utf8)
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let transaction = try decoder.decode(TransactionDTO.self, from: data)
    #expect(transaction.isUserEditable)
  }

  @Test("A stale AI queue response cannot replace the current filter") @MainActor
  func staleAIQueue() async throws {
    let model = AIProposalModel(repository: RaceAIProposalRepository())
    let old = Task { await model.load() }
    try await Task.sleep(for: .milliseconds(10))
    await model.selectStatus(.failed); await old.value
    #expect(model.pendingCount == 2)
  }
}

private actor RaceAIProposalRepository: AIProposalRepository {
  func list(status: AIProposalStatus?, cursor: String?, limit: Int) async throws -> AIProposalPage {
    if status == .pending { try await Task.sleep(for: .milliseconds(80)); return .init(items: [], nextCursor: nil, pendingCount: 1) }
    try await Task.sleep(for: .milliseconds(5)); return .init(items: [], nextCursor: nil, pendingCount: 2)
  }
  func get(id: UUID) async throws -> AIProposalDTO { throw FiscalAPIError.invalidResponse }
  func create(text: String, idempotencyKey: UUID) async throws -> AIProposalDTO { throw FiscalAPIError.invalidResponse }
  func update(id: UUID, request: AIProposalReplacementRequest) async throws -> AIProposalDTO { throw FiscalAPIError.invalidResponse }
  func action(id: UUID, action: String, expectedVersion: Int) async throws -> AIProposalActionResponse { throw FiscalAPIError.invalidResponse }
}

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
    #expect(
      Set(OverviewFixture.allCases.map(\.rawValue))
        == Set(["normal", "empty", "loading", "offline", "unauthorized", "longContent"]))
  }

  @Test("System status decodes the backend contract")
  func systemStatusContract() throws {
    let data = Data(
      #"{"service":"fiscal-api","version":"0.1.0","environment":"test","status":"operational","database":"ready","currency":"CNY","business_timezone":"Asia/Shanghai","timestamp":"2026-07-14T08:00:00Z"}"#
        .utf8)
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
    var draft = AccountDraft()
    draft.name = "招行信用卡"
    draft.kind = .credit
    draft.openingBalanceMinor = 6_842_30
    draft.creditLimitMinor = 50_000_00
    draft.statementDay = 10
    draft.dueDay = 22
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
    #expect(object["opening_balance_minor"] as? Int == 6_842_30)
    #expect(object["credit_limit_minor"] as? Int == 50_000_00)
    #expect(object["sort_order"] == nil)
    var emptyOptional = AccountDraft()
    emptyOptional.name = "现金"
    emptyOptional.kind = .cash
    let emptyObject = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(emptyOptional)) as? [String: Any])
    #expect(emptyObject["institution"] is NSNull)
    #expect(emptyObject["last_four"] is NSNull)
  }

  @Test("Optimistic update sends expected_version")
  func optimisticPayload() throws {
    var draft = AccountDraft()
    draft.name = "现金"
    draft.kind = .cash
    let object = try #require(
      JSONSerialization.jsonObject(
        with: JSONEncoder().encode(VersionedAccountDraft(version: 7, draft: draft)))
        as? [String: Any])
    #expect(object["expected_version"] as? Int == 7)
    #expect(object["version"] == nil)
  }

  @Test("Category local validation enforces color and duplicates") @MainActor
  func categoryValidation() {
    var draft = CategoryDraft()
    draft.name = "餐饮"
    draft.colorHex = "orange"
    #expect(CategoriesModel.validate(draft) != nil)
    draft.colorHex = "#C0784A"
    draft.aliases = ["午饭", "午饭"]
    #expect(CategoriesModel.validate(draft) == "别名和示例不能重复。")
  }

  @Test("API error envelope decodes stable code")
  func errorEnvelope() throws {
    let data = Data(
      #"{"error":{"code":"resource_version_conflict","message":"stale","details":null,"request_id":"req-1"}}"#
        .utf8)
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

@Suite("FiscalKit P3 contracts")
struct FiscalKitP3Tests {
  @Test("Transfer payload uses account_id as source and no source alias")
  func transferPayload() throws {
    let source = UUID()
    let destination = UUID()
    var draft = TransactionDraft()
    draft.kind = .transfer
    draft.amountMinor = 1_280
    draft.occurredAt = Date(timeIntervalSince1970: 0)
    draft.title = "转入储蓄"
    draft.note = "  "
    draft.accountID = source
    draft.destinationAccountID = destination
    let object = try #require(JSONSerialization.jsonObject(with: encoded(draft)) as? [String: Any])
    #expect(object["account_id"] as? String == source.uuidString)
    #expect(object["destination_account_id"] as? String == destination.uuidString)
    #expect(object["source_account_id"] == nil)
    #expect(object["category_id"] is NSNull)
    #expect(object["note"] is NSNull)
    #expect(
      Set(object.keys)
        == Set([
          "kind", "amount_minor", "occurred_at", "title", "note", "account_id",
          "destination_account_id", "category_id", "credit_cycle_id",
        ]))
  }

  @Test("Versioned update is a full semantic replacement")
  func updatePayload() throws {
    var draft = TransactionDraft()
    draft.kind = .expense
    draft.amountMinor = 500
    draft.title = "咖啡"
    draft.accountID = UUID()
    draft.categoryID = UUID()
    let object = try #require(
      JSONSerialization.jsonObject(
        with: encoded(VersionedTransactionDraft(draft: draft, expectedVersion: 7)))
        as? [String: Any])
    #expect(object["expected_version"] as? Int == 7)
    #expect(object["amount_minor"] as? Int == 500)
    #expect(object["source"] == nil)
  }

  @Test("Canonical response decodes account impacts without internal transaction IDs")
  func responsePayload() throws {
    let data = Data(
      #"{"id":"00000000-0000-0000-0000-000000000001","kind":"expense","amount_minor":1280,"occurred_at":"2026-07-15T12:00:00Z","business_date":"2026-07-15","title":"午餐","note":null,"category_id":"00000000-0000-0000-0000-000000000002","account_id":"00000000-0000-0000-0000-000000000003","destination_account_id":null,"credit_cycle_id":null,"installment_plan_id":null,"installment_relation":null,"reimbursement_relations":[],"source":"manual","postings":[{"id":"00000000-0000-0000-0000-000000000004","account_id":"00000000-0000-0000-0000-000000000003","role":"account","amount_minor":-1280,"position":0}],"version":1,"voided_at":null,"created_at":"2026-07-15T12:00:00Z","updated_at":"2026-07-15T12:00:00Z"}"#
        .utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let transaction = try decoder.decode(TransactionDTO.self, from: data)
    #expect(transaction.businessDate == "2026-07-15")
    #expect(transaction.postings.first?.amountMinor == -1_280)
  }

  @Test("Editor validates all three semantic shapes") @MainActor
  func semanticValidation() {
    var draft = TransactionDraft()
    draft.title = "午餐"
    draft.amountMinor = 1
    #expect(TransactionEditorModel.validate(draft) != nil)
    draft.accountID = UUID()
    draft.categoryID = UUID()
    #expect(TransactionEditorModel.validate(draft) == nil)
    draft.kind = .transfer
    draft.categoryID = nil
    draft.destinationAccountID = draft.accountID
    #expect(TransactionEditorModel.validate(draft) == "转出和转入账户不能相同。")
    draft.destinationAccountID = UUID()
    #expect(TransactionEditorModel.validate(draft) == nil)
  }

  @Test("Create key is retained only for ambiguous failures") @MainActor
  func idempotencyDisposition() {
    #expect(TransactionsModel.shouldPreserveCreateKey(after: FiscalAPIError.transport("offline")))
    #expect(TransactionsModel.shouldPreserveCreateKey(after: FiscalAPIError.invalidResponse))
    let detail = APIErrorDetail(
      code: "idempotency_key_reused", message: "reused", details: nil, requestID: "req")
    #expect(
      !TransactionsModel.shouldPreserveCreateKey(
        after: FiscalAPIError.domain(status: 409, detail: detail)))
  }

  @Test("A cancelled old search cannot replace the current query") @MainActor
  func staleSearchIsIgnored() async throws {
    let model = TransactionsModel(repository: RaceTransactionRepository())
    model.search = "old"
    let old = Task { await model.load() }
    try await Task.sleep(for: .milliseconds(10))
    model.search = "new"
    await model.load()
    await old.value
    #expect(model.transactions.map(\.title) == ["new"])
  }

  @Test("Pagination is bound to its filter and cursor snapshot") @MainActor
  func stalePageIsIgnored() async throws {
    let model = TransactionsModel(repository: RaceTransactionRepository())
    await model.load()
    let last = try #require(model.transactions.last)
    let more = Task { await model.loadMoreIfNeeded(after: last) }
    try await Task.sleep(for: .milliseconds(10))
    model.kind = .expense
    await model.load()
    await more.value
    #expect(model.transactions.map(\.title) == ["expense"])
  }

  private func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
  }
}

@Suite("FiscalKit P6 contracts")
struct FiscalKitP6Tests {
  @Test("Reimbursement editor displays yuan while preserving exact minor units")
  @MainActor
  func reimbursementYuanConversion() {
    #expect(ReimbursementClaimEditor.yuanText(minorUnits: 60_001) == "600.01")
    #expect(ReimbursementClaimEditor.validatedAmount(text: "600.01", minimum: 0) == 60_001)
    #expect(ReimbursementClaimEditor.validatedAmount(text: "600.001", minimum: 0) == nil)
    #expect(ReimbursementClaimEditor.validatedAmount(text: "-1", minimum: 0) == nil)
    #expect(ReimbursementClaimEditor.validatedAmount(text: "200", minimum: 30_000) == nil)
    #expect(ReimbursementClaimEditor.validatedAmount(text: "", minimum: 0) == nil)
    #expect(
      ReimbursementClaimEditor.validatedAmount(
        text: "999999999999999999999", minimum: 0) == nil)
  }

  @Test("Reimbursement expected date is strict Shanghai calendar ISO")
  @MainActor
  func reimbursementExpectedDate() {
    #expect(ReimbursementClaimEditor.isValidISODate("2026-07-25"))
    #expect(!ReimbursementClaimEditor.isValidISODate("2026-02-29"))
    #expect(!ReimbursementClaimEditor.isValidISODate("2026-7-25"))
  }

  @Test("Party status uses the localized reimbursement vocabulary")
  func partyStatusTitle() {
    let party = ReimbursementPartyDTO(
      id: UUID(), name: "公司", expectedDate: nil, note: nil, claimedMinor: 100,
      receivedMinor: 50, outstandingMinor: 50, status: "partial_received", position: 0,
      allocations: [])
    #expect(party.statusTitle == "部分到账")
  }

  @Test("Claim replacement preserves the party by expense matrix")
  func claimPayload() throws {
    let partyID = UUID()
    let allocationID = UUID()
    let transactionID = UUID()
    let request = ReimbursementClaimReplacementRequest(
      expectedVersion: 7, title: "差旅报销", note: nil,
      parties: [
        .init(
          id: partyID, name: "公司", expectedDate: "2026-07-25", note: nil,
          allocations: [.init(id: allocationID, transactionID: transactionID, amountMinor: 12_345)])
      ])
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    #expect(object["expected_version"] as? Int == 7)
    let parties = try #require(object["parties"] as? [[String: Any]])
    let allocations = try #require(parties.first?["allocations"] as? [[String: Any]])
    #expect(parties.first?["expected_date"] as? String == "2026-07-25")
    #expect(allocations.first?["transaction_id"] as? String == transactionID.uuidString)
    #expect(allocations.first?["amount_minor"] as? Int == 12_345)
  }

  @Test("Receipt mutation uses exact optimistic version names")
  func receiptPayload() throws {
    let request = ReimbursementReceiptReplacementRequest(
      expectedClaimVersion: 8, expectedReceiptVersion: 3, partyID: UUID(), amountMinor: 500,
      receivedAt: Date(timeIntervalSince1970: 0), destinationAccountID: UUID(), title: "公司到账",
      note: nil)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let object = try #require(
      JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any])
    #expect(object["expected_claim_version"] as? Int == 8)
    #expect(object["expected_receipt_version"] as? Int == 3)
    #expect(object["claim_expected_version"] == nil)
    #expect(object["receipt_expected_version"] == nil)
  }

  @Test("P6 server-owned ledger kind is never a manual editor choice")
  func systemKind() {
    #expect(TransactionKind(rawValue: "reimbursement_receipt") == .reimbursementReceipt)
    #expect(!TransactionKind.allCases.contains(.reimbursementReceipt))
  }

  @Test("Reimbursement operation conflict triggers refresh UX")
  func conflict() {
    #expect(ReimbursementModel.isConflictCode("reimbursement_operation_conflict"))
    #expect(ReimbursementModel.isConflictCode("resource_version_conflict"))
    #expect(!ReimbursementModel.isConflictCode("idempotency_key_reused"))
  }

  @Test("Summary requires merchant principal refunds explicitly")
  func summaryContract() throws {
    let complete = Data(
      #"{"gross_expense_minor":10000,"merchant_principal_refund_minor":1000,"expected_reimbursement_minor":6000,"received_reimbursement_minor":2500,"personal_expected_expense_minor":3000,"personal_realized_expense_minor":6500,"outstanding_minor":3500}"#
        .utf8)
    let value = try JSONDecoder().decode(ReimbursementSummary.self, from: complete)
    #expect(value.merchantPrincipalRefundMinor == 1_000)
    let missing = Data(
      #"{"gross_expense_minor":10000,"expected_reimbursement_minor":6000,"received_reimbursement_minor":2500,"personal_expected_expense_minor":3000,"personal_realized_expense_minor":6500,"outstanding_minor":3500}"#
        .utf8)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ReimbursementSummary.self, from: missing)
    }
  }

  @Test("Required nullable reimbursement response keys cannot disappear")
  func requiredNullableKeys() throws {
    let claim =
      #"{"id":"00000000-0000-0000-0000-000000000601","title":"差旅","note":null,"status":"pending","total_claimed_minor":1000,"received_minor":0,"outstanding_minor":1000,"expense_count":1,"party_count":0,"receipt_count":0,"parties":[],"latest_receipt":null,"version":1,"submitted_at":null,"cancelled_at":null,"voided_at":null,"archived_at":null,"created_at":"2026-07-15T08:00:00Z","updated_at":"2026-07-15T08:00:00Z"}"#
    let decoder = fiscalDecoder()
    #expect(
      try decoder.decode(ReimbursementClaimDTO.self, from: Data(claim.utf8)).latestReceipt == nil)
    for key in [
      #""note":null,"#, #""latest_receipt":null,"#, #""submitted_at":null,"#,
      #""cancelled_at":null,"#, #""voided_at":null,"#, #""archived_at":null,"#,
    ] {
      let missing = claim.replacingOccurrences(of: key, with: "")
      #expect(throws: DecodingError.self) {
        try decoder.decode(ReimbursementClaimDTO.self, from: Data(missing.utf8))
      }
    }
    let partyMissingNote = Data(
      #"{"id":"00000000-0000-0000-0000-000000000602","name":"公司","expected_date":null,"claimed_minor":1000,"received_minor":0,"outstanding_minor":1000,"status":"pending","position":0,"allocations":[]}"#
        .utf8)
    #expect(throws: DecodingError.self) {
      try decoder.decode(ReimbursementPartyDTO.self, from: partyMissingNote)
    }
    #expect(throws: DecodingError.self) {
      try decoder.decode(ReimbursementClaimPage.self, from: Data(#"{"items":[]}"#.utf8))
    }
    let relationMissingParty = Data(
      #"{"role":"expense","claim_id":"00000000-0000-0000-0000-000000000601","claim_title":"差旅","claim_status":"pending","party_name":null,"receipt_id":null,"allocated_minor":1000,"received_minor":0,"outstanding_minor":1000}"#
        .utf8)
    #expect(throws: DecodingError.self) {
      try decoder.decode(ReimbursementRelation.self, from: relationMissingParty)
    }
  }

  @Test("A stale claim response cannot replace the newly selected claim") @MainActor
  func staleClaimSelection() async throws {
    let old = UUID()
    let current = UUID()
    let repository = AuditReimbursementRepository(slowID: old, currentID: current)
    let model = ReimbursementModel(repository: repository)
    let stale = Task { await model.loadClaim(old) }
    try await Task.sleep(for: .milliseconds(10))
    await model.loadClaim(current)
    await stale.value
    #expect(model.selectedClaim?.id == current)
    #expect(model.selectedClaim?.title == "当前报销单")
  }

  @Test("A changed receipt request cannot commit a stale preview") @MainActor
  func receiptPreviewSnapshot() async throws {
    let claimID = UUID()
    let repository = AuditReimbursementRepository(slowID: UUID(), currentID: claimID)
    let model = ReimbursementModel(repository: repository)
    await model.loadClaim(claimID)
    let party = try #require(model.selectedClaim?.parties.first)
    let request = ReimbursementReceiptRequest(
      expectedClaimVersion: 1, partyID: party.id, amountMinor: 100,
      receivedAt: Date(timeIntervalSince1970: 0), destinationAccountID: UUID(), title: "到账",
      note: nil)
    #expect(await model.previewReceipt(request))
    var changed = request
    changed.amountMinor = 200
    #expect(!(await model.createReceipt(changed)))
    #expect(model.receiptPreview == nil)
    #expect(await repository.createReceiptCalls == 0)
  }

  @Test("Cancellation confirmation is bound to the preview claim and version") @MainActor
  func cancellationPreviewSnapshot() async throws {
    let claimID = UUID()
    let repository = AuditReimbursementRepository(slowID: UUID(), currentID: claimID)
    let model = ReimbursementModel(repository: repository)
    await model.loadClaim(claimID)
    #expect(await model.previewCancellation())
    #expect(await model.confirmCancel())
    #expect(await repository.lifecycleIDs == [claimID])
    #expect(await repository.lifecycleActions == ["cancel-outstanding"])
    #expect(await repository.lifecycleVersions == [1])
  }

  @Test("Cancellation confirmation rejects a changed selected version") @MainActor
  func staleCancellationPreview() async throws {
    let claimID = UUID()
    let repository = AuditReimbursementRepository(slowID: UUID(), currentID: claimID)
    let model = ReimbursementModel(repository: repository)
    await model.loadClaim(claimID)
    #expect(await model.previewCancellation())
    await repository.setClaimVersion(2)
    await model.loadClaim(claimID)
    #expect(!(await model.confirmCancel()))
    #expect(model.cancelPreview == nil)
    #expect(model.message == "报销单已变化，请重新预览取消操作。")
    #expect(await repository.lifecycleVersions.isEmpty)
  }

  @Test("A locked allocation can change amount but never below receipts") @MainActor
  func lockedAllocationAmountFloor() {
    let allocationID = UUID()
    let transactionID = UUID()
    let now = Date(timeIntervalSince1970: 0)
    let allocation = ReimbursementAllocationDTO(
      id: allocationID, transactionID: transactionID, expenseTitle: "酒店",
      expenseAmountMinor: 2_000, amountMinor: 1_500, receivedMinor: 600,
      outstandingMinor: 900, locked: true, position: 0)
    let party = ReimbursementPartyDTO(
      id: UUID(), name: "公司", expectedDate: nil, note: nil, claimedMinor: 1_500,
      receivedMinor: 600, outstandingMinor: 900, status: "partial_received", position: 0,
      allocations: [allocation])
    let claim = ReimbursementClaimDTO(
      id: UUID(), title: "差旅", note: nil, status: .partialReceived,
      totalClaimedMinor: 1_500, receivedMinor: 600, outstandingMinor: 900, expenseCount: 1,
      partyCount: 1, receiptCount: 1, parties: [party], latestReceipt: nil, version: 2,
      submittedAt: now, cancelledAt: nil, voidedAt: nil, archivedAt: nil, createdAt: now,
      updatedAt: now)
    #expect(
      ReimbursementClaimEditor.clampedAllocationAmount(
        2_400, allocationID: allocationID, editing: claim) == 2_400)
    #expect(
      ReimbursementClaimEditor.clampedAllocationAmount(
        700, allocationID: allocationID, editing: claim) == 700)
    #expect(
      ReimbursementClaimEditor.clampedAllocationAmount(
        100, allocationID: allocationID, editing: claim) == 600)
  }

  @Test("Claim and receipt pagination reject duplicate concurrent loads") @MainActor
  func guardedPagination() async throws {
    let claimID = UUID()
    let repository = AuditReimbursementRepository(slowID: UUID(), currentID: claimID)
    let model = ReimbursementModel(repository: repository)
    await model.load()
    async let first: Void = model.loadMore()
    async let duplicate: Void = model.loadMore()
    _ = await (first, duplicate)
    #expect(await repository.listCalls == 2)
    await model.loadClaim(claimID)
    async let receiptFirst: Void = model.loadMoreReceipts(claimID: claimID)
    async let receiptDuplicate: Void = model.loadMoreReceipts(claimID: claimID)
    _ = await (receiptFirst, receiptDuplicate)
    #expect(await repository.receiptCalls == 2)
    #expect(model.receiptNextCursor == nil)
  }

  @Test("A filtered refresh discards an older claim page") @MainActor
  func staleClaimPage() async throws {
    let claimID = UUID()
    let repository = AuditReimbursementRepository(slowID: UUID(), currentID: claimID)
    let model = ReimbursementModel(repository: repository)
    await model.load()
    let oldPage = Task { await model.loadMore() }
    try await Task.sleep(for: .milliseconds(10))
    model.statusFilter = .received
    await model.load()
    await oldPage.value
    #expect(model.claims.allSatisfy { $0.id == claimID })
  }
}

@Suite("FiscalKit P4 contracts")
struct FiscalKitP4Tests {
  @Test("Credit cycle and account summary decode the frozen schema")
  func creditResponsePayload() throws {
    let cycle =
      #"{"id":"00000000-0000-0000-0000-000000000010","account_id":"00000000-0000-0000-0000-000000000011","period_start":"2026-06-11","period_end":"2026-07-10","statement_date":"2026-07-10","due_date":"2026-07-22","is_opening_cycle":false,"purchase_minor":50000,"opening_minor":0,"amount_due_minor":50000,"repaid_minor":12000,"remaining_minor":38000,"status":"partial","is_overdue":false,"installment_principal_minor":0,"installment_fee_minor":0,"installment_periods":[],"version":2,"created_at":"2026-07-10T00:00:00Z","updated_at":"2026-07-15T00:00:00Z"}"#
    let json =
      #"{"account_id":"00000000-0000-0000-0000-000000000011","name":"信用卡","institution":"银行","last_four":"1234","credit_limit_minor":1000000,"current_debt_minor":38000,"available_credit_minor":962000,"over_limit_minor":0,"opening_configuration_required":false,"statement_day":10,"due_day":22,"current_cycle":"#
      + cycle + #", "next_due_cycle":"# + cycle
      + #", "has_overdue_cycle":false,"active_installment_count":0,"future_scheduled_gross_minor":0,"next_installment":null}"#
    let data = Data(json.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let summary = try decoder.decode(CreditAccountSummaryDTO.self, from: data)
    #expect(summary.currentCycle?.amountDueMinor == 50_000)
    #expect(summary.nextDueCycle?.status == .partial)
    #expect(summary.availableCreditMinor == 962_000)
    #expect(summary.overLimitMinor == 0)
  }

  @Test("Credit purchase and repayment use exact transaction fields")
  func creditTransactionPayloads() throws {
    let creditAccount = UUID()
    let category = UUID()
    let paymentAccount = UUID()
    let cycle = UUID()
    var purchase = TransactionDraft()
    purchase.kind = .creditPurchase
    purchase.amountMinor = 12_345
    purchase.title = "消费"
    purchase.accountID = creditAccount
    purchase.categoryID = category
    var repayment = TransactionDraft()
    repayment.kind = .repayment
    repayment.amountMinor = 5_000
    repayment.title = "还款"
    repayment.accountID = paymentAccount
    repayment.destinationAccountID = creditAccount
    repayment.creditCycleID = cycle
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let purchaseJSON = try #require(
      JSONSerialization.jsonObject(with: encoder.encode(purchase)) as? [String: Any])
    let repaymentJSON = try #require(
      JSONSerialization.jsonObject(with: encoder.encode(repayment)) as? [String: Any])
    #expect(purchaseJSON["credit_cycle_id"] is NSNull)
    #expect(purchaseJSON["account_id"] as? String == creditAccount.uuidString)
    #expect(repaymentJSON["category_id"] is NSNull)
    #expect(repaymentJSON["credit_cycle_id"] as? String == cycle.uuidString)
  }

  @Test("Credit opening debt requires valid explicit dates") @MainActor
  func openingDebtValidation() {
    var draft = AccountDraft()
    draft.name = "信用卡"
    draft.kind = .credit
    draft.creditLimitMinor = 100_000
    draft.statementDay = 10
    draft.dueDay = 22
    draft.openingBalanceMinor = 5_000
    #expect(AccountsModel.validate(draft) == "正数期初欠款需要确认余额日期和到期日。")
    draft.openingBalanceAsOfDate = "2026-07-10"
    draft.openingDueDate = "2026-07-09"
    #expect(AccountsModel.validate(draft) == "期初到期日不能早于余额日期。")
    draft.openingDueDate = "2026-07-22"
    #expect(AccountsModel.validate(draft) == nil)
  }

  @Test("Credit dashboard aggregation reports Int64 overflow")
  func creditDashboardOverflow() {
    let now = Date(timeIntervalSince1970: 0)
    let first = AccountDTO(
      id: UUID(), name: "A", kind: .cash, institution: nil, lastFour: nil, openingBalanceMinor: 0,
      currentBalanceMinor: .max, openingBalanceAsOfDate: nil, openingDueDate: nil,
      creditLimitMinor: nil, statementDay: nil, dueDay: nil, sortOrder: 0, archivedAt: nil,
      usageCount: 0, version: 1, createdAt: now, updatedAt: now)
    let second = AccountDTO(
      id: UUID(), name: "B", kind: .debit, institution: nil, lastFour: nil, openingBalanceMinor: 0,
      currentBalanceMinor: 1, openingBalanceAsOfDate: nil, openingDueDate: nil,
      creditLimitMinor: nil, statementDay: nil, dueDay: nil, sortOrder: 1, archivedAt: nil,
      usageCount: 0, version: 1, createdAt: now, updatedAt: now)
    #expect(CreditDashboardTotals.checked(accounts: [first, second], credit: []) == nil)
  }

  @Test("Editing a settled repayment retains its canonical cycle") @MainActor
  func settledRepaymentCycleRetention() async throws {
    let cycle = CreditCycleDTO(
      id: UUID(), accountID: UUID(), periodStart: "2026-06-11", periodEnd: "2026-07-10",
      statementDate: "2026-07-10", dueDate: "2026-07-22", isOpeningCycle: false,
      purchaseMinor: 5_000, openingMinor: 0, amountDueMinor: 5_000, repaidMinor: 5_000,
      remainingMinor: 0, status: .settled, isOverdue: false, version: 1, createdAt: Date(),
      updatedAt: Date())
    let model = CreditModel(repository: SettledCycleRepository(cycle: cycle))
    #expect(try await model.cyclesForRepayment(accountID: cycle.accountID).isEmpty)
    #expect(
      try await model.cyclesForRepayment(accountID: cycle.accountID, retaining: cycle.id).map(\.id)
        == [cycle.id])
  }
}

@Suite("FiscalKit P5 contracts")
struct FiscalKitP5Tests {
  @Test("Installment plan decodes scheduled gross semantics and fee metadata")
  func planResponsePayload() throws {
    let data = Data(
      #"{"id":"00000000-0000-0000-0000-000000000101","purchase_transaction_id":"00000000-0000-0000-0000-000000000102","credit_account_id":"00000000-0000-0000-0000-000000000103","fee_transaction_id":"00000000-0000-0000-0000-000000000104","fee_category_id":"00000000-0000-0000-0000-000000000105","fee_occurred_at":"2026-07-15T08:00:00Z","title":"MacBook","status":"active","principal_minor":1200000,"fee_minor":6000,"total_financed_minor":1206000,"installment_count":12,"start_statement_date":"2026-08-10","locked_count":2,"future_count":10,"cancelled_count":0,"cycle_settled_count":1,"scheduled_gross_minor":1206000,"future_scheduled_gross_minor":1005000,"next_period":null,"periods":[],"version":3,"created_at":"2026-07-15T08:00:00Z","updated_at":"2026-07-15T08:00:00Z"}"#
        .utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let plan = try decoder.decode(InstallmentPlanDTO.self, from: data)
    #expect(plan.futureScheduledGrossMinor == 1_005_000)
    #expect(plan.feeTransactionID == UUID(uuidString: "00000000-0000-0000-0000-000000000104"))
    #expect(plan.feeCategoryID == UUID(uuidString: "00000000-0000-0000-0000-000000000105"))
    #expect(plan.cycleSettledCount == 1)
  }

  @Test("Installment preview accepts cycles that do not exist yet")
  func previewCycleIDsAreNullable() throws {
    let data = Data(
      #"{"sequence":1,"scheduled_cycle_id":null,"effective_cycle_id":null,"scheduled_statement_date":"2026-08-10","effective_statement_date":"2026-08-10","due_date":"2026-08-22","principal_minor":10000,"fee_minor":500,"amount_due_minor":10500,"locked":false,"status":"scheduled"}"#
        .utf8)
    let period = try JSONDecoder().decode(InstallmentPeriodPreview.self, from: data)
    #expect(period.scheduledCycleID == nil)
    #expect(period.effectiveCycleID == nil)
    #expect(period.amountDueMinor == 10_500)
  }

  @Test("Installment mutation payload uses exact snake-case contract")
  func createPayload() throws {
    let purchaseID = UUID()
    let categoryID = UUID()
    let request = InstallmentCreateRequest(
      purchaseTransactionID: purchaseID, installmentCount: 6, totalFeeMinor: 1_200,
      feeCategoryID: categoryID, feeOccurredAt: Date(timeIntervalSince1970: 0),
      startStatementDate: "2026-08-10")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let object = try #require(
      JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any])
    #expect(object["purchase_transaction_id"] as? String == purchaseID.uuidString)
    #expect(object["installment_count"] as? Int == 6)
    #expect(object["total_fee_minor"] as? Int == 1_200)
    #expect(object["fee_category_id"] as? String == categoryID.uuidString)
    #expect(object["start_statement_date"] as? String == "2026-08-10")
  }

  @Test("System-generated installment ledger kinds are not manual editor choices")
  func systemKindsAreNotManual() {
    #expect(TransactionKind(rawValue: "installment_fee") == .installmentFee)
    #expect(TransactionKind(rawValue: "installment_refund") == .installmentRefund)
    #expect(!TransactionKind.allCases.contains(.installmentFee))
    #expect(!TransactionKind.allCases.contains(.installmentRefund))
  }

  @Test("Missing P5 outer keys fail decoding instead of silently using P4 shape")
  func requiredOuterKeys() throws {
    let missingFeeMetadata = installmentPlanJSON(planID: UUID(), accountID: UUID())
      .replacingOccurrences(of: #""fee_transaction_id":null,"#, with: "")
    #expect(throws: DecodingError.self) {
      try fiscalDecoder().decode(InstallmentPlanDTO.self, from: Data(missingFeeMetadata.utf8))
    }

    let legacyCycle = Data(
      #"{"id":"00000000-0000-0000-0000-000000000010","account_id":"00000000-0000-0000-0000-000000000011","period_start":"2026-06-11","period_end":"2026-07-10","statement_date":"2026-07-10","due_date":"2026-07-22","is_opening_cycle":false,"purchase_minor":50000,"opening_minor":0,"amount_due_minor":50000,"repaid_minor":12000,"remaining_minor":38000,"status":"partial","is_overdue":false,"version":2,"created_at":"2026-07-10T00:00:00Z","updated_at":"2026-07-15T00:00:00Z"}"#
        .utf8)
    #expect(throws: DecodingError.self) {
      try fiscalDecoder().decode(CreditCycleDTO.self, from: legacyCycle)
    }

    let missingLiabilityAccount = Data(
      #"{"total_future_scheduled_gross_minor":0,"groups":[]}"#.utf8)
    let nullLiabilityAccount = Data(
      #"{"account_id":null,"total_future_scheduled_gross_minor":0,"groups":[]}"#.utf8)
    #expect(throws: DecodingError.self) {
      try fiscalDecoder().decode(InstallmentLiabilities.self, from: missingLiabilityAccount)
    }
    #expect(throws: DecodingError.self) {
      try fiscalDecoder().decode(InstallmentLiabilities.self, from: nullLiabilityAccount)
    }
  }

  @Test("Backend installment conflict codes all trigger conflict recovery")
  func conflictCodes() {
    #expect(InstallmentModel.isConflictCode("version_conflict"))
    #expect(InstallmentModel.isConflictCode("resource_version_conflict"))
    #expect(InstallmentModel.isConflictCode("installment_operation_conflict"))
    #expect(!InstallmentModel.isConflictCode("idempotency_key_reused"))
  }

  @Test("Editor preserves a historical start date outside the rolling eligible window")
  func historicalStartDatePickerOption() {
    #expect(
      InstallmentEditorSheet.legacyStartStatementDate(
        planStartDate: "2025-01-10", eligibleStatementDates: ["2026-08-10", "2026-09-10"])
        == "2025-01-10")
    #expect(
      InstallmentEditorSheet.legacyStartStatementDate(
        planStartDate: "2026-08-10", eligibleStatementDates: ["2026-08-10", "2026-09-10"]) == nil)
  }

  @Test("Switching accounts never publishes the previous account installment list") @MainActor
  func accountKeyedLoading() async throws {
    let first = UUID()
    let second = UUID()
    let repository = AuditInstallmentRepository(firstAccountID: first, secondAccountID: second)
    let model = InstallmentModel(repository: repository, transactions: AuditTransactionRepository())
    let stale = Task { await model.loadAccount(first) }
    try await Task.sleep(for: .milliseconds(10))
    await model.loadAccount(second)
    await stale.value
    #expect(model.loadedAccountID == second)
    #expect(model.plans.allSatisfy { $0.creditAccountID == second })
    #expect(model.liabilities?.accountID == second)
  }

  @Test("A changed editor request cannot submit an old preview") @MainActor
  func previewSnapshotInvalidation() async throws {
    let accountID = UUID()
    let repository = AuditInstallmentRepository(firstAccountID: accountID, secondAccountID: UUID())
    let model = InstallmentModel(repository: repository, transactions: AuditTransactionRepository())
    let planID = await repository.firstPlanID
    await model.loadPlan(planID)
    let purchase = try #require(model.selectedPurchase)
    let base = InstallmentReplacementRequest(
      expectedVersion: 1,
      purchase: .init(
        amountMinor: purchase.amountMinor, occurredAt: purchase.occurredAt, title: purchase.title,
        note: purchase.note, accountID: purchase.accountID!, categoryID: purchase.categoryID!),
      installmentCount: 6, totalFeeMinor: 0, feeCategoryID: nil, feeOccurredAt: nil,
      startStatementDate: "2026-08-10")
    #expect(await model.preview(base))
    var changed = base
    changed.installmentCount = 12
    #expect(await model.update(changed) == nil)
    #expect(model.changePreview == nil)
    #expect(await repository.updateCalls == 0)
  }
}

private func fiscalDecoder() -> JSONDecoder {
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  return decoder
}
private func installmentPlanJSON(planID: UUID, accountID: UUID) -> String {
  #"{"id":"\#(planID.uuidString)","purchase_transaction_id":"00000000-0000-0000-0000-000000000202","credit_account_id":"\#(accountID.uuidString)","fee_transaction_id":null,"fee_category_id":null,"fee_occurred_at":null,"title":"测试分期","status":"active","principal_minor":60000,"fee_minor":0,"total_financed_minor":60000,"installment_count":6,"start_statement_date":"2026-08-10","locked_count":0,"future_count":6,"cancelled_count":0,"cycle_settled_count":0,"scheduled_gross_minor":60000,"future_scheduled_gross_minor":60000,"next_period":null,"periods":[],"version":1,"created_at":"2026-07-15T08:00:00Z","updated_at":"2026-07-15T08:00:00Z"}"#
}
private func installmentPreviewJSON(planID: UUID, accountID: UUID) -> String {
  #"{"id":"\#(planID.uuidString)","purchase_transaction_id":"00000000-0000-0000-0000-000000000202","credit_account_id":"\#(accountID.uuidString)","fee_transaction_id":null,"fee_category_id":null,"fee_occurred_at":null,"title":"测试分期","status":"active","principal_minor":60000,"fee_minor":0,"total_financed_minor":60000,"installment_count":6,"start_statement_date":"2026-08-10","locked_count":0,"future_count":6,"cancelled_count":0,"cycle_settled_count":0,"scheduled_gross_minor":60000,"future_scheduled_gross_minor":60000,"next_period":null,"periods":[]}"#
}

private actor AuditInstallmentRepository: InstallmentRepository {
  let firstAccountID: UUID
  let secondAccountID: UUID
  let firstPlanID = UUID()
  let secondPlanID = UUID()
  private(set) var updateCalls = 0
  init(firstAccountID: UUID, secondAccountID: UUID) {
    self.firstAccountID = firstAccountID
    self.secondAccountID = secondAccountID
  }
  func plan(_ accountID: UUID, _ id: UUID) throws -> InstallmentPlanDTO {
    try fiscalDecoder().decode(
      InstallmentPlanDTO.self,
      from: Data(installmentPlanJSON(planID: id, accountID: accountID).utf8))
  }
  func list(accountID: UUID?, status: InstallmentPlanStatus?, cursor: String?, limit: Int)
    async throws -> InstallmentPlanPage
  {
    let accountID = accountID ?? firstAccountID
    if accountID == firstAccountID { try? await Task.sleep(for: .milliseconds(80)) }
    return .init(
      items: [try plan(accountID, accountID == firstAccountID ? firstPlanID : secondPlanID)],
      nextCursor: nil)
  }
  func get(id: UUID) async throws -> InstallmentPlanDTO { try plan(firstAccountID, id) }
  func eligibility(transactionID: UUID) async throws -> InstallmentEligibility {
    throw RaceRepositoryError.unsupported
  }
  func cycleOptions(transactionID: UUID, months: Int) async throws -> [InstallmentCycleOption] {
    []
  }
  func liabilities(accountID: UUID?) async throws -> InstallmentLiabilities {
    let json =
      #"{"account_id":"\#((accountID ?? firstAccountID).uuidString)","total_future_scheduled_gross_minor":60000,"groups":[]}"#
    return try fiscalDecoder().decode(InstallmentLiabilities.self, from: Data(json.utf8))
  }
  func create(_ request: InstallmentCreateRequest, idempotencyKey: UUID) async throws
    -> InstallmentPlanDTO
  { throw RaceRepositoryError.unsupported }
  func preview(id: UUID, request: InstallmentReplacementRequest) async throws
    -> InstallmentPlanChangePreview
  {
    let current = installmentPlanJSON(planID: id, accountID: firstAccountID)
    let proposed = installmentPreviewJSON(planID: id, accountID: firstAccountID)
    let json =
      #"{"current_plan":\#(current),"proposed_plan":\#(proposed),"locked_periods":[],"future_periods":[],"affected_cycles":[],"warnings":[]}"#
    return try fiscalDecoder().decode(InstallmentPlanChangePreview.self, from: Data(json.utf8))
  }
  func update(id: UUID, request: InstallmentReplacementRequest) async throws -> InstallmentPlanDTO {
    updateCalls += 1
    return try plan(firstAccountID, id)
  }
  func settlementPreview(id: UUID, request: InstallmentSettlementRequest) async throws
    -> InstallmentSettlementPreview
  { throw RaceRepositoryError.unsupported }
  func settleEarly(id: UUID, request: InstallmentSettlementRequest, idempotencyKey: UUID)
    async throws -> InstallmentSettlementResult
  { throw RaceRepositoryError.unsupported }
  func reversePreview(id: UUID, request: InstallmentOperationRequest) async throws
    -> InstallmentReversePreview
  { throw RaceRepositoryError.unsupported }
  func reverseSettlement(id: UUID, request: InstallmentOperationRequest, idempotencyKey: UUID)
    async throws -> InstallmentReverseResult
  { throw RaceRepositoryError.unsupported }
  func cancellationPreview(id: UUID, request: InstallmentOperationRequest) async throws
    -> InstallmentCancellationPreview
  { throw RaceRepositoryError.unsupported }
  func cancelFuture(id: UUID, request: InstallmentOperationRequest, idempotencyKey: UUID)
    async throws -> InstallmentCancellationResult
  { throw RaceRepositoryError.unsupported }
}

private actor AuditTransactionRepository: TransactionRepository {
  func list(_ query: TransactionQuery) async throws -> TransactionPage {
    .init(items: [], nextCursor: nil)
  }
  func get(id: UUID) async throws -> TransactionDTO {
    TransactionDTO(
      id: id, kind: .creditPurchase, occurredAt: Date(timeIntervalSince1970: 0),
      businessDate: "1970-01-01", title: "测试消费", note: nil, amountMinor: 60_000, categoryID: UUID(),
      accountID: UUID(), destinationAccountID: nil, creditCycleID: nil, source: "manual",
      postings: [], version: 1, voidedAt: nil, createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 0))
  }
  func create(_ draft: TransactionDraft, idempotencyKey: UUID) async throws -> TransactionDTO {
    throw RaceRepositoryError.unsupported
  }
  func update(id: UUID, version: Int, draft: TransactionDraft) async throws -> TransactionDTO {
    throw RaceRepositoryError.unsupported
  }
  func void(_ transaction: TransactionDTO) async throws -> TransactionDTO {
    throw RaceRepositoryError.unsupported
  }
  func restore(_ transaction: TransactionDTO) async throws -> TransactionDTO {
    throw RaceRepositoryError.unsupported
  }
}

private actor SettledCycleRepository: CreditRepository {
  let value: CreditCycleDTO
  init(cycle: CreditCycleDTO) { value = cycle }
  func listAccounts() async throws -> [CreditAccountSummaryDTO] { [] }
  func account(id: UUID) async throws -> CreditAccountSummaryDTO {
    throw RaceRepositoryError.unsupported
  }
  func cycles(accountID: UUID, cursor: String?, limit: Int) async throws -> CreditCyclePage {
    .init(items: [value], nextCursor: nil)
  }
  func cycle(id: UUID) async throws -> CreditCycleDTO { value }
  func transactions(cycleID: UUID, cursor: String?, limit: Int) async throws -> TransactionPage {
    .init(items: [], nextCursor: nil)
  }
}

private enum RaceRepositoryError: Error { case unsupported }
private actor AuditReimbursementRepository: ReimbursementRepository {
  let slowID: UUID
  let currentID: UUID
  private(set) var createReceiptCalls = 0
  private(set) var listCalls = 0
  private(set) var receiptCalls = 0
  private(set) var lifecycleIDs: [UUID] = []
  private(set) var lifecycleActions: [String] = []
  private(set) var lifecycleVersions: [Int] = []
  private var claimVersion = 1
  init(slowID: UUID, currentID: UUID) {
    self.slowID = slowID
    self.currentID = currentID
  }
  func list(status: ReimbursementClaimStatus?, includeArchived: Bool, cursor: String?, limit: Int)
    async throws -> ReimbursementClaimPage
  {
    listCalls += 1
    if cursor != nil {
      try? await Task.sleep(for: .milliseconds(80))
      return .init(items: [claim(UUID())], nextCursor: nil)
    }
    return .init(items: [claim(currentID)], nextCursor: "claims-next")
  }
  func get(id: UUID) async throws -> ReimbursementClaimDTO {
    if id == slowID { try? await Task.sleep(for: .milliseconds(80)) }
    return claim(id)
  }
  func setClaimVersion(_ version: Int) { claimVersion = version }
  func create(_ request: ReimbursementClaimCreateRequest, idempotencyKey: UUID) async throws
    -> ReimbursementClaimDTO
  { throw RaceRepositoryError.unsupported }
  func preview(id: UUID, request: ReimbursementClaimReplacementRequest) async throws
    -> ReimbursementClaimPreview
  { throw RaceRepositoryError.unsupported }
  func update(id: UUID, request: ReimbursementClaimReplacementRequest) async throws
    -> ReimbursementClaimDTO
  { throw RaceRepositoryError.unsupported }
  func lifecycle(id: UUID, action: String, version: Int) async throws -> ReimbursementClaimDTO {
    lifecycleIDs.append(id)
    lifecycleActions.append(action)
    lifecycleVersions.append(version)
    claimVersion = version + 1
    return claim(id)
  }
  func cancelPreview(id: UUID, version: Int) async throws -> ReimbursementCancelPreview {
    .init(
      current: claim(id, version: version), proposedStatus: .cancelled, releasedMinor: 1_000,
      retainedReceivedMinor: 0)
  }
  func receipts(claimID: UUID, cursor: String?, limit: Int) async throws -> ReimbursementReceiptPage
  {
    receiptCalls += 1
    if cursor != nil {
      try? await Task.sleep(for: .milliseconds(50))
      return .init(items: [], nextCursor: nil)
    }
    return .init(items: [], nextCursor: "receipt-next")
  }
  func receipt(id: UUID) async throws -> ReimbursementReceiptDTO {
    throw RaceRepositoryError.unsupported
  }
  func receiptPreview(
    id: UUID?, claimID: UUID, create: ReimbursementReceiptRequest?,
    replace: ReimbursementReceiptReplacementRequest?
  ) async throws -> ReimbursementReceiptPreview {
    let request = try #require(create)
    return .init(
      claimBefore: claim(claimID), partyID: request.partyID, amountMinor: request.amountMinor,
      partyReceivedBeforeMinor: 0, partyReceivedAfterMinor: request.amountMinor,
      claimReceivedBeforeMinor: 0, claimReceivedAfterMinor: request.amountMinor,
      persistedAllocations: [])
  }
  func createReceipt(claimID: UUID, request: ReimbursementReceiptRequest, idempotencyKey: UUID)
    async throws -> ReimbursementReceiptDTO
  {
    createReceiptCalls += 1
    throw RaceRepositoryError.unsupported
  }
  func updateReceipt(id: UUID, request: ReimbursementReceiptReplacementRequest) async throws
    -> ReimbursementReceiptDTO
  { throw RaceRepositoryError.unsupported }
  func receiptLifecycle(id: UUID, action: String, request: ReimbursementReceiptVersionRequest)
    async throws -> ReimbursementReceiptDTO
  { throw RaceRepositoryError.unsupported }
  func expenseOptions(search: String?) async throws -> [ReimbursementExpenseOption] { [] }
  func summary(dateFrom: String?, dateTo: String?) async throws -> ReimbursementSummary {
    .init(
      grossExpenseMinor: 1_000, merchantPrincipalRefundMinor: 0, expectedReimbursementMinor: 1_000,
      receivedReimbursementMinor: 0, personalExpectedExpenseMinor: 0,
      personalRealizedExpenseMinor: 1_000, outstandingMinor: 1_000)
  }
  private func claim(_ id: UUID, version: Int? = nil) -> ReimbursementClaimDTO {
    let transactionID = UUID()
    let allocationID = UUID()
    let partyID = UUID()
    let now = Date(timeIntervalSince1970: 0)
    let allocation = ReimbursementAllocationDTO(
      id: allocationID, transactionID: transactionID, expenseTitle: "酒店", expenseAmountMinor: 1_000,
      amountMinor: 1_000, receivedMinor: 0, outstandingMinor: 1_000, locked: false, position: 0)
    let party = ReimbursementPartyDTO(
      id: partyID, name: "公司", expectedDate: "2026-07-25", note: nil, claimedMinor: 1_000,
      receivedMinor: 0, outstandingMinor: 1_000, status: "pending", position: 0,
      allocations: [allocation])
    return ReimbursementClaimDTO(
      id: id, title: id == currentID ? "当前报销单" : "旧报销单", note: nil, status: .pending,
      totalClaimedMinor: 1_000, receivedMinor: 0, outstandingMinor: 1_000, expenseCount: 1,
      partyCount: 1, receiptCount: 0, parties: [party], latestReceipt: nil,
      version: version ?? claimVersion,
      submittedAt: now, cancelledAt: nil, voidedAt: nil, archivedAt: nil, createdAt: now,
      updatedAt: now)
  }
}
private actor RaceTransactionRepository: TransactionRepository {
  func list(_ query: TransactionQuery) async throws -> TransactionPage {
    if query.cursor != nil {
      try? await Task.sleep(for: .milliseconds(120))
      return .init(items: [item("stale-more", .income)], nextCursor: nil)
    }
    if query.search == "old" {
      try? await Task.sleep(for: .milliseconds(100))
      return .init(items: [item("old", .income)], nextCursor: nil)
    }
    if query.search == "new" { return .init(items: [item("new", .income)], nextCursor: nil) }
    if query.kind == .expense { return .init(items: [item("expense", .expense)], nextCursor: nil) }
    return .init(items: [item("first", .income)], nextCursor: "next")
  }
  func get(id: UUID) async throws -> TransactionDTO { throw RaceRepositoryError.unsupported }
  func create(_ draft: TransactionDraft, idempotencyKey: UUID) async throws -> TransactionDTO {
    throw RaceRepositoryError.unsupported
  }
  func update(id: UUID, version: Int, draft: TransactionDraft) async throws -> TransactionDTO {
    throw RaceRepositoryError.unsupported
  }
  func void(_ transaction: TransactionDTO) async throws -> TransactionDTO {
    throw RaceRepositoryError.unsupported
  }
  func restore(_ transaction: TransactionDTO) async throws -> TransactionDTO {
    throw RaceRepositoryError.unsupported
  }

  private func item(_ title: String, _ kind: TransactionKind) -> TransactionDTO {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return TransactionDTO(
      id: UUID(), kind: kind, occurredAt: now, businessDate: "2026-07-15", title: title, note: nil,
      amountMinor: 100, categoryID: nil, accountID: nil, destinationAccountID: nil,
      creditCycleID: nil, source: "manual", postings: [], version: 1, voidedAt: nil, createdAt: now,
      updatedAt: now)
  }
}
