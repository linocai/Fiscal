import SwiftUI

public struct V15ReconciliationMacView: View {
    @State private var model: V15ReconciliationModel
    private let initialGalleryScenario: String?

    @MainActor public init(services: V15Services, offlineSnapshotAt: Date? = nil, initialGalleryScenario: String? = nil) {
        _model = State(initialValue: V15ReconciliationModel(services: services, offlineSnapshotAt: offlineSnapshotAt))
        self.initialGalleryScenario = initialGalleryScenario
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                checkpointWorkspace.frame(minWidth: 390, idealWidth: 440, maxWidth: 520)
                Divider()
                diagnosisWorkspace.frame(minWidth: 480, maxWidth: .infinity)
            }
        }
        .background(V15Palette.paper.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f3e.reconciliation.macos")
        .task {
            if model.masterPhase == .idle {
                await model.load()
                model.beginInlineEditor()
                await prepareGalleryScenario()
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: V15Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("余额核对").font(V15Typography.cardTitle)
                Text("保存核对记录 · 不自动改账").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
            }
            Spacer()
            if model.offlineSnapshotAt != nil { Label("离线只读", systemImage: V15Symbol.offline).foregroundStyle(V15Palette.gold.color).accessibilityIdentifier("v15.f3e.mac.offline") }
            Button { Task { await model.refresh() } } label: { Label("刷新", systemImage: V15Symbol.retry) }.disabled(model.writeLocked).accessibilityIdentifier("v15.f3e.mac.refresh")
        }.padding(.horizontal, V15Spacing.md).padding(.vertical, V15Spacing.sm)
    }

    private var checkpointWorkspace: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.md) {
                    targetSelector
                    mutationSurface
                    checkpointEditor
                    if let snapshot = model.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: snapshot) }
                }
                .padding(V15Spacing.md)
            }
            .frame(maxHeight: .infinity)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.md) {
                    checkpointHistory
                    contextualAttention
                }
                .padding(V15Spacing.md)
            }
            .frame(minHeight: 120, idealHeight: 150, maxHeight: 180)
            .background(V15Palette.card.color.opacity(0.28))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f3e.mac.checkpoint-workspace")
    }

    private var targetSelector: some View {
        V15Section("核对目标") {
            Picker("范围", selection: Binding(get: { model.targetKind }, set: { value in
                Task { await model.setTargetKind(value); model.beginInlineEditor() }
            })) {
                Text("账户").tag(V15ReconciliationTargetKind.account)
                Text("信用账期").tag(V15ReconciliationTargetKind.creditCycle)
            }
            .pickerStyle(.segmented)
            .disabled(!model.targetChangeReasons.isEmpty)
            .accessibilityIdentifier("v15.f3e.mac.kind")

            switch model.masterPhase {
            case .idle, .loading:
                V15LoadingSkeleton()
            case .empty:
                V15EmptyState(title: "暂无目标", explanation: "请先建立账户或信用账期。")
            case .failed(let failure):
                V15ServiceErrorState(message: failure.message) { Task { await model.refresh() } }
            case .loaded:
                if model.visibleTargets.isEmpty {
                    V15EmptyState(title: "此范围暂无目标", explanation: model.targetKind == .account ? "暂无有效账户。" : "暂无信用账期。")
                } else {
                    Picker("当前目标", selection: Binding(get: { model.selectedTarget?.id ?? "" }, set: { id in
                        guard let target = model.visibleTargets.first(where: { $0.id == id }) else { return }
                        Task { await model.selectTarget(target); model.beginInlineEditor() }
                    })) {
                        ForEach(model.visibleTargets) { target in Text(target.label).tag(target.id) }
                    }
                    .pickerStyle(.menu)
                    .disabled(!model.targetChangeReasons.isEmpty)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("v15.f3e.mac.target-picker")
                }
            }
        }
    }

    private var checkpointEditor: some View {
        V15Section("记录检查点", detail: model.asOfDateText) {
            Text(model.selectedTarget?.label ?? "尚未选择目标").font(V15Typography.cardTitle)
            checkpointComparison
            HStack(alignment: .top, spacing: V15Spacing.sm) {
                V15Field("实际余额（元）", text: $model.actualBalanceText, prompt: "0.00", issues: model.checkpointIssues.filter { $0.fieldPath == "actual_balance_minor" })
                    .accessibilityIdentifier("v15.f3e.mac.amount")
                V15Field("核对日期", text: $model.asOfDateText, prompt: "YYYY-MM-DD", issues: model.checkpointIssues.filter { $0.fieldPath == "as_of" })
                    .frame(width: 150)
                    .accessibilityIdentifier("v15.f3e.mac.as-of")
            }
            if model.editorStep == 1 {
                V15ActionButton("开始核对", kind: .secondary, disabledReasons: model.editorOpenReasons, accessibilityIdentifier: "v15.f3e.mac.editor.next") { model.beginInlineEditor() }
            } else if model.editorStep == 2 {
                V15ActionButton("核对差异", kind: .secondary, disabledReasons: model.advanceReasons, accessibilityIdentifier: "v15.f3e.mac.editor.next") { model.advanceEditor() }
            } else {
                V15Field("备注", text: $model.note, prompt: "可选", issues: model.checkpointIssues.filter { $0.fieldPath == "note" }, axis: .vertical)
                    .accessibilityIdentifier("v15.f3e.mac.note")
                Text("确认后只保存这次观察，不会自动创建调整账目。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
                V15ActionButton("保存核对记录", disabledReasons: model.checkpointReasons, accessibilityIdentifier: "v15.f3e.mac.submit") { Task { await model.createCheckpoint() } }
            }
            if !model.serverIssues.isEmpty { V15FieldIssues(issues: model.serverIssues).accessibilityIdentifier("v15.f3e.mac.remote-issues") }
        }
    }

    @ViewBuilder private var checkpointComparison: some View {
        HStack(alignment: .top, spacing: V15Spacing.xs) {
            if let book = model.diagnosis?.bookBalanceMinor { reconciliationFact("账面", book) }
            else { reconciliationUnavailableFact("账面", detail: model.diagnosisPhase == .loading ? "读取中" : "暂无") }
            if let actual = CNYAmountParser.minorUnits(model.actualBalanceText) {
                reconciliationFact("实际", actual)
                if let book = model.diagnosis?.bookBalanceMinor { reconciliationFact("差异", actual - book, emphasized: actual != book) }
                else { reconciliationUnavailableFact("差异", detail: "等待账面") }
            } else {
                reconciliationUnavailableFact("实际", detail: "等待输入")
                reconciliationUnavailableFact("差异", detail: "等待输入")
            }
        }
        .accessibilityIdentifier("v15.f3e.mac.editor.comparison")
    }

    private var checkpointHistory: some View {
        V15Section("历史检查点", detail: model.selectedTarget?.label) {
            switch model.checkpointPhase {
            case .idle:
                V15EmptyState(title: "请选择目标", explanation: "查看对应的核对记录。")
            case .loading:
                V15LoadingSkeleton()
            case .empty:
                V15EmptyState(title: "暂无核对记录", explanation: "输入实际余额后可保存第一条记录。")
                    .accessibilityIdentifier("v15.f3e.mac.checkpoints.empty")
            case .failed(let failure):
                V15ServiceErrorState(message: failure.message) {
                    if let target = model.selectedTarget { Task { await model.selectTarget(target); model.beginInlineEditor() } }
                }
                .accessibilityIdentifier("v15.f3e.mac.checkpoints.error")
            case .loaded:
                ForEach(model.checkpoints) { checkpoint in
                    Button { Task { await model.selectCheckpoint(checkpoint) } } label: { checkpointRow(checkpoint) }
                        .buttonStyle(.plain).v15PlatformHitArea().accessibilityIdentifier("v15.f3e.mac.checkpoint.\(checkpoint.id)")
                }
            }
        }
    }

    private var contextualAttention: some View {
        V15Section("当前目标提醒") {
            switch model.attentionPhase {
            case .idle, .loading:
                V15LoadingSkeleton()
            case .failed(let failure):
                V15ServiceErrorState(message: failure.message) { Task { await model.refreshAttention() } }
            case .empty:
                contextualAttentionEmpty
            case .loaded:
                if model.contextualAttention.isEmpty {
                    contextualAttentionEmpty
                } else {
                    V15Field("忽略到（上海日期）", text: $model.ignoreUntilDateText, prompt: "YYYY-MM-DD")
                    ForEach(model.contextualAttention) { item in
                        VStack(alignment: .leading, spacing: V15Spacing.xs) {
                            Text(item.explanation).font(V15Typography.body).fixedSize(horizontal: false, vertical: true)
                            if let amount = item.amountMinor { V15MoneyText(minorUnits: amount, direction: .neutral) }
                            V15ActionButton("暂时忽略", kind: .quiet, disabledReasons: model.ignoreReasons(for: item)) { Task { await model.ignore(item) } }
                                .accessibilityIdentifier("v15.f3e.mac.ignore.\(item.id)")
                        }
                        .padding(V15Spacing.sm)
                        .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
                    }
                }
            }
        }
    }

    private var contextualAttentionEmpty: some View {
        Text("当前目标没有需要处理的核对提醒。")
            .font(V15Typography.secondary)
            .foregroundStyle(V15Palette.ink.color.opacity(0.66))
            .accessibilityIdentifier("v15.f3e.mac.attention.empty")
    }

    private var diagnosisWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: V15Spacing.lg) {
                V15Section("诊断证据", detail: model.selectedTarget?.label) {
                    switch model.diagnosisPhase {
                    case .idle:
                        V15EmptyState(title: "等待目标", explanation: "选择目标后显示账面变化。")
                    case .loading:
                        V15LoadingSkeleton()
                    case .empty:
                        V15EmptyState(title: "日期无效", explanation: "请输入今天或更早日期。")
                    case .failed(let failure):
                        V15ServiceErrorState(message: failure.message) {
                            if let target = model.selectedTarget { Task { await model.selectTarget(target); model.beginInlineEditor() } }
                        }
                        .accessibilityIdentifier("v15.f3e.mac.diagnosis.error")
                    case .loaded:
                        if let diagnosis = model.diagnosis { diagnosisView(diagnosis).accessibilityIdentifier("v15.f3e.mac.diagnosis") }
                    }
                }
                if let checkpoint = model.selectedCheckpoint {
                    V15Section("记录详情") {
                        HStack { Text("实际余额"); Spacer(); V15MoneyText(minorUnits: checkpoint.actualBalanceMinor, direction: .balance) }
                        HStack { Text("账面余额"); Spacer(); V15MoneyText(minorUnits: checkpoint.bookBalanceMinor, direction: .balance) }
                        HStack { Text("差额"); Spacer(); V15MoneyText(minorUnits: checkpoint.differenceMinor, direction: .neutral) }
                        Text(Self.timestamp(checkpoint.asOf)).font(V15Typography.secondary)
                    }
                    .accessibilityIdentifier("v15.f3e.mac.checkpoint-detail")
                }
            }
            .padding(V15Spacing.md)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.f3e.mac.diagnosis-workspace")
    }

    @ViewBuilder private var mutationSurface: some View {
        if let message = model.successMessage { V15SuccessReceiptState(title: "已保存", detail: message).accessibilityIdentifier("v15.f3e.mac.success") }
        if model.mutationPhase == .loading, !model.hasAcceptedRefreshGate {
            V15LoadingSkeleton().accessibilityIdentifier("v15.f3e.mac.mutation.loading")
        }
        if model.hasUnknownAttempt {
            V15PreviewState {
                VStack(alignment: .leading, spacing: V15Spacing.xs) {
                    Text("\(model.mutationIntentLabel)结果未知").font(V15Typography.cardTitle)
                    Text(model.unknownFactsMessage ?? "系统不会重复保存；请核对最新状态。").font(V15Typography.secondary)
                    V15ActionButton("检查最新状态", kind: .secondary, disabledReason: model.isOffline ? .init(code: "offline_read_only", message: "离线时不能检查最新状态。", fieldPath: nil) : nil) { Task { await model.readFreshFactsForUnknown() } }.accessibilityIdentifier("v15.f3e.mac.unknown.readback")
                    V15ActionButton("核对后继续", kind: .quiet, disabledReason: model.canAbandonUnknown ? nil : .init(code: "fresh_read_required", message: "请先检查最新状态。", fieldPath: nil)) { model.abandonUnknown() }.accessibilityIdentifier("v15.f3e.mac.unknown.abandon")
                }
            }.accessibilityIdentifier("v15.f3e.mac.unknown")
        }
        if model.hasAcceptedRefreshGate {
            V15PartialProgressState(succeeded: "刚才的更改已经保存", currentState: model.acceptedRefreshMessage ?? "最新数据还没有全部更新", remaining: "接下来只会重新读取")
                .accessibilityIdentifier("v15.f3e.mac.fact-refresh")
            V15ActionButton("重新读取", kind: .secondary, disabledReasons: model.factRefreshRetryReasons) { Task { await model.retryAcceptedRefresh() } }
                .accessibilityIdentifier("v15.f3e.mac.fact-refresh.retry")
        }
        if case .conflict(let conflict) = model.mutationPhase { V15ConflictState(conflict: conflict) { Task { await model.reloadAfterConflict() } }.accessibilityIdentifier("v15.f3e.mac.conflict") }
        if case .failed(let failure) = model.mutationPhase, !model.hasAcceptedRefreshGate, model.hasFailedMutation {
            V15PreviewState {
                VStack(alignment: .leading, spacing: V15Spacing.xs) {
                    Text("\(model.mutationIntentLabel)未完成").font(V15Typography.cardTitle)
                    Text(failure.message).font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
                    V15ActionButton("重试\(model.mutationIntentLabel)", symbol: V15Symbol.retry, kind: .secondary, disabledReasons: model.failedMutationRetryReasons) { Task { await model.retryDeterministicMutation() } }
                        .accessibilityIdentifier("v15.f3e.mac.mutation.retry")
                }
            }.accessibilityIdentifier("v15.f3e.mac.mutation.error")
        }
    }

    private func checkpointRow(_ checkpoint: V15ReconciliationCheckpoint) -> some View {
        HStack(alignment: .top, spacing: V15Spacing.xs) {
            RoundedRectangle(cornerRadius: 2).fill(checkpoint.state == .reconciled ? V15Palette.teal.color : V15Palette.yellow.color).frame(width: 4)
            VStack(alignment: .leading) { Text(stateLabel(checkpoint.state)).font(V15Typography.body.weight(.semibold)); Text(Self.timestamp(checkpoint.asOf)).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }
            Spacer(); V15MoneyText(minorUnits: checkpoint.differenceMinor, direction: .neutral)
        }.padding(V15Spacing.sm).background(model.selectedCheckpoint?.id == checkpoint.id ? V15Palette.selected.color : V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
    }

    private func diagnosisView(_ diagnosis: V15ReconciliationDiagnosis) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.sm) {
            HStack(alignment: .top, spacing: V15Spacing.sm) {
                reconciliationFact("账面", diagnosis.bookBalanceMinor)
                if let actual = diagnosis.actualBalanceMinor { reconciliationFact("观察", actual) } else { reconciliationUnavailableFact("观察", detail: "尚未记录") }
                if let difference = diagnosis.differenceMinor { reconciliationFact("差额", difference, emphasized: difference != 0) } else { reconciliationUnavailableFact("差额", detail: "等待观察值") }
            }
            Text("区间起点 \(money(diagnosis.openingBalanceMinor))").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
            Divider()
            Text("区间证据 · \(diagnosis.entries.count) 笔账面变化").font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.62))
            if diagnosis.entries.isEmpty { Text("此区间没有可列出的账目证据。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }
            ForEach(diagnosis.entries) { entry in V15LedgerRow(title: entry.title, detail: Self.timestamp(entry.occurredAt), amountMinor: entry.accountImpactMinor, direction: entry.accountImpactMinor >= 0 ? .inflow : .outflow) }
        }.padding(V15Spacing.md).background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
    }

    private func reconciliationFact(_ title: String, _ value: V15MinorUnits, emphasized: Bool = false) -> some View { VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text(title).font(V15Typography.label); V15MoneyText(minorUnits: value, direction: .neutral, font: V15Typography.body.weight(.semibold)) }.padding(V15Spacing.sm).frame(maxWidth: .infinity, alignment: .leading).background(emphasized ? V15Palette.provisional.color : V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control)) }
    private func reconciliationUnavailableFact(_ title: String, detail: String) -> some View { VStack(alignment: .leading, spacing: V15Spacing.xxs) { Text(title).font(V15Typography.label); Text("—").font(V15Typography.body.weight(.semibold)); Text(detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.62)) }.padding(V15Spacing.sm).frame(maxWidth: .infinity, alignment: .leading).background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control)) }
    private func money(_ value: V15MinorUnits) -> String { V15MoneyPresentation(minorUnits: value, direction: .neutral).text }

    @MainActor private func prepareGalleryScenario() async {
        guard let scenario = initialGalleryScenario else { return }
        if ["reconciliation-editor", "reconciliation-unknown", "reconciliation-cancelled-unknown", "reconciliation-invalid-response", "reconciliation-mutation-error", "reconciliation-partial-refresh"].contains(scenario) {
            model.actualBalanceText = "1234.56"; model.note = "新核对"; model.beginEditor(); model.advanceEditor(); model.advanceEditor()
        }
        if ["reconciliation-unknown", "reconciliation-cancelled-unknown", "reconciliation-invalid-response", "reconciliation-mutation-error", "reconciliation-partial-refresh"].contains(scenario) { await model.createCheckpoint() }
        if scenario == "reconciliation-attention-unknown", let item = model.attention.first { await model.ignore(item) }
    }

    private func stateLabel(_ value: V15ReconciliationState) -> String { switch value { case .open: "有差额"; case .reconciled: "已核平"; case .unknown(let raw): "未知（\(raw)）" } }
    private static func timestamp(_ date: Date) -> String { let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_Hans_CN"); formatter.timeZone = ShanghaiBusinessDate.timeZone; formatter.dateFormat = "yyyy-MM-dd HH:mm"; return formatter.string(from: date) }
}
