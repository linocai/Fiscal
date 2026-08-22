import Foundation
import Observation

@MainActor
@Observable
public final class CreditModel {
    public private(set) var accounts: [CreditAccountSummaryDTO] = []
    public private(set) var selectedAccount: CreditAccountSummaryDTO?
    public private(set) var cycles: [CreditCycleDTO] = []
    public private(set) var selectedCycle: CreditCycleDTO?
    public private(set) var cycleTransactions: [TransactionDTO] = []
    public private(set) var phase: MasterDataPhase = .idle
    public private(set) var message: String?
    public private(set) var refreshMessage: String?
    public private(set) var nextCycleCursor: String?
    public private(set) var nextTransactionCursor: String?
    public private(set) var loadingMore = false
    private let repository: any CreditRepository
    private var generation = 0

    public init(repository: any CreditRepository) { self.repository = repository }

    public func loadAccounts() async {
        generation += 1; let current = generation; let hadData = !accounts.isEmpty
        if !hadData { phase = .loading }; message = nil; refreshMessage = nil
        do {
            let values = try await repository.listAccounts(); guard current == generation, !Task.isCancelled else { return }
            accounts = values; phase = values.isEmpty ? .empty : .loaded
        } catch is CancellationError { if current == generation, !hadData { phase = .idle } }
        catch { guard current == generation else { return }; apply(error, preserving: hadData) }
    }

    public func loadAccount(_ id: UUID) async {
        generation += 1; let current = generation; phase = .loading; message = nil
        do {
            async let summary = repository.account(id: id)
            async let page = repository.cycles(accountID: id, cursor: nil, limit: 20)
            let (loadedSummary, loadedPage) = try await (summary, page); guard current == generation else { return }
            selectedAccount = loadedSummary; cycles = loadedPage.items; nextCycleCursor = loadedPage.nextCursor; phase = .loaded
        } catch is CancellationError { if current == generation { phase = .idle } } catch { guard current == generation else { return }; apply(error, preserving: selectedAccount?.accountID == id) }
    }

    public func loadCycle(_ id: UUID) async {
        generation += 1; let current = generation; phase = .loading; message = nil; refreshMessage = nil
        selectedCycle = nil; cycleTransactions = []; nextTransactionCursor = nil
        do {
            async let cycle = repository.cycle(id: id)
            async let page = repository.transactions(cycleID: id, cursor: nil, limit: 50)
            let (loadedCycle, loadedPage) = try await (cycle, page); guard current == generation else { return }
            selectedCycle = loadedCycle; cycleTransactions = loadedPage.items; nextTransactionCursor = loadedPage.nextCursor; phase = .loaded
        } catch is CancellationError { if current == generation { phase = .idle } } catch { guard current == generation else { return }; apply(error, preserving: false) }
    }

    public func loadMoreCycles() async {
        guard let id = selectedAccount?.accountID, let cursor = nextCycleCursor, !loadingMore else { return }
        let current = generation; loadingMore = true; defer { loadingMore = false }
        do { let page = try await repository.cycles(accountID: id, cursor: cursor, limit: 20); guard current == generation else { return }; let known = Set(cycles.map(\.id)); cycles += page.items.filter { !known.contains($0.id) }; nextCycleCursor = page.nextCursor }
        catch is CancellationError {} catch { if current == generation { refreshMessage = display(error) } }
    }

    public func loadMoreTransactions() async {
        guard let id = selectedCycle?.id, let cursor = nextTransactionCursor, !loadingMore else { return }
        let current = generation; loadingMore = true; defer { loadingMore = false }
        do { let page = try await repository.transactions(cycleID: id, cursor: cursor, limit: 50); guard current == generation else { return }; let known = Set(cycleTransactions.map(\.id)); cycleTransactions += page.items.filter { !known.contains($0.id) }; nextTransactionCursor = page.nextCursor }
        catch is CancellationError {} catch { if current == generation { refreshMessage = display(error) } }
    }

    public func cyclesForRepayment(accountID: UUID, retaining cycleID: UUID? = nil) async throws -> [CreditCycleDTO] {
        var result: [CreditCycleDTO] = []; var cursor: String?
        repeat { let page = try await repository.cycles(accountID: accountID, cursor: cursor, limit: 20); result += page.items; cursor = page.nextCursor } while cursor != nil
        return result.filter { $0.remainingMinor > 0 || $0.id == cycleID }
    }
    public func cycleSummary(id: UUID) async throws -> CreditCycleDTO { try await repository.cycle(id: id) }
    public func refreshCurrentSelection() async {
        await loadAccounts(); if let id = selectedAccount?.accountID { await loadAccount(id) }; if let id = selectedCycle?.id { await loadCycle(id) }
    }
    private func apply(_ error: Error, preserving: Bool) { let text = display(error); message = text; if preserving { refreshMessage = text; phase = .loaded; return }; guard let api = error as? FiscalAPIError else { phase = .failed; return }; switch api { case .unauthorized: phase = .unauthorized; case .transport: phase = .offline; default: phase = .failed } }
    private func display(_ error: Error) -> String { (error as? FiscalAPIError)?.displayMessage ?? error.localizedDescription }
}
