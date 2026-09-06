import SwiftUI

public struct V15RecordView: View {
    @State private var editorPresented = false
    @State private var model: V15RecordModel
    private let presentsEditorDirectly: Bool
    private let onCommitted: (V15RecordModel.CommitOutcome) -> Void
    @Environment(\.dismiss) private var dismiss
    public init(services: V15Services, prefilled: Bool = false, repaymentPrefilled: Bool = false, occurredOn: Date = Date(), presentsEditorDirectly: Bool = false, onCommitted: @escaping (V15RecordModel.CommitOutcome) -> Void = { _ in }) {
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
        self.presentsEditorDirectly = presentsEditorDirectly
        self.onCommitted = onCommitted
    }
    public var body: some View {
#if os(iOS)
        Group {
            if presentsEditorDirectly {
                NavigationStack {
                    V15RecordEditor(model: model, onCommitted: onCommitted)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                        }
                }
            } else {
                NavigationStack {
                    VStack(alignment: .leading, spacing: V15Spacing.lg) {
                        V15RecordHeader(open: { editorPresented = true })
                        Text("保存后会显示最终金额、账户和分录。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    }.padding(V15Spacing.lg).v15IOSScreenCanvas().navigationTitle("录入")
                }
            }
        }
        .sheet(isPresented: $editorPresented, onDismiss: { model.dismiss() }) { V15RecordEditor(model: model, onCommitted: onCommitted).presentationDetents([.large]).accessibilityIdentifier("v15.f1a.record.sheet") }
        .accessibilityIdentifier("v15.f1a.record.ios")
#else
        V15RecordEditor(model: model, onCommitted: onCommitted)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(V15Palette.paper.color)
            .accessibilityIdentifier("v15.f1a.record.macos")
#endif
    }
}

private struct V15RecordHeader: View {
    let open: () -> Void
    var body: some View {
        V15Section("账目信息") {
            V15ActionButton("新建账目", symbol: "plus", action: open).accessibilityIdentifier("v15.f1a.record.open")
        }
    }
}

private struct V15RecordEditor: View {
    @Bindable var model: V15RecordModel
    let onCommitted: (V15RecordModel.CommitOutcome) -> Void
    @State private var showsNote = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        Group {
#if os(iOS)
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.section) {
                    iOSForm
                    repaymentPreviewState
                    submissionState
                }.padding(V15IOSLayout.contentPadding)
            }
            .accessibilityIdentifier("v15.f1a.record.scroll")
            .scrollDismissesKeyboard(.interactively)
            .v15IOSScreenCanvas()
            .navigationTitle("记一笔")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                primaryAction
                    .padding(.horizontal, V15IOSLayout.contentPadding)
                    .padding(.vertical, V15Spacing.sm)
                    .background(V15Palette.paper.color)
                    .overlay(alignment: .top) { Rectangle().fill(V15Palette.hairline.color).frame(height: 1) }
            }
#else
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.md) {
                    HStack { Text("新建账目").font(V15Typography.surfaceTitle); Spacer() }
                    form
                    references
                    repaymentPreviewState
                    submissionState
                    primaryAction
                }.padding(V15Spacing.lg)
            }
            .background(V15Palette.paper.color)
#endif
        }
        .task { await model.loadReferences() }
        .task(id: model.kind) { await model.loadCategories() }
        .task(id: model.destinationAccountID) { if model.kind == .repayment { await model.loadCreditCycles() } }
        .accessibilityIdentifier("v15.f1a.record.editor")
    }

    @ViewBuilder private var primaryAction: some View {
        if model.kind == .repayment, !repaymentPreviewIsReady {
            V15ActionButton("查看还款影响", symbol: "eye", disabledReasons: displayedDisabledReasons, unavailableAccessibilityHint: neutralUnavailableHint) { Task { await model.previewRepayment() } }
                .disabled(!disabledReasons.isEmpty)
                .accessibilityIdentifier("v15.f1a.record.preview")
        } else {
            V15ActionButton(model.kind == .repayment ? "确认还款" : "保存账目", symbol: V15Symbol.receipt, disabledReasons: displayedDisabledReasons, unavailableAccessibilityHint: neutralUnavailableHint, action: submit)
                .disabled(!disabledReasons.isEmpty)
                .accessibilityIdentifier("v15.f1a.record.submit")
        }
    }

    private var form: some View {
        V15Section("内容") {
            V15PickerRow("类型", selection: $model.kind) { ForEach(V15ManualTransactionKind.allCases) { Text($0.displayName).tag($0) } }
                .accessibilityIdentifier("v15.f1a.record.kind")
            V15AmountInput(text: $model.amountText, issues: issues("amount_minor"), automaticallyFocus: true, accessibilityIdentifier: "v15.f1a.record.amount")
            V15Field("名称", text: $model.title, prompt: "例如 午餐", issues: issues("title"))
                .accessibilityIdentifier("v15.f1a.record.title")
            V15Field("备注", text: $model.note, prompt: "可选")
            businessDateField
        }
    }
    private var iOSForm: some View {
        VStack(alignment: .leading, spacing: V15Spacing.lg) {
            iOSKindMenu
            V15AmountInput(text: $model.amountText, issues: issues("amount_minor"), automaticallyFocus: true, accessibilityIdentifier: "v15.f1a.record.amount")
            iOSTitleInput
            iOSReferenceControls
            iOSSecondaryControls
        }
    }

    private var iOSKindMenu: some View {
        Menu {
            ForEach(V15ManualTransactionKind.allCases) { kind in
                Button { model.kind = kind } label: {
                    Label(kind.displayName, systemImage: kindSymbol(kind))
                }
            }
        } label: {
            V15RecordSelectionPill(label: model.kind.displayName, symbol: kindSymbol(model.kind), selected: true)
        }
        .accessibilityIdentifier("v15.f1a.record.kind")
        .accessibilityLabel("类型：\(model.kind.displayName)")
        .accessibilityHint("选择交易类型")
    }

    private var iOSTitleInput: some View {
        VStack(alignment: .leading, spacing: V15Spacing.xs) {
            TextField("名称，例如午餐", text: $model.title, prompt: Text("名称，例如午餐").foregroundStyle(V15Palette.ink.color.opacity(0.56)))
                .font(V15Typography.cardTitle)
                .textFieldStyle(.plain)
                .foregroundStyle(V15Palette.ink.color)
                .tint(V15Palette.teal.color)
                .padding(.vertical, V15Spacing.xs)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(issues("title").isEmpty ? V15Palette.hairline.color : V15Palette.danger.color).frame(height: issues("title").isEmpty ? 1 : 2)
                }
                .accessibilityIdentifier("v15.f1a.record.title")
                .accessibilityLabel("名称")
                .accessibilityHint(issues("title").isEmpty ? "必填。" : issues("title").map(\.message).joined(separator: "；"))
            V15FieldIssues(issues: issues("title"))
        }
    }

    @ViewBuilder private var iOSReferenceControls: some View {
        referenceState
        switch model.kind {
        case .expense, .income, .creditPurchase:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: V15Spacing.sm) { sourceAccountMenu; categoryMenu }
                VStack(alignment: .leading, spacing: V15Spacing.sm) { sourceAccountMenu; categoryMenu }
            }
        case .transfer:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: V15Spacing.sm) { sourceAccountMenu; destinationAccountMenu }
                VStack(alignment: .leading, spacing: V15Spacing.sm) { sourceAccountMenu; destinationAccountMenu }
            }
        case .repayment:
            VStack(alignment: .leading, spacing: V15Spacing.sm) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: V15Spacing.sm) { sourceAccountMenu; destinationAccountMenu }
                    VStack(alignment: .leading, spacing: V15Spacing.sm) { sourceAccountMenu; destinationAccountMenu }
                }
                creditCycleMenu
            }
        }
    }

    private var sourceAccountMenu: some View {
        Menu {
            Button("请选择") { model.accountID = nil }
            ForEach(accounts(for: model.kind)) { account in Button(account.name) { model.accountID = account.id } }
        } label: {
            V15RecordSelectionPill(label: selectedAccountName ?? "账户", symbol: "wallet.bifold", selected: model.accountID != nil)
        }
        .accessibilityIdentifier("v15.f1a.record.account")
        .accessibilityLabel("账户：\(selectedAccountName ?? "未选择")")
        .accessibilityHint("选择账户")
    }

    private var destinationAccountMenu: some View {
        Menu {
            Button("请选择") { model.destinationAccountID = nil }
            ForEach(destinationAccounts(for: model.kind)) { account in Button(account.name) { model.destinationAccountID = account.id } }
        } label: {
            V15RecordSelectionPill(label: selectedDestinationAccountName ?? "目标账户", symbol: "arrow.right.circle", selected: model.destinationAccountID != nil)
        }
        .accessibilityIdentifier("v15.f1a.record.destination")
        .accessibilityLabel("目标账户：\(selectedDestinationAccountName ?? "未选择")")
        .accessibilityHint("选择目标账户")
    }

    private var categoryMenu: some View {
        Menu {
            Button("不分类") { model.categoryID = nil }
            ForEach(model.categories) { category in Button(category.name) { model.categoryID = category.id } }
        } label: {
            V15RecordSelectionPill(label: selectedCategoryName ?? "分类", symbol: "tag", selected: model.categoryID != nil)
        }
        .accessibilityIdentifier("v15.f1a.record.category")
        .accessibilityLabel("分类：\(selectedCategoryName ?? "未选择")")
        .accessibilityHint("选择分类，可选")
    }

    private var creditCycleMenu: some View {
        Group {
            switch model.creditCyclePhase {
            case .loading: Text("正在加载可用信用账期…").font(V15Typography.secondary)
            case .empty: V15EmptyState(title: "没有可还款账期", explanation: "所选信用账户当前没有可用账期。")
            case .failed(let message): V15ServiceErrorState(message: message, retry: { Task { await model.retryCreditCycles() } })
            default:
                Menu {
                    Button("请选择") { model.creditCycleID = nil }
                    ForEach(model.creditCycles) { cycle in Button(cycleLabel(cycle)) { model.creditCycleID = cycle.id } }
                } label: {
                    V15RecordSelectionPill(label: selectedCreditCycleLabel ?? "信用账期", symbol: "calendar", selected: model.creditCycleID != nil)
                }
                .accessibilityIdentifier("v15.f1a.record.credit-cycle")
                .accessibilityLabel("信用账期：\(selectedCreditCycleLabel ?? "未选择")")
                .accessibilityValue(selectedCreditCycleLabel ?? "未选择")
                .accessibilityHint("选择可还款账期")
                V15FieldIssues(issues: issues("credit_cycle_id"))
            }
        }
    }

    private var iOSSecondaryControls: some View {
        VStack(alignment: .leading, spacing: V15Spacing.sm) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: V15Spacing.md) {
                    businessDateField
                    Spacer(minLength: V15Spacing.sm)
                    noteToggle
                }
                VStack(alignment: .leading, spacing: V15Spacing.sm) {
                    businessDateField
                    noteToggle.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            if showsNote {
                V15Field("备注", text: $model.note, prompt: "可选")
                    .accessibilityIdentifier("v15.f1a.record.note")
            }
        }
    }
    private var noteToggle: some View {
        Button { showsNote.toggle() } label: {
            Label(showsNote ? "收起备注" : (model.note.isEmpty ? "备注" : "备注 · 已填写"), systemImage: "text.alignleft")
                .font(V15Typography.secondary.weight(.medium))
        }
        .buttonStyle(.plain)
        .v15PlatformHitArea()
        .accessibilityValue(showsNote ? "已展开" : "已收起")
        .accessibilityIdentifier("v15.f1a.record.note-toggle")
    }
    private var businessDateField: some View {
        HStack(spacing: V15Spacing.xs) {
            Text("日期").font(V15Typography.secondary.weight(.medium)).foregroundStyle(V15Palette.ink.color.opacity(0.72)).fixedSize()
            DatePicker("", selection: $model.occurredOn, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .environment(\.calendar, shanghaiCalendar)
                .environment(\.timeZone, ShanghaiBusinessDate.timeZone)
                .dynamicTypeSize(...datePickerDynamicTypeSize)
                .accessibilityLabel("业务日期（上海）")
                .accessibilityValue(shanghaiDateAccessibilityValue)
                .accessibilityIdentifier("v15.f1a.record.date")
        }
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
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
        case .queued:
            V15SuccessReceiptState(title: "已加入待同步", detail: "联网后会安全保存，不会重复记账。", actionTitle: "录入下一笔", action: newEntry)
                .accessibilityIdentifier("v15.f1a.record.queued")
        case .success(let transaction):
            V15SuccessReceiptState(title: "账目已保存", detail: "已生成 \(transaction.postings.count) 条分录", actionTitle: "录入下一笔", action: newEntry)
                .accessibilityIdentifier("v15.f1a.record.success")
        case .conflict(let conflict): V15ConflictState(conflict: conflict, reload: { Task { await model.reloadAfterConflict() } })
        case .failed(let failure):
            if V15StateVisualSpec.resolve(failure).semantic == .outcomeUnknown {
                V15OutcomeUnknownState(message: failure.message, actionTitle: "安全检查保存结果", action: submit)
            } else {
                V15ServiceErrorState(message: failure.message, retry: submit)
            }
        default: EmptyView()
        }
    }
    @ViewBuilder private var repaymentPreviewState: some View {
        if model.kind == .repayment {
            switch model.repaymentPreviewPhase {
            case .idle: EmptyView()
            case .loading: V15LoadingSkeleton(layout: .decisionCard)
            case .failed(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.previewRepayment() } }
            case .ready(let preview):
                V15PreviewState {
                    VStack(alignment: .leading, spacing: V15Spacing.xs) {
                        Text("请确认这次还款的实际影响").font(V15Typography.body.weight(.semibold))
                        Text("付款账户：\(preview.paymentAccountName) · \(money(preview.paymentBalanceBeforeMinor)) → \(money(preview.paymentBalanceAfterMinor))")
                        Text("信用账户：\(preview.creditAccountName) · 欠款 \(money(preview.creditDebtBeforeMinor)) → \(money(preview.creditDebtAfterMinor))")
                        Text("所选账期待还：\(money(preview.cycleRemainingBeforeMinor)) → \(money(preview.cycleRemainingAfterMinor))")
                    }.font(V15Typography.secondary)
                }
            }
        }
    }
    private var repaymentPreviewIsReady: Bool { if case .ready = model.repaymentPreviewPhase { true } else { false } }
    private func money(_ value: Int64) -> String { V15MoneyPresentation(minorUnits: value, direction: .neutral).text }
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
            V15PickerRow("信用账期", selection: $model.creditCycleID) {
                Text("请选择").tag(Optional<UUID>.none)
                ForEach(model.creditCycles) { cycle in Text(cycleLabel(cycle)).tag(Optional(cycle.id)) }
            }
            .accessibilityIdentifier("v15.f1a.record.credit-cycle")
            .accessibilityValue(model.creditCycleID.flatMap { selectedID in model.creditCycles.first(where: { $0.id == selectedID }).map(cycleLabel) } ?? "未选择信用账期")
            V15FieldIssues(issues: issues("credit_cycle_id"))
        }
    }
    private func cycleLabel(_ cycle: V15CreditCycle) -> String { "\(cycle.periodStart) 至 \(cycle.periodEnd) · 还款日 \(cycle.dueDate)" }
    private var selectedAccountName: String? { model.accounts.first(where: { $0.id == model.accountID })?.name }
    private var selectedDestinationAccountName: String? { model.accounts.first(where: { $0.id == model.destinationAccountID })?.name }
    private var selectedCategoryName: String? { model.categories.first(where: { $0.id == model.categoryID })?.name }
    private var selectedCreditCycleLabel: String? { model.creditCycleID.flatMap { selectedID in model.creditCycles.first(where: { $0.id == selectedID }).map(cycleLabel) } }
    private func kindSymbol(_ kind: V15ManualTransactionKind) -> String {
        switch kind {
        case .expense: "arrow.up.right"
        case .income: "arrow.down.left"
        case .transfer: "arrow.left.arrow.right"
        case .creditPurchase: "creditcard"
        case .repayment: "arrow.uturn.backward.circle"
        }
    }
    private var datePickerDynamicTypeSize: DynamicTypeSize { dynamicTypeSize.isAccessibilitySize ? .accessibility1 : dynamicTypeSize }
    private var shanghaiDateAccessibilityValue: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = shanghaiCalendar
        formatter.timeZone = ShanghaiBusinessDate.timeZone
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: model.occurredOn)
    }
    private func issues(_ path: String) -> [V15FieldIssue] {
        guard !isCompletedDraft else { return [] }
        let remote = model.fieldIssues.filter { $0.fieldPath == path }
        let local = model.localIssues.filter { $0.fieldPath == path }
        if path == "title", model.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return remote }
        if path == "amount_minor", model.amountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return remote }
        return local + remote
    }
    private var disabledReasons: [V15DisabledReason] {
        var reasons = isCompletedDraft ? [] : model.localIssues.map { V15DisabledReason(code: $0.code, message: $0.message, fieldPath: $0.fieldPath) }
        if case .loading = model.accountPhase { reasons.append(.init(code: "accounts_loading", message: "账户仍在加载。", fieldPath: "account_id")) }
        switch model.submission {
        case .submitting: reasons.append(.init(code: "submitting", message: "正在提交账目。", fieldPath: nil))
        case .success: reasons.append(.init(code: "draft_completed", message: "上一笔已保存，请填写新的账目。", fieldPath: nil))
        case .queued: reasons.append(.init(code: "draft_queued", message: "上一笔已加入待同步，请填写新的账目。", fieldPath: nil))
        case .conflict: reasons.append(.init(code: "conflict_reload_required", message: "请先取得最新数据再决定。", fieldPath: nil))
        case .idle, .failed: break
        }
        return reasons
    }
    private var hasStartedEntry: Bool {
        !model.amountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !model.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        model.accountID != nil || model.destinationAccountID != nil || model.categoryID != nil || model.creditCycleID != nil
    }
    private var displayedDisabledReasons: [V15DisabledReason] { hasStartedEntry ? disabledReasons : disabledReasons.filter { $0.fieldPath == nil } }
    private var neutralUnavailableHint: String? {
        guard !disabledReasons.isEmpty, displayedDisabledReasons.isEmpty else { return nil }
        return model.kind == .repayment ? "填写金额、名称、账户和信用账期后，可先查看还款影响。" : "填写金额、名称和账户后可保存账目。"
    }
    private var isCompletedDraft: Bool {
        switch model.submission {
        case .success, .queued: true
        case .idle, .submitting, .conflict, .failed: false
        }
    }
    private func submit() {
        Task {
            if let outcome = await model.submit() {
                showsNote = false
                onCommitted(outcome)
            }
        }
    }
    private func newEntry() {
        showsNote = false
        model.newEntry()
    }
    private var shanghaiCalendar: Calendar { var calendar = Calendar(identifier: .gregorian); calendar.locale = Locale(identifier: "zh_CN"); calendar.timeZone = ShanghaiBusinessDate.timeZone; return calendar }
}

private struct V15RecordSelectionPill: View {
    let label: String
    let symbol: String
    let selected: Bool

    var body: some View {
        Label(label, systemImage: symbol)
            .font(V15Typography.secondary.weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(selected ? V15Palette.teal.color : V15Palette.ink.color.opacity(0.74))
            .padding(.horizontal, V15Spacing.sm)
            .padding(.vertical, V15Spacing.xs)
            .background(selected ? V15Palette.selected.color : V15Palette.surfaceRaised.color, in: Capsule())
            .overlay { Capsule().stroke(selected ? V15Palette.teal.color.opacity(0.22) : V15Palette.hairline.color, lineWidth: 1) }
            .v15PlatformHitArea()
    }
}
