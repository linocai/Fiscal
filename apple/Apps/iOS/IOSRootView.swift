import FiscalKit
import SwiftUI

private enum IOSTab: Hashable { case overview, transactions, cashFlow, more }

struct IOSRootView: View {
    @Bindable var connection: ConnectionModel
    @State private var selection: IOSTab = .overview
    @State private var showP1Notice = false

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { IOSOverviewScreen(connectionPhase: connection.phase) }.tag(IOSTab.overview)
            PlaceholderScreen("流水", symbol: "list.bullet.rectangle", phase: "P3").tag(IOSTab.transactions)
            PlaceholderScreen("现金流", symbol: "arrow.up.arrow.down", phase: "P7").tag(IOSTab.cashFlow)
            PlaceholderScreen("更多", symbol: "ellipsis", phase: "P4–P9").tag(IOSTab.more)
        }
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
        .alert("P1 工程地基", isPresented: $showP1Notice) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("正式记账将在 P3 接入统一业务服务。本阶段不会写入样例账本。")
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton("总览", symbol: "house", tab: .overview)
            tabButton("流水", symbol: "list.bullet.rectangle", tab: .transactions)
            Button { showP1Notice = true } label: {
                Image(systemName: "plus").font(.title3.bold()).foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(LinearGradient(colors: [FiscalColor.accent, FiscalColor.accentDark], startPoint: .top, endPoint: .bottom), in: .rect(cornerRadius: 16))
                    .shadow(color: FiscalColor.accent.opacity(0.4), radius: 9, y: 5)
            }
            .frame(maxWidth: .infinity).accessibilityLabel("记一笔，P3 开放")
            tabButton("现金流", symbol: "arrow.up.arrow.down", tab: .cashFlow)
            tabButton("更多", symbol: "ellipsis", tab: .more)
        }
        .padding(.horizontal, 8).frame(height: 72)
        .background(.regularMaterial, in: .rect(cornerRadius: 31))
        .overlay { RoundedRectangle(cornerRadius: 31).stroke(.white.opacity(0.8), lineWidth: 0.5) }
        .shadow(color: Color.black.opacity(0.16), radius: 22, y: 9)
        .padding(.horizontal, 12).padding(.bottom, 5)
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
