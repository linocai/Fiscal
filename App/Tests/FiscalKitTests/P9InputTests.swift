import AppKit
import Foundation
import Testing

@testable import FiscalKit
@testable import FiscalPreviewSupportmacOS

@Suite("FiscalKit P9 OCR and Shortcuts input")
struct FiscalKitP9InputTests {
  @Test("Source payload distinguishes text, OCR, and shortcut text")
  func sourcePayload() throws {
    let encoder = JSONEncoder()
    let ocr = try #require(
      JSONSerialization.jsonObject(
        with: encoder.encode(V15AIProposalCreate(source: .ocr, text: "合计 28.00")))
        as? [String: Any])
    let shortcut = try #require(
      JSONSerialization.jsonObject(
        with: encoder.encode(V15AIProposalCreate(source: .shortcutText, text: "午餐 28 元")))
        as? [String: Any])
    #expect(ocr["source"] as? String == "ocr")
    #expect(shortcut["source"] as? String == "shortcut_text")
  }

  @Test("Vision OCR line normalization rejects blank output")
  func ocrNormalization() throws {
    let result = try VisionOCRService.result(lines: ["  美团   外卖 ", "", " 合计 28.00 "])
    #expect(result.text == "美团 外卖\n合计 28.00")
    #expect(result.lineCount == 2)
    #expect(throws: OCRInputError.noText) { try VisionOCRService.result(lines: [" ", "\n"]) }
  }

  @Test("Image bytes pass through Vision OCR, stable proposal retry, and one human-confirmed posting")
  @MainActor func imageOCRToConfirmedPosting() async throws {
    let imageData = try Self.syntheticScreenshot()
    let recognized = try await VisionOCRService().recognize(imageData: imageData)
    #expect(recognized.text.contains("28.00"))
    #expect(recognized.text.contains("合计"))

    let transport = F3FTransport(mode: .createUnknown)
    let model = V15AIProposalModel(services: V15Services(transport: transport))
    await model.load()
    model.source = .ocr
    model.inputText = recognized.text
    await model.create()
    #expect(model.hasUnknownCreate)
    #expect((await transport.mutationWires()).count == 1)
    await model.retryUnknownCreate()
    let createWires = await transport.mutationWires().filter { $0.path == "ai/proposals" }
    #expect(createWires.count == 2)
    #expect(createWires[0].headers["Idempotency-Key"] == createWires[1].headers["Idempotency-Key"])
    #expect(createWires[0].body == createWires[1].body)
    let createPayload = try #require(JSONSerialization.jsonObject(with: Data(createWires[0].body.utf8)) as? [String: Any])
    #expect(createPayload["source"] as? String == "ocr")
    #expect(createPayload["text"] as? String == recognized.text)

    let proposal = try #require(model.selectedProposal)
    await model.execute()
    #expect((await transport.mutationWires()).filter { $0.path.hasSuffix("/execute") }.isEmpty)
    model.openReview(proposal)
    model.title = "人工核对的截图消费"
    model.categoryID = V15F3FFixtures.expenseCategoryID
    await model.confirmDraft()
    #expect(model.reviewConfirmed)
    await model.execute()
    #expect(model.selectedProposal?.status == .executed)
    #expect(model.selectedProposal?.transactionID == V15F3FFixtures.transactionID)
    #expect((await transport.mutationWires()).filter { $0.path.hasSuffix("/execute") }.count == 1)
  }

  @MainActor private static func syntheticScreenshot() throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 320,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 1200, height: 320).fill()
    let font = NSFont(name: "PingFangSC-Semibold", size: 96) ?? .systemFont(ofSize: 96, weight: .semibold)
    ("合计 28.00" as NSString).draw(
      in: NSRect(x: 80, y: 85, width: 1040, height: 140),
      withAttributes: [.font: font, .foregroundColor: NSColor.black])
    context.flushGraphics()
    return try #require(bitmap.representation(using: .png, properties: [:]))
  }

  @Test("Ambiguous transport retry preserves one idempotency key")
  func ambiguousRetryKey() async throws {
    let repository = RecordingAIInputRepository(error: .transport("offline"))
    let store = MemoryRetryKeyStore()
    let service = AIInputSubmissionService(repository: repository, retryKeys: store)
    await #expect(throws: FiscalAPIError.self) {
      try await service.submit(source: .shortcutText, text: "午餐 28 元")
    }
    await #expect(throws: FiscalAPIError.self) {
      try await service.submit(source: .shortcutText, text: " 午餐   28 元 ")
    }
    let keys = await repository.keys
    #expect(keys.count == 2)
    #expect(keys[0] == keys[1])
  }

  @Test("Provider failure preserves the operation receipt because proposal already exists")
  func providerFailureKey() async throws {
    let detail = APIErrorDetail(
      code: "ai_provider_not_configured", message: "not configured", details: nil,
      requestID: "p9-test")
    let repository = RecordingAIInputRepository(error: .domain(status: 503, detail: detail))
    let service = AIInputSubmissionService(repository: repository, retryKeys: MemoryRetryKeyStore())
    for _ in 0..<2 {
      await #expect(throws: FiscalAPIError.self) {
        try await service.submit(source: .ocr, text: "合计 28.00")
      }
    }
    let keys = await repository.keys
    #expect(keys.count == 2)
    #expect(keys[0] == keys[1])
    #expect(
      AIInputFeedback.message(for: FiscalAPIError.domain(status: 503, detail: detail)).contains(
        "尚未配置"))
  }

  @Test("OCR refuses an overlong transcript instead of truncating money or merchant")
  func overlongOCR() {
    #expect(throws: OCRInputError.textTooLong) {
      try VisionOCRService.result(lines: [String(repeating: "账", count: 2_001)])
    }
  }
}

private actor MemoryRetryKeyStore: AIInputRetryKeyStoring {
  private var keys: [String: UUID] = [:]

  func key(for fingerprint: String) -> UUID {
    if let key = keys[fingerprint] { return key }
    let key = UUID()
    keys[fingerprint] = key
    return key
  }

  func clear(fingerprint: String) { keys[fingerprint] = nil }
}

private actor RecordingAIInputRepository: AIInputCreating {
  private(set) var keys: [UUID] = []
  private let error: FiscalAPIError

  init(error: FiscalAPIError) { self.error = error }

  func create(source: V15AIProposalSource, text: String, idempotencyKey: UUID) async throws
    -> V15AIProposal
  {
    keys.append(idempotencyKey)
    throw error
  }
}
