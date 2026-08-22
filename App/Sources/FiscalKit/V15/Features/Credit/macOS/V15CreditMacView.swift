import SwiftUI

#if os(macOS)

public struct V15CreditMacView: View {
    @State private var model: V15CreditModel
    private let initialGalleryScenario: String?
    public init(services: V15Services, offlineSnapshotAt: Date? = nil, offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)? = nil, initialGalleryScenario: String? = nil) { _model = State(initialValue: .init(services: services, offlineSnapshotAt: offlineSnapshotAt, offlineSnapshotProvider: offlineSnapshotProvider)); self.initialGalleryScenario = initialGalleryScenario }
    public var body: some View {
        HSplitView {
            accounts.frame(minWidth: 205, idealWidth: 240)
            cycles.frame(minWidth: 380, idealWidth: 500)
            inspector.frame(minWidth: 300, idealWidth: 360)
        }
        .background(V15Palette.paper.color)
        .task { await loadInitialState() }
        .sheet(isPresented: Binding(get: { model.scheduleSheetVisible }, set: { if !$0 { model.dismissScheduleSheet() } })) { V15CreditScheduleMacSheet(model: model) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f3b1.credit.macos")
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
    private var accounts: some View {
        VStack(alignment: .leading, spacing: V15Spacing.sm) {
            HStack { Text("信用账户").font(V15Typography.surfaceTitle); Spacer(); Button { Task { await model.load() } } label: { Image(systemName: V15Symbol.retry) }.accessibilityIdentifier("v15.f3b1.reload") }
            ScrollView { VStack(alignment: .leading, spacing: V15Spacing.xxs) { ForEach(model.accounts) { account in Button { Task { await model.selectAccount(account) } } label: { VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text(account.name).font(V15Typography.body); Text("账单日 \(account.statementDay) · 还款日 \(account.dueDay)").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }.frame(maxWidth: .infinity, alignment: .leading).padding(V15Spacing.sm).background(model.selectedAccount?.id == account.id ? V15Palette.selected.color : .clear, in: RoundedRectangle(cornerRadius: V15Radius.control)) }.buttonStyle(.plain).v15PlatformHitArea().v15KeyboardFocusable().accessibilityIdentifier("v15.f3b1.account.\(account.id)") } } }
            Spacer()
            if let at = model.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: at).accessibilityIdentifier("v15.f3b1.offline") }
        }.padding(V15Spacing.md)
    }
    @ViewBuilder private var cycles: some View {
        ScrollView { VStack(alignment: .leading, spacing: V15Spacing.md) {
            if let account = model.selectedAccount {
                HStack(alignment: .top) { VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text("账期脊柱").font(V15Typography.surfaceTitle); Text("当前欠款").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)); V15MoneyText(minorUnits: account.currentDebtMinor, direction: .outflow) }; Spacer(); Button("调整账期") { model.openScheduleSheet() }.disabled(model.isOffline).keyboardShortcut("s", modifiers: [.command, .option]).accessibilityIdentifier("v15.f3b1.schedule.open") }
                if account.hasOverdueCycle { Text("存在逾期账期；请先查看服务器事实。 ").font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color) }
            }
            switch model.phase {
            case .idle, .loading: V15LoadingSkeleton()
            case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.load() } }
            case .empty: V15EmptyState(title: "目前没有信用账户", explanation: "账户创建和维护在主数据中完成。")
            case .loaded:
                ForEach(model.cycles) { cycle in
                    Button { Task { await model.selectCycle(cycle) } } label: { cycleRow(cycle) }
                        .buttonStyle(.plain).v15PlatformHitArea().v15KeyboardFocusable()
                        .accessibilityIdentifier("v15.f3b1.cycle.\(cycle.id)")
                }
                if model.nextCycleCursor != nil { Button("读取下一页账期") { Task { await model.loadNextCycles() } }.keyboardShortcut(.downArrow, modifiers: [.command, .option]).accessibilityIdentifier("v15.f3b1.cycles.next") }
                if case .failed(let failure) = model.cyclePagePhase { V15ServiceErrorState(message: failure.message) { Task { await model.loadNextCycles() } }.accessibilityIdentifier("v15.f3b1.cycles.page-error") }
            }
        }.padding(V15Spacing.md) }
        .accessibilityIdentifier("v15.f3b1.credit.spine")
    }
    private func cycleRow(_ cycle: V15CreditCycle) -> some View {
        HStack { VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text(cycle.isOpeningCycle ? "期初账期" : "账期").font(V15Typography.label).foregroundStyle(cycle.isOverdue ? V15Palette.gold.color : V15Palette.teal.color); Text("\(cycle.periodStart) 至 \(cycle.periodEnd)").font(V15Typography.body); Text("还款日 \(cycle.dueDate) · \(cycle.isOverdue ? "逾期" : String(describing: cycle.status))").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }; Spacer(); V15MoneyText(minorUnits: cycle.remainingMinor, direction: .outflow, font: V15Typography.secondary) }
            .padding(V15Spacing.sm).frame(maxWidth: .infinity, alignment: .leading).background(model.selectedCycle?.id == cycle.id ? V15Palette.selected.color : V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
    }
    @ViewBuilder private var inspector: some View {
        ScrollView { VStack(alignment: .leading, spacing: V15Spacing.md) {
            Text("检查器").font(V15Typography.surfaceTitle)
            switch model.cycleDetailPhase {
            case .idle: V15EmptyState(title: "选择一个账期", explanation: "账期详情、分期期间和账目均来自服务器。")
            case .loading: V15LoadingSkeleton()
            case .failed(let failure): V15ServiceErrorState(message: failure.message) {}
            case .loaded:
                if let cycle = model.selectedCycle {
                    V15Section("账期事实", detail: "版本 \(cycle.version)") {
                        Text("账单日 \(cycle.statementDate) · 还款日 \(cycle.dueDate)").font(V15Typography.secondary)
                        HStack { V15MoneyText(minorUnits: cycle.amountDueMinor, direction: .outflow); Spacer(); Text("已还").font(V15Typography.secondary); V15MoneyText(minorUnits: cycle.repaidMinor, direction: .neutral, font: V15Typography.secondary) }
                        Text("分期本金 \(cycle.installmentPrincipalMinor) 分 · 手续费 \(cycle.installmentFeeMinor) 分").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
                        if model.nextTransactionCursor != nil { Button("读取下一页账目") { Task { await model.loadNextTransactions() } }.accessibilityIdentifier("v15.f3b1.transactions.next") }
                        if case .failed(let failure) = model.transactionPagePhase { V15ServiceErrorState(message: failure.message) { Task { await model.loadNextTransactions() } }.accessibilityIdentifier("v15.f3b1.transactions.page-error") }
                    }.accessibilityElement(children: .contain).accessibilityIdentifier("v15.f3b1.cycle.inspector")
                }
            }
        }.padding(V15Spacing.md) }
        .accessibilityIdentifier("v15.f3b1.credit.inspector")
    }
}

private struct V15CreditScheduleMacSheet: View {
    @Bindable var model: V15CreditModel
    var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            HStack { VStack(alignment: .leading) { Text("调整账期").font(V15Typography.surfaceTitle); Text("步骤 1 设置 → 步骤 2 预览 → 步骤 3 提交").font(V15Typography.secondary) }; Spacer(); Button("关闭") { model.dismissScheduleSheet() }.accessibilityIdentifier("v15.f3b1.schedule.dismiss") }
            Picker("账期方式", selection: $model.cycleMode) { Text("账单日截点").tag(V15CreditCycleMode.statementDayCutoff); Text("上个自然月").tag(V15CreditCycleMode.previousCalendarMonth) }.accessibilityIdentifier("v15.f3b1.schedule.mode")
            TextField("账单日（1–28）", text: $model.statementDayText).accessibilityIdentifier("v15.f3b1.schedule.statement-day")
            TextField("还款日（1–28）", text: $model.dueDayText).accessibilityIdentifier("v15.f3b1.schedule.due-day")
            ForEach(model.scheduleIssues, id: \.code) { Text($0.message).font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color) }
            ForEach(model.scheduleServerFieldIssues, id: \.code) { Text($0.message).font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color) }.accessibilityIdentifier("v15.f3b1.schedule.server-field-reasons")
            Button("预览服务端影响") { Task { await model.requestSchedulePreview() } }
                .disabled(!model.canRequestSchedulePreview)
                .accessibilityIdentifier("v15.f3b1.schedule.preview")
            if let reason = model.schedulePreviewDisabledReason {
                Text(reason.message).font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color).accessibilityIdentifier("v15.f3b1.schedule.preview-reason")
            }
            if model.scheduleCommandDisabledReason != nil {
                Button("提交账期变更") { Task { await model.commitSchedule() } }
                    .disabled(!model.canCommitSchedule)
                    .accessibilityIdentifier("v15.f3b1.schedule.commit")
                if let reason = model.scheduleDisabledReason {
                    Text(reason.message).font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color).accessibilityIdentifier("v15.f3b1.schedule.commit-reason")
                }
            }
            state
        }.padding(V15Spacing.lg).frame(minWidth: 480, idealWidth: 560).accessibilityElement(children: .contain).accessibilityIdentifier("v15.f3b1.schedule.sheet")
    }
    @ViewBuilder private var state: some View {
        switch model.schedulePhase {
        case .idle: EmptyView()
        case .previewing, .committing: V15LoadingSkeleton()
        case .previewed:
            if let preview = model.schedulePreview { V15Section("服务端影响", detail: "\(preview.affectedCycleCount) 个账期") { Text("消费 \(preview.purchaseCount) 笔 · 还款 \(preview.repaymentCount) 笔 · 分期 \(preview.installmentPeriodCount) 期").font(V15Typography.secondary); if let version = preview.expectedAccountVersion { Text("预览基于账户版本 \(version)").font(V15Typography.secondary).accessibilityIdentifier("v15.f3b1.schedule.preview.account-version") }; ForEach(preview.warnings + preview.conflicts, id: \.self) { Text($0).font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color) }; Button("提交账期变更") { Task { await model.commitSchedule() } }.disabled(!model.canCommitSchedule).accessibilityIdentifier("v15.f3b1.schedule.commit"); if let reason = model.scheduleDisabledReason { Text(reason.message).font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color).accessibilityIdentifier("v15.f3b1.schedule.commit-reason") } }.accessibilityIdentifier("v15.f3b1.schedule.preview") }
        case .succeeded(let result): V15Section("已提交", detail: "数据版本 \(result.dataRevision.map(String.init) ?? "未提供")") { Text("服务器已返回账期变更结果。 ").font(V15Typography.secondary) }.accessibilityIdentifier("v15.f3b1.schedule.receipt")
        case .readbackConfirmed: V15Section("已由账户事实确认") { Text("服务器当前账期与原提交意图一致；这是只读核对，不是提交回执。 ").font(V15Typography.secondary) }.accessibilityIdentifier("v15.f3b1.schedule.readback-confirmed")
        case .unknown: V15Section("提交结果未知") {
            Text("只可使用同一请求键重试，或刷新账户后核对。 ").font(V15Typography.secondary)
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
        }.accessibilityIdentifier("v15.f3b1.schedule.unknown")
        case .conflict(let conflict): V15Section("账期已变化") { Text(conflict.message).font(V15Typography.secondary); if let error = model.scheduleReloadError { Text(error.message).font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color).accessibilityIdentifier("v15.f3b1.schedule.conflict.reload-error") }; Button("刷新账户后重新预览") { Task { await model.reloadAfterConflict() } }.accessibilityIdentifier("v15.f3b1.schedule.conflict.reload") }.accessibilityIdentifier("v15.f3b1.schedule.conflict")
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.requestSchedulePreview() } }.accessibilityIdentifier("v15.f3b1.schedule.error")
        }
    }
}

/// Offline Gallery evidence for states that would otherwise live in a modal
/// sheet (which AppKit's headless snapshot host does not attach to a window).
/// It mirrors the production sheet's copy and controls; interaction evidence
/// remains in the iOS XCUITest and the macOS UI target.
public struct V15CreditMacGalleryEvidence: View {
    public let scenario: String
    public init(scenario: String) { self.scenario = scenario }
    public var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: V15Spacing.md) {
                Text("信用账户").font(V15Typography.surfaceTitle)
                Text("日常信用账户").font(V15Typography.body)
                Text("账单日 20 · 还款日 5").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
                Spacer()
            }.padding(V15Spacing.md).frame(minWidth: 220)
            VStack(alignment: .leading, spacing: V15Spacing.md) {
                Text(scenario == "credit-page-error" ? "账期脊柱" : "调整账期").font(V15Typography.surfaceTitle)
                if scenario == "credit-page-error" {
                    V15Section("账期读取失败") { Text("下一页账期读取失败。请保留当前账期后重试。").font(V15Typography.secondary); Button("重试读取下一页") {} }
                } else {
                    Text("步骤 1 设置 → 步骤 2 预览 → 步骤 3 提交").font(V15Typography.secondary)
                    Text("账期方式：账单日截点 · 账单日 25 · 还款日 10").font(V15Typography.secondary)
                    notice
                }
                Spacer()
            }.padding(V15Spacing.lg).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(V15Palette.paper.color)
        .accessibilityIdentifier("v15.f3b1.credit.gallery-evidence")
    }
    @ViewBuilder private var notice: some View {
        switch scenario {
        case "credit-expired": V15Section("预览已过期") { Text("预览已过期，请重新预览。").font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color); Button("重新预览服务端影响") {} }
        case "credit-disabled": V15Section("服务器未允许提交") { Text("服务端本次预览未允许提交账期变更。").font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color); Button("提交账期变更") {}.disabled(true) }
        default: V15Section("账期已变化") { Text("账期数据已变化。请刷新账户后重新预览。").font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color); Button("刷新账户后重新预览") {} }
        }
    }
}

#endif
