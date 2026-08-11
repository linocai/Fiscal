import SwiftUI

public struct ReconciliationCenterScreen: View {
    public let model: ReconciliationModel
    public let accounts: AccountsModel
    private let openAttention: (AttentionItemDTO) -> Void
    @State private var selectedAccountID: UUID?
    @State private var actual = ""
    @State private var note = ""

    public init(
        model: ReconciliationModel,
        accounts: AccountsModel,
        openAttention: @escaping (AttentionItemDTO) -> Void = { _ in }
    ) {
        self.model = model
        self.accounts = accounts
        self.openAttention = openAttention
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FiscalCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("快速核对", systemImage: "checkmark.circle")
                            .font(.headline)
                        Picker("账户", selection: $selectedAccountID) {
                            Text("选择账户").tag(UUID?.none)
                            ForEach(activeAccounts) { account in
                                Text(account.name).tag(Optional(account.id))
                            }
                        }
                        TextField("实际余额（元）", text: $actual)
#if os(iOS)
                            .keyboardType(.decimalPad)
#endif
                        TextField("备注（可选）", text: $note)
                        if let message = model.message {
                            Text(message).font(.caption).foregroundStyle(FiscalColor.expense)
                        }
                        Button(model.isSaving ? "正在保存…" : "保存核对点") { save() }
                            .buttonStyle(FiscalActionButtonStyle())
                            .disabled(model.isSaving || selectedAccountID == nil)
                    }
                }
                if let latest = model.checkpoints.first {
                    FiscalCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(latest.state == .reconciled ? "已核对" : "存在差额")
                                .font(.headline)
                                .foregroundStyle(latest.state == .reconciled ? FiscalColor.income : FiscalColor.expense)
                            amountRow("账面余额", latest.bookBalanceMinor)
                            amountRow("实际余额", latest.actualBalanceMinor)
                            amountRow("差额", latest.differenceMinor)
                            Text("账面额由服务器按核对时点重算；本记录不会修改任何流水或余额。")
                                .font(.caption).foregroundStyle(FiscalColor.tertiary)
                        }
                    }
                }
                if let diagnosis = model.diagnosis {
                    FiscalCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("差额分析").font(.headline)
                            Text("当前服务端账面额 \(Money(minorUnits: diagnosis.bookBalanceMinor).formatted())")
                            if diagnosis.entries.isEmpty {
                                Text("所选区间没有影响余额的正式流水。")
                                    .font(.caption).foregroundStyle(FiscalColor.tertiary)
                            } else {
                                ForEach(diagnosis.entries.prefix(10)) { entry in
                                    HStack {
                                        Text(entry.title).lineLimit(1)
                                        Spacer()
                                        Text(Money(minorUnits: entry.accountImpactMinor).formatted())
                                            .foregroundStyle(entry.accountImpactMinor < 0 ? FiscalColor.expense : FiscalColor.income)
                                    }.font(.caption)
                                }
                            }
                        }
                    }
                }
                if !model.attention.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("关注事项").font(.headline)
                        ForEach(model.attention) { item in
                            FiscalCard(radius: 14) {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: item.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                                        .foregroundStyle(item.severity == .warning ? FiscalColor.expense : FiscalColor.accent)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.explanation).font(.subheadline.weight(.semibold))
                                        Text(item.suggestedAction).font(.caption).foregroundStyle(FiscalColor.secondary)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 4) {
                                        Button("处理") { openAttention(item) }
                                        Button("忽略") { Task { await model.ignore(item) } }
                                    }
                                    .font(.caption)
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(FiscalColor.iOSBackground)
        .navigationTitle("核对与关注")
        .task {
            // This screen is reachable directly from a deep link, before an
            // account-management screen has had a chance to populate the shared
            // model. Load the server-owned account choices before choosing the
            // default reconciliation target.
            if accounts.accounts.isEmpty { await accounts.load() }
            if selectedAccountID == nil { selectedAccountID = activeAccounts.first?.id }
            if let selectedAccountID { await model.load(accountID: selectedAccountID) }
        }
        .onChange(of: selectedAccountID) { _, id in
            guard let id else { return }
            Task { await model.load(accountID: id) }
        }
    }

    private var activeAccounts: [AccountDTO] { accounts.accounts.filter { $0.archivedAt == nil } }

    private func amountRow(_ title: String, _ value: Int64) -> some View {
        HStack { Text(title).foregroundStyle(FiscalColor.secondary); Spacer(); Text(Money(minorUnits: value).formatted()) }
    }

    private func save() {
        guard let accountID = selectedAccountID,
              let amount = CNYAmountParser.minorUnits(actual) else {
            return
        }
        Task {
            if await model.create(accountID: accountID, actualMinor: amount, note: note) {
                actual = ""; note = ""
            }
        }
    }
}
