import Foundation
import Observation

@MainActor
@Observable
public final class DeviceSecurityModel {
    public enum Phase: Equatable { case idle, loading, loaded, unauthorized, failed }

    public private(set) var phase: Phase = .idle
    public private(set) var status: SecurityStatusDTO?
    public private(set) var operations: OperationsStatusDTO?
    public private(set) var devices: [DeviceTokenSummary] = []
    public private(set) var message: String?
    public private(set) var issuedDeviceToken: IssuedDeviceToken?
    public private(set) var isMutating = false
    private let repository: any DeviceSecurityRepository
    private let tokenStore: any DeviceTokenStoring

    public init(repository: any DeviceSecurityRepository, tokenStore: any DeviceTokenStoring) {
        self.repository = repository; self.tokenStore = tokenStore
    }

    public func load() async {
        if status == nil { phase = .loading }
        message = nil
        do {
            async let loadedStatus = repository.securityStatus(authorizationToken: nil)
            async let loadedDevices = repository.list()
            async let loadedOperations = loadOperationsBestEffort()
            status = try await loadedStatus
            devices = try await loadedDevices
            operations = await loadedOperations
            phase = .loaded
        } catch {
            apply(error)
        }
    }

    @discardableResult
    public func recoverPendingRotation() async -> Bool {
        let pending: PendingDeviceToken
        do {
            guard let value = try await tokenStore.readPending() else { return false }
            pending = value
        } catch {
            message = "待激活设备密钥无法从 Keychain 读取"
            return false
        }
        do {
            _ = try await repository.activate(
                token: pending.token, expectedVersion: pending.expectedVersion)
            try await tokenStore.promotePending()
            return true
        } catch {
            do {
                let verified = try await repository.securityStatus(authorizationToken: pending.token)
                guard let verifiedDevice = verified.currentDevice,
                      verifiedDevice.status == .active,
                      pending.deviceID == nil || verifiedDevice.id == pending.deviceID else {
                    throw error
                }
                try await tokenStore.promotePending()
                return true
            } catch {
                let hasActiveToken = (try? await tokenStore.read()) != nil
                message = hasActiveToken
                    ? "设备密钥轮换尚未确认，原密钥仍会保留"
                    : "新设备密钥尚未确认，候选密钥仍安全保留在 Keychain"
                return false
            }
        }
    }

    public func installIssuedToken(_ rawToken: String) async {
        guard !isMutating else { return }
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("fiscal_dt_v1_"), (56...256).contains(token.count),
              token.dropFirst("fiscal_dt_v1_".count).allSatisfy({
                  $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
              }) else {
            message = "设备密钥格式不正确"
            return
        }
        isMutating = true
        message = nil
        defer { isMutating = false }
        do {
            try await tokenStore.savePending(.init(token: token, expectedVersion: 1))
            guard await recoverPendingRotation() else { return }
            message = "新设备密钥已激活并安全存入 Keychain"
            await loadPreservingMessage()
        } catch {
            applyMutationError(error)
        }
    }

    public func rotateCurrent() async {
        guard let current = status?.currentDevice, !isMutating else { return }
        isMutating = true; message = nil
        defer { isMutating = false }
        do {
            let issued = try await repository.prepareRotation(expectedVersion: current.version)
            try await tokenStore.savePending(.init(
                token: issued.deviceToken,
                expectedVersion: issued.token.version,
                deviceID: issued.token.id
            ))
            guard await recoverPendingRotation() else { return }
            message = "设备密钥已安全轮换，旧密钥已由服务器撤销"
            await loadPreservingMessage()
        } catch {
            applyMutationError(error)
        }
    }

    public func issueDevice(label: String) async {
        guard !isMutating else { return }
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { message = "请输入设备名称"; return }
        isMutating = true; message = nil; defer { isMutating = false }
        do {
            issuedDeviceToken = try await repository.issue(label: normalized)
            message = "新设备密钥只显示这一次；请立即安全转移并激活"
            devices = try await repository.list()
        } catch { applyMutationError(error) }
    }

    public func clearIssuedToken() { issuedDeviceToken = nil }

    public func removeCurrentDevice() async {
        guard let current = status?.currentDevice, !isMutating else { return }
        isMutating = true; message = nil; defer { isMutating = false }
        do {
            _ = try await repository.revoke(id: current.id, expectedVersion: current.version)
        } catch { applyMutationError(error); return }
        // The server key is revoked past this point. Even if local Keychain cleanup fails, move to
        // the unauthorized state so the user isn't stranded with 401s and no way forward (L18).
        let deleted = (try? await tokenStore.delete()) != nil
        let deletedPending = (try? await tokenStore.deletePending()) != nil
        status = nil; operations = nil; devices = []; phase = .unauthorized
        message = deleted && deletedPending
            ? "此设备密钥已从服务器撤销并从本机 Keychain 移除"
            : "此设备密钥已从服务器撤销，但本机 Keychain 未能完全清除；请重新配置连接以清除残留密钥。"
    }

    public func revoke(_ device: DeviceTokenSummary) async {
        guard !isMutating else { return }
        isMutating = true; message = nil; defer { isMutating = false }
        do {
            _ = try await repository.revoke(id: device.id, expectedVersion: device.version)
            devices = try await repository.list()
            message = "已撤销 \(device.label)"
        } catch { applyMutationError(error) }
    }

    private func loadPreservingMessage() async {
        let retained = message
        do {
            async let loadedStatus = repository.securityStatus(authorizationToken: nil)
            async let loadedDevices = repository.list()
            async let loadedOperations = loadOperationsBestEffort()
            status = try await loadedStatus
            devices = try await loadedDevices
            operations = await loadedOperations
            phase = .loaded
        } catch { apply(error) }
        if phase == .loaded { message = retained }
    }

    private func apply(_ error: Error) {
        if case FiscalAPIError.unauthorized = error { phase = .unauthorized }
        else { phase = .failed }
        message = display(error)
    }

    private func loadOperationsBestEffort() async -> OperationsStatusDTO? {
        try? await repository.operationsStatus()
    }

    private func applyMutationError(_ error: Error) { message = display(error) }

    private func display(_ error: Error) -> String {
        if let api = error as? FiscalAPIError { return api.displayMessage }
        if error is TokenStoreError { return "无法安全更新本机 Keychain 中的设备密钥" }
        return error.localizedDescription
    }
}
