import Foundation
import Observation

/// HealthKit metadata keys we stamp on every workout AARC writes.
/// See D19 in docs/decisions.md.
enum HKMetadataKeys {
    static let runId = "aarc.run_id"
    static let testData = "aarc.test_data"
    static let createdAt = "aarc.created_at"
    static let appVersion = "aarc.app_version"
}

/// User-facing safety toggles that govern HealthKit writes.
/// Default at app launch: tag mode ON, skip mode OFF (D19).
@Observable
@MainActor
final class TestDataSettings {
    static let shared = TestDataSettings()

    private let store: UserDefaults
    private static let kIsTestDataMode = "aarc.config.isTestDataMode"
    private static let kSkipHealthKitWrite = "aarc.config.skipHealthKitWrite"
    private static let kLastWipeDate = "aarc.config.lastWipeDate"

    var isTestDataMode: Bool {
        didSet { store.set(isTestDataMode, forKey: Self.kIsTestDataMode) }
    }

    var skipHealthKitWrite: Bool {
        didSet { store.set(skipHealthKitWrite, forKey: Self.kSkipHealthKitWrite) }
    }

    var lastWipeDate: Date? {
        didSet {
            if let lastWipeDate {
                store.set(lastWipeDate, forKey: Self.kLastWipeDate)
            } else {
                store.removeObject(forKey: Self.kLastWipeDate)
            }
        }
    }

    /// True iff either safety mode is engaged. Drives the TEST RUN banner.
    var isAnySafetyModeOn: Bool {
        isTestDataMode || skipHealthKitWrite
    }

    init(store: UserDefaults = .standard) {
        self.store = store
        // Persist the default ON value on first launch so absence-of-key
        // can never mean "test mode silently off".
        if store.object(forKey: Self.kIsTestDataMode) == nil {
            store.set(true, forKey: Self.kIsTestDataMode)
        }
        self.isTestDataMode = store.bool(forKey: Self.kIsTestDataMode)
        self.skipHealthKitWrite = store.bool(forKey: Self.kSkipHealthKitWrite)
        self.lastWipeDate = store.object(forKey: Self.kLastWipeDate) as? Date
    }
}
