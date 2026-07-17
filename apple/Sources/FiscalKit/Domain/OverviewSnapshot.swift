import Foundation

public struct Money: Sendable, Equatable, Codable {
    public let minorUnits: Int64
    public let currency: String

    public init(minorUnits: Int64, currency: String = "CNY") {
        self.minorUnits = minorUnits
        self.currency = currency
    }

    public var decimal: Decimal { Decimal(minorUnits) / 100 }
}
