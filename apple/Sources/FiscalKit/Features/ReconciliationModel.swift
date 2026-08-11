import Foundation
import Observation

@MainActor
@Observable
public final class ReconciliationModel {
    public private(set) var checkpoints: [ReconciliationCheckpointDTO] = []
    public private(set) var attention: [AttentionItemDTO] = []
    public private(set) var diagnosis: BalanceDiagnosisDTO?
    public private(set) var isLoading = false
    public private(set) var isSaving = false
    public private(set) var message: String?
    private let repository: any ReconciliationRepository
    private var generation: UInt64 = 0

    public init(repository: any ReconciliationRepository) { self.repository = repository }

    public func load(accountID: UUID) async {
        generation &+= 1
        let current = generation
        isLoading = true
        defer { if current == generation { isLoading = false } }
        do {
            async let checkpoints = repository.checkpoints(accountID: accountID)
            async let attention = repository.attention()
            async let diagnosis = repository.diagnosis(accountID: accountID, asOf: Date())
            let values = try await (checkpoints, attention, diagnosis)
            guard current == generation else { return }
            self.checkpoints = values.0
            self.attention = values.1.items
            self.diagnosis = values.2
            message = nil
        } catch is CancellationError { return
        } catch { guard current == generation else { return }; message = error.localizedDescription }
    }

    @discardableResult
    public func create(accountID: UUID, actualMinor: Int64, note: String?) async -> Bool {
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await repository.create(.init(
                targetKind: .account,
                accountID: accountID,
                creditCycleID: nil,
                asOf: Date(),
                actualBalanceMinor: actualMinor,
                note: normalizedNote(note)
            ))
            await load(accountID: accountID)
            return true
        } catch { message = error.localizedDescription; return false }
    }

    public func ignore(_ item: AttentionItemDTO) async {
        do {
            try await repository.ignore(item: item, until: Date().addingTimeInterval(7 * 24 * 60 * 60))
            attention.removeAll { $0.id == item.id }
        } catch { message = error.localizedDescription }
    }

    private func normalizedNote(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
