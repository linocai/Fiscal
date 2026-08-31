import SwiftUI

public struct V15CreditView: View {
    @State private var model: V15CreditModel
    private let initialGalleryScenario: String?
    private let fixtureReconnectAction: (() -> Void)?
    private let initialCycle: V15CreditCycle?
    public init(services: V15Services, offlineSnapshotAt: Date? = nil, offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)? = nil, initialGalleryScenario: String? = nil, fixtureReconnectAction: (() -> Void)? = nil, initialCycle: V15CreditCycle? = nil) {
        _model = State(initialValue: .init(services: services, offlineSnapshotAt: offlineSnapshotAt, offlineSnapshotProvider: offlineSnapshotProvider))
        self.initialGalleryScenario = initialGalleryScenario
        self.fixtureReconnectAction = fixtureReconnectAction
        self.initialCycle = initialCycle
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
        if let initialCycle, let account = model.accounts.first(where: { $0.id == initialCycle.accountID }) {
            await model.selectAccount(account)
            await model.selectCycle(initialCycle)
        }
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
                Text("账期与金额以最新数据为准").font(V15Typography.surfaceTitle).foregroundStyle(V15Palette.ink.color)
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
            .buttonStyle(.plain)
            .padding(.horizontal, V15Spacing.sm)
            .padding(.vertical, V15Spacing.xs)
            .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
            .overlay { RoundedRectangle(cornerRadius: V15Radius.control).stroke(V15Palette.hairline.color) }
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
            V15Section("账期", detail: "点击查看详情") {
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
        V15Section("信用概览", detail: "账单日 \(account.statementDay) · 还款日 \(account.dueDay)") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: V15Spacing.sm)], alignment: .leading, spacing: V15Spacing.sm) {
                creditMetric("信用额度", account.creditLimitMinor, .neutral)
                creditMetric("当前欠款", account.currentDebtMinor, .outflow)
                creditMetric("可用额度", account.availableCreditMinor, .balance)
                creditMetric("超额", account.overLimitMinor, account.overLimitMinor > 0 ? .outflow : .neutral)
            }
            Text(account.hasOverdueCycle ? "含逾期账期" : "无逾期账期").font(V15Typography.label).foregroundStyle(account.hasOverdueCycle ? V15Palette.gold.color : V15Palette.teal.color)
            if account.activeInstallmentCount > 0 || account.futureScheduledGrossMinor > 0 {
                V15PreviewState {
                    VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                        Text("未来计划分期").font(V15Typography.body.weight(.semibold))
                        HStack { Text("\(account.activeInstallmentCount) 个进行中计划").font(V15Typography.secondary); Spacer(); V15MoneyText(minorUnits: account.futureScheduledGrossMinor, direction: .outflow) }
                        Text("未来计划总额不计入上面的当前欠款；已出账期数只由对应账期体现。")
                            .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("v15.f3b1.future-installments")
            }
            Button("调整账期") { model.openScheduleSheet() }.disabled(model.isOffline).accessibilityIdentifier("v15.f3b1.schedule.open")
            if model.isOffline { Text("离线时不能修改账期。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }
        }
    }

    private func cycleRow(_ cycle: V15CreditCycle) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                Text(cycle.isOpeningCycle ? "期初账期" : "账期").font(V15Typography.label).foregroundStyle(cycle.isOverdue ? V15Palette.gold.color : V15Palette.teal.color)
                Text("\(cycle.periodStart) 至 \(cycle.periodEnd)").font(V15Typography.body)
                Text("还款日 \(cycle.dueDate) · \(cycleStatusLabel(cycle.status))").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
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
                V15Section("账期详情") {
                    Text("这里汇总消费、期初余额、还款和分期金额。").font(V15Typography.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: V15Spacing.sm)], alignment: .leading, spacing: V15Spacing.sm) {
                        creditMetric("本期应还", cycle.amountDueMinor, .outflow)
                        creditMetric("已还", cycle.repaidMinor, .neutral)
                        creditMetric("仍需还", cycle.remainingMinor, .outflow)
                        creditMetric("本期消费", cycle.purchaseMinor, .outflow)
                        creditMetric("分期本金", cycle.installmentPrincipalMinor, .neutral)
                        creditMetric("分期手续费", cycle.installmentFeeMinor, .neutral)
                    }
                    if cycle.openingMinor != 0 { Text("含期初欠款 \(money(cycle.openingMinor))").font(V15Typography.secondary) }
                    if model.nextTransactionCursor != nil { Button("读取下一页账目") { Task { await model.loadNextTransactions() } }.accessibilityIdentifier("v15.f3b1.transactions.next") }
                    if case .failed(let failure) = model.transactionPagePhase { V15ServiceErrorState(message: failure.message) { Task { await model.loadNextTransactions() } }.accessibilityIdentifier("v15.f3b1.transactions.page-error") }
                }
            }
        }
    }

    private func creditMetric(_ title: String, _ value: V15MinorUnits, _ direction: V15MoneyDirection) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.xxs) {
            Text(title).font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.62))
            V15MoneyText(minorUnits: value, direction: direction, font: V15Typography.money)
        }
        .padding(V15Spacing.sm).frame(maxWidth: .infinity, alignment: .leading)
        .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
    }
    private func cycleStatusLabel(_ value: V15CreditCycleStatus) -> String { switch value { case .open: "开放"; case .unpaid: "未还"; case .partial: "部分已还"; case .overdue: "已逾期"; case .settled: "已结清"; case .unknown: "未知状态" } }
    private func money(_ value: V15MinorUnits) -> String { V15MoneyPresentation(minorUnits: value, direction: .neutral).text }

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
                    Button("第 2 步 · 取预览") { Task { await model.requestSchedulePreview() } }
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
        if !model.scheduleServerFieldIssues.isEmpty { V15Section("需要修正") { ForEach(model.scheduleServerFieldIssues, id: \.code) { Text($0.message).font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color) } }.accessibilityIdentifier("v15.f3b1.schedule.server-field-reasons") }
        if !model.scheduleServerReasons.isEmpty { V15Section("影响说明") { ForEach(model.scheduleServerReasons, id: \.self) { Text($0).font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color) } }.accessibilityIdentifier("v15.f3b1.schedule.server-reasons") }
    }

    @ViewBuilder private var previewSurface: some View {
        switch model.schedulePhase {
        case .idle: EmptyView()
        case .previewing: V15LoadingSkeleton().accessibilityIdentifier("v15.f3b1.schedule.preview.loading")
        case .previewed:
            if let preview = model.schedulePreview {
                V15Section("第 3 步 · 确认影响", detail: "受影响账期 \(preview.affectedCycleCount) 个") {
                    Text("消费 \(preview.purchaseCount) 笔 · 还款 \(preview.repaymentCount) 笔 · 分期 \(preview.installmentPeriodCount) 期").font(V15Typography.secondary)
                    if preview.expectedAccountVersion != nil { Text("预览基于当前账户数据").font(V15Typography.secondary).accessibilityIdentifier("v15.f3b1.schedule.preview.account-version") }
                    ForEach(preview.affectedCycles, id: \.cycleID) { item in Text("\(item.oldStatementDate) / \(item.oldDueDate) → \(item.newStatementDate) / \(item.newDueDate)，保留 \(item.preservedCheckpointCount) 个检查点").font(V15Typography.secondary) }
                    Button("提交账期变更") { Task { await model.commitSchedule() } }
                        .disabled(!model.canCommitSchedule)
                        .accessibilityIdentifier("v15.f3b1.schedule.commit")
                    if let reason = model.scheduleDisabledReason { Text(reason.message).font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color).accessibilityIdentifier("v15.f3b1.schedule.commit-reason") }
                }.accessibilityIdentifier("v15.f3b1.schedule.preview")
            }
        case .committing: V15LoadingSkeleton().accessibilityIdentifier("v15.f3b1.schedule.committing")
        case .succeeded: V15Section("已提交") { Text("账期已更新。").font(V15Typography.secondary) }.accessibilityIdentifier("v15.f3b1.schedule.receipt")
        case .readbackConfirmed: V15Section("已核对") { Text("当前账期与刚才的修改一致。").font(V15Typography.secondary) }.accessibilityIdentifier("v15.f3b1.schedule.readback-confirmed")
        case .unknown: V15Section("提交结果未知") {
            Text("可以安全检查保存结果，或刷新账户后核对。").font(V15Typography.secondary)
            switch model.unknownReadbackPhase {
            case .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f3b1.schedule.unknown.readback.loading")
            case .notConfirmed: Text(model.unknownReadbackNotice ?? "尚未确认这次修改是否生效。").font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color).accessibilityIdentifier("v15.f3b1.schedule.unknown.readback.not-confirmed")
            case .failed(let failure): Text(failure.message).font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color).accessibilityIdentifier("v15.f3b1.schedule.unknown.readback.error")
            case .idle, .confirmed: EmptyView()
            }
            Button("安全检查保存结果") { Task { await model.retryUnknownCommit() } }
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
                Button("恢复连接") { fixtureReconnectAction() }.accessibilityIdentifier("v15.f3b1.fixture.reconnect")
            }
        }.accessibilityIdentifier("v15.f3b1.schedule.unknown")
        case .conflict(let conflict): V15Section("账期已变化") { Text(conflict.message).font(V15Typography.secondary); if let error = model.scheduleReloadError { Text(error.message).font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color).accessibilityIdentifier("v15.f3b1.schedule.conflict.reload-error") }; Button("刷新账户后重新预览") { Task { await model.reloadAfterConflict() } }.accessibilityIdentifier("v15.f3b1.schedule.conflict.reload") }.accessibilityIdentifier("v15.f3b1.schedule.conflict")
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.requestSchedulePreview() } }.accessibilityIdentifier("v15.f3b1.schedule.error")
        }
    }
}
