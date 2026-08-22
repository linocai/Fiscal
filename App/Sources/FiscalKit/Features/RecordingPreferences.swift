import Foundation
import Observation

public enum RecordingDefaultKind: String, CaseIterable, Identifiable, Sendable {
    case expense
    case income

    public var id: Self { self }
    public var title: String { self == .expense ? "支出" : "收入" }
    public var transactionKind: TransactionKind { self == .expense ? .expense : .income }
}

/// Non-sensitive, device-local defaults for new manual entries.
@MainActor
@Observable
public final class RecordingPreferences {
    public private(set) var defaultAccountID: UUID?
    public var defaultKind: RecordingDefaultKind {
        didSet { defaults.set(defaultKind.rawValue, forKey: Keys.kind) }
    }
    public var stayAfterSave: Bool {
        didSet { defaults.set(stayAfterSave, forKey: Keys.stayAfterSave) }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaultAccountID = defaults.string(forKey: Keys.account).flatMap(UUID.init(uuidString:))
        defaultKind = defaults.string(forKey: Keys.kind).flatMap(RecordingDefaultKind.init(rawValue:)) ?? .expense
        stayAfterSave = defaults.bool(forKey: Keys.stayAfterSave)
    }

    public func setDefaultAccount(_ id: UUID?) {
        defaultAccountID = id
        if let id { defaults.set(id.uuidString, forKey: Keys.account) }
        else { defaults.removeObject(forKey: Keys.account) }
    }

    /// Returns the active cash/debit default, clearing stale or incompatible storage.
    @discardableResult
    public func validatedDefaultAccount(in accounts: [AccountDTO]) -> UUID? {
        guard let id = defaultAccountID else { return nil }
        guard accounts.contains(where: { $0.id == id && $0.archivedAt == nil && ($0.kind == .cash || $0.kind == .debit) }) else {
            setDefaultAccount(nil)
            return nil
        }
        return id
    }

    private enum Keys {
        static let account = "fiscal.recording.default-account"
        static let kind = "fiscal.recording.default-kind"
        static let stayAfterSave = "fiscal.recording.stay-after-save"
    }
}

/// The entry remains truthful until the filtered server export is wired in.
public protocol TransactionCSVExportAvailability: Sendable {
    var isAvailable: Bool { get async }
}
