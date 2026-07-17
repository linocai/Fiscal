import SwiftUI

public struct IOSOverviewScreen: View {
    let fixture: OverviewFixture
    let connectionPhase: ConnectionModel.Phase

    public init(fixture: OverviewFixture = .normal, connectionPhase: ConnectionModel.Phase = .idle) {
        self.fixture = fixture
        self.connectionPhase = connectionPhase
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 13) {
                header
                if fixture == .loading {
                    loading
                } else if showsConnectionNotice {
                    connectionNotice
                    content(fixture.snapshot)
                } else {
                    content(fixture.snapshot)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 16)
        }
        .background(FiscalColor.iOSBackground.ignoresSafeArea())
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 9) {
                    Text(fixture.snapshot.period).font(.caption.weight(.semibold)).foregroundStyle(FiscalColor.tertiary)
                    ConnectionBadge(phase: connectionPhase)
                }
                Text("总览").font(.system(size: 32, weight: .bold)).tracking(-0.8).foregroundStyle(FiscalColor.text)
            }
            Spacer()
            Button(action: {}) {
                Image(systemName: "sparkles").font(.system(size: 17, weight: .semibold)).foregroundStyle(FiscalColor.accent)
                    .frame(width: 42, height: 42).background(.regularMaterial, in: .circle)
                    .overlay(alignment: .topTrailing) { Text("1").font(.caption2.bold()).foregroundStyle(.white).frame(width: 17, height: 17).background(FiscalColor.expense, in: .circle) }
            }
            .accessibilityLabel("AI 待确认，1 笔")
        }
    }

    @ViewBuilder private func content(_ snapshot: OverviewSnapshot) -> some View {
        SpendCard(snapshot: snapshot)
        accountCard(snapshot)
        cashFlowCard(snapshot)
        if snapshot.uncategorizedCount > 0 { uncategorized(snapshot.uncategorizedCount) }
        recentCard(snapshot)
    }

    private func accountCard(_ snapshot: OverviewSnapshot) -> some View {
        FiscalCard(radius: 22) {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("可用余额").font(.subheadline.weight(.semibold)).foregroundStyle(FiscalColor.secondary); Spacer(); Text("账户").font(.subheadline.weight(.semibold)).foregroundStyle(FiscalColor.accent) }
                Text(snapshot.available.formatted()).font(.system(size: 33, weight: .bold)).foregroundStyle(FiscalColor.text)
                Text("净资产 \(snapshot.netWorth.formatted())").font(.caption).foregroundStyle(FiscalColor.secondary)
                Divider().opacity(0.35)
                if snapshot.accounts.isEmpty { EmptyInline(symbol: "wallet.bifold", title: "还没有账户") }
                ForEach(Array(snapshot.accounts.enumerated()), id: \.element.id) { index, account in
                    if index > 0 { Divider().padding(.leading, 47).opacity(0.35) }
                    AccountRow(account: account)
                }
            }
        }
    }

    private func cashFlowCard(_ snapshot: OverviewSnapshot) -> some View {
        FiscalCard(radius: 22) {
            HStack(spacing: 12) {
                FiscalIconTile("arrow.up.arrow.down", color: FiscalColor.reimbursement)
                VStack(alignment: .leading, spacing: 4) {
                    Text("本月现金流").font(.subheadline.weight(.semibold)).foregroundStyle(FiscalColor.text)
                    Text("流入 \(snapshot.cashIn.formatted()) · 流出 \(snapshot.cashOut.formatted())").font(.caption).foregroundStyle(FiscalColor.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(snapshot.cashNet.formatted(showPositiveSign: snapshot.cashNet.minorUnits > 0)).font(.subheadline.bold()).foregroundStyle(snapshot.cashNet.minorUnits >= 0 ? FiscalColor.income : FiscalColor.expense)
            }
        }
    }

    private func uncategorized(_ count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark.circle.fill").foregroundStyle(FiscalColor.debt).accessibilityHidden(true)
            Text("\(count) 笔待归类 · 未计入消费统计").font(.caption.weight(.semibold)).foregroundStyle(FiscalColor.secondary)
            Spacer(); Text("去处理").font(.caption.weight(.semibold)).foregroundStyle(FiscalColor.debt)
        }
        .padding(14).background(FiscalColor.debt.opacity(0.09), in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(FiscalColor.debt.opacity(0.22), lineWidth: 0.5) }
    }

    private func recentCard(_ snapshot: OverviewSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Text("最近流水").font(.headline); Spacer(); Text("全部").font(.subheadline.weight(.semibold)).foregroundStyle(FiscalColor.accent) }.padding(.horizontal, 3)
            FiscalCard(radius: 22) {
                VStack(spacing: 12) {
                    if snapshot.recent.isEmpty { EmptyInline(symbol: "list.bullet.rectangle", title: "还没有流水") }
                    ForEach(Array(snapshot.recent.prefix(5).enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().padding(.leading, 47).opacity(0.35) }
                        ActivityRow(activity: item)
                    }
                }
            }
        }
    }

    private var loading: some View {
        VStack(spacing: 13) { ForEach(0..<3, id: \.self) { _ in RoundedRectangle(cornerRadius: 22).fill(FiscalColor.surface.opacity(0.72)).frame(height: 180).redacted(reason: .placeholder) } }
    }

    private var connectionNotice: some View {
        FiscalCard(radius: 16) {
            HStack(spacing: 12) {
                Image(systemName: isUnauthorized ? "key" : "wifi.slash").foregroundStyle(isUnauthorized ? FiscalColor.debt : FiscalColor.expense).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(isUnauthorized ? "需要设备密钥" : "当前离线").font(.subheadline.weight(.semibold))
                    Text(connectionDetail).font(.caption).foregroundStyle(FiscalColor.secondary)
                }
                Spacer()
            }
        }
    }

    private var isUnauthorized: Bool {
        if fixture == .unauthorized { return true }
        if case .unauthorized = connectionPhase { return true }
        return false
    }

    private var connectionDetail: String {
        if case let .offline(message) = connectionPhase, !message.isEmpty {
            return "\(message) · 下方为预览数据"
        }
        return "下方为预览数据，不会写入正式账本"
    }

    private var showsConnectionNotice: Bool {
        if fixture == .offline || fixture == .unauthorized { return true }
        switch connectionPhase {
        case .offline, .unauthorized: return true
        default: return false
        }
    }
}

#Preview("正常") { IOSOverviewScreen() }
#Preview("空状态") { IOSOverviewScreen(fixture: .empty) }
#Preview("加载") { IOSOverviewScreen(fixture: .loading) }
#Preview("离线") { IOSOverviewScreen(fixture: .offline) }
#Preview("未授权") { IOSOverviewScreen(fixture: .unauthorized) }
#Preview("长内容") { IOSOverviewScreen(fixture: .longContent) }
