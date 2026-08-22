import SwiftUI

public struct V15ReconciliationView: View {
    @State private var model: V15ReconciliationModel
    @State private var showsEditor = false

    @MainActor public init(services: V15Services, offlineSnapshotAt: Date? = nil) {
        _model = State(initialValue: V15ReconciliationModel(services: services, offlineSnapshotAt: offlineSnapshotAt))
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.section) {
                    header
                    mutationSurface
                    targetSurface
                    checkpointSurface
                    diagnosisSurface
                    attentionSurface
                }
                .padding(V15Spacing.md)
            }
            .background(V15Palette.paper.color)
            .navigationTitle("核对")
            .toolbar { Button("刷新") { Task { await model.refresh() } }.disabled(model.writeLocked).accessibilityIdentifier("v15.f3e.refresh") }
        }
        .accessibilityIdentifier("v15.f3e.reconciliation.ios")
        .task { if model.masterPhase == .idle { await model.load() } }
        .sheet(isPresented: $showsEditor) { editorSheet }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: V15Spacing.sm) {
            Text("账面事实与实际余额").font(V15Typography.surfaceTitle).foregroundStyle(V15Palette.ink.color)
            Text("核对只保存锚点，不自动改账。差额需要通过正式流水修正。").font(V15Typography.body).foregroundStyle(V15Palette.ink.color.opacity(0.68)).fixedSize(horizontal: false, vertical: true)
            if let snapshot = model.offlineSnapshotAt { V15OfflineReadOnlyBanner(snapshotAt: snapshot).accessibilityIdentifier("v15.f3e.offline") }
        }
    }

    @ViewBuilder private var targetSurface: some View {
        V15Section("核对目标") {
            HStack(spacing: V15Spacing.xs) {
                V15ActionButton("账户", kind: model.targetKind == .account ? .primary : .secondary, disabledReasons: model.targetChangeReasons) { Task { await model.setTargetKind(.account) } }.accessibilityIdentifier("v15.f3e.kind.account")
                V15ActionButton("信用账期", kind: model.targetKind == .creditCycle ? .primary : .secondary, disabledReasons: model.targetChangeReasons) { Task { await model.setTargetKind(.creditCycle) } }.accessibilityIdentifier("v15.f3e.kind.cycle")
            }
            switch model.masterPhase {
            case .idle, .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f3e.targets.loading")
            case .empty: V15EmptyState(title: "暂无可核对目标", explanation: "请先建立账户或信用账期。").accessibilityIdentifier("v15.f3e.targets.empty")
            case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.refresh() } }.accessibilityIdentifier("v15.f3e.targets.error")
            case .loaded:
                if model.visibleTargets.isEmpty { V15EmptyState(title: "此范围暂无目标", explanation: model.targetKind == .account ? "暂无有效账户。" : "暂无信用账期。") }
                else {
                    ScrollView(.horizontal) {
                        HStack(spacing: V15Spacing.xs) {
                            ForEach(model.visibleTargets) { target in
                                V15ActionButton(target.label, kind: model.selectedTarget?.id == target.id ? .primary : .secondary, disabledReasons: model.targetChangeReasons) { Task { await model.selectTarget(target) } }
                                    .accessibilityIdentifier("v15.f3e.target.\(target.id)")
                            }
                        }.padding(.vertical, 2)
                    }.scrollIndicators(.hidden)
                }
            }
            V15ActionButton(model.hasUnknownAttempt ? "返回未知写入核对" : "开始余额核对", symbol: "checkmark.circle", disabledReasons: model.editorOpenReasons) { model.beginEditor(); showsEditor = true }
                .accessibilityIdentifier("v15.f3e.editor.open")
        }
    }

    @ViewBuilder private var checkpointSurface: some View {
        V15Section("核对记录", detail: model.selectedTarget?.label) {
            switch model.checkpointPhase {
            case .idle: V15EmptyState(title: "请选择目标", explanation: "选择账户或账期后读取核对记录。")
            case .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f3e.checkpoints.loading")
            case .empty: V15EmptyState(title: "还没有核对记录", explanation: "首次输入实际余额后，这里会保存可追溯锚点。").accessibilityIdentifier("v15.f3e.checkpoints.empty")
            case .failed(let failure): V15ServiceErrorState(message: failure.message) { if let target = model.selectedTarget { Task { await model.selectTarget(target) } } }.accessibilityIdentifier("v15.f3e.checkpoints.error")
            case .loaded:
                ForEach(model.checkpoints) { checkpoint in
                    Button { Task { await model.selectCheckpoint(checkpoint) } } label: {
                        checkpointRow(checkpoint)
                    }.buttonStyle(.plain).v15PlatformHitArea().accessibilityIdentifier("v15.f3e.checkpoint.\(checkpoint.id)")
                }
            }
        }
    }

    @ViewBuilder private var diagnosisSurface: some View {
        V15Section("差额诊断", detail: model.asOfDateText) {
            switch model.diagnosisPhase {
            case .idle: V15EmptyState(title: "等待目标", explanation: "选择核对目标后读取账面区间。")
            case .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f3e.diagnosis.loading")
            case .empty: V15EmptyState(title: "日期无效", explanation: "请输入今天或更早的上海业务日期。")
            case .failed(let failure): V15ServiceErrorState(message: failure.message) { if let target = model.selectedTarget { Task { await model.selectTarget(target) } } }.accessibilityIdentifier("v15.f3e.diagnosis.error")
            case .loaded:
                if let diagnosis = model.diagnosis {
                    diagnosisCard(diagnosis).accessibilityIdentifier("v15.f3e.diagnosis")
                }
            }
        }
    }

    @ViewBuilder private var attentionSurface: some View {
        V15Section("关注事项") {
            V15Field("忽略到（上海日期）", text: $model.ignoreUntilDateText, prompt: "YYYY-MM-DD", issues: [])
                .accessibilityIdentifier("v15.f3e.ignore.expiry")
            switch model.attentionPhase {
            case .idle, .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f3e.attention.loading")
            case .empty: V15EmptyState(title: "没有待处理事项", explanation: "当前核对与相关业务事实平静。").accessibilityIdentifier("v15.f3e.attention.empty")
            case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.refreshAttention() } }.accessibilityIdentifier("v15.f3e.attention.error")
            case .loaded:
                ForEach(model.attention) { item in
                    VStack(alignment: .leading, spacing: V15Spacing.xs) {
                        HStack { Text(severityLabel(item.severity)).font(V15Typography.label); Spacer(); if let amount = item.amountMinor { V15MoneyText(minorUnits: amount, direction: .neutral) } }
                        Text(item.explanation).font(V15Typography.body).fixedSize(horizontal: false, vertical: true)
                        Text(item.suggestedAction).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
                        V15ActionButton("暂时忽略", kind: .secondary, disabledReasons: model.ignoreReasons(for: item)) { Task { await model.ignore(item) } }
                            .accessibilityIdentifier("v15.f3e.attention.ignore.\(item.id)")
                    }
                    .padding(V15Spacing.md).background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
                }
            }
        }
    }

    private var editorSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.lg) {
                    Text("第 \(model.editorStep) / 3 步").font(V15Typography.label).foregroundStyle(V15Palette.teal.color)
                    editorStep
                    mutationSurface
                    if !model.serverIssues.isEmpty { V15FieldIssues(issues: model.serverIssues).accessibilityIdentifier("v15.f3e.editor.remote-issues") }
                    HStack(alignment: .top) {
                        if model.editorStep > 1 { V15ActionButton("上一步", kind: .quiet) { model.backEditor() }.accessibilityIdentifier("v15.f3e.editor.back") }
                        if model.editorStep < 3 { V15ActionButton("下一步", kind: .primary, disabledReasons: model.advanceReasons) { model.advanceEditor() }.accessibilityIdentifier("v15.f3e.editor.next") }
                        else { V15ActionButton("保存核对记录", kind: .primary, disabledReasons: model.checkpointReasons) { Task { await model.createCheckpoint() } }.accessibilityIdentifier("v15.f3e.editor.submit") }
                    }
                    if model.mutationPhase == .succeeded { V15ActionButton("完成", kind: .secondary) { showsEditor = false }.accessibilityIdentifier("v15.f3e.editor.done") }
                }.padding(V15Spacing.md)
            }
            .background(V15Palette.paper.color)
            .navigationTitle("余额核对")
            .toolbar { Button("关闭") { showsEditor = false }.disabled(!model.editorDismissReasons.isEmpty).accessibilityIdentifier("v15.f3e.editor.close") }
        }
        .accessibilityIdentifier("v15.f3e.editor")
        .interactiveDismissDisabled(!model.editorDismissReasons.isEmpty)
    }

    @ViewBuilder private var editorStep: some View {
        if model.editorStep == 1 {
            V15Section("确认目标") {
                Text(model.selectedTarget?.label ?? "尚未选择").font(V15Typography.cardTitle)
                Text(model.targetKind == .account ? "账户余额锚点" : "信用账期余额锚点").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
            }.accessibilityIdentifier("v15.f3e.editor.step1")
        } else if model.editorStep == 2 {
            V15Section("输入实际余额") {
                V15Field("实际余额（元）", text: $model.actualBalanceText, prompt: "0.00", issues: model.checkpointIssues.filter { $0.fieldPath == "actual_balance_minor" }).accessibilityIdentifier("v15.f3e.editor.amount")
                V15Field("核对日期", text: $model.asOfDateText, prompt: "YYYY-MM-DD", issues: model.checkpointIssues.filter { $0.fieldPath == "as_of" }).accessibilityIdentifier("v15.f3e.editor.as-of")
                V15Field("备注", text: $model.note, prompt: "可选，最多500字", issues: model.checkpointIssues.filter { $0.fieldPath == "note" }, axis: .vertical).accessibilityIdentifier("v15.f3e.editor.note")
                diagnosisSurface
            }.accessibilityIdentifier("v15.f3e.editor.step2")
        } else {
            V15Section("确认并保存") {
                Text(model.selectedTarget?.label ?? "—").font(V15Typography.cardTitle)
                if let amount = CNYAmountParser.minorUnits(model.actualBalanceText) { V15MoneyText(minorUnits: amount, direction: .balance, font: V15Typography.moneyLarge) }
                Text("截至 \(model.asOfDateText) · API按UTC时间戳保存").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
                Text("保存只建立核对证据，不会创建余额调整流水。").font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
            }.accessibilityIdentifier("v15.f3e.editor.step3")
        }
    }

    @ViewBuilder private var mutationSurface: some View {
        if let message = model.successMessage { V15SuccessReceiptState(title: "事实已刷新", detail: message).accessibilityIdentifier("v15.f3e.success") }
        if model.mutationPhase == .loading, !model.hasAcceptedRefreshGate {
            V15LoadingSkeleton().accessibilityIdentifier("v15.f3e.mutation.loading")
        }
        if model.hasUnknownAttempt {
            V15PreviewState {
                VStack(alignment: .leading, spacing: V15Spacing.xs) {
                    Text("\(model.mutationIntentLabel)结果未知").font(V15Typography.cardTitle)
                    Text(model.unknownFactsMessage ?? "不会重发，也不会根据相似记录推断成功。").font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
                    V15ActionButton("只读取最新事实", kind: .secondary, disabledReason: model.isOffline ? .init(code: "offline_read_only", message: "离线不能执行fresh GET。", fieldPath: nil) : nil) { Task { await model.readFreshFactsForUnknown() } }.accessibilityIdentifier("v15.f3e.unknown.readback")
                    V15ActionButton("人工核对后解除锁", kind: .quiet, disabledReason: model.canAbandonUnknown ? nil : .init(code: "fresh_read_required", message: "请先完成fresh GET。", fieldPath: nil)) { model.abandonUnknown() }.accessibilityIdentifier("v15.f3e.unknown.abandon")
                }
            }.accessibilityIdentifier("v15.f3e.unknown")
        }
        if model.hasAcceptedRefreshGate {
            V15PartialProgressState(succeeded: "服务器已接受写入", currentState: model.acceptedRefreshMessage ?? "部分最新事实读取失败", remaining: "只重试GET，不再写入")
                .accessibilityIdentifier("v15.f3e.fact-refresh")
            V15ActionButton("重试事实刷新", kind: .secondary, disabledReasons: model.factRefreshRetryReasons) { Task { await model.retryAcceptedRefresh() } }.accessibilityIdentifier("v15.f3e.fact-refresh.retry")
        }
        if case .conflict(let conflict) = model.mutationPhase { V15ConflictState(conflict: conflict) { Task { await model.reloadAfterConflict() } }.accessibilityIdentifier("v15.f3e.conflict") }
        if case .failed(let failure) = model.mutationPhase, !model.hasAcceptedRefreshGate, model.hasFailedMutation {
            V15PreviewState {
                VStack(alignment: .leading, spacing: V15Spacing.xs) {
                    Text("\(model.mutationIntentLabel)未完成").font(V15Typography.cardTitle)
                    Text(failure.message).font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
                    V15ActionButton("重试\(model.mutationIntentLabel)", symbol: V15Symbol.retry, kind: .secondary, disabledReasons: model.failedMutationRetryReasons) { Task { await model.retryDeterministicMutation() } }
                        .accessibilityIdentifier("v15.f3e.mutation.retry")
                }
            }.accessibilityIdentifier("v15.f3e.mutation.error")
        }
    }

    private func checkpointRow(_ checkpoint: V15ReconciliationCheckpoint) -> some View {
        HStack(alignment: .top, spacing: V15Spacing.sm) {
            RoundedRectangle(cornerRadius: 2).fill(checkpoint.state == .reconciled ? V15Palette.teal.color : V15Palette.yellow.color).frame(width: 4)
            VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                Text(stateLabel(checkpoint.state)).font(V15Typography.body.weight(.semibold))
                Text(Self.timestamp(checkpoint.asOf)).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
                if let note = checkpoint.note { Text(note).font(V15Typography.secondary).lineLimit(2) }
            }
            Spacer()
            V15MoneyText(minorUnits: checkpoint.differenceMinor, direction: .neutral)
        }.padding(V15Spacing.md).background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
    }

    private func diagnosisCard(_ value: V15ReconciliationDiagnosis) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.sm) {
            HStack { Text("账面余额").font(V15Typography.secondary); Spacer(); V15MoneyText(minorUnits: value.bookBalanceMinor, direction: .balance) }
            if let actual = value.actualBalanceMinor { HStack { Text("上次实际余额").font(V15Typography.secondary); Spacer(); V15MoneyText(minorUnits: actual, direction: .balance) } }
            if let difference = value.differenceMinor { HStack { Text("已知差额").font(V15Typography.body.weight(.semibold)); Spacer(); V15MoneyText(minorUnits: difference, direction: .neutral) } }
            ForEach(value.entries) { entry in V15LedgerRow(title: entry.title, detail: Self.timestamp(entry.occurredAt), amountMinor: entry.accountImpactMinor, direction: entry.accountImpactMinor >= 0 ? .inflow : .outflow) }
        }.padding(V15Spacing.md).background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
    }

    private func stateLabel(_ value: V15ReconciliationState) -> String { switch value { case .open: "有差额"; case .reconciled: "已核平"; case .unknown(let raw): "未知状态（\(raw)）" } }
    private func severityLabel(_ value: V15AttentionSeverity) -> String { switch value { case .critical: "重要"; case .warning: "需要留意"; case .info: "提示" } }
    private static func timestamp(_ date: Date) -> String { let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_Hans_CN"); formatter.timeZone = ShanghaiBusinessDate.timeZone; formatter.dateFormat = "yyyy-MM-dd HH:mm"; return formatter.string(from: date) }
}
