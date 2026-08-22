import Foundation

public enum ReimbursementClaimStatus: String, Codable, Sendable, CaseIterable {
  case draft, pending, received, cancelled
  case partialReceived = "partial_received"
  case partiallyReceivedCancelled = "partially_received_cancelled"
  public var title: String {
    switch self {
    case .draft: "待提交"
    case .pending: "待付款"
    case .partialReceived: "部分到账"
    case .received: "全部到账"
    case .cancelled: "已取消"
    case .partiallyReceivedCancelled: "部分到账后取消"
    }
  }
  public var isTerminal: Bool {
    self == .received || self == .cancelled || self == .partiallyReceivedCancelled
  }
}

public struct ReimbursementAllocationDTO: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let transactionID: UUID
  public let expenseTitle: String
  public let expenseAmountMinor: Int64
  public let amountMinor: Int64
  public let receivedMinor: Int64
  public let outstandingMinor: Int64
  public let locked: Bool
  public let position: Int
  enum CodingKeys: String, CodingKey {
    case id, locked, position
    case transactionID = "transaction_id"
    case expenseTitle = "expense_title"
    case expenseAmountMinor = "expense_amount_minor"
    case amountMinor = "amount_minor"
    case receivedMinor = "received_minor"
    case outstandingMinor = "outstanding_minor"
  }
}

public struct ReimbursementPartyDTO: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let name: String
  public let expectedDate: String?
  public let note: String?
  public let claimedMinor: Int64
  public let receivedMinor: Int64
  public let outstandingMinor: Int64
  public let status: String
  public let position: Int
  public let allocations: [ReimbursementAllocationDTO]
  public var statusTitle: String {
    ReimbursementClaimStatus(rawValue: status)?.title ?? status
  }
  enum CodingKeys: String, CodingKey {
    case id, name, note, status, position, allocations
    case expectedDate = "expected_date"
    case claimedMinor = "claimed_minor"
    case receivedMinor = "received_minor"
    case outstandingMinor = "outstanding_minor"
  }
  public init(
    id: UUID, name: String, expectedDate: String?, note: String?, claimedMinor: Int64,
    receivedMinor: Int64, outstandingMinor: Int64, status: String, position: Int,
    allocations: [ReimbursementAllocationDTO]
  ) {
    self.id = id
    self.name = name
    self.expectedDate = expectedDate
    self.note = note
    self.claimedMinor = claimedMinor
    self.receivedMinor = receivedMinor
    self.outstandingMinor = outstandingMinor
    self.status = status
    self.position = position
    self.allocations = allocations
  }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    expectedDate = try values.decode(Optional<String>.self, forKey: .expectedDate)
    note = try values.decode(Optional<String>.self, forKey: .note)
    claimedMinor = try values.decode(Int64.self, forKey: .claimedMinor)
    receivedMinor = try values.decode(Int64.self, forKey: .receivedMinor)
    outstandingMinor = try values.decode(Int64.self, forKey: .outstandingMinor)
    status = try values.decode(String.self, forKey: .status)
    position = try values.decode(Int.self, forKey: .position)
    allocations = try values.decode([ReimbursementAllocationDTO].self, forKey: .allocations)
  }
}

public struct ReimbursementReceiptAllocationDTO: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let allocationID: UUID
  public let amountMinor: Int64
  public let position: Int
  enum CodingKeys: String, CodingKey {
    case id, position
    case allocationID = "allocation_id"
    case amountMinor = "amount_minor"
  }
}

public struct ReimbursementReceiptDTO: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let claimID: UUID
  public let partyID: UUID
  public let amountMinor: Int64
  public let receivedAt: Date
  public let destinationAccountID: UUID
  public let title: String
  public let note: String?
  public let transaction: TransactionDTO
  public let allocations: [ReimbursementReceiptAllocationDTO]
  public let version: Int
  public let voidedAt: Date?
  public let createdAt: Date
  public let updatedAt: Date
  enum CodingKeys: String, CodingKey {
    case id, title, note, transaction, allocations, version
    case claimID = "claim_id"
    case partyID = "party_id"
    case amountMinor = "amount_minor"
    case receivedAt = "received_at"
    case destinationAccountID = "destination_account_id"
    case voidedAt = "voided_at"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    claimID = try values.decode(UUID.self, forKey: .claimID)
    partyID = try values.decode(UUID.self, forKey: .partyID)
    amountMinor = try values.decode(Int64.self, forKey: .amountMinor)
    receivedAt = try values.decode(Date.self, forKey: .receivedAt)
    destinationAccountID = try values.decode(UUID.self, forKey: .destinationAccountID)
    title = try values.decode(String.self, forKey: .title)
    note = try values.decode(Optional<String>.self, forKey: .note)
    transaction = try values.decode(TransactionDTO.self, forKey: .transaction)
    allocations = try values.decode([ReimbursementReceiptAllocationDTO].self, forKey: .allocations)
    version = try values.decode(Int.self, forKey: .version)
    voidedAt = try values.decode(Optional<Date>.self, forKey: .voidedAt)
    createdAt = try values.decode(Date.self, forKey: .createdAt)
    updatedAt = try values.decode(Date.self, forKey: .updatedAt)
  }
}

public struct ReimbursementClaimDTO: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let title: String
  public let note: String?
  public let status: ReimbursementClaimStatus
  public let totalClaimedMinor: Int64
  public let receivedMinor: Int64
  public let outstandingMinor: Int64
  public let expenseCount: Int
  public let partyCount: Int
  public let receiptCount: Int
  public let parties: [ReimbursementPartyDTO]
  public let latestReceipt: ReimbursementReceiptDTO?
  public let version: Int
  public let submittedAt: Date?
  public let cancelledAt: Date?
  public let voidedAt: Date?
  public let archivedAt: Date?
  public let createdAt: Date
  public let updatedAt: Date
  enum CodingKeys: String, CodingKey {
    case id, title, note, status, parties, version
    case totalClaimedMinor = "total_claimed_minor"
    case receivedMinor = "received_minor"
    case outstandingMinor = "outstanding_minor"
    case expenseCount = "expense_count"
    case partyCount = "party_count"
    case receiptCount = "receipt_count"
    case latestReceipt = "latest_receipt"
    case submittedAt = "submitted_at"
    case cancelledAt = "cancelled_at"
    case voidedAt = "voided_at"
    case archivedAt = "archived_at"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }
  public init(
    id: UUID, title: String, note: String?, status: ReimbursementClaimStatus,
    totalClaimedMinor: Int64, receivedMinor: Int64, outstandingMinor: Int64, expenseCount: Int,
    partyCount: Int, receiptCount: Int, parties: [ReimbursementPartyDTO],
    latestReceipt: ReimbursementReceiptDTO?, version: Int, submittedAt: Date?, cancelledAt: Date?,
    voidedAt: Date?, archivedAt: Date?, createdAt: Date, updatedAt: Date
  ) {
    self.id = id
    self.title = title
    self.note = note
    self.status = status
    self.totalClaimedMinor = totalClaimedMinor
    self.receivedMinor = receivedMinor
    self.outstandingMinor = outstandingMinor
    self.expenseCount = expenseCount
    self.partyCount = partyCount
    self.receiptCount = receiptCount
    self.parties = parties
    self.latestReceipt = latestReceipt
    self.version = version
    self.submittedAt = submittedAt
    self.cancelledAt = cancelledAt
    self.voidedAt = voidedAt
    self.archivedAt = archivedAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    title = try values.decode(String.self, forKey: .title)
    note = try values.decode(Optional<String>.self, forKey: .note)
    status = try values.decode(ReimbursementClaimStatus.self, forKey: .status)
    totalClaimedMinor = try values.decode(Int64.self, forKey: .totalClaimedMinor)
    receivedMinor = try values.decode(Int64.self, forKey: .receivedMinor)
    outstandingMinor = try values.decode(Int64.self, forKey: .outstandingMinor)
    expenseCount = try values.decode(Int.self, forKey: .expenseCount)
    partyCount = try values.decode(Int.self, forKey: .partyCount)
    receiptCount = try values.decode(Int.self, forKey: .receiptCount)
    parties = try values.decode([ReimbursementPartyDTO].self, forKey: .parties)
    latestReceipt = try values.decode(
      Optional<ReimbursementReceiptDTO>.self, forKey: .latestReceipt)
    version = try values.decode(Int.self, forKey: .version)
    submittedAt = try values.decode(Optional<Date>.self, forKey: .submittedAt)
    cancelledAt = try values.decode(Optional<Date>.self, forKey: .cancelledAt)
    voidedAt = try values.decode(Optional<Date>.self, forKey: .voidedAt)
    archivedAt = try values.decode(Optional<Date>.self, forKey: .archivedAt)
    createdAt = try values.decode(Date.self, forKey: .createdAt)
    updatedAt = try values.decode(Date.self, forKey: .updatedAt)
  }
}

public struct ReimbursementClaimPage: Codable, Sendable, Equatable {
  public let items: [ReimbursementClaimDTO]
  public let nextCursor: String?
  enum CodingKeys: String, CodingKey {
    case items
    case nextCursor = "next_cursor"
  }
  public init(items: [ReimbursementClaimDTO], nextCursor: String?) {
    self.items = items
    self.nextCursor = nextCursor
  }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    items = try values.decode([ReimbursementClaimDTO].self, forKey: .items)
    nextCursor = try values.decode(Optional<String>.self, forKey: .nextCursor)
  }
}
public struct ReimbursementReceiptPage: Codable, Sendable, Equatable {
  public let items: [ReimbursementReceiptDTO]
  public let nextCursor: String?
  enum CodingKeys: String, CodingKey {
    case items
    case nextCursor = "next_cursor"
  }
  public init(items: [ReimbursementReceiptDTO], nextCursor: String?) {
    self.items = items
    self.nextCursor = nextCursor
  }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    items = try values.decode([ReimbursementReceiptDTO].self, forKey: .items)
    nextCursor = try values.decode(Optional<String>.self, forKey: .nextCursor)
  }
}

public struct ReimbursementAllocationDraft: Codable, Sendable, Equatable, Identifiable {
  public var serverID: UUID?
  public var id: UUID { serverID ?? clientID }
  private var clientID: UUID
  public var transactionID: UUID
  public var amountMinor: Int64
  enum CodingKeys: String, CodingKey {
    case serverID = "id"
    case transactionID = "transaction_id"
    case amountMinor = "amount_minor"
  }
  public init(id: UUID?, transactionID: UUID, amountMinor: Int64) {
    serverID = id
    clientID = UUID()
    self.transactionID = transactionID
    self.amountMinor = amountMinor
  }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    serverID = try values.decode(Optional<UUID>.self, forKey: .serverID)
    clientID = UUID()
    transactionID = try values.decode(UUID.self, forKey: .transactionID)
    amountMinor = try values.decode(Int64.self, forKey: .amountMinor)
  }
}
public struct ReimbursementPartyDraft: Codable, Sendable, Equatable, Identifiable {
  public var serverID: UUID?
  public var id: UUID { serverID ?? clientID }
  private var clientID: UUID
  public var name: String
  public var expectedDate: String?
  public var note: String?
  public var allocations: [ReimbursementAllocationDraft]
  enum CodingKeys: String, CodingKey {
    case serverID = "id"
    case name, note, allocations
    case expectedDate = "expected_date"
  }
  public init(
    id: UUID?, name: String, expectedDate: String?, note: String?,
    allocations: [ReimbursementAllocationDraft]
  ) {
    serverID = id
    clientID = UUID()
    self.name = name
    self.expectedDate = expectedDate
    self.note = note
    self.allocations = allocations
  }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    serverID = try values.decode(Optional<UUID>.self, forKey: .serverID)
    clientID = UUID()
    name = try values.decode(String.self, forKey: .name)
    expectedDate = try values.decode(Optional<String>.self, forKey: .expectedDate)
    note = try values.decode(Optional<String>.self, forKey: .note)
    allocations = try values.decode([ReimbursementAllocationDraft].self, forKey: .allocations)
  }
}
public struct ReimbursementClaimCreateRequest: Codable, Sendable, Equatable {
  public var title: String
  public var note: String?
  public var parties: [ReimbursementPartyDraft]
}
public struct ReimbursementClaimReplacementRequest: Codable, Sendable, Equatable {
  public var expectedVersion: Int
  public var title: String
  public var note: String?
  public var parties: [ReimbursementPartyDraft]
  enum CodingKeys: String, CodingKey {
    case title, note, parties
    case expectedVersion = "expected_version"
  }
}
public struct ReimbursementVersionRequest: Codable, Sendable, Equatable {
  public let expectedVersion: Int
  enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version" }
}

public struct ReimbursementClaimPreview: Codable, Sendable, Equatable {
  public let current: ReimbursementClaimDTO
  public let proposed: ReimbursementClaimDTO
  public let releasedMinor: Int64
  public let newlyClaimedMinor: Int64
  public let warnings: [String]
  enum CodingKeys: String, CodingKey {
    case current, proposed, warnings
    case releasedMinor = "released_minor"
    case newlyClaimedMinor = "newly_claimed_minor"
  }
}
public struct ReimbursementCancelPreview: Codable, Sendable, Equatable {
  public let current: ReimbursementClaimDTO
  public let proposedStatus: ReimbursementClaimStatus
  public let releasedMinor: Int64
  public let retainedReceivedMinor: Int64
  enum CodingKeys: String, CodingKey {
    case current
    case proposedStatus = "proposed_status"
    case releasedMinor = "released_minor"
    case retainedReceivedMinor = "retained_received_minor"
  }
}

public struct ReimbursementReceiptRequest: Codable, Sendable, Equatable {
  public var expectedClaimVersion: Int
  public var partyID: UUID
  public var amountMinor: Int64
  public var receivedAt: Date
  public var destinationAccountID: UUID
  public var title: String
  public var note: String?
  enum CodingKeys: String, CodingKey {
    case title, note
    case expectedClaimVersion = "expected_claim_version"
    case partyID = "party_id"
    case amountMinor = "amount_minor"
    case receivedAt = "received_at"
    case destinationAccountID = "destination_account_id"
  }
}
public struct ReimbursementReceiptReplacementRequest: Codable, Sendable, Equatable {
  public var expectedClaimVersion: Int
  public var expectedReceiptVersion: Int
  public var partyID: UUID
  public var amountMinor: Int64
  public var receivedAt: Date
  public var destinationAccountID: UUID
  public var title: String
  public var note: String?
  enum CodingKeys: String, CodingKey {
    case title, note
    case expectedClaimVersion = "expected_claim_version"
    case expectedReceiptVersion = "expected_receipt_version"
    case partyID = "party_id"
    case amountMinor = "amount_minor"
    case receivedAt = "received_at"
    case destinationAccountID = "destination_account_id"
  }
}
public struct ReimbursementReceiptVersionRequest: Codable, Sendable, Equatable {
  public let expectedClaimVersion: Int
  public let expectedReceiptVersion: Int
  enum CodingKeys: String, CodingKey {
    case expectedClaimVersion = "expected_claim_version"
    case expectedReceiptVersion = "expected_receipt_version"
  }
}
public struct ReimbursementReceiptPreview: Codable, Sendable, Equatable {
  public let claimBefore: ReimbursementClaimDTO
  public let partyID: UUID
  public let amountMinor: Int64
  public let partyReceivedBeforeMinor: Int64
  public let partyReceivedAfterMinor: Int64
  public let claimReceivedBeforeMinor: Int64
  public let claimReceivedAfterMinor: Int64
  public let persistedAllocations: [ReimbursementReceiptAllocationDTO]
  enum CodingKeys: String, CodingKey {
    case partyID = "party_id"
    case amountMinor = "amount_minor"
    case claimBefore = "claim_before"
    case partyReceivedBeforeMinor = "party_received_before_minor"
    case partyReceivedAfterMinor = "party_received_after_minor"
    case claimReceivedBeforeMinor = "claim_received_before_minor"
    case claimReceivedAfterMinor = "claim_received_after_minor"
    case persistedAllocations = "persisted_allocations"
  }
}

public struct ReimbursementEligibility: Codable, Sendable, Equatable {
  public let eligible: Bool
  public let transactionID: UUID
  public let canonicalAmountMinor: Int64
  public let allocatedMinor: Int64
  public let availableMinor: Int64
  public let reasons: [String]
  enum CodingKeys: String, CodingKey {
    case eligible, reasons
    case transactionID = "transaction_id"
    case canonicalAmountMinor = "canonical_amount_minor"
    case allocatedMinor = "allocated_minor"
    case availableMinor = "available_minor"
  }
}
public struct ReimbursementExpenseOption: Codable, Sendable, Equatable, Identifiable {
  public var id: UUID { transactionID }
  public let transactionID: UUID
  public let title: String
  public let businessDate: String
  public let kind: String
  public let accountID: UUID
  public let categoryID: UUID
  public let canonicalAmountMinor: Int64
  public let allocatedMinor: Int64
  public let availableMinor: Int64
  enum CodingKeys: String, CodingKey {
    case title, kind
    case transactionID = "transaction_id"
    case businessDate = "business_date"
    case accountID = "account_id"
    case categoryID = "category_id"
    case canonicalAmountMinor = "canonical_amount_minor"
    case allocatedMinor = "allocated_minor"
    case availableMinor = "available_minor"
  }
}
public struct ReimbursementSummary: Codable, Sendable, Equatable {
  public let grossExpenseMinor: Int64
  public let merchantPrincipalRefundMinor: Int64
  public let expectedReimbursementMinor: Int64
  public let receivedReimbursementMinor: Int64
  public let personalExpectedExpenseMinor: Int64
  public let personalRealizedExpenseMinor: Int64
  public let outstandingMinor: Int64
  enum CodingKeys: String, CodingKey {
    case grossExpenseMinor = "gross_expense_minor"
    case merchantPrincipalRefundMinor = "merchant_principal_refund_minor"
    case expectedReimbursementMinor = "expected_reimbursement_minor"
    case receivedReimbursementMinor = "received_reimbursement_minor"
    case personalExpectedExpenseMinor = "personal_expected_expense_minor"
    case personalRealizedExpenseMinor = "personal_realized_expense_minor"
    case outstandingMinor = "outstanding_minor"
  }
}

public enum ReimbursementRelationRole: String, Codable, Sendable { case expense, receipt }
public struct ReimbursementRelation: Codable, Sendable, Equatable {
  public let role: ReimbursementRelationRole
  public let claimID: UUID
  public let claimTitle: String
  public let claimStatus: ReimbursementClaimStatus
  public let partyID: UUID?
  public let partyName: String?
  public let receiptID: UUID?
  public let allocatedMinor: Int64
  public let receivedMinor: Int64
  public let outstandingMinor: Int64
  enum CodingKeys: String, CodingKey {
    case role
    case claimID = "claim_id"
    case claimTitle = "claim_title"
    case claimStatus = "claim_status"
    case partyID = "party_id"
    case partyName = "party_name"
    case receiptID = "receipt_id"
    case allocatedMinor = "allocated_minor"
    case receivedMinor = "received_minor"
    case outstandingMinor = "outstanding_minor"
  }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    role = try values.decode(ReimbursementRelationRole.self, forKey: .role)
    claimID = try values.decode(UUID.self, forKey: .claimID)
    claimTitle = try values.decode(String.self, forKey: .claimTitle)
    claimStatus = try values.decode(ReimbursementClaimStatus.self, forKey: .claimStatus)
    partyID = try values.decode(Optional<UUID>.self, forKey: .partyID)
    partyName = try values.decode(Optional<String>.self, forKey: .partyName)
    receiptID = try values.decode(Optional<UUID>.self, forKey: .receiptID)
    allocatedMinor = try values.decode(Int64.self, forKey: .allocatedMinor)
    receivedMinor = try values.decode(Int64.self, forKey: .receivedMinor)
    outstandingMinor = try values.decode(Int64.self, forKey: .outstandingMinor)
  }
}
