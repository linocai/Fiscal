import SwiftUI

struct SpendCard: View {
    let snapshot: OverviewSnapshot
    var compact = false

    var body: some View {
        FiscalCard(radius: compact ? 15 : 22) {
            VStack(alignment: .leading, spacing: compact ? 10 : 17) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("本月消费").font(.subheadline.weight(.semibold)).foregroundStyle(FiscalColor.secondary)
                        if !compact { Text("7月1日–14日 · 消费口径").font(.caption).foregroundStyle(FiscalColor.tertiary) }
                    }
                    Spacer()
                    Text("较上月 ↓ 8.2%")
                        .font(.caption.weight(.semibold)).foregroundStyle(FiscalColor.income)
                }
                Text(snapshot.spend.formatted())
                    .font(.system(size: compact ? 26 : 36, weight: .bold, design: .rounded))
                    .foregroundStyle(FiscalColor.text).fiscalMonospacedNumbers()
                if !compact {
                    if snapshot.categories.isEmpty {
                        EmptyInline(symbol: "chart.bar", title: "本月还没有消费记录")
                    } else {
                        VStack(spacing: 11) {
                            ForEach(snapshot.categories) { item in
                                CategoryBar(item: item, maximum: snapshot.categories.map(\.amount.minorUnits).max() ?? 1)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct CategoryBar: View {
    let item: CategorySpend
    let maximum: Int64

    var body: some View {
        HStack(spacing: 10) {
            Text(item.name).font(.caption).foregroundStyle(FiscalColor.secondary).frame(width: 38, alignment: .leading)
            GeometryReader { proxy in
                Capsule().fill(Color.black.opacity(0.045))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color(hex: item.colorHex)).frame(width: max(5, proxy.size.width * CGFloat(item.amount.minorUnits) / CGFloat(maximum)))
                    }
            }
            .frame(height: 7)
            Text(item.amount.formatted()).font(.caption.monospacedDigit()).foregroundStyle(FiscalColor.secondary).frame(width: 82, alignment: .trailing)
        }
    }
}

struct AccountRow: View {
    let account: AccountSummary

    var body: some View {
        HStack(spacing: 11) {
            FiscalIconTile(account.symbol, color: account.kind == .credit ? FiscalColor.debt : FiscalColor.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(account.name).font(.subheadline.weight(.semibold)).foregroundStyle(FiscalColor.text).lineLimit(1)
                Text(account.detail).font(.caption).foregroundStyle(FiscalColor.tertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(account.amount.formatted())
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(account.kind == .credit ? FiscalColor.debt : FiscalColor.text)
        }
    }
}

struct ActivityRow: View {
    let activity: RecentActivity
    var showDate = false

    var body: some View {
        HStack(spacing: 11) {
            FiscalIconTile(activity.symbol, color: activity.direction == .income ? FiscalColor.income : FiscalColor.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(activity.title).font(.subheadline.weight(.semibold)).foregroundStyle(FiscalColor.text).lineLimit(1)
                HStack(spacing: 5) {
                    if showDate { Text(activity.dateLabel) }
                    Text(activity.detail).lineLimit(1)
                    if let tag = activity.tag {
                        Text(tag).font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(FiscalColor.accent.opacity(0.1), in: .rect(cornerRadius: 4))
                    }
                }
                .font(.caption).foregroundStyle(FiscalColor.tertiary)
            }
            Spacer(minLength: 8)
            Text(activity.amount.formatted(showPositiveSign: activity.direction == .income))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(activity.direction == .income ? FiscalColor.income : FiscalColor.text)
        }
    }
}

struct EmptyInline: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(FiscalColor.tertiary)
            Text(title).font(.subheadline).foregroundStyle(FiscalColor.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

public struct ConnectionBadge: View {
    let phase: ConnectionModel.Phase

    public init(phase: ConnectionModel.Phase) { self.phase = phase }

    public var body: some View {
        HStack(spacing: 6) {
            switch phase {
            case .idle:
                Circle().fill(FiscalColor.tertiary).frame(width: 7, height: 7); Text("未检查")
            case .loading:
                ProgressView().controlSize(.mini); Text("连接中")
            case .connected:
                Circle().fill(FiscalColor.income).frame(width: 7, height: 7); Text("已连接")
            case .unauthorized:
                Circle().fill(FiscalColor.debt).frame(width: 7, height: 7); Text("需要设备密钥")
            case .offline:
                Circle().fill(FiscalColor.expense).frame(width: 7, height: 7); Text("离线")
            }
        }
        .font(.caption.weight(.medium)).foregroundStyle(FiscalColor.secondary)
    }
}
