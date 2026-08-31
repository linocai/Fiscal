import Foundation
import Testing

@testable import FiscalKit

@Suite("V15 clean-room foundation")
struct V15FoundationTests {
    @Test("facts contracts tolerate additive keys and reject missing required fields")
    func strictDecode() throws {
        let facts = try V15FixtureCodec.decoder.decode(V15Facts.self, from: V15FixtureLibrary.factsSuccess)
        #expect(facts.meta.dataRevision == Int64.max)
        #expect(facts.cash.currentBalanceMinor == 123_456)
        #expect(facts.future.exactDueOutflowMinor + facts.future.confirmedOutflowMinor == 300)
        #expect(facts.knownFutureEvents.first?.certainty == .exactDue)
        let missing = Data(#"{"meta":{},"window":{},"cash":{},"credit":{},"reimbursements":{},"completeness":{}}"#.utf8)
        #expect(throws: (any Error).self) { try V15FixtureCodec.decoder.decode(V15Facts.self, from: missing) }
    }

    @Test("P34 report retains all server totals, lenses and generated revision identity")
    func periodReportFullContract() throws {
        let report = try V15FixtureCodec.decoder.decode(V15PeriodReport.self, from: V15FixtureLibrary.report)
        #expect(report.meta.dataRevision == 5)
        #expect(report.meta.generatedAt > report.meta.asOf)
        #expect(report.summary.netConsumptionMinor == report.summary.grossConsumptionMinor - report.summary.merchantRefundMinor)
        #expect(report.accounts.first?.closingBalanceMinor == 610)
        #expect(report.categories.first?.transactionCount == 1)
        #expect(report.completeness.uncategorizedTransactionCount == 1)
        let missing = Data(#"{"meta":{},"summary":{},"accounts":[],"categories":[],"merchants":[],"sources":[],"completeness":{}}"#.utf8)
        #expect(throws: (any Error).self) { try V15FixtureCodec.decoder.decode(V15PeriodReport.self, from: missing) }
    }

    @Test("P33 credit schedule preview retains the full atomic effect")
    func creditScheduleFullContract() throws {
        let preview = try V15FixtureCodec.decoder.decode(V15CreditSchedulePreview.self, from: V15FixtureLibrary.creditSchedulePreview)
        #expect(preview.cycleMode == "statement_day_cutoff")
        #expect(preview.oldCycleMode == "previous_calendar_month")
        #expect(preview.affectedCycles.first?.oldDueDate == "2026-09-05")
        #expect(preview.purchaseCount == 2 && preview.repaymentCount == 1 && preview.installmentPeriodCount == 3)
        #expect(preview.currentAccountVersion == preview.expectedAccountVersion)
        #expect(throws: (any Error).self) { try V15FixtureCodec.decoder.decode(V15CreditSchedulePreview.self, from: Data(#"{"account_id":"00000000-0000-0000-0000-000000000020"}"#.utf8)) }
    }

    @Test("P33 four reimbursement preview endpoints use lossless typed effects")
    func reimbursementPreviewFullContracts() throws {
        let replace = try V15FixtureCodec.decoder.decode(V15ReimbursementClaimPreview.self, from: V15FixtureLibrary.reimbursementClaimPreview)
        let cancel = try V15FixtureCodec.decoder.decode(V15ReimbursementCancelPreview.self, from: V15FixtureLibrary.reimbursementCancelPreview)
        let createReceipt = try V15FixtureCodec.decoder.decode(V15ReimbursementReceiptPreview.self, from: V15FixtureLibrary.reimbursementReceiptPreview)
        let replaceReceipt = try V15FixtureCodec.decoder.decode(V15ReimbursementReceiptPreview.self, from: V15FixtureLibrary.reimbursementReceiptPreview)
        #expect(replace.current.parties.first?.allocations.first?.transactionID == UUID(uuidString: "00000000-0000-0000-0000-000000000034"))
        #expect(replace.proposed.title == "新报销")
        #expect(cancel.proposedStatus == "cancelled" && cancel.releasedMinor == 100)
        #expect(createReceipt.persistedAllocations.first?.allocationID == UUID(uuidString: "00000000-0000-0000-0000-000000000033"))
        #expect(replaceReceipt.claimReceivedAfterMinor == 100)
        #expect(throws: (any Error).self) { try V15FixtureCodec.decoder.decode(V15ReimbursementClaimPreview.self, from: Data(#"{"preview_token":"00000000-0000-0000-0000-000000000030"}"#.utf8)) }
    }

    @Test("minor units and UTC boundary retain Int64 and Shanghai business day")
    func moneyAndDateBoundaries() throws {
        #expect(CNYAmountParser.minorUnits("92233720368547758.07") == Int64.max)
        #expect(CNYAmountParser.minorUnits("92233720368547758.08") == nil)
        let utc = try #require(ISO8601DateFormatter().date(from: "2026-08-31T16:30:00Z"))
        #expect(ShanghaiBusinessDate.string(for: utc) == "2026-09-01")
        let august = try #require(ISO8601DateFormatter().date(from: "2026-08-31T15:59:59Z"))
        #expect(ShanghaiBusinessDate.isSameMonth(august, utc) == false)
    }

    @Test("unknown available actions degrade to an explained disabled capability")
    func unknownCapabilitiesAreSafe() {
        let action = V15AvailableAction(action: "future_server_action", enabled: true, reasonCode: nil, reasonMessage: nil)
        #expect(action.capability(knownActions: ["archive"]) == .disabled(action: "future_server_action", reason: .unknownCapability))
    }

    @Test("409 details carry reload locator and field issues")
    func stableConflictMapping() {
        let detail = APIErrorDetail(code: "facts_revision_conflict", message: "重新加载。", details: .object(["reload_path": .string("/api/v1/reports/facts"), "data_revision": .integer(9), "field_issues": .array([.object(["code": .string("stale"), "message": .string("已过期"), "field_path": .string("scope")])])]), requestID: "r")
        let failure = V15ErrorMapper.map(.domain(status: 409, detail: detail))
        #expect(failure.kind == .conflict)
        #expect(failure.conflict?.reloadPath == "/api/v1/reports/facts")
        #expect(failure.conflict?.latestRevision == 9)
        #expect(failure.fieldIssues.first?.fieldPath == "scope")
    }

    @Test("409 parser preserves nested version locators and top-level report/preview refresh facts")
    func conflictVariants() {
        let nested = APIErrorDetail(code: "resource_version_conflict", message: "changed", details: .object(["current_version": .integer(8), "expected_version": .integer(7), "safe_to_reload": .bool(true), "resource": .object(["resource_type": .string("account"), "resource_id": .string("opaque-id"), "reload_path": .string("/api/v1/credit-accounts/opaque-id")])]), requestID: "r")
        let nestedFailure = V15ErrorMapper.map(.domain(status: 409, detail: nested))
        #expect(nestedFailure.conflict?.reloadPath == "/api/v1/credit-accounts/opaque-id")
        #expect(nestedFailure.conflict?.currentVersion == 8 && nestedFailure.conflict?.expectedVersion == 7)
        #expect(nestedFailure.conflict?.safeToReload == true && nestedFailure.conflict?.locator == "opaque-id")
        let report = APIErrorDetail(code: "future_events_scope_changed", message: "reload", details: .object(["expected_data_revision": .integer(4), "current_data_revision": .integer(5), "safe_to_reload": .bool(true), "reload_path": .string("/api/v1/reports/future-events")]), requestID: "r")
        #expect(V15ErrorMapper.map(.domain(status: 409, detail: report)).conflict?.latestRevision == 5)
        let preview = APIErrorDetail(code: "credit_schedule_preview_stale", message: "preview", details: .object(["reason": .string("dependencies_changed"), "safe_to_reload": .bool(true), "reload_path": .string("/api/v1/credit-accounts/opaque-id")]), requestID: "r")
        #expect(V15ErrorMapper.map(.domain(status: 409, detail: preview)).conflict?.safeToReload == true)
    }

    @Test("P31 category previews retain every server-visible atomic dependency")
    func categoryPreviewContracts() throws {
        let merge = Data(#"{"preview_token":"00000000-0000-0000-0000-000000000060","source":{"category_id":"00000000-0000-0000-0000-000000000061","transaction_count":2,"amount_minor":300},"target_id":"00000000-0000-0000-0000-000000000062","child_mapping_requirements":[{"source_child_id":"00000000-0000-0000-0000-000000000063","source_child_name":"子类","target_child_ids":["00000000-0000-0000-0000-000000000064"]}],"atomic":true,"future_additive":true}"#.utf8)
        let split = Data(#"{"preview_token":"00000000-0000-0000-0000-000000000065","root":{"category_id":"00000000-0000-0000-0000-000000000066","transaction_count":1,"amount_minor":100},"required_transaction_ids":["00000000-0000-0000-0000-000000000067"],"child_names":["餐饮","交通"],"atomic":true}"#.utf8)
        let mergePreview = try V15FixtureCodec.decoder.decode(V15CategoryMergePreview.self, from: merge)
        let splitPreview = try V15FixtureCodec.decoder.decode(V15CategorySplitPreview.self, from: split)
        #expect(mergePreview.childMappingRequirements.first?.targetChildIDs.count == 1)
        #expect(splitPreview.requiredTransactionIDs.count == 1 && splitPreview.atomic)
        #expect(throws: (any Error).self) { try V15FixtureCodec.decoder.decode(V15CategoryMergePreview.self, from: Data(#"{"preview_token":"00000000-0000-0000-0000-000000000060"}"#.utf8)) }
    }

    @Test("category formal mutations encode exact snake-case requests and decode receipts")
    func categoryMutationContracts() throws {
        let source = UUID(uuidString: "00000000-0000-0000-0000-000000000080")!
        let target = UUID(uuidString: "00000000-0000-0000-0000-000000000081")!
        let preview = UUID(uuidString: "00000000-0000-0000-0000-000000000082")!
        let merge = V15CategoryMergePreviewRequest(targetID: target, sourceExpectedVersion: 3, targetExpectedVersion: 4)
        let mergeObject = try #require(JSONSerialization.jsonObject(with: V15FixtureCodec.encoder.encode(merge)) as? [String: Any])
        #expect(mergeObject["target_id"] as? String == target.uuidString.uppercased())
        #expect(mergeObject["source_expected_version"] as? Int == 3)
        #expect(mergeObject["targetID"] == nil)
        let commit = V15CategoryMergeCommitRequest(previewToken: preview, childMappings: [.init(sourceChildID: source, targetChildID: target)])
        let commitObject = try #require(JSONSerialization.jsonObject(with: V15FixtureCodec.encoder.encode(commit)) as? [String: Any])
        #expect(commitObject["preview_token"] as? String == preview.uuidString.uppercased())
        #expect(((commitObject["child_mappings"] as? [[String: Any]])?.first?["source_child_id"] as? String) == source.uuidString.uppercased())
        let receipt = Data(##"{"action":"merge","categories":[{"id":"00000000-0000-0000-0000-000000000081","name":"目标","direction":"expense","parent_id":null,"icon":"tag","color_hex":"#00AA00","aliases":[],"examples":[],"is_balance_adjustment":false,"sort_order":0,"archived_at":null,"usage_count":2,"version":5,"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-15T00:00:00Z","children":[]}],"reclassified_transaction_count":2,"future_additive":true}"##.utf8)
        let decoded = try V15FixtureCodec.decoder.decode(V15CategoryTransformReceipt.self, from: receipt)
        #expect(decoded.action == "merge" && decoded.categories.first?.version == 5)
        #expect(throws: (any Error).self) { try V15FixtureCodec.decoder.decode(V15CategoryTransformReceipt.self, from: Data(#"{"action":"merge"}"#.utf8)) }
    }

    @Test("typed write dates use APITransport ISO-8601 wire strings and reimbursement tokens are phase-specific")
    func typedMutationWireContracts() throws {
        let party = UUID(uuidString: "00000000-0000-0000-0000-000000000090")!
        let account = UUID(uuidString: "00000000-0000-0000-0000-000000000091")!
        let transaction = UUID(uuidString: "00000000-0000-0000-0000-000000000092")!
        let token = UUID(uuidString: "00000000-0000-0000-0000-000000000093")!
        let instant = Date(timeIntervalSince1970: 1_755_274_862) // 2025-08-15T16:21:02Z
        let receiptPreview = V15ReimbursementReceiptDraft(expectedClaimVersion: 3, partyID: party, amountMinor: 100, receivedAt: instant, destinationAccountID: account, title: "回款")
        let previewObject = try #require(JSONSerialization.jsonObject(with: V15BodyEncoder.data(receiptPreview)) as? [String: Any])
        #expect((previewObject["received_at"] as? String)?.hasSuffix("Z") == true)
        #expect(previewObject["preview_token"] == nil)
        let claimPreview = V15ReimbursementClaimPreviewRequest(title: "报销", parties: [.init(name: "同事", allocations: [.init(transactionID: transaction, amountMinor: 100)])], expectedVersion: 3)
        let claimPreviewObject = try #require(JSONSerialization.jsonObject(with: V15BodyEncoder.data(claimPreview)) as? [String: Any])
        #expect(claimPreviewObject["preview_token"] == nil && claimPreviewObject["expected_version"] as? Int == 3)
        let claimCommit = V15ReimbursementClaimCommitRequest(title: "报销", parties: [.init(name: "同事", allocations: [.init(transactionID: transaction, amountMinor: 100)])], expectedVersion: 3, previewToken: token)
        let claimCommitObject = try #require(JSONSerialization.jsonObject(with: V15BodyEncoder.data(claimCommit)) as? [String: Any])
        #expect(claimCommitObject["preview_token"] as? String == token.uuidString.uppercased())
        let replacePreview = V15ReimbursementReceiptReplacePreviewRequest(expectedClaimVersion: 3, partyID: party, amountMinor: 100, receivedAt: instant, destinationAccountID: account, title: "回款", expectedReceiptVersion: 2)
        let replacePreviewObject = try #require(JSONSerialization.jsonObject(with: V15BodyEncoder.data(replacePreview)) as? [String: Any])
        #expect(replacePreviewObject["preview_token"] == nil && replacePreviewObject["expected_receipt_version"] as? Int == 2)
        let replaceCommit = V15ReimbursementReceiptReplaceCommitRequest(expectedClaimVersion: 3, partyID: party, amountMinor: 100, receivedAt: instant, destinationAccountID: account, title: "回款", expectedReceiptVersion: 2, previewToken: token)
        let replaceCommitObject = try #require(JSONSerialization.jsonObject(with: V15BodyEncoder.data(replaceCommit)) as? [String: Any])
        #expect(replaceCommitObject["preview_token"] as? String == token.uuidString.uppercased())
        let installment = V15InstallmentActionRequest(expectedVersion: 4, occurredAt: instant)
        let installmentObject = try #require(JSONSerialization.jsonObject(with: V15BodyEncoder.data(installment)) as? [String: Any])
        #expect((installmentObject["occurred_at"] as? String)?.hasSuffix("Z") == true)
    }

    @Test("V15 decoder accepts backend Z, offset and fractional ISO-8601 timestamps")
    func backendDateDecoding() throws {
        let z = try V15FixtureCodec.decoder.decode(V15Preview.self, from: Data(#"{"preview_token":"00000000-0000-0000-0000-000000000094","input_digest":"z","preview_expires_at":"2026-08-15T16:10:00Z","data_revision":1}"#.utf8))
        let offset = try V15FixtureCodec.decoder.decode(V15Preview.self, from: Data(#"{"preview_token":"00000000-0000-0000-0000-000000000095","input_digest":"offset","preview_expires_at":"2026-08-15T16:10:00+00:00","data_revision":1}"#.utf8))
        let microseconds = try V15FixtureCodec.decoder.decode(V15Preview.self, from: Data(#"{"preview_token":"00000000-0000-0000-0000-000000000096","input_digest":"fraction","preview_expires_at":"2026-08-15T16:10:00.123456Z","data_revision":1}"#.utf8))
        #expect(z.expiresAt != nil && offset.expiresAt != nil && microseconds.expiresAt != nil)
    }

    @Test("V15 feature sources cannot reach the raw transport escape hatch")
    func featureSourceAPISeal() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let features = appRoot.appending(path: "Sources/FiscalKit/V15/Features")
        guard FileManager.default.fileExists(atPath: features.path) else { return }
        let forbidden = ["V15Request", "V15Transporting", "V15APITransportAdapter", "V15FixtureTransport", "JSONValue"]
        let files = FileManager.default.enumerator(at: features, includingPropertiesForKeys: nil)?.allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(!forbidden.contains { source.contains($0) }, "\(file.path) reaches a raw V15 transport type")
        }
    }

    @Test("future event optional domain locators are not discarded")
    func futureEventLocators() throws {
        let data = Data(#"{"source_type":"reimbursement_party","source_id":"00000000-0000-0000-0000-000000000070","date":"2026-08-20","direction":"inflow","amount_minor":100,"certainty":"expected","title":"回款","deep_link":"fiscal://reimbursements/1","account_id":null,"claim_id":"00000000-0000-0000-0000-000000000071","party_id":"00000000-0000-0000-0000-000000000072","cycle_id":null}"#.utf8)
        let event = try V15FixtureCodec.decoder.decode(V15FutureEvent.self, from: data)
        #expect(event.claimID != nil && event.partyID != nil && event.cycleID == nil)
    }

    @Test("older generations and their cancellation cannot overwrite newer work")
    @MainActor
    func generationOwnership() {
        let state = V15LoadState<Int>()
        let old = state.begin()
        let fresh = state.begin()
        state.succeed(2, generation: fresh)
        state.fail(.init(kind: .cancelled, message: "取消"), generation: old)
        if case .loaded(let value) = state.phase { #expect(value == 2) } else { Issue.record("stale cancellation replaced loaded state") }
    }

    @Test("preview is invalidated by input, dismiss, cancellation, expiry and stale generation")
    @MainActor
    func previewLifecycle() {
        let lifecycle = V15PreviewLifecycle()
        let token = UUID()
        lifecycle.accept(.init(token: token, inputDigest: "a"), generation: 2, currentGeneration: 2)
        #expect(lifecycle.commitToken(for: "a") == token)
        lifecycle.inputChanged(); #expect(lifecycle.commitToken(for: "a") == nil)
        lifecycle.accept(.init(token: token, inputDigest: "a"), generation: 1, currentGeneration: 2); #expect(lifecycle.commitToken(for: "a") == nil)
        lifecycle.accept(.init(token: token, inputDigest: "a"), generation: 2, currentGeneration: 2); lifecycle.dismissed(); #expect(lifecycle.commitToken(for: "a") == nil)
        lifecycle.accept(.init(token: token, inputDigest: "a", expiresAt: .distantPast), generation: 2, currentGeneration: 2); #expect(lifecycle.commitToken(for: "a") == nil)
        lifecycle.cancelled(); #expect(lifecycle.commitToken(for: "a") == nil)
    }

    @Test("response-unknown preserves idempotency key until a final outcome")
    @MainActor
    func idempotencyOwnership() {
        let owner = V15IdempotencyOwner()
        let first = owner.key(for: "receipt:claim")
        // A response-unknown error intentionally does not call succeeded/abandon.
        #expect(owner.key(for: "receipt:claim") == first)
        owner.succeeded(scope: "receipt:claim")
        #expect(owner.key(for: "receipt:claim") != first)
    }

    @Test("fixture reads work offline while every write is refused with stable reason")
    @MainActor
    func offlineReadOnly() async throws {
        let revisions = DataRevisionStore(defaults: nil)
        revisions.markOfflineSnapshot(at: Date(timeIntervalSince1970: 42))
        let services = V15Services(transport: V15FixtureLibrary.readOnlyTransport(), revisionStore: revisions)
        let facts = try await services.reports.facts()
        #expect(facts.meta.timezone == "Asia/Shanghai")
        do {
            _ = try await services.credit.schedulePreview(accountID: UUID(), request: .init(expectedVersion: 1, cycleMode: "statement_day_cutoff", statementDay: 1, dueDay: 1))
            Issue.record("offline write was accepted")
        } catch let error as V15Failure {
            #expect(error.kind == .offlineReadOnly)
        }
        #expect(services.offlineSnapshotAt == Date(timeIntervalSince1970: 42))
    }

    @Test("cursor and revision contract stay server-owned")
    func cursorAndRevision() throws {
        let data = Data(#"{"meta":{"timezone":"Asia/Shanghai","currency":"CNY","as_of":"2026-08-15T16:01:02Z","data_revision":8,"schema_version":"1"},"scope":{"scope_type":"cash_accounts","schema_version":"1","expected_data_revision":8,"read_path":"/api/v1/reports/facts/drill-down?scope=cash_accounts","deep_link":"fiscal://facts/cash"},"items":[],"next_cursor":"opaque-cursor"}"#.utf8)
        let page = try V15FixtureCodec.decoder.decode(V15FactDrillDown.self, from: data)
        #expect(page.scope.expectedDataRevision == page.meta.dataRevision)
        #expect(page.nextCursor == "opaque-cursor")
    }

    @Test("candidate filters, receipt accounts and migration path preserve backend routing")
    @MainActor
    func reimbursementAndMigrationRoutes() async throws {
        let candidate = Data(#"{"items":[{"transaction_id":"00000000-0000-0000-0000-000000000050","title":"未分类支出","business_date":"2026-08-15","kind":"expense","account_id":"00000000-0000-0000-0000-000000000051","category_id":null,"canonical_amount_minor":100,"allocated_minor":0,"available_minor":100,"eligibility":{"eligible":true,"transaction_id":"00000000-0000-0000-0000-000000000050","canonical_amount_minor":100,"allocated_minor":0,"available_minor":100,"reasons":[],"reason_details":[]}}],"next_cursor":"opaque"}"#.utf8)
        let accounts = Data(#"{"items":[{"id":"00000000-0000-0000-0000-000000000052","name":"现金","kind":"cash"}]}"#.utf8)
        let fixture = V15FixtureTransport(responses: ["reimbursement-expense-candidates": candidate, "reimbursement-receipt-account-options": accounts, "migrations/runs/00000000-0000-0000-0000-000000000053": Data(#"{"id":"00000000-0000-0000-0000-000000000053"}"#.utf8)])
        let services = V15Services(transport: fixture)
        let page = try await services.reimbursements.candidates(query: "未分类", dateFrom: "2026-08-01", dateTo: "2026-08-31", cursor: "opaque", limit: 20)
        #expect(page.items.first?.categoryID == nil && page.items.first?.eligibility.eligible == true)
        #expect(page.items.first?.eligibility.transactionID == page.items.first?.transactionID)
        #expect(page.items.first?.eligibility.canonicalAmountMinor == 100)
        #expect(page.items.first?.eligibility.allocatedMinor == 0)
        #expect(page.items.first?.eligibility.availableMinor == 100)
        let requestedCandidates = await fixture.lastRequest()
        #expect(requestedCandidates?.query.map(\.name) == ["limit", "query", "date_from", "date_to", "cursor"])
        let receiptAccounts = try await services.reimbursements.receiptAccountOptions()
        #expect(receiptAccounts.items.first?.kind == "cash")
        _ = try await services.deepLinks.migrationRun(UUID(uuidString: "00000000-0000-0000-0000-000000000053")!)
        #expect((await fixture.lastRequest())?.path == "migrations/runs/00000000-0000-0000-0000-000000000053")
    }

    @Test("monthly/yearly routes cannot be swapped with the month/year query enum")
    @MainActor
    func reportPeriodRoutes() async throws {
        let month = try #require(V15ReportMonth("2026-08")); let year = try #require(V15ReportYear("2026"))
        #expect(V15ReportMonth("2026") == nil && V15ReportYear("2026-08") == nil)
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000054")!
        let fixture = V15FixtureTransport(responses: ["reports/v2/monthly/2026-08": V15FixtureLibrary.reportV2, "reports/v2/yearly/2026": V15FixtureLibrary.reportV2, "reports/v2/period-drill-down": Data(#"{"meta":{"period_kind":"month","period":"2026-08","date_from":"2026-08-01","date_to":"2026-08-31","timezone":"Asia/Shanghai","currency":"CNY","as_of":"2026-08-15T16:01:02Z","data_revision":5,"report_schema_version":"2","generated_at":"2026-08-15T16:01:03Z"},"dimension":"ledger","category_id":"00000000-0000-0000-0000-000000000054","account_id":null,"merchant_id":null,"source":null,"items":[],"next_cursor":null}"#.utf8)])
        let reports = V15Services(transport: fixture).reports
        _ = try await reports.monthly(month); #expect((await fixture.lastRequest())?.path == "reports/v2/monthly/2026-08")
        _ = try await reports.yearly(year); #expect((await fixture.lastRequest())?.path == "reports/v2/yearly/2026")
        _ = try await reports.periodDrillDown(period: .month(month), expectedRevision: 5, filter: .category(categoryID))
        #expect((await fixture.lastRequest())?.query.prefix(2).map(\.value) == ["month", "2026-08"])
    }

    @Test("bootstrap distinguishes a rotated credential from an unknown access key")
    @MainActor
    func honestCredentialFailureStates() async {
        let rotated = V15BootstrapModel(services: V15Services(transport: BootstrapFailureTransport(code: "credential_generation_changed")))
        await rotated.connect()
        #expect(rotated.phase == .credentialGenerationChanged)
        #expect(rotated.error?.code == "credential_generation_changed")

        let invalid = V15BootstrapModel(services: V15Services(transport: BootstrapFailureTransport(code: "invalid_access_key")))
        await invalid.connect()
        #expect(invalid.phase == .invalidAccessKey)
        #expect(invalid.error?.code == "invalid_access_key")
    }
}

private actor BootstrapFailureTransport: V15Transporting {
    let code: String
    init(code: String) { self.code = code }

    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        throw V15Failure(kind: .transport, code: code, message: code == "credential_generation_changed" ? "访问口令已更改。" : "访问密钥无效。")
    }

    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data {
        throw V15Failure(kind: .transport, code: code, message: "访问密钥无效。")
    }
}
