import Foundation
import Observation

@MainActor
@Observable
public final class AISettingsModel {
  public private(set) var settings: AISettingsDTO?
  public private(set) var providerSettings: AIProviderSettingsDTO?
  public private(set) var phase: MasterDataPhase = .idle
  public private(set) var message: String?
  public private(set) var isSaving = false
  public private(set) var isSavingProvider = false
  public private(set) var conflictDetected = false
  public var autoExecuteEnabled = false
  public var ocrSourceEnabled = false
  public var shortcutTextSourceEnabled = false
  public var autoExecuteLimitMinor: Int64 = 100_000
  public var minimumConfidenceBps = 9_000
  public var providerBaseURL = ""
  public var providerModel = ""
  public var providerAPIKey = ""

  public static let limitOptions: [Int64] = [50_000, 100_000]
  public static let confidenceOptions = [9_000, 9_500, 10_000]
  private let repository: any AISettingsRepository
  private var generation = 0

  public init(repository: any AISettingsRepository) { self.repository = repository }

  public func load() async {
    generation += 1; let current = generation
    if settings == nil { phase = .loading }
    message = nil; conflictDetected = false
    do {
      async let settingsValue = repository.get()
      async let providerValue = repository.getProvider()
      let (value, provider) = try await (settingsValue, providerValue)
      guard current == generation else { return }
      apply(value); applyProvider(provider); phase = .loaded
    } catch is CancellationError { if current == generation, settings == nil { phase = .idle } }
    catch { guard current == generation else { return }; fail(error) }
  }

  public func save() async -> Bool {
    guard let settings, !isSaving else { return false }
    guard (1...100_000).contains(autoExecuteLimitMinor),
      (9_000...10_000).contains(minimumConfidenceBps)
    else { message = "自动记账规则不能低于服务端安全边界。"; return false }
    generation += 1; let current = generation; isSaving = true
    message = nil; conflictDetected = false; defer { isSaving = false }
    do {
      let value = try await repository.update(.init(
        autoExecuteEnabled: autoExecuteEnabled,
        ocrSourceEnabled: ocrSourceEnabled,
        shortcutTextSourceEnabled: shortcutTextSourceEnabled,
        autoExecuteLimitMinor: autoExecuteLimitMinor,
        minimumConfidenceBps: minimumConfidenceBps,
        expectedVersion: settings.version))
      guard current == generation else { return false }
      apply(value)
      applyProvider(try await repository.getProvider())
      phase = .loaded; return true
    } catch { guard current == generation else { return false }; fail(error); return false }
  }

  public func saveProvider() async -> Bool {
    guard let providerSettings, !isSavingProvider else { return false }
    let baseURL = providerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let model = providerModel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: baseURL), url.scheme == "https", url.host != nil else {
      message = "AI Provider 地址必须是完整的 HTTPS URL。"; return false
    }
    guard !model.isEmpty else { message = "请填写 AI 模型名称。"; return false }
    if !providerSettings.apiKeyConfigured && providerAPIKey.isEmpty {
      message = "首次配置必须填写 API Key。"; return false
    }
    isSavingProvider = true; message = nil; conflictDetected = false
    defer { isSavingProvider = false }
    do {
      let value = try await repository.updateProvider(.init(
        baseURL: baseURL,
        model: model,
        apiKey: providerAPIKey.isEmpty ? nil : providerAPIKey,
        expectedVersion: providerSettings.version
      ))
      providerAPIKey = ""
      applyProvider(value)
      apply(try await repository.get())
      phase = .loaded
      message = "AI Provider 已安全保存到服务器。"
      return true
    } catch { fail(error); return false }
  }

  private func apply(_ value: AISettingsDTO) {
    settings = value
    autoExecuteEnabled = value.autoExecuteEnabled
    ocrSourceEnabled = value.ocrSourceEnabled
    shortcutTextSourceEnabled = value.shortcutTextSourceEnabled
    autoExecuteLimitMinor = value.autoExecuteLimitMinor
    minimumConfidenceBps = value.minimumConfidenceBps
  }
  private func applyProvider(_ value: AIProviderSettingsDTO) {
    providerSettings = value
    providerBaseURL = value.baseURL ?? "https://api.openai.com/v1"
    providerModel = value.model ?? ""
    providerAPIKey = ""
  }
  private func fail(_ error: Error) {
    message = (error as? FiscalAPIError)?.displayMessage ?? "AI 设置暂时无法保存。"
    if let api = error as? FiscalAPIError, case .domain(_, let detail) = api,
      detail.code == "resource_version_conflict"
    { conflictDetected = true }
    phase = settings == nil ? .failed : .loaded
  }
}
