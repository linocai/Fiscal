import SwiftUI

#if os(macOS)

public struct V15CreditMacView: View {
    private let services: V15Services
    @State private var showsPayoff = false
    @State private var recordKind: V15ManualTransactionKind?
    @State private var model: V15CreditModel
    private let initialGalleryScenario: String?
    private let initialCycle: V15CreditCycle?
    private let initialAccountID: UUID?
    @State private var initialContextFailure: V15Failure?
    public init(services: V15Services, offlineSnapshotAt: Date? = nil, offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)? = nil, initialGalleryScenario: String? = nil, initialCycle: V15CreditCycle? = nil, initialAccountID: UUID? = nil) { self.services = services; _model = State(initialValue: .init(services: services, offlineSnapshotAt: offlineSnapshotAt, offlineSnapshotProvider: offlineSnapshotProvider)); _initialContextFailure = State(initialValue: nil); self.initialGalleryScenario = initialGalleryScenario; self.initialCycle = initialCycle; self.initialAccountID = initialAccountID }
    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            accounts
            HSplitView {
                cycles.frame(minWidth: 300, idealWidth: 460)
                inspector.frame(minWidth: 270, idealWidth: 340)
            }
        }
        .padding(24)
        .v22PageCanvas()
        .task { await loadInitialState() }
        .sheet(isPresented: Binding(get: { model.scheduleSheetVisible }, set: { if !$0 { model.dismissScheduleSheet() } })) { V15CreditScheduleMacSheet(model: model) }
        .sheet(isPresented: $showsPayoff, onDismiss: { Task { await model.reloadSelectedAccount() } }) {
            if let account = model.selectedAccount { V15CreditPayoffView(services: services, accountID: account.id, accountName: account.name) }
        }
        .sheet(item: $recordKind) { kind in
            VStack(spacing: 0) {
                HStack { Spacer(); Button("关闭") { recordKind = nil }.keyboardShortcut(.cancelAction) }.padding(16)
                V15RecordView(services: services, initialKind: kind, initialCreditAccountID: model.selectedAccount?.id, presentsEditorDirectly: true) { _ in
                    Task { await model.reloadSelectedAccount() }
                }
            }.frame(minWidth: 640, minHeight: 600).v22PageCanvas()
        }
        .overlay {
            if let initialContextFailure {
                ZStack {
                    V15Palette.paper.color
                    V15ServiceErrorState(message: initialContextFailure.message) { Task { await loadInitialState() } }
                        .padding(V15Spacing.xl)
                        .accessibilityIdentifier("v15.f3b1.mac.initial-context.error")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f3b1.credit.macos")
    }
    private func loadInitialState() async {
        initialContextFailure = nil
        await model.load()
        // Keep a real list/master-data failure visible with its retry action.
        // "Unavailable" is only an accurate contextual-route error after the
        // account list completed successfully.
        guard initialContextMayResolve else { return }
        if let initialCycle {
            guard let account = model.accounts.first(where: { $0.id == initialCycle.accountID }) else {
                initialContextFailure = .init(kind: .decoding, code: "initial_credit_account_unavailable", message: "无法打开这个账期所属的信用账户；它可能已停用或不再存在。")
                return
            }
            await model.selectAccount(account); await model.selectCycle(initialCycle)
        } else if let initialAccountID {
            guard let account = model.accounts.first(where: { $0.id == initialAccountID }) else {
                initialContextFailure = .init(kind: .decoding, code: "initial_credit_account_unavailable", message: "无法打开指定的信用账户；它可能已停用或不再存在。")
                return
            }
            await model.selectAccount(account)
        }
        guard let scenario = initialGalleryScenario else { return }
        if scenario == "credit-page-error" { await model.loadNextCycles(); return }
        guard ["credit-expired", "credit-disabled", "credit-conflict", "credit-field-error"].contains(scenario) else { return }
        model.openScheduleSheet(); model.cycleMode = .statementDayCutoff; model.statementDayText = "25"; model.dueDayText = "10"
        await model.requestSchedulePreview()
        if scenario == "credit-conflict" { await model.commitSchedule() }
    }
    private var initialContextMayResolve: Bool {
        switch model.phase {
        case .loaded, .empty: true
        case .idle, .loading, .failed: false
        }
    }
    private var accounts: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                V22PageHeader("信用账期", symbol: "creditcard", subtitle: "管理账单、还款日与可用额度")
                Button { Task { await model.load() } } label: { Image(systemName: V15Symbol.retry) }
                    .buttonStyle(.borderless)
                    .help("刷新信用账期")
                    .accessibilityIdentifier("v15.f3b1.reload")
            }
            V23WrappingLayout {
                ForEach(model.accounts) { account in
                    V23ChoiceButton(account.name, symbol: "creditcard", selected: model.selectedAccount?.id == account.id) { Task { await model.selectAccount(account) } }
                        .accessibilityIdentifier("v15.f3b1.account.\(account.id)")
                }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("v22.credit.account-picker")
            if let at = model.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: at).accessibilityIdentifier("v15.f3b1.offline") }
        }
    }
    @ViewBuilder private var cycles: some View {
        ScrollView { VStack(alignment: .leading, spacing: V15Spacing.md) {
            if let account = model.selectedAccount {
                HStack(alignment: .top) { VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text(account.cycleMode == .onDemand ? "随借随还" : "账期").font(V15Typography.surfaceTitle); Text("当前欠款").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)); V15MoneyText(minorUnits: account.currentDebtMinor, direction: .outflow) }; Spacer(); if account.cycleMode != .onDemand { Button("调整账期") { model.openScheduleSheet() }.disabled(model.isOffline).keyboardShortcut("s", modifiers: [.command, .option]).accessibilityIdentifier("v15.f3b1.schedule.open") } }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), spacing: V15Spacing.sm)], alignment: .leading, spacing: V15Spacing.sm) {
                    if account.cycleMode != .onDemand { creditMetric("信用额度", account.creditLimitMinor, .neutral) }
                    if account.cycleMode != .onDemand { creditMetric("可用额度", account.availableCreditMinor, .balance) }
                    if account.cycleMode != .onDemand { creditMetric("超额", account.overLimitMinor, (account.overLimitMinor ?? 0) > 0 ? .outflow : .neutral) }
                }
                V15ActionButton("全额结清与回执", symbol: "checkmark.seal", kind: .secondary) { showsPayoff = true }
                    .disabled(model.isOffline).accessibilityIdentifier("v230.credit.payoff")
                if account.cycleMode == .onDemand { onDemandActions }
                if account.activeInstallmentCount > 0 || account.futureScheduledGrossMinor > 0 {
                    V15PreviewState {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text("未来计划分期").font(V15Typography.body.weight(.semibold)); Text("\(account.activeInstallmentCount) 个进行中计划 · 全额结清时统一核对").font(V15Typography.secondary) }
                            Spacer(); V15MoneyText(minorUnits: account.futureScheduledGrossMinor, direction: .outflow)
                        }
                    }.accessibilityIdentifier("v15.f3b1.mac.future-installments")
                }
                if account.hasOverdueCycle { Text("存在逾期账期，请先查看详情。").font(V15Typography.secondary).foregroundStyle(V15Palette.warning.color) }
            }
            switch model.phase {
            case .idle, .loading: V15LoadingSkeleton()
            case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.load() } }
            case .empty: V15EmptyState(title: "目前没有信用账户", explanation: "到账户页添加信用账户后，这里会显示账单。")
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
        HStack { VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text(cycle.isOpeningCycle ? "期初账期" : "账期").font(V15Typography.label).foregroundStyle(cycle.isOverdue ? V15Palette.warning.color : V15Palette.teal.color); Text("\(cycle.periodStart) 至 \(cycle.periodEnd)").font(V15Typography.body); Text("还款日 \(cycle.dueDate) · \(cycleStatusLabel(cycle.status))").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }; Spacer(); V15MoneyText(minorUnits: cycle.remainingMinor, direction: .outflow, font: V15Typography.secondary) }
            .padding(V15Spacing.sm).frame(maxWidth: .infinity, alignment: .leading).background(model.selectedCycle?.id == cycle.id ? V15Palette.selected.color : V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
    }
    @ViewBuilder private var inspector: some View {
        ScrollView { VStack(alignment: .leading, spacing: V15Spacing.md) {
            Text("详情").font(V15Typography.surfaceTitle)
            switch model.cycleDetailPhase {
            case .idle: V15EmptyState(title: model.selectedAccount?.cycleMode == .onDemand ? "无固定账期" : "选择一个账期", explanation: model.selectedAccount?.cycleMode == .onDemand ? "此账户不设额度、利息或固定还款日。借入与偿还后，当前欠款会同步更新。" : "这里显示账期详情、分期和相关账目。")
            case .loading: V15LoadingSkeleton()
            case .failed(let failure): V15ServiceErrorState(message: failure.message) {}
            case .loaded:
                if let cycle = model.selectedCycle {
                    V15Section("账期详情") {
                        Text("账单日 \(cycle.statementDate) · 还款日 \(cycle.dueDate)").font(V15Typography.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: V15Spacing.sm)], alignment: .leading, spacing: V15Spacing.sm) {
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
                    }.accessibilityElement(children: .contain).accessibilityIdentifier("v15.f3b1.cycle.inspector")
                }
            }
        }.padding(V15Spacing.md) }
        .accessibilityIdentifier("v15.f3b1.credit.inspector")
    }
    private var onDemandActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("不设额度 · 无固定还款日").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.64))
            V15AdaptiveStack(spacing: 10) {
                V15ActionButton("记录借入", symbol: "arrow.down.left.circle", kind: .secondary) { recordKind = .borrowing }
                    .accessibilityIdentifier("v230.credit.borrow")
                V15ActionButton("记录还款", symbol: "arrow.up.right.circle") { recordKind = .repayment }
                    .accessibilityIdentifier("v230.credit.repay")
            }.disabled(model.isOffline)
        }
    }
    private func creditMetric(_ title: String, _ value: V15MinorUnits?, _ direction: V15MoneyDirection) -> some View { V22Metric(title, minorUnits: value, direction: direction) }
    private func cycleStatusLabel(_ value: V15CreditCycleStatus) -> String { switch value { case .open: "开放"; case .unpaid: "未还"; case .partial: "部分已还"; case .overdue: "已逾期"; case .settled: "已结清"; case .unknown: "未知状态" } }
    private func money(_ value: V15MinorUnits) -> String { V15MoneyPresentation(minorUnits: value, direction: .neutral).text }
}

private struct V15CreditScheduleMacSheet: View {
    @Bindable var model: V15CreditModel
    var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            HStack { V22PageHeader("调整账期", symbol: "calendar", subtitle: "先查看影响，再确认修改"); Button("关闭") { model.dismissScheduleSheet() }.accessibilityIdentifier("v15.f3b1.schedule.dismiss") }
            V22FlowProgress(["设置", "查看影响", "确认"], current: model.schedulePreview == nil ? 0 : 1)
            V22FormSection("账单规则") {
                V23ChoiceGroup("账期方式", selection: $model.cycleMode, choices: [V23Choice(.statementDayCutoff, "账单日截点"), V23Choice(.previousCalendarMonth, "上个自然月")], identifier: "v15.f3b1.schedule.mode")
                HStack(alignment: .top, spacing: 20) {
                    V15Field("账单日", text: $model.statementDayText, prompt: "1–28", keyboard: .integer).accessibilityIdentifier("v15.f3b1.schedule.statement-day")
                    V15Field("还款日", text: $model.dueDayText, prompt: "1–28", keyboard: .integer).accessibilityIdentifier("v15.f3b1.schedule.due-day")
                }
            }
            V15FieldIssues(issues: model.scheduleIssues)
                .accessibilityIdentifier("v15.f3b1.schedule.local-reasons")
            V15FieldIssues(issues: model.scheduleServerFieldIssues)
                .accessibilityIdentifier("v15.f3b1.schedule.server-field-reasons")
            V15ActionButton("取预览", disabledReason: model.schedulePreviewDisabledReason, showsDisabledReasons: false, accessibilityIdentifier: "v15.f3b1.schedule.preview") {
                Task { await model.requestSchedulePreview() }
            }
            disabledReasonNotice(model.schedulePreviewDisabledReason, accessibilityIdentifier: "v15.f3b1.schedule.preview-reason")
            if model.scheduleCommandDisabledReason != nil {
                V15ActionButton("提交账期变更", disabledReason: model.scheduleDisabledReason, showsDisabledReasons: false, accessibilityIdentifier: "v15.f3b1.schedule.commit") {
                    Task { await model.commitSchedule() }
                }
                disabledReasonNotice(model.scheduleDisabledReason, accessibilityIdentifier: "v15.f3b1.schedule.commit-reason")
            }
            state
        }.padding(V15Spacing.lg).frame(minWidth: 480, idealWidth: 560).accessibilityElement(children: .contain).accessibilityIdentifier("v15.f3b1.schedule.sheet")
    }
    @ViewBuilder private var state: some View {
        switch model.schedulePhase {
        case .idle: EmptyView()
        case .previewing, .committing: V15LoadingSkeleton()
        case .previewed:
            if let preview = model.schedulePreview {
                V15Section("影响预览", detail: "\(preview.affectedCycleCount) 个账期") {
                    Text("消费 \(preview.purchaseCount) 笔 · 还款 \(preview.repaymentCount) 笔 · 分期 \(preview.installmentPeriodCount) 期")
                        .font(V15Typography.secondary)
                    ForEach(preview.warnings + preview.conflicts, id: \.self) {
                        Text($0).font(V15Typography.secondary).foregroundStyle(V15Palette.warning.color)
                    }
                    V15ActionButton("确认账期变更", disabledReason: model.scheduleDisabledReason, showsDisabledReasons: false, accessibilityIdentifier: "v15.f3b1.schedule.commit") {
                        Task { await model.commitSchedule() }
                    }
                    disabledReasonNotice(model.scheduleDisabledReason, accessibilityIdentifier: "v15.f3b1.schedule.commit-reason")
                }
                .accessibilityIdentifier("v15.f3b1.schedule.preview")
            }
        case .succeeded: V15Section("已提交") { Text("账期已更新。").font(V15Typography.secondary) }.accessibilityIdentifier("v15.f3b1.schedule.receipt")
        case .readbackConfirmed: V15Section("已核对") { Text("当前账期与刚才的修改一致。").font(V15Typography.secondary) }.accessibilityIdentifier("v15.f3b1.schedule.readback-confirmed")
        case .unknown: V15Section("提交结果未知") {
            Text("可以安全检查保存结果，或刷新账户后核对。").font(V15Typography.secondary)
            switch model.unknownReadbackPhase {
            case .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f3b1.schedule.unknown.readback.loading")
            case .notConfirmed: Text(model.unknownReadbackNotice ?? "尚未确认这次修改是否生效。").font(V15Typography.secondary).foregroundStyle(V15Palette.unknown.color).accessibilityIdentifier("v15.f3b1.schedule.unknown.readback.not-confirmed")
            case .failed(let failure): Text(failure.message).font(V15Typography.secondary).foregroundStyle(V15Palette.danger.color).accessibilityIdentifier("v15.f3b1.schedule.unknown.readback.error")
            case .idle, .confirmed: EmptyView()
            }
            Button("安全检查保存结果") { Task { await model.retryUnknownCommit() } }
                .disabled(model.unknownReadbackPhase == .loading || model.unknownRetryDisabledReason != nil)
                .accessibilityIdentifier("v15.f3b1.schedule.unknown.retry")
            if let reason = model.unknownRetryDisabledReason {
                Text(reason.message).font(V15Typography.secondary).foregroundStyle(V15Palette.unknown.color).accessibilityIdentifier("v15.f3b1.schedule.unknown.retry-reason")
            } else if let notice = model.unknownRetryNotice {
                Text(notice).font(V15Typography.secondary).foregroundStyle(V15Palette.unknown.color).accessibilityIdentifier("v15.f3b1.schedule.unknown.retry-notice")
            }
            Button("刷新账户后核对") { Task { await model.resolveUnknownByReadback() } }.disabled(model.unknownReadbackPhase == .loading).accessibilityIdentifier("v15.f3b1.schedule.unknown.readback")
            Button("放弃同一键恢复并刷新账户") { model.abandonUnknownAttempt() }
                .disabled(model.unknownReadbackPhase == .loading)
                .accessibilityIdentifier("v15.f3b1.schedule.unknown.abandon")
        }.accessibilityIdentifier("v15.f3b1.schedule.unknown")
        case .conflict(let conflict): V15Section("账期已变化") { Text(conflict.message).font(V15Typography.secondary); if let error = model.scheduleReloadError { Text(error.message).font(V15Typography.secondary).foregroundStyle(V15Palette.danger.color).accessibilityIdentifier("v15.f3b1.schedule.conflict.reload-error") }; Button("刷新账户后重新预览") { Task { await model.reloadAfterConflict() } }.accessibilityIdentifier("v15.f3b1.schedule.conflict.reload") }.accessibilityIdentifier("v15.f3b1.schedule.conflict")
        case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.requestSchedulePreview() } }.accessibilityIdentifier("v15.f3b1.schedule.error")
        }
    }

    /// Field validation is already shown in the danger treatment directly
    /// above. Only non-field gates belong beside a disabled action, where a
    /// neutral explanation avoids presenting a normal workflow state as an
    /// additional error.
    @ViewBuilder private func disabledReasonNotice(_ reason: V15DisabledReason?, accessibilityIdentifier: String) -> some View {
        if let reason, reason.fieldPath == nil {
            Text(V15Accessibility.safeReason(reason))
                .font(V15Typography.secondary)
                .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(accessibilityIdentifier)
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
                Text(scenario == "credit-page-error" ? "账期" : "调整账期").font(V15Typography.surfaceTitle)
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
        case "credit-expired": V15Section("预览已过期") { Text("预览已过期，请重新预览。").font(V15Typography.secondary).foregroundStyle(V15Palette.warning.color); Button("重新取预览") {} }
        case "credit-disabled": V15Section("暂时无法提交") { Text("当前预览不允许确认账期变更。").font(V15Typography.secondary).foregroundStyle(V15Palette.warning.color); Button("确认账期变更") {}.disabled(true) }
        default: V15Section("账期已变化") { Text("账期数据已变化。请刷新账户后重新预览。").font(V15Typography.secondary).foregroundStyle(V15Palette.warning.color); Button("刷新账户后重新预览") {} }
        }
    }
}

#endif
