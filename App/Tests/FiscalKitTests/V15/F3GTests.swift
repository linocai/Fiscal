import Foundation
import PDFKit
import Testing
@testable import FiscalKit

@Suite("F3-G typed statement import")
struct F3GTests {
    private struct NamedProcessor: V15StatementLocalProcessing {
        func process(url: URL, attemptID: UUID, expectedVersion: Int) async throws -> V15StatementLocalDocument {
            .init(sha256: String(repeating: "c", count: 64), byteSize: 19, pageCount: 1, evidence: .init(expectedVersion: expectedVersion, attemptID: attemptID, pages: [], rows: []))
        }
    }
    @MainActor private func settled(_ model: V15StatementImportModel) async {
        for _ in 0..<80 {
            if model.phase != .localProcessing && model.phase != .registering && model.phase != .extracting { return }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }
    @MainActor private func ready(_ transport: F3GTransport = .init(mode: .normal), offline: Bool = false) async -> V15StatementImportModel {
        let model = V15StatementImportModel(services: .init(transport: transport), offlineSnapshotAt: offline ? Date(timeIntervalSince1970: 1_786_464_000) : nil)
        model.startSyntheticGallery(); await settled(model)
        model.providerAuthorized = true; await model.startProviderAttempt(); await model.runValidation()
        return model
    }

    @Test("register wire is metadata-only and masked evidence has no raw document surface")
    @MainActor func metadataOnly() async throws {
        let transport = F3GTransport(mode: .normal); let model = await ready(transport)
        let writes = await transport.recordedWrites()
        let registration = try #require(writes.first { $0.request.path == "statement-imports" })
        #expect(registration.body.contains("document_sha256"))
        #expect(registration.body.contains("byte_size"))
        #expect(!registration.body.lowercased().contains("data"))
        #expect(!registration.body.lowercased().contains("image"))
        let evidence = try #require(writes.first { $0.request.path.hasSuffix("/evidence") })
        #expect(evidence.body.contains("evidence_text_masked"))
        #expect(evidence.body.contains("bounding_box"))
        #expect(!evidence.body.contains("source.pdf"))
        #expect(model.workbench?.rows.count == 1)
    }

    @Test("provider unknown recovery reuses exact request-bound authorization, body and key")
    @MainActor func providerSameKeyRecovery() async {
        let transport = F3GTransport(mode: .providerUnknown); let model = V15StatementImportModel(services: .init(transport: transport))
        model.startSyntheticGallery(); await settled(model); model.providerAuthorized = true
        await model.startProviderAttempt()
        guard case .providerResponseUnknown = model.phase else { Issue.record("provider transport unknown must retain owner"); return }
        await model.recoverProviderAttempt()
        let wires = await transport.recordedWrites().filter { $0.request.path.hasSuffix("/provider-attempts") }
        #expect(wires.count == 2)
        #expect(wires.first?.request.headers["Idempotency-Key"] != nil)
        #expect(wires.first?.request.headers["Idempotency-Key"] == wires.last?.request.headers["Idempotency-Key"])
        #expect(wires.first?.body == wires.last?.body)
        #expect(wires.first?.body.contains("evidence_sha256") == true)
        #expect(model.phase == .reviewing)
    }

    @Test("preview is server-derived, selection invalidates it, and confirmation sends exact request")
    @MainActor func previewExactPayload() async throws {
        let transport = F3GTransport(mode: .normal); let model = await ready(transport)
        await model.previewConfirmation(); let preview = try #require(model.preview)
        #expect(preview.request.expectedBatchVersion == 5)
        #expect(preview.amounts.unknownSelectedCount == 0)
        model.toggleRow(V15F3GFixtures.rowID); #expect(model.preview == nil)
        model.toggleRow(V15F3GFixtures.rowID); await model.previewConfirmation(); await model.confirm()
        let confirm = try #require((await transport.recordedWrites()).last { $0.request.path.hasSuffix("/confirm") })
        #expect(confirm.body.contains("expected_batch_version"))
        #expect(confirm.body.contains("expected_final_create_draft_version"))
        #expect(model.receipt?.createdCount == 1)
    }

    @Test("confirmation unknown only reads same key receipt and never blindly creates a new key")
    @MainActor func confirmationUnknownReadback() async throws {
        let transport = F3GTransport(mode: .unknown); let model = await ready(transport)
        await model.previewConfirmation(); await model.confirm()
        guard case .responseUnknown = model.phase else { Issue.record("must retain confirmation unknown state"); return }
        let before = await transport.recordedWrites().filter { $0.request.path.hasSuffix("/confirm") }
        await model.readConfirmationReceipt()
        let after = await transport.recordedWrites().filter { $0.request.path.hasSuffix("/confirm") }
        #expect(before.count == 1); #expect(after.count == 1)
        #expect(model.receipt?.replay == true)
    }

    @Test("offline has zero mutation wires and unknown resolution remains display-only")
    @MainActor func offlineAndForwardSafety() async throws {
        let transport = F3GTransport(mode: .normal); let model = V15StatementImportModel(services: .init(transport: transport), offlineSnapshotAt: Date(timeIntervalSince1970: 1_786_464_000))
        model.startSyntheticGallery(); try? await Task.sleep(for: .milliseconds(60))
        #expect(await transport.recordedWrites().isEmpty)
        let unknown = try V15FixtureCodec.decoder.decode(V15StatementResolution.self, from: Data("\"future_resolution\"".utf8))
        #expect(!unknown.isExecutable)
    }

    @Test("synthetic PDF extraction releases its private temporary workspace and emits only masked evidence")
    func localPDFCleanup() async throws {
        let root = FileManager.default.temporaryDirectory
        let before = Set((try FileManager.default.contentsOfDirectory(atPath: root.path)).filter { $0.hasPrefix("fiscal-statement-") })
        let fixture = root.appendingPathComponent("f3g-synthetic-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let document = PDFDocument(); document.insert(PDFPage(), at: 0)
        #expect(document.write(to: fixture))
        let output = try await V15PDFStatementProcessor().process(url: fixture, attemptID: UUID(), expectedVersion: 1)
        #expect(output.evidence.pages.allSatisfy { $0.evidenceTextMasked?.contains("4111") != true })
        let after = Set((try FileManager.default.contentsOfDirectory(atPath: root.path)).filter { $0.hasPrefix("fiscal-statement-") })
        #expect(after == before)
    }

    @Test("the local filename never crosses the registration boundary")
    @MainActor func filenameNeverOnWire() async throws {
        let transport = F3GTransport(mode: .normal)
        let model = V15StatementImportModel(services: .init(transport: transport), processor: NamedProcessor())
        model.selectFile(url: URL(fileURLWithPath: "/private/tmp/Payroll-Alice-2026.pdf")); await settled(model)
        let registration = try #require((await transport.recordedWrites()).first { $0.request.path == "statement-imports" })
        #expect(registration.body.contains("statement.pdf"))
        #expect(!registration.body.contains("Payroll-Alice-2026.pdf"))
    }

    @Test("unknown batch workbench and preview statuses are uniformly display-only with zero later writes")
    @MainActor func futureStatusStopsWrites() async throws {
        let futureBatch = F3GTransport(mode: .futureBatch); let batchModel = V15StatementImportModel(services: .init(transport: futureBatch))
        batchModel.startSyntheticGallery(); await settled(batchModel)
        #expect(batchModel.writeReasons.contains(where: { $0.code == "unknown_import_status" }))
        #expect((await futureBatch.recordedWrites()).count == 1)

        let futureWorkbench = F3GTransport(mode: .futureWorkbench); let boardModel = await ready(futureWorkbench)
        let beforeBoard = await futureWorkbench.recordedWrites().count
        let row = try #require(boardModel.workbench?.rows.first)
        await boardModel.resolve(row: row, as: .createNew); await boardModel.previewConfirmation()
        #expect((await futureWorkbench.recordedWrites()).count == beforeBoard)

        let futurePreview = F3GTransport(mode: .futurePreview); let previewModel = await ready(futurePreview)
        await previewModel.previewConfirmation(); let beforeConfirm = await futurePreview.recordedWrites().count
        await previewModel.confirm()
        #expect(previewModel.writeReasons.contains(where: { $0.code == "unknown_import_status" }))
        #expect((await futurePreview.recordedWrites()).count == beforeConfirm)
    }

    @Test("workbench filters and integer cursor retain prior rows on a local next-page failure")
    @MainActor func workbenchPagination() async throws {
        let paged = F3GTransport(mode: .paged); let model = await ready(paged)
        #expect(model.workbench?.nextCursor == 1)
        await model.setWorkbenchEvidenceFilter("available")
        let filterRequest = try #require((await paged.recordedRequests()).last { $0.path.hasSuffix("/review-workbench") })
        let filterJSON = try #require(filterRequest.query.first(where: { $0.name == "filters" })?.value)
        #expect(filterJSON.contains("evidence_state"))
        #expect(!filterJSON.contains("evidenceState"))
        #expect(model.workbench?.rows.map(\.id) == [V15F3GFixtures.rowID])
        await model.loadNextWorkbench()
        #expect(model.workbench?.rows.map(\.id) == [V15F3GFixtures.rowID, V15F3GFixtures.secondRowID])

        let failing = F3GTransport(mode: .pageFailure); let failed = await ready(failing); let prior = failed.workbench?.rows
        await failed.loadNextWorkbench()
        #expect(failed.workbench?.rows == prior)
        #expect(failed.workbenchFailure?.message == "下一页读取失败。")
    }

    @Test("workbench filter query uses every backend snake_case key and fixture rejects camelCase")
    @MainActor func workbenchFilterWire() async throws {
        let transport = F3GTransport(mode: .normal)
        let services = V15Services(transport: transport)
        let board = try await services.statementImports.workbench(importID: V15F3GFixtures.batchID, filters: .init(candidateKind: "existing_transaction", checkStatus: "passed", evidenceState: "available"))
        #expect(board.rows.map(\.id) == [V15F3GFixtures.rowID])
        let request = try #require((await transport.recordedRequests()).last)
        let encoded = try #require(request.query.first(where: { $0.name == "filters" })?.value)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        #expect(object["candidate_kind"] as? String == "existing_transaction")
        #expect(object["check_status"] as? String == "passed")
        #expect(object["evidence_state"] as? String == "available")
        #expect(object["candidateKind"] == nil)
        #expect(object["checkStatus"] == nil)
        #expect(object["evidenceState"] == nil)
    }

    @Test("masked page retry remains local to the workbench")
    @MainActor func pageReadFailureIsLocalAndRetryable() async throws {
        let transport = F3GTransport(mode: .pageReadFailure)
        let model = await ready(transport)
        let board = try #require(model.workbench)
        await model.loadPage(1)
        #expect(model.page == nil)
        #expect(model.pageFailure?.message == "脱敏页面读取失败。")
        #expect(model.workbench == board)
        #expect(model.phase == .ready)
        await model.loadPage(1)
        #expect(model.page?.pageNumber == 1)
        #expect(model.pageFailure == nil)
        #expect(model.workbench == board)
        #expect(model.phase == .ready)
    }

    @Test("owned provider work cancels before wire, and after wire remains same-key recoverable")
    @MainActor func lifecycleCancellationOwnership() async {
        let prewire = F3GTransport(mode: .normal); let preModel = V15StatementImportModel(services: .init(transport: prewire))
        preModel.startSyntheticGallery(); await settled(preModel); preModel.providerAuthorized = true
        preModel.requestProviderAttempt(); preModel.sceneDidLeaveActive(); try? await Task.sleep(for: .milliseconds(60))
        #expect(!(await prewire.recordedWrites()).contains(where: { $0.request.path.hasSuffix("/provider-attempts") }))

        let delayed = F3GTransport(mode: .delayedProvider); let model = V15StatementImportModel(services: .init(transport: delayed))
        model.startSyntheticGallery(); await settled(model); model.providerAuthorized = true; model.requestProviderAttempt()
        for _ in 0..<40 where !(await delayed.hasProviderWireStarted()) { try? await Task.sleep(for: .milliseconds(10)) }
        model.sceneDidLeaveActive()
        #expect(model.phase == .providerResponseUnknown)
        await model.recoverProviderAttempt()
        let wires = await delayed.recordedWrites().filter { $0.request.path.hasSuffix("/provider-attempts") }
        #expect(wires.count == 2)
        #expect(wires.first?.request.headers["Idempotency-Key"] == wires.last?.request.headers["Idempotency-Key"])
    }

    @Test("confirmation sheet dismissal is a clear pre-wire cancel and a same-key post-wire receipt recovery")
    @MainActor func confirmationDismissalOwnership() async throws {
        let prewire = F3GTransport(mode: .normal); let preModel = await ready(prewire)
        await preModel.previewConfirmation(); preModel.requestConfirm(); preModel.dismissPreview()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(!(await prewire.recordedWrites()).contains(where: { $0.request.path.hasSuffix("/confirm") }))
        #expect(preModel.preview != nil)
        #expect(preModel.phase == .ready)

        let delayed = F3GTransport(mode: .delayedConfirm); let model = await ready(delayed)
        await model.previewConfirmation(); let exactRequest = try #require(model.preview?.request)
        model.requestConfirm()
        for _ in 0..<40 where !(await delayed.hasConfirmWireStarted()) { try? await Task.sleep(for: .milliseconds(10)) }
        model.dismissPreview() // A sheet close cannot stop a possibly delivered request.
        #expect(model.isConfirmationInFlight)
        model.sceneDidLeaveActive()
        #expect(model.phase == .responseUnknown)
        #expect(model.preview?.request == exactRequest)
        await model.readConfirmationReceipt()
        #expect(model.receipt?.replay == true)
        #expect((await delayed.recordedWrites()).filter { $0.request.path.hasSuffix("/confirm") }.count == 1)
    }

    @Test("preview owns visible loading and deterministic failure or conflict retry state")
    @MainActor func previewLoadingAndRetryState() async {
        let delayed = F3GTransport(mode: .delayedPreview); let delayedModel = await ready(delayed)
        delayedModel.requestPreview()
        #expect(delayedModel.isPreviewLoading)
        try? await Task.sleep(for: .milliseconds(5200))
        #expect(delayedModel.preview != nil)
        #expect(delayedModel.previewFailure == nil)

        let unavailable = F3GTransport(mode: .previewFailure); let unavailableModel = await ready(unavailable)
        await unavailableModel.previewConfirmation()
        #expect(unavailableModel.previewFailure?.message == "确认预览暂时不可用。")
        await unavailableModel.previewConfirmation()
        #expect(unavailableModel.preview != nil)

        let conflict = F3GTransport(mode: .previewConflict); let conflictModel = await ready(conflict)
        await conflictModel.previewConfirmation()
        #expect(conflictModel.previewFailure?.kind == .conflict)
        await conflictModel.previewConfirmation()
        #expect(conflictModel.preview != nil)
    }

    @Test("page, filter, reload, and next reads do not replace a delayed resolution owner")
    @MainActor func readsDoNotCancelPostWireResolution() async throws {
        let transport = F3GTransport(mode: .delayedResolution)
        let model = await ready(transport)
        let unresolved = try #require(model.workbench?.rows.first(where: { $0.id == V15F3GFixtures.unresolvedID }))

        model.requestResolution(row: unresolved, as: .createNew)
        for _ in 0..<40 where !(await transport.hasResolutionWireStarted()) { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(await transport.hasResolutionWireStarted())

        model.requestPage(1)
        try? await Task.sleep(for: .milliseconds(80))
        model.requestWorkbenchEvidenceFilter("available")
        try? await Task.sleep(for: .milliseconds(80))
        model.requestReloadWorkbench()
        try? await Task.sleep(for: .milliseconds(80))
        model.requestNextWorkbench()
        try? await Task.sleep(for: .milliseconds(2200))

        let requests = await transport.recordedRequests()
        #expect(requests.contains(where: { $0.path.hasSuffix("/review-workbench/pages/1") }))
        #expect(requests.filter { $0.path.hasSuffix("/review-workbench") }.count >= 4)
        #expect(model.page?.pageNumber == 1)
        #expect(model.workbenchFailure == nil)
        #expect(model.phase == .ready)
        #expect((await transport.recordedWrites()).filter { $0.request.path.hasSuffix("/draft-resolution") }.count == 1)
    }

    @Test("post-wire resolution cancellation recovers by readback and never replays the PUT")
    @MainActor func resolutionUnknownUsesReadbackOnly() async throws {
        let transport = F3GTransport(mode: .delayedResolution)
        let model = await ready(transport)
        let unresolved = try #require(model.workbench?.rows.first(where: { $0.id == V15F3GFixtures.unresolvedID }))

        model.requestResolution(row: unresolved, as: .createNew)
        for _ in 0..<40 where !(await transport.hasResolutionWireStarted()) { try? await Task.sleep(for: .milliseconds(10)) }
        model.sceneDidLeaveActive()
        guard case .failed(let failure) = model.phase else { Issue.record("post-wire resolution must be unknown"); return }
        #expect(failure.code == "resolution_response_unknown")
        model.retryFromFailure()
        try? await Task.sleep(for: .milliseconds(120))
        #expect((await transport.recordedWrites()).filter { $0.request.path.hasSuffix("/draft-resolution") }.count == 1)
        #expect((await transport.recordedRequests()).contains(where: { $0.path.hasSuffix("/review-workbench") }))
    }

    @Test("unknown resolution recovery scans unfiltered cursor pages and only unlocks an owner with fresh matching facts")
    @MainActor func resolutionOwnerScopedReadback() async throws {
        let recovered = F3GTransport(mode: .resolutionUnknownReadback)
        let recoveredModel = await ready(recovered)
        let owner = try #require(recoveredModel.workbench?.rows.first(where: { $0.id == V15F3GFixtures.unresolvedID }))
        await recoveredModel.setWorkbenchEvidenceFilter("unavailable")
        #expect(recoveredModel.workbench?.rows.isEmpty == true)
        await recoveredModel.resolve(row: owner, as: .createNew)
        recoveredModel.requestResolutionReadback()
        for _ in 0..<80 where recoveredModel.isResolutionReadbackInFlight { try? await Task.sleep(for: .milliseconds(15)) }
        #expect(recoveredModel.phase == .ready)
        #expect(recoveredModel.batch?.version == 6)
        #expect(recoveredModel.workbenchFilter.evidenceState == "unavailable")
        #expect(recoveredModel.workbench?.rows.isEmpty == true)
        let recoveryReads = await recovered.recordedRequests().filter { $0.path.hasSuffix("/review-workbench") && !$0.query.contains(where: { $0.name == "filters" }) }
        #expect(recoveryReads.contains(where: { $0.query.contains(where: { $0.name == "cursor" && $0.value == "0" }) }))
        #expect(recoveryReads.contains(where: { $0.query.contains(where: { $0.name == "cursor" && $0.value == "1" }) }))
        #expect((await recovered.recordedWrites()).filter { $0.request.path.hasSuffix("/draft-resolution") }.count == 1)

        for mode in [F3GTransport.Mode.resolutionReadbackMissing, .resolutionReadbackPageFailure, .resolutionReadbackStale] {
            let transport = F3GTransport(mode: mode)
            let model = await ready(transport)
            let lockedOwner = try #require(model.workbench?.rows.first(where: { $0.id == V15F3GFixtures.unresolvedID }))
            await model.resolve(row: lockedOwner, as: .createNew)
            model.requestResolutionReadback()
            for _ in 0..<80 where model.isResolutionReadbackInFlight { try? await Task.sleep(for: .milliseconds(15)) }
            guard case .failed(let failure) = model.phase else { Issue.record("missing, page failure, or stale owner evidence must retain the unknown lock"); continue }
            #expect(failure.code == "resolution_response_unknown")
            #expect(model.writeReasons.contains(where: { $0.code == "lifecycle_response_unknown" }))
            #expect((await transport.recordedWrites()).filter { $0.request.path.hasSuffix("/draft-resolution") }.count == 1)
        }
    }

    @Test("active resolution fail-closes every other mutation wire")
    @MainActor func activeResolutionBlocksMutationReplacement() async throws {
        let transport = F3GTransport(mode: .delayedResolution); let model = await ready(transport)
        let unresolved = try #require(model.workbench?.rows.first(where: { $0.id == V15F3GFixtures.unresolvedID }))
        let executable = try #require(model.workbench?.rows.first(where: { $0.id == V15F3GFixtures.rowID }))
        model.requestResolution(row: unresolved, as: .createNew)
        for _ in 0..<40 where !(await transport.hasResolutionWireStarted()) { try? await Task.sleep(for: .milliseconds(10)) }
        model.requestResolution(row: executable, as: .ignoreIntentional)
        model.requestPreview(); model.requestConfirm()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(model.writeReasons.contains(where: { $0.code == "mutation_in_progress" }))
        let writes = await transport.recordedWrites()
        #expect(writes.filter { $0.request.path.hasSuffix("/draft-resolution") }.count == 1)
        #expect(!writes.contains(where: { $0.request.path.hasSuffix("/confirmation-preview") || $0.request.path.hasSuffix("/confirm") }))
    }

    @Test("replacing a workbench invalidates a server preview before confirm")
    @MainActor func reloadRequiresFreshPreview() async throws {
        let transport = F3GTransport(mode: .normal); let model = await ready(transport)
        await model.previewConfirmation(); #expect(model.preview != nil)
        await model.reloadWorkbench(); await model.confirm()
        #expect(model.preview == nil)
        #expect(model.confirmReasons.contains(where: { $0.code == "preview_required" }))
        #expect(!(await transport.recordedWrites()).contains(where: { $0.request.path.hasSuffix("/confirm") }))
    }
}
