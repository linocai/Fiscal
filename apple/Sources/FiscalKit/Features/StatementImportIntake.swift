import CryptoKit
import Foundation
import Observation
import PDFKit

/// The metadata visible before consent. The source name is UI-only and never belongs to a remote
/// DTO, persisted cache, log event, or bookmark.
public struct StatementImportLocalMetadata: Sendable, Equatable {
  public let sourceFilename: String
  public let byteSize: Int
  public let pageCount: Int
  public let documentSHA256: String

  public init(sourceFilename: String, byteSize: Int, pageCount: Int, documentSHA256: String) {
    self.sourceFilename = sourceFilename
    self.byteSize = byteSize
    self.pageCount = pageCount
    self.documentSHA256 = documentSHA256
  }
}

public struct StatementImportDTO: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let status: String
  public let version: Int
  public let duplicate: Bool?

  public init(id: UUID, status: String, version: Int, duplicate: Bool? = nil) {
    self.id = id
    self.status = status
    self.version = version
    self.duplicate = duplicate
  }
}

public struct StatementImportRegistrationRequest: Codable, Sendable, Equatable {
  public let documentSHA256: String
  public let byteSize: Int
  public let pageCount: Int
  public let mimeType: String
  /// The server requires a display name. P28-A always sends this fixed safe value, never the
  /// selected file name or path.
  public let displayName: String

  public init(metadata: StatementImportLocalMetadata) {
    documentSHA256 = metadata.documentSHA256
    byteSize = metadata.byteSize
    pageCount = metadata.pageCount
    mimeType = "application/pdf"
    displayName = "statement.pdf"
  }

  enum CodingKeys: String, CodingKey {
    case documentSHA256 = "document_sha256"
    case byteSize = "byte_size"
    case pageCount = "page_count"
    case mimeType = "mime_type"
    case displayName = "display_name"
  }
}

public struct StatementImportAttemptDTO: Codable, Sendable, Equatable {
  public let id: UUID
  public let status: String
  public init(id: UUID, status: String) { self.id = id; self.status = status }
}

public struct StatementImportEvidenceUploadDTO: Codable, Sendable, Equatable {
  public let id: UUID
  public let status: String
  public let version: Int
  public init(id: UUID, status: String, version: Int) {
    self.id = id; self.status = status; self.version = version
  }
}

public enum StatementImportIntakeError: Error, LocalizedError, Sendable, Equatable {
  case unsupportedFile
  case inaccessibleFile
  case missingStartVersion
  case invalidStartVersion
  case noSelectedDocument
  case noRedactedPackage

  public var errorDescription: String? {
    switch self {
    case .unsupportedFile: "请选择可读取的 PDF 文件。"
    case .inaccessibleFile: "无法读取所选文件。"
    case .missingStartVersion: "服务端未返回提取版本；已停止，未上传证据。"
    case .invalidStartVersion: "服务端返回的提取版本无效；已停止，未上传证据。"
    case .noSelectedDocument: "请先选择账单 PDF。"
    case .noRedactedPackage: "没有可安全重试的脱敏证据。"
    }
  }
}

/// The only P28-A remote surface. Its parameter types make it impossible to pass a file URL,
/// bookmark, PDF bytes, page image, filename, or unredacted extraction result across the boundary.
public protocol StatementImportIntakeRepository: Sendable {
  func register(_ request: StatementImportRegistrationRequest) async throws -> StatementImportDTO
  func startLocalExtraction(batchID: UUID, expectedVersion: Int) async throws
    -> (attempt: StatementImportAttemptDTO, expectedVersion: Int)
  func submitEvidence(batchID: UUID, package: StatementImportEvidencePackage) async throws
    -> StatementImportEvidenceUploadDTO
  func fail(batchID: UUID, expectedVersion: Int, code: String) async throws -> StatementImportDTO
  func batch(id: UUID) async throws -> StatementImportDTO
}

public struct RemoteStatementImportIntakeRepository: StatementImportIntakeRepository {
  private let transport: APITransport
  public init(transport: APITransport) { self.transport = transport }

  public func register(_ request: StatementImportRegistrationRequest) async throws -> StatementImportDTO {
    try await transport.request("statement-imports", method: "POST", body: request)
  }

  public func startLocalExtraction(
    batchID: UUID, expectedVersion: Int
  ) async throws -> (attempt: StatementImportAttemptDTO, expectedVersion: Int) {
    struct StartRequest: Codable, Sendable { let expectedVersion: Int
      enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version" } }
    let result: APIResponseMetadata<StatementImportAttemptDTO> = try await transport
      .requestWithResponseMetadata(
        "statement-imports/\(batchID.uuidString)/attempts", method: "POST",
        body: StartRequest(expectedVersion: expectedVersion))
    guard let rawVersion = result.header("X-Fiscal-Statement-Import-Version") else {
      throw StatementImportIntakeError.missingStartVersion
    }
    guard let version = Int(rawVersion), version > 0 else {
      throw StatementImportIntakeError.invalidStartVersion
    }
    return (result.value, version)
  }

  public func submitEvidence(
    batchID: UUID, package: StatementImportEvidencePackage
  ) async throws -> StatementImportEvidenceUploadDTO {
    try await transport.request(
      "statement-imports/\(batchID.uuidString)/evidence", method: "POST", body: package)
  }

  public func fail(batchID: UUID, expectedVersion: Int, code: String) async throws -> StatementImportDTO {
    struct Failure: Codable, Sendable {
      let expectedVersion: Int
      let errorCode: String
      enum CodingKeys: String, CodingKey {
        case expectedVersion = "expected_version", errorCode = "error_code"
      }
    }
    return try await transport.request(
      "statement-imports/\(batchID.uuidString)/fail", method: "POST",
      body: Failure(expectedVersion: expectedVersion, errorCode: code))
  }

  public func batch(id: UUID) async throws -> StatementImportDTO {
    try await transport.request("statement-imports/\(id.uuidString)", cache: false)
  }
}

/// A local-only processor. Source access is security scoped only while copying to a randomized
/// temporary directory. The copied PDF and all rendered images remain inside the extractor call
/// and are removed by `StatementPDFTemporaryWorkspace` on every exit path.
public protocol StatementImportLocalProcessing: Sendable {
  func inspect(url: URL) async throws -> StatementImportLocalMetadata
  func redactedPackage(
    url: URL, attemptID: UUID, expectedVersion: Int
  ) async throws -> (StatementImportEvidencePackage, StatementImportEvidencePreview)
}

public struct SecurityScopedStatementImportProcessor: StatementImportLocalProcessing {
  private let extractor: StatementPDFEvidenceExtractor

  public init(extractor: StatementPDFEvidenceExtractor = .init()) { self.extractor = extractor }

  public func inspect(url: URL) async throws -> StatementImportLocalMetadata {
    try await Task.detached(priority: .userInitiated) {
      guard url.isFileURL else { throw StatementImportIntakeError.unsupportedFile }
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      let sourceValues = try url.resourceValues(forKeys: [.isRegularFileKey, .nameKey])
      guard sourceValues.isRegularFile == true else { throw StatementImportIntakeError.inaccessibleFile }
      let sourceFilename = sourceValues.name ?? "statement.pdf"
      return try await StatementPDFTemporaryWorkspace.withDirectory { directory in
        let copy = directory.appendingPathComponent("source.pdf")
        try FileManager.default.copyItem(at: url, to: copy)
        let copiedValues = try copy.resourceValues(forKeys: [.fileSizeKey])
        guard let byteSize = copiedValues.fileSize,
          let document = PDFDocument(url: copy), !document.isLocked, document.pageCount > 0
        else { throw StatementImportIntakeError.inaccessibleFile }
        return StatementImportLocalMetadata(
          sourceFilename: sourceFilename, byteSize: byteSize,
          pageCount: document.pageCount, documentSHA256: try Self.digest(url: copy))
      }
    }.value
  }

  public func redactedPackage(
    url: URL, attemptID: UUID, expectedVersion: Int
  ) async throws -> (StatementImportEvidencePackage, StatementImportEvidencePreview) {
    guard url.isFileURL else { throw StatementImportIntakeError.unsupportedFile }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    return try await StatementPDFTemporaryWorkspace.withDirectory { directory in
      let copy = directory.appendingPathComponent("source.pdf")
      try FileManager.default.copyItem(at: url, to: copy)
      let evidence = try await extractor.extract(from: copy)
      return try StatementImportEvidencePackageBuilder().build(
        attemptID: attemptID, expectedVersion: expectedVersion, document: evidence)
    }
  }

  private static func digest(url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while true {
      let data = try handle.read(upToCount: 1_048_576) ?? Data()
      if data.isEmpty { break }
      hash.update(data: data)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

@MainActor
@Observable
public final class StatementImportIntakeModel {
  public enum Phase: Sendable, Equatable {
    case idle, inspecting, awaitingConsent, registering, duplicate(StatementImportDTO), extracting
    case uploading, reviewRequired(StatementImportDTO), localFailure(String), remoteFailure(String)
    case remoteUnknown(UUID), duplicateRetryRequired(StatementImportDTO)
    case duplicateInProgress(StatementImportDTO), cancelled
  }

  public private(set) var phase: Phase = .idle
  public private(set) var metadata: StatementImportLocalMetadata?
  public private(set) var preview: StatementImportEvidencePreview?
  private var sourceURL: URL?
  private var package: StatementImportEvidencePackage?
  private var batch: StatementImportDTO?
  private var activeAttemptExpectedVersion: Int?
  private var failIssued = false
  /// Incremented only for lifecycle disposal.  A cancelled upload carrying an older generation
  /// must not turn a scene transition into a best-effort remote `fail` mutation.
  private var interruptionGeneration = 0
  @ObservationIgnored private var activeUpload: Task<Void, Never>?
  private let repository: any StatementImportIntakeRepository
  private let processor: any StatementImportLocalProcessing

  public init(
    repository: any StatementImportIntakeRepository,
    processor: any StatementImportLocalProcessing = SecurityScopedStatementImportProcessor()
  ) {
    self.repository = repository
    self.processor = processor
  }

  public func select(url: URL) async {
    discardForSceneInterruption()
    reset(keepPhase: false)
    phase = .inspecting
    do {
      metadata = try await processor.inspect(url: url)
      sourceURL = url
      phase = .awaitingConsent
    } catch is CancellationError {
      phase = .cancelled
    } catch {
      phase = .localFailure(Self.message(error))
    }
  }

  /// This is the sole consent gate. Selecting, inspecting, drag/drop, and duplicate detection
  /// cannot call the repository before this method is explicitly invoked by the user.
  public func consentAndUpload() async {
    await performConsentAndUpload(interruptionGeneration: nil)
  }

  private func performConsentAndUpload(interruptionGeneration: Int?) async {
    guard let metadata, let sourceURL else { phase = .localFailure("请选择账单 PDF。"); return }
    phase = .registering
    do {
      let registered = try await repository.register(.init(metadata: metadata))
      try Task.checkCancellation()
      batch = registered
      if registered.duplicate == true {
        showDuplicateRecovery(registered)
        return
      }
      try await extractAndUpload(batch: registered, sourceURL: sourceURL)
    } catch is CancellationError {
      guard interruptionGeneration == nil || interruptionGeneration == self.interruptionGeneration else {
        return
      }
      await cancelActiveAttempt()
    } catch {
      await handleFailure(error)
    }
  }

  private func extractAndUpload(batch registered: StatementImportDTO, sourceURL: URL) async throws {
    let started = try await repository.startLocalExtraction(
      batchID: registered.id, expectedVersion: registered.version)
    activeAttemptExpectedVersion = started.expectedVersion
    try Task.checkCancellation()
    phase = .extracting
    let built = try await processor.redactedPackage(
      url: sourceURL, attemptID: started.attempt.id, expectedVersion: started.expectedVersion)
    try Task.checkCancellation()
    package = built.0
    preview = built.1
    clearSource()
    phase = .uploading
    try Task.checkCancellation()
    let uploaded: StatementImportEvidenceUploadDTO
    do {
      uploaded = try await repository.submitEvidence(batchID: registered.id, package: built.0)
    } catch is CancellationError {
      activeAttemptExpectedVersion = nil
      phase = .remoteUnknown(registered.id)
      return
    } catch {
      activeAttemptExpectedVersion = nil
      phase = .remoteUnknown(registered.id)
      return
    }
    let reviewed = StatementImportDTO(id: uploaded.id, status: uploaded.status, version: uploaded.version)
    batch = reviewed
    activeAttemptExpectedVersion = nil
    phase = .reviewRequired(reviewed)
    package = nil
  }

  private func showDuplicateRecovery(_ existing: StatementImportDTO) {
    switch existing.status {
    case "review_required", "ready_to_confirm", "partially_confirmed":
      clearSource(); phase = .reviewRequired(existing)
    case "failed": phase = .duplicateRetryRequired(existing)
    case "extracting", "parsing":
      clearSource(); phase = .duplicateInProgress(existing)
    default:
      clearSource(); phase = .duplicate(existing)
    }
  }

  /// This explicit read only refreshes the existing batch; it never starts or resends work.
  public func recoverDuplicate() async {
    let existing: StatementImportDTO?
    switch phase {
    case .duplicate(let value), .duplicateRetryRequired(let value), .duplicateInProgress(let value):
      existing = value
    default: existing = nil
    }
    guard let existing else { return }
    do {
      let refreshed = try await repository.batch(id: existing.id)
      batch = refreshed
      showDuplicateRecovery(refreshed)
    } catch { phase = .remoteFailure("无法查询现有导入批次。") }
  }

  /// Opens a server-known batch from Attention or a deep link. This is a read-only recovery path:
  /// it never restarts extraction, resends evidence, invokes a provider, or confirms rows.
  public func openExistingBatch(id: UUID) async {
    do {
      let existing = try await repository.batch(id: id)
      batch = existing
      showDuplicateRecovery(existing)
    } catch {
      phase = .remoteFailure("无法查询现有导入批次。")
    }
  }

  /// Restarting a failed duplicate is an explicit foreground action; no background retry exists.
  public func retryFailedDuplicate() async {
    guard case .duplicateRetryRequired(let existing) = phase, let sourceURL else { return }
    batch = existing
    do { try await extractAndUpload(batch: existing, sourceURL: sourceURL) }
    catch is CancellationError { await cancelActiveAttempt() }
    catch { await handleFailure(error) }
  }

  /// Starts user-approved work without blocking the view. Cancellation is retained locally and
  /// results in at most one best-effort failed-attempt request.
  public func beginConsentAndUpload() {
    activeUpload?.cancel()
    let generation = interruptionGeneration
    activeUpload = Task { [weak self] in
      guard let self else { return }
      await self.performConsentAndUpload(interruptionGeneration: generation)
      self.activeUpload = nil
    }
  }

  /// Replays only the in-memory redacted package. It never accesses the selected source again.
  public func retryEvidence() async {
    guard case .remoteUnknown(let batchID) = phase, let package else {
      phase = .localFailure(StatementImportIntakeError.noRedactedPackage.localizedDescription)
      return
    }
    phase = .uploading
    do {
      let uploaded = try await repository.submitEvidence(batchID: batchID, package: package)
      let reviewed = StatementImportDTO(id: uploaded.id, status: uploaded.status, version: uploaded.version)
      batch = reviewed
      phase = .reviewRequired(reviewed)
      self.package = nil
    } catch is CancellationError {
      phase = .remoteUnknown(batchID)
    } catch {
      phase = .remoteUnknown(batchID)
    }
  }

  /// A response-loss recovery path performs one explicit read; it never resends evidence.
  public func queryRemoteStatus() async {
    guard case .remoteUnknown(let id) = phase else { return }
    do {
      let value = try await repository.batch(id: id)
      batch = value
      if value.status == "review_required" { phase = .reviewRequired(value); package = nil }
      else { phase = .remoteFailure("服务端当前状态：\(value.status)。请确认后再继续。") }
    } catch {
      phase = .remoteUnknown(id)
    }
  }

  public func cancel() async {
    // A transport-loss response is ambiguous: a /fail could race an accepted evidence package.
    // Keep the package and require an explicit status read or replay instead of changing remote state.
    if case .remoteUnknown = phase { return }
    activeUpload?.cancel()
    activeUpload = nil
    switch phase {
    case .registering, .extracting, .uploading:
      if batch != nil { await cancelActiveAttempt() }
      else { phase = .cancelled; reset(keepPhase: true) }
    default:
      phase = .cancelled
      reset(keepPhase: true)
    }
  }

  public func cleanup() { discardForSceneInterruption() }

  /// Scene/background interruption is not a user cancellation.  Do not perform a best-effort
  /// network mutation from lifecycle code: discard the in-memory source/package so a future
  /// foreground action must explicitly query or choose the document again.
  public func discardForSceneInterruption() {
    interruptionGeneration &+= 1
    activeUpload?.cancel()
    activeUpload = nil
    clearSource(); metadata = nil; preview = nil; package = nil; batch = nil; failIssued = false
    activeAttemptExpectedVersion = nil
    phase = .idle
  }

  private func cancelActiveAttempt() async {
    guard let batch, !failIssued else { phase = .cancelled; clearSource(); return }
    failIssued = true
    clearSource()
    let expectedVersion = activeAttemptExpectedVersion ?? batch.version
    activeAttemptExpectedVersion = nil
    do {
      _ = try await repository.fail(
        batchID: batch.id, expectedVersion: expectedVersion,
        code: "document_cancelled")
      phase = .cancelled
    } catch {
      phase = .remoteUnknown(batch.id)
    }
  }

  private func handleFailure(_ error: Error) async {
    guard let batch, !failIssued else { phase = .localFailure(Self.message(error)); clearSource(); return }
    failIssued = true
    clearSource()
    let expectedVersion = activeAttemptExpectedVersion ?? batch.version
    activeAttemptExpectedVersion = nil
    do {
      _ = try await repository.fail(
        batchID: batch.id, expectedVersion: expectedVersion,
        code: "client_extraction_failed")
      phase = .localFailure(Self.message(error))
    } catch {
      phase = .remoteUnknown(batch.id)
    }
  }

  private func reset(keepPhase: Bool) {
    activeUpload = nil
    clearSource(); metadata = nil; preview = nil; package = nil; batch = nil; failIssued = false
    activeAttemptExpectedVersion = nil
    if !keepPhase { phase = .idle }
  }

  private func clearSource() { sourceURL = nil }

  private static func message(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? "本地账单处理失败。"
  }
}
