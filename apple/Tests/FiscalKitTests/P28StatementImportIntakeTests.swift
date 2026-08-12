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

  private static func workbenchBody(
    batchID: UUID, rowID: UUID, batchVersion: Int, rowVersion: Int, draftVersion: Int,
    finalVersion: Int? = nil
  ) -> Data {
    Data("""
    {"batch_id":"\(batchID.uuidString)","batch_version":\(batchVersion),"review_available":true,"rows":[{"id":"\(rowID.uuidString)","row_number":1,"page_number":1,"row_version":\(rowVersion),"source_kind":"text","evidence_text_masked":"[REDACTED] market","draft":{"id":"\(UUID().uuidString)","resolution":"unresolved","version":\(draftVersion)},"candidates":[],"final_create_draft_version":\(finalVersion.map { String($0) } ?? "null")}],"next_cursor":null}
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
  init(batchID: UUID, rowID: UUID) { self.batchID = batchID; self.rowID = rowID }
  func workbench(batchID: UUID, cursor: Int, limit: Int, filters: [String: String]) async throws -> StatementImportWorkbench {
    recorded.append("workbench"); #expect(batchID == self.batchID); #expect(cursor == 0 && limit == 100 && filters.isEmpty)
    return try JSONDecoder().decode(StatementImportWorkbench.self, from: Data("{\"batch_id\":\"\(batchID.uuidString)\",\"batch_version\":3,\"review_available\":false,\"rows\":[{\"id\":\"\(rowID.uuidString)\",\"row_number\":1,\"page_number\":1,\"row_version\":1,\"source_kind\":\"text\",\"evidence_text_masked\":\"[REDACTED] market\",\"draft\":null,\"candidates\":[],\"final_create_draft_version\":null}],\"next_cursor\":null}".utf8))
  }
  func page(batchID: UUID, pageNumber: Int) async throws -> StatementImportWorkbenchPage {
    recorded.append("page"); #expect(batchID == self.batchID && pageNumber == 1)
    return try JSONDecoder().decode(StatementImportWorkbenchPage.self, from: Data("{\"page_number\":1,\"source_available\":true,\"source_kind\":\"text\",\"evidence_text_masked\":\"[REDACTED] market\"}".utf8))
  }
  func calls() -> [String] { recorded }
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
