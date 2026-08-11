import Foundation
import Observation

/// Drives the access-passphrase connection, change-passphrase flow, and status.
/// The access key is written straight into `AccessKeyStore` and never surfaced.
@MainActor
@Observable
public final class PassphraseModel {
    public enum Phase: Equatable { case idle, loading, loaded, unauthorized, failed }

    public private(set) var phase: Phase = .idle
    public private(set) var status: AccessCredentialStatus?
    public private(set) var operations: OperationsStatusDTO?
    public private(set) var message: String?
    public private(set) var isMutating = false

    private let repository: any AuthRepositoryProtocol
    private let accessKeyStore: any AccessKeyStoring
    private var generation = 0

    public init(
        repository: any AuthRepositoryProtocol,
        accessKeyStore: any AccessKeyStoring
    ) {
        self.repository = repository
        self.accessKeyStore = accessKeyStore
    }

    /// True while the credential exists and a valid access key is held.
    public var isConnected: Bool { phase == .loaded && status?.passphraseSet == true }

    public func loadStatus() async {
        generation += 1
        let current = generation
        if status == nil { phase = .loading }
        message = nil
        do {
            let loaded = try await repository.status()
            let ops = try? await repository.operations()
            guard current == generation else { return }
            status = loaded
            operations = ops
            phase = .loaded
        } catch is CancellationError {
            guard current == generation else { return }
            if phase == .loading { phase = status == nil ? .idle : .loaded }
        } catch {
            guard current == generation else { return }
            apply(error)
        }
    }

    public func login(passphrase: String) async {
        guard !isMutating, validate(passphrase, field: "访问口令") else { return }
        isMutating = true
        message = nil
        defer { isMutating = false }
        do {
            let response = try await repository.session(passphrase: passphrase)
            try await accessKeyStore.save(response.accessKey)
        } catch {
            applyMutationError(error)
            return
        }
        await loadStatus()
    }

    public func changePassphrase(old: String, new: String) async {
        guard !isMutating, validate(new, field: "新访问口令") else { return }
        isMutating = true
        message = nil
        defer { isMutating = false }
        do {
            let response = try await repository.change(oldPassphrase: old, newPassphrase: new)
            try await accessKeyStore.save(response.accessKey)
        } catch {
            applyMutationError(error)
            return
        }
        await loadStatus()
        if phase == .loaded { message = "访问口令已更新，其它设备需重新输入新口令" }
    }

    private func validate(_ passphrase: String, field: String) -> Bool {
        guard (8...128).contains(passphrase.count) else {
            message = "\(field)需为 8 到 128 个字符"
            return false
        }
        return true
    }

    private func apply(_ error: Error) {
        if case FiscalAPIError.unauthorized = error { phase = .unauthorized } else { phase = .failed }
        message = display(error)
    }

    private func applyMutationError(_ error: Error) { message = display(error) }

    private func display(_ error: Error) -> String {
        if let api = error as? FiscalAPIError { return api.displayMessage }
        if error is AccessKeyStoreError {
            return "口令已通过服务器验证，但本机保存连接凭证失败；请再试一次连接"
        }
        return error.localizedDescription
    }
}
