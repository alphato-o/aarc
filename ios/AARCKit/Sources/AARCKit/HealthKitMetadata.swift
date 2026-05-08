import Foundation

/// HealthKit workout metadata keys AARC stamps on every workout it writes.
/// See D19 in docs/decisions.md.
public enum HKMetadataKeys {
    public static let runId = "aarc.run_id"
    public static let testData = "aarc.test_data"
    public static let createdAt = "aarc.created_at"
    public static let appVersion = "aarc.app_version"
}
