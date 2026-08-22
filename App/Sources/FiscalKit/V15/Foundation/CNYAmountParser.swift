import Foundation

/// The one CNY text boundary shared by the legacy app and the V15 clean room.
/// Values crossing an API boundary are always `Int64` minor units.
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

public enum ShanghaiBusinessDate {
    public static let timeZone = TimeZone(identifier: "Asia/Shanghai")!
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = timeZone
        return calendar
    }()

    /// Converts an instant to the API's local business day. This must not be
    /// replaced with a device-local calendar in V15 features or exports.
    public static func date(for instant: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day], from: instant)
    }

    public static func string(for instant: Date) -> String {
        let values = date(for: instant)
        return String(format: "%04d-%02d-%02d", values.year ?? 0, values.month ?? 0, values.day ?? 0)
    }

    public static func isSameMonth(_ lhs: Date, _ rhs: Date) -> Bool {
        let l = date(for: lhs); let r = date(for: rhs)
        return l.year == r.year && l.month == r.month
    }
}
