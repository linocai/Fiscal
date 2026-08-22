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
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard url.isFileURL else { throw V15StatementLocalError.unsupported }
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey]); guard values.isRegularFile == true else { throw V15StatementLocalError.unavailable }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fiscal-statement-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let copy = directory.appendingPathComponent("source.pdf")
            try FileManager.default.copyItem(at: url, to: copy); try Task.checkCancellation()
            let data = try Data(contentsOf: copy, options: [.mappedIfSafe]); defer { _ = data }
            guard let pdf = PDFDocument(url: copy), !pdf.isLocked, pdf.pageCount > 0 else { throw V15StatementLocalError.unsupported }
            var hasher = SHA256(); hasher.update(data: data)
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            var pages: [V15StatementEvidencePage] = []; var rows: [V15StatementEvidenceRow] = []
            for index in 0..<pdf.pageCount {
                try Task.checkCancellation()
                let source = pdf.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
                let masked = source.map(Self.mask)
                pages.append(.init(pageNumber: index + 1, sourceKind: source?.isEmpty == false ? "text" : "unsupported", evidenceTextMasked: masked?.isEmpty == false ? masked : nil, boundingBoxes: masked?.isEmpty == false ? [.init(x: 0, y: 0, width: 1, height: 1)] : []))
                if let masked, !masked.isEmpty { rows.append(.init(rowNumber: rows.count + 1, pageNumber: index + 1, evidenceTextMasked: masked, boundingBox: .init(x: 0, y: 0, width: 1, height: 1))) }
            }
            return .init(sha256: digest, byteSize: data.count, pageCount: pdf.pageCount, evidence: .init(expectedVersion: expectedVersion, attemptID: attemptID, pages: pages, rows: rows))
        }.value
    }
    private static func mask(_ source: String) -> String { source.replacingOccurrences(of: "[0-9]", with: "•", options: .regularExpression).prefix(20_000).description }
}

@MainActor @Observable
public final class V15StatementImportModel {
    public enum Phase: Equatable { case idle, localProcessing, registering, extracting, awaitingProviderConsent, parsing, providerResponseUnknown, reviewing, ready, confirming, responseUnknown, completed(V15StatementConfirmationReceipt), failed(V15Failure) }
    public private(set) var phase: Phase = .idle
    public private(set) var batch: V15StatementImport?
    public private(set) var workbench: V15StatementWorkbench?
    public private(set) var selectedRowIDs = Set<UUID>()
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
    public var providerAuthorized = false { didSet { if oldValue != providerAuthorized { providerAuthorizationChanged() } } }
    private let services: V15Services
    private let processor: any V15StatementLocalProcessing
    private let offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)?
    private var localDocument: V15StatementLocalDocument?
    private var evidenceSHA256: String?
    private var providerSnapshotID: UUID?
    private struct ProviderAttemptOwner: Sendable, Equatable { let batchID: UUID; let expectedVersion: Int; let evidenceSHA256: String; let authorization: V15StatementProviderAuthorization; let idempotencyKey: UUID }
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
    private var isDisplayOnly: Bool { batch?.status.isDisplayOnly == true || workbench?.status.isDisplayOnly == true || preview?.status.isDisplayOnly == true }
    public var selectedRows: [V15StatementWorkbenchRow] { (workbench?.rows ?? []).filter { selectedRowIDs.contains($0.id) } }
    private var activeMutationMayProceed: Bool { writeReasons.allSatisfy { $0.code == "mutation_in_progress" } }
    public var isPreviewLoading: Bool { activeMutation == .preview }
    public var isConfirmationInFlight: Bool { activeMutation == .confirm }
    public var writeReasons: [V15DisabledReason] { var result: [V15DisabledReason] = []; if isOffline { result.append(.init(code: "offline_read_only", message: "离线快照不能导入或确认账单。", fieldPath: nil)) }; if batch?.status.isDisplayOnly == true || workbench?.status.isDisplayOnly == true || preview?.status.isDisplayOnly == true { result.append(.init(code: "unknown_import_status", message: "服务器返回未知账单状态；当前仅可展示，不能写入。", fieldPath: nil)) }; if activeMutation != nil { result.append(.init(code: "mutation_in_progress", message: "当前写入仍在进行；请等待结果或先读取安全恢复状态。", fieldPath: nil)) }; if case .responseUnknown = phase { result.append(.init(code: "response_unknown", message: "确认结果未知，请先用同一请求凭证读取收据。", fieldPath: nil)) }; if case .providerResponseUnknown = phase { result.append(.init(code: "provider_response_unknown", message: "解析结果未知；只能使用同一授权和请求凭证恢复。", fieldPath: nil)) }; if case .failed(let failure) = phase, failure.kind == .responseUnknown { result.append(.init(code: "lifecycle_response_unknown", message: "离开时请求结果未知；请重新读取服务器状态后再操作。", fieldPath: nil)) }; return result }
    public var previewReasons: [V15DisabledReason] { var result = writeReasons; if selectedRowIDs.isEmpty { result.append(.init(code: "selection_required", message: "请选择要确认的行。", fieldPath: "rows")) }; if selectedRows.contains(where: { !$0.draft.map(\.resolution.isExecutable).isTrue }) { result.append(.init(code: "unresolved_selected", message: "所选行仍未完成处理。", fieldPath: "rows")) }; return result }
    public var confirmReasons: [V15DisabledReason] { var result = writeReasons; if preview == nil || previewFingerprint != currentPreviewFingerprint { result.append(.init(code: "preview_required", message: "复核行已刷新；请重新获取服务器确认预览。", fieldPath: nil)) }; return result }

    public func selectFile(url: URL) { guard writeReasons.isEmpty else { return }; cancelLocalAndDiscard(); generation &+= 1; let token = generation; phase = .localProcessing
        localTask = Task { [weak self] in guard let self else { return }; do {
            // First derive only metadata; the evidence request gets its server attempt/version later.
            let metadata = try await self.processor.process(url: url, attemptID: UUID(), expectedVersion: 1)
            guard token == self.generation else { return }; self.localDocument = metadata; await self.registerAndExtract(token: token)
        } catch is CancellationError { guard token == self.generation else { return }; self.phase = .idle
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
            fail(.init(kind: .responseUnknown, code: "lifecycle_response_unknown", message: "页面离开时服务器写入结果未知；请重新读取后再操作。"))
        default:
            evidenceSHA256 = nil; providerSnapshotID = nil; providerOwner = nil; providerAuthorized = false
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
    public func requestPreview() { runMutation(.preview) { await self.previewConfirmation() } }
    public func requestConfirm() { runMutation(.confirm) { await self.confirm() } }
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

    private func registerAndExtract(token: UInt64) async { guard let localDocument, !isOffline else { return }; do {
        phase = .registering; let registered = try await services.statementImports.register(.init(documentSHA256: localDocument.sha256, byteSize: localDocument.byteSize, pageCount: localDocument.pageCount, displayName: "statement.pdf")); guard token == generation else { return }; batch = registered.value; if registered.value.status.isDisplayOnly { phase = .ready; return }
        phase = .extracting; let attempt = try await services.statementImports.startExtraction(importID: registered.value.id, expectedVersion: registered.value.version); guard token == generation else { return }
        let fresh = try await services.statementImports.statement(id: registered.value.id, readCachePolicy: .reloadIgnoringCache); guard token == generation else { return }; batch = fresh
        let evidence = V15StatementEvidenceSubmission(expectedVersion: fresh.version, attemptID: attempt.id, pages: localDocument.evidence.pages, rows: localDocument.evidence.rows)
        let accepted = try await services.statementImports.submitEvidence(importID: fresh.id, request: evidence); guard token == generation else { return }; batch = accepted.batch; evidenceSHA256 = accepted.evidenceSHA256; phase = .awaitingProviderConsent
    } catch let failure as V15Failure { guard token == generation else { return }; fail(failure) } catch { guard token == generation else { return }; fail(.init(kind: .transport, message: "账单导入请求失败。")) } }

    public func startProviderAttempt() async { guard providerAuthorized, case .awaitingProviderConsent = phase, let batch, let evidenceSHA256, let localDocument, activeMutationMayProceed else { return }; let pages = localDocument.evidence.pages.map(\.pageNumber); let authorization = V15StatementProviderAuthorization(confirmed: true, provider: "synthetic_statement", providerModel: "synthetic-statement-v1", promptVersion: "statement-p26-v1", schemaVersion: "statement-provider-v1", evidenceSHA256: evidenceSHA256, pageNumbers: pages, rowCount: localDocument.evidence.rows.count, redactionVersion: "statement-redaction-v1", redactionCount: localDocument.evidence.rows.count); let owner = ProviderAttemptOwner(batchID: batch.id, expectedVersion: batch.version, evidenceSHA256: evidenceSHA256, authorization: authorization, idempotencyKey: UUID()); providerOwner = owner; await performProviderAttempt(owner)
    }
    /// Provider attempts are idempotent. A cancelled/unknown response reuses
    /// exactly the captured authorization, expected version, evidence digest,
    /// and key; it never creates a silent second parse intent.
    public func recoverProviderAttempt() async { guard let owner = providerOwner, case .providerResponseUnknown = phase, !isOffline, !isDisplayOnly else { return }; await performProviderAttempt(owner) }
    private func performProviderAttempt(_ owner: ProviderAttemptOwner) async { guard batch?.id == owner.batchID else { return }; generation &+= 1; let token = generation; phase = .parsing
        do { let value = try await services.statementImports.providerAttempt(importID: owner.batchID, request: .init(expectedVersion: owner.expectedVersion, evidenceSHA256: owner.evidenceSHA256, authorization: owner.authorization), idempotencyKey: owner.idempotencyKey); guard token == generation else { return }; guard value.executionScope == "request_bound", let snapshot = UUID(uuidString: value.providerAttemptID) else { fail(.init(kind: .decoding, code: "provider_scope_invalid", message: "服务端未确认本次解析是请求内执行。")); return }; guard value.providerStatus == "succeeded" else { fail(.init(kind: .transport, code: "provider_attempt_failed", message: "服务端已确认解析失败；请检查脱敏证据后重新发起新的授权。")); return }; providerSnapshotID = snapshot; self.localDocument = nil; providerOwner = nil; phase = .reviewing
        } catch let failure as V15Failure { guard token == generation else { return }; if failure.kind == .responseUnknown || failure.kind == .cancelled || failure.kind == .decoding { phase = .providerResponseUnknown } else { fail(failure) } } catch { guard token == generation else { return }; phase = .providerResponseUnknown }
    }
    public func runValidation() async { guard case .reviewing = phase, let batch, let providerSnapshotID, activeMutationMayProceed else { return }; generation &+= 1; let token = generation
        do { let review = try await services.statementImports.validationRun(importID: batch.id, request: .init(expectedBatchVersion: batch.version, providerSnapshotID: providerSnapshotID)); guard token == generation else { return }; let board = try await services.statementImports.workbench(importID: batch.id, cursor: 0, filters: workbenchFilter, readCachePolicy: .reloadIgnoringCache); guard token == generation else { return }; guard review.batchID == board.batchID else { fail(.init(kind: .decoding, code: "review_owner_mismatch", message: "复核结果不属于当前账单。")); return }; self.batch = try await services.statementImports.statement(id: batch.id, readCachePolicy: .reloadIgnoringCache); workbench = board; workbenchFailure = nil; selectedRowIDs = Set(board.rows.filter { $0.draft?.resolution.isExecutable == true }.map(\.id)); phase = .ready
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
                selectedRowIDs = selectedRowIDs.intersection(Set(board.rows.map(\.id)))
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
    public func toggleRow(_ id: UUID) { guard writeReasons.isEmpty, workbench?.rows.contains(where: { $0.id == id }) == true else { return }; if selectedRowIDs.contains(id) { selectedRowIDs.remove(id) } else { selectedRowIDs.insert(id) }; invalidatePreview() }
    public func resolve(row: V15StatementWorkbenchRow, as resolution: V15StatementResolution) async {
        guard let batch, activeMutationMayProceed else { return }
        if case .unknown = resolution { return }
        let request = V15StatementDraftResolutionPut(expectedBatchVersion: batch.version, expectedRowVersion: row.rowVersion, expectedResolutionVersion: row.draft?.version ?? 0, resolution: resolution, matchedTransactionID: resolution == .matchExisting ? row.candidates.first?.transactionID : nil, ignoredReason: resolution == .ignoreIntentional ? "人工确认忽略" : nil)
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
    public func previewConfirmation() async { guard let batch, !isDisplayOnly, activeMutation == nil || activeMutation == .preview else { return }; previewFailure = nil; generation &+= 1; let token = generation; let fingerprint = currentPreviewFingerprint; guard fingerprint != nil else { return }; do { let value = try await services.statementImports.confirmationPreview(importID: batch.id, rowIDs: selectedRowIDs.sorted { $0.uuidString < $1.uuidString }); guard token == generation, fingerprint == currentPreviewFingerprint else { return }; guard Set(value.request.rows.map(\.rowID)) == selectedRowIDs else { previewFailure = .init(kind: .decoding, code: "preview_selection_mismatch", message: "服务器确认预览与当前选择不一致。"); return }; preview = value; previewFingerprint = fingerprint; phase = .ready } catch let failure as V15Failure { guard token == generation else { return }; previewFailure = failure; phase = .ready } catch { guard token == generation else { return }; previewFailure = .init(kind: .transport, message: "确认预览失败。"); phase = .ready } }
    public func confirm() async { guard let batch, let preview, activeMutationMayProceed, previewFingerprint == currentPreviewFingerprint, confirmReasons.filter({ $0.code != "mutation_in_progress" }).isEmpty else { return }; let key = UUID(); confirmationKey = key; confirmationMayBeInFlight = true; generation &+= 1; let token = generation; phase = .confirming; do { let value = try await services.statementImports.confirm(importID: batch.id, serverRequest: preview.request, idempotencyKey: key); guard token == generation else { return }; confirmationMayBeInFlight = false; await reloadWorkbench(); guard token == generation else { return }; receipt = value; phase = .completed(value) } catch let failure as V15Failure { guard token == generation else { return }; confirmationMayBeInFlight = false; if failure.kind == .responseUnknown || failure.kind == .cancelled || failure.kind == .decoding { phase = .responseUnknown } else { fail(failure) } } catch { guard token == generation else { return }; confirmationMayBeInFlight = false; phase = .responseUnknown } }
    public func readConfirmationReceipt() async { guard let batch, let key = confirmationKey, case .responseUnknown = phase else { return }; generation &+= 1; let token = generation; do { let value = try await services.statementImports.confirmationReceipt(importID: batch.id, idempotencyKey: key, readCachePolicy: .reloadIgnoringCache); guard token == generation else { return }; await reloadWorkbench(); guard token == generation else { return }; receipt = value; phase = .completed(value) } catch let failure as V15Failure { guard token == generation else { return }; if failure.kind != .cancelled { fail(failure) } } catch { guard token == generation else { return }; fail(.init(kind: .transport, message: "同一请求凭证的确认收据读取失败。")) } }
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
                        retainResolutionUnknown(owner, message: "最新复核行版本或处理事实尚未足以确认结果；仅可重试读取，不会重复提交。", token: token)
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
                    retainResolutionUnknown(owner, message: "服务器返回的复核分页无法安全继续；仅可重试读取，不会重复提交。", token: token)
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
    private func providerAuthorizationChanged() { if case .awaitingProviderConsent = phase { providerOwner = nil } else { providerAuthorized = false } }
    private var currentPreviewFingerprint: PreviewFingerprint? { guard let batch, let workbench else { return nil }; return .init(batchVersion: batch.version, workbenchVersion: workbench.batchVersion, selectedRows: selectedRows.sorted { $0.id.uuidString < $1.id.uuidString }.map { .init(id: $0.id, rowVersion: $0.rowVersion, draftVersion: $0.draft?.version ?? 0, finalCreateDraftVersion: $0.finalCreateDraftVersion) }) }
    private func invalidatePreview() { preview = nil; previewFingerprint = nil; previewFailure = nil; receipt = nil; if case .completed = phase { phase = .ready } }
    private func fail(_ failure: V15Failure) { fieldIssues = failure.fieldIssues; phase = failure.kind == .cancelled ? .idle : .failed(failure) }
    private static func syntheticDocument() -> V15StatementLocalDocument { let digest = String(repeating: "a", count: 64); let box = V15StatementBoundingBox(x: 0.08, y: 0.16, width: 0.76, height: 0.12); let page = V15StatementEvidencePage(pageNumber: 1, sourceKind: "text", evidenceTextMasked: "合成账单 · ••••-••-•• 工作餐 ••.••", boundingBoxes: [box]); let row = V15StatementEvidenceRow(rowNumber: 1, pageNumber: 1, evidenceTextMasked: "合成交易 ••.••", boundingBox: box); return .init(sha256: digest, byteSize: 512, pageCount: 1, evidence: .init(expectedVersion: 1, attemptID: UUID(), pages: [page], rows: [row])) }
}

private extension Optional where Wrapped == Bool { var isTrue: Bool { self == true } }
