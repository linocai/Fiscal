import Foundation
import Testing
@testable import FiscalKit

@Suite("F4-C encrypted Archive") struct F4CTests {
    @MainActor @Test("Archive uses the exact POST contract and fixed AI-redaction flag")
    func exactWireAndHandoff() async throws {
        let transport = F4CTransport(mode: .normal)
        let model = V15ArchiveModel(services: V15Services(transport: transport))
        model.password = "synthetic-password-123"; model.passwordConfirmation = "synthetic-password-123"
        model.beginExport(); model.confirmExport(); await waitForTransfer(model)
        let request = try #require(await transport.recordedRequests().first)
        #expect(request.path == "archives/export" && request.method == "POST")
        #expect(await transport.recordedBodies().first == .object(["password": .string("synthetic-password-123"), "include_ai_raw": .bool(false)]))
        let url = try #require(model.temporaryURL)
        #expect(url.lastPathComponent == "fiscal-archive-v1.far")
        #expect(model.password.isEmpty && model.passwordConfirmation.isEmpty)
        guard case .ready(let metadata) = model.phase else { Issue.record("only metadata may survive a successful transfer"); return }
        #expect(metadata.filename == "fiscal-archive-v1.far")
        await model.saveReadyArtifact(using: F4CArchiveSaver(mode: .saved))
        #expect(model.temporaryURL == nil && model.password.isEmpty && model.passwordConfirmation.isEmpty)
        guard case .completed = model.phase else { Issue.record("successful native handoff required") ; return }
    }

    @MainActor @Test("invalid metadata fails closed and password change cleans an active file")
    func metadataAndCredentialInvalidation() async throws {
        for mode in [F4CTransport.Mode.badType, .badFilename, .missingSecurity, .oversized] {
            let model = V15ArchiveModel(services: V15Services(transport: F4CTransport(mode: mode)))
            model.password = "synthetic-password-123"; model.passwordConfirmation = "synthetic-password-123"
            model.beginExport(); model.confirmExport(); await waitForTransfer(model)
            guard case .failed = model.phase else { Issue.record("\(mode) must fail closed"); continue }
            #expect(model.temporaryURL == nil)
        }
        let model = V15ArchiveModel(services: V15Services(transport: F4CTransport(mode: .normal)))
        model.password = "synthetic-password-123"; model.passwordConfirmation = "synthetic-password-123"
        model.beginExport(); model.confirmExport(); await waitForTransfer(model)
        let directory = try #require(model.temporaryURL?.deletingLastPathComponent())
        model.password = "changed-synthetic-password-123"
        #expect(model.temporaryURL == nil && !FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor @Test("offline, invalid confirmation, cancel, and unknown issue no unsafe local success")
    func disabledCancellationAndUnknown() async {
        let offlineTransport = F4CTransport(mode: .offline)
        let offline = V15ArchiveModel(services: V15Services(transport: offlineTransport), offlineSnapshotAt: .now)
        offline.password = "synthetic-password-123"; offline.passwordConfirmation = "synthetic-password-123"; offline.beginExport()
        #expect(await offlineTransport.recordedRequests().isEmpty)

        let invalidTransport = F4CTransport(mode: .normal)
        let invalid = V15ArchiveModel(services: V15Services(transport: invalidTransport))
        invalid.password = "synthetic-password-123"; invalid.passwordConfirmation = "different-synthetic-password"
        invalid.beginExport(); #expect(await invalidTransport.recordedRequests().isEmpty)

        let loadingTransport = F4CTransport(mode: .loading)
        let loading = V15ArchiveModel(services: V15Services(transport: loadingTransport))
        loading.password = "synthetic-password-123"; loading.passwordConfirmation = "synthetic-password-123"; loading.beginExport(); loading.confirmExport(); await Task.yield(); loading.cancel()
        #expect(loading.temporaryURL == nil && loading.phase == .idle && loading.password.isEmpty && loading.passwordConfirmation.isEmpty)

        let unknown = V15ArchiveModel(services: V15Services(transport: F4CTransport(mode: .unknown)))
        unknown.password = "synthetic-password-123"; unknown.passwordConfirmation = "synthetic-password-123"; unknown.beginExport(); unknown.confirmExport(); await waitForTransfer(unknown)
        guard case .unknown = unknown.phase else { Issue.record("response unknown must never claim an archive") ; return }
        #expect(unknown.temporaryURL == nil)
    }

    @MainActor @Test("failed and unknown transfers require an explicit reset and new POST")
    func retryIsExplicitNewTransfer() async {
        for mode in [F4CTransport.Mode.failureThenSuccess, .unknownThenSuccess] {
            let transport = F4CTransport(mode: mode)
            let model = V15ArchiveModel(services: V15Services(transport: transport))
            model.password = "synthetic-password-123"; model.passwordConfirmation = "synthetic-password-123"
            model.beginExport(); model.confirmExport(); await waitForTransfer(model)
            switch mode {
            case .failureThenSuccess: guard case .failed = model.phase else { Issue.record("failure must stay visible"); continue }
            case .unknownThenSuccess: guard case .unknown = model.phase else { Issue.record("unknown must stay visible"); continue }
            default: Issue.record("invalid retry fixture")
            }
            #expect(await transport.recordedRequests().count == 1)
            model.resetForNewExport()
            #expect(model.phase == .idle && model.temporaryURL == nil && model.password.isEmpty && model.passwordConfirmation.isEmpty)
            model.password = "synthetic-password-123"; model.passwordConfirmation = "synthetic-password-123"
            model.beginExport(); model.confirmExport(); await waitForTransfer(model)
            guard case .ready = model.phase else { Issue.record("only a user-confirmed second POST may succeed"); continue }
            #expect(await transport.recordedRequests().count == 2)
        }
    }

    @MainActor @Test("save cancellation deletes temporary bytes without another export")
    func saveCancellationAndRestoreBoundary() async throws {
        let transport = F4CTransport(mode: .normal)
        let model = V15ArchiveModel(services: V15Services(transport: transport))
        model.password = "synthetic-password-123"; model.passwordConfirmation = "synthetic-password-123"; model.beginExport(); model.confirmExport(); await waitForTransfer(model)
        let directory = try #require(model.temporaryURL?.deletingLastPathComponent())
        await model.saveReadyArtifact(using: F4CArchiveSaver(mode: .cancelled))
        #expect(model.phase == .idle && model.temporaryURL == nil && model.password.isEmpty && model.passwordConfirmation.isEmpty && !FileManager.default.fileExists(atPath: directory.path))
        #expect(await transport.recordedRequests().count == 1)
        #expect(model.restoreDisabledReason.contains("全新空目标"))
    }

    @MainActor @Test("temporary write failure leaves no partial directory and can be explicitly retried")
    func temporaryWriteFailureCleansUpAndRetries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FiscalF4CWriteFailure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var writes = 0
        let transport = F4CTransport(mode: .normal)
        let model = V15ArchiveModel(
            services: V15Services(transport: transport),
            temporaryRoot: root,
            temporaryWriter: { data, url in
                writes += 1
                if writes == 1 { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: url, options: .atomic)
            }
        )
        model.password = "synthetic-password-123"; model.passwordConfirmation = "synthetic-password-123"
        model.beginExport(); model.confirmExport(); await waitForTransfer(model)
        guard case .failed = model.phase else { Issue.record("write failure must not claim a ready archive"); return }
        #expect(model.temporaryURL == nil)
        #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty)

        model.resetForNewExport()
        model.password = "synthetic-password-123"; model.passwordConfirmation = "synthetic-password-123"
        model.beginExport(); model.confirmExport(); await waitForTransfer(model)
        guard case .ready = model.phase else { Issue.record("explicit retry after cleanup must be allowed"); return }
        #expect(await transport.recordedRequests().count == 2)
    }

    @MainActor @Test("system facts load independently and passphrase success clears every credential field")
    func systemFactsAndPassphraseSuccess() async throws {
        let transport = F4CSystemTransport(passphraseOutcome: .success)
        let model = V15SystemFactsModel(services: V15Services(transport: transport))
        await model.load()
        #expect(model.phase == .loaded)
        #expect(model.systemStatus?.version == "1.5.2")
        #expect(model.operationsStatus?.disk.state == "healthy")
        #expect(model.dataRevision?.revision == 52)
        #expect(model.authStatus?.credentialGeneration == 2)

        model.oldPassphrase = "old-passphrase"
        model.newPassphrase = "new-passphrase"
        model.newPassphraseConfirmation = "new-passphrase"
        #expect(model.passphraseDisabledReason == nil)
        await model.changePassphrase()
        #expect(model.oldPassphrase.isEmpty && model.newPassphrase.isEmpty && model.newPassphraseConfirmation.isEmpty)
        guard case .succeeded(let generation) = model.passphrasePhase else { Issue.record("expected passphrase success"); return }
        #expect(generation == 3)
        #expect(await transport.passphraseBody() == .object(["old_passphrase": .string("old-passphrase"), "new_passphrase": .string("new-passphrase")]))
    }

    @MainActor @Test("a later failed facts refresh clears prior server facts instead of presenting them as current")
    func failedSecondFactsReadDoesNotReuseFacts() async {
        let transport = F4CSystemTransport(passphraseOutcome: .success)
        let model = V15SystemFactsModel(services: V15Services(transport: transport))
        await model.load()
        #expect(model.phase == .loaded && model.systemStatus != nil)
        await transport.failFactReads()
        await model.load()
        guard case .failed = model.phase else { Issue.record("all failed reads must not remain loaded"); return }
        #expect(model.systemStatus == nil && model.operationsStatus == nil && model.dataRevision == nil && model.authStatus == nil)
    }

    @MainActor @Test("passphrase validation and uncertain outcomes fail closed without unsafe retry advice")
    func passphraseFailureStates() async {
        let invalid = V15SystemFactsModel(services: V15Services(transport: F4CSystemTransport(passphraseOutcome: .invalid)))
        invalid.oldPassphrase = "old-passphrase"
        invalid.newPassphrase = "new-passphrase"
        invalid.newPassphraseConfirmation = "different-passphrase"
        #expect(invalid.passphraseDisabledReason?.code == "passphrase_confirmation")
        invalid.newPassphraseConfirmation = "new-passphrase"
        await invalid.changePassphrase()
        guard case .failed(let failure) = invalid.passphrasePhase else { Issue.record("expected invalid passphrase failure"); return }
        #expect(failure.message == "当前口令不正确。")

        let unknown = V15SystemFactsModel(services: V15Services(transport: F4CSystemTransport(passphraseOutcome: .unknown)))
        unknown.oldPassphrase = "old-passphrase"
        unknown.newPassphrase = "new-passphrase"
        unknown.newPassphraseConfirmation = "new-passphrase"
        await unknown.changePassphrase()
        guard case .responseUnknown = unknown.passphrasePhase else { Issue.record("expected unknown outcome"); return }
        #expect(unknown.passphraseDisabledReason?.code == "passphrase_result_unknown")
        #expect(!unknown.oldPassphrase.isEmpty && !unknown.newPassphrase.isEmpty)
    }

    @MainActor @Test("credential-store failure after a successful passphrase rotation requires re-unlock and cannot be resubmitted")
    func passphraseStoreFailureRequiresReunlock() async {
        let services = V15Services(
            transport: F4CSystemTransport(passphraseOutcome: .success),
            saveAccessKey: { _ in throw CocoaError(.fileWriteNoPermission) }
        )
        let model = V15SystemFactsModel(services: services)
        model.oldPassphrase = "old-passphrase"
        model.newPassphrase = "new-passphrase"
        model.newPassphraseConfirmation = "new-passphrase"
        await model.changePassphrase()
        guard case .requiresReunlock(let failure) = model.passphrasePhase else { Issue.record("expected terminal re-unlock state"); return }
        #expect(failure.code == "access_key_store_failed")
        #expect(model.oldPassphrase.isEmpty && model.newPassphrase.isEmpty && model.newPassphraseConfirmation.isEmpty)
        #expect(model.passphraseDisabledReason?.code == "passphrase_reunlock_required")
        #expect(model.passphraseEntryDisabled)
    }

    #if os(macOS)
    @Test("native overwrite replaces only the selected destination")
    func atomicOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FiscalF4CAtomicWriter-\(UUID().uuidString)", isDirectory: true)
        let temporary = directory.appendingPathComponent("fiscal-archive-v1.far")
        let destination = directory.appendingPathComponent("saved.far")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("new encrypted archive".utf8).write(to: temporary)
        try Data("old archive".utf8).write(to: destination)
        try V15ArchiveAtomicWriter.replace(temporaryURL: temporary, destinationURL: destination)
        #expect(try Data(contentsOf: destination) == Data("new encrypted archive".utf8))
        #expect(FileManager.default.fileExists(atPath: temporary.path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(".fiscal-archive").path))
    }
    #endif

    @MainActor private func waitForTransfer(_ model: V15ArchiveModel) async {
        for _ in 0..<100 {
            if case .creating = model.phase {
                try? await Task.sleep(for: .milliseconds(10))
            } else {
                return
            }
        }
        Issue.record("Archive transfer did not reach a terminal state")
    }
}

private actor F4CSystemTransport: V15Transporting {
    enum PassphraseOutcome: Sendable { case success, invalid, unknown }
    private let passphraseOutcome: PassphraseOutcome
    private var bodies: [String: JSONValue?] = [:]
    private var shouldFailFactReads = false

    init(passphraseOutcome: PassphraseOutcome) { self.passphraseOutcome = passphraseOutcome }

    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        bodies[request.path] = body
        if shouldFailFactReads, request.path != "auth/passphrase/change" { throw V15Failure(kind: .transport, message: "fixture read failed") }
        switch request.path {
        case "system/status":
            return try decode(Data(#"{"service":"fiscal","version":"1.5.2","environment":"test","status":"operational","database":"ready","currency":"CNY","business_timezone":"Asia/Shanghai","timestamp":"2026-08-22T12:00:00Z"}"#.utf8))
        case "system/operations-status":
            return try decode(Data(#"{"service_version":"1.5.2","release_revision":"release-26","database":"ready","alembic_revision":"schema-26","release_alembic_revision":"schema-26","schema_state":"current","backup":{"state":"verified","created_at":"2026-08-22T10:00:00Z","age_hours":2,"duration_seconds":4,"size_bytes":4096},"restore":{"state":"verified","checked_at":"2026-08-22T09:00:00Z","age_hours":3,"duration_seconds":9},"disk":{"state":"healthy","checked_at":"2026-08-22T12:00:00Z","used_percent":41,"warning_percent":75,"failure_percent":90}}"#.utf8))
        case "data-revision":
            return try decode(Data(#"{"revision":52}"#.utf8))
        case "auth/status":
            return try decode(Data(#"{"authentication_mode":"passphrase","passphrase_set":true,"credential_generation":2,"last_rotated_at":"2026-08-21T12:00:00Z","active_access_key_count":1,"server_time":"2026-08-22T12:00:00Z"}"#.utf8))
        case "auth/passphrase/change":
            switch passphraseOutcome {
            case .success: return try decode(Data(#"{"access_key":"replacement-access-key","credential_generation":3}"#.utf8))
            case .invalid: throw V15Failure(kind: .transport, code: "invalid_passphrase", message: "backend detail must not leak")
            case .unknown: throw V15Failure(kind: .responseUnknown, code: "response_unknown", message: "unknown")
            }
        default:
            throw V15Failure(kind: .transport, message: "fixture route missing")
        }
    }

    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { Data() }
    func passphraseBody() -> JSONValue? { bodies["auth/passphrase/change"] ?? nil }
    func failFactReads() { shouldFailFactReads = true }
    private func decode<Response: Decodable>(_ data: Data) throws -> Response { try V15FixtureCodec.decoder.decode(Response.self, from: data) }
}
