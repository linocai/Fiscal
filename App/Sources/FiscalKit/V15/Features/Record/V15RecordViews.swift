import SwiftUI

public struct V15RecordView: View {
    @State private var editorPresented = false
    @State private var model: V15RecordModel
    public init(services: V15Services, prefilled: Bool = false, repaymentPrefilled: Bool = false, occurredOn: Date = Date()) {
        let record = V15RecordModel(services: services, occurredOn: occurredOn)
        if prefilled { record.title = "午餐"; record.amountText = "12.80"; record.accountID = V15F1AFixtures.accountID; record.categoryID = V15F1AFixtures.categoryID }
        if repaymentPrefilled {
            record.kind = .repayment
            record.title = "信用卡还款"
            record.amountText = "12.80"
            record.accountID = V15F1AFixtures.accountID
            record.destinationAccountID = V15F1AFixtures.creditID
            record.creditCycleID = V15F1AFixtures.creditCycleID
        }
        _model = State(initialValue: record)
    }
    public var body: some View {
#if os(iOS)
        NavigationStack {
            VStack(alignment: .leading, spacing: V15Spacing.lg) {
                V15RecordHeader(open: { editorPresented = true })
                Text("新账目会以服务器返回的交易编号、版本和分录为准。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
            }.padding(V15Spacing.lg).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(V15Palette.paper.color).navigationTitle("录入")
        }
        .sheet(isPresented: $editorPresented, onDismiss: { model.dismiss() }) { V15RecordEditor(model: model).presentationDetents([.large]).accessibilityIdentifier("v15.f1a.record.sheet") }
        .accessibilityIdentifier("v15.f1a.record.ios")
#else
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: V15Spacing.lg) {
                Text("账目脊柱").font(V15Typography.surfaceTitle)
                Text("新的事实录入在此开始。保存后只显示服务端实际返回的凭证。") .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
                V15RecordHeader(open: {})
                Spacer()
            }.padding(V15Spacing.lg).frame(minWidth: 330, maxWidth: .infinity, alignment: .topLeading)
            Divider()
            V15RecordEditor(model: model).frame(width: 420)
        }.background(V15Palette.paper.color).accessibilityIdentifier("v15.f1a.record.macos")
#endif
    }
}

private struct V15RecordHeader: View {
    let open: () -> Void
    var body: some View {
        V15Section("手工事实") {
            V15ActionButton("新建账目", symbol: "plus", action: open).accessibilityIdentifier("v15.f1a.record.open")
        }
    }
}

private struct V15RecordEditor: View {
    @Bindable var model: V15RecordModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: V15Spacing.md) {
                HStack { Text("新建账目").font(V15Typography.surfaceTitle); Spacer() }
                form
                references
                submissionState
                V15ActionButton("保存账目", symbol: V15Symbol.receipt, disabledReasons: disabledReasons, action: { Task { await model.submit() } })
                    .accessibilityIdentifier("v15.f1a.record.submit")
            }.padding(V15Spacing.lg)
        }
        .background(V15Palette.paper.color)
        .task { await model.loadReferences() }
        .task(id: model.kind) { await model.loadCategories() }
        .task(id: model.destinationAccountID) { if model.kind == .repayment { await model.loadCreditCycles() } }
        .accessibilityIdentifier("v15.f1a.record.editor")
    }

    private var form: some View {
        V15Section("内容") {
            V15PickerRow("类型", selection: $model.kind) { ForEach(V15ManualTransactionKind.allCases) { Text($0.displayName).tag($0) } }
                .accessibilityIdentifier("v15.f1a.record.kind")
            V15Field("金额（元）", text: $model.amountText, prompt: "例如 12.80", issues: issues("amount_minor"))
            V15Field("名称", text: $model.title, prompt: "例如 午餐", issues: issues("title"))
            V15Field("备注", text: $model.note, prompt: "可选")
            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                Text("业务日期").font(V15Typography.secondary.weight(.semibold)).foregroundStyle(V15Palette.ink.color)
                DatePicker("", selection: $model.occurredOn, displayedComponents: .date)
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "zh_CN"))
                    .environment(\.calendar, shanghaiCalendar)
                    .environment(\.timeZone, ShanghaiBusinessDate.timeZone)
                    .dynamicTypeSize(...datePickerDynamicTypeSize)
                    .accessibilityLabel("业务日期（上海）")
                    .accessibilityValue(shanghaiDateAccessibilityValue)
            }
        }
    }
    @ViewBuilder private var references: some View {
        V15Section("账户与分类") {
            referenceState
            Picker("账户", selection: $model.accountID) {
                Text("请选择").tag(Optional<UUID>.none)
                ForEach(accounts(for: model.kind)) { Text($0.name).tag(Optional($0.id)) }
            }.pickerStyle(.menu).accessibilityIdentifier("v15.f1a.record.account")
            if model.kind == .transfer || model.kind == .repayment {
                Picker("目标账户", selection: $model.destinationAccountID) {
                    Text("请选择").tag(Optional<UUID>.none)
                    ForEach(destinationAccounts(for: model.kind)) { Text($0.name).tag(Optional($0.id)) }
                }.pickerStyle(.menu).accessibilityIdentifier("v15.f1a.record.destination")
            }
            if model.kind == .expense || model.kind == .income || model.kind == .creditPurchase {
                Picker("分类（可选）", selection: $model.categoryID) {
                    Text("不分类").tag(Optional<UUID>.none)
                    ForEach(model.categories) { Text($0.name).tag(Optional($0.id)) }
                }.pickerStyle(.menu).accessibilityIdentifier("v15.f1a.record.category")
            }
            if model.kind == .repayment { creditCyclePicker }
        }
    }
    @ViewBuilder private var referenceState: some View {
        switch model.accountPhase {
        case .loading: V15LoadingSkeleton()
        case .empty: V15EmptyState(title: "没有可用账户", explanation: "请先在主数据中创建账户。")
        case .failed(let message): V15ServiceErrorState(message: message, retry: { Task { await model.retryReferences() } })
        default: EmptyView()
        }
        switch model.categoryPhase {
        case .loading: Text("正在加载分类…").font(V15Typography.secondary)
        case .empty where model.kind == .expense || model.kind == .income || model.kind == .creditPurchase: Text("没有可用分类；可以不分类保存。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
        case .failed(let message): V15ServiceErrorState(message: message, retry: { Task { await model.loadCategories() } })
        default: EmptyView()
        }
    }
    @ViewBuilder private var submissionState: some View {
        switch model.submission {
        case .success(let transaction):
            V15SuccessReceiptState(title: "已保存事实", detail: "交易 \(transaction.id.uuidString) · v\(transaction.version) · \(transaction.postings.count) 条分录", actionTitle: "录入下一笔", action: { model.newEntry() })
                .accessibilityIdentifier("v15.f1a.record.success")
        case .conflict(let conflict): V15ConflictState(conflict: conflict, reload: { Task { await model.reloadAfterConflict() } })
        case .failed(let failure): V15ServiceErrorState(message: failure.message, retry: { Task { await model.submit() } })
        default: EmptyView()
        }
    }
    private func accounts(for kind: V15ManualTransactionKind) -> [V15AccountResponse] {
        switch kind { case .creditPurchase: model.accounts.filter { $0.kind == .credit }; case .transfer, .repayment: model.accounts.filter { $0.kind == .cash || $0.kind == .debit }; case .expense, .income: model.accounts.filter { $0.kind == .cash || $0.kind == .debit } }
    }
    private func destinationAccounts(for kind: V15ManualTransactionKind) -> [V15AccountResponse] { kind == .repayment ? model.accounts.filter { $0.kind == .credit } : model.accounts.filter { $0.kind == .cash || $0.kind == .debit } }
    @ViewBuilder private var creditCyclePicker: some View {
        switch model.creditCyclePhase {
        case .loading: Text("正在加载可用信用账期…").font(V15Typography.secondary)
        case .empty: V15EmptyState(title: "没有可还款账期", explanation: "所选信用账户当前没有可用账期。")
        case .failed(let message): V15ServiceErrorState(message: message, retry: { Task { await model.retryCreditCycles() } })
        default:
            Picker("信用账期", selection: $model.creditCycleID) {
                Text("请选择").tag(Optional<UUID>.none)
                ForEach(model.creditCycles) { cycle in Text(cycleLabel(cycle)).tag(Optional(cycle.id)) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("v15.f1a.record.credit-cycle")
            .accessibilityValue(model.creditCycleID.flatMap { selectedID in model.creditCycles.first(where: { $0.id == selectedID }).map(cycleLabel) } ?? "未选择信用账期")
            V15FieldIssues(issues: issues("credit_cycle_id"))
        }
    }
    private func cycleLabel(_ cycle: V15CreditCycle) -> String { "\(cycle.periodStart) 至 \(cycle.periodEnd) · 还款日 \(cycle.dueDate)" }
    private var datePickerDynamicTypeSize: DynamicTypeSize { dynamicTypeSize.isAccessibilitySize ? .accessibility1 : dynamicTypeSize }
    private var shanghaiDateAccessibilityValue: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = shanghaiCalendar
        formatter.timeZone = ShanghaiBusinessDate.timeZone
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: model.occurredOn)
    }
    private func issues(_ path: String) -> [V15FieldIssue] { model.allIssues.filter { $0.fieldPath == path } }
    private var disabledReasons: [V15DisabledReason] {
        var reasons = model.localIssues.map { V15DisabledReason(code: $0.code, message: $0.message, fieldPath: $0.fieldPath) }
        if case .loading = model.accountPhase { reasons.append(.init(code: "accounts_loading", message: "账户仍在加载。", fieldPath: "account_id")) }
        if case .submitting = model.submission { reasons.append(.init(code: "submitting", message: "正在提交账目。", fieldPath: nil)) }
        return reasons
    }
    private var shanghaiCalendar: Calendar { var calendar = Calendar(identifier: .gregorian); calendar.locale = Locale(identifier: "zh_CN"); calendar.timeZone = ShanghaiBusinessDate.timeZone; return calendar }
}
