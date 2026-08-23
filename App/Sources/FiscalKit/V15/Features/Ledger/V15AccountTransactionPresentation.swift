import Foundation

public struct V15AccountTransactionPresentation: Sendable, Equatable {
    public let accountPath: String
    public let accountEffect: String?
    public let amountMinor: V15MinorUnits
    public let direction: V15MoneyDirection
    public let isAccountScoped: Bool
    public let hasAuthoritativePosting: Bool
}

public enum V15AccountTransactionPresenter {
    public static func present(
        _ transaction: V15Transaction,
        scopedAccountID: UUID?,
        accounts: [V15AccountResponse]
    ) -> V15AccountTransactionPresentation {
        let names = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) })
        let accountKinds = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.kind) })
        let sourceName = accountName(transaction.accountID, names: names)
        let path: String
        if let destinationID = transaction.destinationAccountID {
            path = "\(sourceName) → \(accountName(destinationID, names: names))"
        } else {
            path = sourceName
        }

        guard let scopedAccountID else {
            return .init(
                accountPath: path,
                accountEffect: nil,
                amountMinor: transaction.amountMinor,
                direction: transactionDirection(transaction),
                isAccountScoped: false,
                hasAuthoritativePosting: false
            )
        }

        guard let posting = transaction.postings.first(where: { $0.accountID == scopedAccountID }) else {
            return .init(
                accountPath: path,
                accountEffect: "当前账户影响待确认",
                amountMinor: transaction.amountMinor,
                direction: .neutral,
                isAccountScoped: true,
                hasAuthoritativePosting: false
            )
        }

        let direction: V15MoneyDirection = posting.amountMinor < 0 ? .outflow : posting.amountMinor > 0 ? .inflow : .neutral
        let effect: String
        if accountKinds[scopedAccountID] == .credit {
            effect = posting.amountMinor < 0 ? "欠款增加" : posting.amountMinor > 0 ? "欠款减少" : "欠款不变"
        } else {
            effect = posting.amountMinor < 0 ? "余额减少" : posting.amountMinor > 0 ? "余额增加" : "余额不变"
        }
        return .init(
            accountPath: path,
            accountEffect: effect,
            amountMinor: posting.amountMinor,
            direction: direction,
            isAccountScoped: true,
            hasAuthoritativePosting: true
        )
    }

    private static func accountName(_ id: UUID?, names: [UUID: String]) -> String {
        guard let id else { return "未提供账户" }
        return names[id] ?? "账户信息不可读取"
    }

    private static func transactionDirection(_ transaction: V15Transaction) -> V15MoneyDirection {
        switch transaction.kind {
        case "income", "reimbursement_receipt": .inflow
        case "transfer": .neutral
        default: .outflow
        }
    }
}
