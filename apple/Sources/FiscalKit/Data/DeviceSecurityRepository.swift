import Foundation

public protocol DeviceSecurityRepository: Sendable {
    func securityStatus(authorizationToken: String?) async throws -> SecurityStatusDTO
    func operationsStatus() async throws -> OperationsStatusDTO
    func list() async throws -> [DeviceTokenSummary]
    func issue(label: String) async throws -> IssuedDeviceToken
    func prepareRotation(expectedVersion: Int) async throws -> IssuedDeviceToken
    func activate(token: String, expectedVersion: Int) async throws -> ActivatedDeviceToken
    func revoke(id: UUID, expectedVersion: Int) async throws -> DeviceTokenSummary
}

public struct RemoteDeviceSecurityRepository: DeviceSecurityRepository {
    private let transport: APITransport
    public init(transport: APITransport) { self.transport = transport }

    public func securityStatus(authorizationToken: String? = nil) async throws -> SecurityStatusDTO {
        try await transport.request(
            "system/security-status", authorizationToken: authorizationToken)
    }

    public func operationsStatus() async throws -> OperationsStatusDTO {
        try await transport.request("system/operations-status")
    }

    public func list() async throws -> [DeviceTokenSummary] {
        let response: DeviceTokenListResponse = try await transport.request("device-tokens")
        return response.items
    }

    public func issue(label: String) async throws -> IssuedDeviceToken {
        try await transport.request(
            "device-tokens", method: "POST", body: IssueRequest(label: label))
    }

    public func prepareRotation(expectedVersion: Int) async throws -> IssuedDeviceToken {
        try await transport.request(
            "device-tokens/current/rotate", method: "POST",
            body: DeviceTokenVersionRequest(expectedVersion: expectedVersion))
    }

    public func activate(token: String, expectedVersion: Int) async throws -> ActivatedDeviceToken {
        try await transport.request(
            "device-tokens/activate", method: "POST", authorizationToken: token,
            body: DeviceTokenVersionRequest(expectedVersion: expectedVersion))
    }

    public func revoke(id: UUID, expectedVersion: Int) async throws -> DeviceTokenSummary {
        let response: RevokedDeviceToken = try await transport.request(
            "device-tokens/\(id)/revoke", method: "POST",
            body: DeviceTokenVersionRequest(expectedVersion: expectedVersion))
        return response.token
    }
}

private struct IssueRequest: Encodable, Sendable { let label: String }
private struct DeviceTokenVersionRequest: Encodable, Sendable {
    let expectedVersion: Int
    enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version" }
}
