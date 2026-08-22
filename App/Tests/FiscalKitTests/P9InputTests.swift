import Foundation
import Testing

@testable import FiscalKit

@Suite("FiscalKit P9 OCR and Shortcuts input")
struct FiscalKitP9InputTests {
  @Test("Source payload distinguishes text, OCR, and shortcut text")
  func sourcePayload() throws {
    let encoder = JSONEncoder()
    let ocr = try #require(
      JSONSerialization.jsonObject(
        with: encoder.encode(AIProposalCreateRequest(source: .ocr, text: "合计 28.00")))
        as? [String: Any])
    let shortcut = try #require(
      JSONSerialization.jsonObject(
        with: encoder.encode(AIProposalCreateRequest(source: .shortcutText, text: "午餐 28 元")))
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

  func create(source: AIProposalSource, text: String, idempotencyKey: UUID) async throws
    -> AIProposalDTO
  {
    keys.append(idempotencyKey)
    throw error
  }
}
