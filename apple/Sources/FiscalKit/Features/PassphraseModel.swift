import Foundation
import Observation

/// Drives the access-passphrase connection: login, transition set-passphrase, change-passphrase,
/// and status. The access key is written straight into `AccessKeyStore` (iCloud-synced) and never
/// surfaced. A `.loaded` status with `passphraseSet == false` is the transition state (a legacy
/// device token is still bridging); `passphraseSet == true` is the connected state.
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
    private let legacyTokenStore: any DeviceTokenStoring
    private var generation = 0

    public init(
        repository: any AuthRepositoryProtocol,
        accessKeyStore: any AccessKeyStoring,
        legacyTokenStore: any DeviceTokenStoring
    ) {
        self.repository = repository
        self.accessKeyStore = accessKeyStore
        self.legacyTokenStore = legacyTokenStore
    }

    /// True while the credential exists and a valid access key is held.
    public var isConnected: Bool { phase == .loaded && status?.passphraseSet == true }
    /// True while no passphrase is set yet but a legacy device token bridges the connection.
    public var isTransition: Bool { phase == .loaded && status?.passphraseSet == false }

    public func loadStatus() async {
        generation += 1
        let current = generation
        if status == nil { phase = .loading }
        message = nil
        do {
            let loaded = try await repository.status(authorizationToken: nil)
            let ops = try? await repository.operations(authorizationToken: nil)
            guard current == generation else { return }
            status = loaded
            operations = ops
            phase = .loaded
        } catch is CancellationError {
            guard current == generation else { return }
            if phase == .loading { phase = status == nil ? .idle : .loaded }
        } catch {
            guard current == generation else { return }
            if case FiscalAPIError.unauthorized = error, await loadTransitionStatus(current) {
                return
            }
            apply(error)
        }
    }

    /// When the access key is missing/invalid, probe status through a still-valid legacy device
    /// token. Success means we are in the transition window (passphrase not yet set).
    private func loadTransitionStatus(_ current: Int) async -> Bool {
        guard let legacy = try? await legacyTokenStore.read(), !legacy.isEmpty else {
            return false
        }
        do {
            let loaded = try await repository.status(authorizationToken: legacy)
            let ops = try? await repository.operations(authorizationToken: legacy)
            guard current == generation else { return true }
            status = loaded
            operations = ops
            phase = .loaded
            return true
        } catch {
            return false
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

    /// Transition set-passphrase: bridge the still-valid legacy device token to authorize
    /// `initialize`. On success the device layer is permanently closed server-side.
    public func initializePassphrase(_ newPassphrase: String) async {
        guard !isMutating, validate(newPassphrase, field: "访问口令") else { return }
        isMutating = true
        message = nil
        defer { isMutating = false }
        let legacy: String?
        do {
            legacy = try await legacyTokenStore.read()
        } catch {
            message = "无法读取本机的旧连接凭证"
            return
        }
        guard let legacy, !legacy.isEmpty else {
            message = "本机没有可用于设定访问口令的旧连接凭证"
            return
        }
        do {
            let response = try await repository.initialize(passphrase: newPassphrase, legacyToken: legacy)
            try await accessKeyStore.save(response.accessKey)
        } catch {
            applyMutationError(error)
            return
        }
        await loadStatus()
        if phase == .loaded { message = "访问口令已设定，本机已切换到口令连接" }
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
        if error is TokenStoreError { return "无法读取本机 Keychain 中的旧连接凭证" }
        return error.localizedDescription
    }
}
