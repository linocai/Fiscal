import Foundation
import Testing
@testable import FiscalKit

@Suite("FiscalKit P11 device security")
struct P11SecurityTests {
  @Test("Rotation promotes the candidate only after server activation") @MainActor
  func rotationCommitsInTwoPhases() async throws {
    let fixture = SecurityFixture(activation: .succeeds)
    let model = DeviceSecurityModel(repository: fixture.repository, tokenStore: fixture.store)
    await model.load()
    await fixture.events.clear()

    await model.rotateCurrent()

    let events = await fixture.events.values
    #expect(Array(events.prefix(4)) == [
      "prepare:7", "save-pending:candidate-key", "activate:candidate-key:1", "promote-pending",
    ])
    #expect(await fixture.store.activeToken == "candidate-key")
    #expect(await fixture.store.pendingToken == nil)
    #expect(model.message == "设备密钥已安全轮换，旧密钥已由服务器撤销")
  }

  @Test("A lost activation response is confirmed with the candidate before promotion") @MainActor
  func ambiguousActivationIsRecovered() async {
    let fixture = SecurityFixture(activation: .commitsThenLosesResponse)
    let model = DeviceSecurityModel(repository: fixture.repository, tokenStore: fixture.store)
    await model.load()
    await fixture.events.clear()

    await model.rotateCurrent()

    let events = await fixture.events.values
    #expect(Array(events.prefix(5)) == [
      "prepare:7", "save-pending:candidate-key", "activate:candidate-key:1",
      "status:candidate-key", "promote-pending",
    ])
    #expect(await fixture.store.activeToken == "candidate-key")
    #expect(await fixture.store.pendingToken == nil)
    #expect(model.message == "设备密钥已安全轮换，旧密钥已由服务器撤销")
  }

  @Test("An unconfirmed activation keeps both the old key and pending candidate") @MainActor
  func failedActivationPreservesRecoveryState() async {
    let fixture = SecurityFixture(activation: .failsUnconfirmed)
    let model = DeviceSecurityModel(repository: fixture.repository, tokenStore: fixture.store)
    await model.load()
    await fixture.events.clear()

    await model.rotateCurrent()

    #expect(await fixture.events.values == [
      "prepare:7", "save-pending:candidate-key", "activate:candidate-key:1",
      "status:candidate-key",
    ])
    #expect(await fixture.store.activeToken == "old-key")
    #expect(await fixture.store.pendingToken?.token == "candidate-key")
    #expect(model.message == "设备密钥轮换尚未确认，原密钥仍会保留")
  }

  @Test("A newly issued raw token can be explicitly cleared after its one-time display") @MainActor
  func issuedRawTokenCanBeCleared() async {
    let fixture = SecurityFixture(activation: .succeeds)
    let model = DeviceSecurityModel(repository: fixture.repository, tokenStore: fixture.store)

    await model.issueDevice(label: "  iPad mini  ")
    #expect(model.issuedDeviceToken?.deviceToken == "candidate-key")
    #expect(await fixture.events.values.first == "issue:iPad mini")

    model.clearIssuedToken()
    #expect(model.issuedDeviceToken == nil)
  }

  @Test("A transferred pending token activates before becoming the device's active key") @MainActor
  func transferredTokenInstallsSafely() async {
    let fixture = SecurityFixture(activation: .succeeds, activeToken: nil)
    let model = DeviceSecurityModel(repository: fixture.repository, tokenStore: fixture.store)

    await model.installIssuedToken("fiscal_dt_v1_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ")

    #expect(Array((await fixture.events.values).prefix(3)) == [
      "save-pending:fiscal_dt_v1_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ",
      "activate:fiscal_dt_v1_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ:1",
      "promote-pending",
    ])
    #expect(await fixture.store.activeToken == "fiscal_dt_v1_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ")
    #expect(model.message == "新设备密钥已激活并安全存入 Keychain")
  }
}

private struct SecurityFixture {
  let events: SecurityEventLog
  let repository: SecurityRepositoryMock
  let store: DeviceTokenStoreMock

  init(activation: SecurityRepositoryMock.ActivationBehavior, activeToken: String? = "old-key") {
    let events = SecurityEventLog()
    self.events = events
    repository = SecurityRepositoryMock(events: events, activation: activation)
    store = DeviceTokenStoreMock(events: events, activeToken: activeToken)
  }
}

private actor SecurityEventLog {
  private var storage: [String] = []
  var values: [String] { storage }
  func append(_ value: String) { storage.append(value) }
  func clear() { storage.removeAll() }
}

private actor DeviceTokenStoreMock: DeviceTokenStoring {
  private(set) var activeToken: String?
  private(set) var pendingToken: PendingDeviceToken?
  private let events: SecurityEventLog

  init(events: SecurityEventLog, activeToken: String?) {
    self.events = events
    self.activeToken = activeToken
  }

  func read() async throws -> String? { activeToken }

  func save(_ token: String) async throws {
    await events.append("save-active:\(token)")
    activeToken = token
  }

  func delete() async throws {
    await events.append("delete-active")
    activeToken = nil
  }

  func savePending(_ pending: PendingDeviceToken) async throws {
    await events.append("save-pending:\(pending.token)")
    pendingToken = pending
  }

  func readPending() async throws -> PendingDeviceToken? { pendingToken }

  func deletePending() async throws {
    await events.append("delete-pending")
    pendingToken = nil
  }

  func promotePending() async throws {
    guard let pendingToken else { throw SecurityTestError.missingPendingToken }
    await events.append("promote-pending")
    activeToken = pendingToken.token
    self.pendingToken = nil
  }
}

private actor SecurityRepositoryMock: DeviceSecurityRepository {
  enum ActivationBehavior: Sendable {
    case succeeds
    case commitsThenLosesResponse
    case failsUnconfirmed
  }

  private let events: SecurityEventLog
  private let activation: ActivationBehavior
  private var serverActivatedCandidate = false

  init(events: SecurityEventLog, activation: ActivationBehavior) {
    self.events = events
    self.activation = activation
  }

  func securityStatus(authorizationToken: String?) async throws -> SecurityStatusDTO {
    await events.append("status:\(authorizationToken ?? "active")")
    if authorizationToken == "candidate-key" {
      guard serverActivatedCandidate else { throw SecurityTestError.candidateNotActive }
      return Self.status(current: Self.candidate(status: .active, version: 2))
    }
    return Self.status(current: Self.activeDevice)
  }

  func list() async throws -> [DeviceTokenSummary] {
    await events.append("list")
    return [Self.activeDevice]
  }

  func operationsStatus() async throws -> OperationsStatusDTO {
    await events.append("operations")
    return OperationsStatusDTO(
      serviceVersion: "0.1.0", releaseRevision: String(repeating: "a", count: 40),
      database: "ready", alembicRevision: "20260716_0010",
      releaseAlembicRevision: "20260716_0010", schemaState: "current",
      backup: BackupOperationStatus(
        state: "verified", createdAt: Self.timestamp, ageHours: 1,
        durationSeconds: 3, sizeBytes: 1024),
      restore: RestoreOperationStatus(
        state: "verified", checkedAt: Self.timestamp, ageHours: 2, durationSeconds: 8),
      disk: DiskOperationStatus(
        state: "healthy", checkedAt: Self.timestamp, usedPercent: 21,
        warningPercent: 75, failurePercent: 85))
  }

  func issue(label: String) async throws -> IssuedDeviceToken {
    await events.append("issue:\(label)")
    return Self.issuedCandidate
  }

  func prepareRotation(expectedVersion: Int) async throws -> IssuedDeviceToken {
    await events.append("prepare:\(expectedVersion)")
    return Self.issuedCandidate
  }

  func activate(token: String, expectedVersion: Int) async throws -> ActivatedDeviceToken {
    await events.append("activate:\(token):\(expectedVersion)")
    switch activation {
    case .succeeds:
      serverActivatedCandidate = true
      return ActivatedDeviceToken(
        token: Self.candidate(status: .active, version: 2),
        revokedPredecessorID: Self.activeDevice.id)
    case .commitsThenLosesResponse:
      serverActivatedCandidate = true
      throw SecurityTestError.responseLost
    case .failsUnconfirmed:
      throw SecurityTestError.activationFailed
    }
  }

  func revoke(id: UUID, expectedVersion: Int) async throws -> DeviceTokenSummary {
    await events.append("revoke:\(id):\(expectedVersion)")
    return Self.activeDevice
  }

  private static let activeID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
  private static let candidateID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
  private static let timestamp = Date(timeIntervalSince1970: 1_752_681_600)

  private static let activeDevice = DeviceTokenSummary(
    id: activeID, label: "My Mac", role: .operator, status: .active,
    fingerprint: "old-fingerprint", version: 7, createdAt: timestamp,
    activatedAt: timestamp, lastUsedAt: timestamp, expiresAt: nil)

  private static var issuedCandidate: IssuedDeviceToken {
    IssuedDeviceToken(deviceToken: "candidate-key", token: candidate(status: .pending, version: 1))
  }

  private static func candidate(status: DeviceTokenStatus, version: Int) -> DeviceTokenSummary {
    DeviceTokenSummary(
      id: candidateID, label: "My Mac", role: .operator, status: status,
      fingerprint: "candidate-fingerprint", version: version, createdAt: timestamp,
      activatedAt: status == .active ? timestamp : nil, lastUsedAt: nil, expiresAt: nil)
  }

  private static func status(current: DeviceTokenSummary) -> SecurityStatusDTO {
    SecurityStatusDTO(
      authenticationMode: "database", serverTime: timestamp, currentDevice: current,
      tokenCounts: DeviceTokenCounts(active: 1, pending: 0),
      rateLimits: DeviceRateLimits(
        readPerMinute: 120, writePerMinute: 30, aiPerMinute: 10, failedAuthPerMinute: 10))
  }
}

private enum SecurityTestError: Error {
  case responseLost
  case activationFailed
  case candidateNotActive
  case missingPendingToken
}
