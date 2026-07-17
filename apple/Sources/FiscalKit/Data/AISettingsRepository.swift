import Foundation

public protocol AISettingsRepository: Sendable {
  func get() async throws -> AISettingsDTO
  func update(_ request: AISettingsUpdateRequest) async throws -> AISettingsDTO
  func getProvider() async throws -> AIProviderSettingsDTO
  func updateProvider(_ request: AIProviderSettingsUpdateRequest) async throws -> AIProviderSettingsDTO
}

public actor RemoteAISettingsRepository: AISettingsRepository {
  private let transport: APITransport
  public init(transport: APITransport) { self.transport = transport }
  public func get() async throws -> AISettingsDTO {
    try await transport.request("ai/settings")
  }
  public func update(_ request: AISettingsUpdateRequest) async throws -> AISettingsDTO {
    try await transport.request("ai/settings", method: "PUT", body: request)
  }
  public func getProvider() async throws -> AIProviderSettingsDTO {
    try await transport.request("ai/provider-settings")
  }
  public func updateProvider(
    _ request: AIProviderSettingsUpdateRequest
  ) async throws -> AIProviderSettingsDTO {
    try await transport.request("ai/provider-settings", method: "PUT", body: request)
  }
}
