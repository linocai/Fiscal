import Foundation

public struct BackupOperationStatus: Codable, Sendable, Equatable {
    public let state: String
    public let createdAt: Date?
    public let ageHours: Int?
    public let durationSeconds: Int?
    public let sizeBytes: Int?
    enum CodingKeys: String, CodingKey {
        case state
        case createdAt = "created_at", ageHours = "age_hours"
        case durationSeconds = "duration_seconds", sizeBytes = "size_bytes"
    }
}

public struct RestoreOperationStatus: Codable, Sendable, Equatable {
    public let state: String
    public let checkedAt: Date?
    public let ageHours: Int?
    public let durationSeconds: Int?
    enum CodingKeys: String, CodingKey {
        case state
        case checkedAt = "checked_at", ageHours = "age_hours", durationSeconds = "duration_seconds"
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
        case checkedAt = "checked_at", usedPercent = "used_percent"
        case warningPercent = "warning_percent", failurePercent = "failure_percent"
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
        case serviceVersion = "service_version", releaseRevision = "release_revision"
        case database, alembicRevision = "alembic_revision"
        case releaseAlembicRevision = "release_alembic_revision", schemaState = "schema_state"
        case backup, restore, disk
    }
}
