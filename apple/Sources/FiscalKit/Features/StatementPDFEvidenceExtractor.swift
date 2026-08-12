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

public enum StatementPDFPageKind: String, Sendable, Equatable {
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

  init(page: PDFPage) {
    let box = page.bounds(for: .mediaBox)
    widthPoints = Double(abs(box.width))
    heightPoints = Double(abs(box.height))
    rotationDegrees = ((page.rotation % 360) + 360) % 360
  }
}

public struct StatementPDFBoundingBox: Sendable, Equatable {
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
