import Foundation
import Testing

@testable import FiscalKit

@Suite("FiscalKit P16 horizontal guards")
struct P16HorizontalTests {
  // MARK: M12 – a late cash-flow history page cannot overwrite the newly selected month

  @Test("Cash-flow history ignores a stale month response") @MainActor
  func cashFlowHistoryIgnoresStaleMonth() async throws {
    let anchor = try #require(isoDate("2026-07-15T12:00:00Z"))
    let model = FutureCashFlowModel(repository: RaceCashFlowRepository(), now: anchor)
    let stale = Task { await model.loadHistory() }  // month 2026-07 (slow)
    try await Task.sleep(for: .milliseconds(20))
    await model.moveHistoryMonth(-1)  // switches to 2026-06 and loads it (fast)
    await stale.value
    #expect(model.history?.month == "2026-06")
  }

  // MARK: L5 – a failed supplementary read must not report a successful save as a failure

  @Test("AI settings save survives a failing provider re-read") @MainActor
  func aiSettingsSaveSurvivesProviderReadFailure() async {
    let repository = FlakyAISettingsRepository()
    let model = AISettingsModel(repository: repository)
    await model.load()
    await repository.setFailProviderRead(true)
    let saved = await model.save()
    #expect(saved)
    #expect(model.settings?.version == 2)
    #expect(model.message == nil)
  }
}

private func isoDate(_ value: String) -> Date? {
  let formatter = ISO8601DateFormatter()
  return formatter.date(from: value)
}

private enum RaceError: Error { case unsupported }

private actor RaceCashFlowRepository: FutureCashFlowRepository {
  func active(accountID: UUID?) async throws -> FutureCashFlowActive { throw RaceError.unsupported }
  func history(month: String) async throws -> FutureCashFlowHistory {
    try? await Task.sleep(for: .milliseconds(month == "2026-07" ? 80 : 5))
    return FutureCashFlowHistory(month: month, items: [])
  }
  func create(_ draft: FutureCashFlowDraft, idempotencyKey: UUID) async throws
    -> FutureCashFlowCreateResponse
  { throw RaceError.unsupported }
  func update(id: UUID, request: FutureCashFlowReplace) async throws
    -> FutureCashFlowCreateResponse
  { throw RaceError.unsupported }
  func confirm(id: UUID, version: Int) async throws -> FutureCashFlowItem {
    throw RaceError.unsupported
  }
  func cancel(id: UUID, version: Int, scope: FutureCashFlowMutationScope) async throws
    -> FutureCashFlowCreateResponse
  { throw RaceError.unsupported }
  func settle(id: UUID, request: FutureCashFlowSettlement, idempotencyKey: UUID) async throws
    -> FutureCashFlowItem
  { throw RaceError.unsupported }
  func updateSystem(
    kind: FutureCashFlowSystemKind, referenceID: UUID, request: FutureCashFlowSystemReplace
  ) async throws -> FutureCashFlowItem { throw RaceError.unsupported }
}

private actor FlakyAISettingsRepository: AISettingsRepository {
  private var failProviderRead = false
  func setFailProviderRead(_ value: Bool) { failProviderRead = value }

  private func settings(version: Int) -> AISettingsDTO {
    AISettingsDTO(
      autoExecuteEnabled: false, ocrSourceEnabled: false, shortcutTextSourceEnabled: false,
      autoExecuteLimitMinor: 100_000, minimumConfidenceBps: 9_000, providerConfigured: true,
      effectiveAutoExecute: false, version: version, createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 0))
  }
  private func provider() -> AIProviderSettingsDTO {
    AIProviderSettingsDTO(
      provider: "openai_compatible", baseURL: "https://api.example.com/v1", model: "gpt",
      apiKeyConfigured: true, version: 1, updatedAt: Date(timeIntervalSince1970: 0))
  }

  func get() async throws -> AISettingsDTO { settings(version: 1) }
  func update(_ request: AISettingsUpdateRequest) async throws -> AISettingsDTO {
    settings(version: 2)
  }
  func getProvider() async throws -> AIProviderSettingsDTO {
    if failProviderRead { throw FiscalAPIError.transport("offline") }
    return provider()
  }
  func updateProvider(_ request: AIProviderSettingsUpdateRequest) async throws
    -> AIProviderSettingsDTO
  { provider() }
}
