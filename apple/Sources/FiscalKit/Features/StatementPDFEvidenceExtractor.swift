import CoreGraphics
import Foundation
import PDFKit
import Vision

/// The local-only evidence boundary used before a statement can be previewed or sent anywhere.
/// It deliberately owns neither an import batch nor the source document: callers retain the URL
/// and this type only returns in-memory, page-scoped evidence.
public struct StatementPDFEvidenceExtractor: Sendable {
  public let limits: StatementPDFExtractionLimits
  private let ocr: any StatementPDFOCRRecognizing

  public init(
    limits: StatementPDFExtractionLimits = .default,
    ocr: any StatementPDFOCRRecognizing = VisionStatementPDFOCRRecognizer()
  ) {
    self.limits = limits
    self.ocr = ocr
  }

  public func extract(from fileURL: URL) async throws -> StatementPDFDocumentEvidence {
    do {
      try Task.checkCancellation()
      guard fileURL.isFileURL else { throw StatementPDFExtractionError.invalidFileURL }
      let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      guard values.isRegularFile == true else { throw StatementPDFExtractionError.unreadablePDF }
      guard let fileSize = values.fileSize else { throw StatementPDFExtractionError.unreadablePDF }
      guard fileSize <= limits.maximumFileBytes else {
        throw StatementPDFExtractionError.fileTooLarge(limit: limits.maximumFileBytes)
      }
      guard let document = PDFDocument(url: fileURL) else {
        throw StatementPDFExtractionError.unreadablePDF
      }
      guard !document.isLocked else {
        throw StatementPDFExtractionError.passwordProtected
      }
      guard document.pageCount > 0 else { throw StatementPDFExtractionError.emptyDocument }
      guard document.pageCount <= limits.maximumPages else {
        throw StatementPDFExtractionError.pageLimitExceeded(limit: limits.maximumPages)
      }

      var pages: [StatementPDFPageEvidence] = []
      var ocrCharacterCount = 0
      for pageIndex in 0..<document.pageCount {
        try Task.checkCancellation()
        guard let page = document.page(at: pageIndex) else {
          throw StatementPDFExtractionError.unreadablePDF
        }
        let pageNumber = pageIndex + 1
        let geometry = StatementPDFPageGeometry(page: page)
        let textLines = Self.textLines(from: page, pageNumber: pageNumber, geometry: geometry)
        let image = try StatementPDFPageRasterizer.image(
          from: page, geometry: geometry, maximumPixels: limits.maximumRasterPixels)
        let ocrLines = try await ocr.recognize(pageNumber: pageNumber, image: image)
        ocrCharacterCount += ocrLines.reduce(into: 0) { $0 += $1.rawText.count }
        guard ocrCharacterCount <= limits.maximumOCRCharacters else {
          throw StatementPDFExtractionError.ocrCharacterLimitExceeded(
            limit: limits.maximumOCRCharacters)
        }

        let uniqueOCRLines = ocrLines.filter { ocrLine in
          !textLines.contains { textLine in ocrLine.duplicates(textLine) }
        }
        let kind = StatementPDFPageKind(textLines: textLines, ocrLines: uniqueOCRLines)
        pages.append(
          StatementPDFPageEvidence(
            pageNumber: pageNumber, kind: kind, geometry: geometry,
            lines: Self.readingOrder(textLines + uniqueOCRLines)))
      }
      return StatementPDFDocumentEvidence(pageCount: document.pageCount, pages: pages)
    } catch is CancellationError {
      throw StatementPDFExtractionError.cancelled
    } catch let error as StatementPDFExtractionError {
      throw error
    } catch {
      throw StatementPDFExtractionError.unreadablePDF
    }
  }

  private static func textLines(
    from page: PDFPage, pageNumber: Int, geometry: StatementPDFPageGeometry
  ) -> [StatementPDFLineEvidence] {
    guard let pageText = page.string, !pageText.isEmpty,
      let selection = page.selection(for: NSRange(location: 0, length: (pageText as NSString).length))
    else { return [] }
    return selection.selectionsByLine().compactMap { selection in
      guard let rawText = selection.string, let normalizedText = StatementPDFLineEvidence.normalized(rawText)
      else { return nil }
      return StatementPDFLineEvidence(
        pageNumber: pageNumber, source: .textLayer, rawText: rawText,
        normalizedText: normalizedText,
        boundingBox: StatementPDFBoundingBox(pdfRect: selection.bounds(for: page), geometry: geometry))
    }
  }

  private static func readingOrder(
    _ lines: [StatementPDFLineEvidence]
  ) -> [StatementPDFLineEvidence] {
    lines.sorted {
      let rowTolerance = 0.02
      if abs($0.boundingBox.y - $1.boundingBox.y) > rowTolerance {
        return $0.boundingBox.y < $1.boundingBox.y
      }
      if $0.boundingBox.x != $1.boundingBox.x { return $0.boundingBox.x < $1.boundingBox.x }
      return $0.source.rawValue < $1.source.rawValue
    }
  }
}

public struct StatementPDFExtractionLimits: Sendable, Equatable {
  public var maximumFileBytes: Int
  public var maximumPages: Int
  public var maximumRasterPixels: Int
  public var maximumOCRCharacters: Int

  public init(
    maximumFileBytes: Int = 20 * 1_024 * 1_024,
    maximumPages: Int = 50,
    maximumRasterPixels: Int = 12_000_000,
    maximumOCRCharacters: Int = 100_000
  ) {
    self.maximumFileBytes = maximumFileBytes
    self.maximumPages = maximumPages
    self.maximumRasterPixels = maximumRasterPixels
    self.maximumOCRCharacters = maximumOCRCharacters
  }

  public static let `default` = StatementPDFExtractionLimits()
}

public struct StatementPDFDocumentEvidence: Sendable, Equatable {
  public let pageCount: Int
  public let pages: [StatementPDFPageEvidence]

  public init(pageCount: Int, pages: [StatementPDFPageEvidence]) {
    self.pageCount = pageCount
    self.pages = pages
  }
}

public struct StatementPDFPageEvidence: Sendable, Equatable {
  public let pageNumber: Int
  public let kind: StatementPDFPageKind
  public let geometry: StatementPDFPageGeometry
  public let lines: [StatementPDFLineEvidence]

  public init(
    pageNumber: Int, kind: StatementPDFPageKind, geometry: StatementPDFPageGeometry,
    lines: [StatementPDFLineEvidence]
  ) {
    self.pageNumber = pageNumber
    self.kind = kind
    self.geometry = geometry
    self.lines = lines
  }
}

public enum StatementPDFPageKind: String, Codable, Sendable, Equatable {
  case text
  case scannedImage = "scanned_image"
  case mixed
  case unsupported

  init(textLines: [StatementPDFLineEvidence], ocrLines: [StatementPDFLineEvidence]) {
    switch (!textLines.isEmpty, !ocrLines.isEmpty) {
    case (true, true): self = .mixed
    case (true, false): self = .text
    case (false, true): self = .scannedImage
    case (false, false): self = .unsupported
    }
  }
}

public struct StatementPDFPageGeometry: Sendable, Equatable {
  public let widthPoints: Double
  public let heightPoints: Double
  public let rotationDegrees: Int

  public init(widthPoints: Double, heightPoints: Double, rotationDegrees: Int) {
    self.widthPoints = widthPoints
    self.heightPoints = heightPoints
    self.rotationDegrees = rotationDegrees
  }

  init(page: PDFPage) {
    let box = page.bounds(for: .mediaBox)
    self.init(
      widthPoints: Double(abs(box.width)), heightPoints: Double(abs(box.height)),
      rotationDegrees: ((page.rotation % 360) + 360) % 360)
  }
}

public struct StatementPDFBoundingBox: Codable, Sendable, Equatable {
  /// Coordinates are normalized to the visible page with a top-left origin, which gives PDFKit
  /// and Vision evidence one stable coordinate system for later review UI.
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x; self.y = y; self.width = width; self.height = height
  }

  init(pdfRect: CGRect, geometry: StatementPDFPageGeometry) {
    let safeWidth = max(geometry.widthPoints, 1)
    let safeHeight = max(geometry.heightPoints, 1)
    x = Double(pdfRect.minX) / safeWidth
    y = 1 - Double(pdfRect.maxY) / safeHeight
    width = Double(pdfRect.width) / safeWidth
    height = Double(pdfRect.height) / safeHeight
  }

  init(visionRect: CGRect) {
    x = Double(visionRect.minX)
    y = 1 - Double(visionRect.maxY)
    width = Double(visionRect.width)
    height = Double(visionRect.height)
  }

  fileprivate func overlaps(_ other: Self) -> Bool {
    let left = max(x, other.x), right = min(x + width, other.x + other.width)
    let top = max(y, other.y), bottom = min(y + height, other.y + other.height)
    let intersection = max(0, right - left) * max(0, bottom - top)
    let smallerArea = min(width * height, other.width * other.height)
    return smallerArea > 0 && intersection / smallerArea >= 0.5
  }
}

public enum StatementPDFEvidenceSource: String, Sendable, Equatable {
  case textLayer = "text_layer"
  case visionOCR = "vision_ocr"
}

public struct StatementPDFLineEvidence: Sendable, Equatable {
  public let pageNumber: Int
  public let source: StatementPDFEvidenceSource
  /// The evidence is never normalized in place so amount/date punctuation remains auditable.
  public let rawText: String
  /// Normalization collapses whitespace only; it does not rewrite digits, signs, dates or decimals.
  public let normalizedText: String
  public let boundingBox: StatementPDFBoundingBox

  public init(
    pageNumber: Int, source: StatementPDFEvidenceSource, rawText: String,
    normalizedText: String? = nil, boundingBox: StatementPDFBoundingBox
  ) {
    self.pageNumber = pageNumber
    self.source = source
    self.rawText = rawText
    self.normalizedText = normalizedText ?? Self.normalized(rawText) ?? rawText
    self.boundingBox = boundingBox
  }

  static func normalized(_ rawText: String) -> String? {
    let value = rawText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return value.isEmpty ? nil : value
  }

  fileprivate func duplicates(_ other: Self) -> Bool {
    normalizedText == other.normalizedText && boundingBox.overlaps(other.boundingBox)
  }
}

public protocol StatementPDFOCRRecognizing: Sendable {
  func recognize(pageNumber: Int, image: CGImage) async throws -> [StatementPDFLineEvidence]
}

public struct VisionStatementPDFOCRRecognizer: StatementPDFOCRRecognizing {
  public init() {}

  public func recognize(pageNumber: Int, image: CGImage) async throws -> [StatementPDFLineEvidence] {
    try Task.checkCancellation()
    var request = RecognizeTextRequest(.revision3)
    request.recognitionLevel = .accurate
    request.automaticallyDetectsLanguage = true
    request.recognitionLanguages = [
      Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en-US"),
    ]
    request.usesLanguageCorrection = false
    do {
      let observations = try await request.perform(on: image)
      return observations.compactMap { observation -> StatementPDFLineEvidence? in
        guard let candidate = observation.topCandidates(1).first,
          let normalizedText = StatementPDFLineEvidence.normalized(candidate.string)
        else { return nil }
        return StatementPDFLineEvidence(
          pageNumber: pageNumber, source: .visionOCR, rawText: candidate.string,
          normalizedText: normalizedText,
          boundingBox: StatementPDFBoundingBox(visionRect: observation.boundingBox.cgRect))
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw StatementPDFExtractionError.ocrFailed
    }
  }
}

public enum StatementPDFExtractionError: Error, LocalizedError, Sendable, Equatable {
  case invalidFileURL
  case unreadablePDF
  case passwordProtected
  case emptyDocument
  case fileTooLarge(limit: Int)
  case pageLimitExceeded(limit: Int)
  case pagePixelLimitExceeded(limit: Int)
  case ocrCharacterLimitExceeded(limit: Int)
  case ocrFailed
  case cancelled

  public var code: String {
    switch self {
    case .invalidFileURL: "statement_pdf_invalid_file_url"
    case .unreadablePDF: "statement_pdf_unreadable"
    case .passwordProtected: "statement_pdf_password_protected"
    case .emptyDocument: "statement_pdf_empty_document"
    case .fileTooLarge: "statement_pdf_file_too_large"
    case .pageLimitExceeded: "statement_pdf_page_limit_exceeded"
    case .pagePixelLimitExceeded: "statement_pdf_page_pixel_limit_exceeded"
    case .ocrCharacterLimitExceeded: "statement_pdf_ocr_character_limit_exceeded"
    case .ocrFailed: "statement_pdf_ocr_failed"
    case .cancelled: "statement_pdf_cancelled"
    }
  }

  public var errorDescription: String? { code }
}

/// A narrow temporary workspace for future import preview code. It is not used to persist source
/// PDFs or rendered pages; its `defer` cleanup covers success, failure and cancellation paths.
public enum StatementPDFTemporaryWorkspace {
  public static func withDirectory<Result: Sendable>(
    operation: @Sendable (URL) async throws -> Result
  ) async throws -> Result {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "fiscal-statement-pdf-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await operation(directory)
  }
}

/// The only cross-boundary form derived from a local statement. It deliberately carries no PDF
/// URL, bytes, rendered image, source text, account metadata, or provider instruction.
public struct StatementImportEvidencePackage: Codable, Sendable, Equatable {
  public let attemptID: UUID
  public let expectedVersion: Int
  public let pages: [StatementImportEvidencePageDTO]
  public let rows: [StatementImportEvidenceRowDTO]

  public init(
    attemptID: UUID, expectedVersion: Int, pages: [StatementImportEvidencePageDTO],
    rows: [StatementImportEvidenceRowDTO]
  ) {
    self.attemptID = attemptID
    self.expectedVersion = expectedVersion
    self.pages = pages
    self.rows = rows
  }

  enum CodingKeys: String, CodingKey {
    case attemptID = "attempt_id"
    case expectedVersion = "expected_version"
    case pages, rows
  }
}

public struct StatementImportEvidencePageDTO: Codable, Sendable, Equatable, Identifiable {
  public var id: Int { pageNumber }
  public let pageNumber: Int
  public let sourceKind: StatementPDFPageKind
  public let evidenceTextMasked: String?
  public let boundingBoxes: [StatementPDFBoundingBox]

  public init(
    pageNumber: Int, sourceKind: StatementPDFPageKind, evidenceTextMasked: String?,
    boundingBoxes: [StatementPDFBoundingBox]
  ) {
    self.pageNumber = pageNumber
    self.sourceKind = sourceKind
    self.evidenceTextMasked = evidenceTextMasked
    self.boundingBoxes = boundingBoxes
  }

  enum CodingKeys: String, CodingKey {
    case pageNumber = "page_number"
    case sourceKind = "source_kind"
    case evidenceTextMasked = "evidence_text_masked"
    case boundingBoxes = "bounding_boxes"
  }
}

public struct StatementImportEvidenceRowDTO: Codable, Sendable, Equatable, Identifiable {
  public var id: Int { rowNumber }
  public let rowNumber: Int
  public let pageNumber: Int
  public let evidenceTextMasked: String
  public let boundingBox: StatementPDFBoundingBox

  public init(
    rowNumber: Int, pageNumber: Int, evidenceTextMasked: String,
    boundingBox: StatementPDFBoundingBox
  ) {
    self.rowNumber = rowNumber
    self.pageNumber = pageNumber
    self.evidenceTextMasked = evidenceTextMasked
    self.boundingBox = boundingBox
  }

  enum CodingKeys: String, CodingKey {
    case rowNumber = "row_number"
    case pageNumber = "page_number"
    case evidenceTextMasked = "evidence_text_masked"
    case boundingBox = "bounding_box"
  }
}

/// A display-ready, redacted-only local preview. UI work can render this later without ever
/// keeping the original document alive.
public struct StatementImportEvidencePreview: Sendable, Equatable {
  public let pages: [StatementImportEvidencePageDTO]
  public let rows: [StatementImportEvidenceRowDTO]
  public let redactedFieldCount: Int

  public init(
    pages: [StatementImportEvidencePageDTO], rows: [StatementImportEvidenceRowDTO],
    redactedFieldCount: Int
  ) {
    self.pages = pages
    self.rows = rows
    self.redactedFieldCount = redactedFieldCount
  }

  public var pageCount: Int { pages.count }
  public var rowCount: Int { rows.count }
}

public enum StatementImportEvidencePackageError: Error, Sendable, Equatable {
  case invalidAttemptVersion
  case invalidPageSequence
}

/// Deterministic local redaction shared by page and row evidence. A later network adapter must
/// send only the result of this type, never `StatementPDFDocumentEvidence` or a file URL.
public struct StatementImportEvidencePackageBuilder: Sendable {
  public init() {}

  public func build(
    attemptID: UUID, expectedVersion: Int, document: StatementPDFDocumentEvidence
  ) throws -> (package: StatementImportEvidencePackage, preview: StatementImportEvidencePreview) {
    guard expectedVersion > 0 else { throw StatementImportEvidencePackageError.invalidAttemptVersion }
    guard document.pageCount > 0 else { throw StatementImportEvidencePackageError.invalidPageSequence }
    let expectedPages = Array(1...document.pageCount)
    guard document.pages.map(\.pageNumber) == expectedPages else {
      throw StatementImportEvidencePackageError.invalidPageSequence
    }
    var redactedFieldCount = 0
    var rows: [StatementImportEvidenceRowDTO] = []
    let pages = document.pages.map { page -> StatementImportEvidencePageDTO in
      let redactedLines = page.lines.map { line -> String in
        let result = StatementImportEvidenceRedactor.redact(line.rawText)
        redactedFieldCount += result.fieldCount
        rows.append(
          StatementImportEvidenceRowDTO(
            rowNumber: rows.count + 1, pageNumber: page.pageNumber,
            evidenceTextMasked: result.text, boundingBox: line.boundingBox))
        return result.text
      }
      return StatementImportEvidencePageDTO(
        pageNumber: page.pageNumber, sourceKind: page.kind,
        evidenceTextMasked: redactedLines.isEmpty ? nil : redactedLines.joined(separator: "\n"),
        boundingBoxes: page.lines.map(\.boundingBox))
    }
    let package = StatementImportEvidencePackage(
      attemptID: attemptID, expectedVersion: expectedVersion, pages: pages, rows: rows)
    return (package, StatementImportEvidencePreview(
      pages: pages, rows: rows, redactedFieldCount: redactedFieldCount))
  }
}

public enum StatementImportEvidenceRedactor {
  private static let labelledSensitiveField = try! NSRegularExpression(
    pattern: "(?i)(?:\\b(?:card(?:\\s*(?:number|no\\.?))?|account(?:\\s*(?:number|no\\.?))?|customer(?:\\s*(?:number|no\\.?))?|name|address)\\b|卡号|账号|客户号|姓名|地址|持卡人)\\s*(?:[:：#]|\\s)\\s*[^\\n]+")
  private static let accountOrCardNumber = try! NSRegularExpression(
    pattern: "(?<!\\d)(?:\\d[ -]?){9,18}\\d(?!\\d)")

  public static func redact(_ source: String) -> (text: String, fieldCount: Int) {
    let labelled = replace(labelledSensitiveField, in: source, with: "[REDACTED]")
    let numbered = replace(accountOrCardNumber, in: labelled.text, with: "[REDACTED]")
    return (numbered.text, labelled.count + numbered.count)
  }

  public static func containsProhibitedSensitiveValue(_ text: String) -> Bool {
    let range = NSRange(text.startIndex..., in: text)
    return labelledSensitiveField.firstMatch(in: text, range: range) != nil
      || accountOrCardNumber.firstMatch(in: text, range: range) != nil
  }

  private static func replace(
    _ expression: NSRegularExpression, in text: String, with replacement: String
  ) -> (text: String, count: Int) {
    let range = NSRange(text.startIndex..., in: text)
    let count = expression.numberOfMatches(in: text, range: range)
    return (expression.stringByReplacingMatches(in: text, range: range, withTemplate: replacement), count)
  }
}

/// A local test seam only. It retains a redacted package in memory and performs no I/O, transport,
/// Provider call, or source-document persistence.
public protocol StatementImportEvidenceRepository: Sendable {
  func recordPrepared(_ package: StatementImportEvidencePackage) async throws
}

public actor RecordingStatementImportEvidenceRepository: StatementImportEvidenceRepository {
  private var packages: [StatementImportEvidencePackage] = []

  public init() {}

  public func recordPrepared(_ package: StatementImportEvidencePackage) async throws {
    guard package.pages.map(\.pageNumber) == Array(1...package.pages.count) else {
      throw StatementImportEvidencePackageError.invalidPageSequence
    }
    packages.append(package)
  }

  public func preparedPackages() -> [StatementImportEvidencePackage] { packages }
}

/// P26's confirmation-only client contract. It is derived from the already-redacted preview and
/// contains no evidence text at all; a future transport may send it only after user confirmation.
public struct StatementImportProviderAuthorizationRequest: Codable, Sendable, Equatable {
  public let expectedVersion: Int
  public let evidenceSHA256: String
  public let authorization: Authorization

  public init(
    expectedVersion: Int, evidenceSHA256: String, preview: StatementImportEvidencePreview
  ) {
    self.expectedVersion = expectedVersion
    self.evidenceSHA256 = evidenceSHA256
    authorization = Authorization(
      confirmed: true, provider: "synthetic_statement", providerModel: "synthetic-statement-v1",
      promptVersion: "statement-p26-v1", schemaVersion: "statement-provider-v1",
      evidenceSHA256: evidenceSHA256, pageNumbers: preview.pages.map(\.pageNumber),
      rowCount: preview.rowCount, redactionVersion: "statement-redaction-v1",
      redactionCount: preview.pages.reduce(0) { partial, page in
        partial + (page.evidenceTextMasked?.components(separatedBy: "[REDACTED]").count ?? 1) - 1
      })
  }

  enum CodingKeys: String, CodingKey {
    case expectedVersion = "expected_version"
    case evidenceSHA256 = "evidence_sha256"
    case authorization
  }

  public struct Authorization: Codable, Sendable, Equatable {
    public let confirmed: Bool
    public let provider: String
    public let providerModel: String
    public let promptVersion: String
    public let schemaVersion: String
    public let evidenceSHA256: String
    public let pageNumbers: [Int]
    public let rowCount: Int
    public let redactionVersion: String
    public let redactionCount: Int
    enum CodingKeys: String, CodingKey {
      case confirmed, provider
      case providerModel = "provider_model"
      case promptVersion = "prompt_version"
      case schemaVersion = "schema_version"
      case evidenceSHA256 = "evidence_sha256"
      case pageNumbers = "page_numbers"
      case rowCount = "row_count"
      case redactionVersion = "redaction_version"
      case redactionCount = "redaction_count"
    }
  }
}

/// No remote implementation belongs to P26-A. This seam lets UI confirmation be tested without
/// making a provider/network call or giving a repository the original package/evidence text.
public protocol StatementImportProviderAttemptRepository: Sendable {
  func confirm(_ request: StatementImportProviderAuthorizationRequest, idempotencyKey: UUID) async throws
}

public actor RecordingStatementImportProviderAttemptRepository: StatementImportProviderAttemptRepository {
  private var confirmations: [(StatementImportProviderAuthorizationRequest, UUID)] = []
  public init() {}
  public func confirm(
    _ request: StatementImportProviderAuthorizationRequest, idempotencyKey: UUID
  ) async throws { confirmations.append((request, idempotencyKey)) }
  public func recordedConfirmations() -> [(StatementImportProviderAuthorizationRequest, UUID)] {
    confirmations
  }
}

/// P27-A read-only review DTO. It deliberately has no confirm operation, provider body, or ledger
/// transport; the app can render deterministic checks and versioned local draft intent only.
public struct StatementImportReviewDTO: Codable, Sendable, Equatable {
  public let batchID: UUID
  public let batchVersion: Int
  public let status: String
  public let validationRunID: UUID
  public let checks: [Check]
  public let candidates: [Candidate]
  public let drafts: [Draft]
  enum CodingKeys: String, CodingKey {
    case batchID = "batch_id", batchVersion = "batch_version", status
    case validationRunID = "validation_run_id", checks, candidates, drafts
  }

  public struct Check: Codable, Sendable, Equatable {
    public let checkKind: String
    public let status: String
    public let evidenceRowIDs: [UUID]
    enum CodingKeys: String, CodingKey {
      case checkKind = "check_kind", status, evidenceRowIDs = "evidence_row_ids"
    }
  }
  public struct Candidate: Codable, Sendable, Equatable {
    public let id: UUID
    public let statementImportRowID: UUID
    public let candidateKind: String
    public let transactionID: UUID?
    enum CodingKeys: String, CodingKey {
      case id, statementImportRowID = "statement_import_row_id"
      case candidateKind = "candidate_kind", transactionID = "transaction_id"
    }
  }
  public struct Draft: Codable, Sendable, Equatable {
    public let id: UUID
    public let statementImportRowID: UUID
    public let resolution: String
    public let version: Int
    enum CodingKeys: String, CodingKey {
      case id, statementImportRowID = "statement_import_row_id", resolution, version
    }
  }
}

public protocol StatementImportReviewRepository: Sendable {
  func review() async throws -> StatementImportReviewDTO
}

public actor RecordingStatementImportReviewRepository: StatementImportReviewRepository {
  private let value: StatementImportReviewDTO
  public init(_ value: StatementImportReviewDTO) { self.value = value }
  public func review() async throws -> StatementImportReviewDTO { value }
}

/// P27-B's typed, idempotent confirmation contract. This is a DTO seam only;
/// it performs no ledger transport or automatic confirmation.
public struct StatementImportConfirmationDTO: Codable, Sendable, Equatable {
  public struct Row: Codable, Sendable, Equatable {
    public let rowID: UUID
    public let expectedRowVersion: Int
    public let expectedDraftVersion: Int
    public let expectedFinalCreateDraftVersion: Int?
    enum CodingKeys: String, CodingKey {
      case rowID = "row_id", expectedRowVersion = "expected_row_version"
      case expectedDraftVersion = "expected_draft_version"
      case expectedFinalCreateDraftVersion = "expected_final_create_draft_version"
    }
  }
  public let expectedBatchVersion: Int
  public let rows: [Row]
  enum CodingKeys: String, CodingKey { case expectedBatchVersion = "expected_batch_version", rows }
}

public struct StatementImportConfirmationPreview: Codable, Sendable, Equatable {
  public struct Counts: Codable, Sendable, Equatable {
    public let selected: Int; public let createNew: Int; public let matchExisting: Int; public let ignoreNonTransaction: Int; public let ignoreIntentional: Int; public let unresolved: Int; public let batchUnresolved: Int
    enum CodingKeys: String, CodingKey { case selected, unresolved; case createNew = "create_new", matchExisting = "match_existing", ignoreNonTransaction = "ignore_non_transaction", ignoreIntentional = "ignore_intentional", batchUnresolved = "batch_unresolved" }
  }
  public struct Amounts: Codable, Sendable, Equatable {
    public let knownCreateMinor: Int; public let knownMatchMinor: Int; public let knownTotalMinor: Int; public let unknownSelectedCount: Int
    enum CodingKeys: String, CodingKey { case knownCreateMinor = "known_create_minor", knownMatchMinor = "known_match_minor", knownTotalMinor = "known_total_minor", unknownSelectedCount = "unknown_selected_count" }
  }
  public struct Check: Codable, Sendable, Equatable { public let checkKind: String; public let status: String; enum CodingKeys: String, CodingKey { case checkKind = "check_kind", status } }
  public let batchID: UUID; public let batchVersion: Int; public let status: String; public let counts: Counts; public let amounts: Amounts; public let checks: [Check]; public let warnings: [String]; public let request: StatementImportConfirmationDTO
  enum CodingKeys: String, CodingKey { case status, counts, amounts, checks, warnings, request; case batchID = "batch_id", batchVersion = "batch_version" }
}

public struct StatementImportConfirmationReceipt: Codable, Sendable, Equatable {
  public let operationID: UUID; public let batchID: UUID; public let batchVersion: Int; public let status: String; public let confirmedRowIDs: [UUID]; public let replay: Bool
  enum CodingKeys: String, CodingKey { case status, replay; case operationID = "operation_id", batchID = "batch_id", batchVersion = "batch_version", confirmedRowIDs = "confirmed_row_ids" }
}

public protocol StatementImportConfirmationRepository: Sendable {
  func preview(batchID: UUID, rowIDs: [UUID]) async throws -> StatementImportConfirmationPreview
  func receipt(batchID: UUID, idempotencyKey: UUID) async throws -> StatementImportConfirmationReceipt
  func confirm(batchID: UUID, request: StatementImportConfirmationDTO, idempotencyKey: UUID) async throws -> StatementImportConfirmationReceipt
  func confirm(_ request: StatementImportConfirmationDTO, idempotencyKey: UUID) async throws
}

public extension StatementImportConfirmationRepository {
  func preview(batchID: UUID, rowIDs: [UUID]) async throws -> StatementImportConfirmationPreview { throw FiscalAPIError.invalidResponse }
  func receipt(batchID: UUID, idempotencyKey: UUID) async throws -> StatementImportConfirmationReceipt { throw FiscalAPIError.invalidResponse }
  func confirm(batchID: UUID, request: StatementImportConfirmationDTO, idempotencyKey: UUID) async throws -> StatementImportConfirmationReceipt { throw FiscalAPIError.invalidResponse }
}

public actor RecordingStatementImportConfirmationRepository: StatementImportConfirmationRepository {
  private var attempts: [(StatementImportConfirmationDTO, UUID)] = []
  public init() {}
  public func confirm(_ request: StatementImportConfirmationDTO, idempotencyKey: UUID) async throws {
    attempts.append((request, idempotencyKey))
  }
  public func recordedAttempts() -> [(StatementImportConfirmationDTO, UUID)] { attempts }
}

private enum StatementPDFPageRasterizer {
  static func image(
    from page: PDFPage, geometry: StatementPDFPageGeometry, maximumPixels: Int
  ) throws -> CGImage {
    let scale = 2.0
    let width = max(1, Int((geometry.widthPoints * scale).rounded(.up)))
    let height = max(1, Int((geometry.heightPoints * scale).rounded(.up)))
    guard width <= Int.max / height, width * height <= maximumPixels else {
      throw StatementPDFExtractionError.pagePixelLimitExceeded(limit: maximumPixels)
    }
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw StatementPDFExtractionError.unreadablePDF }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.saveGState()
    context.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: context)
    context.restoreGState()
    guard let image = context.makeImage() else { throw StatementPDFExtractionError.unreadablePDF }
    return image
  }
}
