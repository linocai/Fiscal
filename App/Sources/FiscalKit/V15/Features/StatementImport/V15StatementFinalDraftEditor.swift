import Foundation
import SwiftUI

/// A draft editor only. Saving never posts to the ledger.
struct V15StatementFinalDraftEditor: View {
    let model: V15StatementImportModel
    let row: V15StatementWorkbenchRow
    @Environment(\.dismiss) private var dismiss
    @State private var accounts: [V15AccountResponse] = []
    @State private var categories: [V15CategoryResponse] = []
    @State private var kind: V15ManualTransactionKind = .expense
    @State private var accountID: UUID?
    @State private var destinationID: UUID?
    @State private var categoryID: UUID?
    @State private var amount = ""
    @State private var title = ""
    @State private var date = Date()
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    @State private var version = 0
    @State private var loadedRowVersion: Int?
    @State private var loadedBatchVersion: Int?
    private var sources: [V15AccountResponse] { accounts.filter { kind == .creditPurchase ? $0.kind == .credit : $0.kind == .cash || $0.kind == .debit } }
    private var destinations: [V15AccountResponse] { accounts.filter { $0.id != accountID && (kind == .repayment ? $0.kind == .credit : $0.kind == .cash || $0.kind == .debit) } }
    private var needsDestination: Bool { kind == .transfer || kind == .repayment }
    private var needsCategory: Bool { kind == .expense || kind == .income || kind == .creditPurchase }
    private var availableCategories: [V15CategoryResponse] { categories.filter { $0.direction == (kind == .income ? "income" : "expense") && $0.children.isEmpty && !$0.isBalanceAdjustment } }
    private var valid: Bool {
        guard let value = CNYAmountParser.minorUnits(amount), value > 0,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sources.contains(where: { $0.id == accountID }) else { return false }
        return (!needsDestination || destinations.contains(where: { $0.id == destinationID }))
            && (!needsCategory || availableCategories.contains(where: { $0.id == categoryID }))
    }
    var body: some View {
        NavigationStack {
            Form {
                Text(row.evidenceTextMasked ?? "原始证据不可用")
                Picker("类型", selection: Binding(get: { kind }, set: { kind = $0; accountID = nil; destinationID = nil; categoryID = nil })) { ForEach(V15ManualTransactionKind.allCases) { Text($0.displayName).tag($0) } }
                TextField("标题", text: $title)
                TextField("金额（元）", text: $amount)
                DatePicker("交易日期", selection: $date, displayedComponents: .date)
                Picker("账户", selection: $accountID) {
                    Text("请选择").tag(UUID?.none)
                    ForEach(sources) { Text($0.name).tag(Optional($0.id)) }
                }
                if needsDestination {
                    Picker("目标账户", selection: $destinationID) {
                        Text("请选择").tag(UUID?.none)
                        ForEach(destinations) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                if needsCategory {
                    Picker("分类", selection: $categoryID) {
                        Text("请选择").tag(UUID?.none)
                        ForEach(availableCategories) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("v221.statement.final-draft-error") }
                Text("保存仅更新此行草稿；返回复核后仍须预览并确认入账。")
                Button(saving ? "正在保存…" : "保存草稿") { Task { await save() } }
                    .disabled(loading || saving || !valid)
            }
            .environment(\.timeZone, TimeZone(identifier: "Asia/Shanghai")!)
            .navigationTitle("新建交易草稿")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(saving) } }
            .task { await load() }
            .onChange(of: accountID) { _, _ in if accountID == destinationID { destinationID = nil } }
            .onDisappear { model.finalDraftEditorDismissed() }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }
    private func load() async {
        do {
            let context = try await model.finalDraftContext(row: row)
            guard !Task.isCancelled else { return }
            accounts = context.accounts
            categories = context.categories.flatMap { $0.children.isEmpty ? [$0] : $0.children }
            loadedRowVersion = row.rowVersion; loadedBatchVersion = model.batch?.version
            if let draft = context.draft {
                version = draft.version; kind = draft.transaction.kind
                title = draft.transaction.title; date = draft.transaction.occurredAt
                amount = "\(draft.transaction.amountMinor / 100).\(String(format: "%02lld", draft.transaction.amountMinor % 100))"
                accountID = draft.transaction.accountID; destinationID = draft.transaction.destinationAccountID; categoryID = draft.transaction.categoryID
            } else {
                title = "账单交易"
                if let candidate = row.candidates.first(where: { $0.candidateKind == "provider_candidate" }) {
                    if let minor = candidate.amountMinor, minor > 0 { amount = "\(minor / 100).\(String(format: "%02lld", minor % 100))" }
                    if let day = candidate.transactionDate {
                        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
                        if let parsed = formatter.date(from: day) { date = parsed }
                    }
                }
            }
        } catch { self.error = "草稿或账户资料读取失败，请关闭后重试。" }
        loading = false
    }
    private func save() async {
        guard valid, let minor = CNYAmountParser.minorUnits(amount), let batchVersion = loadedBatchVersion, let rowVersion = loadedRowVersion else { return }
        saving = true; error = nil
        do {
            let request = V15TransactionCreateRequest(kind: kind, amountMinor: minor, occurredAt: date, title: title.trimmingCharacters(in: .whitespacesAndNewlines), accountID: accountID, categoryID: needsCategory ? categoryID : nil, destinationAccountID: needsDestination ? destinationID : nil)
            try await model.saveFinalDraft(row: row, request: .init(expectedVersion: version, transaction: request, expectedBatchVersion: batchVersion, expectedRowVersion: rowVersion))
            dismiss()
        } catch let failure as V15Failure { error = failure.message }
        catch { self.error = "草稿保存结果未知，请关闭后重新读取该行；不要重复保存。" }
        saving = false
    }
}


/// A provider candidate is evidence, not an existing ledger transaction.
struct V15StatementMatchChooser: View {
    let model: V15StatementImportModel
    let row: V15StatementWorkbenchRow
    var body: some View {
        let candidates = model.existingMatchCandidates(for: row)
        if candidates.count > 1 {
            Picker("选择具体交易", selection: Binding(get: { model.selectedMatchTransactionID(for: row) }, set: { model.selectMatchTransaction($0, for: row) })) {
                Text("请选择匹配目标").tag(UUID?.none)
                ForEach(candidates) { candidate in
                    if let id = candidate.transactionID {
                        Text("\(candidate.transactionDate ?? "日期未知") · 交易 \(id.uuidString)").tag(Optional(id))
                    }
                }
            }
            .disabled(row.isConfirmed || !model.writeReasons.isEmpty)
            .accessibilityIdentifier("v221.statement.match-choice.\(row.id)")
        }
    }
}
