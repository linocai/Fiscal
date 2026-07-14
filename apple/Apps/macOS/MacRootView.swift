import FiscalKit
import SwiftUI

private enum MacSection: String, CaseIterable, Identifiable {
    case overview = "总览", transactions = "流水", accounts = "账户", cashFlow = "现金流"
    case reimbursement = "报销", reports = "报表", ai = "AI 待确认", settings = "设置"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .overview: "house"
        case .transactions: "list.bullet.rectangle"
        case .accounts: "wallet.bifold"
        case .cashFlow: "arrow.up.arrow.down"
        case .reimbursement: "doc.text"
        case .reports: "chart.bar"
        case .ai: "sparkles"
        case .settings: "gearshape"
        }
    }
    var phase: String {
        switch self {
        case .overview: "P1"
        case .transactions: "P3"
        case .accounts: "P4"
        case .cashFlow, .reports: "P7"
        case .reimbursement: "P6"
        case .ai: "P8–P9"
        case .settings: "P2–P11"
        }
    }
}

struct MacRootView: View {
    @Bindable var connection: ConnectionModel
    @State private var section: MacSection = .overview

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.45)
            Group {
                if section == .overview {
                    MacOverviewScreen(connectionPhase: connection.phase)
                } else {
                    PlaceholderScreen(section.rawValue, symbol: section.symbol, phase: section.phase)
                }
            }
        }
        .background(FiscalColor.macBackground)
    }

    private var sidebar: some View {
        VStack(spacing: 7) {
            Spacer().frame(height: 42)
            ForEach(MacSection.allCases) { item in
                Button { section = item } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.symbol).font(.system(size: 18, weight: .semibold))
                            .frame(width: 42, height: 34)
                            .background(section == item ? AnyShapeStyle(LinearGradient(colors: [FiscalColor.accent, FiscalColor.accentDark], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color.clear), in: .rect(cornerRadius: 10))
                            .foregroundStyle(section == item ? .white : Color(hex: 0x6B7484))
                        Text(item.rawValue).font(.system(size: 10, weight: .medium)).foregroundStyle(section == item ? FiscalColor.accent : FiscalColor.secondary).lineLimit(1)
                    }
                    .frame(width: 94, height: 53)
                    .overlay(alignment: .topTrailing) {
                        if item == .ai { Text("1").font(.caption2.bold()).foregroundStyle(.white).frame(width: 16, height: 16).background(FiscalColor.expense, in: .circle).offset(x: -16, y: 1) }
                    }
                }.buttonStyle(.plain)
            }
            Spacer()
        }
        .frame(width: 110)
        .background(.regularMaterial)
    }
}
