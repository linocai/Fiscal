import SwiftUI

public struct MacOverviewScreen: View {
    let fixture: OverviewFixture
    let connectionPhase: ConnectionModel.Phase

    public init(fixture: OverviewFixture = .normal, connectionPhase: ConnectionModel.Phase = .idle) {
        self.fixture = fixture
        self.connectionPhase = connectionPhase
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("总览").font(.system(size: 26, weight: .bold)).tracking(-0.5)
                    Spacer()
                    ConnectionBadge(phase: connectionPhase)
                }
                if fixture == .loading {
                    loading
                } else {
                    if fixture == .offline || fixture == .unauthorized { connectionNotice }
                    summaryGrid
                    HStack(alignment: .top, spacing: 16) {
                        recentCard.frame(maxWidth: .infinity)
                        VStack(spacing: 16) { accountsCard; cashFlowCard }.frame(width: 280)
                    }
                }
            }
            .padding(22)
        }
        .background(FiscalColor.macBackground)
    }

    private var snapshot: OverviewSnapshot { fixture.snapshot }

    private var summaryGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            MetricCard(label: "本月消费", amount: snapshot.spend, detail: "较上月 ↓ 8.2%", color: FiscalColor.text)
            MetricCard(label: "现金流净额", amount: snapshot.cashNet, detail: "本月实际流入与流出", color: FiscalColor.income, positive: true)
            MetricCard(label: "信用应还", amount: snapshot.creditDue, detail: "最近还款日 07-22", color: FiscalColor.debt)
            MetricCard(label: "报销待回款", amount: snapshot.reimbursementDue, detail: "预计 ~07-18", color: FiscalColor.reimbursement)
        }
    }

    private var recentCard: some View {
        FiscalCard(radius: 15) {
            VStack(alignment: .leading, spacing: 13) {
                HStack { Text("最近流水").font(.headline); Spacer(); Text("在「流水」中查看全部").font(.caption.weight(.semibold)).foregroundStyle(FiscalColor.accent) }
                HStack {
                    Text("日期").frame(width: 60, alignment: .leading); Text("摘要"); Spacer(); Text("金额")
                }.font(.caption.weight(.semibold)).foregroundStyle(FiscalColor.tertiary)
                Divider().opacity(0.35)
                if snapshot.recent.isEmpty { EmptyInline(symbol: "list.bullet.rectangle", title: "还没有流水") }
                ForEach(Array(snapshot.recent.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().opacity(0.3) }
                    HStack(spacing: 10) {
                        Text(item.dateLabel).frame(width: 60, alignment: .leading).font(.caption).foregroundStyle(FiscalColor.tertiary)
                        FiscalIconTile(item.symbol, color: item.direction == .income ? FiscalColor.income : FiscalColor.accent)
                        VStack(alignment: .leading, spacing: 2) { Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1); Text(item.detail).font(.caption).foregroundStyle(FiscalColor.tertiary).lineLimit(1) }
                        Spacer()
                        Text(item.amount.formatted(showPositiveSign: item.direction == .income)).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(item.direction == .income ? FiscalColor.income : FiscalColor.text)
                    }
                }
            }
        }
    }

    private var accountsCard: some View {
        FiscalCard(radius: 15) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("账户概览").font(.headline); Spacer(); Text("查看全部").font(.caption.weight(.semibold)).foregroundStyle(FiscalColor.accent) }
                Text(snapshot.available.formatted()).font(.system(size: 25, weight: .bold, design: .rounded)).monospacedDigit()
                Text("可用余额 · 净资产 \(snapshot.netWorth.formatted())").font(.caption).foregroundStyle(FiscalColor.tertiary)
                Divider().opacity(0.35)
                if snapshot.accounts.isEmpty { EmptyInline(symbol: "wallet.bifold", title: "还没有账户") }
                ForEach(Array(snapshot.accounts.prefix(3).enumerated()), id: \.element.id) { index, account in
                    if index > 0 { Divider().padding(.leading, 47).opacity(0.3) }
                    AccountRow(account: account)
                }
            }
        }
    }

    private var cashFlowCard: some View {
        FiscalCard(radius: 15) {
            VStack(alignment: .leading, spacing: 10) {
                HStack { FiscalIconTile("arrow.up.arrow.down", color: FiscalColor.reimbursement); Text("现金流").font(.headline); Spacer(); Text("查看全部").font(.caption.weight(.semibold)).foregroundStyle(FiscalColor.accent) }
                HStack { Text("本月净额").font(.caption).foregroundStyle(FiscalColor.secondary); Spacer(); Text(snapshot.cashNet.formatted(showPositiveSign: true)).font(.subheadline.bold().monospacedDigit()).foregroundStyle(FiscalColor.income) }
                Text("未来账期与计划现金流将在 P7 接入正式账本计算服务。").font(.caption).foregroundStyle(FiscalColor.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var loading: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) { ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: 15).fill(.white.opacity(0.75)).frame(height: 118) } }
            RoundedRectangle(cornerRadius: 15).fill(.white.opacity(0.75)).frame(height: 340)
        }.redacted(reason: .placeholder)
    }

    private var connectionNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: fixture == .unauthorized ? "key" : "wifi.slash")
            Text(fixture == .unauthorized ? "设备密钥尚未配置；当前显示严格隔离的预览数据。" : "无法连接个人 VPS；当前显示严格隔离的预览数据。")
            Spacer()
        }
        .font(.subheadline).foregroundStyle(FiscalColor.secondary).padding(12)
        .background((fixture == .unauthorized ? FiscalColor.debt : FiscalColor.expense).opacity(0.09), in: .rect(cornerRadius: 10))
    }
}

private struct MetricCard: View {
    let label: String
    let amount: Money
    let detail: String
    let color: Color
    var positive = false

    var body: some View {
        FiscalCard(radius: 15) {
            VStack(alignment: .leading, spacing: 8) {
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(FiscalColor.secondary)
                Text(amount.formatted(showPositiveSign: positive && amount.minorUnits > 0)).font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(color).monospacedDigit().lineLimit(1).minimumScaleFactor(0.72)
                Text(detail).font(.caption2).foregroundStyle(FiscalColor.tertiary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview("正常") { MacOverviewScreen().frame(width: 830, height: 650) }
#Preview("空状态") { MacOverviewScreen(fixture: .empty).frame(width: 830, height: 650) }
#Preview("加载") { MacOverviewScreen(fixture: .loading).frame(width: 830, height: 650) }
#Preview("离线") { MacOverviewScreen(fixture: .offline).frame(width: 830, height: 650) }
#Preview("未授权") { MacOverviewScreen(fixture: .unauthorized).frame(width: 830, height: 650) }
#Preview("长内容") { MacOverviewScreen(fixture: .longContent).frame(width: 830, height: 650) }
