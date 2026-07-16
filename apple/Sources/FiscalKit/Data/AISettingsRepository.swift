import Foundation

public protocol AISettingsRepository: Sendable {
  func get() async throws -> AISettingsDTO
  func update(_ request: AISettingsUpdateRequest) async throws -> AISettingsDTO
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
}
