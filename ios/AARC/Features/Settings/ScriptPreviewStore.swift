import Foundation
import Observation
import AARCKit

/// Persists the most-recently generated script + the user's plan
/// inputs across navigation transitions and app launches. Without
/// this, ScriptPreviewView's `@State` was destroyed when the user
/// popped the nav stack and any generated script vanished.
///
/// Stored in UserDefaults — small (a few KB of JSON), survives launch.
/// Replaced atomically each time the user taps Generate.
///
/// This is also the single source of truth for "what's the user's
/// current plan" — read by RunOrchestrator at start time and by
/// ScriptEngine when the run goes live.
@Observable
@MainActor
final class ScriptPreviewStore {
    static let shared = ScriptPreviewStore()

    private static let kLatest = "aarc.script_preview.latest"
    private static let kPlanKind = "aarc.script_preview.planKind"
    private static let kDistance = "aarc.script_preview.distanceKm"
    private static let kTimeMinutes = "aarc.script_preview.timeMinutes"

    var latest: GeneratedScript? {
        didSet { persistLatest() }
    }

    var planKind: RunPlan.Kind {
        didSet { UserDefaults.standard.set(planKind.rawValue, forKey: Self.kPlanKind) }
    }

    var distanceKm: Double {
        didSet { UserDefaults.standard.set(distanceKm, forKey: Self.kDistance) }
    }

    var timeMinutes: Double {
        didSet { UserDefaults.standard.set(timeMinutes, forKey: Self.kTimeMinutes) }
    }

    /// Computed plan from the persisted fields.
    var currentPlan: RunPlan {
        switch planKind {
        case .distance: return .distance(km: distanceKm)
        case .time: return .time(minutes: timeMinutes)
        case .open: return .open
        }
    }

    init() {
        let store = UserDefaults.standard
        if let raw = store.string(forKey: Self.kPlanKind),
           let kind = RunPlan.Kind(rawValue: raw) {
            self.planKind = kind
        } else {
            self.planKind = .distance
        }
        self.distanceKm = store.object(forKey: Self.kDistance) as? Double ?? 5
        self.timeMinutes = store.object(forKey: Self.kTimeMinutes) as? Double ?? 30
        if let data = store.data(forKey: Self.kLatest),
           let decoded = try? JSONDecoder().decode(GeneratedScript.self, from: data) {
            self.latest = decoded
        }
    }

    func clear() {
        latest = nil
    }

    private func persistLatest() {
        let store = UserDefaults.standard
        if let latest, let data = try? JSONEncoder().encode(latest) {
            store.set(data, forKey: Self.kLatest)
        } else {
            store.removeObject(forKey: Self.kLatest)
        }
    }
}
