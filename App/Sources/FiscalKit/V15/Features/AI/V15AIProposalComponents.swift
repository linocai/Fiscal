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
                    Text(proposal.title ?? "未命名内容").font(V15Typography.body.weight(.semibold)).foregroundStyle(V15Palette.ink.color).lineLimit(2)
                    Text("\(Self.statusLabel(proposal.status)) · \(proposal.source.displayName)").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    if !proposal.missingFields.isEmpty { Text("待补充：\(proposal.missingFields.map(Self.fieldLabel).joined(separator: "、"))").font(V15Typography.secondary).foregroundStyle(V15Palette.gold.color).lineLimit(2) }
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
        .accessibilityLabel("\(Self.statusLabel(proposal.status))，\(proposal.title ?? "未命名内容")，\(proposal.missingFields.isEmpty ? "内容完整" : "待补充\(proposal.missingFields.map(Self.fieldLabel).joined(separator: "、"))")")
        .accessibilityIdentifier("v15.f3f.proposal.\(proposal.id)")
    }

    private var marker: Color {
        switch proposal.status { case .pending: V15Palette.teal.color; case .processing: V15Palette.yellow.color; case .failed: V15Palette.gold.color; case .executed: V15Palette.teal.color.opacity(0.45); case .ignored, .undone: V15Palette.ink.color.opacity(0.3); case .unknown: V15Palette.yellow.color }
    }

    static func statusLabel(_ status: V15AIProposalStatus) -> String {
        switch status {
        case .processing: "解析中"
        case .pending: "待确认"
        case .executed: "已记账"
        case .failed: "解析失败"
        case .ignored: "已忽略"
        case .undone: "已撤销"
        case .unknown: "暂时无法识别"
        }
    }

    private static func fieldLabel(_ raw: String) -> String {
        ["kind": "类型", "amount_minor": "金额", "occurred_at": "时间", "title": "标题", "note": "备注", "account_id": "账户", "category_id": "分类", "destination_account_id": "目标账户", "credit_cycle_id": "账期", "target": "目标"][raw] ?? "其他内容"
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
                }
                Text(proposal.title ?? "未命名内容").font(V15Typography.cardTitle).foregroundStyle(V15Palette.ink.color).fixedSize(horizontal: false, vertical: true)
                if let amount = proposal.amountMinor { V15MoneyText(minorUnits: amount, direction: .outflow, font: V15Typography.moneyLarge) }
                VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                    Text("你输入的原文").font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.62))
                    Text("「\(proposal.text)」").font(V15Typography.body).foregroundStyle(V15Palette.ink.color.opacity(0.76)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                .padding(V15Spacing.sm).frame(maxWidth: .infinity, alignment: .leading)
                .background(V15Palette.ink.color.opacity(0.035), in: RoundedRectangle(cornerRadius: V15Radius.control))
                .accessibilityIdentifier("v15.f3f.original-text")
            }

                V15Section("识别结果") {
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
                Text("识别把握只用于排序和提醒，不能跳过你的确认；不确定的内容会以浅色标出。")
                    .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
                if !proposal.missingFields.isEmpty {
                    Label("待补充：\(proposal.missingFields.map(Self.fieldLabel).joined(separator: "、"))", systemImage: V15Symbol.warning)
                        .font(V15Typography.secondary.weight(.medium)).foregroundStyle(V15Palette.gold.color).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("v15.f3f.missing-fields")
                }
                if let explanation = proposal.explanation { Text(explanation).font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true) }
            }

            if proposal.errorCode != nil || proposal.errorMessage != nil {
                V15Section("处理失败") {
                    Label(proposal.errorMessage ?? "没有可用的错误说明。", systemImage: V15Symbol.warning).font(V15Typography.body).fixedSize(horizontal: false, vertical: true)
                }.accessibilityIdentifier("v15.f3f.proposal-error")
            }

            V15Section("你的修改") {
                if let diff = proposal.finalFieldDiff, !diff.isEmpty {
                    ForEach(diff.keys.sorted(), id: \.self) { key in
                        HStack(alignment: .top) { Text(Self.fieldLabel(key)).font(V15Typography.secondary.weight(.semibold)); Spacer(); Text(Self.diffSummary(diff[key])).font(V15Typography.secondary).multilineTextAlignment(.trailing) }
                    }
                } else {
                    Text(proposal.qualityStatus == .historicalUnavailable ? "历史记录没有可用的识别详情。" : "尚未保存修改。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
                }
            }.accessibilityIdentifier("v15.f3f.diff")

            V15Section("处理记录") {
                if events.isEmpty { Text("暂时没有处理记录。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }
                ForEach(events) { event in
                    HStack(alignment: .top, spacing: V15Spacing.sm) {
                        Circle().fill(V15Palette.teal.color).frame(width: 7, height: 7).padding(.top, 6)
                        VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                            Text(Self.eventLabel(event.eventType)).font(V15Typography.body.weight(.medium))
                            if let reason = Self.eventReason(event) { Text(reason).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }
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
    private static func fieldLabel(_ raw: String) -> String { ["kind": "类型", "amount_minor": "金额", "occurred_at": "时间", "title": "标题", "note": "备注", "account_id": "账户", "category_id": "分类", "destination_account_id": "目标账户", "credit_cycle_id": "账期", "target": "目标" ][raw] ?? "其他内容" }
    private static func diffSummary(_ value: V15AIEventValue?) -> String { guard case .object(let object)? = value else { return "已修改" }; return "\(scalar(object["from"])) → \(scalar(object["to"]))" }
    private static func scalar(_ value: V15AIEventValue?) -> String { switch value { case .string(let value): value; case .integer(let value): String(value); case .decimal(let value): "\(value)"; case .bool(let value): value ? "true" : "false"; case .null: "空"; case .array, .object: "结构化内容"; case nil: "空" } }
    private static func eventLabel(_ value: V15AIQualityEventType) -> String { switch value { case .parsed: "已解析"; case .confirmUnchanged: "确认时未修改"; case .confirmEdited: "确认时已修改"; case .ignored: "已忽略"; case .executeFailed: "记账失败"; case .historicalAutomaticExecute: "历史自动处理（只读）"; case .manualExecute: "已记账"; case .undone: "已撤销"; case .providerRetry: "已重试解析"; case .finalFailure: "最终失败"; case .unknown: "其他事件" } }
    private static func eventReason(_ event: V15AIQualityEvent) -> String? {
        guard let reason = event.reason else { return nil }
        return switch reason {
        case "ai_provider_not_configured": "AI 服务尚未配置。"
        case "ai_provider_unavailable", "ai_provider_upstream_failure": "AI 服务端当时暂时异常。"
        case "ai_provider_rate_limited": "AI 服务当时请求较多。"
        case "ai_provider_timeout": "AI 服务当时响应超时。"
        case "ai_provider_connection_failed": "当时无法连接 AI 服务。"
        case "ai_provider_configuration_rejected": "AI 服务当时拒绝了当前配置。"
        case "ai_provider_invalid_response": "AI 服务当时返回了无法识别的内容。"
        case "ai_processing_cancelled": "本次解析已取消。"
        default:
            event.eventType == .executeFailed ? "本次记账未能完成。" : "本次处理未能完成。"
        }
    }
}

struct V15AIMutationSurface: View {
    @Bindable var model: V15AIProposalModel
    var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.sm) {
            switch model.mutationPhase {
            case .idle: EmptyView()
            case .loading: V15LoadingSkeleton().accessibilityIdentifier("v15.f3f.mutation.loading")
            case .succeeded(let message): V15SuccessReceiptState(title: "数据已更新", detail: message).accessibilityIdentifier("v15.f3f.success")
            case .failed(let failure): V15ServiceErrorState(message: failure.message) {}.accessibilityIdentifier("v15.f3f.mutation.error")
            case .conflict(let conflict):
                V15PreviewState {
                    VStack(alignment: .leading, spacing: V15Spacing.xs) {
                        Text("数据已更新").font(V15Typography.cardTitle)
                        Text(model.recoveryMessage ?? conflict.message).font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
                        V15ActionButton("读取最新内容", symbol: V15Symbol.retry, kind: .secondary, disabledReason: model.directReadbackDisabledReason) { Task { await model.reloadConflict() } }
                            .accessibilityIdentifier("v15.f3f.conflict.reload")
                    }
                }.accessibilityIdentifier("v15.f3f.conflict")
            case .unknown:
                V15PreviewState {
                    VStack(alignment: .leading, spacing: V15Spacing.xs) {
                        Text("操作结果暂时不明").font(V15Typography.cardTitle)
                        Text(model.recoveryMessage ?? "不根据相似记录猜测成功。 ").font(V15Typography.secondary).fixedSize(horizontal: false, vertical: true)
                        if model.hasUnknownDirect {
                            V15ActionButton("读取最新内容", kind: .secondary, disabledReason: model.directReadbackDisabledReason) { Task { await model.recoverUnknownDirect() } }.accessibilityIdentifier("v15.f3f.unknown.readback")
                            V15ActionButton("核对后继续", kind: .quiet, disabledReason: model.readbackCompleted ? nil : .init(code: "fresh_read_required", message: "请先读取最新内容。", fieldPath: nil)) { model.abandonUnknownDirect() }.accessibilityIdentifier("v15.f3f.unknown.abandon")
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
                    Text(model.hasUnknownCreate ? "创建结果暂时不明" : "正在等待创建结果").font(V15Typography.cardTitle)
                    Text(model.recoveryMessage ?? "系统会用相同内容安全检查，不会创建重复记录。")
                        .font(V15Typography.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    V15ActionButton("安全重试相同内容", symbol: V15Symbol.retry, kind: .secondary, disabledReasons: model.unknownCreateRetryReasons) {
                        Task { await model.retryUnknownCreate() }
                    }
                    .accessibilityIdentifier("v15.f3f.unknown.create-retry")
                    V15ActionButton("停止检查", kind: .quiet, disabledReasons: model.unknownCreateAbandonReasons) {
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
                Text("执行时会按你确认的方向、计划金额和预计日期创建现金流事项。")
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
    @State private var showsDeleteConfirmation = false
    var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.sm) {
            if proposal.status == .pending {
                V15ActionButton("检查并修改", kind: .secondary, disabledReasons: model.actionReasons(.replace, proposal: proposal), action: openReview).accessibilityIdentifier("v15.f3f.review.open")
                V15ActionButton("确认记账", symbol: "checkmark.circle", kind: .primary, disabledReasons: model.actionReasons(.execute, proposal: proposal)) { Task { await model.execute() } }.accessibilityIdentifier("v15.f3f.execute")
                V15ActionButton("忽略", kind: .quiet, disabledReasons: model.actionReasons(.ignore, proposal: proposal)) { Task { await model.ignore() } }.accessibilityIdentifier("v15.f3f.ignore")
            } else if proposal.status == .failed {
                V15ActionButton("重新解析", symbol: V15Symbol.retry, kind: .secondary, disabledReasons: model.actionReasons(.retry, proposal: proposal)) { Task { await model.retryParsing() } }.accessibilityIdentifier("v15.f3f.retry")
            } else if proposal.status == .executed {
                V15ActionButton("撤销这笔记账", kind: .destructive, disabledReasons: model.actionReasons(.undo, proposal: proposal)) { Task { await model.undo() } }.accessibilityIdentifier("v15.f3f.undo")
            } else if proposal.status == .processing {
                Text("正在解析，完成后即可处理。")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    .accessibilityIdentifier("v15.f3f.no-actions")
            } else {
                Text(proposal.status.isDisplayOnly ? "未知未来状态只可查看。" : "此状态没有可用写操作。")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    .accessibilityIdentifier(proposal.status.isDisplayOnly ? "v15.f3f.unknown-readonly" : "v15.f3f.no-actions")
            }
            if [.pending, .failed, .ignored].contains(proposal.status) {
                V15ActionButton("删除这项内容", symbol: "trash", kind: .destructive, disabledReasons: model.actionReasons(.delete, proposal: proposal)) {
                    showsDeleteConfirmation = true
                }
                .accessibilityIdentifier("v15.f3f.delete")
            }
        }
        .alert("删除这项内容？", isPresented: $showsDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { Task { await model.deleteSelected() } }
                .accessibilityIdentifier("v15.f3f.delete.confirm")
        } message: {
            Text("只删除这项尚未记账的内容，不会影响账本。删除后无法恢复。")
        }
    }
}
