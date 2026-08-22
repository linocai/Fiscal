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
