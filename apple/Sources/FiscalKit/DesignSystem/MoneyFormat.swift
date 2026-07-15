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

public enum CNYAmountParser {
    public static func minorUnits(_ text: String) -> Int64? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: "^-?[0-9]+(?:\\.[0-9]{0,2})?$", options: .regularExpression) != nil,
              let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let scaled = decimal * 100
        guard scaled >= Decimal(Int64.min), scaled <= Decimal(Int64.max) else { return nil }
        return NSDecimalNumber(decimal: scaled).int64Value
    }
}
