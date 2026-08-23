import Foundation
import Testing

@testable import FiscalKit

@Suite("F3-B1 credit schedule")
struct F3B1Tests {
    @MainActor private func prepareSchedule(_ model: V15CreditModel) async {
        await model.load()
        model.openScheduleSheet()
        model.cycleMode = .statementDayCutoff
        model.statementDayText = "25"
        model.dueDayText = "10"
        await model.requestSchedulePreview()
    }

    @Test("an A command settling after B selection updates only A's command state")
    @MainActor func delayedACommandsNeverPolluteB() async {
        for mode in [F3B1Transport.Mode.commitDelayedSuccess, .commitDelayedConflict, .commitDelayedFailure, .commitDelayedUnknown] {
            let model = V15CreditModel(services: V15Services(transport: F3B1Transport(mode: mode)))
            await prepareSchedule(model)
            guard let first = model.accounts.first, let second = model.accounts.last else { Issue.record("credit account fixtures missing"); return }
            let submit = Task { @MainActor in await model.commitSchedule() }
            try? await Task.sleep(for: .milliseconds(20))
            await model.selectAccount(second)
            #expect(model.selectedAccount?.id == second.id && model.schedulePhase == .idle && model.schedulePreview == nil)
            _ = await submit.value
            #expect(model.selectedAccount?.id == second.id && model.schedulePhase == .idle && model.schedulePreview == nil)
            await model.selectAccount(first)
            switch mode {
            case .commitDelayedSuccess: guard case .succeeded = model.schedulePhase else { Issue.record("A success must remain on A"); continue }
            case .commitDelayedConflict: guard case .conflict = model.schedulePhase else { Issue.record("A conflict must remain on A"); continue }
            case .commitDelayedFailure: guard case .failed = model.schedulePhase else { Issue.record("A failure must remain on A"); continue }
            case .commitDelayedUnknown: guard case .unknown = model.schedulePhase else { Issue.record("A unknown must remain on A"); continue }
            default: Issue.record("unexpected command mode")
            }
        }
    }

    @Test("unknown recovery is account-scoped while B can preview commit and A replays its exact key")
    @MainActor func unknownRecoveryIsAccountScoped() async {
        let transport = F3B1Transport(mode: .commitUnknownReplayDelayed)
        let model = V15CreditModel(services: V15Services(transport: transport))
        await prepareSchedule(model)
        guard let first = model.accounts.first, let second = model.accounts.last else { Issue.record("credit account fixtures missing"); return }
        await model.commitSchedule()
        guard case .unknown = model.schedulePhase else { Issue.record("A must become unknown"); return }
        let aKey = model.lastCommitKey
        model.dismissScheduleSheet()
        await model.selectAccount(second)
        #expect(model.schedulePhase == .idle && model.schedulePreview == nil && model.lastCommitKey == nil)
        model.openScheduleSheet(); await model.requestSchedulePreview()
        #expect(model.canCommitSchedule)
        let bCommit = Task { @MainActor in await model.commitSchedule() }
        try? await Task.sleep(for: .milliseconds(20))
        await model.commitSchedule()
        _ = await bCommit.value
        guard case .succeeded = model.schedulePhase else { Issue.record("B must remain independently committable"); return }
        await model.selectAccount(first)
        guard case .unknown = model.schedulePhase else { Issue.record("returning to A must restore its recovery state"); return }
        #expect(model.lastCommitKey == aKey)
        await model.resolveUnknownByReadback()
        guard case .notConfirmed = model.unknownReadbackPhase else { Issue.record("A readback must stay available"); return }
        await model.retryUnknownCommit()
        guard case .succeeded = model.schedulePhase else { Issue.record("A must replay after B activity"); return }
        let wires = await transport.commitWires()
        #expect(wires.count == 3 && wires[0].idempotencyKey == wires[2].idempotencyKey && wires[0].body == wires[2].body && wires[1].idempotencyKey != wires[0].idempotencyKey)
    }

    @Test("only the selected unknown account may explicitly abandon its recovery")
    @MainActor func unknownAbandonIsAccountScoped() async {
        let model = V15CreditModel(services: V15Services(transport: F3B1Transport(mode: .commitUnknownThenSuccess)))
        await prepareSchedule(model)
        guard let first = model.accounts.first, let second = model.accounts.last else { Issue.record("credit account fixtures missing"); return }
        await model.commitSchedule(); model.dismissScheduleSheet(); await model.selectAccount(second)
        model.abandonUnknownAttempt()
        #expect(model.schedulePhase == .idle && model.scheduleDisabledReason?.code == "preview_required")
        await model.selectAccount(first)
        guard case .unknown = model.schedulePhase else { Issue.record("B cannot abandon A recovery"); return }
        model.abandonUnknownAttempt()
        #expect(model.schedulePhase == .idle && model.scheduleDisabledReason?.code == "reload_required")
    }

    @Test("delayed A master cannot overwrite a newer B account selection")
    @MainActor func delayedMasterSelectionKeepsBState() async {
        let model = V15CreditModel(services: V15Services(transport: F3B1Transport(mode: .masterSelectionRace)))
        let initialLoad = Task { @MainActor in await model.load() }
        try? await Task.sleep(for: .milliseconds(20))
        guard let second = model.accounts.last else { Issue.record("account list must arrive before delayed A master"); return }
        await model.selectAccount(second)
        _ = await initialLoad.value
        #expect(model.selectedAccount?.id == second.id)
        #expect(model.selectedAccountVersion == 7 && model.statementDayText == "18" && model.dueDayText == "3")
        #expect(model.cycles.count == 2 && model.cycles.allSatisfy { $0.accountID == second.id })
    }

    @Test("delayed A cycle page cannot clear or replace newer B cycles")
    @MainActor func delayedCyclePageKeepsBState() async {
        let model = V15CreditModel(services: V15Services(transport: F3B1Transport(mode: .cyclesSelectionRace)))
        await model.load()
        guard let first = model.accounts.first, let second = model.accounts.last else { Issue.record("credit account fixtures missing"); return }
        let delayedA = Task { @MainActor in await model.selectAccount(first) }
        try? await Task.sleep(for: .milliseconds(20))
        await model.selectAccount(second)
        _ = await delayedA.value
        #expect(model.selectedAccount?.id == second.id && model.selectedAccountVersion == 7)
        #expect(model.cycles.count == 2 && model.cycles.allSatisfy { $0.accountID == second.id } && model.nextCycleCursor != nil)
    }

    @Test("refresh load and selection race leaves the newest B account and draft intact")
    @MainActor func refreshLoadSelectionRaceKeepsBState() async {
        let model = V15CreditModel(services: V15Services(transport: F3B1Transport(mode: .refreshLoadSelectionRace)))
        await model.load()
        guard let second = model.accounts.last else { Issue.record("second credit account fixture missing"); return }
        let refresh = Task { @MainActor in await model.reloadSelectedAccount() }
        try? await Task.sleep(for: .milliseconds(20))
        let replacementLoad = Task { @MainActor in await model.load() }
        try? await Task.sleep(for: .milliseconds(20))
        await model.selectAccount(second)
        _ = await refresh.value; _ = await replacementLoad.value
        #expect(model.selectedAccount?.id == second.id && model.selectedAccountVersion == 7)
        #expect(model.statementDayText == "18" && model.dueDayText == "3")
        #expect(model.cycles.count == 2 && model.cycles.allSatisfy { $0.accountID == second.id })
    }

    @Test("all P33 credit reads retain server fields, opaque cursors and local page errors")
    @MainActor func readsAndPages() async {
        let transport = F3B1Transport(mode: .cyclePageFailure)
        let model = V15CreditModel(services: V15Services(transport: transport))
        await model.load()
        #expect(model.accounts.count == 2 && model.cycles.count == 2)
        guard let second = model.accounts.last else { Issue.record("second account fixture missing"); return }
        await model.selectAccount(second)
        #expect(model.selectedAccount?.id == second.id && model.cycles.allSatisfy { $0.accountID == second.id })
        await model.selectAccount(model.accounts[0])
        let opening = model.cycles.first(where: \.isOpeningCycle)
        #expect(opening?.isOverdue == true && opening?.purchaseMinor == 125_000)
        await model.loadNextCycles()
        #expect(model.cycles.count == 2 && model.nextCycleCursor != nil)
        guard case .failed = model.cyclePagePhase else { Issue.record("failed next page must stay local"); return }
        guard let cycle = model.cycles.first else { Issue.record("missing cycle"); return }
        await model.selectCycle(cycle)
        #expect(model.selectedCycle?.installmentFeeMinor == 2_000 && model.cycleTransactions.isEmpty)
        let requests = await transport.allRequests()
        #expect(requests.contains { $0.path == "credit-accounts/\(V15F3B1Fixtures.accountID)/cycles" && $0.query.contains(.init(name: "cursor", value: "opaque-credit-next")) })
    }

    @Test("preview invalidates on every input and commits only exact preview token with account version")
    @MainActor func previewLifecycleAndCommit() async {
        let transport = F3B1Transport(mode: .normal)
        let model = V15CreditModel(services: V15Services(transport: transport))
        await model.load(); model.openScheduleSheet()
        model.cycleMode = .statementDayCutoff; model.statementDayText = "25"; model.dueDayText = "10"
        await model.requestSchedulePreview()
        #expect(model.schedulePreview?.previewToken == V15F3B1Fixtures.token && model.canCommitSchedule)
        model.statementDayText = "29"
        #expect(model.schedulePreview == nil && !model.canCommitSchedule && model.scheduleDisabledReason?.fieldPath == "statement_day")
        model.statementDayText = "25"; await model.requestSchedulePreview(); await model.commitSchedule()
        guard case .succeeded = model.schedulePhase else { Issue.record("successful commit must surface server result"); return }
        let allRequests = await transport.allRequests()
        let commits = allRequests.filter { $0.path.hasSuffix("schedule-change") }
        #expect(commits.count == 1 && commits[0].headers["Idempotency-Key"] != nil)
        let previews = allRequests.filter { $0.path.hasSuffix("schedule-change-preview") }
        #expect(previews.count == 2)
    }

    @Test("an unknown command blocks preview traffic and keeps same-key recovery visible until it settles")
    @MainActor func unknownCommandBlocksPreviewUntilSameKeyRecovery() async {
        let transport = F3B1Transport(mode: .commitUnknownThenSuccess)
        let model = V15CreditModel(services: V15Services(transport: transport))
        await prepareSchedule(model)
        await model.commitSchedule()
        guard case .unknown = model.schedulePhase else { Issue.record("fixture must enter response-unknown"); return }
        #expect(model.schedulePreview == nil)
        let key = model.lastCommitKey
        let before = (await transport.allRequests()).filter { $0.path.hasSuffix("schedule-change-preview") }.count
        await model.requestSchedulePreview()
        let after = (await transport.allRequests()).filter { $0.path.hasSuffix("schedule-change-preview") }.count
        guard case .unknown = model.schedulePhase else { Issue.record("blocked preview must preserve unknown recovery phase"); return }
        #expect(before == after && model.lastCommitKey == key && model.schedulePreview == nil)
        #expect(!model.canRequestSchedulePreview && !model.canCommitSchedule)
        #expect(model.schedulePreviewDisabledReason?.code == "unknown_schedule_recovery_required")
        #expect(model.scheduleDisabledReason?.code == "unknown_schedule_recovery_required")
        await model.retryUnknownCommit()
        guard case .succeeded = model.schedulePhase else { Issue.record("same-key recovery must settle the command"); return }
        #expect(model.canRequestSchedulePreview)
        await model.requestSchedulePreview()
        #expect(model.canCommitSchedule)
    }

    @Test("an in-flight command blocks preview traffic without replacing its phase or preview")
    @MainActor func committingCommandBlocksPreviewUntilItSettles() async {
        let transport = F3B1Transport(mode: .commitDelayedSuccess)
        let model = V15CreditModel(services: V15Services(transport: transport))
        await prepareSchedule(model)
        let submit = Task { @MainActor in await model.commitSchedule() }
        try? await Task.sleep(for: .milliseconds(20))
        guard case .committing = model.schedulePhase else { Issue.record("fixture must still be committing"); return }
        let before = (await transport.allRequests()).filter { $0.path.hasSuffix("schedule-change-preview") }.count
        await model.requestSchedulePreview()
        let after = (await transport.allRequests()).filter { $0.path.hasSuffix("schedule-change-preview") }.count
        guard case .committing = model.schedulePhase else { Issue.record("blocked preview must preserve in-flight command phase"); return }
        #expect(before == after && model.schedulePreview != nil)
        #expect(!model.canRequestSchedulePreview && !model.canCommitSchedule)
        #expect(model.schedulePreviewDisabledReason?.code == "schedule_command_in_flight")
        #expect(model.scheduleDisabledReason?.code == "schedule_command_in_flight")
        _ = await submit.value
        guard case .succeeded = model.schedulePhase else { Issue.record("in-flight command must still settle normally"); return }
    }

    @Test("normal and same-key success stay hard-gated through their delayed post-commit refresh")
    @MainActor func postSuccessRefreshKeepsEveryCommandActionGated() async {
        for (mode, replay) in [(F3B1Transport.Mode.commitSuccessPostReloadDelayed, false), (.commitUnknownReplayPostReloadDelayed, true)] {
            let transport = F3B1Transport(mode: mode)
            let model = V15CreditModel(services: V15Services(transport: transport))
            await prepareSchedule(model)
            let completion: Task<Void, Never>
            if replay {
                await model.commitSchedule()
                guard case .unknown = model.schedulePhase else { Issue.record("replay fixture must enter unknown"); continue }
                completion = Task { @MainActor in await model.retryUnknownCommit() }
            } else {
                completion = Task { @MainActor in await model.commitSchedule() }
            }
            try? await Task.sleep(for: .milliseconds(40))
            guard case .committing = model.schedulePhase else { Issue.record("post-success refresh must retain committing phase"); continue }
            let before = await transport.allRequests()
            let previewCount = before.filter { $0.path.hasSuffix("schedule-change-preview") }.count
            let commitCount = before.filter { $0.path.hasSuffix("schedule-change") }.count
            await model.requestSchedulePreview(); await model.commitSchedule(); await model.retryUnknownCommit(); await model.resolveUnknownByReadback(); model.abandonUnknownAttempt()
            let after = await transport.allRequests()
            guard case .committing = model.schedulePhase else { Issue.record("actions during refresh must not replace the committing phase"); continue }
            #expect(after.filter { $0.path.hasSuffix("schedule-change-preview") }.count == previewCount)
            #expect(after.filter { $0.path.hasSuffix("schedule-change") }.count == commitCount)
            #expect(!model.canRequestSchedulePreview && !model.canCommitSchedule)
            #expect(model.schedulePreviewDisabledReason?.code == "schedule_command_in_flight")
            #expect(model.scheduleDisabledReason?.message == "账期变更正在提交/刷新结果，请稍候；此时不能重新预览或重复提交。")
            _ = await completion.value
            guard case .succeeded = model.schedulePhase else { Issue.record("post-refresh command must expose its real success only after reload"); continue }
            #expect(model.canRequestSchedulePreview)
        }
    }

    @Test("expiry disabled server action conflict and response-unknown stay visible and safe")
    @MainActor func gatesAndUnknownRetry() async {
        let expired = V15CreditModel(services: V15Services(transport: F3B1Transport(mode: .previewExpired)))
        await expired.load(); expired.cycleMode = .statementDayCutoff; expired.statementDayText = "25"; expired.dueDayText = "10"; await expired.requestSchedulePreview()
        #expect(expired.scheduleDisabledReason?.code == "preview_expired")
        let disabled = V15CreditModel(services: V15Services(transport: F3B1Transport(mode: .previewDisabled)))
        await disabled.load(); disabled.cycleMode = .statementDayCutoff; disabled.statementDayText = "25"; disabled.dueDayText = "10"; await disabled.requestSchedulePreview()
        #expect(disabled.scheduleDisabledReason?.code == "server_action_unavailable")
        let conflict = V15CreditModel(services: V15Services(transport: F3B1Transport(mode: .commitConflict)))
        await conflict.load(); conflict.cycleMode = .statementDayCutoff; conflict.statementDayText = "25"; conflict.dueDayText = "10"; await conflict.requestSchedulePreview(); await conflict.commitSchedule()
        guard case .conflict = conflict.schedulePhase else { Issue.record("409 must force reload + preview"); return }
        let conflictThenSuccess = V15CreditModel(services: V15Services(transport: F3B1Transport(mode: .commitConflictThenSuccess)))
        await conflictThenSuccess.load(); conflictThenSuccess.cycleMode = .statementDayCutoff; conflictThenSuccess.statementDayText = "25"; conflictThenSuccess.dueDayText = "10"; await conflictThenSuccess.requestSchedulePreview(); await conflictThenSuccess.commitSchedule()
        await conflictThenSuccess.reloadAfterConflict(); await conflictThenSuccess.requestSchedulePreview(); await conflictThenSuccess.commitSchedule()
        guard case .succeeded = conflictThenSuccess.schedulePhase else { Issue.record("409 recovery must reload, preview again, then settle from the server result"); return }
        let transport = F3B1Transport(mode: .commitUnknownThenSuccess)
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let unknown = V15CreditModel(services: V15Services(transport: transport), now: { clock })
        await unknown.load(); unknown.cycleMode = .statementDayCutoff; unknown.statementDayText = "25"; unknown.dueDayText = "10"; await unknown.requestSchedulePreview(); await unknown.commitSchedule()
        guard case .unknown = unknown.schedulePhase else { Issue.record("response unknown must not claim success"); return }
        let original = unknown.lastCommitKey; unknown.statementDayText = "26"; clock = Date(timeIntervalSince1970: 2_000_000_000); await unknown.retryUnknownCommit()
        guard case .succeeded = unknown.schedulePhase else { Issue.record("same-key replay must settle result"); return }
        let wires = await transport.commitWires()
        #expect(wires.count == 2 && wires.allSatisfy { $0.idempotencyKey == original?.uuidString } && wires[0].body == wires[1].body && wires[1].body.contains("\"statement_day\":25"))
    }

    @Test("unknown replay records an honest definitive expiry instead of making a new write")
    @MainActor func unknownReplayExpiry() async {
        let transport = F3B1Transport(mode: .commitUnknownThenExpired)
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let model = V15CreditModel(services: V15Services(transport: transport), now: { clock })
        await model.load(); model.openScheduleSheet(); model.cycleMode = .statementDayCutoff; model.statementDayText = "25"; model.dueDayText = "10"; await model.requestSchedulePreview(); await model.commitSchedule()
        clock = Date(timeIntervalSince1970: 2_000_000_000); await model.retryUnknownCommit()
        guard case .failed(let failure) = model.schedulePhase else { Issue.record("server expiry must remain visible"); return }
        let wires = await transport.commitWires()
        #expect(failure.code == "preview_expired" && wires.count == 2)
    }

    @Test("unknown readback failure retains both recovery actions and the exact replay")
    @MainActor func unknownReadbackFailureThenReplay() async {
        let transport = F3B1Transport(mode: .commitUnknownReadbackFails)
        let model = V15CreditModel(services: V15Services(transport: transport))
        await model.load(); model.openScheduleSheet(); model.cycleMode = .statementDayCutoff; model.statementDayText = "25"; model.dueDayText = "10"
        await model.requestSchedulePreview(); await model.commitSchedule(); await model.resolveUnknownByReadback()
        guard case .unknown = model.schedulePhase, case .failed(let failure) = model.unknownReadbackPhase else { Issue.record("failed readback must retain response-unknown recovery"); return }
        #expect(failure.message == "账户核对读取失败。")
        await model.retryUnknownCommit()
        guard case .succeeded = model.schedulePhase else { Issue.record("same-key replay must remain available after readback failure"); return }
        let wires = await transport.commitWires()
        #expect(wires.count == 2 && wires[0] == wires[1])
    }

    @Test("unknown readback keeps replay when current server facts cannot prove the intent")
    @MainActor func unknownReadbackOldStateRetainsAttempt() async {
        let transport = F3B1Transport(mode: .commitUnknownReadbackOldState)
        let model = V15CreditModel(services: V15Services(transport: transport))
        await model.load(); model.openScheduleSheet(); model.cycleMode = .statementDayCutoff; model.statementDayText = "25"; model.dueDayText = "10"
        await model.requestSchedulePreview(); await model.commitSchedule(); await model.resolveUnknownByReadback()
        guard case .unknown = model.schedulePhase, case .notConfirmed = model.unknownReadbackPhase else { Issue.record("old facts must say unconfirmed, not discard the attempt"); return }
        await model.retryUnknownCommit()
        let wires = await transport.commitWires()
        #expect(wires.count == 2 && wires[0] == wires[1])
    }

    @Test("matching schedule and advanced account version can confirm unknown by readback")
    @MainActor func unknownReadbackMatchingStateConfirmsWithoutReceipt() async {
        let transport = F3B1Transport(mode: .commitUnknownReadbackMatches)
        let model = V15CreditModel(services: V15Services(transport: transport))
        await model.load(); model.openScheduleSheet(); model.cycleMode = .statementDayCutoff; model.statementDayText = "25"; model.dueDayText = "10"
        await model.requestSchedulePreview(); await model.commitSchedule(); await model.resolveUnknownByReadback()
        #expect(model.schedulePhase == .readbackConfirmed && model.unknownReadbackPhase == .confirmed)
        await model.retryUnknownCommit()
        let wires = await transport.commitWires()
        #expect(wires.count == 1)
    }

    @Test("unknown readback forces every proving fact fresh while ordinary reads retain cache defaults")
    @MainActor func unknownReadbackForcesFreshFacts() async {
        let transport = F3B1Transport(mode: .commitUnknownReadbackFresh)
        let model = V15CreditModel(services: V15Services(transport: transport))
        await model.load(); model.openScheduleSheet(); model.cycleMode = .statementDayCutoff; model.statementDayText = "25"; model.dueDayText = "10"
        await model.requestSchedulePreview(); await model.commitSchedule(); await model.resolveUnknownByReadback()
        #expect(model.schedulePhase == .readbackConfirmed)
        let requests = await transport.allRequests()
        guard let commit = requests.firstIndex(where: { $0.path.hasSuffix("schedule-change") && $0.method == "POST" }) else { Issue.record("missing unknown commit"); return }
        let readback = requests.suffix(from: requests.index(after: commit)).filter { $0.method == "GET" }
        let expectedPrefix = [
            "credit-accounts/\(V15F3B1Fixtures.accountID)",
            "accounts/\(V15F3B1Fixtures.accountID)",
            "credit-accounts/\(V15F3B1Fixtures.accountID)/cycles"
        ]
        #expect(Array(readback.prefix(3).map(\.path)) == expectedPrefix)
        #expect(readback.count == 5 && readback.allSatisfy { $0.readCachePolicy == .reloadIgnoringCache })
        #expect(requests.prefix(upTo: commit).filter { $0.method == "GET" }.allSatisfy { $0.readCachePolicy == .standard })
    }

    @Test("decoded offline fallback cannot confirm unknown attempt")
    @MainActor func unknownReadbackOfflineFallbackRetainsAttempt() async {
        let marker = F3B1OfflineSnapshotMarker()
        let transport = F3B1Transport(mode: .commitUnknownReadbackOfflineFallback, offlineSnapshotMarker: marker)
        let model = V15CreditModel(services: V15Services(transport: transport), offlineSnapshotProvider: { marker.snapshotAt })
        await model.load(); model.openScheduleSheet(); model.cycleMode = .statementDayCutoff; model.statementDayText = "25"; model.dueDayText = "10"
        await model.requestSchedulePreview(); await model.commitSchedule(); await model.resolveUnknownByReadback()
        guard case .unknown = model.schedulePhase, case .notConfirmed = model.unknownReadbackPhase else { Issue.record("offline fallback must retain the unknown attempt"); return }
        #expect(model.unknownReadbackNotice == "离线时无法检查最新状态。")
        let wires = await transport.commitWires()
        #expect(wires.count == 1)
    }

    @Test("double unknown readback is a single flight")
    @MainActor func doubleUnknownReadbackIsSingleFlight() async {
        let transport = F3B1Transport(mode: .commitUnknownReadbackDelayed)
        let model = V15CreditModel(services: V15Services(transport: transport))
        await model.load(); model.openScheduleSheet(); model.cycleMode = .statementDayCutoff; model.statementDayText = "25"; model.dueDayText = "10"
        await model.requestSchedulePreview(); await model.commitSchedule()
        let first = Task { @MainActor in await model.resolveUnknownByReadback() }
        try? await Task.sleep(for: .milliseconds(20)); await model.resolveUnknownByReadback(); _ = await first.value
        #expect(await transport.readbackRequestCount() == 1)
    }

    @Test("offline unknown retry preserves the immutable attempt until online same-key replay")
    @MainActor func unknownRetryOfflineThenOnlineUsesCapturedWire() async {
        let marker = F3B1OfflineSnapshotMarker()
        let transport = F3B1Transport(mode: .commitUnknownThenSuccess)
        let model = V15CreditModel(services: V15Services(transport: transport), offlineSnapshotProvider: { marker.snapshotAt })
        await model.load(); model.openScheduleSheet(); model.cycleMode = .statementDayCutoff; model.statementDayText = "25"; model.dueDayText = "10"
        await model.requestSchedulePreview(); await model.commitSchedule()
        let key = model.lastCommitKey
        marker.snapshotAt = Date(timeIntervalSince1970: 1_786_464_000)
        await model.retryUnknownCommit()
        guard case .unknown = model.schedulePhase else { Issue.record("offline replay must preserve the unknown gate"); return }
        #expect(model.lastCommitKey == key && model.unknownRetryNotice == "离线时无法检查保存结果。")
        #expect((await transport.commitWires()).count == 1)
        marker.snapshotAt = nil
        await model.retryUnknownCommit()
        guard case .succeeded = model.schedulePhase else { Issue.record("online recovery must replay the stored request"); return }
        let wires = await transport.commitWires()
        #expect(wires.count == 2 && wires[0] == wires[1] && wires.allSatisfy { $0.idempotencyKey == key?.uuidString })
    }

    @Test("offline response during unknown replay retains attempt instead of failing")
    @MainActor func unknownRetryOfflineRaceRetainsAttempt() async {
        let transport = F3B1Transport(mode: .commitUnknownRetryOffline)
        let model = V15CreditModel(services: V15Services(transport: transport))
        await model.load(); model.openScheduleSheet(); model.cycleMode = .statementDayCutoff; model.statementDayText = "25"; model.dueDayText = "10"
        await model.requestSchedulePreview(); await model.commitSchedule()
        let key = model.lastCommitKey
        await model.retryUnknownCommit()
        guard case .unknown = model.schedulePhase else { Issue.record("offline transport race must retain unknown recovery"); return }
        #expect(model.lastCommitKey == key && model.unknownRetryNotice == "离线时无法检查保存结果。")
        await model.retryUnknownCommit()
        guard case .succeeded = model.schedulePhase else { Issue.record("same key must remain replayable after offline race"); return }
        let wires = await transport.commitWires()
        #expect(wires.count == 3 && wires.dropFirst().allSatisfy { $0 == wires[0] })
    }

    @Test("double unknown replay is a single flight")
    @MainActor func doubleUnknownReplayIsSingleFlight() async {
        let transport = F3B1Transport(mode: .commitUnknownReplayDelayed)
        let model = V15CreditModel(services: V15Services(transport: transport))
        await model.load(); model.openScheduleSheet(); model.cycleMode = .statementDayCutoff; model.statementDayText = "25"; model.dueDayText = "10"
        await model.requestSchedulePreview(); await model.commitSchedule()
        let first = Task { @MainActor in await model.retryUnknownCommit() }
        try? await Task.sleep(for: .milliseconds(20)); await model.retryUnknownCommit(); _ = await first.value
        guard case .succeeded = model.schedulePhase else { Issue.record("delayed unknown replay must settle once"); return }
        #expect((await transport.commitWires()).count == 2)
    }

    @Test("conflict cannot clear until account and master refresh both succeed")
    @MainActor func conflictReloadFailureThenRetry() async {
        let model = V15CreditModel(services: V15Services(transport: F3B1Transport(mode: .reloadFailsOnceAfterConflict)))
        await model.load(); model.openScheduleSheet(); model.cycleMode = .statementDayCutoff; model.statementDayText = "25"; model.dueDayText = "10"; await model.requestSchedulePreview(); await model.commitSchedule()
        await model.reloadAfterConflict()
        #expect(model.scheduleReloadRequired && model.scheduleReloadError != nil && !model.canCommitSchedule)
        await model.reloadAfterConflict()
        #expect(!model.scheduleReloadRequired && model.scheduleReloadError == nil)
        await model.requestSchedulePreview()
        #expect(model.canCommitSchedule)
    }

    @Test("double schedule submit has one in-flight request")
    @MainActor func doubleCommitIsSingleFlight() async {
        let transport = F3B1Transport(mode: .commitDelayedSuccess)
        let model = V15CreditModel(services: V15Services(transport: transport))
        await model.load(); model.openScheduleSheet(); model.cycleMode = .statementDayCutoff; model.statementDayText = "25"; model.dueDayText = "10"; await model.requestSchedulePreview()
        let first = Task { @MainActor in await model.commitSchedule() }
        try? await Task.sleep(for: .milliseconds(20)); await model.commitSchedule(); _ = await first.value
        let wires = await transport.commitWires()
        #expect(wires.count == 1)
    }

    @Test("server field validation stays in the schedule sheet model")
    @MainActor func serverFieldErrors() async {
        let model = V15CreditModel(services: V15Services(transport: F3B1Transport(mode: .previewFieldError)))
        await model.load(); model.openScheduleSheet(); model.cycleMode = .statementDayCutoff; model.statementDayText = "25"; model.dueDayText = "10"
        await model.requestSchedulePreview()
        #expect(model.scheduleServerFieldIssues == [.init(code: "due_day_invalid", message: "还款日不符合当前账期规则。", fieldPath: "due_day")])
    }

    @Test("offline blocks all schedule writes before transport")
    @MainActor func offlineWritesAreZero() async {
        let transport = F3B1Transport(mode: .normal)
        let model = V15CreditModel(services: V15Services(transport: transport), offlineSnapshotAt: Date(timeIntervalSince1970: 1))
        await model.load(); model.openScheduleSheet(); await model.requestSchedulePreview(); await model.commitSchedule()
        let requests = await transport.allRequests()
        #expect(requests.allSatisfy { !$0.path.contains("schedule-change") })
        #expect(model.scheduleDisabledReason?.code == "offline_read_only")
    }
}
