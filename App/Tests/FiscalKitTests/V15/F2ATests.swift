import Foundation
import Testing

@testable import FiscalKit

@Suite("F2-A current facts typed reads and safety")
struct F2ATests {
    @Test("formal root fixture returns a complete Shanghai monthly fact for the requested period")
    @MainActor func formalRootFixtureMonthlyFact() async throws {
        let services = V15F2BFixtures.services(route: "today-root-workspace")
        let period = try #require(V15ReportMonth("2026-08"))
        let report = try await services.reports.monthly(period)
        #expect(report.meta.period == period.rawValue)
        #expect(report.meta.timezone == "Asia/Shanghai")
        #expect(report.summary.personalRealizedMinor == 123_456)
    }

    @Test("facts decodes every server card, future field and all four exact drill-down unions")
    @MainActor func typedFactsAndScopes() async throws {
        let transport = V15F2ATransport()
        let model = V15TodayReadModel(services: V15Services(transport: transport))
        await model.refresh()
        let facts = try #require(model.facts)
        #expect(facts.meta.timezone == "Asia/Shanghai" && facts.meta.currency == "CNY")
        #expect(facts.cash.currentBalanceMinor == .max)
        #expect(facts.completeness.uncategorizedTransactionAmountMinor == 500 && facts.completeness.lastReconciledAt != nil)
        #expect(facts.future.afterConfirmedOutflowMinor == 9_223_372_036_854_775_707)
        #expect(facts.knownFutureEvents.first?.cycleID == V15F2AFixtures.cycleID)
        for type in ["cash_accounts", "credit_cycles", "reimbursement_outstanding", "completeness_issues"] {
            await model.openScope(type: type)
            let item = try #require(model.scopeItems.first)
            switch (type, item) {
            case ("cash_accounts", .cashAccount(let value)): #expect(value.accountID == V15F2AFixtures.accountID)
            case ("credit_cycles", .creditCycle(let value)): #expect(value.remainingMinor == 800 && value.dueDate == "2026-08-20")
            case ("reimbursement_outstanding", .reimbursementOutstanding(let value)): #expect(value.partyID == V15F2AFixtures.partyID && value.outstandingMinor == 1000)
            case ("completeness_issues", .completenessIssue(let value)): #expect(value.issueType == .uncategorizedTransactions && value.amountMinor == 500)
            default: Issue.record("wrong typed union for \(type)")
            }
        }
        let requests = await transport.allRequests()
        #expect(requests.allSatisfy { $0.method == "GET" })
        #expect(!requests.contains { $0.path.contains("overview") || $0.path.contains("future-events") })
    }

    @Test("scope keeps the opaque cursor and local page failure never loses prior rows")
    @MainActor func cursorAndPageFailure() async throws {
        let transport = V15F2ATransport(mode: .pageFailure)
        let model = V15TodayReadModel(services: V15Services(transport: transport))
        await model.refresh(); await model.openScope(type: "cash_accounts")
        #expect(model.scopeItems.count == 1 && model.hasNextPage)
        await model.loadNextPage()
        #expect(model.scopeItems.count == 1 && model.hasNextPage && !model.isLoadingNextPage)
        guard case .failed = model.nextPagePhase else { Issue.record("page failure must be local"); return }
        let request = try #require((await transport.allRequests()).last)
        #expect(request.query.contains(.init(name: "cursor", value: "opaque-cash")))
        #expect(request.query.contains(.init(name: "expected_data_revision", value: "42")))
    }

    @Test("409 gate owns every scope and link entrance until a successful newer facts reload")
    @MainActor func revisionConflict() async throws {
        let transport = V15F2ATransport(mode: .scopeConflictThenNewRevision)
        let model = V15TodayReadModel(services: V15Services(transport: transport))
        await model.refresh(); await model.openScope(type: "cash_accounts")
        #expect(model.requiresFactsReload && model.facts == nil && model.scopeItems.isEmpty)
        guard case .requiresFactsReload(let failure) = model.scopePhase else { Issue.record("409 must own scope state"); return }
        #expect(failure.code == "report_facts_scope_changed" && failure.conflict?.expectedDataRevision == 42 && failure.conflict?.currentDataRevision == 43)
        let before = (await transport.allRequests()).count
        await model.openScope(type: "cash_accounts")
        await model.loadNextPage()
        await model.openLinkedRead("fiscal://accounts/\(V15F2AFixtures.accountID)")
        await model.openAttention(try #require(model.attention.first(where: { $0.sourceType == "uncategorized_transaction" })))
        #expect((await transport.allRequests()).count == before)
        guard case .requiresFactsReload = model.linkedReadPhase else { Issue.record("link state must retain the facts gate"); return }
        await model.refresh()
        #expect(!model.requiresFactsReload && model.facts?.meta.dataRevision == 43)
        await model.openScope(type: "cash_accounts")
        #expect((await transport.allRequests()).filter { $0.path == "reports/facts/drill-down" }.count == 2)
        #expect(model.selectedScope?.expectedDataRevision == 43 && !model.scopeItems.isEmpty)
        guard case .loaded = model.scopePhase else { Issue.record("a recovered selected scope must settle with rows, not idle/loading"); return }
        let renewedScopeRead = try #require((await transport.allRequests()).last(where: { $0.path == "reports/facts/drill-down" }))
        #expect(renewedScopeRead.query.contains(.init(name: "expected_data_revision", value: "43")))
        #expect(!renewedScopeRead.query.contains(where: { $0.name == "cursor" }))
    }

    @Test("a failed facts reload cannot clear the 409 gate")
    @MainActor func failedReloadKeepsConflictGate() async throws {
        let transport = V15F2ATransport(mode: .scopeConflictThenRefreshFailure)
        let model = V15TodayReadModel(services: V15Services(transport: transport))
        await model.refresh(); await model.openScope(type: "cash_accounts")
        #expect(model.requiresFactsReload)
        await model.refresh()
        #expect(model.requiresFactsReload && model.facts == nil)
        guard case .requiresFactsReload = model.scopePhase else { Issue.record("failed reload must keep scope gated"); return }
        let before = (await transport.allRequests()).count
        await model.openScope(type: "cash_accounts")
        await model.openLinkedRead("fiscal://transactions/\(V15F2AFixtures.transactionID)")
        #expect((await transport.allRequests()).count == before)
    }

    @Test("409 recovery forces an uncached facts read and rejects an older revision")
    @MainActor func forcedRevisionRecovery() async throws {
        let transport = V15F2ATransport(mode: .scopeConflictForceRefreshSequence)
        let model = V15TodayReadModel(services: V15Services(transport: transport))
        await model.refresh(); await model.openScope(type: "cash_accounts")
        #expect(model.requiresFactsReload && model.requiredFactsRevision == 43)
        #expect(model.factsReloadRequiredReason?.code == "facts_reload_required")

        await model.refresh()
        #expect(model.requiresFactsReload && model.facts == nil && model.requiredFactsRevision == 43)
        guard case .requiresReload = model.factsPhase else { Issue.record("older forced response must preserve reload gate"); return }

        await model.refresh()
        #expect(!model.requiresFactsReload && model.facts?.meta.dataRevision == 43 && model.requiredFactsRevision == nil)
        let factReads = (await transport.allRequests()).filter { $0.path == "reports/facts" }
        #expect(factReads.map(\.readCachePolicy) == [.standard, .reloadIgnoringCache, .reloadIgnoringCache])
    }

    @Test("a stale or invalid forced facts response never leaves its attention refresh loading")
    @MainActor func forcedRecoveryAlwaysSettlesAttention() async {
        for mode in [
            V15F2ATransport.Mode.scopeConflictForceRefreshSequence,
            .scopeConflictForceRefreshInvalidFacts,
            .scopeConflictForceRefreshAttentionFailure,
            .scopeConflictForceRefreshAttentionCancelled
        ] {
            let transport = V15F2ATransport(mode: mode)
            let model = V15TodayReadModel(services: V15Services(transport: transport))
            await model.refresh(); await model.openScope(type: "cash_accounts")
            await model.refresh()
            #expect(model.requiresFactsReload && model.facts == nil)
            switch mode {
            case .scopeConflictForceRefreshAttentionFailure:
                guard case .failed = model.attentionPhase else { Issue.record("attention transport failure must settle while facts stays gated"); continue }
            case .scopeConflictForceRefreshAttentionCancelled:
                guard case .idle = model.attentionPhase else { Issue.record("cancelled attention must release loading ownership"); continue }
            default:
                guard case .loaded = model.attentionPhase else { Issue.record("successful attention must settle while facts stays gated"); continue }
            }
            await model.refresh()
            #expect(!model.requiresFactsReload && model.facts?.meta.dataRevision == 43)
            guard case .loaded = model.attentionPhase else { Issue.record("the subsequent refresh owns and settles attention"); continue }
        }
    }

    @Test("refresh and close-inspector generations reject stale responses including cancelled work")
    @MainActor func requestOwnership() async {
        let racing = V15TodayReadModel(services: V15Services(transport: V15F2ATransport(mode: .refreshRace)))
        let old = Task { await racing.refresh() }
        await Task.yield()
        await racing.refresh()
        _ = await old.result
        #expect(racing.facts?.meta.dataRevision == 42)

        let attentionRacing = V15TodayReadModel(services: V15Services(transport: V15F2ATransport(mode: .attentionRefreshRace)))
        let oldAttention = Task { await attentionRacing.refresh() }
        await Task.yield()
        await attentionRacing.refresh()
        _ = await oldAttention.result
        #expect(attentionRacing.attention.count == 10)
        guard case .loaded = attentionRacing.attentionPhase else { Issue.record("new attention refresh must own its settled phase"); return }

        let slow = V15TodayReadModel(services: V15Services(transport: V15F2ATransport(mode: .slowScope)))
        await slow.refresh()
        let scope = Task { await slow.openScope(type: "cash_accounts") }
        await Task.yield()
        slow.closeScopeInspector()
        _ = await scope.result
        #expect(slow.selectedScope == nil && slow.scopeItems.isEmpty)
        guard case .idle = slow.scopePhase else { Issue.record("closed inspector must not be repopulated by old request"); return }
    }

    @Test("empty, failed and offline facts states preserve only server snapshot as_of")
    @MainActor func statesAndOffline() async {
        let snapshotAt = Date(timeIntervalSince1970: 1_786_464_000)
        let empty = V15TodayReadModel(services: V15Services(transport: V15F2ATransport(mode: .emptyScope)), offlineSnapshotProvider: { snapshotAt })
        await empty.refresh(); await empty.openScope(type: "completeness_issues")
        #expect(empty.isOffline && empty.offlineAsOf == empty.facts?.meta.asOf)
        guard case .empty = empty.scopePhase else { Issue.record("empty page must remain explicit"); return }
        let failed = V15TodayReadModel(services: V15Services(transport: V15F2ATransport(mode: .factsFailure)))
        await failed.refresh()
        guard case .failed = failed.factsPhase else { Issue.record("facts failure must be explicit"); return }
    }

    @Test("offline status follows the production revision store dynamically after an awaited snapshot fallback")
    @MainActor func dynamicOfflineSnapshot() async throws {
        let onlineStore = DataRevisionStore(defaults: nil)
        let online = V15TodayReadModel(services: V15Services(transport: V15F2ATransport(), revisionStore: onlineStore))
        await online.refresh()
        #expect(!online.isOffline)

        let revisionStore = DataRevisionStore(defaults: nil)
        let snapshotAt = Date(timeIntervalSince1970: 1_786_464_000)
        let transport = V15F2AOfflineSnapshotTransport(revisionStore: revisionStore, snapshotAt: snapshotAt)
        let model = V15TodayReadModel(services: V15Services(transport: transport, revisionStore: revisionStore))
        #expect(!model.isOffline)
        await model.refresh()
        #expect(model.isOffline && model.offlineSnapshotAt == snapshotAt)
        #expect(model.offlineAsOf == model.facts?.meta.asOf)
        #expect((await transport.allRequests()).allSatisfy { $0.method == "GET" })
    }

    @Test("attention mirrors reconciliation service actions and only uncategorized transactions have an F2 read destination")
    @MainActor func allowlistedLinks() async throws {
        let transport = V15F2ATransport()
        let model = V15TodayReadModel(services: V15Services(transport: transport))
        await model.refresh()
        #expect(model.attention.count == 10)
        let dismissible: Set<String> = ["reconciliation_checkpoint", "reconciliation_missing", "uncategorized_transaction", "ai_proposal", "operation_exception", "cash_flow_overdue", "reimbursement_overdue", "credit_cycle_overdue"]
        let statementTypes: Set<String> = ["statement_import_review", "statement_import_failed"]
        #expect(model.attention.map(\.sourceType) == [
            "operation_exception", "credit_cycle_overdue",
            "reconciliation_checkpoint", "statement_import_failed", "cash_flow_overdue", "reimbursement_overdue",
            "reconciliation_missing", "uncategorized_transaction", "ai_proposal", "statement_import_review"
        ])
        for item in model.attention {
            #expect(item.availableActions.count == 1)
            let action = try #require(item.availableActions.first)
            #expect(action.action == "ignore")
            if dismissible.contains(item.sourceType) {
                #expect(action.enabled && model.attentionActionReasons(for: item).first?.code == "f2_read_only")
            } else if statementTypes.contains(item.sourceType) {
                #expect(!action.enabled && action.reasonCode == "statement_import_attention_not_dismissible")
            } else { Issue.record("fixture source must remain one generated by reconciliation service") }
        }
        let reconciliationMissing = try #require(model.attention.first(where: { $0.sourceType == "reconciliation_missing" }))
        #expect(reconciliationMissing.deepLink == "fiscal://reconciliation/accounts/\(V15F2AFixtures.accountID)" && reconciliationMissing.severity == .info)
        let uncategorized = try #require(model.attention.first(where: { $0.sourceType == "uncategorized_transaction" }))
        #expect(uncategorized.severity == .info && uncategorized.amountMinor == nil)
        let count = await transport.allRequests().count
        for raw in ["https://example.invalid", "fiscal://accounts/not-a-uuid", "fiscal://accounts/\(V15F2AFixtures.accountID)/extra", "fiscal://transactions/\(V15F2AFixtures.transactionID)?evil=1", "fiscal://unknown/\(V15F2AFixtures.accountID)"] {
            await model.openLinkedRead(raw)
            guard case .unavailable = model.linkedReadPhase else { Issue.record("unsafe link must be unavailable"); continue }
        }
        await model.openAttention(reconciliationMissing)
        #expect((await transport.allRequests()).count == count)
        guard case .unavailable = model.linkedReadPhase else { Issue.record("reconciliation target must safely degrade in F2-A"); return }
        let unknown = try V15FixtureCodec.decoder.decode(V15AttentionItem.self, from: V15F2AFixtures.unknownAttention)
        await model.openAttention(unknown)
        #expect((await transport.allRequests()).count == count && model.attentionActionReasons(for: unknown).first?.code == "attention_action_unknown")
        await model.openAttention(uncategorized)
        guard case .transaction(let transaction) = model.linkedReadPhase else { Issue.record("allowlisted transaction link must read only transaction"); return }
        #expect(transaction.id == V15F2AFixtures.transactionID)
        #expect((await transport.allRequests()).allSatisfy { $0.method == "GET" })
    }

    @Test("unknown drill row stays display-only; service rejects invalid window and page bounds")
    @MainActor func unknownAndBounds() async throws {
        let unknown = try V15FixtureCodec.decoder.decode(V15FactDrillDownItem.self, from: V15F2AFixtures.unknownItem)
        guard case .unknown(let type) = unknown else { Issue.record("new item type must not decode as a known item"); return }
        #expect(type == "new_server_type")
        let transport = V15F2ATransport()
        let services = V15Services(transport: transport)
        let model = V15TodayReadModel(services: services)
        await model.openFactItem(unknown)
        guard case .unavailable = model.linkedReadPhase else { Issue.record("unknown row must never open a link"); return }
        do { _ = try await services.reports.facts(windowDays: 91); Issue.record("window bounds were not checked") } catch let failure as V15Failure { #expect(failure.code == "invalid_facts_window") } catch { Issue.record("wrong error") }
        let facts = try V15FixtureCodec.decoder.decode(V15Facts.self, from: V15F2AFixtures.facts())
        let scope = try #require(facts.cash.scope)
        do { _ = try await services.reports.drillDown(scope: scope, limit: 101); Issue.record("limit bounds were not checked") } catch let failure as V15Failure { #expect(failure.code == "invalid_facts_limit") } catch { Issue.record("wrong error") }
        #expect(V15TodayReadModel.shanghaiDateLabel(Date(timeIntervalSince1970: 0)).contains("1970"))
    }

    @Test("linked reads retry only a parsed safe locator and stale attempts cannot overwrite close or a newer link")
    @MainActor func linkedReadRetryAndOwnership() async throws {
        let retryTransport = V15F2ATransport(mode: .linkedReadFailsThenSucceeds)
        let retrying = V15TodayReadModel(services: V15Services(transport: retryTransport))
        await retrying.refresh()
        await retrying.openLinkedRead("fiscal://transactions/\(V15F2AFixtures.transactionID)")
        guard case .failed = retrying.linkedReadPhase else { Issue.record("safe linked read must surface its failure in-sheet"); return }
        #expect((await retryTransport.allRequests()).filter { $0.path == "transactions/\(V15F2AFixtures.transactionID)" }.count == 1)
        await retrying.retryLinkedRead()
        guard case .transaction(let value) = retrying.linkedReadPhase else { Issue.record("retry must reopen the retained safe locator"); return }
        #expect(value.id == V15F2AFixtures.transactionID)
        let afterSuccess = (await retryTransport.allRequests()).count
        retrying.closeLinkedRead()
        await retrying.retryLinkedRead()
        #expect((await retryTransport.allRequests()).count == afterSuccess)
        await retrying.openLinkedRead("fiscal://transactions/\(V15F2AFixtures.transactionID)?unsafe=1")
        guard case .unavailable = retrying.linkedReadPhase else { Issue.record("unsafe locator must remain unavailable"); return }
        await retrying.retryLinkedRead()
        #expect((await retryTransport.allRequests()).count == afterSuccess)

        let slow = V15TodayReadModel(services: V15Services(transport: V15F2ATransport(mode: .slowLinkedRead)))
        await slow.refresh()
        let cancelled = Task { await slow.openLinkedRead("fiscal://transactions/\(V15F2AFixtures.transactionID)") }
        await Task.yield()
        slow.closeLinkedRead()
        _ = await cancelled.result
        guard case .idle = slow.linkedReadPhase else { Issue.record("close must own a cancelled linked read"); return }

        let old = Task { await slow.openLinkedRead("fiscal://transactions/\(V15F2AFixtures.transactionID)") }
        await Task.yield()
        await slow.openLinkedRead("fiscal://accounts/\(V15F2AFixtures.accountID)")
        _ = await old.result
        guard case .account(let account) = slow.linkedReadPhase else { Issue.record("new linked read must own the final inspector state"); return }
        #expect(account.id == V15F2AFixtures.accountID)
    }
}
