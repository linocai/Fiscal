import Foundation

public struct RateLimits: Codable, Sendable, Equatable {
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

/// Response of `/auth/session`, `/auth/passphrase/initialize`, and `/auth/passphrase/change`.
/// The access key appears only in these three responses and is stored, never displayed.
public struct AccessKeyResponse: Codable, Sendable, Equatable {
    public let accessKey: String
    public let credentialGeneration: Int

    enum CodingKeys: String, CodingKey {
        case accessKey = "access_key"
        case credentialGeneration = "credential_generation"
    }
}

/// Response of `/auth/status`. Never carries an access key or passphrase.
public struct AccessCredentialStatus: Codable, Sendable, Equatable {
    public let authenticationMode: String
    public let passphraseSet: Bool
    public let credentialGeneration: Int?
    public let lastRotatedAt: Date?
    public let activeAccessKeyCount: Int
    public let serverTime: Date
    public let rateLimits: RateLimits

    enum CodingKeys: String, CodingKey {
        case authenticationMode = "authentication_mode"
        case passphraseSet = "passphrase_set"
        case credentialGeneration = "credential_generation"
        case lastRotatedAt = "last_rotated_at"
        case activeAccessKeyCount = "active_access_key_count"
        case serverTime = "server_time"
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
