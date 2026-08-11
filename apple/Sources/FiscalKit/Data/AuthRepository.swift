import Foundation

public protocol AuthRepositoryProtocol: Sendable {
    func session(passphrase: String) async throws -> AccessKeyResponse
    func change(oldPassphrase: String, newPassphrase: String) async throws -> AccessKeyResponse
    func status() async throws -> AccessCredentialStatus
    func operations() async throws -> OperationsStatusDTO
}

public struct RemoteAuthRepository: AuthRepositoryProtocol {
    private let transport: APITransport
    public init(transport: APITransport) { self.transport = transport }

    public func session(passphrase: String) async throws -> AccessKeyResponse {
        try await transport.request(
            "auth/session", method: "POST", body: PassphraseBody(passphrase: passphrase))
    }

    public func change(oldPassphrase: String, newPassphrase: String) async throws -> AccessKeyResponse {
        try await transport.request(
            "auth/passphrase/change", method: "POST",
            body: ChangePassphraseBody(oldPassphrase: oldPassphrase, newPassphrase: newPassphrase))
    }

    public func status() async throws -> AccessCredentialStatus {
        try await transport.request("auth/status")
    }

    public func operations() async throws -> OperationsStatusDTO {
        try await transport.request("system/operations-status")
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
