import SwiftUI

public struct V15CreditView: View {
    @State private var model: V15CreditModel
    private let initialGalleryScenario: String?
    private let fixtureReconnectAction: (() -> Void)?
    public init(services: V15Services, offlineSnapshotAt: Date? = nil, offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)? = nil, initialGalleryScenario: String? = nil, fixtureReconnectAction: (() -> Void)? = nil) {
        _model = State(initialValue: .init(services: services, offlineSnapshotAt: offlineSnapshotAt, offlineSnapshotProvider: offlineSnapshotProvider))
        self.initialGalleryScenario = initialGalleryScenario
        self.fixtureReconnectAction = fixtureReconnectAction
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.md) {
                    header
                    accountPicker
                    content
                    if let at = model.offlineSnapshotAt {
                        V15OfflineReadOnlyBanner(snapshotAt: at).accessibilityIdentifier("v15.f3b1.offline")
                    }
                }
                .padding(V15Spacing.md)
            }
            .background(V15Palette.paper.color)
            .navigationTitle("信用账期")
            .task { await loadInitialState() }
            .sheet(isPresented: Binding(get: { model.scheduleSheetVisible }, set: { if !$0 { model.dismissScheduleSheet() } })) {
                scheduleSheet
            }
        }
        .accessibilityIdentifier("v15.f3b1.credit.ios")
    }

    private func loadInitialState() async {
        await model.load()
        guard let scenario = initialGalleryScenario else { return }
        if scenario == "credit-page-error" { await model.loadNextCycles(); return }
        guard ["credit-expired", "credit-disabled", "credit-conflict", "credit-field-error"].contains(scenario) else { return }
        model.openScheduleSheet(); model.cycleMode = .statementDayCutoff; model.statementDayText = "25"; model.dueDayText = "10"
        await model.requestSchedulePreview()
        if scenario == "credit-conflict" { await model.commitSchedule() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                Text("已知未来 · 信用账期").font(V15Typography.label).foregroundStyle(V15Palette.teal.color)
                Text("只以服务器账期和影响预览为准").font(V15Typography.surfaceTitle).foregroundStyle(V15Palette.ink.color)
            }
            Spacer()
            Button { Task { await model.reloadSelectedAccount() } } label: { Image(systemName: V15Symbol.retry) }
                .accessibilityIdentifier("v15.f3b1.reload")
        }
    }

    @ViewBuilder private var accountPicker: some View {
        if !model.accounts.isEmpty {
            Menu {
                ForEach(model.accounts) { account in
                    Button(account.name) { Task { await model.selectAccount(account) } }
                        .accessibilityIdentifier("v15.f3b1.account.\(account.id)")
                }
            } label: { Label(model.selectedAccount?.name ?? "选择信用账户", systemImage: "creditcard") }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("v15.f3b1.account-picker")
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .loading:
            V15LoadingSkeleton().accessibilityIdentifier("v15.f3b1.loading")
        case .failed(let failure):
            V15ServiceErrorState(message: failure.message) { Task { await model.load() } }.accessibilityIdentifier("v15.f3b1.error")
        case .empty:
            V15EmptyState(title: "目前没有信用账户", explanation: "账户创建和维护在主数据中完成。")
        case .loaded:
            if let account = model.selectedAccount { accountSummary(account) }
            V15Section("账期脊柱", detail: "上海业务日；点击查看账期事实") {
                ForEach(model.cycles) { cycle in
                    Button { Task { await model.selectCycle(cycle) } } label: { cycleRow(cycle) }
                        .buttonStyle(.plain).v15PlatformHitArea()
                        .accessibilityIdentifier("v15.f3b1.cycle.\(cycle.id)")
                }
                if model.nextCycleCursor != nil {
                    Button("读取下一页账期") { Task { await model.loadNextCycles() } }
                        .accessibilityIdentifier("v15.f3b1.cycles.next")
                }
                if case .failed(let failure) = model.cyclePagePhase {
                    V15ServiceErrorState(message: failure.message) { Task { await model.loadNextCycles() } }
                        .accessibilityIdentifier("v15.f3b1.cycles.page-error")
                }
            }
            cycleInspector
        }
    }

    private func accountSummary(_ account: V15CreditAccountSummary) -> some View {
        V15Section("当前信用事实", detail: "账单日 \(account.statementDay) · 还款日 \(account.dueDay)") {
            HStack {
                VStack(alignment: .leading) { Text("当前欠款").font(V15Typography.secondary); V15MoneyText(minorUnits: account.currentDebtMinor, direction: .outflow) }
                Spacer()
                Text(account.hasOverdueCycle ? "含逾期账期" : "无逾期账期").font(V15Typography.label).foregroundStyle(account.hasOverdueCycle ? V15Palette.gold.color : V15Palette.teal.color)
            }
            Button("调整账期") { model.openScheduleSheet() }.disabled(model.isOffline).accessibilityIdentifier("v15.f3b1.schedule.open")
            if model.isOffline { Text("离线快照不能修改账期。 ").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }
        }
    }

    private func cycleRow(_ cycle: V15CreditCycle) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                Text(cycle.isOpeningCycle ? "期初账期" : "账期").font(V15Typography.label).foregroundStyle(cycle.isOverdue ? V15Palette.gold.color : V15Palette.teal.color)
                Text("\(cycle.periodStart) 至 \(cycle.periodEnd)").font(V15Typography.body)
                Text("还款日 \(cycle.dueDate) · \(cycle.isOverdue ? "已逾期" : String(describing: cycle.status))").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
            }
            Spacer()
            V15MoneyText(minorUnits: cycle.remainingMinor, direction: .outflow, font: V15Typography.secondary)
        }
        .padding(V15Spacing.sm).background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
    }

    @ViewBuilder private var cycleInspector: some View {
        switch model.cycleDetailPhase {
        case .idle: EmptyView()
        case .loading: V15LoadingSkeleton()
        case .failed(let failure): V15ServiceErrorState(message: failure.message) {}
        case .loaded:
            if let cycle = model.selectedCycle {
                V15Section("账期检查器", detail: "服务器版本 \(cycle.version)") {
                    Text("消费、期初、还款和分期金额均为服务端事实。 ").font(V15Typography.secondary)
                    V15MoneyText(minorUnits: cycle.amountDueMinor, direction: .outflow)
                    if model.nextTransactionCursor != nil { Button("读取下一页账目") { Task { await model.loadNextTransactions() } }.accessibilityIdentifier("v15.f3b1.transactions.next") }
                    if case .failed(let failure) = model.transactionPagePhase { V15ServiceErrorState(message: failure.message) { Task { await model.loadNextTransactions() } }.accessibilityIdentifier("v15.f3b1.transactions.page-error") }
                }
            }
        }
    }

    private var scheduleSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.md) {
                    Text("第 1 步 · 设置账期").font(V15Typography.surfaceTitle)
                    Picker("账期方式", selection: $model.cycleMode) {
                        Text("账单日截点").tag(V15CreditCycleMode.statementDayCutoff)
                        Text("上个自然月").tag(V15CreditCycleMode.previousCalendarMonth)
                    }.accessibilityIdentifier("v15.f3b1.schedule.mode")
                    TextField("账单日（1–28）", text: $model.statementDayText).accessibilityIdentifier("v15.f3b1.schedule.statement-day")
                    TextField("还款日（1–28）", text: $model.dueDayText).accessibilityIdentifier("v15.f3b1.schedule.due-day")
                    reasons
                    Button("第 2 步 · 预览服务端影响") { Task { await model.requestSchedulePreview() } }
                        .disabled(!model.canRequestSchedulePreview)
                        .accessibilityIdentifier("v15.f3b1.schedule.preview")
                    if let reason = model.schedulePreviewDisabledReason {
                        Text(reason.message).font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color).accessibilityIdentifier("v15.f3b1.schedule.preview-reason")
                    }
                    // Keep the commit gate visible while an unresolved command
                    // owns this account.  The recovery controls below are the
                    // only legal actions; a disabled control without this
                    // reason would look like a silent no-op.
                    if model.scheduleCommandDisabledReason != nil {
                        Button("提交账期变更") { Task { await model.commitSchedule() } }
                            .disabled(!model.canCommitSchedule)
                            .accessibilityIdentifier("v15.f3b1.schedule.commit")
                        if let reason = model.scheduleDisabledReason {
                            Text(reason.message).font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color).accessibilityIdentifier("v15.f3b1.schedule.commit-reason")
                        }
                    }
                    previewSurface
                }.padding(V15Spacing.md)
            }
            .navigationTitle("调整账期")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { model.dismissScheduleSheet() }.accessibilityIdentifier("v15.f3b1.schedule.dismiss") } }
        }
        .accessibilityIdentifier("v15.f3b1.schedule.sheet")
    }

    @ViewBuilder private var reasons: some View {
        if !model.scheduleIssues.isEmpty { V15Section("请先修正") { ForEach(model.scheduleIssues, id: \.code) { Text($0.message).font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color) } }.accessibilityIdentifier("v15.f3b1.schedule.local-reasons") }
        if !model.scheduleServerFieldIssues.isEmpty { V15Section("服务器要求修正") { ForEach(model.scheduleServerFieldIssues, id: \.code) { Text($0.message).font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color) } }.accessibilityIdentifier("v15.f3b1.schedule.server-field-reasons") }
        if !model.scheduleServerReasons.isEmpty { V15Section("服务器影响说明") { ForEach(model.scheduleServerReasons, id: \.self) { Text($0).font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color) } }.accessibilityIdentifier("v15.f3b1.schedule.server-reasons") }
    }

    @ViewBuilder private var previewSurface: some View {
        switch model.schedulePhase {
        case .idle: EmptyView()
        case .previewing: V15LoadingSkeleton().accessibilityIdentifier("v15.f3b1.schedule.preview.loading")
        case .previewed:
            if let preview = model.schedulePreview {
                V15Section("第 3 步 · 确认影响", detail: "受影响账期 \(preview.affectedCycleCount) 个") {
                    Text("消费 \(preview.purchaseCount) 笔 · 还款 \(preview.repaymentCount) 笔 · 分期 \(preview.installmentPeriodCount) 期").font(V15Typography.secondary)
                    if let version = preview.expectedAccountVersion { Text("预览基于账户版本 \(version)").font(V15Typography.secondary).accessibilityIdentifier("v15.f3b1.schedule.preview.account-version") }
                    ForEach(preview.affectedCycles, id: \.cycleID) { item in Text("\(item.oldStatementDate) / \(item.oldDueDate) → \(item.newStatementDate) / \(item.newDueDate)，保留 \(item.preservedCheckpointCount) 个检查点").font(V15Typography.secondary) }
                    Button("提交账期变更") { Task { await model.commitSchedule() } }
                        .disabled(!model.canCommitSchedule)
                        .accessibilityIdentifier("v15.f3b1.schedule.commit")
                    if let reason = model.scheduleDisabledReason { Text(reason.message).font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color).accessibilityIdentifier("v15.f3b1.schedule.commit-reason") }
                }.accessibilityIdentifier("v15.f3b1.schedule.preview")
            }
        case .committing: V15LoadingSkeleton().accessibilityIdentifier("v15.f3b1.schedule.committing")
        case .succeeded(let result): V15Section("已提交", detail: "服务器数据版本 \(result.dataRevision.map(String.init) ?? "未提供")") { Text("账期已按服务端结果更新。 ").font(V15Typography.secondary) }.accessibilityIdentifier("v15.f3b1.schedule.receipt")
        case .readbackConfirmed: V15Section("已由账户事实确认") { Text("服务器当前账期与原提交意图一致；这是只读核对，不是提交回执。 ").font(V15Typography.secondary) }.accessibilityIdentifier("v15.f3b1.schedule.readback-confirmed")
        case .unknown: V15Section("提交结果未知") {
            Text("仅可用同一请求键重试，或刷新账户后核对。 ").font(V15Typography.secondary)
            switch model.unknownReadbackPhase {
            case .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f3b1.schedule.unknown.readback.loading")
            case .notConfirmed: Text(model.unknownReadbackNotice ?? "尚未确认：服务器事实不足以证明原提交已生效。 ").font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color).accessibilityIdentifier("v15.f3b1.schedule.unknown.readback.not-confirmed")
            case .failed(let failure): Text(failure.message).font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color).accessibilityIdentifier("v15.f3b1.schedule.unknown.readback.error")
            case .idle, .confirmed: EmptyView()
            }
            Button("用同一请求重试") { Task { await model.retryUnknownCommit() } }
                .disabled(model.unknownReadbackPhase == .loading || model.unknownRetryDisabledReason != nil)
                .accessibilityIdentifier("v15.f3b1.schedule.unknown.retry")
            if let reason = model.unknownRetryDisabledReason {
                Text(reason.message).font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color).accessibilityIdentifier("v15.f3b1.schedule.unknown.retry-reason")
            } else if let notice = model.unknownRetryNotice {
                Text(notice).font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color).accessibilityIdentifier("v15.f3b1.schedule.unknown.retry-notice")
            }
            Button("刷新账户后核对") { Task { await model.resolveUnknownByReadback() } }.disabled(model.unknownReadbackPhase == .loading).accessibilityIdentifier("v15.f3b1.schedule.unknown.readback")
            Button("放弃同一键恢复并刷新账户") { model.abandonUnknownAttempt() }
                .disabled(model.unknownReadbackPhase == .loading)
                .accessibilityIdentifier("v15.f3b1.schedule.unknown.abandon")
            if let fixtureReconnectAction {
                Button("恢复在线连接") { fixtureReconnectAction() }.accessibilityIdentifier("v15.f3b1.fixture.reconnect")
            }
        }.accessibilityIdentifier("v15.f3b1.schedule.unknown")
        case .conflict(let conflict): V15Section("账期已变化") { Text(conflict.message).font(V15Typography.secondary); if let error = model.scheduleReloadError { Text(error.message).font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color).accessibilityIdentifier("v15.f3b1.schedule.conflict.reload-error") }; Button("刷新账户后重新预览") { Task { await model.reloadAfterConflict() } }.accessibilityIdentifier("v15.f3b1.schedule.conflict.reload") }.accessibilityIdentifier("v15.f3b1.schedule.conflict")
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.requestSchedulePreview() } }.accessibilityIdentifier("v15.f3b1.schedule.error")
        }
    }
}
