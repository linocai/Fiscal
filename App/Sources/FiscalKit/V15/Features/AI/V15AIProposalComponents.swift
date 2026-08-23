import SwiftUI

struct V15AIProposalRow: View {
    let proposal: V15AIProposal
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: V15Spacing.sm) {
                RoundedRectangle(cornerRadius: 2).fill(marker).frame(width: 4, height: 34).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                    Text(proposal.title ?? "未命名提案").font(V15Typography.body.weight(.semibold)).foregroundStyle(V15Palette.ink.color).lineLimit(2)
                    Text("\(Self.statusLabel(proposal.status)) · \(proposal.source.displayName)").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    if !proposal.missingFields.isEmpty { Text("缺少：\(proposal.missingFields.joined(separator: "、"))").font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color).lineLimit(2) }
                }
                Spacer(minLength: V15Spacing.xs)
                if let amount = proposal.amountMinor { V15MoneyText(minorUnits: amount, direction: .outflow) }
            }
            .padding(.vertical, V15Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, V15Spacing.sm)
        .background(selected ? V15Palette.selected.color : .clear, in: RoundedRectangle(cornerRadius: V15Radius.control))
        .v15PlatformHitArea()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Self.statusLabel(proposal.status))，\(proposal.title ?? "未命名提案")，\(proposal.missingFields.isEmpty ? "字段完整" : "缺少\(proposal.missingFields.joined(separator: "、"))")")
        .accessibilityIdentifier("v15.f3f.proposal.\(proposal.id)")
    }

    private var marker: Color {
        switch proposal.status { case .pending: V15Palette.teal.color; case .processing: V15Palette.yellow.color; case .failed: V15Palette.gold.color; case .executed: V15Palette.teal.color.opacity(0.45); case .ignored, .undone: V15Palette.ink.color.opacity(0.3); case .unknown: V15Palette.yellow.color }
    }

    static func statusLabel(_ status: V15AIProposalStatus) -> String {
        switch status {
        case .processing: "解析中"
        case .pending: "待人工确认"
        case .executed: "已人工执行"
        case .failed: "解析失败"
        case .ignored: "已忽略"
        case .undone: "已撤销"
        case .unknown(let raw): "未知状态（\(raw)）"
        }
    }
}

struct V15AIProposalDetail: View {
    let proposal: V15AIProposal
    let events: [V15AIQualityEvent]
    var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.lg) {
            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(V15AIProposalRow.statusLabel(proposal.status)).font(V15Typography.label).foregroundStyle(V15Palette.teal.color)
                    Spacer()
                    Text("v\(proposal.version)").font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.55))
                }
                Text(proposal.title ?? "未命名提案").font(V15Typography.cardTitle).foregroundStyle(V15Palette.ink.color).fixedSize(horizontal: false, vertical: true)
                if let amount = proposal.amountMinor { V15MoneyText(minorUnits: amount, direction: .outflow, font: V15Typography.moneyLarge) }
                VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                    Text("你输入的原文").font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.62))
                    Text("「\(proposal.text)」").font(V15Typography.body).foregroundStyle(V15Palette.ink.color.opacity(0.76)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                .padding(V15Spacing.sm).frame(maxWidth: .infinity, alignment: .leading)
                .background(V15Palette.ink.color.opacity(0.035), in: RoundedRectangle(cornerRadius: V15Radius.control))
                .accessibilityIdentifier("v15.f3f.original-text")
            }

            V15Section("解析完整度") {
                if proposal.target == .cashFlow {
                    Label("执行目标：未来现金流（不会创建即时交易）", systemImage: "calendar.badge.clock")
                        .font(V15Typography.body.weight(.medium)).foregroundStyle(V15Palette.teal.color)
                        .accessibilityIdentifier("v15.f3f.cash-flow.target")
                }
                confidenceRow("整体", value: proposal.overallConfidenceBPS)
                confidenceRow("类型", value: proposal.fieldConfidences.kind)
                confidenceRow("金额", value: proposal.fieldConfidences.amountMinor)
                confidenceRow("时间", value: proposal.fieldConfidences.occurredAt)
                confidenceRow("标题", value: proposal.fieldConfidences.title)
                confidenceRow("备注", value: proposal.fieldConfidences.note)
                confidenceRow("账户", value: proposal.fieldConfidences.accountID)
                confidenceRow("分类", value: proposal.fieldConfidences.categoryID)
                confidenceRow("目标账户", value: proposal.fieldConfidences.destinationAccountID)
                Text("置信度只用于排序与提示，不能跳过人工确认；低置信字段以未定底色标出。")
                    .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
                if !proposal.missingFields.isEmpty {
                    Label("缺少字段：\(proposal.missingFields.joined(separator: "、"))", systemImage: V15Symbol.warning)
                        .font(V15Typography.secondary.weight(.medium)).foregroundStyle(V15Palette.gold.color).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("v15.f3f.missing-fields")
                }
                if !proposal.reasonCodes.isEmpty { Text("原因：\(proposal.reasonCodes.joined(separator: " · "))").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true) }
                if let explanation = proposal.explanation { Text(explanation).font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true) }
            }

            if proposal.errorCode != nil || proposal.errorMessage != nil {
                V15Section("错误事实") {
                    Label(proposal.errorMessage ?? "服务端没有提供错误说明。", systemImage: V15Symbol.warning).font(V15Typography.body).fixedSize(horizontal: false, vertical: true)
                    if let code = proposal.errorCode { Text(code).font(.caption.monospaced()).foregroundStyle(V15Palette.ink.color.opacity(0.6)) }
                }.accessibilityIdentifier("v15.f3f.proposal-error")
            }

            V15Section("人工编辑差异") {
                if let diff = proposal.finalFieldDiff, !diff.isEmpty {
                    ForEach(diff.keys.sorted(), id: \.self) { key in
                        HStack(alignment: .top) { Text(Self.fieldLabel(key)).font(V15Typography.secondary.weight(.semibold)); Spacer(); Text(Self.diffSummary(diff[key])).font(V15Typography.secondary).multilineTextAlignment(.trailing) }
                    }
                } else {
                    Text(proposal.qualityStatus == .historicalUnavailable ? "历史提案没有可用的解析快照。" : "尚未保存人工编辑差异。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
                }
            }.accessibilityIdentifier("v15.f3f.diff")

            V15Section("质量事件") {
                if events.isEmpty { Text("暂时没有质量事件。会保留解析、人工确认、失败与撤销事实。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }
                ForEach(events) { event in
                    HStack(alignment: .top, spacing: V15Spacing.sm) {
                        Circle().fill(V15Palette.teal.color).frame(width: 7, height: 7).padding(.top, 6)
                        VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                            Text(Self.eventLabel(event.eventType)).font(V15Typography.body.weight(.medium))
                            if let reason = event.reason { Text(reason).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }
                        }
                    }
                }
            }.accessibilityIdentifier("v15.f3f.quality-events")
        }
    }

    @ViewBuilder private func confidenceRow(_ label: String, value: Int?) -> some View {
        let needsReview = value.map { $0 < 9_000 } ?? true
        HStack(spacing: V15Spacing.sm) {
            RoundedRectangle(cornerRadius: 2).fill(needsReview ? V15Palette.yellow.color : V15Palette.teal.color.opacity(0.45)).frame(width: 4, height: 24).accessibilityHidden(true)
            Text(label).font(V15Typography.secondary)
            if needsReview { Text("需复核").font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.62)) }
            Spacer()
            Text(value.map { "\($0 / 100)%" } ?? "未提供").font(V15Typography.money).foregroundStyle(V15Palette.ink.color)
        }
        .padding(.horizontal, V15Spacing.sm).padding(.vertical, V15Spacing.xs)
        .background(needsReview ? V15Palette.provisional.color : V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
    }
    private static func fieldLabel(_ raw: String) -> String { ["kind": "类型", "amount_minor": "金额", "occurred_at": "时间", "title": "标题", "note": "备注", "account_id": "账户", "category_id": "分类", "destination_account_id": "目标账户", "credit_cycle_id": "账期", "target": "目标" ][raw] ?? raw }
    private static func diffSummary(_ value: V15AIEventValue?) -> String { guard case .object(let object)? = value else { return "已修改" }; return "\(scalar(object["from"])) → \(scalar(object["to"]))" }
    private static func scalar(_ value: V15AIEventValue?) -> String { switch value { case .string(let value): value; case .integer(let value): String(value); case .decimal(let value): "\(value)"; case .bool(let value): value ? "true" : "false"; case .null: "空"; case .array, .object: "结构化内容"; case nil: "空" } }
    private static func eventLabel(_ value: V15AIQualityEventType) -> String { switch value { case .parsed: "已解析"; case .confirmUnchanged: "人工确认未改"; case .confirmEdited: "人工确认并编辑"; case .ignored: "已忽略"; case .executeFailed: "执行失败"; case .historicalAutomaticExecute: "历史自动执行事件（只读）"; case .manualExecute: "人工执行"; case .undone: "已撤销"; case .providerRetry: "提供方重试"; case .finalFailure: "最终失败"; case .unknown(let raw): "未知事件（\(raw)）" } }
}

struct V15AIMutationSurface: View {
    @Bindable var model: V15AIProposalModel
    var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.sm) {
            switch model.mutationPhase {
            case .idle: EmptyView()
            case .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f3f.mutation.loading")
            case .succeeded(let message): V15SuccessReceiptState(title: "服务端事实已更新", detail: message).accessibilityIdentifier("v15.f3f.success")
            case .failed(let failure): V15ServiceErrorState(message: failure.message) {}.accessibilityIdentifier("v15.f3f.mutation.error")
            case .conflict(let conflict):
                V15PreviewState {
                    VStack(alignment: .leading, spacing: V15Spacing.xs) {
                        Text("服务端版本已变化").font(V15Typography.cardTitle)
                        Text(model.recoveryMessage ?? conflict.message).font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
                        V15ActionButton("只读取冲突后的最新提案", symbol: V15Symbol.retry, kind: .secondary, disabledReason: model.directReadbackDisabledReason) { Task { await model.reloadConflict() } }
                            .accessibilityIdentifier("v15.f3f.conflict.reload")
                    }
                }.accessibilityIdentifier("v15.f3f.conflict")
            case .unknown:
                V15PreviewState {
                    VStack(alignment: .leading, spacing: V15Spacing.xs) {
                        Text("写入结果未知").font(V15Typography.cardTitle)
                        Text(model.recoveryMessage ?? "不根据相似记录猜测成功。 ").font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
                        if model.hasUnknownDirect {
                            V15ActionButton("只读取最新提案", kind: .secondary, disabledReason: model.directReadbackDisabledReason) { Task { await model.recoverUnknownDirect() } }.accessibilityIdentifier("v15.f3f.unknown.readback")
                            V15ActionButton("人工核对后解除锁", kind: .quiet, disabledReason: model.readbackCompleted ? nil : .init(code: "fresh_read_required", message: "请先完成一次服务端最新事实读取。", fieldPath: nil)) { model.abandonUnknownDirect() }.accessibilityIdentifier("v15.f3f.unknown.abandon")
                        }
                    }
                }
            }
            if !model.serverIssues.isEmpty { V15FieldIssues(issues: model.serverIssues).accessibilityIdentifier("v15.f3f.remote-issues") }
        }
    }
}

struct V15AIStableCreateRecoverySurface: View {
    @Bindable var model: V15AIProposalModel

    var body: some View {
        if model.hasStableCreateRecovery {
            V15PreviewState {
                VStack(alignment: .leading, spacing: V15Spacing.xs) {
                    Text(model.hasUnknownCreate ? "新建提案结果未知" : "正在等待新建提案结果").font(V15Typography.cardTitle)
                    Text(model.recoveryMessage ?? "此请求使用固定凭证；不会用新文本或新凭证重新发送。")
                        .font(V15Typography.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    V15ActionButton("用同一凭证重试相同文本", symbol: V15Symbol.retry, kind: .secondary, disabledReasons: model.unknownCreateRetryReasons) {
                        Task { await model.retryUnknownCreate() }
                    }
                    .accessibilityIdentifier("v15.f3f.unknown.create-retry")
                    V15ActionButton("放弃这次未知请求", kind: .quiet, disabledReasons: model.unknownCreateAbandonReasons) {
                        model.abandonUnknownCreate()
                    }
                    .accessibilityIdentifier("v15.f3f.unknown.create-abandon")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("v15.f3f.unknown.create-recovery")
        }
    }
}

struct V15AIEditorFields: View {
    @Bindable var model: V15AIProposalModel
    var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            if model.isCashFlowReview {
                Label("未来现金流草案", systemImage: "calendar.badge.clock").font(V15Typography.body.weight(.semibold)).foregroundStyle(V15Palette.teal.color)
                Text("服务端仍要求兼容的 draft wire；执行时会按确认后的方向、计划金额和预计日期创建现金流事项。")
                    .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
            }
            Picker(model.isCashFlowReview ? "现金流方向" : "交易类型", selection: $model.kind) { ForEach(model.reviewKinds) { Text($0.displayName).tag($0) } }.pickerStyle(.menu).accessibilityIdentifier("v15.f3f.editor.kind")
            V15Field(model.isCashFlowReview ? "计划金额（元）" : "金额（元）", text: $model.amountText, prompt: "0.00", issues: issues("draft.amount_minor")).accessibilityIdentifier("v15.f3f.editor.amount")
            DatePicker(model.isCashFlowReview ? "预计日期" : "发生时间", selection: $model.occurredAt).accessibilityIdentifier("v15.f3f.editor.date")
            V15Field("标题", text: $model.title, prompt: "最多120字", issues: issues("draft.title")).accessibilityIdentifier("v15.f3f.editor.title")
            V15Field("备注", text: $model.note, prompt: "可选，最多500字", issues: issues("draft.note"), axis: .vertical).accessibilityIdentifier("v15.f3f.editor.note")
            Picker("账户", selection: $model.accountID) {
                Text("请选择").tag(nil as UUID?)
                ForEach(model.activeAccounts) { Text($0.name).tag(Optional($0.id)) }
            }.pickerStyle(.menu).accessibilityIdentifier("v15.f3f.editor.account")
            if model.kind != .transfer && model.kind != .repayment {
                Picker("分类", selection: $model.categoryID) {
                    Text("未分类（允许）").tag(nil as UUID?)
                    ForEach(model.visibleCategories) { Text($0.name).tag(Optional($0.id)) }
                }.pickerStyle(.menu).accessibilityIdentifier("v15.f3f.editor.category")
            }
            if model.kind == .transfer || model.kind == .repayment {
                Picker("目标账户", selection: $model.destinationAccountID) {
                    Text("请选择").tag(nil as UUID?)
                    ForEach(model.activeAccounts) { Text($0.name).tag(Optional($0.id)) }
                }.pickerStyle(.menu).accessibilityIdentifier("v15.f3f.editor.destination")
            }
            if model.kind == .repayment {
                Picker("信用账期", selection: $model.creditCycleID) {
                    Text("请选择").tag(nil as UUID?)
                    ForEach(model.creditCycles) { Text("\($0.statementDate) · \(Self.accountName($0.accountID, model: model))").tag(Optional($0.id)) }
                }.pickerStyle(.menu).accessibilityIdentifier("v15.f3f.editor.credit-cycle")
            }
            if !model.editorIssues.isEmpty { V15FieldIssues(issues: model.editorIssues).accessibilityIdentifier("v15.f3f.editor.local-issues") }
        }
    }
    private func issues(_ path: String) -> [V15FieldIssue] { (model.editorIssues + model.serverIssues).filter { $0.fieldPath == path } }
    private static func accountName(_ id: UUID, model: V15AIProposalModel) -> String { model.accounts.first(where: { $0.id == id })?.name ?? "信用账户" }
}

struct V15AIProposalActions: View {
    @Bindable var model: V15AIProposalModel
    let proposal: V15AIProposal
    let openReview: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.sm) {
            if proposal.status == .pending {
                V15ActionButton("审核字段", kind: .secondary, disabledReasons: model.actionReasons(.replace, proposal: proposal), action: openReview).accessibilityIdentifier("v15.f3f.review.open")
                V15ActionButton("人工执行", symbol: "checkmark.circle", kind: .primary, disabledReasons: model.actionReasons(.execute, proposal: proposal)) { Task { await model.execute() } }.accessibilityIdentifier("v15.f3f.execute")
                V15ActionButton("忽略提案", kind: .quiet, disabledReasons: model.actionReasons(.ignore, proposal: proposal)) { Task { await model.ignore() } }.accessibilityIdentifier("v15.f3f.ignore")
            } else if proposal.status == .failed {
                V15ActionButton("重新解析", symbol: V15Symbol.retry, kind: .secondary, disabledReasons: model.actionReasons(.retry, proposal: proposal)) { Task { await model.retryParsing() } }.accessibilityIdentifier("v15.f3f.retry")
            } else if proposal.status == .executed {
                V15ActionButton("撤销这笔人工执行", kind: .destructive, disabledReasons: model.actionReasons(.undo, proposal: proposal)) { Task { await model.undo() } }.accessibilityIdentifier("v15.f3f.undo")
            } else {
                Text(proposal.status.isDisplayOnly ? "未知未来状态只可查看。" : "此状态没有可用写操作。")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    .accessibilityIdentifier(proposal.status.isDisplayOnly ? "v15.f3f.unknown-readonly" : "v15.f3f.no-actions")
            }
        }
    }
}
