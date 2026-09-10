import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import FiscalKit

@Suite("V221 real statement evidence and recovery")
struct V221StatementImportTests {
    @Test("Production processor preserves text-PDF dates and amounts while redacting identity")
    func textPDF() async throws { try await checkPDF(scanned: false) }

    @Test("Production processor OCRs an actual scanned PDF")
    func scannedPDF() async throws { try await checkPDF(scanned: true) }

    private func checkPDF(scanned: Bool, services: V15Services? = nil) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v221-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let pdf = try #require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        pdf.beginPDFPage(nil)
        if scanned {
            let bitmap = try #require(CGContext(data: nil, width: 1224, height: 1584, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 1224, height: 1584)); bitmap.scaleBy(x: 2, y: 2)
            drawLines(bitmap)
            pdf.draw(try #require(bitmap.makeImage()), in: bounds)
        } else { drawLines(pdf) }
        pdf.endPDFPage(); pdf.closePDF()
        let result = try await V15PDFStatementProcessor().process(url: url, attemptID: UUID(), expectedVersion: 2)
        let text = result.evidence.pages.compactMap(\.evidenceTextMasked).joined(separator: "\n")
        #expect(text.contains("2026-08-12")); #expect(text.contains("18.50"))
        #expect(!text.contains("4111111111111111")); #expect(text.contains("[REDACTED]"))
        #expect(result.evidence.rows.count >= 2)
        #expect(result.evidence.pages.first?.sourceKind == (scanned ? "scanned_image" : "text"))
        #expect(result.evidence.rows.allSatisfy { $0.boundingBox.width < 1 && $0.boundingBox.height < 1 })
        if let services { try await completeHTTPImport(result, services: services) }
    }
    @Test("Real PDF to loopback backend through production HTTP transport", .enabled(if: ProcessInfo.processInfo.environment["FISCAL_STATEMENT_E2E_URL"] != nil))
    @MainActor func realHTTPChain() async throws {
        let raw = try #require(ProcessInfo.processInfo.environment["FISCAL_STATEMENT_E2E_URL"])
        let url = try #require(URL(string: raw))
        #expect(url.host == "127.0.0.1" || url.host == "localhost")
        guard url.host == "127.0.0.1" || url.host == "localhost" else { return }
        let transport = APITransport(baseURL: url, token: "local-e2e-only")
        let services = V15Services(transport: V15APITransportAdapter(transport: transport))
        try await checkPDF(scanned: false, services: services)
        try await checkPDF(scanned: true, services: services)
    }
    @MainActor private func completeHTTPImport(_ document: V15StatementLocalDocument, services: V15Services) async throws {
        let api = services.statementImports
        let registration = try await api.register(.init(documentSHA256: document.sha256, byteSize: document.byteSize, pageCount: document.pageCount, displayName: "statement.pdf"))
        let id = registration.value.id
        let attempt = try await api.startExtraction(importID: id, expectedVersion: registration.value.version)
        let extracting = try await api.statement(id: id, readCachePolicy: .reloadIgnoringCache)
        _ = try await api.submitEvidence(importID: id, request: .init(expectedVersion: extracting.version, attemptID: attempt.id, pages: document.evidence.pages, rows: document.evidence.rows))
        let info = try await api.providerAuthorization(importID: id, readCachePolicy: .reloadIgnoringCache)
        #expect(info.redactionCount == document.evidence.pages.reduce(0) { $0 + ($1.evidenceTextMasked?.components(separatedBy: "[REDACTED]").count ?? 1) - 1 })
        let authorization = V15StatementProviderAuthorization(confirmed: true, provider: try #require(info.provider), providerModel: try #require(info.providerModel), promptVersion: try #require(info.promptVersion), schemaVersion: try #require(info.schemaVersion), evidenceSHA256: try #require(info.evidenceSHA256), pageNumbers: info.pageNumbers, rowCount: info.rowCount, redactionVersion: info.redactionVersion, redactionCount: info.redactionCount, configurationRevision: info.configurationRevision)
        let provider = try await api.providerAttempt(importID: id, request: .init(expectedVersion: info.batchVersion, evidenceSHA256: authorization.evidenceSHA256, authorization: authorization), idempotencyKey: UUID())
        #expect(provider.providerAttemptID != provider.providerSnapshotID?.uuidString)
        _ = try await api.validationRun(importID: id, request: .init(expectedBatchVersion: provider.batch.version, providerSnapshotID: try #require(provider.providerSnapshotID)))
        let account = try await services.masterData.createAccount(.init(name: "V221 PDF \(UUID())", kind: .cash))
        var board = try await api.workbench(importID: id, readCachePolicy: .reloadIgnoringCache)
        #expect(account.currentBalanceMinor == 0)
        for row in board.rows {
            let hasCandidate = row.candidates.contains { $0.candidateKind == "provider_candidate" }
            _ = try await api.putResolution(importID: id, rowID: row.id, request: .init(expectedBatchVersion: board.batchVersion, expectedRowVersion: row.rowVersion, expectedResolutionVersion: row.draft?.version ?? 0, resolution: hasCandidate ? .createNew : .ignoreNonTransaction, matchedTransactionID: nil, ignoredReason: nil))
            let current = try await api.statement(id: id, readCachePolicy: .reloadIgnoringCache)
            if hasCandidate {
                _ = try await api.putFinalCreateDraft(importID: id, rowID: row.id, request: .init(expectedVersion: 0, transaction: .init(kind: .expense, amountMinor: 1850, occurredAt: Date(timeIntervalSince1970: 1786507200), title: "Grocery", accountID: account.id), expectedBatchVersion: current.version, expectedRowVersion: row.rowVersion))
            }
            let stalePreview = try await api.confirmationPreview(importID: id, rowIDs: [row.id])
            // Persist a confirmation whose response was lost, then make its version stale.
            // Recovery must observe the real backend's 404 receipt and 409 rejection.
            let pendingKey = UUID()
            let pendingID = try services.pendingWrites.prepare(kind: .statementConfirmation, title: "E2E stale confirmation", request: stalePreview.request, idempotencyKey: pendingKey, resourceID: id)
            try services.pendingWrites.markInFlight(pendingID)
            services.pendingWrites.markUnknown(pendingID)
            let latestBoard = try await api.workbench(importID: id, readCachePolicy: .reloadIgnoringCache)
            let latestRow = try #require(latestBoard.rows.first { $0.id == row.id })
            _ = try await api.putResolution(importID: id, rowID: row.id, request: .init(expectedBatchVersion: latestBoard.batchVersion, expectedRowVersion: latestRow.rowVersion, expectedResolutionVersion: latestRow.draft?.version ?? 0, resolution: .unresolved, matchedTransactionID: nil, ignoredReason: nil))
            let changedBoard = try await api.workbench(importID: id, readCachePolicy: .reloadIgnoringCache)
            let changedRow = try #require(changedBoard.rows.first { $0.id == row.id })
            _ = try await api.putResolution(importID: id, rowID: row.id, request: .init(expectedBatchVersion: changedBoard.batchVersion, expectedRowVersion: changedRow.rowVersion, expectedResolutionVersion: changedRow.draft?.version ?? 0, resolution: hasCandidate ? .createNew : .ignoreNonTransaction, matchedTransactionID: nil, ignoredReason: nil))
            let restored = V15StatementImportModel(services: services)
            await restored.resumePendingImport()
            #expect(restored.phase == .responseUnknown)
            await restored.readConfirmationReceipt()
            #expect(restored.phase == .responseUnknown)
            await restored.recoverOriginalConfirmation()
            #expect(restored.phase == .ready)
            #expect(restored.previewFailure?.kind == .conflict)
            #expect(services.pendingWrites.item(pendingID) == nil)
            restored.toggleRow(row.id)
            if !restored.selectedRowIDs.contains(row.id) { restored.toggleRow(row.id) }
            await restored.previewConfirmation()
            #expect(restored.preview != nil)
            let preview = try await api.confirmationPreview(importID: id, rowIDs: [row.id])
            let key = UUID()
            let receipt = try await api.confirm(importID: id, serverRequest: preview.request, idempotencyKey: key)
            #expect(receipt.confirmedRowIDs == [row.id])
            let readback = try await api.confirmationReceipt(importID: id, idempotencyKey: key, readCachePolicy: .reloadIgnoringCache)
            #expect(readback.operationID == receipt.operationID)
            board = try await api.workbench(importID: id, readCachePolicy: .reloadIgnoringCache)
        }
        let recovery = try await api.recovery(importID: id, readCachePolicy: .reloadIgnoringCache)
        #expect(recovery.nextAction == "completed")
        let freshAccount = try await services.masterData.account(id: account.id)
        #expect(freshAccount.currentBalanceMinor == -1850)
    }
    private func drawLines(_ context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
        for (index, text) in ["Card: 4111111111111111", "2026-08-12 Grocery 18.50"].enumerated() {
            let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            context.textPosition = CGPoint(x: 40, y: 710 - index * 40); CTLineDraw(line, context)
        }
    }

    @Test("Flat backend response uses validated snapshot and latest version")
    @MainActor func snapshotIdentity() async throws {
        let transport = F3GTransport(mode: .normal)
        let model = V15StatementImportModel(services: .init(transport: transport))
        model.startSyntheticGallery()
        for _ in 0..<200 { if model.phase == .awaitingProviderConsent { break }; try await Task.sleep(for: .milliseconds(15)) }
        model.providerAuthorized = true; await model.startProviderAttempt(); await model.runValidation()
        let wire = try #require(await transport.recordedWrites().first { $0.request.path.hasSuffix("/validation-runs") })
        #expect(wire.body.contains(V15F3GFixtures.snapshotID.uuidString))
        #expect(!wire.body.contains(V15F3GFixtures.providerID.uuidString))
        #expect(wire.body.contains("\"expected_batch_version\":4"))
    }

    @Test("Recreated model restores original provider intent from shared journal")
    @MainActor func providerRestart() async throws {
        let transport = F3GTransport(mode: .providerUnknown)
        let services = V15Services(transport: transport)
        let original = V15StatementImportModel(services: services)
        original.startSyntheticGallery()
        for _ in 0..<200 { if original.phase == .awaitingProviderConsent { break }; try await Task.sleep(for: .milliseconds(15)) }
        original.providerAuthorized = true; await original.startProviderAttempt()
        let restored = V15StatementImportModel(services: services)
        await restored.resumePendingImport()
        #expect(restored.phase == .providerResponseUnknown)
        await restored.recoverProviderAttempt()
        let calls = await transport.recordedWrites().filter { $0.request.path.hasSuffix("/provider-attempts") }
        #expect(calls.count == 2); #expect(calls.first?.body == calls.last?.body)
        #expect(calls.first?.request.headers["Idempotency-Key"] == calls.last?.request.headers["Idempotency-Key"])
        #expect(services.pendingWrites.items.isEmpty)
    }
}
