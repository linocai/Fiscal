import Foundation

public struct AISettingsDTO: Codable, Sendable, Equatable {
  public let autoExecuteEnabled: Bool
  public let ocrSourceEnabled: Bool
  public let shortcutTextSourceEnabled: Bool
  public let autoExecuteLimitMinor: Int64
  public let minimumConfidenceBps: Int
  public let providerConfigured: Bool
  public let effectiveAutoExecute: Bool
  public let version: Int
  public let createdAt: Date
  public let updatedAt: Date
  enum CodingKeys: String, CodingKey {
    case version
    case autoExecuteEnabled = "auto_execute_enabled"
    case ocrSourceEnabled = "ocr_source_enabled"
    case shortcutTextSourceEnabled = "shortcut_text_source_enabled"
    case autoExecuteLimitMinor = "auto_execute_limit_minor"
    case minimumConfidenceBps = "minimum_confidence_bps"
    case providerConfigured = "provider_configured"
    case effectiveAutoExecute = "effective_auto_execute"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }
}
public struct AISettingsUpdateRequest: Codable, Sendable, Equatable {
  public let autoExecuteEnabled: Bool
  public let ocrSourceEnabled: Bool
  public let shortcutTextSourceEnabled: Bool
  public let autoExecuteLimitMinor: Int64
  public let minimumConfidenceBps: Int
  public let expectedVersion: Int
  enum CodingKeys: String, CodingKey {
    case autoExecuteEnabled = "auto_execute_enabled"
    case ocrSourceEnabled = "ocr_source_enabled"
    case shortcutTextSourceEnabled = "shortcut_text_source_enabled"
    case autoExecuteLimitMinor = "auto_execute_limit_minor"
    case minimumConfidenceBps = "minimum_confidence_bps"
    case expectedVersion = "expected_version"
  }
  public init(
    autoExecuteEnabled: Bool, ocrSourceEnabled: Bool = false,
    shortcutTextSourceEnabled: Bool = false, autoExecuteLimitMinor: Int64,
    minimumConfidenceBps: Int, expectedVersion: Int
  ) {
    self.autoExecuteEnabled = autoExecuteEnabled
    self.ocrSourceEnabled = ocrSourceEnabled
    self.shortcutTextSourceEnabled = shortcutTextSourceEnabled
    self.autoExecuteLimitMinor = autoExecuteLimitMinor
    self.minimumConfidenceBps = minimumConfidenceBps
    self.expectedVersion = expectedVersion
  }
}

public struct AIProviderSettingsDTO: Codable, Sendable, Equatable {
  public let provider: String?
  public let baseURL: String?
  public let model: String?
  public let apiKeyConfigured: Bool
  public let version: Int
  public let updatedAt: Date
  enum CodingKeys: String, CodingKey {
    case provider, model, version
    case baseURL = "base_url"
    case apiKeyConfigured = "api_key_configured"
    case updatedAt = "updated_at"
  }
}

public struct AIProviderSettingsUpdateRequest: Codable, Sendable, Equatable {
  public let provider = "openai_compatible"
  public let baseURL: String
  public let model: String
  public let apiKey: String?
  public let expectedVersion: Int
  enum CodingKeys: String, CodingKey {
    case provider, model
    case baseURL = "base_url"
    case apiKey = "api_key"
    case expectedVersion = "expected_version"
  }
  public init(baseURL: String, model: String, apiKey: String?, expectedVersion: Int) {
    self.baseURL = baseURL
    self.model = model
    self.apiKey = apiKey
    self.expectedVersion = expectedVersion
  }
}
