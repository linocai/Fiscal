import Foundation
import Observation

public enum V15ArchiveArtifactSaveResult: Sendable { case saved, cancelled }

public protocol V15ArchiveArtifactSaving: Sendable {
    func save(temporaryURL: URL, suggestedFilename: String) async throws -> V15ArchiveArtifactSaveResult
}

/// Owns the short-lived password, network transfer, and temporary archive.
/// The encrypted bytes are never decoded or logged on-device.
@MainActor @Observable
public final class V15ArchiveModel {
    /// Only local handoff metadata survives a successful transfer. Archive
    /// bytes remain a transient task-local value until written to the secure
    /// temporary file.
    public struct Metadata: Equatable, Sendable { public let filename: String }
    public enum Phase: Equatable {
        case idle, confirming, creating, ready(Metadata), saving(Metadata)
        case saveFailed(Metadata, V15Failure), completed(Metadata)
        case failed(V15Failure), unknown(V15Failure)
    }
    public struct TransferOwner: Equatable, Sendable { let generation: UInt64; let filename: String = "fiscal-archive-v1.far" }

    public private(set) var phase: Phase = .idle
    public private(set) var temporaryURL: URL?
    public private(set) var owner: TransferOwner?
    public var password = "" { didSet { if !clearingCredentials { credentialsChanged() } } }
    public var passwordConfirmation = "" { didSet { if !clearingCredentials { credentialsChanged() } } }
    private let services: V15Services
    private let offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)?
    private let temporaryRoot: URL
    private let temporaryWriter: (Data, URL) throws -> Void
    private var generation: UInt64 = 0
    private var transferTask: Task<Void, Never>?
    private var clearingCredentials = false

    public init(services: V15Services, offlineSnapshotAt: Date? = nil, offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)? = nil, temporaryRoot: URL = FileManager.default.temporaryDirectory, temporaryWriter: @escaping (Data, URL) throws -> Void = { data, url in try data.write(to: url, options: .atomic) }) {
        self.services = services
        self.offlineSnapshotProvider = offlineSnapshotProvider ?? { offlineSnapshotAt ?? services.offlineSnapshotAt }
        self.temporaryRoot = temporaryRoot
        self.temporaryWriter = temporaryWriter
    }

    public var offlineSnapshotAt: Date? { offlineSnapshotProvider?() }
    public var isOffline: Bool { offlineSnapshotAt != nil }
    public var passwordIssue: String? {
        guard phase.acceptsCredentials else { return nil }
        return credentialIssue
    }
    private var credentialIssue: String? {
        guard (12...128).contains(password.count) else { return "密码须为 12 到 128 个字符。" }
        guard password == passwordConfirmation else { return "两次输入的密码不一致。" }
        return nil
    }
    public var exportDisabledReason: String? {
        if isOffline { return "离线快照不能创建归档；请连接服务器。" }
        if let passwordIssue { return passwordIssue }
        if case .creating = phase { return "正在创建加密归档。" }
        if case .saving = phase { return "正在保存加密归档。" }
        return nil
    }
    public var canBeginExport: Bool { exportDisabledReason == nil && phase == .idle }
    public var restoreDisabledReason: String { "恢复仅由受控操作员在 schema-compatible 的全新空目标执行；此设备不提供恢复入口。" }

    public func beginExport() {
        guard canBeginExport else { return }
        phase = .confirming
    }

    public func cancel() { invalidate(removeFile: true) }
    public func dismiss() { invalidate(removeFile: true) }

    public func confirmExport() {
        guard case .confirming = phase, !isOffline, credentialIssue == nil else { return }
        generation &+= 1
        let captured = TransferOwner(generation: generation)
        owner = captured
        phase = .creating
        let capturedPassword = password
        transferTask?.cancel()
        transferTask = Task { [weak self] in
            guard let self else { return }
            do {
                let artifact = try await self.services.archives.export(password: capturedPassword)
                guard !Task.isCancelled, self.owner == captured, self.generation == captured.generation else { return }
                let url = try self.writeTemporary(artifact)
                guard !Task.isCancelled, self.owner == captured, self.generation == captured.generation else { Self.removeTemporary(url); return }
                let metadata = Metadata(filename: artifact.filename)
                self.temporaryURL = url
                self.clearCredentials()
                self.phase = .ready(metadata)
            } catch let failure as V15Failure {
                guard self.owner == captured, self.generation == captured.generation else { return }
                self.temporaryURL = nil
                self.phase = failure.kind == .responseUnknown ? .unknown(failure) : (failure.kind == .cancelled ? .idle : .failed(failure))
            } catch {
                guard self.owner == captured, self.generation == captured.generation else { return }
                self.phase = .failed(.init(kind: .transport, code: "archive_transfer_failed", message: "无法创建加密归档。"))
            }
        }
    }

    public func saveReadyArtifact(using saver: any V15ArchiveArtifactSaving) async {
        guard case .ready(let metadata) = phase, let url = temporaryURL, url.lastPathComponent == metadata.filename else { return }
        let captured = owner
        phase = .saving(metadata)
        do {
            let result = try await saver.save(temporaryURL: url, suggestedFilename: metadata.filename)
            guard owner == captured, temporaryURL == url else { return }
            switch result {
            case .saved: finishHandoff(metadata, url: url)
            case .cancelled: invalidate(removeFile: true)
            }
        } catch {
            guard owner == captured, temporaryURL == url else { return }
            phase = .saveFailed(metadata, .init(kind: .transport, code: "archive_save_failed", message: "无法保存加密归档。"))
        }
    }

    public func retrySave(using saver: any V15ArchiveArtifactSaving) async {
        guard case .saveFailed(let metadata, _) = phase else { return }
        phase = .ready(metadata)
        await saveReadyArtifact(using: saver)
    }

    /// iOS fileExporter invokes this only after the native picker completes.
    public func completeIOSHandoff(success: Bool) {
        guard case .ready(let metadata) = phase, let url = temporaryURL else { return }
        success ? finishHandoff(metadata, url: url) : invalidate(removeFile: true)
    }

    /// A retry is deliberately a reset, never an automatic replay. The user
    /// must enter a new password and explicitly confirm a new POST.
    public func resetForNewExport() { invalidate(removeFile: true) }

    private func finishHandoff(_ metadata: Metadata, url: URL) {
        Self.removeTemporary(url); temporaryURL = nil; owner = nil; transferTask = nil; clearCredentials(); phase = .completed(metadata)
    }
    private func credentialsChanged() {
        // Editing credentials invalidates any derived transfer, but must not
        // erase the character the user has just entered.
        invalidate(removeFile: true, shouldClearCredentials: false)
    }
    private func invalidate(removeFile: Bool, shouldClearCredentials: Bool = true) {
        generation &+= 1; transferTask?.cancel(); transferTask = nil
        if removeFile, let temporaryURL { Self.removeTemporary(temporaryURL) }
        temporaryURL = nil; owner = nil
        if shouldClearCredentials { clearCredentials() }
        phase = .idle
    }
    private func clearCredentials() {
        clearingCredentials = true
        password = ""
        passwordConfirmation = ""
        clearingCredentials = false
    }
    private func writeTemporary(_ artifact: V15ArchiveArtifact) throws -> URL {
        let directory = temporaryRoot.appendingPathComponent("FiscalV15Archive-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(artifact.filename, isDirectory: false)
            try temporaryWriter(artifact.data, url)
            return url
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
    private static func removeTemporary(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

/// Read-only operations facts and the separately authenticated passphrase
/// rotation flow share the System & Data surface, but never share archive
/// transfer state or credentials.
@MainActor @Observable
public final class V15SystemFactsModel {
    public enum Phase: Equatable { case idle, loading, loaded, offline(Date), failed(V15Failure) }
    public enum PassphrasePhase: Equatable {
        case idle, changing, succeeded(credentialGeneration: Int), failed(V15Failure), responseUnknown(V15Failure), requiresReunlock(V15Failure)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var systemStatus: V15SystemStatus?
    public private(set) var operationsStatus: OperationsStatusDTO?
    public private(set) var dataRevision: DataRevisionResponse?
    public private(set) var authStatus: V15AuthStatus?
    public private(set) var systemFailure: V15Failure?
    public private(set) var operationsFailure: V15Failure?
    public private(set) var revisionFailure: V15Failure?
    public private(set) var authFailure: V15Failure?
    public private(set) var passphrasePhase: PassphrasePhase = .idle
    public var oldPassphrase = ""
    public var newPassphrase = ""
    public var newPassphraseConfirmation = ""

    private let services: V15Services
    private let offlineSnapshotProvider: @MainActor @Sendable () -> Date?
    private var generation: UInt64 = 0
    private var mutationGeneration: UInt64 = 0

    public init(services: V15Services, offlineSnapshotAt: Date? = nil) {
        self.services = services
        self.offlineSnapshotProvider = { offlineSnapshotAt ?? services.offlineSnapshotAt }
    }

    public var offlineSnapshotAt: Date? { offlineSnapshotProvider() }
    public var isOffline: Bool { offlineSnapshotAt != nil }
    public var isChangingPassphrase: Bool { if case .changing = passphrasePhase { true } else { false } }
    public var passphraseEntryDisabled: Bool {
        switch passphrasePhase {
        case .changing, .requiresReunlock: true
        default: false
        }
    }
    public var passphraseDisabledReason: V15DisabledReason? {
        if isOffline { return .init(code: "offline_read_only", message: "离线快照不能修改口令；请连接服务器。", fieldPath: nil) }
        if case .requiresReunlock = passphrasePhase {
            return .init(code: "passphrase_reunlock_required", message: "口令已经修改，但本机无法保存新凭证；请使用新口令重新解锁。", fieldPath: nil)
        }
        if case .responseUnknown = passphrasePhase {
            return .init(code: "passphrase_result_unknown", message: "修改结果未知；不要重复提交，请先尝试用新口令重新解锁。", fieldPath: nil)
        }
        guard (8...128).contains(oldPassphrase.count) else { return .init(code: "old_passphrase_length", message: "当前口令须为 8 到 128 个字符。", fieldPath: "old_passphrase") }
        guard (8...128).contains(newPassphrase.count) else { return .init(code: "new_passphrase_length", message: "新口令须为 8 到 128 个字符。", fieldPath: "new_passphrase") }
        guard newPassphrase != oldPassphrase else { return .init(code: "passphrase_unchanged", message: "新口令必须与当前口令不同。", fieldPath: "new_passphrase") }
        guard newPassphrase == newPassphraseConfirmation else { return .init(code: "passphrase_confirmation", message: "两次输入的新口令不一致。", fieldPath: "new_passphrase_confirmation") }
        if isChangingPassphrase { return .init(code: "passphrase_changing", message: "正在修改口令。", fieldPath: nil) }
        return nil
    }

    public func load() async {
        generation &+= 1
        let current = generation
        resetFactFailures()
        clearFacts()
        guard let snapshot = offlineSnapshotAt else {
            phase = .loading
            let systemService = services.system
            let sessionService = services.session
            async let system = Self.capture { try await systemService.status() }
            async let operations = Self.capture { try await systemService.operationsStatus() }
            async let revision = Self.capture { try await systemService.dataRevision() }
            async let auth = Self.capture { try await sessionService.status() }
            let results = await (system, operations, revision, auth)
            guard current == generation else { return }
            if Task.isCancelled { phase = .idle; return }
            switch results.0 { case .success(let value): systemStatus = value; case .failure(let failure): systemFailure = failure }
            switch results.1 { case .success(let value): operationsStatus = value; case .failure(let failure): operationsFailure = failure }
            switch results.2 { case .success(let value): dataRevision = value; case .failure(let failure): revisionFailure = failure }
            switch results.3 { case .success(let value): authStatus = value; case .failure(let failure): authFailure = failure }
            if systemStatus != nil || operationsStatus != nil || dataRevision != nil || authStatus != nil {
                phase = .loaded
            } else {
                phase = .failed(systemFailure ?? operationsFailure ?? revisionFailure ?? authFailure ?? .init(kind: .transport, message: "无法读取系统事实。"))
            }
            return
        }
        phase = .offline(snapshot)
    }

    public func changePassphrase() async {
        guard passphraseDisabledReason == nil else { return }
        mutationGeneration &+= 1
        let current = mutationGeneration
        let old = oldPassphrase
        let new = newPassphrase
        passphrasePhase = .changing
        do {
            let response = try await services.session.changePassphrase(oldPassphrase: old, newPassphrase: new)
            guard current == mutationGeneration else { return }
            clearPassphrases()
            passphrasePhase = .succeeded(credentialGeneration: response.credentialGeneration)
        } catch is CancellationError {
            guard current == mutationGeneration else { return }
            passphrasePhase = .idle
        } catch let failure as V15Failure {
            guard current == mutationGeneration else { return }
            if failure.kind == .responseUnknown {
                passphrasePhase = .responseUnknown(failure)
            } else if failure.code == "access_key_store_failed" {
                clearPassphrases()
                passphrasePhase = .requiresReunlock(failure)
            } else if failure.code == "invalid_passphrase" {
                passphrasePhase = .failed(.init(kind: failure.kind, code: failure.code, message: "当前口令不正确。"))
            } else {
                passphrasePhase = .failed(failure)
            }
        } catch {
            guard current == mutationGeneration else { return }
            passphrasePhase = .failed(.init(kind: .transport, code: "passphrase_change_failed", message: "无法修改口令。"))
        }
    }

    public func resetPassphraseFlow() {
        mutationGeneration &+= 1
        clearPassphrases()
        passphrasePhase = .idle
    }

    public func invalidate() {
        generation &+= 1
        mutationGeneration &+= 1
        resetPassphraseFlow()
        phase = .idle
    }

    private func resetFactFailures() {
        systemFailure = nil; operationsFailure = nil; revisionFailure = nil; authFailure = nil
    }
    private func clearFacts() {
        systemStatus = nil; operationsStatus = nil; dataRevision = nil; authStatus = nil
    }
    private func clearPassphrases() {
        oldPassphrase = ""; newPassphrase = ""; newPassphraseConfirmation = ""
    }
    private nonisolated static func capture<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async -> Result<Value, V15Failure> {
        do { return .success(try await operation()) }
        catch is CancellationError { return .failure(.init(kind: .cancelled, message: "请求已取消。")) }
        catch let failure as V15Failure { return .failure(failure) }
        catch { return .failure(.init(kind: .transport, message: "无法读取系统事实。")) }
    }
}

private extension V15ArchiveModel.Phase {
    var acceptsCredentials: Bool {
        switch self { case .idle, .confirming: true; default: false }
    }
}
