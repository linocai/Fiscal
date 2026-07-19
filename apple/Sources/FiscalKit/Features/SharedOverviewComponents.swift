import SwiftUI

struct EmptyInline: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(FiscalColor.tertiary).accessibilityHidden(true)
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
                Circle().fill(FiscalColor.debt).frame(width: 7, height: 7); Text("需要访问口令")
            case .offline:
                Circle().fill(FiscalColor.expense).frame(width: 7, height: 7); Text("离线")
            }
        }
        .font(.caption.weight(.medium)).foregroundStyle(FiscalColor.secondary)
    }
}
