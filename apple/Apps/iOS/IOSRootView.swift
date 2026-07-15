import FiscalKit
import SwiftUI

private enum IOSTab: Hashable { case overview, transactions, cashFlow, more }
private enum IOSMoreDestination: Hashable { case accounts, categories }

struct IOSRootView: View {
    @Bindable var connection: ConnectionModel
    let accounts: AccountsModel
    let categories: CategoriesModel
    let transactions: TransactionsModel
    @State private var selection: IOSTab = .overview
    @State private var showRecordSheet = false

    var body: some View {
        Group {
            switch selection {
            case .overview: NavigationStack { IOSOverviewScreen(connectionPhase: connection.phase) }
            case .transactions: NavigationStack { IOSTransactionsScreen(model: transactions, accounts: accounts, categories: categories) }
            case .cashFlow: PlaceholderScreen("现金流", symbol: "arrow.up.arrow.down", phase: "P7")
            case .more: IOSMoreScreen(accounts: accounts, categories: categories, connection: connection)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FiscalColor.iOSBackground.ignoresSafeArea())
        .overlay(alignment: .bottom) { tabBar }
        .sheet(isPresented: $showRecordSheet) { TransactionEditorSheet(transactions: transactions, accounts: accounts, categories: categories) }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton("总览", symbol: "house", tab: .overview)
            tabButton("流水", symbol: "list.bullet.rectangle", tab: .transactions)
            Button { showRecordSheet = true } label: {
                Image(systemName: "plus").font(.title3.bold()).foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(LinearGradient(colors: [FiscalColor.accent, FiscalColor.accentDark], startPoint: .top, endPoint: .bottom), in: .rect(cornerRadius: 16))
                    .shadow(color: FiscalColor.accent.opacity(0.4), radius: 9, y: 5)
            }
            .frame(maxWidth: .infinity).accessibilityLabel("记一笔")
            tabButton("现金流", symbol: "arrow.up.arrow.down", tab: .cashFlow)
            tabButton("更多", symbol: "ellipsis", tab: .more)
        }
        .padding(.horizontal, 8).frame(height: 72)
        .glassEffect(.regular, in: .rect(cornerRadius: 31))
        .padding(.horizontal, 12)
        .padding(.bottom, 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fiscal.customBottomBar")
    }

    private func tabButton(_ title: String, symbol: String, tab: IOSTab) -> some View {
        Button { selection = tab } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 20, weight: .medium))
                Text(title).font(.caption2.weight(.medium))
            }
            .foregroundStyle(selection == tab ? FiscalColor.accent : Color(hex: 0x9098A4))
            .frame(maxWidth: .infinity, minHeight: 56)
        }
    }
}

private struct IOSMoreScreen: View {
    let accounts: AccountsModel
    let categories: CategoriesModel
    let connection: ConnectionModel
    @State private var path: [IOSMoreDestination] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 14) {
                    FiscalCard(radius: 20) {
                        VStack(spacing: 0) {
                            NavigationLink(value: IOSMoreDestination.accounts) {
                                row("账户", symbol: "wallet.bifold", detail: "现金 · 储蓄卡 · 信用卡", color: FiscalColor.accent)
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 46)
                            NavigationLink(value: IOSMoreDestination.categories) {
                                row("分类设置", symbol: "tag", detail: "两级 · AI 识别资料", color: FiscalColor.reimbursement)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    FiscalCard(radius: 18) { HStack { ConnectionBadge(phase: connection.phase); Spacer(); Text("个人 VPS · 设备密钥访问").font(.caption).foregroundStyle(FiscalColor.tertiary) } }
                    FiscalCard(radius: 20) { VStack(spacing: 0) { placeholderRow("信用账期与分期", "calendar.badge.clock", "P4–P5"); Divider(); placeholderRow("报销", "doc.text", "P6"); Divider(); placeholderRow("报表", "chart.bar", "P7"); Divider(); placeholderRow("其他设置", "gearshape", "P11") } }
                }.padding(16).padding(.bottom, 100)
            }
            .background(FiscalColor.iOSBackground).navigationTitle("更多")
            .navigationDestination(for: IOSMoreDestination.self) { destination in
                switch destination {
                case .accounts: AccountsManagementScreen(model: accounts)
                case .categories: CategoriesManagementScreen(model: categories)
                }
            }
        }
    }
    private func row(_ title: String, symbol: String, detail: String, color: Color) -> some View {
        HStack(spacing: 12) { FiscalIconTile(symbol, color: color); Text(title).font(.headline); Spacer(); Text(detail).font(.caption).foregroundStyle(FiscalColor.tertiary).lineLimit(1); Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(FiscalColor.tertiary) }
            .frame(minHeight: 56)
            .contentShape(.rect)
    }
    private func placeholderRow(_ title: String, _ symbol: String, _ phase: String) -> some View {
        HStack(spacing: 12) { FiscalIconTile(symbol, color: FiscalColor.tertiary); Text(title); Spacer(); Text(phase).font(.caption).foregroundStyle(FiscalColor.tertiary) }.frame(minHeight: 52)
    }
}
