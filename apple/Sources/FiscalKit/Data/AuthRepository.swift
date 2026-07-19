import Foundation

public protocol AuthRepositoryProtocol: Sendable {
    func session(passphrase: String) async throws -> AccessKeyResponse
    /// Transition-only: sets the passphrase authorized by a still-valid legacy device token.
    func initialize(passphrase: String, legacyToken: String) async throws -> AccessKeyResponse
    func change(oldPassphrase: String, newPassphrase: String) async throws -> AccessKeyResponse
    /// `authorizationToken` overrides the stored access key (used to bridge status in transition).
    func status(authorizationToken: String?) async throws -> AccessCredentialStatus
    func operations(authorizationToken: String?) async throws -> OperationsStatusDTO
}

public struct RemoteAuthRepository: AuthRepositoryProtocol {
    private let transport: APITransport
    public init(transport: APITransport) { self.transport = transport }

    public func session(passphrase: String) async throws -> AccessKeyResponse {
        try await transport.request(
            "auth/session", method: "POST", body: PassphraseBody(passphrase: passphrase))
    }

    public func initialize(passphrase: String, legacyToken: String) async throws -> AccessKeyResponse {
        try await transport.request(
            "auth/passphrase/initialize", method: "POST", authorizationToken: legacyToken,
            body: PassphraseBody(passphrase: passphrase))
    }

    public func change(oldPassphrase: String, newPassphrase: String) async throws -> AccessKeyResponse {
        try await transport.request(
            "auth/passphrase/change", method: "POST",
            body: ChangePassphraseBody(oldPassphrase: oldPassphrase, newPassphrase: newPassphrase))
    }

    public func status(authorizationToken: String? = nil) async throws -> AccessCredentialStatus {
        try await transport.request("auth/status", authorizationToken: authorizationToken)
    }

    public func operations(authorizationToken: String? = nil) async throws -> OperationsStatusDTO {
        try await transport.request(
            "system/operations-status", authorizationToken: authorizationToken)
    }
}

private struct PassphraseBody: Encodable, Sendable { let passphrase: String }
private struct ChangePassphraseBody: Encodable, Sendable {
    let oldPassphrase: String
    let newPassphrase: String
    enum CodingKeys: String, CodingKey {
        case oldPassphrase = "old_passphrase"
        case newPassphrase = "new_passphrase"
    }
}
