import SwiftUI

public struct PlaceholderScreen: View {
    let title: String
    let symbol: String
    let phase: String

    public init(_ title: String, symbol: String, phase: String) {
        self.title = title
        self.symbol = symbol
        self.phase = phase
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text("此模块将在 \(phase) 按统一账本口径接入。P1 不会用样例交互冒充正式业务。")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FiscalColor.macBackground)
    }
}
