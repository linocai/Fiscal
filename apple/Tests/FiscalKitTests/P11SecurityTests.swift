import Foundation
import Security
import Testing

@testable import FiscalKit

@Suite("FiscalKit P19 access passphrase")
struct P19AccessPassphraseTests {
    @Test("Access keys are stored in the iCloud-synchronized keychain, not device-bound")
    func accessKeyStoreUsesSynchronizableKeychain() {
        let query = AccessKeyStore.keychainQuery(
            service: "com.linotsai.fiscal.access", account: "access-key",
            accessGroup: "HX73DFL88G.com.linotsai.fiscal")
        #expect(query[kSecAttrSynchronizable as String] as? Bool == true)
        #expect((query[kSecAttrService as String] as? String) == "com.linotsai.fiscal.access")
        #expect((query[kSecAttrAccount as String] as? String) == "access-key")
        #expect(
            (query[kSecAttrAccessGroup as String] as? String) == "HX73DFL88G.com.linotsai.fiscal")
        let accessible = query[kSecAttrAccessible as String]
        #expect((accessible as! CFString) == kSecAttrAccessibleAfterFirstUnlock)
        // Device-bound accessibility cannot synchronize; make sure we did not pick it.
        #expect((accessible as! CFString) != kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    @Test("A default access-key store carries no access group (macOS uses the implicit group)")
    func defaultAccessKeyStoreQueryOmitsAccessGroup() {
        let query = AccessKeyStore.keychainQuery(
            service: "com.linotsai.fiscal.access", account: "access-key", accessGroup: nil)
        #expect(query[kSecAttrAccessGroup as String] == nil)
    }

    @Test("Entering the passphrase mints and stores an access key and reaches the connected state")
    @MainActor
    func loginStoresAccessKeyAndConnects() async {
        let store = AccessKeyStoreMock()
        let repo = AuthRepositoryMock(store: store, legacyToken: nil, passphrase: "opensesame")
        let model = PassphraseModel(
            repository: repo, accessKeyStore: store, legacyTokenStore: LegacyTokenStoreMock(nil))

        await model.loadStatus()
        #expect(model.phase == .unauthorized)

        await model.login(passphrase: "wrong-passphrase")
        #expect(model.phase == .unauthorized)
        #expect(await store.value == nil)

        await model.login(passphrase: "opensesame")
        #expect(model.isConnected)
        #expect(model.phase == .loaded)
        #expect(await store.value?.hasPrefix("fiscal_ak_v1_") == true)
    }

    @Test("Transition: a legacy device token bridges the one-time set-passphrase call") @MainActor
    func initializeBridgesLegacyTokenAndClosesTransition() async {
        let store = AccessKeyStoreMock()
        let legacy = LegacyTokenStoreMock("fiscal_dt_v1_legacy")
        let repo = AuthRepositoryMock(
            store: store, legacyToken: "fiscal_dt_v1_legacy", passphrase: nil)
        let model = PassphraseModel(
            repository: repo, accessKeyStore: store, legacyTokenStore: legacy)

        await model.loadStatus()
        // No access key yet, but the legacy token bridges status: transition, not unauthorized.
        #expect(model.isTransition)
        #expect(model.status?.passphraseSet == false)

        await model.initializePassphrase("brand-new-passphrase")
        #expect(model.isConnected)
        #expect(model.status?.passphraseSet == true)
        #expect(await store.value?.hasPrefix("fiscal_ak_v1_") == true)
        #expect(model.message == "访问口令已设定，本机已切换到口令连接")
    }

    @Test("Changing the passphrase rotates the stored access key and stays connected") @MainActor
    func changeRotatesAccessKey() async {
        let store = AccessKeyStoreMock()
        let repo = AuthRepositoryMock(store: store, legacyToken: nil, passphrase: "opensesame")
        let model = PassphraseModel(
            repository: repo, accessKeyStore: store, legacyTokenStore: LegacyTokenStoreMock(nil))
        await model.login(passphrase: "opensesame")
        let firstKey = await store.value

        await model.changePassphrase(old: "opensesame", new: "second-passphrase")
        #expect(model.isConnected)
        #expect(model.message == "访问口令已更新，其它设备需重新输入新口令")
        let rotatedKey = await store.value
        #expect(rotatedKey != nil)
        #expect(rotatedKey != firstKey)
        // The old passphrase no longer works; the new one does.
        await model.login(passphrase: "opensesame")
        #expect(model.message == "访问口令无效或已更改，请重新输入。")
    }

    @Test("A globally revoked access key drops the model into the unauthorized state") @MainActor
    func globalRevocationForcesUnauthorized() async {
        let store = AccessKeyStoreMock()
        let repo = AuthRepositoryMock(store: store, legacyToken: nil, passphrase: "opensesame")
        let model = PassphraseModel(
            repository: repo, accessKeyStore: store, legacyTokenStore: LegacyTokenStoreMock(nil))
        await model.login(passphrase: "opensesame")
        #expect(model.isConnected)

        // Another device changed the passphrase: the generation bumped and this key is revoked.
        await repo.externallyChangePassphrase()
        await model.loadStatus()
        #expect(model.phase == .unauthorized)
        #expect(model.isConnected == false)
    }
}

private actor AccessKeyStoreMock: AccessKeyStoring {
    private(set) var value: String?
    init(_ value: String? = nil) { self.value = value }
    func read() -> String? { value }
    func save(_ accessKey: String) { value = accessKey }
    func delete() { value = nil }
}

private actor LegacyTokenStoreMock: DeviceTokenStoring {
    private var token: String?
    init(_ token: String?) { self.token = token }
    func read() -> String? { token }
    func save(_ token: String) { self.token = token }
    func delete() { token = nil }
}

private actor AuthRepositoryMock: AuthRepositoryProtocol {
    private let store: AccessKeyStoreMock
    private let legacyToken: String?
    private var passphrase: String?
    private var generation = 1
    private var validKeys: Set<String> = []
    private var counter = 0

    init(store: AccessKeyStoreMock, legacyToken: String?, passphrase: String?) {
        self.store = store
        self.legacyToken = legacyToken
        self.passphrase = passphrase
    }

    func externallyChangePassphrase() {
        generation += 1
        validKeys.removeAll()
    }

    func session(passphrase: String) throws -> AccessKeyResponse {
        guard self.passphrase != nil else { throw conflict("passphrase_not_set") }
        guard passphrase == self.passphrase else { throw unauthorized("invalid_passphrase") }
        return mint()
    }

    func initialize(passphrase: String, legacyToken: String) throws -> AccessKeyResponse {
        guard self.passphrase == nil else { throw conflict("passphrase_already_set") }
        guard legacyToken == self.legacyToken else { throw FiscalAPIError.unauthorized(nil) }
        self.passphrase = passphrase
        return mint()
    }

    func change(oldPassphrase: String, newPassphrase: String) throws -> AccessKeyResponse {
        guard passphrase != nil else { throw conflict("passphrase_not_set") }
        guard oldPassphrase == passphrase else { throw unauthorized("invalid_passphrase") }
        generation += 1
        validKeys.removeAll()
        passphrase = newPassphrase
        return mint()
    }

    func status(authorizationToken: String?) async throws -> AccessCredentialStatus {
        let token: String?
        if let authorizationToken { token = authorizationToken } else { token = await store.read() }
        if let token, validKeys.contains(token) { return statusDTO(passphraseSet: true) }
        if let token, token == legacyToken, passphrase == nil {
            return statusDTO(passphraseSet: false)
        }
        throw FiscalAPIError.unauthorized(nil)
    }

    func operations(authorizationToken: String?) async throws -> OperationsStatusDTO {
        throw FiscalAPIError.unauthorized(nil)
    }

    private func mint() -> AccessKeyResponse {
        counter += 1
        let key = "fiscal_ak_v1_key\(counter)"
        validKeys.insert(key)
        return AccessKeyResponse(accessKey: key, credentialGeneration: generation)
    }

    private func statusDTO(passphraseSet: Bool) -> AccessCredentialStatus {
        AccessCredentialStatus(
            authenticationMode: passphraseSet ? "passphrase" : "transition_device_token",
            passphraseSet: passphraseSet,
            credentialGeneration: passphraseSet ? generation : nil,
            lastRotatedAt: nil,
            activeAccessKeyCount: passphraseSet ? validKeys.count : 0,
            serverTime: Date(timeIntervalSince1970: 1_752_681_600),
            rateLimits: RateLimits(
                readPerMinute: 120, writePerMinute: 30, aiPerMinute: 10, failedAuthPerMinute: 10))
    }

    private func unauthorized(_ code: String) -> FiscalAPIError {
        .unauthorized(APIErrorDetail(code: code, message: code, details: nil, requestID: "test"))
    }

    private func conflict(_ code: String) -> FiscalAPIError {
        .domain(
            status: 409,
            detail: APIErrorDetail(code: code, message: code, details: nil, requestID: "test"))
    }
}
