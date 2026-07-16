import Foundation

public struct AISettingsDTO: Codable, Sendable, Equatable {
  public let autoExecuteEnabled: Bool
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
  public let autoExecuteLimitMinor: Int64
  public let minimumConfidenceBps: Int
  public let expectedVersion: Int
  enum CodingKeys: String, CodingKey {
    case autoExecuteEnabled = "auto_execute_enabled"
    case autoExecuteLimitMinor = "auto_execute_limit_minor"
    case minimumConfidenceBps = "minimum_confidence_bps"
    case expectedVersion = "expected_version"
  }
  public init(
    autoExecuteEnabled: Bool, autoExecuteLimitMinor: Int64,
    minimumConfidenceBps: Int, expectedVersion: Int
  ) {
    self.autoExecuteEnabled = autoExecuteEnabled
    self.autoExecuteLimitMinor = autoExecuteLimitMinor
    self.minimumConfidenceBps = minimumConfidenceBps
    self.expectedVersion = expectedVersion
  }
}
