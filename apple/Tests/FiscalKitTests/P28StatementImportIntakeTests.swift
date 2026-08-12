import Foundation
import Testing

@testable import FiscalKit

@Suite("FiscalKit P28-A statement import intake", .serialized)
struct FiscalKitP28StatementImportIntakeTests {
  @Test("Consent is required before any metadata API call, then only redacted JSON crosses")
  func consentAndPayloadRedline() async throws {
    let repository = IntakeRepositoryFixture()
    let model = await MainActor.run {
      StatementImportIntakeModel(repository: repository, processor: IntakeProcessorFixture())
    }
    await model.select(url: URL(fileURLWithPath: "/private/statement-1234.pdf"))
    #expect(await repository.callNames() == [])
    #expect(await MainActor.run { model.phase == .awaitingConsent })

    await model.consentAndUpload()
    #expect(await repository.callNames() == ["register", "start", "evidence"])
    #expect(await MainActor.run {
      if case .reviewRequired = model.phase { return true }
      return false
    })
    let evidence = try #require(await repository.evidencePackages().first)
    let payload = String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self)
    #expect(!payload.contains("/private/statement-1234.pdf"))
    #expect(!payload.contains("statement-1234.pdf"))
    #expect(!payload.contains("1234567890123456"))
    #expect(!payload.contains("image"))
    #expect(!payload.contains("bookmark"))
    #expect(!payload.contains("rawText"))
    #expect(payload.contains("[REDACTED]"))
  }

  @Test("Duplicate stops before start and leaves no source metadata after cleanup")
  func duplicateDoesNotStartExtraction() async throws {
    let repository = IntakeRepositoryFixture(duplicate: true)
    let model = await MainActor.run {
      StatementImportIntakeModel(repository: repository, processor: IntakeProcessorFixture())
    }
    await model.select(url: URL(fileURLWithPath: "/private/duplicate.pdf"))
    await model.consentAndUpload()
    #expect(await repository.callNames() == ["register"])
    #expect(await MainActor.run {
      if case .duplicate = model.phase { return true }
      return false
    })
    await model.cleanup()
    #expect(await MainActor.run { model.metadata == nil && model.preview == nil && model.phase == .idle })
  }

  @Test("Response loss has no auto resend and explicit retry reuses one redacted package")
  func responseLossNeedsExplicitRetry() async throws {
    let repository = IntakeRepositoryFixture(failFirstEvidence: true)
    let model = await MainActor.run {
      StatementImportIntakeModel(repository: repository, processor: IntakeProcessorFixture())
    }
    await model.select(url: URL(fileURLWithPath: "/private/loss.pdf"))
    await model.consentAndUpload()
    #expect(await repository.callNames() == ["register", "start", "evidence"])
    #expect(await MainActor.run {
      if case .remoteUnknown = model.phase { return true }
      return false
    })
    await model.retryEvidence()
    #expect(await repository.callNames() == ["register", "start", "evidence", "evidence"])
    let packages = await repository.evidencePackages()
    #expect(packages.count == 2)
    #expect(packages.first == packages.last)
  }

  @Test("Missing start version stops before local extraction and evidence upload")
  func missingStartVersionIsFatal() async throws {
    let repository = IntakeRepositoryFixture(missingStartVersion: true)
    let processor = IntakeProcessorFixture()
    let model = await MainActor.run {
      StatementImportIntakeModel(repository: repository, processor: processor)
    }
    await model.select(url: URL(fileURLWithPath: "/private/header.pdf"))
    await model.consentAndUpload()
    #expect(await repository.callNames() == ["register", "start", "fail"])
    #expect(await processor.extractionCount() == 0)
  }

  @Test("Cancel sends one failure attempt and never queues an automatic resend")
  func cancelUsesOneFailAttempt() async throws {
    let repository = IntakeRepositoryFixture(failFirstEvidence: true)
    let model = await MainActor.run {
      StatementImportIntakeModel(repository: repository, processor: IntakeProcessorFixture())
    }
    await model.select(url: URL(fileURLWithPath: "/private/cancel.pdf"))
    await model.consentAndUpload()
    await model.cancel()
    #expect(await repository.callNames() == ["register", "start", "evidence", "fail"])
    #expect(await MainActor.run { model.phase == .cancelled })
  }

  @Test("P28-B workbench is cache-free, masked-only, and clears on exit")
  func workbenchRoutesMaskedEvidenceWithoutConfirm() async throws {
    let batchID = UUID(); let rowID = UUID()
    let repository = WorkbenchFixture(batchID: batchID, rowID: rowID)
    let model = await MainActor.run { StatementImportReviewWorkbenchModel(repository: repository) }
    await model.reload(batchID: batchID)
    let row = try #require(await MainActor.run { model.workbench?.rows.first })
    await model.select(row)
    #expect(await repository.calls() == ["workbench", "page"])
    #expect(await MainActor.run { model.page?.evidenceTextMasked == "[REDACTED] market" })
    await model.clear()
    #expect(await MainActor.run { model.workbench == nil && model.page == nil })
  }

  @Test("Resolution PUT reloads cache-free versions and never resends after a 409")
  func resolutionUsesFreshVersionsAndConflictReloadsOnce() async throws {
    let batchID = UUID(), rowID = UUID()
    let cache = HTTPResponseCache()
    StubURLProtocol.install { request in
      let path = request.url!.path
      #expect(!path.contains("confirm"))
      if request.httpMethod == "GET" {
        #expect(path == "/api/v1/statement-imports/\(batchID)/review-workbench")
        #expect(request.url?.query?.contains("cursor=0") == true)
        #expect(request.url?.query?.contains("limit=100") == true || request.url?.query?.contains("limit=200") == true)
        return .init(body: Self.workbenchBody(batchID: batchID, rowID: rowID, batchVersion: 9, rowVersion: 4, draftVersion: 7))
      }
      #expect(path == "/api/v1/statement-imports/\(batchID)/rows/\(rowID)/draft-resolution")
      #expect(request.httpMethod == "PUT")
      let data = try! #require(Self.requestBody(request))
      let body = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
      #expect(body["expected_batch_version"] as? Int == 9)
      #expect(body["expected_row_version"] as? Int == 4)
      #expect(body["expected_resolution_version"] as? Int == 7)
      #expect(body["resolution"] as? String == "ignore_intentional")
      #expect(body["ignored_reason"] as? String == "synthetic reason")
      return .init(status: 409, body: Data(#"{"error":{"code":"version_conflict","message":"changed","request_id":"r"}}"#.utf8))
    }
    let transport = APITransport(baseURL: URL(string: "http://stub")!, session: StubURLProtocol.session(), token: "t", responseCache: cache)
    let model = await MainActor.run {
      StatementImportReviewWorkbenchModel(
        repository: RemoteStatementImportReviewWorkbenchRepository(transport: transport),
        resolutionRepository: RemoteStatementImportDraftResolutionRepository(transport: transport))
    }
    await model.reload(batchID: batchID) // visible selection state is stale by design
    await model.saveResolution(rowID: rowID, resolution: .ignoreIntentional, ignoredReason: "synthetic reason")
    // Initial display GET, mutation preflight GET, then the conflict recovery GET.  No resend.
    #expect(StubURLProtocol.requestCount == 4)
    #expect(await cache.snapshot().entryCount == 0)
    #expect(await MainActor.run { model.error == "服务器已变化，请重新选择后再提交。" })
  }

  @Test("Final create draft reads its current version and decodes the normal JSON response")
  func finalCreateDraftUsesFreshVersion() async throws {
    let batchID = UUID(), rowID = UUID(), finalID = UUID(), resolutionID = UUID()
    StubURLProtocol.install { request in
      if request.httpMethod == "GET" {
        return .init(body: Self.workbenchBody(batchID: batchID, rowID: rowID, batchVersion: 9, rowVersion: 4, draftVersion: 2, finalVersion: 6))
      }
      #expect(request.url?.path == "/api/v1/statement-imports/\(batchID)/rows/\(rowID)/final-create-draft")
      let data = try! #require(Self.requestBody(request))
      let body = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
      #expect(body["expected_version"] as? Int == 6)
      #expect((body["transaction"] as? [String: Any])?["kind"] as? String == "expense")
      return .init(body: Data("""
        {"id":"\(finalID.uuidString)","statement_import_row_id":"\(rowID.uuidString)","draft_resolution_id":"\(resolutionID.uuidString)","transaction":{"kind":"expense","amount_minor":123,"occurred_at":"2026-08-12T12:00:00Z","title":"Manual","note":null,"account_id":null,"category_id":null,"destination_account_id":null,"credit_cycle_id":null},"version":7}
        """.utf8))
    }
    let transport = APITransport(baseURL: URL(string: "http://stub")!, session: StubURLProtocol.session(), token: "t", responseCache: HTTPResponseCache())
    var transaction = TransactionDraft(); transaction.kind = .expense; transaction.amountMinor = 123
    transaction.title = "Manual"; transaction.occurredAt = Date(timeIntervalSince1970: 1_786_276_800)
    let response = try await RemoteStatementImportFinalCreateDraftRepository(transport: transport)
      .putFinalCreateDraft(batchID: batchID, rowID: rowID, transaction: transaction)
    #expect(response.id == finalID && response.version == 7)
    #expect(StubURLProtocol.requestCount == 2)
  }

  @Test("Confirmation previews before one explicit final POST with its exact key")
  func confirmationPreviewThenExplicitFinalPost() async throws {
    let batchID = UUID(), rowID = UUID(), operationID = UUID()
    let observedConfirm = ConfirmationFlag()
    StubURLProtocol.install { request in
      let path = request.url!.path
      if request.httpMethod == "GET" {
        return .init(body: Self.workbenchBody(batchID: batchID, rowID: rowID, batchVersion: 9, rowVersion: 4, draftVersion: 7, resolution: "ignore_non_transaction"))
      }
      let data = try! #require(Self.requestBody(request))
      let body = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
      if path.hasSuffix("confirmation-preview") {
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == nil)
        #expect((body["row_ids"] as? [String]) == [rowID.uuidString])
        #expect(!observedConfirm.value)
        return .init(body: Data("""
          {"batch_id":"\(batchID.uuidString)","batch_version":9,"status":"review_required","selected_rows":[],"counts":{"selected":1,"create_new":0,"match_existing":0,"ignore_non_transaction":1,"ignore_intentional":0,"unresolved":0,"batch_unresolved":0},"amounts":{"known_create_minor":0,"known_match_minor":0,"known_total_minor":0,"unknown_selected_count":1},"checks":[],"warnings":[],"request":{"expected_batch_version":9,"rows":[{"row_id":"\(rowID.uuidString)","expected_row_version":4,"expected_draft_version":7,"expected_final_create_draft_version":null}]}}
          """.utf8))
      }
      #expect(path.hasSuffix("confirm")); #expect(!observedConfirm.value); observedConfirm.value = true
      #expect(UUID(uuidString: request.value(forHTTPHeaderField: "Idempotency-Key") ?? "") != nil)
      #expect(body["expected_batch_version"] as? Int == 9)
      return .init(body: Data("""
        {"operation_id":"\(operationID.uuidString)","batch_id":"\(batchID.uuidString)","batch_version":10,"status":"confirmed","confirmed_row_ids":["\(rowID.uuidString)"],"replay":false}
        """.utf8))
    }
    let transport = APITransport(baseURL: URL(string: "http://stub")!, session: StubURLProtocol.session(), token: "t", responseCache: HTTPResponseCache())
    let model = await MainActor.run {
      StatementImportReviewWorkbenchModel(
        repository: RemoteStatementImportReviewWorkbenchRepository(transport: transport),
        confirmationRepository: RemoteStatementImportConfirmationRepository(transport: transport))
    }
    #expect(await model.prepareConfirmation(batchID: batchID, rowIDs: [rowID]))
    #expect(!observedConfirm.value)
    #expect(await model.confirmPrepared())
    #expect(observedConfirm.value)
    #expect(StubURLProtocol.requestCount == 4) // fresh reload, preview, post-confirm reload
  }

  @Test("Confirmation transport loss has no resend and receipt lookup is explicit")
  func confirmationTransportLossNeedsExplicitReceiptLookup() async throws {
    let batchID = UUID(), rowID = UUID()
    let workbench = WorkbenchFixture(batchID: batchID, rowID: rowID, reviewAvailable: true, resolution: "ignore_non_transaction")
    let confirmations = ConfirmationFixture(batchID: batchID, rowID: rowID, failConfirm: true)
    let model = await MainActor.run { StatementImportReviewWorkbenchModel(repository: workbench, confirmationRepository: confirmations) }
    #expect(await model.prepareConfirmation(batchID: batchID, rowIDs: [rowID]))
    let confirmed = await model.confirmPrepared()
    #expect(!confirmed)
    #expect(await confirmations.calls() == ["preview", "confirm"])
    #expect(await MainActor.run { model.responseUnknownConfirmationKey != nil })
    #expect(await model.lookupConfirmationReceipt())
    #expect(await confirmations.calls() == ["preview", "confirm", "receipt"])
  }

  @Test("Frozen rows cannot enter confirmation and scene cleanup never retries evidence")
  func frozenRowsAndCleanupStayReadOnly() async throws {
    let batchID = UUID(), rowID = UUID()
    let workbench = WorkbenchFixture(batchID: batchID, rowID: rowID, reviewAvailable: true, resolution: "ignore_non_transaction", confirmed: true)
    let confirmations = ConfirmationFixture(batchID: batchID, rowID: rowID, failConfirm: false)
    let model = await MainActor.run { StatementImportReviewWorkbenchModel(repository: workbench, confirmationRepository: confirmations) }
    #expect(!(await model.prepareConfirmation(batchID: batchID, rowIDs: [rowID])))
    #expect(await confirmations.calls().isEmpty)
    await model.clear()
    #expect(await MainActor.run { model.confirmationPreview == nil && model.responseUnknownConfirmationKey == nil })
  }

  @Test("Scene interruption discards in-memory evidence without an automatic POST")
  func sceneInterruptionDoesNotRetryEvidence() async throws {
    let repository = IntakeRepositoryFixture(failFirstEvidence: true)
    let model = await MainActor.run { StatementImportIntakeModel(repository: repository, processor: IntakeProcessorFixture()) }
    await model.select(url: URL(fileURLWithPath: "/private/interrupted.pdf"))
    await model.consentAndUpload()
    #expect(await repository.callNames() == ["register", "start", "evidence"])
    await MainActor.run { model.discardForSceneInterruption() }
    #expect(await repository.callNames() == ["register", "start", "evidence"])
    #expect(await MainActor.run { model.phase == .idle && model.metadata == nil && model.preview == nil })
  }

  @Test("Background interruption cancels local extraction without evidence or failure POST")
  func backgroundInterruptionCancelsActiveLocalWorkLocally() async throws {
    let repository = IntakeRepositoryFixture()
    let processor = InterruptibleIntakeProcessor()
    let model = await MainActor.run {
      StatementImportIntakeModel(repository: repository, processor: processor)
    }
    await model.select(url: URL(fileURLWithPath: "/private/background.pdf"))
    await MainActor.run { model.beginConsentAndUpload() }
    await processor.waitUntilExtractionBegins()
    #expect(await repository.callNames() == ["register", "start"])

    await MainActor.run { model.discardForSceneInterruption() }
    await processor.waitUntilCancelled()
    #expect(await repository.callNames() == ["register", "start"])
    #expect(await MainActor.run { model.phase == .idle && model.metadata == nil && model.preview == nil })
  }

  private static func workbenchBody(
    batchID: UUID, rowID: UUID, batchVersion: Int, rowVersion: Int, draftVersion: Int,
    finalVersion: Int? = nil, resolution: String = "unresolved"
  ) -> Data {
    Data("""
    {"batch_id":"\(batchID.uuidString)","batch_version":\(batchVersion),"review_available":true,"rows":[{"id":"\(rowID.uuidString)","row_number":1,"page_number":1,"row_version":\(rowVersion),"source_kind":"text","evidence_text_masked":"[REDACTED] market","draft":{"id":"\(UUID().uuidString)","resolution":"\(resolution)","version":\(draftVersion)},"candidates":[],"final_create_draft_version":\(finalVersion.map { String($0) } ?? "null"),"is_confirmed":false}],"next_cursor":null}
    """.utf8)
  }

  private static func requestBody(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open(); defer { stream.close() }
    var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count >= 0 else { return nil }
      data.append(buffer, count: count)
    }
    return data
  }
}

private actor WorkbenchFixture: StatementImportReviewWorkbenchRepository {
  private let batchID: UUID; private let rowID: UUID; private var recorded: [String] = []
  private let reviewAvailable: Bool; private let resolution: String; private let confirmed: Bool
  init(batchID: UUID, rowID: UUID, reviewAvailable: Bool = false, resolution: String = "unresolved", confirmed: Bool = false) { self.batchID = batchID; self.rowID = rowID; self.reviewAvailable = reviewAvailable; self.resolution = resolution; self.confirmed = confirmed }
  func workbench(batchID: UUID, cursor: Int, limit: Int, filters: [String: String]) async throws -> StatementImportWorkbench {
    recorded.append("workbench"); #expect(batchID == self.batchID); #expect(cursor == 0 && limit == 100 && filters.isEmpty)
    return try JSONDecoder().decode(StatementImportWorkbench.self, from: Data("{\"batch_id\":\"\(batchID.uuidString)\",\"batch_version\":3,\"review_available\":\(reviewAvailable),\"rows\":[{\"id\":\"\(rowID.uuidString)\",\"row_number\":1,\"page_number\":1,\"row_version\":1,\"source_kind\":\"text\",\"evidence_text_masked\":\"[REDACTED] market\",\"draft\":{\"id\":\"\(UUID().uuidString)\",\"resolution\":\"\(resolution)\",\"version\":1},\"candidates\":[],\"final_create_draft_version\":null,\"is_confirmed\":\(confirmed)}],\"next_cursor\":null}".utf8))
  }
  func page(batchID: UUID, pageNumber: Int) async throws -> StatementImportWorkbenchPage {
    recorded.append("page"); #expect(batchID == self.batchID && pageNumber == 1)
    return try JSONDecoder().decode(StatementImportWorkbenchPage.self, from: Data("{\"page_number\":1,\"source_available\":true,\"source_kind\":\"text\",\"evidence_text_masked\":\"[REDACTED] market\"}".utf8))
  }
  func calls() -> [String] { recorded }
}

private actor ConfirmationFixture: StatementImportConfirmationRepository {
  private let batchID: UUID; private let rowID: UUID; private let failConfirm: Bool; private var recorded: [String] = []
  init(batchID: UUID, rowID: UUID, failConfirm: Bool) { self.batchID = batchID; self.rowID = rowID; self.failConfirm = failConfirm }
  func preview(batchID: UUID, rowIDs: [UUID]) async throws -> StatementImportConfirmationPreview {
    recorded.append("preview"); #expect(batchID == self.batchID && rowIDs == [rowID])
    return try JSONDecoder().decode(StatementImportConfirmationPreview.self, from: Data("{\"batch_id\":\"\(batchID.uuidString)\",\"batch_version\":3,\"status\":\"review_required\",\"counts\":{\"selected\":1,\"create_new\":0,\"match_existing\":0,\"ignore_non_transaction\":1,\"ignore_intentional\":0,\"unresolved\":0,\"batch_unresolved\":0},\"amounts\":{\"known_create_minor\":0,\"known_match_minor\":0,\"known_total_minor\":0,\"unknown_selected_count\":1},\"checks\":[],\"warnings\":[],\"request\":{\"expected_batch_version\":3,\"rows\":[{\"row_id\":\"\(rowID.uuidString)\",\"expected_row_version\":1,\"expected_draft_version\":1,\"expected_final_create_draft_version\":null}]}}".utf8))
  }
  func confirm(batchID: UUID, request: StatementImportConfirmationDTO, idempotencyKey: UUID) async throws -> StatementImportConfirmationReceipt { recorded.append("confirm"); #expect(batchID == self.batchID && request.rows.first?.rowID == rowID && idempotencyKey.uuidString.isEmpty == false); if failConfirm { throw FiscalAPIError.transport("lost") }; throw FiscalAPIError.invalidResponse }
  func receipt(batchID: UUID, idempotencyKey: UUID) async throws -> StatementImportConfirmationReceipt { recorded.append("receipt"); #expect(batchID == self.batchID && idempotencyKey.uuidString.isEmpty == false); return .init(operationID: UUID(), batchID: batchID, batchVersion: 4, status: "confirmed", confirmedRowIDs: [rowID], replay: true) }
  func confirm(_ request: StatementImportConfirmationDTO, idempotencyKey: UUID) async throws { _ = request; _ = idempotencyKey }
  func calls() -> [String] { recorded }
}

private final class ConfirmationFlag: @unchecked Sendable {
  private let lock = NSLock(); private var stored = false
  var value: Bool { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
}

private actor IntakeRepositoryFixture: StatementImportIntakeRepository {
  private let duplicate: Bool
  private let missingStartVersion: Bool
  private var failFirstEvidence: Bool
  private var calls: [String] = []
  private var packages: [StatementImportEvidencePackage] = []
  private let batchID = UUID()

  init(duplicate: Bool = false, missingStartVersion: Bool = false, failFirstEvidence: Bool = false) {
    self.duplicate = duplicate
    self.missingStartVersion = missingStartVersion
    self.failFirstEvidence = failFirstEvidence
  }

  func register(_: StatementImportRegistrationRequest) async throws -> StatementImportDTO {
    calls.append("register")
    return .init(id: batchID, status: duplicate ? "created" : "created", version: 1, duplicate: duplicate)
  }

  func startLocalExtraction(
    batchID: UUID, expectedVersion: Int
  ) async throws -> (attempt: StatementImportAttemptDTO, expectedVersion: Int) {
    calls.append("start")
    #expect(batchID == self.batchID)
    #expect(expectedVersion == 1)
    if missingStartVersion { throw StatementImportIntakeError.missingStartVersion }
    return (.init(id: UUID(), status: "started"), 2)
  }

  func submitEvidence(
    batchID: UUID, package: StatementImportEvidencePackage
  ) async throws -> StatementImportEvidenceUploadDTO {
    calls.append("evidence")
    #expect(batchID == self.batchID)
    packages.append(package)
    if failFirstEvidence { failFirstEvidence = false; throw FiscalAPIError.transport("response lost") }
    return .init(id: batchID, status: "review_required", version: 3)
  }

  func fail(batchID: UUID, expectedVersion: Int, code: String) async throws -> StatementImportDTO {
    calls.append("fail")
    #expect(batchID == self.batchID)
    #expect(expectedVersion > 0)
    #expect(["document_cancelled", "client_extraction_failed"].contains(code))
    return .init(id: batchID, status: "failed", version: expectedVersion + 1)
  }

  func batch(id: UUID) async throws -> StatementImportDTO {
    calls.append("get")
    return .init(id: id, status: "review_required", version: 3)
  }

  func callNames() -> [String] { calls }
  func evidencePackages() -> [StatementImportEvidencePackage] { packages }
}

private actor IntakeProcessorFixture: StatementImportLocalProcessing {
  private var extractions = 0

  func inspect(url: URL) async throws -> StatementImportLocalMetadata {
    .init(
      sourceFilename: url.lastPathComponent, byteSize: 120, pageCount: 1,
      documentSHA256: String(repeating: "a", count: 64))
  }

  func redactedPackage(
    url _: URL, attemptID: UUID, expectedVersion: Int
  ) async throws -> (StatementImportEvidencePackage, StatementImportEvidencePreview) {
    extractions += 1
    let evidence = StatementPDFDocumentEvidence(pageCount: 1, pages: [
      .init(
        pageNumber: 1, kind: .text,
        geometry: .init(widthPoints: 612, heightPoints: 792, rotationDegrees: 0),
        lines: [.init(
          pageNumber: 1, source: .textLayer,
          rawText: "Card Number: 1234567890123456", boundingBox: .init(x: 0, y: 0, width: 0.2, height: 0.1))]),
    ])
    return try StatementImportEvidencePackageBuilder().build(
      attemptID: attemptID, expectedVersion: expectedVersion, document: evidence)
  }

  func extractionCount() -> Int { extractions }
}

private actor InterruptibleIntakeProcessor: StatementImportLocalProcessing {
  private var began = false
  private var cancelled = false
  private var continuation: CheckedContinuation<Void, Never>?

  func inspect(url: URL) async throws -> StatementImportLocalMetadata {
    .init(sourceFilename: url.lastPathComponent, byteSize: 120, pageCount: 1,
          documentSHA256: String(repeating: "a", count: 64))
  }

  func redactedPackage(
    url _: URL, attemptID _: UUID, expectedVersion _: Int
  ) async throws -> (StatementImportEvidencePackage, StatementImportEvidencePreview) {
    try await withTaskCancellationHandler(operation: {
      await withCheckedContinuation { continuation in
        began = true
        self.continuation = continuation
      }
      try Task.checkCancellation()
      throw StatementImportIntakeError.inaccessibleFile
    }, onCancel: {
      Task { await self.cancelLocalWork() }
    })
  }

  func waitUntilExtractionBegins() async {
    while !began { await Task.yield() }
  }

  func waitUntilCancelled() async {
    while !cancelled { await Task.yield() }
  }

  private func cancelLocalWork() {
    cancelled = true
    continuation?.resume()
    continuation = nil
  }
}
