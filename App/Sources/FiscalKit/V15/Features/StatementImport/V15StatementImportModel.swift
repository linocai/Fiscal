import CryptoKit
import Foundation
import Observation
import PDFKit

/// Device-only result. It has no URL, bookmark, Data, image, or raw OCR text;
/// leaving the current import task makes the value unrecoverable by design.
public struct V15StatementLocalDocument: Sendable, Equatable {
    public let sha256: String; public let byteSize, pageCount: Int
    public let evidence: V15StatementEvidenceSubmission
}

public enum V15StatementLocalError: Error, Sendable, Equatable { case unsupported, unavailable, cancelled
    var failure: V15Failure { switch self { case .unsupported: .init(kind: .decoding, code: "document_invalid", message: "请选择未加密、可读取的 PDF。")
    case .unavailable: .init(kind: .transport, code: "document_unavailable", message: "账单文件已不可访问。")
    case .cancelled: .init(kind: .cancelled, code: "document_cancelled", message: "本地提取已取消。") } }
}

public protocol V15StatementLocalProcessing: Sendable { func process(url: URL, attemptID: UUID, expectedVersion: Int) async throws -> V15StatementLocalDocument }

/// A current-task-only PDFKit processor. The source URL is security scoped
/// only during the call; a randomized temporary copy is removed on every path.
public struct V15PDFStatementProcessor: V15StatementLocalProcessing {
    public init() {}
    public func process(url: URL, attemptID: UUID, expectedVersion: Int) async throws -> V15StatementLocalDocument {
        let task = Task<V15StatementLocalDocument, Error>.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard url.isFileURL else { throw V15StatementLocalError.unsupported }
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]); guard values.isRegularFile == true else { throw V15StatementLocalError.unavailable }
            guard (values.fileSize ?? 0) <= StatementPDFExtractionLimits.default.maximumFileBytes else { throw StatementPDFExtractionError.fileTooLarge(limit: StatementPDFExtractionLimits.default.maximumFileBytes) }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fiscal-statement-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let copy = directory.appendingPathComponent("source.pdf")
            try FileManager.default.copyItem(at: url, to: copy); try Task.checkCancellation()
            let data = try Data(contentsOf: copy, options: [.mappedIfSafe]); defer { _ = data }
            let document = try await StatementPDFEvidenceExtractor().extract(from: copy)
            let prepared = try StatementImportEvidencePackageBuilder().build(attemptID: attemptID, expectedVersion: expectedVersion, document: document).package
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let pages = prepared.pages.map { page in
                V15StatementEvidencePage(pageNumber: page.pageNumber, sourceKind: page.sourceKind.rawValue, evidenceTextMasked: page.evidenceTextMasked, boundingBoxes: page.boundingBoxes.map(Self.box))
            }
            let rows = prepared.rows.map { row in
                V15StatementEvidenceRow(rowNumber: row.rowNumber, pageNumber: row.pageNumber, evidenceTextMasked: row.evidenceTextMasked, boundingBox: Self.box(row.boundingBox))
            }
            return .init(sha256: digest, byteSize: data.count, pageCount: document.pageCount, evidence: .init(expectedVersion: expectedVersion, attemptID: attemptID, pages: pages, rows: rows))
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    private static func box(_ box: StatementPDFBoundingBox) -> V15StatementBoundingBox { .init(x: box.x, y: box.y, width: box.width, height: box.height) }
}

@MainActor @Observable
public final class V15StatementImportModel {
    public enum Phase: Equatable { case idle, localProcessing, registering, extracting, awaitingProviderConsent, parsing, providerResponseUnknown, reviewing, ready, confirming, responseUnknown, completed(V15StatementConfirmationReceipt), failed(V15Failure) }
    public private(set) var phase: Phase = .idle
    public private(set) var batch: V15StatementImport?
    public private(set) var workbench: V15StatementWorkbench?
    public private(set) var selectedRowIDs = Set<UUID>()
    public private(set) var selectedMatchIDs: [UUID: UUID] = [:]
    public private(set) var preview: V15StatementConfirmationPreview?
    /// Preview failures stay local to the confirmation surface, so the
    /// workbench remains usable and the sheet can offer an explicit retry.
    public private(set) var previewFailure: V15Failure?
    public private(set) var receipt: V15StatementConfirmationReceipt?
    public private(set) var page: V15StatementWorkbenchPage?
    /// A page read is an auxiliary masked-evidence request. Its failure must
    /// leave the workbench and its global lifecycle phase intact.
    public private(set) var pageFailure: V15Failure?
    public private(set) var isLoadingPage = false
    public private(set) var workbenchFilter = V15StatementWorkbenchFilter()
    public private(set) var workbenchFailure: V15Failure?
    public private(set) var isLoadingMore = false
    public private(set) var fieldIssues: [V15FieldIssue] = []
    public private(set) var localFailure: V15Failure?
    public private(set) var providerAuthorizationPreview: V15StatementProviderAuthorizationPreview?
    public var providerAuthorized = false { didSet { if oldValue != providerAuthorized { providerAuthorizationChanged() } } }
    private let services: V15Services
    private let processor: any V15StatementLocalProcessing
    private let offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)?
    private var localDocument: V15StatementLocalDocument?
    private var evidenceSHA256: String?
    private var providerSnapshotID: UUID?
    private var recoveredReadOnly = false
    private struct ProviderAttemptOwner: Codable, Sendable, Equatable { let batchID: UUID; let expectedVersion: Int; let evidenceSHA256: String; let authorization: V15StatementProviderAuthorization; let idempotencyKey: UUID }
    private var providerOwner: ProviderAttemptOwner?
    /// Draft-resolution PUT has no idempotency key. Once its wire is sent, a
    /// cancellation can only converge through a fresh read; it must never
    /// issue a second PUT from a rebuilt editor state.
    private struct ResolutionOwner: Sendable, Equatable {
        let batchID, rowID: UUID
        let expectedBatchVersion, expectedRowVersion, expectedResolutionVersion: Int
        let resolution: V15StatementResolution
        let matchedTransactionID: UUID?
        let ignoredReason: String?

        func isConfirmed(by row: V15StatementWorkbenchRow, batchVersion: Int) -> Bool {
            batchVersion > expectedBatchVersion
                && row.rowVersion >= expectedRowVersion
                && (row.draft?.version ?? 0) > expectedResolutionVersion
                && row.draft?.resolution == resolution
                && row.draft?.matchedTransactionID == matchedTransactionID
                && row.draft?.ignoredReason == ignoredReason
        }
    }
    private var resolutionOwner: ResolutionOwner?
    private var resolutionMayBeInFlight = false
    /// Owner-scoped recovery is intentionally independent of the visible
    /// workbench/page reads: it must scan unfiltered pages without replacing
    /// the user's current filter, cursor, or selected evidence page.
    public private(set) var isResolutionReadbackInFlight = false
    public private(set) var resolutionReadbackMessage: String?
    private var providerJournalID: UUID?
    private var confirmationJournalID: UUID?
    private var confirmationKey: UUID?
    private struct PreviewRowFingerprint: Equatable { let id: UUID; let rowVersion, draftVersion: Int; let finalCreateDraftVersion: Int? }
    private struct PreviewFingerprint: Equatable { let batchVersion, workbenchVersion: Int; let selectedRows: [PreviewRowFingerprint] }
    private var previewFingerprint: PreviewFingerprint?
    /// Set immediately before the confirmation transport call. From that
    /// point a cancellation is conservatively treated as outcome-unknown.
    private var confirmationMayBeInFlight = false
    private var generation: UInt64 = 0
    private var workbenchGeneration: UInt64 = 0
    private var pageGeneration: UInt64 = 0
    private var resolutionReadbackGeneration: UInt64 = 0
    @ObservationIgnored private var localTask: Task<Void, Never>?
    @ObservationIgnored private var mutationTask: Task<Void, Never>?
    @ObservationIgnored private var workbenchTask: Task<Void, Never>?
    @ObservationIgnored private var pageTask: Task<Void, Never>?
    @ObservationIgnored private var resolutionReadbackTask: Task<Void, Never>?
    private enum Mutation: Equatable { case provider, validation, resolution, preview, confirm, receipt }
    private var activeMutation: Mutation?

    public init(services: V15Services, processor: any V15StatementLocalProcessing = V15PDFStatementProcessor(), offlineSnapshotAt: Date? = nil, offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)? = nil) { self.services = services; self.processor = processor; self.offlineSnapshotProvider = offlineSnapshotProvider ?? { offlineSnapshotAt ?? services.offlineSnapshotAt } }
    public var offlineSnapshotAt: Date? { offlineSnapshotProvider?() }
    public var isOffline: Bool { offlineSnapshotAt != nil }
    private var isDisplayOnly: Bool { recoveredReadOnly || batch?.status == .abandoned || batch?.status.isDisplayOnly == true || workbench?.status.isDisplayOnly == true || preview?.status.isDisplayOnly == true }
    public var selectedRows: [V15StatementWorkbenchRow] { (workbench?.rows ?? []).filter { selectedRowIDs.contains($0.id) } }
    private var activeMutationMayProceed: Bool { writeReasons.allSatisfy { $0.code == "mutation_in_progress" } }
    private var hasUnsettledImportIntent: Bool {
        if providerJournalID != nil || confirmationJournalID != nil || confirmationKey != nil { return true }
        guard let id = batch?.id else { return false }
        return services.pendingWrites.items.contains { $0.resourceID == id && ($0.kind == .statementProviderAttempt || $0.kind == .statementConfirmation) }
    }
    public var isPreviewLoading: Bool { activeMutation == .preview }
    public var isConfirmationInFlight: Bool { activeMutation == .confirm }
    public var writeReasons: [V15DisabledReason] { var result: [V15DisabledReason] = []; if recoveredReadOnly || batch?.status == .abandoned { result.append(.init(code: "import_read_only", message: "当前账单仅可查看。", fieldPath: nil)) }; if isOffline { result.append(.init(code: "offline_read_only", message: "离线时不能导入或确认账单。", fieldPath: nil)) }; if batch?.status.isDisplayOnly == true || workbench?.status.isDisplayOnly == true || preview?.status.isDisplayOnly == true { result.append(.init(code: "unknown_import_status", message: "暂时无法识别账单状态；当前只供查看。", fieldPath: nil)) }; if activeMutation != nil { result.append(.init(code: "mutation_in_progress", message: "当前操作仍在进行；请稍候或先检查恢复状态。", fieldPath: nil)) }; if case .responseUnknown = phase { result.append(.init(code: "response_unknown", message: "确认结果暂时不明，请先检查确认结果。", fieldPath: nil)) }; if case .providerResponseUnknown = phase { result.append(.init(code: "provider_response_unknown", message: "解析结果暂时不明，请继续恢复解析。", fieldPath: nil)) }; if case .failed(let failure) = phase, failure.kind == .responseUnknown { result.append(.init(code: "lifecycle_response_unknown", message: "离开时操作结果暂时不明；请检查最新状态后再操作。", fieldPath: nil)) }; return result }
    public var previewReasons: [V15DisabledReason] { var result = writeReasons; if selectedRowIDs.isEmpty { result.append(.init(code: "selection_required", message: "请选择要确认的行。", fieldPath: "rows")) }; if selectedRows.contains(where: { !$0.draft.map(\.resolution.isExecutable).isTrue }) { result.append(.init(code: "unresolved_selected", message: "所选行仍未完成处理。", fieldPath: "rows")) }; return result }
    public var confirmReasons: [V15DisabledReason] { var result = writeReasons; if preview == nil || previewFingerprint != currentPreviewFingerprint { result.append(.init(code: "preview_required", message: "复核行已经更新；请重新查看确认预览。", fieldPath: nil)) }; return result }

    public func selectFile(url: URL) { guard writeReasons.isEmpty else { return }; cancelLocalAndDiscard(); generation &+= 1; let token = generation; phase = .localProcessing
        localTask = Task { [weak self] in guard let self else { return }; do {
            // First derive only metadata; the evidence request gets its server attempt/version later.
            let metadata = try await self.processor.process(url: url, attemptID: UUID(), expectedVersion: 1)
            guard token == self.generation else { return }; self.localDocument = metadata; await self.registerAndExtract(token: token)
        } catch is CancellationError { guard token == self.generation else { return }; self.phase = .idle
        } catch let error as StatementPDFExtractionError { guard token == self.generation else { return }; if error == .cancelled { self.phase = .idle } else { let failure = V15Failure(kind: .decoding, code: error.code, message: "无法提取此 PDF，请检查文件是否加密、损坏或超出上限。"); self.localFailure = failure; self.phase = .failed(failure) }
        } catch let error as V15StatementLocalError { guard token == self.generation else { return }; self.localFailure = error.failure; self.phase = .failed(error.failure)
        } catch { guard token == self.generation else { return }; let failure = V15Failure(kind: .transport, code: "document_unavailable", message: "本地账单处理失败。 "); self.localFailure = failure; self.phase = .failed(failure) } }
    }
    /// Gallery-only fixture path. Production screens never invoke this method.
    public func startSyntheticGallery() { guard writeReasons.isEmpty else { return }; cancelLocalAndDiscard(); generation &+= 1; let token = generation; localDocument = Self.syntheticDocument(); phase = .registering; localTask = Task { [weak self] in await self?.registerAndExtract(token: token) } }
    /// Gallery-only sequencing for synthetic fixtures. It follows the same
    /// request-bound flow as the UI, but never opens or retains a user file.
    public func prepareSyntheticGallery(_ scenario: String) async {
        guard !isOffline, scenario != "statement-import-intake" else { return }
        cancelLocalAndDiscard(); generation &+= 1
        let token = generation
        localDocument = Self.syntheticDocument()
        await registerAndExtract(token: token)
        guard case .awaitingProviderConsent = phase else { return }
        if scenario == "statement-import-provider" { return }
        providerAuthorized = true
        await startProviderAttempt()
        if scenario == "statement-import-request-bound-cancel" { return }
        guard case .reviewing = phase else { return }
        if scenario == "statement-import-review" { return }
        await runValidation()
        if scenario == "statement-import-page" || scenario == "statement-import-page-error" { await loadPage(1); return }
        if scenario == "statement-import-paged-filtered" { await setWorkbenchEvidenceFilter("available"); return }
        if scenario == "statement-import-resolution-recovery", let row = workbench?.rows.first(where: { $0.draft?.resolution == .unresolved }) {
            // Gallery-only: retain a current filter which excludes the owner,
            // then expose the GET-only recovery UI. Production always starts
            // this from a user's explicit row-resolution action.
            await setWorkbenchEvidenceFilter("unavailable")
            await resolve(row: row, as: .createNew)
            return
        }
        if scenario == "statement-import-preview" || scenario == "statement-import-preview-error" || scenario == "statement-import-preview-conflict" { await previewConfirmation(); return }
        if scenario == "statement-import-partial" || scenario == "statement-import-unknown" {
            await previewConfirmation()
            await confirm()
        }
    }
    public func cancelLocalAndDiscard() {
        let active = activeMutation
        let retainConfirmationRequest = active == .confirm && confirmationMayBeInFlight
        generation &+= 1
        workbenchGeneration &+= 1
        pageGeneration &+= 1
        resolutionReadbackGeneration &+= 1
        localTask?.cancel(); localTask = nil
        mutationTask?.cancel(); mutationTask = nil; activeMutation = nil
        workbenchTask?.cancel(); workbenchTask = nil
        pageTask?.cancel(); pageTask = nil
        resolutionReadbackTask?.cancel(); resolutionReadbackTask = nil
        if resolutionOwner != nil { isResolutionReadbackInFlight = false; resolutionReadbackMessage = "恢复读取已停止；只能重新读取完整复核行，不会重复提交。" }
        localDocument = nil
        page = nil; pageFailure = nil; isLoadingPage = false
        if !retainConfirmationRequest { preview = nil; previewFailure = nil; selectedRowIDs.removeAll() }
        switch active {
        case .provider:
            // The provider request can already have reached the server. Keep its immutable
            // request-bound owner so the sole recovery path replays exactly that request.
            phase = .providerResponseUnknown
        case .confirm:
            if confirmationMayBeInFlight {
                // The exact server request and idempotency key remain intact;
                // only the same-key receipt readback is permitted next.
                phase = .responseUnknown
            } else {
                confirmationKey = nil
                phase = .ready
            }
        case .resolution where resolutionMayBeInFlight:
            fail(.init(kind: .responseUnknown, code: "resolution_response_unknown", message: "行处理方案结果未知；正在读取最新复核行，绝不会重复提交。"))
        case .validation, .resolution, .preview:
            fail(.init(kind: .responseUnknown, code: "lifecycle_response_unknown", message: "离开页面时操作结果暂时不明；请检查最新状态后再操作。"))
        default:
            if providerJournalID == nil { evidenceSHA256 = nil; providerSnapshotID = nil; providerOwner = nil }; providerAuthorized = false
            if case .localProcessing = phase { phase = .idle }
            if case .registering = phase { phase = .idle }
            if case .extracting = phase { phase = .idle }
        }
    }
    public func sceneDidLeaveActive() { cancelLocalAndDiscard() }

    public func requestProviderAttempt() { runMutation(.provider) { await self.startProviderAttempt() } }
    public func requestProviderRecovery() { runMutation(.provider) { await self.recoverProviderAttempt() } }
    public func requestValidation() { runMutation(.validation) { await self.runValidation() } }
    public func requestResolution(row: V15StatementWorkbenchRow, as resolution: V15StatementResolution) { runMutation(.resolution) { await self.resolve(row: row, as: resolution) } }
    public func requestPreview() { guard !hasUnsettledImportIntent, activeMutationMayProceed else { return }; runMutation(.preview) { await self.previewConfirmation() } }
    public func requestConfirm() { guard !hasUnsettledImportIntent else { return }; runMutation(.confirm) { await self.confirm() } }
    public func requestConfirmationRecovery() { runMutation(.confirm) { await self.recoverOriginalConfirmation() } }
    public func requestReceiptReadback() { runMutation(.receipt) { await self.readConfirmationReceipt() } }
    public func requestReloadWorkbench() { runWorkbenchRead { await self.reloadWorkbench() } }
    public func requestNextWorkbench() { runWorkbenchRead { await self.loadNextWorkbench() } }
    public func requestWorkbenchEvidenceFilter(_ evidenceState: String?) { runWorkbenchRead { await self.setWorkbenchEvidenceFilter(evidenceState) } }
    public func requestPage(_ number: Int) { runPageRead { await self.loadPage(number) } }
    private func runMutation(_ mutation: Mutation, _ action: @escaping @MainActor () async -> Void) {
        // A mutation request is an immutable intent. Never replace it with a
        // second action while its wire may be in flight.
        guard activeMutation == nil else { return }
        generation &+= 1
        // Claim ownership synchronously. Sheet dismissal and scene changes can
        // occur before the task gets its first scheduling turn.
        activeMutation = mutation
        mutationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            await action()
            guard !Task.isCancelled, self.activeMutation == mutation else { return }
            self.activeMutation = nil; self.mutationTask = nil
        }
    }
    private func runWorkbenchRead(_ action: @escaping @MainActor () async -> Void) {
        workbenchGeneration &+= 1
        workbenchTask?.cancel()
        workbenchTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            await action()
            guard !Task.isCancelled else { return }
            self.workbenchTask = nil
        }
    }
    private func runPageRead(_ action: @escaping @MainActor () async -> Void) {
        pageGeneration &+= 1
        pageTask?.cancel()
        pageTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            await action()
            guard !Task.isCancelled else { return }
            self.pageTask = nil
        }
    }

    private func registerAndExtract(token: UInt64) async {
        guard let localDocument, !isOffline else { return }
        do {
            phase = .registering
            let registered = try await services.statementImports.register(.init(documentSHA256: localDocument.sha256, byteSize: localDocument.byteSize, pageCount: localDocument.pageCount, displayName: "statement.pdf"))
            guard token == generation else { return }
            batch = registered.value
            if registered.value.status.isDisplayOnly { phase = .ready; return }
            var existingLocalAttempt: UUID?
            if registered.duplicate {
                let recovery = try await services.statementImports.recovery(importID: registered.value.id, readCachePolicy: .reloadIgnoringCache)
                guard token == generation else { return }
                batch = recovery.batch
                if recovery.nextAction != "extract" { await applyRecovery(recovery); return }
                existingLocalAttempt = recovery.activeAttemptID
            }
            phase = .extracting
            let attemptID: UUID
            if let existingLocalAttempt { attemptID = existingLocalAttempt }
            else { attemptID = try await services.statementImports.startExtraction(importID: registered.value.id, expectedVersion: batch?.version ?? registered.value.version).id }
            guard token == generation else { return }
            let fresh = try await services.statementImports.statement(id: registered.value.id, readCachePolicy: .reloadIgnoringCache)
            guard token == generation else { return }; batch = fresh
            let evidence = V15StatementEvidenceSubmission(expectedVersion: fresh.version, attemptID: attemptID, pages: localDocument.evidence.pages, rows: localDocument.evidence.rows)
            let accepted = try await services.statementImports.submitEvidence(importID: fresh.id, request: evidence)
            guard token == generation else { return }
            batch = accepted.batch; evidenceSHA256 = accepted.evidenceSHA256
            try await loadProviderAuthorization()
        } catch let failure as V15Failure { guard token == generation else { return }; fail(failure) }
        catch { guard token == generation else { return }; fail(.init(kind: .transport, message: "账单导入失败。")) }
    }

    private func loadProviderAuthorization() async throws {
        guard let batch else { return }
        let token = generation
        let value = try await services.statementImports.providerAuthorization(importID: batch.id, readCachePolicy: .reloadIgnoringCache)
        guard token == generation, self.batch?.id == batch.id else { return }
        providerAuthorizationPreview = value
        evidenceSHA256 = value.evidenceSHA256
        providerAuthorized = false
        phase = .awaitingProviderConsent
    }
    public func startProviderAttempt() async {
        guard providerAuthorized, case .awaitingProviderConsent = phase, let batch,
              let info = providerAuthorizationPreview, info.configured,
              let provider = info.provider, let model = info.providerModel,
              let prompt = info.promptVersion, let schema = info.schemaVersion,
              let evidence = info.evidenceSHA256, activeMutationMayProceed else { return }
        let authorization = V15StatementProviderAuthorization(confirmed: true, provider: provider, providerModel: model, promptVersion: prompt, schemaVersion: schema, evidenceSHA256: evidence, pageNumbers: info.pageNumbers, rowCount: info.rowCount, redactionVersion: info.redactionVersion, redactionCount: info.redactionCount, configurationRevision: info.configurationRevision)
        let owner = ProviderAttemptOwner(batchID: batch.id, expectedVersion: info.batchVersion, evidenceSHA256: evidence, authorization: authorization, idempotencyKey: UUID())
        do {
            providerJournalID = try services.pendingWrites.prepare(kind: .statementProviderAttempt, title: "账单解析", request: owner, idempotencyKey: owner.idempotencyKey, resourceID: owner.batchID)
            providerOwner = owner
            await performProviderAttempt(owner)
        } catch { fail(.init(kind: .transport, code: "journal_unavailable", message: "解析请求无法安全保存，请检查本地存储后重试。")) }
    }
    /// Reads the durable receipt first, then replays only the original authorized intent.
    public func recoverProviderAttempt() async {
        guard let owner = providerOwner, case .providerResponseUnknown = phase, !isOffline, !isDisplayOnly else { return }
        let token = generation
        do {
            let value = try await services.statementImports.providerAttemptReceipt(importID: owner.batchID, idempotencyKey: owner.idempotencyKey, readCachePolicy: .reloadIgnoringCache)
            guard token == generation, providerOwner == owner else { return }
            if value.providerStatus != "started" { try acceptProvider(value); return }
            await performProviderAttempt(owner)
        } catch let failure as V15Failure where failure.code == "statement_provider_receipt_not_found" {
            // Missing is still unknown; an explicit retry uses the identical authorized key.
            guard token == generation, providerOwner == owner else { return }
            await performProviderAttempt(owner)
        } catch { phase = .providerResponseUnknown }
    }
    private func performProviderAttempt(_ owner: ProviderAttemptOwner) async {
        guard batch?.id == owner.batchID, let journalID = providerJournalID else { return }
        generation &+= 1; let token = generation
        do { try services.pendingWrites.markInFlight(journalID) }
        catch { fail(.init(kind: .transport, code: "journal_unavailable", message: "解析请求无法安全保存。")); return }
        phase = .parsing
        do {
            let value = try await services.statementImports.providerAttempt(importID: owner.batchID, request: .init(expectedVersion: owner.expectedVersion, evidenceSHA256: owner.evidenceSHA256, authorization: owner.authorization), idempotencyKey: owner.idempotencyKey)
            guard token == generation else { return }
            try acceptProvider(value)
        } catch let failure as V15Failure {
            guard token == generation else { return }
            services.pendingWrites.markUnknown(journalID)
            if failure.code == "statement_provider_authorization_stale" {
                do { try services.pendingWrites.complete(journalID) } catch { phase = .providerResponseUnknown; return }
                providerJournalID = nil; providerOwner = nil
                try? await loadProviderAuthorization()
                localFailure = failure
            } else { phase = .providerResponseUnknown }
        } catch { guard token == generation else { return }; services.pendingWrites.markUnknown(journalID); phase = .providerResponseUnknown }
    }
    private func acceptProvider(_ value: V15StatementProviderAttempt) throws {
        guard value.executionScope == "request_bound", value.batch.id == batch?.id else { throw V15Failure(kind: .decoding, message: "解析结果归属不匹配。") }
        batch = value.batch
        if value.providerStatus == "started" { phase = .providerResponseUnknown; return }
        guard ["succeeded", "failed", "abandoned"].contains(value.providerStatus) else { phase = .providerResponseUnknown; return }
        if value.providerStatus == "succeeded", value.providerSnapshotID == nil { throw V15Failure(kind: .decoding, message: "解析结果缺少已验证快照。") }
        if let id = providerJournalID { try services.pendingWrites.complete(id) }
        providerJournalID = nil; providerOwner = nil; providerAuthorized = false
        guard let snapshot = value.providerSnapshotID, value.providerStatus == "succeeded" else {
            fail(.init(kind: .transport, code: "provider_attempt_failed", message: "账单解析失败，请重新查看授权信息后重试。")); return
        }
        providerSnapshotID = snapshot; localDocument = nil; phase = .reviewing
    }
    private func applyRecovery(_ value: V15StatementRecovery) async {
        batch = value.batch; evidenceSHA256 = value.evidenceSHA256; providerSnapshotID = value.providerSnapshotID
        if await restorePending(batchID: value.batch.id) { return }
        switch value.nextAction {
        case "authorize_provider": do { try await loadProviderAuthorization() } catch { fail(.init(kind: .transport, message: "授权信息读取失败。")) }
        case "validate": phase = .reviewing
        case "review", "completed": await reloadWorkbench(); phase = .ready
        case "recover_provider": phase = .failed(.init(kind: .responseUnknown, message: "原解析仍需恢复；本机缺少原授权记录，不能创建新的解析。"))
        default: recoveredReadOnly = true; phase = .failed(.init(kind: .conflict, code: "import_read_only", message: "此账单当前仅可查看。"))
        }
    }
    public func resumePendingImport() async {
        guard batch == nil, !isOffline, let item = services.pendingWrites.items.first(where: { $0.kind == .statementProviderAttempt || $0.kind == .statementConfirmation }), let id = item.resourceID else { return }
        do { let value = try await services.statementImports.recovery(importID: id, readCachePolicy: .reloadIgnoringCache); await applyRecovery(value) }
        catch { fail(.init(kind: .responseUnknown, message: "未决账单读取失败，请保持原操作记录并重试。")) }
    }
    private func restorePending(batchID: UUID) async -> Bool {
        guard let item = services.pendingWrites.items.first(where: { $0.resourceID == batchID && ($0.kind == .statementProviderAttempt || $0.kind == .statementConfirmation) }) else { return false }
        do {
            guard let payload = item.payload else { throw V15Failure(kind: .decoding, message: "缺少原请求。") }
            if item.kind == .statementProviderAttempt {
                providerOwner = try JSONDecoder().decode(ProviderAttemptOwner.self, from: JSONEncoder().encode(payload))
                providerJournalID = item.id; phase = .providerResponseUnknown
            } else { confirmationKey = item.idempotencyKey; confirmationJournalID = item.id; phase = .responseUnknown }
        } catch { fail(.init(kind: .responseUnknown, message: "无法读取原导入请求；保留记录等待恢复。")) }
        return true
    }
    public func runValidation() async { guard case .reviewing = phase, let batch, let providerSnapshotID, activeMutationMayProceed else { return }; generation &+= 1; let token = generation
        do { let review = try await services.statementImports.validationRun(importID: batch.id, request: .init(expectedBatchVersion: batch.version, providerSnapshotID: providerSnapshotID)); guard token == generation else { return }; let board = try await services.statementImports.workbench(importID: batch.id, cursor: 0, filters: workbenchFilter, readCachePolicy: .reloadIgnoringCache); guard token == generation else { return }; guard review.batchID == board.batchID else { fail(.init(kind: .decoding, code: "review_owner_mismatch", message: "复核结果不属于当前账单。")); return }; self.batch = try await services.statementImports.statement(id: batch.id, readCachePolicy: .reloadIgnoringCache); workbench = board; workbenchFailure = nil; selectedRowIDs = Set(board.rows.filter { !$0.isConfirmed && $0.draft?.resolution.isExecutable == true }.map(\.id)); phase = .ready
        } catch let failure as V15Failure { guard token == generation else { return }; fail(failure) } catch { guard token == generation else { return }; fail(.init(kind: .transport, message: "账单复核读取失败。")) } }
    public func reloadWorkbench() async { await loadWorkbench(cursor: 0, replacing: true) }
    public func loadNextWorkbench() async { guard let cursor = workbench?.nextCursor, !isLoadingMore else { return }; await loadWorkbench(cursor: cursor, replacing: false) }
    public func setWorkbenchEvidenceFilter(_ evidenceState: String?) async {
        guard evidenceState == nil || evidenceState == "available" || evidenceState == "unavailable" else { return }
        workbenchFilter = .init(evidenceState: evidenceState)
        invalidatePreview()
        await reloadWorkbench()
    }
    private func loadWorkbench(cursor: Int, replacing: Bool) async {
        guard let batch else { return }; let owner = batch.id; workbenchGeneration &+= 1; let token = workbenchGeneration
        if !replacing { isLoadingMore = true }; workbenchFailure = nil
        do {
            let board = try await services.statementImports.workbench(importID: owner, cursor: cursor, filters: workbenchFilter, readCachePolicy: .reloadIgnoringCache)
            guard token == workbenchGeneration, owner == self.batch?.id else { return }
            if replacing {
                workbench = board
                selectedRowIDs = selectedRowIDs.intersection(Set(board.rows.filter { !$0.isConfirmed }.map(\.id)))
                if case .responseUnknown = phase {} else { invalidatePreview() }
            }
            else if let existing = workbench {
                workbench = .init(batchID: board.batchID, batchVersion: board.batchVersion, status: board.status, reviewAvailable: board.reviewAvailable, validationRunID: board.validationRunID, checks: board.checks, rows: existing.rows + board.rows, nextCursor: board.nextCursor, sourceUnavailableCount: existing.sourceUnavailableCount + board.sourceUnavailableCount)
            }
            isLoadingMore = false
        } catch let failure as V15Failure {
            guard token == workbenchGeneration, owner == self.batch?.id else { return }; isLoadingMore = false; workbenchFailure = failure
        } catch {
            guard token == workbenchGeneration, owner == self.batch?.id else { return }; isLoadingMore = false; workbenchFailure = .init(kind: .transport, message: "账单复核读取失败。")
        }
    }
    public func loadPage(_ number: Int) async {
        guard let batch else { return }
        let owner = batch.id
        pageGeneration &+= 1
        let token = pageGeneration
        isLoadingPage = true
        pageFailure = nil
        do {
            let value = try await services.statementImports.workbenchPage(importID: owner, pageNumber: number, readCachePolicy: .reloadIgnoringCache)
            guard token == pageGeneration, owner == self.batch?.id else { return }
            page = value
            isLoadingPage = false
        } catch let failure as V15Failure {
            guard token == pageGeneration, owner == self.batch?.id else { return }
            isLoadingPage = false
            pageFailure = failure
        } catch {
            guard token == pageGeneration, owner == self.batch?.id else { return }
            isLoadingPage = false
            pageFailure = .init(kind: .transport, message: "账单页读取失败。")
        }
    }
    public func toggleRow(_ id: UUID) { guard writeReasons.isEmpty, workbench?.rows.contains(where: { $0.id == id && !$0.isConfirmed }) == true else { return }; if selectedRowIDs.contains(id) { selectedRowIDs.remove(id) } else { selectedRowIDs.insert(id) }; invalidatePreview() }
    public func existingMatchCandidates(for row: V15StatementWorkbenchRow) -> [V15StatementWorkbenchCandidate] {
        var seen = Set<UUID>()
        return row.candidates.filter { candidate in
            guard candidate.candidateKind == "existing_transaction", let id = candidate.transactionID else { return false }
            return seen.insert(id).inserted
        }
    }
    public func selectedMatchTransactionID(for row: V15StatementWorkbenchRow) -> UUID? {
        let ids = existingMatchCandidates(for: row).compactMap(\.transactionID)
        if let selected = selectedMatchIDs[row.id], ids.contains(selected) { return selected }
        if let saved = row.draft?.matchedTransactionID, ids.contains(saved) { return saved }
        return ids.count == 1 ? ids.first : nil
    }
    public func selectMatchTransaction(_ id: UUID?, for row: V15StatementWorkbenchRow) {
        guard !row.isConfirmed, writeReasons.isEmpty else { return }
        if let id { guard existingMatchCandidates(for: row).contains(where: { $0.transactionID == id }) else { return }; selectedMatchIDs[row.id] = id }
        else { selectedMatchIDs.removeValue(forKey: row.id) }
        invalidatePreview()
    }
    public func resolve(row: V15StatementWorkbenchRow, as resolution: V15StatementResolution) async {
        guard let batch, !row.isConfirmed, activeMutationMayProceed else { return }
        if case .unknown = resolution { return }
        if resolution == .matchExisting && selectedMatchTransactionID(for: row) == nil {
            localFailure = .init(kind: .conflict, code: "match_selection_required", message: "请选择要匹配的具体交易。")
            return
        }
        let request = V15StatementDraftResolutionPut(expectedBatchVersion: batch.version, expectedRowVersion: row.rowVersion, expectedResolutionVersion: row.draft?.version ?? 0, resolution: resolution, matchedTransactionID: resolution == .matchExisting ? selectedMatchTransactionID(for: row) : nil, ignoredReason: resolution == .ignoreIntentional ? "人工确认忽略" : nil)
        let owner = ResolutionOwner(batchID: batch.id, rowID: row.id, expectedBatchVersion: request.expectedBatchVersion, expectedRowVersion: request.expectedRowVersion, expectedResolutionVersion: request.expectedResolutionVersion, resolution: request.resolution, matchedTransactionID: request.matchedTransactionID, ignoredReason: request.ignoredReason)
        resolutionOwner = owner
        resolutionMayBeInFlight = true
        generation &+= 1
        let token = generation
        do {
            let _ = try await services.statementImports.putResolution(importID: batch.id, rowID: row.id, request: request)
            guard token == generation, resolutionOwner == owner else { return }
            resolutionMayBeInFlight = false
            resolutionOwner = nil
            self.batch = try await services.statementImports.statement(id: batch.id, readCachePolicy: .reloadIgnoringCache)
            guard token == generation else { return }
            await reloadWorkbench()
        } catch let failure as V15Failure {
            guard token == generation, resolutionOwner == owner else { return }
            if failure.kind == .responseUnknown || failure.kind == .cancelled {
                phase = .failed(.init(kind: .responseUnknown, code: "resolution_response_unknown", message: "行处理方案结果未知；只能读取完整复核行恢复，绝不会重复提交。"))
            } else {
                resolutionMayBeInFlight = false
                resolutionOwner = nil
                fail(failure)
            }
        } catch {
            guard token == generation, resolutionOwner == owner else { return }
            phase = .failed(.init(kind: .responseUnknown, code: "resolution_response_unknown", message: "行处理方案结果未知；只能读取完整复核行恢复，绝不会重复提交。"))
        }
    }
    public func finalDraftCreditCycles(accountID: UUID) async throws -> [V15CreditCycle] {
        let account = try await services.masterData.account(id: accountID)
        guard account.cycleMode != "on_demand" else { return [] }
        var values: [V15CreditCycle] = []; var cursor: String?
        repeat { let page = try await services.credit.cycles(accountID: accountID, cursor: cursor); values += page.items.filter { $0.remainingMinor > 0 }; cursor = page.nextCursor } while cursor != nil
        return values
    }
    public func finalDraftContext(row: V15StatementWorkbenchRow) async throws -> (accounts: [V15AccountResponse], categories: [V15CategoryResponse], draft: V15StatementFinalCreateDraft?) {
        guard let batch, !row.isConfirmed else { throw V15Failure(kind: .conflict, message: "此行已冻结。") }
        let accounts = try await services.masterData.accounts(includeArchived: false)
        let categories = try await services.masterData.categories(includeArchived: false)
        let draft = row.finalCreateDraftVersion == nil ? nil : try await services.statementImports.finalCreateDraft(importID: batch.id, rowID: row.id, readCachePolicy: .reloadIgnoringCache)
        return (accounts, categories, draft)
    }
    public func saveFinalDraft(row: V15StatementWorkbenchRow, request: V15StatementFinalCreateDraftPut) async throws {
        guard let batch, !row.isConfirmed, activeMutationMayProceed else { throw V15Failure(kind: .conflict, message: "此行当前不能编辑。") }
        invalidatePreview()
        _ = try await services.statementImports.putFinalCreateDraft(importID: batch.id, rowID: row.id, request: request)
        self.batch = try await services.statementImports.statement(id: batch.id, readCachePolicy: .reloadIgnoringCache)
        await reloadWorkbench()
    }
    public func finalDraftEditorDismissed() { invalidatePreview() }
    public func previewConfirmation() async { guard !hasUnsettledImportIntent, activeMutationMayProceed, let batch, !isDisplayOnly, activeMutation == nil || activeMutation == .preview else { return }; previewFailure = nil; generation &+= 1; let token = generation; let fingerprint = currentPreviewFingerprint; guard fingerprint != nil else { return }; do { let value = try await services.statementImports.confirmationPreview(importID: batch.id, rowIDs: selectedRowIDs.sorted { $0.uuidString < $1.uuidString }); guard token == generation, fingerprint == currentPreviewFingerprint else { return }; guard Set(value.request.rows.map(\.rowID)) == selectedRowIDs else { previewFailure = .init(kind: .decoding, code: "preview_selection_mismatch", message: "确认预览与当前选择不一致，请重新获取。"); return }; preview = value; previewFingerprint = fingerprint; phase = .ready } catch let failure as V15Failure { guard token == generation else { return }; previewFailure = failure; phase = .ready } catch { guard token == generation else { return }; previewFailure = .init(kind: .transport, message: "确认预览失败。"); phase = .ready } }
    public func confirm() async {
        guard !hasUnsettledImportIntent, let batch, let preview, activeMutationMayProceed, previewFingerprint == currentPreviewFingerprint, confirmReasons.filter({ $0.code != "mutation_in_progress" }).isEmpty else { return }
        let key = UUID()
        do {
            let id = try services.pendingWrites.prepare(kind: .statementConfirmation, title: "账单确认", request: preview.request, idempotencyKey: key, resourceID: batch.id)
            confirmationJournalID = id; confirmationKey = key
            try services.pendingWrites.markInFlight(id)
        } catch { previewFailure = .init(kind: .transport, code: "journal_unavailable", message: "确认请求无法安全保存，尚未发送。"); return }
        confirmationMayBeInFlight = true; generation &+= 1; let token = generation; phase = .confirming
        do {
            let value = try await services.statementImports.confirm(importID: batch.id, serverRequest: preview.request, idempotencyKey: key)
            guard token == generation else { return }
            try await acceptConfirmation(value)
        } catch {
            guard token == generation else { return }
            await handleConfirmationFailure(error)
        }
    }
    private func handleConfirmationFailure(_ error: Error, recoveringUnknown: Bool = false) async {
        let failure = error as? V15Failure
        // These confirmation-service errors are emitted only after the global mutation
        // lock and original-key lookup. Gateway/auth 4xx cannot settle an older send.
        let settledRecoveryCodes: Set<String> = ["resource_version_conflict", "statement_import_confirmation_invalid", "statement_import_row_confirmed", "statement_import_final_draft_missing", "statement_import_not_found"]
        let rejected = failure.map { recoveringUnknown ? settledRecoveryCodes.contains($0.code ?? "") : ($0.kind == .conflict || $0.isDefinitiveRejection) } ?? false
        if let failure, rejected {
            do {
                if let id = confirmationJournalID { try services.pendingWrites.complete(id) }
            } catch {
                if let id = confirmationJournalID { services.pendingWrites.markUnknown(id) }
                confirmationMayBeInFlight = false; phase = .responseUnknown
                previewFailure = .init(kind: .transport, code: "journal_unavailable", message: "服务器已拒绝确认，但本地恢复记录未能更新，请再次检查原请求。")
                return
            }
            confirmationJournalID = nil; confirmationKey = nil; confirmationMayBeInFlight = false
            invalidatePreview(); phase = .ready
            if let batch {
                do { self.batch = try await services.statementImports.statement(id: batch.id, readCachePolicy: .reloadIgnoringCache) }
                catch { workbenchFailure = .init(kind: .transport, message: "确认已被拒绝，账单刷新失败，请重试刷新。") }
                await reloadWorkbench()
            }
            previewFailure = failure
            localFailure = failure
            return
        }
        if let id = confirmationJournalID { services.pendingWrites.markUnknown(id) }
        confirmationMayBeInFlight = false; phase = .responseUnknown
        previewFailure = failure
    }
    private func acceptConfirmation(_ value: V15StatementConfirmationReceipt) async throws {
        guard value.batchID == batch?.id else { throw V15Failure(kind: .decoding, message: "确认回执归属不匹配。") }
        if let id = confirmationJournalID { try services.pendingWrites.complete(id) }
        confirmationJournalID = nil; confirmationKey = nil; confirmationMayBeInFlight = false
        let token = generation
        receipt = value
        previewFailure = nil
        phase = value.status == "partially_confirmed" ? .ready : .completed(value)
        do {
            let fresh = try await services.statementImports.statement(id: value.batchID, readCachePolicy: .reloadIgnoringCache)
            guard token == generation, batch?.id == value.batchID else { return }
            batch = fresh
            await reloadWorkbench()
            guard token == generation, batch?.id == value.batchID else { return }
            selectedRowIDs.subtract(value.confirmedRowIDs)
            receipt = value
            phase = value.status == "partially_confirmed" ? .ready : .completed(value)
        } catch { workbenchFailure = .init(kind: .transport, message: "确认已经完成，复核列表刷新失败。") }
    }
    public func readConfirmationReceipt() async {
        guard let batch, let key = confirmationKey, case .responseUnknown = phase else { return }
        generation &+= 1; let token = generation
        do {
            let value = try await services.statementImports.confirmationReceipt(importID: batch.id, idempotencyKey: key, readCachePolicy: .reloadIgnoringCache)
            guard token == generation else { return }
            try await acceptConfirmation(value)
        } catch {
            guard token == generation else { return }
            // A missing receipt cannot prove a financial write was never executed.
            phase = .responseUnknown
            previewFailure = .init(kind: .responseUnknown, message: "尚未取得原确认回执，请继续检查；不会创建新的确认请求。")
        }
    }
    /// Explicit recovery may resend the exact journal request, after checking its receipt.
    public func recoverOriginalConfirmation() async {
        guard case .responseUnknown = phase, !isOffline, !isDisplayOnly,
              let batch, let id = confirmationJournalID, let item = services.pendingWrites.item(id),
              item.resourceID == batch.id, let payload = item.payload else { return }
        do {
            let known = try await services.statementImports.confirmationReceipt(importID: batch.id, idempotencyKey: item.idempotencyKey, readCachePolicy: .reloadIgnoringCache)
            try await acceptConfirmation(known)
            return
        } catch let failure as V15Failure where failure.code == "statement_import_confirmation_receipt_not_found" {
            // This does not assert non-execution. The original idempotency key protects replay.
        } catch { return }
        generation &+= 1; let token = generation
        do {
            let original = try JSONDecoder().decode(V15StatementConfirmRequest.self, from: JSONEncoder().encode(payload))
            try services.pendingWrites.markInFlight(id)
            confirmationMayBeInFlight = true; phase = .confirming
            let value = try await services.statementImports.confirm(importID: batch.id, serverRequest: original, idempotencyKey: item.idempotencyKey)
            guard token == generation else { return }
            try await acceptConfirmation(value)
        } catch {
            guard token == generation else { return }
            await handleConfirmationFailure(error, recoveringUnknown: true)
        }
    }
    /// Dismissing a sheet never silently cancels a possibly delivered confirm.
    /// Before any confirm wire exists it is an explicit no-write cancellation;
    /// after that point the retained key can only read the receipt.
    public func dismissPreview() {
        switch activeMutation {
        case .confirm:
            guard !confirmationMayBeInFlight else { return }
            mutationTask?.cancel(); mutationTask = nil; activeMutation = nil
            confirmationKey = nil; phase = .ready
        case .preview:
            mutationTask?.cancel(); mutationTask = nil; activeMutation = nil
            previewFailure = nil
            if receipt == nil { invalidatePreview() }
        default:
            if receipt == nil { invalidatePreview() }
        }
    }
    public func retryFromFailure() {
        guard case .failed(let failure) = phase else { return }
        if failure.code == "resolution_response_unknown", resolutionOwner != nil {
            requestResolutionReadback()
            return
        }
        if failure.code == "provider_attempt_failed", batch != nil {
            localTask = Task { [weak self] in try? await self?.loadProviderAuthorization() }
            return
        }
        if failure.kind == .responseUnknown { return }
        fieldIssues = []
        phase = .idle
    }
    /// A resolution has no idempotency key. Recovery is deliberately an
    /// owner-scoped, unfiltered fresh workbench scan, never a second PUT
    /// reconstructed from editor state or a read of the visible filter only.
    public func requestResolutionReadback() {
        guard resolutionOwner != nil, !isOffline, !isResolutionReadbackInFlight else { return }
        resolutionReadbackGeneration &+= 1
        let token = resolutionReadbackGeneration
        isResolutionReadbackInFlight = true
        resolutionReadbackMessage = "正在读取完整复核行以确认处理结果；不会重复提交。"
        resolutionReadbackTask?.cancel()
        resolutionReadbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.readResolutionOutcome(token: token)
        }
    }
    private func readResolutionOutcome(token: UInt64) async {
        guard let owner = resolutionOwner, owner.batchID == batch?.id else { return }
        do {
            var cursor = 0
            while true {
                try Task.checkCancellation()
                let board = try await services.statementImports.workbench(importID: owner.batchID, cursor: cursor, filters: nil, readCachePolicy: .reloadIgnoringCache)
                guard token == resolutionReadbackGeneration, resolutionOwner == owner else { return }
                if let row = board.rows.first(where: { $0.id == owner.rowID }) {
                    guard owner.isConfirmed(by: row, batchVersion: board.batchVersion) else {
                        retainResolutionUnknown(owner, message: "最新复核行仍不足以确认结果；可以重新读取，不会重复提交。", token: token)
                        return
                    }
                    let freshBatch = try await services.statementImports.statement(id: owner.batchID, readCachePolicy: .reloadIgnoringCache)
                    guard token == resolutionReadbackGeneration, resolutionOwner == owner, freshBatch.version >= board.batchVersion else { return }
                    batch = freshBatch
                    mergeRecoveredResolution(row, from: board)
                    resolutionMayBeInFlight = false
                    resolutionOwner = nil
                    isResolutionReadbackInFlight = false
                    resolutionReadbackTask = nil
                    resolutionReadbackMessage = "已在完整复核行中确认处理结果；当前筛选与页面保持不变。"
                    if case .failed(let failure) = phase, failure.code == "resolution_response_unknown" { phase = .ready }
                    return
                }
                guard let nextCursor = board.nextCursor else {
                    retainResolutionUnknown(owner, message: "未在完整复核行中找到原处理行；仅可重试读取，不会重复提交。", token: token)
                    return
                }
                guard nextCursor > cursor else {
                    retainResolutionUnknown(owner, message: "复核列表暂时无法安全继续；可以重新读取，不会重复提交。", token: token)
                    return
                }
                cursor = nextCursor
            }
        } catch is CancellationError {
            guard token == resolutionReadbackGeneration, resolutionOwner == owner else { return }
            isResolutionReadbackInFlight = false
            resolutionReadbackTask = nil
            resolutionReadbackMessage = "恢复读取已取消；只能重新读取完整复核行，不会重复提交。"
        } catch let failure as V15Failure {
            retainResolutionUnknown(owner, message: "恢复读取失败：\(failure.message)；仅可重试读取，不会重复提交。", token: token)
        } catch {
            retainResolutionUnknown(owner, message: "恢复读取失败；仅可重试读取，不会重复提交。", token: token)
        }
    }
    private func retainResolutionUnknown(_ owner: ResolutionOwner, message: String, token: UInt64) {
        guard token == resolutionReadbackGeneration, resolutionOwner == owner else { return }
        isResolutionReadbackInFlight = false
        resolutionReadbackTask = nil
        resolutionReadbackMessage = message
        phase = .failed(.init(kind: .responseUnknown, code: "resolution_response_unknown", message: message))
    }
    private func mergeRecoveredResolution(_ row: V15StatementWorkbenchRow, from fresh: V15StatementWorkbench) {
        guard let current = workbench, current.batchID == fresh.batchID else { return }
        workbench = .init(batchID: current.batchID, batchVersion: fresh.batchVersion, status: fresh.status, reviewAvailable: fresh.reviewAvailable, validationRunID: fresh.validationRunID, checks: fresh.checks, rows: current.rows.map { $0.id == row.id ? row : $0 }, nextCursor: current.nextCursor, sourceUnavailableCount: current.sourceUnavailableCount)
    }
    private func providerAuthorizationChanged() { if case .awaitingProviderConsent = phase { providerOwner = nil } else if providerAuthorized { providerAuthorized = false } }
    private var currentPreviewFingerprint: PreviewFingerprint? { guard let batch, let workbench else { return nil }; return .init(batchVersion: batch.version, workbenchVersion: workbench.batchVersion, selectedRows: selectedRows.sorted { $0.id.uuidString < $1.id.uuidString }.map { .init(id: $0.id, rowVersion: $0.rowVersion, draftVersion: $0.draft?.version ?? 0, finalCreateDraftVersion: $0.finalCreateDraftVersion) }) }
    private func invalidatePreview() { preview = nil; previewFingerprint = nil; previewFailure = nil; receipt = nil; if case .completed = phase { phase = .ready } }
    private func fail(_ failure: V15Failure) { fieldIssues = failure.fieldIssues; phase = failure.kind == .cancelled ? .idle : .failed(failure) }
    private static func syntheticDocument() -> V15StatementLocalDocument { let digest = String(repeating: "a", count: 64); let box = V15StatementBoundingBox(x: 0.08, y: 0.16, width: 0.76, height: 0.12); let page = V15StatementEvidencePage(pageNumber: 1, sourceKind: "text", evidenceTextMasked: "合成账单 · ••••-••-•• 工作餐 ••.••", boundingBoxes: [box]); let row = V15StatementEvidenceRow(rowNumber: 1, pageNumber: 1, evidenceTextMasked: "合成交易 ••.••", boundingBox: box); return .init(sha256: digest, byteSize: 512, pageCount: 1, evidence: .init(expectedVersion: 1, attemptID: UUID(), pages: [page], rows: [row])) }
}

private extension Optional where Wrapped == Bool { var isTrue: Bool { self == true } }
