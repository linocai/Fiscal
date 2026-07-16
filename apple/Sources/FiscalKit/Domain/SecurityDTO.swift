import Foundation

public enum DeviceTokenRole: String, Codable, Sendable, CaseIterable {
    case device, `operator`
    public var title: String { self == .operator ? "运维设备" : "普通设备" }
}

public enum DeviceTokenStatus: String, Codable, Sendable {
    case pending, active, revoked
    public var title: String {
        switch self { case .pending: "待激活"; case .active: "有效"; case .revoked: "已撤销" }
    }
}

public struct DeviceTokenSummary: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let label: String
    public let role: DeviceTokenRole
    public let status: DeviceTokenStatus
    public let fingerprint: String
    public let version: Int
    public let createdAt: Date
    public let activatedAt: Date?
    public let lastUsedAt: Date?
    public let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, label, role, status, fingerprint, version
        case createdAt = "created_at"
        case activatedAt = "activated_at"
        case lastUsedAt = "last_used_at"
        case expiresAt = "expires_at"
    }
}

public struct DeviceTokenCounts: Codable, Sendable, Equatable {
    public let active: Int
    public let pending: Int
}

public struct DeviceRateLimits: Codable, Sendable, Equatable {
    public let readPerMinute: Int
    public let writePerMinute: Int
    public let aiPerMinute: Int
    public let failedAuthPerMinute: Int

    enum CodingKeys: String, CodingKey {
        case readPerMinute = "read_per_minute"
        case writePerMinute = "write_per_minute"
        case aiPerMinute = "ai_per_minute"
        case failedAuthPerMinute = "failed_auth_per_minute"
    }
}

public struct SecurityStatusDTO: Codable, Sendable, Equatable {
    public let authenticationMode: String
    public let serverTime: Date
    public let currentDevice: DeviceTokenSummary?
    public let tokenCounts: DeviceTokenCounts
    public let rateLimits: DeviceRateLimits

    enum CodingKeys: String, CodingKey {
        case authenticationMode = "authentication_mode"
        case serverTime = "server_time"
        case currentDevice = "current_device"
        case tokenCounts = "token_counts"
        case rateLimits = "rate_limits"
    }
}

public struct BackupOperationStatus: Codable, Sendable, Equatable {
    public let state: String
    public let createdAt: Date?
    public let ageHours: Int?
    public let durationSeconds: Int?
    public let sizeBytes: Int?

    enum CodingKeys: String, CodingKey {
        case state
        case createdAt = "created_at"
        case ageHours = "age_hours"
        case durationSeconds = "duration_seconds"
        case sizeBytes = "size_bytes"
    }
}

public struct RestoreOperationStatus: Codable, Sendable, Equatable {
    public let state: String
    public let checkedAt: Date?
    public let ageHours: Int?
    public let durationSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case state
        case checkedAt = "checked_at"
        case ageHours = "age_hours"
        case durationSeconds = "duration_seconds"
    }
}

public struct DiskOperationStatus: Codable, Sendable, Equatable {
    public let state: String
    public let checkedAt: Date?
    public let usedPercent: Int?
    public let warningPercent: Int?
    public let failurePercent: Int?

    enum CodingKeys: String, CodingKey {
        case state
        case checkedAt = "checked_at"
        case usedPercent = "used_percent"
        case warningPercent = "warning_percent"
        case failurePercent = "failure_percent"
    }
}

public struct OperationsStatusDTO: Codable, Sendable, Equatable {
    public let serviceVersion: String
    public let releaseRevision: String?
    public let database: String
    public let alembicRevision: String
    public let releaseAlembicRevision: String?
    public let schemaState: String
    public let backup: BackupOperationStatus
    public let restore: RestoreOperationStatus
    public let disk: DiskOperationStatus

    enum CodingKeys: String, CodingKey {
        case serviceVersion = "service_version"
        case releaseRevision = "release_revision"
        case database
        case alembicRevision = "alembic_revision"
        case releaseAlembicRevision = "release_alembic_revision"
        case schemaState = "schema_state"
        case backup, restore, disk
    }
}

public struct DeviceTokenListResponse: Codable, Sendable, Equatable {
    public let items: [DeviceTokenSummary]
}

public struct IssuedDeviceToken: Codable, Sendable, Equatable {
    public let deviceToken: String
    public let token: DeviceTokenSummary
    enum CodingKeys: String, CodingKey { case deviceToken = "device_token"; case token }
}

public struct ActivatedDeviceToken: Codable, Sendable, Equatable {
    public let token: DeviceTokenSummary
    public let revokedPredecessorID: UUID?
    enum CodingKeys: String, CodingKey {
        case token
        case revokedPredecessorID = "revoked_predecessor_id"
    }
}

public struct RevokedDeviceToken: Codable, Sendable, Equatable {
    public let token: DeviceTokenSummary
}
