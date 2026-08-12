import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

@testable import FiscalKit

@Suite("FiscalKit P25 local statement PDF evidence")
struct FiscalKitP25StatementPDFEvidenceTests {
  @Test("Synthetic text PDF keeps page order, source evidence, and money/date punctuation")
  func textEvidenceIsStable() async throws {
    let extractor = StatementPDFEvidenceExtractor(ocr: FixtureOCR(linesByPage: [:]))
    let first = "2026-08-01 Refund -1,234.50"
    let second = "2026-08-02 Coffee 28.00"
    let evidence = try await withSyntheticPDF(pages: [[first], [second]]) { url in
      try await extractor.extract(from: url)
    }

    #expect(evidence.pageCount == 2)
    #expect(evidence.pages.map(\.pageNumber) == [1, 2])
    #expect(evidence.pages.map(\.kind) == [.text, .text])
    #expect(evidence.pages[0].lines.map(\.source) == [.textLayer])
    #expect(evidence.pages[0].lines.first?.normalizedText == first)
    #expect(evidence.pages[1].lines.first?.normalizedText == second)
    #expect(evidence.pages[0].lines.first?.boundingBox.width ?? 0 > 0)
  }

  @Test("Synthetic scanned, mixed, and blank pages preserve page identity without duplicate OCR")
  func pageKindsAndRegionDeduplication() async throws {
    let duplicateRegion = StatementPDFBoundingBox(x: 0, y: 0, width: 1, height: 1)
    let scanLine = FixtureOCR.line(page: 1, text: "退款（-1,234.50）", box: duplicateRegion)
    let duplicateText = FixtureOCR.line(page: 2, text: "2026-08-03 Groceries 66.00", box: duplicateRegion)
    let imageOnlyText = FixtureOCR.line(
      page: 2, text: "扫码支付 8.00", box: .init(x: 0.12, y: 0.42, width: 0.3, height: 0.04))
    let extractor = StatementPDFEvidenceExtractor(
      ocr: FixtureOCR(linesByPage: [1: [scanLine], 2: [duplicateText, imageOnlyText]]))
    let evidence = try await withSyntheticPDF(
      pages: [[], ["2026-08-03 Groceries 66.00"], []]
    ) { url in
      try await extractor.extract(from: url)
    }

    #expect(evidence.pages.map(\.kind) == [.scannedImage, .mixed, .unsupported])
    #expect(evidence.pages[0].lines.map(\.source) == [.visionOCR])
    #expect(evidence.pages[0].lines.first?.rawText == "退款（-1,234.50）")
    #expect(evidence.pages[1].lines.filter { $0.normalizedText == "2026-08-03 Groceries 66.00" }.count == 1)
    #expect(evidence.pages[1].lines.map(\.source).contains(.visionOCR))
  }

  @Test("Redacted evidence package is previewable, Codable, and local-repository only")
  func redactedEvidencePackage() async throws {
    let evidence = StatementPDFDocumentEvidence(pageCount: 2, pages: [
      StatementPDFPageEvidence(
        pageNumber: 1, kind: .text,
        geometry: StatementPDFPageGeometry(widthPoints: 612, heightPoints: 792, rotationDegrees: 0),
        lines: [
          .init(
            pageNumber: 1, source: .textLayer,
            rawText: "2026-08-12 Synthetic Market 18.50", boundingBox: .init(x: 0.1, y: 0.1, width: 0.3, height: 0.1)),
          .init(
            pageNumber: 1, source: .textLayer,
            rawText: "Card Number: 1234567890123456", boundingBox: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.1)),
        ]),
      StatementPDFPageEvidence(
        pageNumber: 2, kind: .unsupported,
        geometry: StatementPDFPageGeometry(widthPoints: 612, heightPoints: 792, rotationDegrees: 0),
        lines: []),
    ])
    let built = try StatementImportEvidencePackageBuilder().build(
      attemptID: UUID(), expectedVersion: 2, document: evidence)

    #expect(built.preview.pageCount == 2)
    #expect(built.preview.rowCount == 2)
    #expect(built.preview.redactedFieldCount == 1)
    #expect(built.package.pages[1].evidenceTextMasked == nil)
    #expect(!built.package.rows.map { $0.evidenceTextMasked }.joined().contains("1234567890123456"))
    #expect(!built.package.rows.contains {
      StatementImportEvidenceRedactor.containsProhibitedSensitiveValue($0.evidenceTextMasked)
    })

    let encoded = try JSONEncoder().encode(built.package)
    let serialized = try #require(String(data: encoded, encoding: .utf8))
    #expect(!serialized.contains("1234567890123456"))
    #expect(!serialized.contains("pdf"))
    #expect(!serialized.contains("image"))

    let repository = RecordingStatementImportEvidenceRepository()
    try await repository.recordPrepared(built.package)
    #expect(await repository.preparedPackages() == [built.package])
  }

  @Test("Invalid, protected, and bounded PDF input produce stable local errors")
  func stableInputErrors() async throws {
    let extractor = StatementPDFEvidenceExtractor(ocr: FixtureOCR(linesByPage: [:]))
    let duplicateRegion = StatementPDFBoundingBox(x: 0, y: 0, width: 1, height: 1)
    try await StatementPDFTemporaryWorkspace.withDirectory { directory in
      let invalid = directory.appendingPathComponent("invalid.pdf")
      try Data("not a PDF".utf8).write(to: invalid)
      await #expect(throws: StatementPDFExtractionError.unreadablePDF) {
        try await extractor.extract(from: invalid)
      }

      let protected = directory.appendingPathComponent("protected.pdf")
      try syntheticPDF(pages: [["Locked statement"]], to: protected)
      let document = try #require(PDFDocument(url: protected))
      let encrypted = directory.appendingPathComponent("encrypted.pdf")
      #expect(document.write(
        to: encrypted,
        withOptions: [.userPasswordOption: "fixture-password", .ownerPasswordOption: "fixture-owner"]))
      await #expect(throws: StatementPDFExtractionError.passwordProtected) {
        try await extractor.extract(from: encrypted)
      }

      let pageLimited = StatementPDFEvidenceExtractor(
        limits: .init(maximumFileBytes: 1_000_000, maximumPages: 1, maximumRasterPixels: 1_000_000,
                      maximumOCRCharacters: 1_000),
        ocr: FixtureOCR(linesByPage: [:]))
      let twoPages = directory.appendingPathComponent("two-pages.pdf")
      try syntheticPDF(pages: [["first"], ["second"]], to: twoPages)
      await #expect(throws: StatementPDFExtractionError.pageLimitExceeded(limit: 1)) {
        try await pageLimited.extract(from: twoPages)
      }

      let fileLimited = StatementPDFEvidenceExtractor(
        limits: .init(maximumFileBytes: 1, maximumPages: 10, maximumRasterPixels: 1_000_000,
                      maximumOCRCharacters: 1_000),
        ocr: FixtureOCR(linesByPage: [:]))
      await #expect(throws: StatementPDFExtractionError.fileTooLarge(limit: 1)) {
        try await fileLimited.extract(from: twoPages)
      }

      let onePage = directory.appendingPathComponent("one-page.pdf")
      try syntheticPDF(pages: [["raster bound"]], to: onePage)
      let pixelLimited = StatementPDFEvidenceExtractor(
        limits: .init(maximumFileBytes: 1_000_000, maximumPages: 10, maximumRasterPixels: 1,
                      maximumOCRCharacters: 1_000),
        ocr: FixtureOCR(linesByPage: [:]))
      await #expect(throws: StatementPDFExtractionError.pagePixelLimitExceeded(limit: 1)) {
        try await pixelLimited.extract(from: onePage)
      }

      let characterLimited = StatementPDFEvidenceExtractor(
        limits: .init(maximumFileBytes: 1_000_000, maximumPages: 10, maximumRasterPixels: 2_000_000,
                      maximumOCRCharacters: 5),
        ocr: FixtureOCR(linesByPage: [1: [
          FixtureOCR.line(page: 1, text: "123456", box: duplicateRegion),
        ]]))
      await #expect(throws: StatementPDFExtractionError.ocrCharacterLimitExceeded(limit: 5)) {
        try await characterLimited.extract(from: onePage)
      }
    }
  }

  @Test("Synthetic rotated PDF retains its page geometry and evidence location")
  func rotatedPageEvidence() async throws {
    let extractor = StatementPDFEvidenceExtractor(ocr: FixtureOCR(linesByPage: [:]))
    let evidence = try await StatementPDFTemporaryWorkspace.withDirectory { directory in
      let source = directory.appendingPathComponent("source.pdf")
      try syntheticPDF(pages: [["2026-08-04 Rotated 20.00"]], to: source)
      let document = try #require(PDFDocument(url: source))
      document.page(at: 0)?.rotation = 90
      let rotated = directory.appendingPathComponent("rotated.pdf")
      #expect(document.write(to: rotated))
      return try await extractor.extract(from: rotated)
    }

    #expect(evidence.pages.first?.geometry.rotationDegrees == 90)
    #expect(evidence.pages.first?.lines.first?.boundingBox.width ?? 0 > 0)
  }

  @Test("Temporary workspace removes synthetic inputs after success, failure, and cancellation")
  func temporaryWorkspaceAlwaysCleansUp() async throws {
    let successPath = try await StatementPDFTemporaryWorkspace.withDirectory { directory in
      try Data("success".utf8).write(to: directory.appendingPathComponent("fixture.pdf"))
      return directory
    }
    #expect(!FileManager.default.fileExists(atPath: successPath.path))

    let failureProbe = TemporaryPathProbe()
    await #expect(throws: FixtureFailure.expected) {
      try await StatementPDFTemporaryWorkspace.withDirectory { directory in
        await failureProbe.record(directory)
        try Data("failure".utf8).write(to: directory.appendingPathComponent("fixture.pdf"))
        throw FixtureFailure.expected
      }
    }
    #expect(!FileManager.default.fileExists(atPath: await failureProbe.path().path))

    let cancellationProbe = TemporaryPathProbe()
    await #expect(throws: CancellationError.self) {
      try await StatementPDFTemporaryWorkspace.withDirectory { directory in
        await cancellationProbe.record(directory)
        try Data("cancelled".utf8).write(to: directory.appendingPathComponent("fixture.pdf"))
        throw CancellationError()
      }
    }
    #expect(!FileManager.default.fileExists(atPath: await cancellationProbe.path().path))
  }
}

private struct FixtureOCR: StatementPDFOCRRecognizing {
  let linesByPage: [Int: [StatementPDFLineEvidence]]

  func recognize(pageNumber: Int, image _: CGImage) async throws -> [StatementPDFLineEvidence] {
    linesByPage[pageNumber, default: []]
  }

  static func line(
    page: Int, text: String, box: StatementPDFBoundingBox
  ) -> StatementPDFLineEvidence {
    .init(pageNumber: page, source: .visionOCR, rawText: text, boundingBox: box)
  }
}

private enum FixtureFailure: Error, Sendable { case expected }

private actor TemporaryPathProbe {
  private var storedPath: URL?

  func record(_ path: URL) { storedPath = path }

  func path() -> URL { storedPath! }
}

private func withSyntheticPDF<Result: Sendable>(
  pages: [[String]], operation: @Sendable (URL) async throws -> Result
) async throws -> Result {
  try await StatementPDFTemporaryWorkspace.withDirectory { directory in
    let url = directory.appendingPathComponent("synthetic-statement.pdf")
    try syntheticPDF(pages: pages, to: url)
    return try await operation(url)
  }
}

private func syntheticPDF(pages: [[String]], to url: URL) throws {
  var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
  guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
    throw FixtureFailure.expected
  }
  let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
  for page in pages {
    context.beginPDFPage(nil)
    for (index, text) in page.enumerated() {
      let attributed = NSAttributedString(string: text, attributes: [.font: font])
      let line = CTLineCreateWithAttributedString(attributed)
      context.textPosition = CGPoint(x: 72, y: 720 - CGFloat(index * 28))
      CTLineDraw(line, context)
    }
    context.endPDFPage()
  }
  context.closePDF()
}
