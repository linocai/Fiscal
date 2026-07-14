import Foundation

public extension Money {
    func formatted(showPositiveSign: Bool = false) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.currencySymbol = "¥"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.positivePrefix = showPositiveSign ? "+¥" : "¥"
        formatter.negativePrefix = "-¥"
        return formatter.string(from: decimal as NSDecimalNumber) ?? "¥0.00"
    }
}
